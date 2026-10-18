#!/usr/bin/env python3
"""Diagnostic macOS tuple snapshots/compression; not a production recorder.

Requires cached Cargo dependencies, zstd and brotli. Native reads recheck process
identity but still have partial-visibility and non-atomic-scan limitations.
"""
import argparse
import contextlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid

STATUS_INTERVAL = 10.0
MAX_NATIVE_ROW_BYTES = 16 * 1024 * 1024
DEFAULT_MAX_CAPTURE_BYTES = 24 * 1024**3
DEFAULT_MIN_FREE_BYTES = 20 * 1024**3


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
    if timings_path is not None and Path(timings_path).exists():
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


@contextlib.contextmanager
def _native_build(capture):
    """Build the same embedded sampler once and share it across capture modes."""
    project = Path(__file__).resolve().parent
    source = project / "src/main.rs"
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
    with tempfile.TemporaryDirectory(prefix="procstats-probe-") as directory:
        root = Path(directory)
        (root / "src").mkdir()
        (root / "src/main.rs").write_text(rust)
        (root / "Cargo.toml").write_text(
            '[package]\nname="procstats-recording-probe"\nversion="0.0.0"\nedition="2024"\n'
            '[dependencies]\nlibc="0.2"\nserde_json="1"\nsha2="0.10"\n'
            f'herdr-pane-load={{path={json.dumps(str(project))}}}\n'
        )
        subprocess.run(["cargo", "build", "--offline", "--release", "--manifest-path",
                        str(root / "Cargo.toml")], check=True,
                       stdout=subprocess.DEVNULL if capture else None)
        yield root / "target/release/procstats-recording-probe"


def _exclusive(path, flags=os.O_WRONLY):
    return os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)


