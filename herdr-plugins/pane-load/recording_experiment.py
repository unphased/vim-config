#!/usr/bin/env python3
"""Compare full snapshots, lossless deltas and bounded adaptive history.

A live run observes the Mac at a constant base rate. Lower-rate comparisons are
subsamples of that same run. --workload starts ONE bounded CPU worker plus a
20 MiB allocation ramp. All private raw data is temporary; no production changes.
"""
import argparse
import json
import math
from pathlib import Path
import runpy
import statistics
import subprocess
import time

from recording_adaptive import adaptive_records
from recording_codec import (canonical_row, sparse_frames, restore_sparse,
                             encode_sparse, decode_sparse, encode_events, decode_events,
                             _uvarint, _read_uvarint)

PROBE = runpy.run_path(str(Path(__file__).with_name("recording-probe.py")))
CODECS = [("zstd-1",["zstd","-q","-1","-c"],["zstd","-q","-d","-c"]),
          ("zstd-3",["zstd","-q","-3","-c"],["zstd","-q","-d","-c"]),
          ("brotli-4",["brotli","-q","4","-c"],["brotli","-d","-c"])]

WORKLOAD = r'''
import json, time
start=time.monotonic()
blocks=[]
old_phase=None
while True:
    elapsed=time.monotonic()-start
    phase=('busy' if 10<=elapsed<40 else 'pulse' if 45<=elapsed<46 else
           'rss_grow' if 50<=elapsed<52 else 'rss_hold' if 52<=elapsed<55 else 'quiet')
    if phase!=old_phase:
        print(json.dumps({'phase':phase,'elapsed_s':elapsed,'wall_ns':time.time_ns()}),flush=True)
        old_phase=phase
    if elapsed>=60:
        break
    if phase in ('busy','pulse'):
        sum(i*i for i in range(10000))
    else:
        if phase=='rss_grow':
            desired=min(20,int((elapsed-50)*10)+1)
            while len(blocks)<desired:
                blocks.append(bytearray(1024*1024))
        elif elapsed>=55:
            blocks.clear()
        time.sleep(.01)
'''


def synthetic_rows(samples, interval, processes=1000):
    """Deterministic largely-idle host with a sustained plateau and pulse."""
    cpu = [0]*processes
    for seq in range(samples):
        elapsed = seq*interval
        rows = []
        for pid in range(processes):
            rate = .02 if pid==1 else (.8 if pid==0 and 10<=elapsed<40 else 0)
            if pid==0 and 45<=elapsed<46:
                rate=.8
            if seq:
                cpu[pid] += round(rate*interval*1e9)
            rss=16*1024*1024
            if pid==2:
                rss += int(min(max(elapsed-50,0),2)*10)*1024*1024
                if elapsed>=55:
                    rss=16*1024*1024
            rows.append([pid+100,1,123,0,"worker",cpu[pid],0,rss])
        start=round(elapsed*1e9)
        yield {"seq":seq,"wall_start_ns":10**18+start,"scan_start_ns":start,
               "scan_end_ns":start+1_000_000,"processes":rows}


def chunk_events(rows, chunks, events):
    """Offline finalization: split summaries using their original observations."""
    import bisect
    sequences=[row["seq"] for row in rows]
    boundaries=[chunk[-1]["seq"] for chunk in chunks]
    output=[[] for _ in chunks]
    observed=None
    for event in events:
        end=event["last_seq"] if event["type"]=="summary" else event["seq"]
        last=bisect.bisect_left(boundaries,end)
        first=bisect.bisect_left(boundaries,event.get("first_seq",end))
        if first==last:
            output[last].append(event)
            continue
        if observed is None:
            observed={row["seq"]:{(p[0],p[2],p[3]):p for p in row["processes"]} for row in rows}
        identity=tuple(event["identity"])
        lo=bisect.bisect_left(sequences,event["first_seq"])
        hi=bisect.bisect_right(sequences,end)
        slices=[[] for _ in range(first,last+1)]
        for row in rows[lo:hi]:
            idx=bisect.bisect_left(boundaries,row["seq"])
            slices[idx-first].append((row,observed[row["seq"]][identity]))
        assert sum(map(len,slices))==event["observations"]
        for idx, observations in enumerate(slices,first):
            a,p=observations[0]; b,q=observations[-1]
            split=dict(event)
            split.update(first_seq=a["seq"],last_seq=b["seq"],
                first_wall_start_ns=a["wall_start_ns"],last_wall_start_ns=b["wall_start_ns"],
                first_scan_start_ns=a["scan_start_ns"],last_scan_start_ns=b["scan_start_ns"],
                first_scan_end_ns=a["scan_end_ns"],last_scan_end_ns=b["scan_end_ns"],
                user_ns_start=p[5],user_ns_end=q[5],system_ns_start=p[6],system_ns_end=q[6],
                rss_min_bytes=min(item[7] for _,item in observations),
                rss_max_bytes=max(item[7] for _,item in observations),rss_end_bytes=q[7],
                observations=len(observations),metadata=[q[1],q[4]])
            output[idx].append(split)
    for chunk, selected in zip(chunks,output):
        assert sum(1 if e["type"]=="sample" else e.get("observations",0) for e in selected)==sum(
            len(row["processes"]) for row in chunk)
    return output


