#!/usr/bin/env python3
"""Diagnostic only: existing macOS sampler -> tuple snapshots -> compression.

Uses the current UI sampler, including its incomplete-observation/identity-race
limitations. This is not a historical recording format or production recorder.
Requires cargo (cached dependencies for --offline), zstd and brotli on PATH.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import signal
import subprocess
import tempfile


def dictionary_arrays(chunk):
    """Reset metadata at every chunk; missing slots mean unobserved, not exited."""
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
            slots.append(slot)
            users.append(user)
            systems.append(system)
            rss.append(resident)
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
        raw_bytes += len(data)
        compressed_bytes += len(compressed)
    return raw_bytes, compressed_bytes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args()
    if args.samples < 1 or not 0 < args.interval < float("inf"):
        parser.error("samples and finite interval must be positive")
    # Unwind TemporaryDirectory and subprocess.run cleanup on catchable termination.
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminate)
    # Private data is removed on normal exit, SIGINT or SIGTERM, not SIGKILL.
    os.umask(0o077)
    source = Path(__file__).resolve().parent / "src/main.rs"
    rust = r'''
#[allow(dead_code)]
mod existing {
    include!(SOURCE_PATH);
    pub fn probe(samples: u64, interval: f64) {
        let mut sampler = MacProcessSampler::new().unwrap();
        let start = Instant::now();
        let mut out = io::BufWriter::new(io::stdout().lock());
        for seq in 0..samples {
            let deadline = start + Duration::from_secs_f64(seq as f64 * interval);
            if let Some(delay) = deadline.checked_duration_since(Instant::now()) {
                thread::sleep(delay);
            }
            let wall_start = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
            let scan_start = start.elapsed().as_nanos();
            let processes = sampler.enumerate();
            let scan_end = start.elapsed().as_nanos();
            let tuples: Vec<_> = processes.into_iter().map(|p| {
                json!([p.pid,p.ppid,p.start.0,p.start.1,p.name,p.user_ns,p.system_ns,p.resident_bytes])
            }).collect();
            let bytes = serde_json::to_vec(&json!({"seq":seq,
                "wall_start_ns":wall_start as u64,"scan_start_ns":scan_start as u64,
                "scan_end_ns":scan_end as u64,"processes":tuples})).unwrap();
            let encode_end = start.elapsed().as_nanos();
            out.write_all(&bytes).unwrap();
            out.write_all(b"\n").unwrap();
            out.flush().unwrap();
            eprintln!("{}",json!({"processes":tuples.len(),"scan_ns":scan_end-scan_start,
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
        (root / "src").mkdir()
        (root / "src/main.rs").write_text(rust)
        (root / "Cargo.toml").write_text(
            '[package]\nname="procstats-recording-probe"\nversion="0.0.0"\n'
            'edition="2024"\n[dependencies]\nlibc="0.2"\nserde_json="1"\nsha2="0.10"\n')
        subprocess.run(["cargo", "build", "--offline", "--release", "--manifest-path",
                        str(root / "Cargo.toml")], check=True)
        with (root / "snapshots").open("wb") as out, (root / "timings").open("wb") as err:
            subprocess.run([str(root / "target/release/procstats-recording-probe"),
                            str(args.samples), str(args.interval)], stdout=out, stderr=err, check=True)
        rows = [json.loads(x) for x in (root / "snapshots").read_text().splitlines()]
        timings = [json.loads(x) for x in (root / "timings").read_text().splitlines()]
        observed_interval = ((rows[-1]["scan_start_ns"] - rows[0]["scan_start_ns"])
                             / (len(rows)-1) / 1e9) if len(rows) > 1 else None
        overruns = sum(row["scan_end_ns"] > (row["seq"]+1)*args.interval*1e9 for row in rows)
        print(json.dumps({"type":"sampling", "frames":len(rows), "interval_s":args.interval,
            "observed_interval_s":observed_interval,"scan_deadline_overruns":overruns,
            "processes_min":min(x["processes"] for x in timings),
            "processes_max":max(x["processes"] for x in timings),
            "scan_avg_ms":statistics.mean(x["scan_ns"] for x in timings)/1e6,
            "scan_max_ms":max(x["scan_ns"] for x in timings)/1e6,
            "encode_avg_ms":statistics.mean(x["encode_ns"] for x in timings)/1e6,
            "raw_bytes":sum(x["bytes"] for x in timings)}), flush=True)
        codecs = [("zstd-1", ["zstd","-q","-1","-c"], ["zstd","-q","-d","-c"]),
                  ("zstd-3", ["zstd","-q","-3","-c"], ["zstd","-q","-d","-c"]),
                  ("brotli-4", ["brotli","-q","4","-c"], ["brotli","-d","-c"])]
        for chunk_frames in sorted({1, min(10,len(rows)), len(rows)}):
            for layout in ["full", "dictionary-arrays"]:
                for codec, encoder, decoder in codecs:
                    raw, compressed = measure(rows, chunk_frames, layout, encoder, decoder)
                    print(json.dumps({"type":"compression", "layout":layout,"codec":codec,
                        "chunk_frames":chunk_frames,"raw_bytes":raw,"compressed_bytes":compressed,
                        "ratio":raw/compressed,"projected_MiB_per_day_at_requested_interval":
                        compressed/len(rows)/args.interval*86400/1024**2,
                        "projected_MiB_per_day_at_observed_interval":
                        compressed/len(rows)/observed_interval*86400/1024**2
                        if observed_interval else None}), flush=True)


if __name__ == "__main__":
    main()
