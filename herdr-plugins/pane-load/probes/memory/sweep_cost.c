// Spike: cost of sampling per-process memory across the whole system.
// macOS: proc_pid_rusage(RUSAGE_INFO_V4) per pid.
// Linux: /proc/<pid>/status (cheap) and /proc/<pid>/smaps_rollup (PSS, expensive).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>

#define SWEEPS 20

static double now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void report(const char *label, double *t, int n, int npids) {
    qsort(t, n, sizeof(double), cmp_d);
    double med = t[n / 2];
    printf("%-34s pids=%d  sweep min=%.3f ms  median=%.3f ms  per-pid=%.2f us\n",
           label, npids, t[0] / 1e3, med / 1e3, med / npids);
}

#if defined(__APPLE__)
#include <libproc.h>
#include <sys/resource.h>

// proc_listallpids(NULL, 0) returns a pid COUNT, not bytes.
// Pad the buffer since processes can spawn between the two calls.
static int list_pids(pid_t **out) {
    int count = proc_listallpids(NULL, 0);
    int cap = count + 256;
    pid_t *p = malloc(cap * sizeof(pid_t));
    int n = proc_listallpids(p, cap * sizeof(pid_t));
    *out = p;
    return n;
}

int main(void) {
    static double t_fp[SWEEPS + 1];
    pid_t *pids;
    int total = list_pids(&pids);
    int ok = 0;
    double sum_fp = 0, sum_res = 0;

    for (int s = 0; s <= SWEEPS; s++) {
        int n = list_pids(&pids);
        double t0 = now_us();
        int good = 0;
        double fp = 0, res = 0;
        for (int i = 0; i < n; i++) {
            struct rusage_info_v4 ru;
            if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&ru) == 0) {
                good++;
                fp += ru.ri_phys_footprint;
                res += ru.ri_resident_size;
            }
        }
        double dt = now_us() - t0;
        if (s == 0) { ok = good; sum_fp = fp; sum_res = res; free(pids); continue; } // warm-up
        t_fp[s - 1] = dt;
        free(pids);
    }
    printf("macOS: %d pids listed, %d readable by this user\n", total, ok);
    printf("sum phys_footprint=%.0f MB  sum resident_size=%.0f MB (double counts shared)\n",
           sum_fp / 1048576, sum_res / 1048576);
    report("proc_pid_rusage(V4)", t_fp, SWEEPS, total);
    return 0;
}

#elif defined(__linux__)

static int list_pids(pid_t *out, int cap) {
    DIR *d = opendir("/proc");
    struct dirent *e;
    int n = 0;
    while (d && (e = readdir(d)) && n < cap) {
        if (!isdigit((unsigned char)e->d_name[0])) continue;
        out[n++] = atoi(e->d_name);
    }
    if (d) closedir(d);
    return n;
}

// Reads a whole small file into buf. Returns bytes read or -1.
static ssize_t slurp(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t total = 0, r;
    while (total < (ssize_t)cap - 1 && (r = read(fd, buf + total, cap - 1 - total)) > 0)
        total += r;
    close(fd);
    buf[total] = 0;
    return total;
}

static long kb_field(const char *buf, const char *key) {
    const char *p = strstr(buf, key);
    if (!p) return -1;
    return atol(p + strlen(key));
}

int main(void) {
    static pid_t pids[8192];
    static char buf[1 << 20];
    static double t_status[SWEEPS], t_rollup[SWEEPS];
    long sum_anon = 0, sum_swap = 0, sum_pss = 0;
    int readable_status = 0, readable_rollup = 0, total = 0;

    for (int s = 0; s <= SWEEPS; s++) {
        total = list_pids(pids, 8192);
        char path[64];
        double t0 = now_us();
        int good = 0;
        long anon = 0, swap = 0;
        for (int i = 0; i < total; i++) {
            snprintf(path, sizeof path, "/proc/%d/status", pids[i]);
            if (slurp(path, buf, sizeof buf) < 0) continue;
            good++;
            long a = kb_field(buf, "RssAnon:"), w = kb_field(buf, "VmSwap:");
            if (a > 0) anon += a;
            if (w > 0) swap += w;
        }
        double dt_status = now_us() - t0;

        t0 = now_us();
        int good_r = 0;
        long pss = 0;
        for (int i = 0; i < total; i++) {
            snprintf(path, sizeof path, "/proc/%d/smaps_rollup", pids[i]);
            if (slurp(path, buf, sizeof buf) < 0) continue;
            good_r++;
            long p = kb_field(buf, "Pss:");
            if (p > 0) pss += p;
        }
        double dt_rollup = now_us() - t0;

        if (s == 0) {
            readable_status = good; readable_rollup = good_r;
            sum_anon = anon; sum_swap = swap; sum_pss = pss;
            continue;
        }
        t_status[s - 1] = dt_status;
        t_rollup[s - 1] = dt_rollup;
    }
    printf("Linux: %d pids listed, status readable=%d, smaps_rollup readable=%d\n",
           total, readable_status, readable_rollup);
    printf("sum RssAnon=%ld MB  sum VmSwap=%ld MB  sum Pss=%ld MB\n",
           sum_anon / 1024, sum_swap / 1024, sum_pss / 1024);
    report("/proc/pid/status (cheap)", t_status, SWEEPS, total);
    report("/proc/pid/smaps_rollup (PSS)", t_rollup, SWEEPS, total);
    return 0;
}

#else
#error unsupported platform
#endif
