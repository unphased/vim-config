// Cost of a full sweep that reads footprint+interval max and then resets the interval.
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <libproc.h>
int proc_reset_footprint_interval(pid_t pid);
static double now_us(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e6+t.tv_nsec/1e3;}
int main(void){
    int cnt = proc_listallpids(NULL,0)+256; pid_t *pids = malloc(cnt*sizeof(pid_t));
    int n = proc_listallpids(pids, cnt*sizeof(pid_t));
    for (int s = 0; s < 3; s++) {
        double t0 = now_us(); int ok = 0;
        for (int i=0;i<n;i++){ struct rusage_info_v6 r; if (!proc_pid_rusage(pids[i],RUSAGE_INFO_V6,(rusage_info_t*)&r)) ok++; }
        double t_read = now_us()-t0; t0 = now_us(); int rok = 0;
        for (int i=0;i<n;i++) if (proc_reset_footprint_interval(pids[i]) == 0) rok++;
        double t_reset = now_us()-t0;
        printf("pids=%d read ok=%d %.2f ms | reset ok=%d %.2f ms\n", n, ok, t_read/1e3, rok, t_reset/1e3);
    }
}
