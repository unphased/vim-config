// Probe macOS memory APIs as an unprivileged user: CPU/resident parity between
// proc_pid_rusage and PROC_PIDTASKINFO, and per-call sweep cost including
// task_name_for_pid + TASK_VM_INFO (per-process compressed bytes).
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

static double now_us(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e6+t.tv_nsec/1e3;}
#define MB(x) ((double)(x)/1048576)

int main(void){
    // 1. Units: rusage ri_user_time vs PROC_PIDTASKINFO pti_total_user for self after burning CPU.
    volatile double x=0; for (long i=0;i<200000000;i++) x+=i*0.5;
    struct rusage_info_v6 ru; struct proc_taskinfo ti;
    proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t*)&ru);
    proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &ti, sizeof ti);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    printf("\nunits: ri_user_time=%llu pti_total_user=%llu timebase=%u/%u\n",
        ru.ri_user_time, ti.pti_total_user, tb.numer, tb.denom);
    printf("       rusage resident=%llu taskinfo resident=%llu\n", ru.ri_resident_size, ti.pti_resident_size);

    // 2. Compressed via task_name_for_pid + TASK_VM_INFO, over all pids.
    int cnt = proc_listallpids(NULL,0)+256; pid_t *pids = malloc(cnt*sizeof(pid_t));
    int n = proc_listallpids(pids, cnt*sizeof(pid_t));
    int name_ok=0, vm_ok=0, ru_ok=0, ti_ok=0; double comp_sum=0, fp_sum=0;
    pid_t best=0; uint64_t bestc=0;
    double t0=now_us();
    for (int i=0;i<n;i++){ struct proc_taskinfo t; if (proc_pidinfo(pids[i],PROC_PIDTASKINFO,0,&t,sizeof t)==sizeof t) ti_ok++; }
    double t_ti=now_us()-t0; t0=now_us();
    for (int i=0;i<n;i++){ struct rusage_info_v6 r; if (!proc_pid_rusage(pids[i],RUSAGE_INFO_V6,(rusage_info_t*)&r)) { ru_ok++; fp_sum+=r.ri_phys_footprint; } }
    double t_ru=now_us()-t0; t0=now_us();
    for (int i=0;i<n;i++){
        mach_port_t tn;
        if (task_name_for_pid(mach_task_self(), pids[i], &tn) != KERN_SUCCESS) continue;
        name_ok++;
        task_vm_info_data_t vi; mach_msg_type_number_t c2 = TASK_VM_INFO_COUNT;
        if (task_info(tn, TASK_VM_INFO, (task_info_t)&vi, &c2) == KERN_SUCCESS) {
            vm_ok++; comp_sum += vi.compressed;
            if (vi.compressed > bestc) { bestc = vi.compressed; best = pids[i]; }
        }
        mach_port_deallocate(mach_task_self(), tn);
    }
    double t_vm=now_us()-t0;
    printf("\npids=%d\n", n);
    printf("PROC_PIDTASKINFO      ok=%4d sweep=%.2f ms\n", ti_ok, t_ti/1e3);
    printf("proc_pid_rusage V6    ok=%4d sweep=%.2f ms  sum footprint=%.0f MB\n", ru_ok, t_ru/1e3, MB(fp_sum));
    printf("task_name+TASK_VM_INFO name_ok=%4d vm_ok=%4d sweep=%.2f ms  sum compressed=%.0f MB\n", name_ok, vm_ok, t_vm/1e3, MB(comp_sum));
    if (best) {
        char nm[64]={0}; proc_name(best,nm,sizeof nm);
        mach_port_t tn; task_name_for_pid(mach_task_self(), best, &tn);
        task_vm_info_data_t vi; mach_msg_type_number_t c2 = TASK_VM_INFO_COUNT;
        task_info(tn, TASK_VM_INFO, (task_info_t)&vi, &c2);
        struct rusage_info_v6 r; proc_pid_rusage(best,RUSAGE_INFO_V6,(rusage_info_t*)&r);
        printf("\nmost-compressed pid %d (%s): vm.phys_footprint=%.1f MB vm.compressed=%.1f MB vm.internal=%.1f MB vm.resident=%.1f MB | rusage footprint=%.1f MB resident=%.1f MB\n",
            best, nm, MB(vi.phys_footprint), MB(vi.compressed), MB(vi.internal), MB(vi.resident_size), MB(r.ri_phys_footprint), MB(r.ri_resident_size));
    }
    return 0;
}