def _adaptive_sparse_blob(chunk, events):
    # Samples at the same acquisition share timestamps and sparse process state.
    samples, reasons, other = {}, [], []
    for event in events:
        if event["type"]!="sample":
            other.append(event)
            continue
        seq=event["seq"]
        row=samples.setdefault(seq,{key:event[key] for key in
            ("seq","wall_start_ns","scan_start_ns","scan_end_ns")})
        for key in ("wall_start_ns","scan_start_ns","scan_end_ns"):
            assert row[key]==event[key]
        row.setdefault("processes",[]).append(event["process"])
        if "reason" in event:
            reasons.append([seq,*event["identity"],event["reason"]])
    source=[canonical_row(samples[seq]) for seq in sorted(samples)]
    sections=[encode_sparse(chunk[:1]),encode_sparse(source),encode_events(other),
              json.dumps(reasons,separators=(",", ":")).encode()]
    return b"PAS1"+b"".join(bytes(_uvarint(len(s)))+s for s in sections)


def _check_adaptive_sparse(data, chunk, events):
    if data[:4]!=b"PAS1":
        raise ValueError("bad sparse adaptive header")
    offset=4
    sections=[]
    for _ in range(4):
        length,offset=_read_uvarint(data,offset)
        sections.append(data[offset:offset+length]); offset+=length
    assert offset==len(data)
    assert decode_sparse(sections[0])==chunk[:1]
    reasons={(seq,pid,sec,usec):reason for seq,pid,sec,usec,reason in json.loads(sections[3])}
    restored=decode_events(sections[2])
    for row in decode_sparse(sections[1]):
        for process in row["processes"]:
            identity=[process[0],process[2],process[3]]
            event={key:row[key] for key in ("seq","wall_start_ns","scan_start_ns","scan_end_ns")}
            event.update(type="sample",identity=identity,process=process)
            reason=reasons.get((row["seq"],*identity))
            if reason is not None:
                event["reason"]=reason
            restored.append(event)
    key=lambda e:(e.get("seq",e.get("first_seq")),tuple(e["identity"]),e["type"])
    assert sorted(restored,key=key)==sorted(events,key=key)


