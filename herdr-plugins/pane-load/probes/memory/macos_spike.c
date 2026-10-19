// Does ri_interval_max_phys_footprint catch a spike that is gone by the next sample?
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <libproc.h>
int proc_reset_footprint_interval(pid_t pid);
#define MB(x) ((double)(x)/1048576)
static void show(const char *tag, pid_t pid){
    struct rusage_info_v6 ru; proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t*)&ru);
    printf("%-26s footprint=%7.1f resident=%7.1f interval_max=%7.1f lifetime_max=%7.1f (MB)\n", tag,
        MB(ru.ri_phys_footprint), MB(ru.ri_resident_size), MB(ru.ri_interval_max_phys_footprint), MB(ru.ri_lifetime_max_phys_footprint));
}
int main(void){
    int go[2]; pipe(go);
    pid_t c = fork();
    if (c == 0) {
        char b; read(go[0], &b, 1);
        size_t n = 300u<<20;
        volatile char *p = mmap(0, n, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0);
        for (size_t i = 0; i < n; i += 4096) p[i] = 1;   // touch every page
        munmap((void*)p, n);
        for(;;) pause();
    }
    usleep(100000);
    show("before spike", c);
    printf("reset -> %d\n", proc_reset_footprint_interval(c));
    write(go[1], "x", 1); usleep(500000);
    show("after spike+unmap", c);
    printf("reset -> %d\n", proc_reset_footprint_interval(c));
    show("after reset", c);
    kill(c, SIGKILL); waitpid(c, 0, 0);
}
