// Relationship between TASK_VM_INFO.compressed and phys_footprint across own-user processes.
#include <stdio.h>
#include <stdlib.h>
#include <libproc.h>
#include <mach/mach.h>
#define MB(x) ((double)(x)/1048576)
int main(void){
    int cnt = proc_listallpids(NULL,0)+256; pid_t *pids = malloc(cnt*sizeof(pid_t));
    int n = proc_listallpids(pids, cnt*sizeof(pid_t));
    int ok=0, over=0; double comp=0, fp=0;
    for (int i=0;i<n;i++){
        mach_port_t tn; if (task_name_for_pid(mach_task_self(), pids[i], &tn)) continue;
        task_vm_info_data_t v; mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
        if (task_info(tn, TASK_VM_INFO, (task_info_t)&v, &c) == KERN_SUCCESS) {
            ok++; comp += v.compressed; fp += v.phys_footprint;
            if (v.compressed > v.phys_footprint) {
                over++; char nm[64]={0}; proc_name(pids[i], nm, sizeof nm);
                printf("compressed>footprint: pid %d %-28s compressed=%.0f MB footprint=%.0f MB\n", pids[i], nm, MB(v.compressed), MB(v.phys_footprint));
            }
        }
        mach_port_deallocate(mach_task_self(), tn);
    }
    printf("own-readable=%d  compressed>footprint in %d  sum compressed=%.0f MB  sum footprint=%.0f MB\n", ok, over, MB(comp), MB(fp));
}
