#!/usr/bin/env python3
"""CPU-only layout/compressor matrix over a private diagnostic capture.

Keeps every observed identity's first/last readings at every retention rate.
Excludes PID/tree/RSS/index data: numbers are NOT whole-recorder storage totals.
Optional Mach timebase restores native counters from exact normalized ns values.
"""
import argparse
from collections import defaultdict
import gzip
import json
from pathlib import Path
import subprocess

from recording_codec import _uvarint, _read_uvarint
from recording_cpu_columns import encode_series, decode_series, quantize_cumulative

LAYOUTS = ("interleaved","columns","runs","grouped","both-runs","cpu-runs",
           "cumulative-columns","cumulative-interleaved")
INTEGER_CODECS = ("uvarint","uint64le")
COMPRESSORS = [("zstd-1",["zstd","-q","-1","-c"],["zstd","-q","-d","-c"]),
               ("zstd-3",["zstd","-q","-3","-c"],["zstd","-q","-d","-c"]),
               ("brotli-4",["brotli","-q","4","-c"],["brotli","-d","-c"])]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def restore_native(ns, numer, denom):
    require(numer >= denom > 0, "native restoration requires an injective timebase (numer >= denom > 0)")
    require(isinstance(ns,int) and not isinstance(ns,bool) and ns>=0, "invalid normalized CPU counter")
    native=(ns*denom+numer-1)//numer
    if native*numer//denom!=ns:
        raise ValueError("counter is not an exact normalized value for this Mach timebase")
    return native


def load_series(path, numer, denom):
    series=defaultdict(list)
    previous_parts={}
    with path.open() as source:
        header=json.loads(next(source))
        if header.get("probe_capture")!=1:
            raise ValueError("not a diagnostic capture")
        first=last=None
        for line in source:
            row=json.loads(line)
            stamp=row["scan_start_ns"]
            first=stamp if first is None else first
            last=stamp
            for p in row["processes"]:
                user,system=restore_native(p[5],numer,denom),restore_native(p[6],numer,denom)
                identity=(p[0],p[2],p[3])
                old=previous_parts.get(identity)
                require(old is None or (user>=old[0] and system>=old[1]),
                        "component counter reset: split acquisition epochs before comparison")
                previous_parts[identity]=(user,system)
                cpu=user+system
                samples=series[identity]
                require(not samples or (cpu>=samples[-1][1] and stamp>samples[-1][2]),
                        "counter reset or nonmonotone time: split acquisition epochs before comparison")
                samples.append((row["seq"],cpu,stamp))
    require(first is not None and last>first, "capture must span multiple observations")
    duration=(last-first)/1e9
    return dict(sorted(series.items())),header["hz"],duration


def retain_endpoints(series, stride):
    result=[]
    for samples in series.values():
        selected=[sample for i,sample in enumerate(samples)
                  if i==0 or i==len(samples)-1 or sample[0]%stride==0]
        result.append(([s[1] for s in selected],[s[2] for s in selected]))
    return result


def bundle(series, cpu_quantum, time_quantum, layout, integer_codec, endpoints):
    output=bytearray(b"CPC1")
    output.extend(_uvarint(cpu_quantum)); output.extend(_uvarint(time_quantum))
    output.append(int(endpoints)); output.extend(_uvarint(len(series)))
    accounted=0
    for cpu,times in series:
        cq,cr=quantize_cumulative(cpu,cpu_quantum)
        tq,tr=quantize_cumulative(times,time_quantum)
        require(all(b>a for a,b in zip(tq,tq[1:])),
                "time quantum collapses retained observations; choose a finer time unit")
        data=encode_series(cq,tq,layout,integer_codec)
        output.extend(_uvarint(len(data))); output.extend(data)
        if endpoints:
            for value in (cr[0],cr[-1],tr[0],tr[-1]):
                output.extend(_uvarint(value))
        accounted+=cpu_quantum*(cq[-1]-cq[0])+(cr[-1]-cr[0] if endpoints else 0)
    return bytes(output),accounted


