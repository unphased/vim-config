#!/usr/bin/env python3
"""Narrow real-capture replay: shared clocks, sparse changes, bounded CPU curves.

Full frames include exact topology/RSS/timing/availability sidecar, but CPU is
TOTAL only (user/system split intentionally not retained). No daemon integration.
"""
import argparse
from collections import defaultdict
from fractions import Fraction
import gzip
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import time

from recording_codec import encode_sparse, decode_sparse, canonical_row
from recording_cpu_matrix import load_series, require
from recording_cpu_shared import encode_shared, decode_shared
from recording_cpu_decimate import simplify, audit

CASES=[('sparse-native','changes',1,0),('sparse-1ms','changes',24000,0),
       ('sparse-10ms','changes',240000,0),('linear-exact','points',1,0),
       ('linear-1ms','points',1,24000),('linear-10ms','points',1,240000),
       ('linear-100ms','points',1,2400000),
       ('combined-1ms','points',12000,12000),('combined-10ms','points',120000,120000)]
CODECS=[('zstd-3',['zstd','-q','-3','-c'],['zstd','-q','-d','-c']),
        ('brotli-4',['brotli','-q','4','-c'],['brotli','-d','-c']),
        ('gzip-6',None,None)]


def frame(cpu,sidecar,tolerance,rss_unit=1):
    return b'PFX2'+struct.pack('<QQQQ',tolerance,len(cpu),len(sidecar),rss_unit)+cpu+sidecar


def unframe(data):
    require(data[:4]==b'PFX2' and len(data)>=36,'invalid focus frame')
    tolerance,n,m,rss_unit=struct.unpack_from('<QQQQ',data,4)
    require(len(data)==36+n+m and rss_unit>0,'invalid focus lengths or RSS unit')
    return tolerance,data[36:36+n],data[36+n:],rss_unit


def loss(raw,decoded):
    """Compare at recorded sample times; do not invent truth between polls."""
    require(raw.keys()==decoded.keys(),'identity dropped')
    largest=Fraction(0); interval_rate=Fraction(0); total_points=0
    for identity,source in raw.items():
        selected=decoded[identity]
        require(source[0]==selected[0] and source[-1]==selected[-1],'CPU endpoint lost')
        j=0; previous_error=None; previous=None
        for seq,cpu,stamp in source:
            while j+1<len(selected) and selected[j+1][0]<=seq:
                j+=1
            if selected[j][0]==seq:
                estimate=Fraction(selected[j][1])
            else:
                a,b=selected[j:j+2]
                estimate=Fraction(a[1])+Fraction((b[1]-a[1])*(stamp-a[2]),b[2]-a[2])
            error=estimate-cpu
            largest=max(largest,abs(error))
            if previous is not None and seq==previous[0]+1:
                interval_rate=max(interval_rate,abs(error-previous_error)/(stamp-previous[2]))
            previous_error=error; previous=(seq,cpu,stamp)
        total_points+=len(selected)
    return {'max_counter_error_native':largest,
            'max_counter_error_ms':float(largest)*125/3/1e6,
            'max_observed_interval_error_pp':float(interval_rate)*125/3*100,
            'retained_points':total_points}


def worker_window_error(source,decoded,pid):
    """Whole-capture window audit; callers concatenate independently decoded frames."""
    for identity,original in source.items():
        if identity[0]==pid:
            value=audit(original,decoded[identity],allow_estimated=True)['max_1s_cpu_rate_error']
            return None if value is None else value*125/3*100
    return None


