#!/usr/bin/env python3
"""Prepare private encoding blocks; audit state grows with distinct identities."""
import argparse
from contextlib import contextmanager
from collections import Counter, defaultdict
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from recording_codec import _read_uvarint, _uvarint, canonical_row, encode_sparse, decode_sparse
from recording_cpu_shared import decode_shared, encode_shared
from recording_structure import decode_structure, encode_structure

MAGIC = b"PST1"
CPU_TIMEBASE = (125, 3)
CPU_QUANTUM = 24_000                 # 1ms in native Mach ticks
PAGE = 4096
MAX_POINTS = 1_000_000


def restore_native(ns, numer=125, denom=3):
    if isinstance(ns, bool) or not isinstance(ns, int) or ns < 0:
        raise ValueError("invalid normalized CPU counter")
    ticks = (ns * denom + numer - 1) // numer
    if ticks * numer // denom != ns:
        raise ValueError("CPU counter is not an exact normalized Mach value")
    return ticks


@contextmanager
def _source_stream(path):
    path = Path(path)
    if path.suffix != '.zst':
        with path.open('rb') as stream:
            yield stream
        return
    with tempfile.TemporaryFile() as errors:
        child = subprocess.Popen(['zstd', '-q', '-d', '-c', '--', str(path)],
                                 stdout=subprocess.PIPE, stderr=errors)
        try:
            yield child.stdout
            if child.wait():
                errors.seek(0)
                raise ValueError('source decompression failed: ' + errors.read(4096).decode(errors='replace'))
        finally:
            child.stdout.close()
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()


def _rows(path, digest=None):
    with _source_stream(path) as source:
        line = source.readline()
        if digest is not None:
            digest.update(line)
        try:
            header = json.loads(line)
        except (ValueError, TypeError) as exc:
            raise ValueError("invalid capture header") from exc
        if not isinstance(header, dict) or header.get("probe_capture") != 1:
            raise ValueError("not a diagnostic capture")
        hz = header.get("hz")
        if isinstance(hz, bool) or not isinstance(hz, int) or hz < 1:
            raise ValueError("capture header requires positive integer hz")
        yield header, None
        for line in source:
            if digest is not None:
                digest.update(line)
            try:
                yield header, canonical_row(json.loads(line))
            except (ValueError, TypeError, KeyError) as exc:
                raise ValueError("invalid capture row") from exc


def _preflight(path):
    digest, previous, page_aligned = hashlib.sha256(), {}, True
    first = last = previous_seq = previous_stamp = None
    rows = points = 0
    for header, row in _rows(path, digest):
        if row is None:
            continue
        if row["seq"] < 0 or row["scan_start_ns"] < 0:
            raise ValueError("sequence and scan timestamp must be nonnegative")
        if previous_seq is not None and (row["seq"] <= previous_seq or
                                         row["scan_start_ns"] <= previous_stamp):
            raise ValueError("sequence and scan timestamps must increase")
        previous_seq, previous_stamp = row["seq"], row["scan_start_ns"]
        first = row if first is None else first
        last = row
        rows += 1
        points += len(row["processes"])
        for p in row["processes"]:
            identity = (p[0], p[2], p[3])
            user, system = restore_native(p[5]), restore_native(p[6])
            old = previous.get(identity)
            if old is not None and (p[5] < old[0] or p[6] < old[1] or
                                    user < old[2] or system < old[3]):
                raise ValueError("CPU component counter reset")
            previous[identity] = (p[5], p[6], user, system)
            page_aligned &= p[7] % PAGE == 0
    if not rows:
        raise ValueError("capture has no observations")
    return {"header": header, "sha256": digest.hexdigest(), "first": first,
            "last": last, "rows": rows, "points": points,
            "rss_unit": PAGE if page_aligned else 1}


def _rss_value(rss, scheme, unit):
    if scheme == "relative10":
        pages = rss // PAGE
        step = 1 << max(0, pages.bit_length() - 10)
        q = pages // step * step
        return q, q * PAGE
    q = rss // unit
    return q, q * unit


def pack_block(header, cpu, metadata):
    h = json.dumps(header, sort_keys=True, separators=(",", ":")).encode()
    return MAGIC + _uvarint(len(h)) + h + _uvarint(len(cpu)) + cpu + _uvarint(len(metadata)) + metadata