def _capture_segmented(samples, interval, directory, segment_samples, max_bytes, min_free):
    hz = 1 / interval
    if not math.isfinite(hz) or abs(hz - round(hz)) > 1e-9:
        raise ValueError("capture mode requires an integer Hz")
    directory = Path(directory)
    os.mkdir(directory, 0o700)
    os.chmod(directory, 0o700)
    run_id = str(uuid.uuid4())
    timing_path = directory / "native-timings.jsonl"
    manifest_path = directory / "segments.jsonl"
    timing_fd = _exclusive(timing_path)
    try:
        manifest_fd = _exclusive(manifest_path)
    except BaseException:
        os.close(timing_fd)
        raise
    count = segments = source_done = 0
    current = None
    native = compressor = None
    interrupted = budget = False
    failed = None
    native_pid = None
    unindexed_artifact = None
    shutdown_timer = None
    old_handler = signal.getsignal(signal.SIGTERM)

    def force_stop():
        # Killing a stuck compressor also unblocks a pending pipe write.
        for child in (native, compressor):
            if child is not None and child.poll() is None:
                try:
                    child.kill()
                except ProcessLookupError:
                    pass

    def handle_sigterm(*_):
        nonlocal interrupted, shutdown_timer
        interrupted = True
        if native is None and current is None and compressor is None:
            raise SystemExit(143)  # Also unwind an interrupted build.
        if shutdown_timer is None:
            shutdown_timer = threading.Timer(5, force_stop)
            shutdown_timer.daemon = True
            shutdown_timer.start()
        if native is not None and native.poll() is None:
            try:
                native.terminate()
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGTERM, handle_sigterm)

    def sizes():
        src = source_done + (os.fstat(current["file"].fileno()).st_size
                             if current and not current["file"].closed else 0)
        return src, os.fstat(timing_fd).st_size

    def status(value):
        src, timings = sizes()
        data = {"pid": os.getpid(), "native_pid": native_pid, "status": value,
                "requested_samples": samples, "actual_samples": count, "segments": segments,
                "source_bytes": src, "timings_bytes": timings,
                "unindexed_artifact": unindexed_artifact}
        temp = directory / (".status-" + uuid.uuid4().hex)
        fd = _exclusive(temp)
        try:
            with os.fdopen(fd, "wb") as out:
                out.write((json.dumps(data, separators=(",", ":")) + "\n").encode())
                out.flush(); os.fsync(out.fileno())
            os.replace(temp, directory / "status.json")
        finally:
            if temp.exists(): temp.unlink()

    def manifest(record):
        data = (json.dumps(record, separators=(",", ":")) + "\n").encode()
        view = memoryview(data)
        while view:
            view = view[os.write(manifest_fd, view):]

    def write_source(data):
        view = memoryview(data)
        while view:
            written = compressor.stdin.write(view)
            if not written:
                raise BrokenPipeError('compressor stopped accepting source bytes')
            view = view[written:]

    def begin_segment():
        nonlocal current, compressor, segments, unindexed_artifact
        index = segments
        requested = min(segment_samples, samples - count)
        partial = directory / (f"source-{index:06d}.jsonl.zst.partial")
        fd = _exclusive(partial)
        output = os.fdopen(fd, "wb", buffering=0)
        unindexed_artifact = partial.name
        current = {"index": index, "requested": requested, "count": 0, "first_seq": None,
                   "last_seq": None, "first_time": None, "last_time": None,
                   "partial": partial, "file": output}
        try:
            compressor = subprocess.Popen(['zstd', '-q', '--single-thread', '-3', '-c'],
                                          stdin=subprocess.PIPE, stdout=output, bufsize=0)
            header = {"probe_capture": 1, "hz": round(hz), "seconds": requested * interval,
                      "workload": {"pid": None, "events": []}, "requested_samples": requested,
                      "requested_samples_this_segment": requested, "total_requested_samples": samples,
                      "capture_run_id": run_id, "segment_index": index}
            write_source((json.dumps(header, separators=(',', ':')) + '\n').encode())
        except BaseException:
            child = compressor
            if child is not None:
                try:
                    child.stdin.close()
                except (BrokenPipeError, OSError):
                    pass
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            compressor = None
            output.close()
            current = None
            raise

    def finish_segment(complete):
        nonlocal current, compressor, source_done, segments, unindexed_artifact
        if current is None:
            return
        item, child = current, compressor
        current = None  # Finalization must never be retried after a partial failure.
        artifact = item['partial']
        try:
            child.stdin.close()  # Unbuffered: no potentially blocking flush here.
            try:
                rc = child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
                raise RuntimeError('compressor did not finish within shutdown grace')
            ok = rc == 0
            item['file'].flush()
            os.fsync(item['file'].fileno())
            item['file'].close()
            if ok:
                final = artifact.with_suffix('')
                if final.exists():
                    raise FileExistsError(final)
                os.replace(artifact, final)
                artifact = final
                unindexed_artifact = artifact.name
            manifest({'path': artifact.name, 'segment_index': item['index'],
                      'count': item['count'], 'requested_samples': item['requested'],
                      'seq_range': [item['first_seq'], item['last_seq']],
                      'time_range_ns': [item['first_time'], item['last_time']],
                      'complete': bool(complete and ok), 'capture_run_id': run_id})
            segments += 1
            unindexed_artifact = None
            if not ok:
                raise subprocess.CalledProcessError(rc or 1, 'zstd')
        finally:
            try:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
            finally:
                compressor = None
                item['file'].close()
                if artifact.exists():
                    source_done += artifact.stat().st_size

    def consume(line):
        nonlocal count
        if len(line) > MAX_NATIVE_ROW_BYTES or not line.endswith(b"\n"):
            raise ValueError("native row exceeds limit or is not newline-terminated")
        row = json.loads(line)
        if current is None:
            begin_segment()
        item = current
        write_source(line)
        seq, stamp = row["seq"], row["scan_start_ns"]
        item["first_seq"] = seq if item["first_seq"] is None else item["first_seq"]
        item["last_seq"] = seq
        item["first_time"] = stamp if item["first_time"] is None else item["first_time"]
        item["last_time"] = stamp
        item["count"] += 1
        count += 1
        if item["count"] == item["requested"]:
            finish_segment(True)

    try:
        # Persist initial status/manifest before building or spawning children.
        status("starting")
        usage = shutil.disk_usage(directory)
        if usage.free < min_free:
            budget = True
        if not budget:
            with _native_build(True) as executable:
                status("starting")
                native = subprocess.Popen([str(executable), str(samples), str(interval)],
                                          stdout=subprocess.PIPE, stderr=timing_fd)
                native_pid = native.pid
                status("running")
                next_check = time.monotonic() + STATUS_INTERVAL
                while True:
                    line = native.stdout.readline(MAX_NATIVE_ROW_BYTES + 1)
                    if not line:
                        break
                    consume(line)
                    now = time.monotonic()
                    if now >= next_check or current is None:
                        status("running")
                        usage = shutil.disk_usage(directory)
                        src, timing_size = sizes()
                        if src + timing_size >= max_bytes or usage.free < min_free:
                            budget = True
                            if native.poll() is None: native.terminate()
                        next_check = now + STATUS_INTERVAL
                    if budget and native.poll() is None:
                        # Keep draining bytes already emitted before termination.
                        native.terminate()
                if native.poll() is None and (interrupted or budget):
                    native.terminate()
                rc = native.wait()
                native.stdout.close()
                native = None
                if current is not None:
                    finish_segment(False if (interrupted or budget or rc) else
                                   current["count"] == current["requested"])
                if rc and not (interrupted or budget):
                    raise subprocess.CalledProcessError(rc, str(executable))
                if count != samples and not (interrupted or budget):
                    raise RuntimeError(f"native sampler ended after {count} of {samples} samples")
    except BaseException as error:
        failed = None if interrupted and isinstance(error, SystemExit) and error.code == 143 else error
        if native is not None:
            if native.poll() is None:
                native.terminate()
                try: native.wait(timeout=5)
                except subprocess.TimeoutExpired: native.kill(); native.wait()
            if native.stdout: native.stdout.close()
            native = None
        if current is not None:
            try: finish_segment(False)
            except BaseException as finish_error:
                if failed is None: failed = finish_error
    finally:
        if shutdown_timer is not None:
            shutdown_timer.cancel()
        signal.signal(signal.SIGTERM, old_handler)
        final_status = "failed" if failed else "stopped-budget" if budget else "interrupted" if interrupted else "complete"
        try:
            status(final_status)
        except BaseException as status_error:
            if failed is None:
                failed = status_error
                final_status = "failed"
        src, timing_size = sizes()
        os.close(timing_fd)
        os.close(manifest_fd)

    result = {"type": "sampling", "status": final_status, "requested_samples": samples,
              "actual_samples": count, "segments": segments, "capture_run_id": run_id,
              "source_bytes": src, "timings_bytes": timing_size, "native_pid": native_pid}
    if failed:
        raise failed
    return result