def verify_bundle(data, expected):
    require(data[:4]==b"CPC1", "invalid corpus header")
    cpu_unit,offset=_read_uvarint(data,4)
    time_unit,offset=_read_uvarint(data,offset)
    endpoints=data[offset]; offset+=1
    count,offset=_read_uvarint(data,offset)
    require(count==len(expected), "series count mismatch")
    for cpu,times in expected:
        length,offset=_read_uvarint(data,offset)
        cq,tq=decode_series(data[offset:offset+length]); offset+=length
        source_cq,source_cr=quantize_cumulative(cpu,cpu_unit)
        source_tq,source_tr=quantize_cumulative(times,time_unit)
        require((cq,tq)==(source_cq,source_tq), "cumulative array roundtrip failed")
        if endpoints:
            tails=[]
            for _ in range(4):
                value,offset=_read_uvarint(data,offset); tails.append(value)
            require(tails==[source_cr[0],source_cr[-1],source_tr[0],source_tr[-1]], "endpoint remainder mismatch")
            require(cpu_unit*(cq[-1]-cq[0])+tails[1]-tails[0]==cpu[-1]-cpu[0], "CPU accounting failed")
            require(time_unit*(tq[-1]-tq[0])+tails[3]-tails[2]==times[-1]-times[0], "elapsed time accounting failed")
            require(cpu_unit*cq[0]+tails[0]==cpu[0] and cpu_unit*cq[-1]+tails[1]==cpu[-1],
                    "CPU endpoints not reconstructed exactly")
    require(offset==len(data), "trailing corpus bytes")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input",type=Path,required=True)
    parser.add_argument("--mach-timebase",type=int,nargs=2,metavar=("NUMER","DENOM"))
    parser.add_argument("--rates",type=int,nargs="+",default=[1,10])
    parser.add_argument("--cpu-ms",type=int,nargs="+",default=[0,1,10],help="0 keeps native counter units")
    parser.add_argument("--time-ms",type=int,default=1)
    parser.add_argument("--endpoints",choices=("exact","bounded"),default="exact")
    args=parser.parse_args()
    numer,denom=args.mach_timebase or (1,1)
    if min(numer,denom,args.time_ms)<1 or any(v<0 for v in args.cpu_ms):
        parser.error("positive units and nonnegative CPU quantums required")
    source,base_hz,duration=load_series(args.input,numer,denom)
    total=sum(cpu[-1][1]-cpu[0][1] for cpu in source.values())
    print(json.dumps({"type":"source","component":"CPU/time only","series":len(source),
        "base_hz":base_hz,"duration_s":duration,"duration_convention":"measured first-to-last scan start",
        "cpu_native_unit_ns":[numer,denom],
        "observed_cpu_increment_native_units":total,"endpoints":args.endpoints}),flush=True)
    for rate in args.rates:
        if rate<1 or base_hz%rate:
            parser.error("retention rates must divide acquisition rate")
        retained=retain_endpoints(source,base_hz//rate)
        require(sum(c[-1]-c[0] for c,_ in retained)==total, "retention dropped observed CPU time")
        for cpu_ms in args.cpu_ms:
            quantum=1 if cpu_ms==0 else cpu_ms*1_000_000*denom//numer
            if quantum<1 or (cpu_ms and cpu_ms*1_000_000*denom%numer):
                parser.error("CPU quantum must be an exact positive native-unit multiple")
            for layout in LAYOUTS:
                for integer_codec in INTEGER_CODECS:
                    data,accounted=bundle(retained,quantum,args.time_ms*1_000_000,
                                          layout,integer_codec,args.endpoints=="exact")
                    verify_bundle(data,retained)
                    if args.endpoints=="exact":
                        require(accounted==total, "quantized endpoint accounting lost CPU time")
                    sizes=[]
                    for compressor,encoder,decoder in COMPRESSORS:
                        packed=subprocess.run(encoder,input=data,capture_output=True,check=True).stdout
                        decoded=subprocess.run(decoder,input=packed,capture_output=True,check=True).stdout
                        require(decoded==data, "compressed byte roundtrip failed")
                        sizes.append({"codec":compressor,"bytes":len(packed),
                                      "MiB_per_day":len(packed)/duration*86400/1024**2})
                    packed=gzip.compress(data,compresslevel=6,mtime=0)
                    require(gzip.decompress(packed)==data, "gzip byte roundtrip failed")
                    sizes.append({"codec":"gzip-6","bytes":len(packed),
                                  "MiB_per_day":len(packed)/duration*86400/1024**2})
                    print(json.dumps({"type":"matrix","retention_hz":rate,"cpu_ms":cpu_ms,
                        "cpu_quantum_native_units":quantum,"time_ms":args.time_ms,
                        "layout":layout,"integer_codec":integer_codec,"endpoints":args.endpoints,
                        "raw_bytes":len(data),"raw_MiB_per_day":len(data)/duration*86400/1024**2,
                        "accounted_cpu_increment_native_units":accounted,"compressed":sizes}),flush=True)


if __name__=="__main__":
    main()