def unpack_block(data):
    if not isinstance(data, (bytes, bytearray, memoryview)) or bytes(data[:4]) != MAGIC:
        raise ValueError("invalid PST1 envelope")
    data, offset = bytes(data), 4
    values = []
    for _ in range(3):
        n, offset = _read_uvarint(data, offset)
        if n > len(data) - offset:
            raise ValueError("truncated PST1 section")
        values.append(data[offset:offset+n]); offset += n
    if offset != len(data):
        raise ValueError("trailing PST1 bytes")
    try:
        header = json.loads(values[0])
    except ValueError as exc:
        raise ValueError("invalid PST1 JSON header") from exc
    if not isinstance(header, dict):
        raise ValueError("invalid PST1 JSON header")
    return header, values[1], values[2]


def _private_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write(data)


def prepare(input_path, output_dir, rss="exact", layout="mask"):
    if rss not in ("exact", "64k", "256k", "1m", "relative10"):
        raise ValueError("unknown RSS scheme")
    if layout not in ("mask", "columns"):
        raise ValueError("unknown metadata layout")
    source = _preflight(input_path)
    if rss == 'relative10' and source['rss_unit'] != PAGE:
        raise ValueError('relative10 requires page-aligned source RSS')
    unit = source["rss_unit"] if rss == "exact" else {
        "64k": 65536, "256k": 262144, "1m": 1048576,
        "relative10": PAGE}.get(rss, PAGE)
    output_dir = Path(output_dir)
    os.mkdir(output_dir, 0o700)  # exclusive; never overwrite a prior run
    os.chmod(output_dir, 0o700)
    try:
        hz = source["header"]["hz"]
        max_frames = min(MAX_POINTS, max(1, hz * 30))
        blocks, audit = [], _new_audit()
        digest = hashlib.sha256()
        chunk, chunk_points, ordinal = [], 0, 0
        rss_stats = {"sample_count": 0, "changed_sample_count": 0,
                     "max_absolute_error_bytes": 0, "max_relative_error": 0.0}
        def emit():
            nonlocal chunk, chunk_points
            if not chunk:
                return
            blocks.append(_encode_block(chunk, len(blocks), output_dir, layout, rss,
                                        unit, rss_stats))
            chunk, chunk_points = [], 0

        for header, row in _rows(input_path, digest):
            if row is None:
                continue
            if chunk and (len(chunk) >= max_frames or
                          chunk_points + len(row["processes"]) > MAX_POINTS):
                emit()
            if len(row["processes"]) > MAX_POINTS:
                raise ValueError("single observation exceeds point limit")
            chunk.append(row)
            chunk_points += len(row["processes"])
            _audit_row(audit, row, ordinal, rss, unit)
            ordinal += 1
        emit()
        if digest.hexdigest() != source["sha256"]:
            raise ValueError("input changed during preparation")
        _finish_audit(audit)
        first, last = source["first"], source["last"]
        manifest = {
            "schema": "recording-storage-manifest-v1", "input_sha256": source["sha256"],
            "source": {"observations": source["rows"], "points": source["points"],
                       "first_seq": first["seq"], "last_seq": last["seq"],
                       "first_scan_start_ns": first["scan_start_ns"],
                       "last_scan_start_ns": last["scan_start_ns"],
                       "duration_ns": last["scan_start_ns"] - first["scan_start_ns"],
                       'nominal_hz': hz,
                       'capture_run_id': source['header'].get('capture_run_id'),
                       'segment_index': source['header'].get('segment_index')},
            "cpu": {"unit": "native Mach ticks", "timebase_mach": [125, 3],
                    "quantum_native_ticks": CPU_QUANTUM, "quantum_ns": 1_000_000,
                    "time_exact": True, "cpu_exact": False,
                    "interior_error": "0 <= source-decoded < 1ms; per-block endpoints exact",
                    "component_split": False},
            "rss": {"scheme": rss, "unit_bytes": unit,
                    "unit_note": "relative10 stores page counts rounded by per-sample top-10-bit step"
                    if rss == "relative10" else "decoded RSS = stored integer * unit_bytes",
                    **rss_stats},
            "layout": layout, "audit": audit, "blocks": blocks}
        _private_write(output_dir / "manifest.json",
                       (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode())
        return manifest
    except BaseException:
        shutil.rmtree(output_dir)
        raise


def _encode_block(rows, index, root, layout, scheme, unit, stats):
    source_cpu, metadata_rows = defaultdict(list), []
    point_count = 0
    for row in rows:
        metadata = {k: row[k] for k in ("seq", "wall_start_ns", "scan_start_ns", "scan_end_ns")}
        processes = []
        for p in row["processes"]:
            identity = (p[0], p[2], p[3])
            cpu = restore_native(p[5]) + restore_native(p[6])
            source_cpu[identity].append((row["seq"], cpu, row["scan_start_ns"]))
            q, quantized = _rss_value(p[7], scheme, unit)
            error = p[7] - quantized
            stats["sample_count"] += 1
            stats["changed_sample_count"] += error != 0
            stats["max_absolute_error_bytes"] = max(stats["max_absolute_error_bytes"], error)
            if p[7]:
                stats["max_relative_error"] = max(stats["max_relative_error"], error / p[7])
            processes.append([p[0], p[1], p[2], p[3], p[4], 0, 0, q])
            point_count += 1
        metadata["processes"] = processes
        metadata_rows.append(metadata)
    cpu_blob = encode_shared(source_cpu, layout="changes", quantum=CPU_QUANTUM,
                             clock_unit_ns=1, cpu_timebase=CPU_TIMEBASE)
    encode_meta = encode_structure if layout == 'columns' else encode_sparse
    decode_meta = decode_structure if layout == 'columns' else decode_sparse
    meta_blob = encode_meta(metadata_rows)
    header = {"schema": "recording-storage-block-v1", "layout": layout,
              "rss_scheme": scheme, "rss_unit_bytes": unit,
              "cpu_quantum_native_ticks": CPU_QUANTUM,
              "cpu_timebase_mach": [125, 3], "timestamp_unit_ns": 1,
              "all_observations_kept": True}
    packed = pack_block(header, cpu_blob, meta_blob)
    unpacked_header, unpacked_cpu, unpacked_meta = unpack_block(packed)
    if unpacked_header != header:
        raise ValueError("block envelope header verification failed")
    actual_cpu = decode_shared(unpacked_cpu)
    if actual_cpu.keys() != source_cpu.keys():
        raise ValueError("CPU identity coverage verification failed")
    for identity, samples in source_cpu.items():
        actual = actual_cpu[identity]
        if len(actual) != len(samples):
            raise ValueError("CPU point coverage verification failed")
        for i, (expected, got) in enumerate(zip(samples, actual)):
            if expected[0] != got[0] or expected[2] != got[2]:
                raise ValueError("CPU clock verification failed")
            error = expected[1] - got[1]
            if (i in (0, len(samples)-1) and error != 0) or (0 < i < len(samples)-1 and
                                                               not 0 <= error < CPU_QUANTUM):
                raise ValueError("CPU precision verification failed")
    expected_meta = [{**{k: r[k] for k in ("seq", "wall_start_ns", "scan_start_ns", "scan_end_ns")},
                      "processes": r["processes"]} for r in metadata_rows]
    if decode_meta(unpacked_meta) != expected_meta:
        raise ValueError("metadata roundtrip verification failed")
    name = f"block-{index:04d}.pst"
    _private_write(root / name, packed)
    return {"path": name, "sha256": hashlib.sha256(packed).hexdigest(),
            "row_count": len(rows), "seq_range": [rows[0]["seq"], rows[-1]["seq"]],
            "time_range_ns": [rows[0]["scan_start_ns"], rows[-1]["scan_start_ns"]],
            "raw_bytes": len(packed), "cpu_bytes": len(cpu_blob),
            "metadata_bytes": len(meta_blob), "point_count": point_count}


def _new_audit():
    return {"states": {}, "initial": [], "final": [], "ids_by_pid": defaultdict(set),
            "names": Counter(), "new_names": Counter(), "templates": Counter(),
            "name_changes": 0, "ppid_changes": 0, "returns": 0,
            "rss_changes": 0, "quantized_rss_changes": 0}


def _audit_row(audit, row, ordinal, scheme, unit):
    current = []
    if ordinal == 0:
        audit["initial"] = [(p[0], p[2], p[3]) for p in row["processes"]]
    for p in row["processes"]:
        identity = (p[0], p[2], p[3]); current.append(identity)
        audit["ids_by_pid"][p[0]].add(identity)
        audit["names"][p[4]] += 1
        audit["templates"][(p[1], p[4])] += 1
        state = audit["states"].get(identity)
        q, qbytes = _rss_value(p[7], scheme, unit)
        if state is None:
            if ordinal:
                audit['new_names'][p[4]] += 1
            state = audit["states"][identity] = {"count": 0, "runs": 0,
                "last": -2, "name": p[4], "ppid": p[1], "peak": 0, "qpeak": 0,
                "rss": p[7], "quantized_rss": qbytes}
        elif state['rss'] != p[7]:
            audit['rss_changes'] += 1
        if state['count'] and state['quantized_rss'] != qbytes:
            audit['quantized_rss_changes'] += 1
        if state["last"] != ordinal - 1:
            state["runs"] += 1
            if state["count"]:
                audit["returns"] += 1
        if state["count"] and state["name"] != p[4]: audit["name_changes"] += 1
        if state["count"] and state["ppid"] != p[1]: audit["ppid_changes"] += 1
        state.update(count=state["count"]+1, last=ordinal, name=p[4], ppid=p[1],
                     peak=max(state["peak"], p[7]), qpeak=max(state["qpeak"], qbytes),
                     rss=p[7], quantized_rss=qbytes)
    audit["final"] = current


def _finish_audit(a):
    states = a.pop("states")
    bins = Counter()
    for s in states.values():
        n = s["count"]
        label = "1" if n == 1 else "2-4" if n <= 4 else "5-16" if n <= 16 else "17-64" if n <= 64 else "65-256" if n <= 256 else "257+"
        bins[label] += 1
    first_pids = defaultdict(set); final_pids = defaultdict(set)
    for pid, start, usec in a["initial"]: first_pids[pid].add((pid, start, usec))
    for pid, start, usec in a["final"]: final_pids[pid].add((pid, start, usec))
    reused = sorted(pid for pid, ids in a["ids_by_pid"].items() if len(ids) > 1)
    initial = set(a['initial'])
    a.update({"rss_transition_count": a.pop('rss_changes'),
              "quantized_rss_transition_count": a.pop('quantized_rss_changes'),
              "new_identity_names": dict(a.pop('new_names')),
              "observation_run_count": sum(s['runs'] for s in states.values()),
              "disappearance_count": sum(s['runs'] for s in states.values()) - len(a['final']),
              "disappearance_semantics": "absent at next recorded scan; NOT a proven exit",
              "max_peak_underestimate_bytes": max((s['peak'] - s['qpeak'] for s in states.values()), default=0),
              "all_identity_count": len(states), "initial_observed_ids": [list(x) for x in a["initial"]],
              "final_observed_ids": [list(x) for x in a["final"]],
              "new_identity_count": sum(i not in initial for i in states),
              "pid_reuse_count": len(reused), "pid_reuse_pids": reused,
              "non_exit_return_count": a.pop("returns"),
              "name_change_count": a.pop("name_changes"),
              "ppid_change_count": a.pop("ppid_changes"),
              "observation_length_bins": dict(bins),
              "singleton_identities": bins["1"], "multi_observation_identities": len(states)-bins["1"],
              "name_counts": dict(a.pop("names")),
              "common_parent_name_templates": [{"ppid": key[0], "name": key[1], "count": n}
                                                for key, n in a.pop("templates").most_common(20)],
              "same_pid_first_last_different_identity_count": sum(
                  pid in first_pids and pid in final_pids and first_pids[pid] != final_pids[pid]
                  for pid in set(first_pids) | set(final_pids))})
    a.pop("initial"); a.pop("final"); a.pop("ids_by_pid")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--rss", choices=("exact", "64k", "256k", "1m", "relative10"), default="exact")
    parser.add_argument("--layout", choices=("mask", "columns"), default="mask")
    args = parser.parse_args(argv)
    try:
        result = prepare(args.input, args.output_dir, args.rss, args.layout)
    except (ValueError, OSError) as exc:
        parser.error(str(exc))
    print(json.dumps({"manifest": str(args.output_dir / "manifest.json"),
                      "input_sha256": result["input_sha256"], "blocks": len(result["blocks"])}))


if __name__ == "__main__":
    main()
