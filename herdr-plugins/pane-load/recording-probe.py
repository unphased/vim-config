#!/usr/bin/env python3
"""Diagnostic macOS tuple snapshots/compression; not a production recorder.

Requires cached Cargo dependencies, zstd and brotli. Native reads recheck process
identity but still have partial-visibility and non-atomic-scan limitations.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import tempfile


def dictionary_arrays(chunk):
    identities, previous, frames = {}, {}, []
    for row in chunk:
        updates, slots, users, systems, rss = [], [], [], [], []
        for pid, ppid, sec, usec, name, user, system, resident in row["processes"]:
            identity = (pid, sec, usec)
            if identity not in identities:
                identities[identity] = len(identities)
            slot = identities[identity]
            meta = [pid, sec, usec, ppid, name]
            if previous.get(slot) != meta:
                updates.append([slot, *meta])
                previous[slot] = meta
            slots.append(slot); users.append(user); systems.append(system); rss.append(resident)
        frames.append([row["seq"], row["wall_start_ns"], row["scan_start_ns"],
                       row["scan_end_ns"], updates, slots, users, systems, rss])
    return frames


def restore_dictionary(frames):
    metadata, rows = {}, []
    for seq, wall, start, end, updates, slots, users, systems, rss in frames:
        for slot, *meta in updates:
            metadata[slot] = meta
        processes = []
        for slot, user, system, resident in zip(slots, users, systems, rss, strict=True):
            pid, sec, usec, ppid, name = metadata[slot]
            processes.append([pid, ppid, sec, usec, name, user, system, resident])
        rows.append({"seq":seq, "wall_start_ns":wall, "scan_start_ns":start,
                     "scan_end_ns":end, "processes":processes})
    return rows


def measure(rows, chunk_frames, layout, encoder, decoder):
    raw_bytes = compressed_bytes = 0
    for offset in range(0, len(rows), chunk_frames):
        chunk = rows[offset:offset + chunk_frames]
        payload = chunk if layout == "full" else dictionary_arrays(chunk)
        data = json.dumps(payload, separators=(",", ":")).encode()
        compressed = subprocess.run(encoder, input=data, capture_output=True, check=True).stdout
        decoded = subprocess.run(decoder, input=compressed, capture_output=True, check=True).stdout
        if decoded != data:
            raise RuntimeError("compression round-trip mismatch")
        restored = json.loads(decoded)
        if layout == "dictionary-arrays":
            restored = restore_dictionary(restored)
        if restored != chunk:
            raise RuntimeError("layout round-trip mismatch")
        raw_bytes += len(data); compressed_bytes += len(compressed)
    return raw_bytes, compressed_bytes


def private_run():
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminate)
    os.umask(0o077)


def _summarize_capture(capture_path, timings_path, samples, interval, process_succeeded):
    actual = invalid = 0
    first = last = None
    with Path(capture_path).open("rb") as source:
        json.loads(next(source))
        for line in source:
            try:
                row = json.loads(line)
                stamp = row["scan_start_ns"]
            except (ValueError, KeyError, StopIteration):
                invalid += 1
                continue
            first = stamp if first is None else first
            last = stamp
            actual += 1
    totals = {"scan_ns": 0, "encode_ns": 0, "bytes": 0}
    count = 0
    pmin = pmax = None
    scanmax = 0
    if Path(timings_path).exists():
        with Path(timings_path).open("rb") as source:
            for line in source:
                try:
                    timing = json.loads(line)
                except ValueError:
                    continue
                count += 1
                for key in totals: totals[key] += timing.get(key, 0)
                n = timing.get("processes", 0)
                pmin = n if pmin is None else min(pmin, n)
                pmax = n if pmax is None else max(pmax, n)
                scanmax = max(scanmax, timing.get("scan_ns", 0))
    complete = process_succeeded and actual == samples and not invalid
    return {"type":"sampling", "status":"complete" if complete else "incomplete",
        "frames":actual, "actual_samples":actual, "requested_samples":samples,
        "interval_s":interval, "hz":round(1/interval), "requested_seconds":samples*interval,
        "observed_duration_s":(last-first)/1e9 if first is not None and last is not None else None,
        "observed_interval_s":(last-first)/(actual-1)/1e9 if actual>1 and last is not None else None,
        "processes_min":pmin, "processes_max":pmax,
        "scan_avg_ms":totals["scan_ns"]/count/1e6 if count else None,
        "scan_max_ms":scanmax/1e6 if count else None,
        "encode_avg_ms":totals["encode_ns"]/count/1e6 if count else None,
        "raw_bytes":totals["bytes"], "invalid_rows":invalid}


def collect_rows(samples, interval, workload_code=None, capture_out=None):
    """Acquire privately; capture_out streams natural activity directly to exclusive JSONL."""
    capture = capture_out is not None
    if capture and workload_code is not None:
        raise ValueError("capture mode does not support a controlled workload")
    hz = 1 / interval
    if capture and abs(hz-round(hz)) > 1e-9:
        raise ValueError("capture mode requires an integer Hz")
    output = None
    if capture:
        fd = os.open(capture_out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            output = os.fdopen(fd, "wb")
        except BaseException:
            os.close(fd)
            raise
        try:
            output.write((json.dumps({"probe_capture":1,"hz":round(hz),"seconds":samples*interval,
                "workload":{"pid":None,"events":[]},"requested_samples":samples},separators=(",", ":"))+"\n").encode())
            output.flush()
        except BaseException:
            output.close()
            raise
    source = Path(__file__).resolve().parent / "src/main.rs"
    rust = r'''
#[allow(dead_code)]
mod existing { include!(SOURCE_PATH); pub fn probe(samples:u64,interval:f64) {
let sampler=MacProcessSampler::new().unwrap(); let start=Instant::now(); let mut out=io::BufWriter::new(io::stdout().lock());
for seq in 0..samples { let deadline=start+Duration::from_secs_f64(seq as f64*interval);
if let Some(delay)=deadline.checked_duration_since(Instant::now()){thread::sleep(delay);}
let wall=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos(); let scan_start=start.elapsed().as_nanos();
let pids=sampler.pids(); let enumerated=pids.len(); let processes:Vec<_>=pids.into_iter().filter_map(|pid|{let p=sampler.process(pid)?;let a=sampler.bsd_info(pid)?;(p.identity()==(pid,a.start_sec,a.start_usec)).then_some(p)}).collect();
let scan_end=start.elapsed().as_nanos(); let tuples:Vec<_>=processes.into_iter().map(|p|json!([p.pid,p.ppid,p.start.0,p.start.1,p.name,p.user_ns,p.system_ns,p.resident_bytes])).collect();
let bytes=serde_json::to_vec(&json!({"seq":seq,"wall_start_ns":wall as u64,"scan_start_ns":scan_start as u64,"scan_end_ns":scan_end as u64,"processes":tuples})).unwrap();
let encode_end=start.elapsed().as_nanos();out.write_all(&bytes).unwrap();out.write_all(b"\n").unwrap();out.flush().unwrap();
eprintln!("{}",json!({"processes":tuples.len(),"enumerated":enumerated,"unreadable_or_raced":enumerated-tuples.len(),"scan_ns":scan_end-scan_start,"encode_ns":encode_end-scan_end,"bytes":bytes.len()+1})); }} }
fn main(){let a:Vec<String>=std::env::args().collect();existing::probe(a[1].parse().unwrap(),a[2].parse().unwrap());}
'''.replace("SOURCE_PATH", json.dumps(str(source)))
    timing_path = None
    succeeded = False
    try:
        with tempfile.TemporaryDirectory(prefix="procstats-probe-") as directory:
            root=Path(directory); timing_path=root/"timings"
            (root/"src").mkdir(); (root/"src/main.rs").write_text(rust)
            (root/"Cargo.toml").write_text('[package]\nname="procstats-recording-probe"\nversion="0.0.0"\nedition="2024"\n[dependencies]\nlibc="0.2"\nserde_json="1"\nsha2="0.10"\n')
            try:
                subprocess.run(["cargo","build","--offline","--release","--manifest-path",str(root/"Cargo.toml")],check=True,stdout=subprocess.DEVNULL if capture else None)
                if capture:
                    with timing_path.open("wb") as err:
                        child=subprocess.Popen([str(root/"target/release/procstats-recording-probe"),str(samples),str(interval)],stdout=output,stderr=err)
                        try: rc=child.wait()
                        finally:
                            if child.poll() is None:
                                child.terminate()
                                try: child.wait(timeout=5)
                                except subprocess.TimeoutExpired: child.kill(); child.wait()
                    if rc: raise subprocess.CalledProcessError(rc, child.args)
                    succeeded=True
                else:
                    with (root/"snapshots").open("wb") as out, (root/"timings").open("wb") as err, (root/"workload").open("wb") as log:
                        worker=subprocess.Popen([sys.executable,"-c",workload_code],stdout=log,stderr=log) if workload_code else None
                        try: subprocess.run([str(root/"target/release/procstats-recording-probe"),str(samples),str(interval)],stdout=out,stderr=err,check=True)
                        finally:
                            if worker:
                                if worker.poll() is None: worker.terminate()
                                try: worker.wait(timeout=5)
                                except subprocess.TimeoutExpired: worker.kill(); worker.wait()
                    rows=[json.loads(x) for x in (root/"snapshots").read_text().splitlines()]
                    timings=[json.loads(x) for x in (root/"timings").read_text().splitlines()]
                    workload={"pid":worker.pid if worker else None,"events":[json.loads(x) for x in (root/"workload").read_text().splitlines()]}
                    return rows,timings,workload
            finally:
                if capture:
                    output.flush()
                    summary=_summarize_capture(capture_out,timing_path,samples,interval,succeeded)
                    if not summary["status"]=="complete": print(json.dumps(summary),file=sys.stderr,flush=True)
        return summary
    finally:
        if output is not None: output.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--capture-out", type=Path)
    args = parser.parse_args()
    if args.samples < 1 or not 0 < args.interval < float("inf"):
        parser.error("samples and finite interval must be positive")
    if args.capture_out and abs(1/args.interval-round(1/args.interval)) > 1e-9:
        parser.error("--capture-out requires an integer Hz")
    private_run()
    if args.capture_out:
        try:
            summary=collect_rows(args.samples,args.interval,capture_out=args.capture_out)
        except Exception as error:
            print(f"capture failed: {error}",file=sys.stderr,flush=True)
            return 1
        print(json.dumps(summary),flush=True)
        return 0 if summary["status"]=="complete" else 1
    rows, timings, _ = collect_rows(args.samples, args.interval)
    observed = ((rows[-1]["scan_start_ns"]-rows[0]["scan_start_ns"])/(len(rows)-1)/1e9) \
        if len(rows)>1 else None
    print(json.dumps({"type":"sampling","frames":len(rows),"interval_s":args.interval,
        "observed_interval_s":observed,"processes_min":min(x["processes"] for x in timings),
        "processes_max":max(x["processes"] for x in timings),
        "scan_deadline_overruns":sum(r["scan_end_ns"]>(r["seq"]+1)*args.interval*1e9 for r in rows),
        "scan_avg_ms":statistics.mean(x["scan_ns"] for x in timings)/1e6,
        "scan_max_ms":max(x["scan_ns"] for x in timings)/1e6,
        "encode_avg_ms":statistics.mean(x["encode_ns"] for x in timings)/1e6,
        "raw_bytes":sum(x["bytes"] for x in timings)}), flush=True)
    codecs = [("zstd-1",["zstd","-q","-1","-c"],["zstd","-q","-d","-c"]),
              ("zstd-3",["zstd","-q","-3","-c"],["zstd","-q","-d","-c"]),
              ("brotli-4",["brotli","-q","4","-c"],["brotli","-d","-c"])]
    for chunk_frames in sorted({1,min(10,len(rows)),len(rows)}):
        for layout in ["full","dictionary-arrays"]:
            for codec, encoder, decoder in codecs:
                raw, compressed = measure(rows,chunk_frames,layout,encoder,decoder)
                print(json.dumps({"type":"compression","layout":layout,"codec":codec,
                    "chunk_frames":chunk_frames,"raw_bytes":raw,"compressed_bytes":compressed,
                    "ratio":raw/compressed,"projected_MiB_per_day_at_requested_interval":
                    compressed/len(rows)/args.interval*86400/1024**2,
                    "projected_MiB_per_day_at_observed_interval":
                    compressed/len(rows)/observed*86400/1024**2 if observed else None}), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
