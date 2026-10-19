// Linux: does VmHWM catch a spike, and can clear_refs 5 reset it unprivileged?
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/wait.h>
static void show(const char *tag, pid_t pid){
    char path[64], buf[8192]; snprintf(path, sizeof path, "/proc/%d/status", pid);
    int fd = open(path, O_RDONLY); int n = read(fd, buf, sizeof buf - 1); close(fd); buf[n] = 0;
    long hwm = atol(strstr(buf, "VmHWM:") + 6), rss = atol(strstr(buf, "VmRSS:") + 6), anon = atol(strstr(buf, "RssAnon:") + 8);
    printf("%-22s VmRSS=%6ld MB RssAnon=%6ld MB VmHWM=%6ld MB\n", tag, rss/1024, anon/1024, hwm/1024);
}
static int reset(pid_t pid){
    char path[64]; snprintf(path, sizeof path, "/proc/%d/clear_refs", pid);
    int fd = open(path, O_WRONLY); if (fd < 0) return -1;
    int r = write(fd, "5", 1); close(fd); return r == 1 ? 0 : -1;
}
int main(void){
    int go[2]; pipe(go); pid_t c = fork();
    if (c == 0) { char b; read(go[0], &b, 1); size_t n = 300u<<20;
        volatile char *p = mmap(0, n, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);
        for (size_t i = 0; i < n; i += 4096) p[i] = 1; munmap((void*)p, n); for(;;) pause(); }
    usleep(100000); show("before spike", c);
    write(go[1], "x", 1); usleep(500000); show("after spike+unmap", c);
    printf("clear_refs 5 (own child) -> %d\n", reset(c)); show("after reset", c);
    printf("clear_refs 5 (pid 1)     -> %d\n", reset(1));
    kill(c, SIGKILL); waitpid(c, 0, 0);
}
