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


def collect_rows(samples, interval, workload_code=None):
    """Acquire privately; optional bounded workload is killed/reaped on any exit."""
    source = Path(__file__).resolve().parent / "src/main.rs"
    rust = r'''
#[allow(dead_code)]
mod existing {
    include!(SOURCE_PATH);
    pub fn probe(samples: u64, interval: f64) {
        let sampler = MacProcessSampler::new().unwrap();
        let start = Instant::now();
        let mut out = io::BufWriter::new(io::stdout().lock());
        for seq in 0..samples {
            let deadline = start + Duration::from_secs_f64(seq as f64 * interval);
            if let Some(delay) = deadline.checked_duration_since(Instant::now()) {
                thread::sleep(delay);
            }
            let wall = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
            let scan_start = start.elapsed().as_nanos();
            let pids = sampler.pids();
            let enumerated = pids.len();
            let processes: Vec<_> = pids.into_iter().filter_map(|pid| {
                let process = sampler.process(pid)?;
                let after = sampler.bsd_info(pid)?;
                (process.identity() == (pid, after.start_sec, after.start_usec)).then_some(process)
            }).collect();
            let scan_end = start.elapsed().as_nanos();
            let tuples: Vec<_> = processes.into_iter().map(|p| {
                json!([p.pid,p.ppid,p.start.0,p.start.1,p.name,p.user_ns,p.system_ns,p.resident_bytes])
            }).collect();
            let bytes = serde_json::to_vec(&json!({"seq":seq,"wall_start_ns":wall as u64,
                "scan_start_ns":scan_start as u64,"scan_end_ns":scan_end as u64,
                "processes":tuples})).unwrap();
            let encode_end = start.elapsed().as_nanos();
            out.write_all(&bytes).unwrap(); out.write_all(b"\n").unwrap(); out.flush().unwrap();
            eprintln!("{}",json!({"processes":tuples.len(),"enumerated":enumerated,
                "unreadable_or_raced":enumerated-tuples.len(),"scan_ns":scan_end-scan_start,
                "encode_ns":encode_end-scan_end,"bytes":bytes.len()+1}));
        }
    }
}
fn main() {
    let args: Vec<String> = std::env::args().collect();
    existing::probe(args[1].parse().unwrap(),args[2].parse().unwrap());
}
'''.replace("SOURCE_PATH", json.dumps(str(source)))
    with tempfile.TemporaryDirectory(prefix="procstats-probe-") as directory:
        root = Path(directory)
        (root / "src").mkdir(); (root / "src/main.rs").write_text(rust)
        (root / "Cargo.toml").write_text(
            '[package]\nname="procstats-recording-probe"\nversion="0.0.0"\n'
            'edition="2024"\n[dependencies]\nlibc="0.2"\nserde_json="1"\nsha2="0.10"\n')
        subprocess.run(["cargo","build","--offline","--release","--manifest-path",
                        str(root / "Cargo.toml")], check=True)
        with (root / "snapshots").open("wb") as out, (root / "timings").open("wb") as err, \
                (root / "workload").open("wb") as log:
            worker = subprocess.Popen([sys.executable,"-c",workload_code], stdout=log, stderr=log) \
                if workload_code else None
            try:
                subprocess.run([str(root / "target/release/procstats-recording-probe"),
                                str(samples),str(interval)], stdout=out, stderr=err, check=True)
            finally:
                if worker:
                    if worker.poll() is None:
                        worker.terminate()
                    try:
                        worker.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        worker.kill(); worker.wait()
        rows = [json.loads(x) for x in (root / "snapshots").read_text().splitlines()]
        timings = [json.loads(x) for x in (root / "timings").read_text().splitlines()]
        workload = {"pid":worker.pid if worker else None,
                    "events":[json.loads(x) for x in (root / "workload").read_text().splitlines()]}
        return rows, timings, workload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args()
    if args.samples < 1 or not 0 < args.interval < float("inf"):
        parser.error("samples and finite interval must be positive")
    private_run()
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
    main()