def collect_rows(samples, interval, workload_code=None, capture_out=None, capture_dir=None,
                 segment_samples=6000, max_capture_bytes=DEFAULT_MAX_CAPTURE_BYTES,
                 min_free_bytes=DEFAULT_MIN_FREE_BYTES):
    """Acquire rows, or capture exclusive JSONL / bounded compressed diagnostic segments."""
    if type(samples) is not int or samples < 1 or not math.isfinite(interval) or interval <= 0:
        raise ValueError("samples and finite interval must be positive")
    if capture_dir is not None:
        if capture_out is not None: raise ValueError("choose only one capture destination")
        if workload_code is not None: raise ValueError("capture mode does not support a controlled workload")
        if any(type(value) is not int or value < 1 for value in
               (samples, segment_samples, max_capture_bytes, min_free_bytes)):
            raise ValueError("capture limits must be positive integers")
        return _capture_segmented(samples, interval, capture_dir, segment_samples,
                                  max_capture_bytes, min_free_bytes)
    capture = capture_out is not None
    if capture and workload_code is not None:
        raise ValueError("capture mode does not support a controlled workload")
    hz = 1 / interval
    if capture and (not math.isfinite(hz) or abs(hz-round(hz)) > 1e-9):
        raise ValueError("capture mode requires an integer Hz")
    output = timing_path = None
    succeeded = header_written = False
    try:
        if capture:
            fd = os.open(capture_out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                output = os.fdopen(fd, 'wb')
            except BaseException:
                os.close(fd)
                raise
            output.write((json.dumps({'probe_capture': 1, 'hz': round(hz), 'seconds': samples*interval,
                'workload': {'pid': None, 'events': []}, 'requested_samples': samples},
                separators=(',', ':')) + '\n').encode())
            output.flush()
            header_written = True
            timing_fd, timing_name = tempfile.mkstemp(prefix='procstats-probe-timings-')
            os.close(timing_fd)
            timing_path = Path(timing_name)
        with _native_build(capture) as executable:
            if capture:
                with tempfile.TemporaryDirectory(prefix="procstats-probe-") as directory:
                    with timing_path.open("wb") as err:
                        child = subprocess.Popen([str(executable), str(samples), str(interval)],
                                                 stdout=output, stderr=err)
                        try: rc = child.wait()
                        finally:
                            if child.poll() is None:
                                child.terminate()
                                try: child.wait(timeout=5)
                                except subprocess.TimeoutExpired: child.kill(); child.wait()
                    if rc: raise subprocess.CalledProcessError(rc, child.args)
                    succeeded = True
                    return _summarize_capture(capture_out, timing_path, samples, interval, True)
            else:
                with tempfile.TemporaryDirectory(prefix="procstats-probe-") as directory:
                    root = Path(directory)
                    with (root/"snapshots").open("wb") as out, (root/"timings").open("wb") as err, (root/"workload").open("wb") as log:
                        worker = subprocess.Popen([sys.executable,"-c",workload_code],stdout=log,stderr=log) if workload_code else None
                        try: subprocess.run([str(executable),str(samples),str(interval)],stdout=out,stderr=err,check=True)
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
            try:
                if output is not None:
                    output.close()
                if header_written:
                    summary = _summarize_capture(capture_out, timing_path, samples, interval, succeeded)
                    if summary['status'] != 'complete':
                        print(json.dumps(summary), file=sys.stderr, flush=True)
            finally:
                if timing_path is not None:
                    timing_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--interval", type=float, default=1.0)
    destination = parser.add_mutually_exclusive_group()
    destination.add_argument("--capture-out", type=Path)
    destination.add_argument("--capture-dir", type=Path)
    parser.add_argument("--segment-samples", type=int, default=6000)
    parser.add_argument("--max-capture-bytes", type=int, default=DEFAULT_MAX_CAPTURE_BYTES)
    parser.add_argument("--min-free-bytes", type=int, default=DEFAULT_MIN_FREE_BYTES)
    args = parser.parse_args()
    if args.samples < 1 or not math.isfinite(args.interval) or args.interval <= 0:
        parser.error("samples and finite interval must be positive")
    if min(args.segment_samples, args.max_capture_bytes, args.min_free_bytes) < 1:
        parser.error("capture limits must be positive")
    if args.capture_out and (not math.isfinite(1 / args.interval) or abs(1/args.interval-round(1/args.interval)) > 1e-9):
        parser.error("--capture-out requires an integer Hz")
    if args.capture_dir and (not math.isfinite(1 / args.interval) or abs(1/args.interval-round(1/args.interval)) > 1e-9):
        parser.error("--capture-dir requires an integer Hz")
    private_run()
    if args.capture_out or args.capture_dir:
        try:
            if args.capture_dir:
                summary=collect_rows(args.samples,args.interval,capture_dir=args.capture_dir,
                    segment_samples=args.segment_samples,max_capture_bytes=args.max_capture_bytes,
                    min_free_bytes=args.min_free_bytes)
            else:
                summary=collect_rows(args.samples,args.interval,capture_out=args.capture_out)
        except SystemExit:
            raise
        except Exception as error:
            print(f"capture failed: {error}",file=sys.stderr,flush=True)
            return 1
        print(json.dumps(summary),flush=True)
        if summary["status"] == "interrupted": return 143
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