def run(path,frame_seconds):
    source,base_hz,duration=load_series(path,125,3)
    with path.open() as stream:
        header=json.loads(next(stream)); rows=[canonical_row(json.loads(line)) for line in stream]
    workload_pid=header.get('workload',{}).get('pid')
    rss_unit=0
    for row in rows:
        for p in row['processes']:
            rss_unit=math.gcd(rss_unit,p[7])
    rss_unit=max(1,rss_unit)
    print(json.dumps({'type':'source','sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
        'duration_s':duration,'acquisition_hz':base_hz,'identities':len(source),
        'raw_points':sum(map(len,source.values())),'cpu_component':'total only; no user/system split',
        'sidecar':'exact identity/name/PPID/RSS/availability/scan bounds/wall markers',
        'rss_exact_unit_bytes':rss_unit,
        'time_basis':'captured scan-start markers, NOT per-process query timestamps',
        'decimator':'offline bounded cumulative-CPU interpolation error; not a streaming policy'}),flush=True)
    for seconds in frame_seconds:
        size=base_hz*seconds
        chunks=[]
        for offset in range(0,len(rows),size):
            part=rows[offset:offset+size]; seqs={row['seq'] for row in part}
            series={k:[p for p in samples if p[0] in seqs] for k,samples in source.items()}
            series={k:v for k,v in series.items() if v}
            metadata=[]
            for row in part:
                clone={**row,'processes':[]}
                for p in row['processes']:
                    q=p[:]; q[5]=q[6]=0; q[7]//=rss_unit; clone['processes'].append(q)
                metadata.append(clone)
            sidecar=encode_sparse(metadata)
            restored_meta=decode_sparse(sidecar)
            require(restored_meta==metadata,'sidecar roundtrip failed')
            for restored_row,original in zip(restored_meta,part):
                recovered={**restored_row,'processes':[p[:7]+[p[7]*rss_unit] for p in restored_row['processes']]}
                expected={**original,'processes':[p[:5]+[0,0,p[7]] for p in original['processes']]}
                require(recovered==expected,'native RSS unit changed metadata')
            chunks.append((series,sidecar,metadata))
        for name,layout,quantum,tolerance in CASES:
            started=time.monotonic(); blobs=[]; retained=0; maxerr=0; maxrate=0
            restored_all=defaultdict(list); cpu_blobs=[]
            for series,sidecar,metadata in chunks:
                selected=series if layout=='changes' else {
                    k:simplify(v,tolerance,max_span_ns=10_000_000_000) for k,v in series.items()}
                payload=encode_shared(selected,layout=layout,quantum=quantum)
                restored=decode_shared(payload)
                if quantum==1:
                    require(restored==selected,'CPU integer roundtrip failed')
                metrics=loss(series,restored)
                require(metrics['max_counter_error_native']<=tolerance+quantum-1,
                        'declared CPU curve error exceeded')
                for identity,points in restored.items():
                    restored_all[identity].extend(points)
                cpu_blobs.append(payload)
                retained+=metrics['retained_points']; maxerr=max(maxerr,metrics['max_counter_error_ms'])
                maxrate=max(maxrate,metrics['max_observed_interval_error_pp'])
                data=frame(payload,sidecar,tolerance,rss_unit)
                epsilon,cpu,meta,unit=unframe(data)
                require(epsilon==tolerance and cpu==payload and meta==sidecar and unit==rss_unit,'frame roundtrip failed')
                blobs.append(data)
            work_error=worker_window_error(source,restored_all,workload_pid)
            loss(source,restored_all)  # Validate global endpoints across frame boundaries.
            encoded_seconds=time.monotonic()-started
            results=[]
            for codec,encoder,decoder in CODECS:
                total=0; ctime=0; dtime=0; cpu_total=0; sidecar_total=0
                for blob in blobs:
                    t=time.monotonic()
                    packed=(subprocess.run(encoder,input=blob,capture_output=True,check=True).stdout
                            if encoder else gzip.compress(blob,compresslevel=6,mtime=0))
                    ctime+=time.monotonic()-t; t=time.monotonic()
                    decoded=(subprocess.run(decoder,input=packed,capture_output=True,check=True).stdout
                             if decoder else gzip.decompress(packed))
                    dtime+=time.monotonic()-t
                    require(decoded==blob,'compressed frame roundtrip failed')
                    total+=len(packed)
                for component in cpu_blobs:
                    packed=(subprocess.run(encoder,input=component,capture_output=True,check=True).stdout
                            if encoder else gzip.compress(component,compresslevel=6,mtime=0))
                    cpu_total+=len(packed)
                for _,component,_ in chunks:
                    packed=(subprocess.run(encoder,input=component,capture_output=True,check=True).stdout
                            if encoder else gzip.compress(component,compresslevel=6,mtime=0))
                    sidecar_total+=len(packed)
                results.append({'codec':codec,'bytes':total,'MiB_per_day':total/duration*86400/1024**2,
                    'CPU_only_MiB_per_day':cpu_total/duration*86400/1024**2,
                    'sidecar_only_MiB_per_day':sidecar_total/duration*86400/1024**2,
                    'component_sizes_not_additive':True,'compress_s':ctime,'decompress_s':dtime})
            print(json.dumps({'type':'focus','case':name,'frame_s':seconds,'frames':len(blobs),
                'cpu_quantum_native':quantum,'curve_tolerance_ms':tolerance*125/3/1e6,
                'total_counter_error_bound_ms':(tolerance+quantum-1)*125/3/1e6,
                'retained_points':retained,'source_points':sum(map(len,source.values())),
                'max_counter_error_ms':maxerr,'max_observed_interval_error_pp':maxrate,
                'controlled_worker_max_1s_error_pp':work_error,
                'worker_window_audit_scope':'whole capture, including across frame boundaries',
                'encoded_bytes':sum(map(len,blobs)),
                'encoded_MiB_per_day':sum(map(len,blobs))/duration*86400/1024**2,
                'CPU_frame_encode_and_audit_s_excluding_sidecar':encoded_seconds,'compressed':results}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',type=Path,required=True)
    parser.add_argument('--frames',type=int,nargs='+',default=[10,60])
    args=parser.parse_args()
    if min(args.frames)<1:
        parser.error('positive frame durations required')
    run(args.input,args.frames)