def quantize_summaries(events, cpu_unit_ns, rss_unit_bytes):
    """Explicit steady-summary precision experiment; never change full samples."""
    output=[]
    for original in events:
        event=dict(original)
        if event["type"]=="summary":
            if cpu_unit_ns:
                for key in ("user_ns_start","user_ns_end","system_ns_start","system_ns_end"):
                    event[key]=event[key]//cpu_unit_ns*cpu_unit_ns
            if rss_unit_bytes:
                for key in ("rss_min_bytes","rss_end_bytes"):
                    event[key]=event[key]//rss_unit_bytes*rss_unit_bytes
                event["rss_max_bytes"]=-(-event["rss_max_bytes"]//rss_unit_bytes)*rss_unit_bytes
        output.append(event)
    return output


def _quantized_blob(chunk, events, cpu_unit_ns, rss_unit_bytes):
    rounded=quantize_summaries(events,cpu_unit_ns,rss_unit_bytes)
    return (b"PAQ1"+bytes(_uvarint(cpu_unit_ns))+bytes(_uvarint(rss_unit_bytes))+
            _adaptive_sparse_blob(chunk,rounded))


def _check_quantized(data, chunk, events, cpu_unit_ns, rss_unit_bytes):
    assert data[:4]==b"PAQ1"
    cpu,offset=_read_uvarint(data,4); rss,offset=_read_uvarint(data,offset)
    assert (cpu,rss)==(cpu_unit_ns,rss_unit_bytes)
    _check_adaptive_sparse(data[offset:],chunk,quantize_summaries(events,cpu,rss))


def _adaptive_blob(chunk, events):
    checkpoint=encode_sparse(chunk[:1])
    return b"PAB1"+bytes(_uvarint(len(checkpoint)))+checkpoint+encode_events(events)


def _check_adaptive(data, chunk, events):
    if data[:4]!=b"PAB1":
        raise ValueError("bad adaptive chunk")
    length, offset=_read_uvarint(data,4)
    assert decode_sparse(data[offset:offset+length])==chunk[:1]
    assert decode_events(data[offset+length:])==events


def compare(rows, hz, chunk_seconds, workload_pid=None, summary_seconds=10, cpu_threshold=.20,
            summary_cpu_unit_ns=0,summary_rss_unit_bytes=0):
    interval=statistics.mean(b["scan_start_ns"]-a["scan_start_ns"]
                            for a,b in zip(rows,rows[1:]))/1e9
    duration=(rows[-1]["scan_start_ns"]-rows[0]["scan_start_ns"])/1e9+interval
    stats={}
    events=list(adaptive_records(iter(rows),stats=stats,summary_seconds=summary_seconds,
        cpu_threshold=cpu_threshold,max_buffered_per_process=math.ceil(2*hz)+8))
    # Both missing observations and summary coverage must account for every input.
    covered=sum(1 if e["type"]=="sample" else e["observations"] if e["type"]=="summary" else 0
                for e in events)
    assert covered==sum(len(r["processes"]) for r in rows)
    if workload_pid:
        selected=[e for e in events if e["identity"][0]==workload_pid]
        print(json.dumps({"type":"workload_retention","hz":hz,"stats":stats,
            "trigger_samples":[{"seq":e["seq"],"wall_ns":e["wall_start_ns"],"reason":e["reason"]}
                for e in selected if e["type"]=="sample" and "reason" in e],
            "full_samples":sum(e["type"]=="sample" for e in selected),
            "summarized_observations":sum(e.get("observations",0) for e in selected)}),flush=True)
    for seconds in chunk_seconds:
        frames=max(1,round(seconds/interval))
        chunks=[rows[n:n+frames] for n in range(0,len(rows),frames)]
        event_chunks=chunk_events(rows,chunks,events)
        layouts=["full-json","sparse-json","sparse-varint","adaptive-json","adaptive-varint","adaptive-sparse"]
        if summary_cpu_unit_ns or summary_rss_unit_bytes:
            layouts.append("adaptive-sparse-quantized")
        for layout in layouts:
            raw_total=0
            compressed={codec:0 for codec,_,_ in CODECS}
            encode_seconds=0
            for chunk, selected in zip(chunks,event_chunks):
                start=time.perf_counter()
                if layout=="full-json":
                    data=json.dumps(chunk,separators=(",", ":")).encode()
                    restore=lambda d: json.loads(d)==chunk
                elif layout=="sparse-json":
                    data=json.dumps(sparse_frames(chunk),separators=(",", ":")).encode()
                    restore=lambda d: restore_sparse(json.loads(d))==chunk
                elif layout=="sparse-varint":
                    data=encode_sparse(chunk)
                    restore=lambda d: decode_sparse(d)==chunk
                elif layout=="adaptive-json":
                    data=json.dumps([chunk[0],selected],separators=(",", ":")).encode()
                    restore=lambda d: json.loads(d)==[chunk[0],selected]
                elif layout=="adaptive-varint":
                    data=_adaptive_blob(chunk,selected)
                    restore=lambda d: (_check_adaptive(d,chunk,selected) is None)
                elif layout=="adaptive-sparse":
                    data=_adaptive_sparse_blob(chunk,selected)
                    restore=lambda d: (_check_adaptive_sparse(d,chunk,selected) is None)
                else:
                    data=_quantized_blob(chunk,selected,summary_cpu_unit_ns,summary_rss_unit_bytes)
                    restore=lambda d: (_check_quantized(d,chunk,selected,
                        summary_cpu_unit_ns,summary_rss_unit_bytes) is None)
                encode_seconds+=time.perf_counter()-start
                raw_total+=len(data)
                for codec,encoder,decoder in CODECS:
                    packed=subprocess.run(encoder,input=data,capture_output=True,check=True).stdout
                    decoded=subprocess.run(decoder,input=packed,capture_output=True,check=True).stdout
                    assert decoded==data and restore(decoded)
                    compressed[codec]+=len(packed)
            print(json.dumps({"type":"storage","hz":hz,"observed_interval_s":interval,
                "duration_s":duration,"chunk_seconds":seconds,"layout":layout,
                "summary_seconds":summary_seconds,"cpu_threshold":cpu_threshold,
                "summary_cpu_unit_ns":summary_cpu_unit_ns if layout.endswith("quantized") else 0,
                "summary_rss_unit_bytes":summary_rss_unit_bytes if layout.endswith("quantized") else 0,
                "raw_bytes":raw_total,"raw_MiB_per_day":raw_total/duration*86400/1024**2,
                "encoded_in_s":encode_seconds,"compressed":[{"codec":codec,"bytes":size,
                    "MiB_per_day":size/duration*86400/1024**2,"ratio":raw_total/size}
                    for codec,size in compressed.items()],"adaptive_stats":stats}),flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds",type=float,default=60)
    parser.add_argument("--hz",type=int,default=10)
    parser.add_argument("--summary-seconds",type=float,default=10)
    parser.add_argument("--cpu-threshold",type=float,default=.20)
    parser.add_argument("--summary-cpu-ms",type=int,default=0)
    parser.add_argument("--summary-rss-kib",type=int,default=0)
    parser.add_argument("--synthetic",action="store_true")
    parser.add_argument("--workload",action="store_true")
    args=parser.parse_args()
    if (not math.isfinite(args.seconds) or args.seconds<=0 or args.hz<1 or args.seconds*args.hz<2
            or not math.isfinite(args.summary_seconds) or args.summary_seconds<0
            or not math.isfinite(args.cpu_threshold) or args.cpu_threshold<0
            or args.summary_cpu_ms<0 or args.summary_rss_kib<0):
        parser.error("positive finite duration/rate producing at least two samples required")
    PROBE["private_run"]()
    samples=round(args.seconds*args.hz)
    if args.synthetic:
        rows=list(synthetic_rows(samples,1/args.hz))
        workload={"pid":100,"events":[]}
    else:
        rows,timings,workload=PROBE["collect_rows"](samples,1/args.hz,WORKLOAD if args.workload else None)
        print(json.dumps({"type":"sampling","frames":len(rows),"hz":args.hz,
            "processes_min":min(t["processes"] for t in timings),
            "processes_max":max(t["processes"] for t in timings),
            "scan_avg_ms":statistics.mean(t["scan_ns"] for t in timings)/1e6,
            "scan_max_ms":max(t["scan_ns"] for t in timings)/1e6,
            "encode_avg_ms":statistics.mean(t["encode_ns"] for t in timings)/1e6,
            "scan_deadline_overruns":sum(r["scan_end_ns"]>(r["seq"]+1)/args.hz*1e9 for r in rows),
            "unreadable_or_raced_max":max(t["unreadable_or_raced"] for t in timings),
            "workload":workload}),flush=True)
    for row in rows:
        row["processes"].sort(key=lambda p:(p[0],p[2],p[3]))
    for hz in sorted({1,min(5,args.hz),args.hz}):
        if args.hz%hz:
            continue
        subset=rows[::args.hz//hz]
        if len(subset)>1:
            compare(subset,hz,sorted({min(10,args.seconds),args.seconds}),workload["pid"],
                    args.summary_seconds,args.cpu_threshold,args.summary_cpu_ms*1_000_000,
                    args.summary_rss_kib*1024)


if __name__=="__main__":
    main()
