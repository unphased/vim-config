#!/usr/bin/env python3
"""Prepare a private, full-coverage review cache with declared CPU/RSS quantization."""
import argparse
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import resource
import shutil
import stat
import subprocess
import sys
import tempfile
import time

import recording_codec
import recording_cpu_shared
import recording_storage
import recording_structure

_rows = recording_storage._rows

DEFAULT_MAX_CACHE_BYTES = 8 * 1024 ** 3
DEFAULT_MIN_FREE_BYTES = 20 * 1024 ** 3
MAX_POINTS = recording_storage.MAX_POINTS
RSS_UNIT = 262144
POLICY = {
    "name": "observed-component-decrease-cut-v1",
    "layout": "mask",
    "rss_scheme": "256k",
    "rss_unit_bytes": RSS_UNIT,
    "cpu_quantum_native_ticks": recording_storage.CPU_QUANTUM,
    "cpu_timebase_mach": list(recording_storage.CPU_TIMEBASE),
    "component_decreases_cut_blocks": True,
    "interval_semantics": "CPU rate across affected interval unavailable; not proof of process restart",
}


class CountingDigest:
    """SHA-256 accumulator that also counts the exact decompressed JSONL bytes."""
    def __init__(self):
        self._hash = hashlib.sha256()
        self.bytes = 0

    def update(self, data):
        self._hash.update(data)
        self.bytes += len(data)

    def hexdigest(self):
        return self._hash.hexdigest()


def _sha256_file(path):
    digest = hashlib.sha256()
    size = 0
    with Path(path).open("rb") as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def _json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _write_private(path, data, *, replace=False):
    path = Path(path)
    if not replace:
        recording_storage._private_write(path, data)
        return
    fd, name = tempfile.mkstemp(prefix=".tmp-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise


def _write_json(path, value, *, replace=False):
    _write_private(path, _json_bytes(value), replace=replace)


def _read_json(path):
    with Path(path).open("r", encoding="utf-8") as source:
        return json.load(source)


def _integer(value, label, *, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"invalid {label}")
    return value


def _safe_relative(value, label):
    if (not isinstance(value, str) or not value or "\\" in value or "\0" in value or
            PurePosixPath(value).is_absolute() or PureWindowsPath(value).is_absolute() or
            PureWindowsPath(value).drive or ".." in PurePosixPath(value).parts):
        raise ValueError(f"unsafe {label}")
    return value


def _contained_file(root, relative, label):
    relative = _safe_relative(relative, label)
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing or symlinked {label}")
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise ValueError(f"{label} escapes capture root") from exc
    return path


def _load_capture(capture_root):
    root = Path(capture_root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("capture root must be a real directory")
    root = root.resolve()
    preservation_path = _contained_file(root, "PRESERVATION.json", "preservation manifest")
    run_path = _contained_file(root, "run.json", "run metadata")
    ledger_path = _contained_file(root, "source/segments.jsonl", "segment ledger")
    preservation = _read_json(preservation_path)
    run = _read_json(run_path)
    if not isinstance(preservation, dict) or not isinstance(run, dict):
        raise ValueError("invalid capture provenance metadata")
    run_id = preservation.get("capture_run_id")
    if (not isinstance(run_id, str) or not run_id or
            ("capture_run_id" in run and run["capture_run_id"] != run_id)):
        raise ValueError("capture run ID differs between preservation and run metadata")
    hz = _integer(run.get("hz"), "nominal hz", minimum=1)

    frozen = {}
    files = preservation.get("files")
    if not isinstance(files, list):
        raise ValueError("preservation file list is missing")
    for item in files:
        if not isinstance(item, dict):
            raise ValueError("invalid preservation file entry")
        relative = _safe_relative(item.get("path"), "preservation path")
        if relative in frozen:
            raise ValueError("duplicate preservation file path")
        size = _integer(item.get("bytes"), f"preserved byte count for {relative}")
        digest = item.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            raise ValueError(f"invalid preserved digest for {relative}")
        frozen[relative] = {"bytes": size, "sha256": digest}

    for relative, path in (("run.json", run_path), ("source/segments.jsonl", ledger_path)):
        expected = frozen.get(relative)
        if expected is None or _sha256_file(path) != (expected["bytes"], expected["sha256"]):
            raise ValueError(f"preserved provenance mismatch: {relative}")

    ledger = []
    with ledger_path.open("r", encoding="utf-8") as source:
        for line in source:
            if not line.strip():
                raise ValueError("blank line in segment ledger")
            try:
                item = json.loads(line)
            except ValueError as exc:
                raise ValueError("invalid segment ledger JSON") from exc
            if not isinstance(item, dict):
                raise ValueError("invalid segment ledger entry")
            ledger.append(item)
    if not ledger:
        raise ValueError("capture has no source segments")
    if (preservation.get("segments") != len(ledger) or
            preservation.get("actual_samples") != sum(_integer(x.get("count"), "segment count", minimum=1)
                                                        for x in ledger)):
        raise ValueError("preservation counts differ from source ledger")
    segments = []
    total_zstd_bytes = 0
    source_digests = []
    total_samples = 0
    previous_seq = previous_stamp = None
    actual_full_segments = 0
    for index, item in enumerate(ledger):
        name = item.get("path")
        name = _safe_relative(name, "segment path")
        if PurePosixPath(name).name != name or name in (".", ".."):
            raise ValueError("segment path must be a basename")
        if item.get("segment_index") != index or item.get("capture_run_id") != run_id:
            raise ValueError("segment index or capture run ID differs from ledger order")
        count = _integer(item.get("count"), "segment count", minimum=1)
        requested = _integer(item.get("requested_samples"), "requested segment samples", minimum=1)
        complete = item.get("complete")
        if type(complete) is not bool or complete != (count == requested):
            raise ValueError("segment complete flag does not match its sample count")
        if index < len(ledger) - 1 and not complete:
            raise ValueError("only the final segment may be partial")
        if count > requested:
            raise ValueError("segment exceeds requested sample count")
        seq_range, time_range = item.get("seq_range"), item.get("time_range_ns")
        if (not isinstance(seq_range, list) or len(seq_range) != 2 or
                not isinstance(time_range, list) or len(time_range) != 2):
            raise ValueError("invalid segment sequence/time range")
        seq_first, seq_last = (_integer(x, "segment sequence") for x in seq_range)
        time_first, time_last = (_integer(x, "segment timestamp") for x in time_range)
        if seq_last < seq_first or time_last < time_first or count > seq_last - seq_first + 1:
            raise ValueError("invalid segment coverage range")
        if previous_seq is not None and (seq_first <= previous_seq or time_first <= previous_stamp):
            raise ValueError("segment ledger coverage is not strictly increasing")
        source_path = _contained_file(root, f"source/{name}", "source segment")
        frozen_entry = frozen.get(f"source/{name}")
        if frozen_entry is None:
            raise ValueError("source segment is absent from preservation manifest")
        source_bytes, source_sha = _sha256_file(source_path)
        if (source_bytes, source_sha) != (frozen_entry["bytes"], frozen_entry["sha256"]):
            raise ValueError(f"preserved source digest mismatch: {name}")
        total_zstd_bytes += source_bytes
        source_digests.append(source_sha)
        total_samples += count
        actual_full_segments += complete
        previous_seq, previous_stamp = seq_last, time_last
        segments.append({"index": index, "name": name, "path": source_path,
                         "count": count, "requested_samples": requested,
                         "complete": complete, "seq_range": [seq_first, seq_last],
                         "time_range_ns": [time_first, time_last],
                         "source_bytes": source_bytes, "source_sha256": source_sha})
    expected_ranges = preservation.get("seq_range")
    if (not isinstance(expected_ranges, list) or len(expected_ranges) != 2 or
            expected_ranges != [segments[0]["seq_range"][0], segments[-1]["seq_range"][1]]):
        raise ValueError("preservation sequence range differs from segment ledger")
    if preservation.get("full_segments", actual_full_segments) != actual_full_segments:
        raise ValueError("preservation full-segment count differs from ledger")
    if preservation.get("last_segment_samples", segments[-1]["count"]) != segments[-1]["count"]:
        raise ValueError("preservation final-segment count differs from ledger")
    expected_zstd_bytes = preservation.get("source_zstd_bytes")
    if expected_zstd_bytes is not None and expected_zstd_bytes != total_zstd_bytes:
        raise ValueError("preservation compressed source byte total differs from ledger")

    ordered_digest = hashlib.sha256("\n".join(source_digests).encode()).hexdigest()
    provenance = {
        "capture_run_id": run_id, "nominal_hz": hz,
        "preservation_sha256": _sha256_file(preservation_path)[1],
        "run_sha256": frozen["run.json"]["sha256"],
        "ledger_sha256": frozen["source/segments.jsonl"]["sha256"],
        "segments": [{k: segment[k] for k in ("index", "name", "count", "requested_samples",
                      "complete", "seq_range", "time_range_ns", "source_bytes", "source_sha256")}
                     for segment in segments],
        "source_zstd_bytes": total_zstd_bytes,
        "source_digest_list_sha256": ordered_digest,
    }
    return {"root": root, "run_id": run_id, "hz": hz, "segments": segments,
            "total_samples": total_samples, "source_zstd_bytes": total_zstd_bytes,
            "input_sha256": ordered_digest, "provenance": provenance}


def _implementation_fingerprint():
    modules = (sys.modules[__name__], recording_storage, recording_codec,
               recording_cpu_shared, recording_structure)
    hashes = {}
    for module in modules:
        path = Path(module.__file__)
        hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    frozen = {"modules": hashes, "policy": POLICY}
    return hashlib.sha256(_json_bytes(frozen)).hexdigest()


def _ensure_private_directory(path, *, create=False):
    path = Path(path)
    if create:
        os.mkdir(path, 0o700)
        os.chmod(path, 0o700)
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"cache path is not a real directory: {path}")
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError(f"cache directory is not privately owned: {path}")
    return path


def _lock_cache(root):
    fd = os.open(root / ".lock", os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        _private_file(root / ".lock")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _private_file(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing or symlinked private cache file: {path}")
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError(f"cache file is not privately owned: {path}")


def _cache_bytes(root):
    total = 0
    for directory, subdirs, files in os.walk(root, followlinks=False):
        for name in subdirs:
            path = Path(directory) / name
            if path.is_symlink():
                raise ValueError("symlink in private cache")
        for name in files:
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                raise ValueError("non-file in private cache")
            total += path.stat().st_size
    return total


def _check_budget(root, max_cache_bytes, min_free_bytes):
    usage = _cache_bytes(root)
    if usage > max_cache_bytes:
        raise OSError(f"cache exceeds max_cache_bytes ({usage} > {max_cache_bytes})")
    free = shutil.disk_usage(root.parent).free
    if free < min_free_bytes:
        raise OSError(f"free space below min_free_bytes ({free} < {min_free_bytes})")
    return usage, free


def _rss_metrics():
    usage = resource.getrusage(resource.RUSAGE_SELF)
    peak = usage.ru_maxrss
    if sys.platform != "darwin":
        peak *= 1024
    return peak


def _progress_record(event, *, started, child_before, state_count, **extra):
    now = time.perf_counter()
    child = resource.getrusage(resource.RUSAGE_CHILDREN)
    self_usage = resource.getrusage(resource.RUSAGE_SELF)
    return {"event": event, "wall_seconds": now - started,
            "self_cpu_seconds": self_usage.ru_utime + self_usage.ru_stime,
            "child_cpu_seconds": (child.ru_utime - child_before.ru_utime) +
                                  (child.ru_stime - child_before.ru_stime),
            "peak_rss_bytes": _rss_metrics(), "state_count": state_count, **extra}


def _block_with_flags(path, events):
    if not events:
        return
    old = Path(path).read_bytes()
    header, cpu, metadata = recording_storage.unpack_block(old)
    if "cpu_component_discontinuities_before" in header:
        raise ValueError("block unexpectedly already contains discontinuity flags")
    updated = dict(header)
    updated["cpu_component_discontinuities_before"] = events
    packed = recording_storage.pack_block(updated, cpu, metadata)
    checked_header, checked_cpu, checked_metadata = recording_storage.unpack_block(packed)
    if (checked_header != updated or checked_cpu != cpu or checked_metadata != metadata or
            {k: v for k, v in checked_header.items() if k != "cpu_component_discontinuities_before"} != header):
        raise ValueError("flagged PST1 block roundtrip changed encoded sections")
    _write_private(path, packed, replace=True)


def _hash_record(path):
    size, digest = _sha256_file(path)
    return {"bytes": size, "sha256": digest}


def _read_boundary(path, expected_count, segment):
    _private_file(path)
    result = {}
    count = 0
    try:
        with gzip.open(path, "rt", encoding="utf-8") as source:
            for line in source:
                values = json.loads(line)
                if not isinstance(values, list) or len(values) != 7:
                    raise ValueError("invalid boundary state row")
                pid, start, usec, user, system, seq, stamp = values
                identity = tuple(_integer(x, "boundary identity") for x in (pid, start, usec))
                state = tuple(_integer(x, "boundary CPU state") for x in (user, system, seq, stamp))
                recording_storage.restore_native(user)
                recording_storage.restore_native(system)
                if identity in result or not (segment["seq_range"][0] <= seq <= segment["seq_range"][1] and
                                               segment["time_range_ns"][0] <= stamp <= segment["time_range_ns"][1]):
                    raise ValueError("boundary state is duplicate or outside shard coverage")
                result[identity] = state
                count += 1
    except (OSError, EOFError, json.JSONDecodeError) as exc:
        raise ValueError("invalid compressed boundary ledger") from exc
    if count != expected_count:
        raise ValueError("boundary state count differs from part manifest")
    return result


def _validate_part(root, index, segment, part_record):
    relative = part_record.get("path")
    if relative != f"parts/part-{index:06d}":
        raise ValueError("unsafe or out-of-order part path")
    part_dir = root / relative
    _ensure_private_directory(part_dir)
    part_manifest_path = part_dir / "part.json"
    _private_file(part_manifest_path)
    expected_manifest_sha = part_record.get("part_manifest_sha256")
    if _sha256_file(part_manifest_path)[1] != expected_manifest_sha:
        raise ValueError("part manifest digest mismatch")
    part = _read_json(part_manifest_path)
    if (part.get("segment_index") != index or
            part.get("source_sha256") != segment["source_sha256"] or
            part.get("source_bytes") != segment["source_bytes"] or
            part.get("source_json_sha256") != part_record.get("source_json_sha256") or
            part.get("source_json_bytes") != part_record.get("source_json_bytes") or
            part.get("row_count") != segment["count"] or
            part.get("seq_range") != segment["seq_range"] or
            part.get("time_range_ns") != segment["time_range_ns"]):
        raise ValueError("part manifest coverage/provenance mismatch")
    blocks = part.get("blocks")
    if not isinstance(blocks, list) or not blocks:
        raise ValueError("part has no blocks")
    rows = points = event_boundaries = event_count = 0
    previous_seq = previous_time = None
    root_blocks = []
    part_paths = set()
    for item in blocks:
        if not isinstance(item, dict):
            raise ValueError("invalid cached block record")
        name = item.get("path")
        name = _safe_relative(name, "block path")
        if PurePosixPath(name).name != name or name in part_paths:
            raise ValueError("unsafe or duplicate block path")
        part_paths.add(name)
        path = part_dir / name
        _private_file(path)
        blob = path.read_bytes()
        if len(blob) != item.get("raw_bytes") or hashlib.sha256(blob).hexdigest() != item.get("sha256"):
            raise ValueError("cached PST1 block digest mismatch")
        header, _cpu, _metadata = recording_storage.unpack_block(blob)
        flags = header.get("cpu_component_discontinuities_before", [])
        if flags:
            if not isinstance(flags, list):
                raise ValueError("invalid PST1 discontinuity flags")
            event_boundaries += 1
            event_count += len(flags)
        times, seqs = item.get("time_range_ns"), item.get("seq_range")
        if (not isinstance(times, list) or len(times) != 2 or
                not isinstance(seqs, list) or len(seqs) != 2 or
                (previous_time is not None and (times[0] <= previous_time or seqs[0] <= previous_seq))):
            raise ValueError("cached blocks have invalid or overlapping coverage")
        if (item.get("row_count", 0) < 1 or item.get("point_count", -1) < 0 or
                item.get("raw_bytes") != len(blob)):
            raise ValueError("invalid cached block coverage counters")
        rows += item["row_count"]
        points += item["point_count"]
        previous_time, previous_seq = times[1], seqs[1]
        root_item = dict(item)
        root_item["path"] = f"{relative}/{name}"
        root_blocks.append(root_item)
    if (rows != segment["count"] or blocks[0]["seq_range"][0] != segment["seq_range"][0] or
            blocks[-1]["seq_range"][1] != segment["seq_range"][1] or
            blocks[0]["time_range_ns"][0] != segment["time_range_ns"][0] or
            blocks[-1]["time_range_ns"][1] != segment["time_range_ns"][1]):
        raise ValueError("cached part blocks do not cover source ledger")

    event_file = part_dir / "events.jsonl"
    boundary_file = part_dir / "boundary.jsonl.gz"
    for auxiliary_name, record_name in (("events.jsonl", "events"),
                                         ("boundary.jsonl.gz", "boundary_ledger")):
        path = part_dir / auxiliary_name
        _private_file(path)
        record = part.get(record_name)
        if (not isinstance(record, dict) or
                {k: record.get(k) for k in ("bytes", "sha256")} != _hash_record(path)):
            raise ValueError(f"cached {record_name} digest mismatch")
    with event_file.open("r", encoding="utf-8") as source:
        event_lines = sum(1 for line in source if line.strip())
    if (event_lines != event_count or part.get("event_count") != event_count or
            part.get("event_boundary_count") != event_boundaries):
        raise ValueError("cached event diagnostics differ from flagged block headers")
    boundary = _read_boundary(boundary_file, part["boundary_ledger"]["identity_count"], segment)
    if part.get("boundary_ledger", {}).get("identity_count") != len(boundary):
        raise ValueError("cached boundary identity count mismatch")
    return {"manifest": part, "blocks": root_blocks, "boundary": boundary,
            "rss_stats": part.get("rss_stats", {}), "event_count": event_count,
            "event_boundary_count": event_boundaries}


def _restore_parts(root, capture, session, fingerprint):
    if session.get("schema") != "recording-review-session-v1":
        raise ValueError("unknown cache session schema")
    if session.get("implementation_fingerprint") != fingerprint:
        raise ValueError("resume rejected: implementation fingerprint changed")
    if session.get("policy") != POLICY or session.get("provenance") != capture["provenance"]:
        raise ValueError("resume rejected: capture provenance or review flags changed")
    recorded = session.get("completed_parts")
    if not isinstance(recorded, list) or len(recorded) > len(capture["segments"]):
        raise ValueError("invalid completed part checkpoint")
    parts_root = root / "parts"
    if parts_root.exists():
        _ensure_private_directory(parts_root)
    else:
        os.mkdir(parts_root, 0o700)
    all_blocks, segments, global_previous = [], [], {}
    rss_total = {"sample_count": 0, "changed_sample_count": 0,
                 "max_absolute_error_bytes": 0, "max_relative_error": 0.0}
    event_count = event_boundaries = json_bytes = points = 0
    for index, part_record in enumerate(recorded):
        checked = _validate_part(root, index, capture["segments"][index], part_record)
        all_blocks.extend(checked["blocks"])
        global_previous.update(checked["boundary"])
        part = checked["manifest"]
        segments.append({"segment_index": index, "path": capture["segments"][index]["name"],
                         "count": capture["segments"][index]["count"],
                         "requested_samples": capture["segments"][index]["requested_samples"],
                         "complete": capture["segments"][index]["complete"],
                         "seq_range": capture["segments"][index]["seq_range"],
                         "time_range_ns": capture["segments"][index]["time_range_ns"],
                         "source_sha256": part["source_sha256"],
                         "source_json_sha256": part["source_json_sha256"],
                         "source_json_bytes": part["source_json_bytes"]})
        event_count += checked["event_count"]
        event_boundaries += checked["event_boundary_count"]
        json_bytes += part["source_json_bytes"]
        points += part["point_count"]
        for key in ("sample_count", "changed_sample_count"):
            rss_total[key] += checked["rss_stats"].get(key, 0)
        rss_total["max_absolute_error_bytes"] = max(
            rss_total["max_absolute_error_bytes"], checked["rss_stats"].get("max_absolute_error_bytes", 0))
        rss_total["max_relative_error"] = max(
            rss_total["max_relative_error"], checked["rss_stats"].get("max_relative_error", 0.0))
    expected_names = {f"part-{index:06d}" for index in range(len(recorded))}
    for child in parts_root.iterdir():
        if child.name in expected_names:
            continue
        match = child.name.startswith("part-") and len(child.name) == 11 and child.name[5:].isdigit()
        index = int(child.name[5:]) if match else -1
        if not match or index < len(recorded) or index >= len(capture["segments"]):
            raise ValueError("unrecognized cache part path")
        _ensure_private_directory(child)
        shutil.rmtree(child)
    return {"blocks": all_blocks, "segments": segments, "previous": global_previous,
            "rss_stats": rss_total, "event_count": event_count,
            "event_boundaries": event_boundaries, "source_json_bytes": json_bytes,
            "points": points, "next_index": len(recorded), "parts_root": parts_root}


def _encode_part(capture, segment, output_root, parts_root, global_previous,
                 started, child_before, progress, max_cache_bytes, min_free_bytes,
                 rss_total):
    index = segment["index"]
    part_dir = parts_root / f"part-{index:06d}"
    os.mkdir(part_dir, 0o700)
    os.chmod(part_dir, 0o700)
    events_path = part_dir / "events.jsonl"
    fd = os.open(events_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    events_out = os.fdopen(fd, "wb")
    events_count = event_boundaries = raw_rows = point_count = 0
    first = last = None
    previous_seq = previous_stamp = None
    raw_digest = CountingDigest()
    chunk, chunk_points, block_index = [], 0, 0
    touched = set()
    part_stats = {"sample_count": 0, "changed_sample_count": 0,
                  "max_absolute_error_bytes": 0, "max_relative_error": 0.0}
    blocks = []
    pending_flags = []
    max_rows = min(MAX_POINTS, max(1, capture["hz"] * 30))

    def emit():
        nonlocal chunk, chunk_points, block_index, pending_flags
        if not chunk:
            return
        block = recording_storage._encode_block(chunk, block_index, part_dir, "mask", "256k",
                                                RSS_UNIT, part_stats)
        if pending_flags:
            block_path = part_dir / block["path"]
            _block_with_flags(block_path, pending_flags)
            blob = block_path.read_bytes()
            block["sha256"] = hashlib.sha256(blob).hexdigest()
            block["raw_bytes"] = len(blob)
        blocks.append(block)
        block_index += 1
        chunk, chunk_points, pending_flags = [], 0, []
        cache_bytes, _free = _check_budget(output_root, max_cache_bytes, min_free_bytes)
        if progress:
            progress(_progress_record("block", started=started, child_before=child_before,
                state_count=len(global_previous), segment_index=index,
                block_index=block_index - 1, row_count=block["row_count"],
                point_count=block["point_count"], cache_bytes=cache_bytes))

    try:
        with events_out:
            for header, row in _rows(segment["path"], raw_digest):
                if row is None:
                    if header.get("hz") != capture["hz"]:
                        raise ValueError("segment header hz differs from run metadata")
                    if header.get("capture_run_id") is not None and header["capture_run_id"] != capture["run_id"]:
                        raise ValueError("segment header capture run ID differs")
                    if header.get("segment_index") is not None and header["segment_index"] != index:
                        raise ValueError("segment header index differs from ledger")
                    for key in ("requested_samples", "requested_samples_this_segment"):
                        if key in header and header[key] != segment["requested_samples"]:
                            raise ValueError(f"segment header {key} differs from ledger")
                    continue
                if row["seq"] < 0 or row["scan_start_ns"] < 0:
                    raise ValueError("sequence and scan timestamp must be nonnegative")
                if previous_seq is not None and (row["seq"] <= previous_seq or
                                                row["scan_start_ns"] <= previous_stamp):
                    raise ValueError("sequence and scan timestamps must increase globally")
                if (previous_seq is None and row["seq"] != segment["seq_range"][0] or
                        row["scan_start_ns"] < segment["time_range_ns"][0]):
                    raise ValueError("source first observation differs from ledger coverage")
                if chunk and (len(chunk) >= max_rows or
                              chunk_points + len(row["processes"]) > MAX_POINTS):
                    emit()
                if len(row["processes"]) > MAX_POINTS:
                    raise ValueError("single observation exceeds point limit")
                row_events = []
                for process in row["processes"]:
                    identity = (process[0], process[2], process[3])
                    recording_storage.restore_native(process[5])
                    recording_storage.restore_native(process[6])
                    user, system = process[5], process[6]
                    old = global_previous.get(identity)
                    if old is not None:
                        old_user, old_system, old_seq, old_stamp = old
                        for name, before, now in (("user", old_user, user),
                                                  ("system", old_system, system)):
                            if now < before:
                                row_events.append({
                                    "identity": list(identity), "component": name,
                                    "current_name": process[4],
                                    "previous_seq": old_seq, "current_seq": row["seq"],
                                    "previous_scan_start_ns": old_stamp,
                                    "current_scan_start_ns": row["scan_start_ns"],
                                    "previous_user_ns": old_user, "current_user_ns": user,
                                    "previous_system_ns": old_system, "current_system_ns": system,
                                    "reason": "observed_component_decrease",
                                    "semantics": "CPU rate across affected interval unavailable; not proof of process restart",
                                })
                    global_previous[identity] = (user, system, row["seq"], row["scan_start_ns"])
                    touched.add(identity)
                if row_events:
                    emit()
                    pending_flags = row_events
                    event_boundaries += 1
                    events_count += len(row_events)
                    for event in row_events:
                        events_out.write(_json_bytes(event))
                if first is None:
                    first = row
                last = row
                raw_rows += 1
                point_count += len(row["processes"])
                chunk.append(row)
                chunk_points += len(row["processes"])
                previous_seq, previous_stamp = row["seq"], row["scan_start_ns"]
            emit()
            events_out.flush()
            os.fsync(events_out.fileno())
        if raw_rows != segment["count"] or first is None or last is None:
            raise ValueError("source observation count differs from ledger")
        if _sha256_file(segment["path"]) != (segment["source_bytes"], segment["source_sha256"]):
            raise ValueError("compressed source changed during review")
        if ([first["seq"], last["seq"]] != segment["seq_range"] or
                [first["scan_start_ns"], last["scan_start_ns"]] != segment["time_range_ns"]):
            raise ValueError("source sequence/time coverage differs from ledger")
        if raw_digest.bytes < 1:
            raise ValueError("empty source JSONL stream")

        boundary_path = part_dir / "boundary.jsonl.gz"
        with boundary_path.open("xb") as raw_file:
            os.chmod(boundary_path, 0o600)
            with gzip.GzipFile(fileobj=raw_file, mode="wb", compresslevel=1, mtime=0) as zipped:
                for identity in sorted(touched):
                    user, system, seq, stamp = global_previous[identity]
                    zipped.write(_json_bytes([*identity, user, system, seq, stamp]))
        part_record = {
            "schema": "recording-review-part-v1", "segment_index": index,
            "source_path": segment["name"], "source_sha256": segment["source_sha256"],
            "source_bytes": segment["source_bytes"], "source_json_sha256": raw_digest.hexdigest(),
            "source_json_bytes": raw_digest.bytes, "row_count": raw_rows,
            "point_count": point_count, "seq_range": segment["seq_range"],
            "time_range_ns": segment["time_range_ns"],
            "complete": segment["complete"], "requested_samples": segment["requested_samples"],
            "blocks": blocks, "events": _hash_record(events_path),
            "event_count": events_count, "event_boundary_count": event_boundaries,
            "boundary_ledger": {**_hash_record(boundary_path), "identity_count": len(touched)},
            "rss_stats": part_stats,
        }
        _check_budget(output_root, max_cache_bytes, min_free_bytes)
        _write_json(part_dir / "part.json", part_record)
        _check_budget(output_root, max_cache_bytes, min_free_bytes)
        part_sha = _sha256_file(part_dir / "part.json")[1]
        return {"path": f"parts/part-{index:06d}",
                "part_manifest_sha256": part_sha,
                "source_json_sha256": raw_digest.hexdigest(),
                "source_json_bytes": raw_digest.bytes,
                "row_count": raw_rows, "point_count": point_count,
                "event_count": events_count, "event_boundary_count": event_boundaries,
                "rss_stats": part_stats, "blocks": blocks,
                "boundary": _read_boundary(boundary_path, len(touched), segment),
                "complete": segment["complete"], "seq_range": segment["seq_range"],
                "time_range_ns": segment["time_range_ns"]}
    except BaseException:
        try:
            events_out.close()
        except BaseException:
            pass
        if part_dir.exists() and not part_dir.is_symlink():
            shutil.rmtree(part_dir)
        raise


def _new_root_manifest(capture, state):
    segments = capture["segments"]
    first = segments[0]["seq_range"][0]
    last = segments[-1]["seq_range"][1]
    first_stamp = segments[0]["time_range_ns"][0]
    last_stamp = segments[-1]["time_range_ns"][1]
    return {
        "schema": "recording-review-manifest-v1",
        "input_sha256": capture["input_sha256"],
        "input_sha256_kind": "sha256 of ordered compressed source-shard SHA256 digests; not expanded JSONL hash",
        "source": {"observations": capture["total_samples"], "points": state["points"],
                   "first_seq": first, "last_seq": last,
                   "first_scan_start_ns": first_stamp, "last_scan_start_ns": last_stamp,
                   "duration_ns": last_stamp - first_stamp,
                   "nominal_hz": capture["hz"], "capture_run_id": capture["run_id"]},
        "source_json_bytes": state["source_json_bytes"],
        "source_zstd_bytes": capture["source_zstd_bytes"],
        "cpu_component_discontinuity_count": state["event_count"],
        "cpu_component_discontinuity_boundary_count": state["event_boundaries"],
        "cpu_quality_semantics": POLICY["interval_semantics"],
        "cpu": {"unit": "native Mach ticks", "timebase_mach": list(recording_storage.CPU_TIMEBASE),
                "quantum_native_ticks": recording_storage.CPU_QUANTUM,
                "quantum_ns": 1_000_000, "time_exact": True, "cpu_exact": False,
                "interior_error": "0 <= source-decoded < 1ms; per-block endpoints exact",
                "component_split": False,
                "component_discontinuities": "observed decreases cut independent blocks; affected interval rates unavailable"},
        "rss": {"scheme": "256k", "unit_bytes": RSS_UNIT,
                "unit_note": "decoded RSS = stored integer * unit_bytes",
                **state["rss_stats"]},
        "layout": "mask", "parts": state["part_records"],
        "segments": state["segments"], "blocks": state["blocks"],
    }


def prepare_capture(capture_root, output_dir, *, resume=False, progress=None,
                    max_cache_bytes=DEFAULT_MAX_CACHE_BYTES,
                    min_free_bytes=DEFAULT_MIN_FREE_BYTES):
    """Validate and cache all preserved observations in independently decodable PST1 blocks."""
    _integer(max_cache_bytes, "max_cache_bytes", minimum=1)
    _integer(min_free_bytes, "min_free_bytes")
    capture = _load_capture(capture_root)
    output = Path(output_dir)
    if output.is_symlink():
        raise ValueError("output directory cannot be a symlink")
    try:
        output.resolve().relative_to(capture["root"])
        raise ValueError("output directory must not be inside immutable capture root")
    except ValueError as exc:
        if str(exc) == "output directory must not be inside immutable capture root":
            raise
    try:
        capture["root"].relative_to(output.resolve())
        raise ValueError("output directory must not contain immutable capture root")
    except ValueError as exc:
        if str(exc) == "output directory must not contain immutable capture root":
            raise
    output.parent.mkdir(parents=True, exist_ok=True)
    fingerprint = _implementation_fingerprint()
    started = time.perf_counter()
    child_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    lock_fd = None
    current_part = None
    try:
        if resume:
            _ensure_private_directory(output)
            lock_fd = _lock_cache(output)
            session_path = output / "session.json"
            _private_file(session_path)
            session = _read_json(session_path)
            if (session.get("implementation_fingerprint") != fingerprint or
                    session.get("provenance") != capture["provenance"] or
                    session.get("policy") != POLICY):
                raise ValueError("resume rejected: capture, implementation, or policy changed")
            state = _restore_parts(output, capture, session, fingerprint)
            part_records = session["completed_parts"][:]
            if (output / "manifest.json").exists() and len(part_records) != len(capture["segments"]):
                raise ValueError("final manifest exists before all parts are checkpointed")
        else:
            os.mkdir(output, 0o700)
            os.chmod(output, 0o700)
            lock_fd = _lock_cache(output)
            session = {"schema": "recording-review-session-v1",
                       "implementation_fingerprint": fingerprint,
                       "policy": POLICY, "provenance": capture["provenance"],
                       "completed_parts": []}
            _write_json(output / "session.json", session)
            parts_root = output / "parts"
            os.mkdir(parts_root, 0o700)
            os.chmod(parts_root, 0o700)
            state = {"blocks": [], "segments": [], "previous": {},
                     "rss_stats": {"sample_count": 0, "changed_sample_count": 0,
                                    "max_absolute_error_bytes": 0,
                                    "max_relative_error": 0.0},
                     "event_count": 0, "event_boundaries": 0,
                     "source_json_bytes": 0, "points": 0,
                     "next_index": 0, "parts_root": parts_root}
            part_records = []
        _check_budget(output, max_cache_bytes, min_free_bytes)
        for index in range(state["next_index"], len(capture["segments"])):
            segment = capture["segments"][index]
            current_part = output / "parts" / f"part-{index:06d}"
            result = _encode_part(capture, segment, output, output / "parts",
                                 state["previous"], started, child_before, progress,
                                 max_cache_bytes, min_free_bytes, state["rss_stats"])
            state["previous"].update(result["boundary"])
            state["blocks"].extend({**block, "path": f"{result['path']}/{block['path']}"}
                                   for block in result["blocks"])
            state["points"] += result["point_count"]
            state["source_json_bytes"] += result["source_json_bytes"]
            state["event_count"] += result["event_count"]
            state["event_boundaries"] += result["event_boundary_count"]
            for key in ("sample_count", "changed_sample_count"):
                state["rss_stats"][key] += result["rss_stats"][key]
            state["rss_stats"]["max_absolute_error_bytes"] = max(
                state["rss_stats"]["max_absolute_error_bytes"],
                result["rss_stats"]["max_absolute_error_bytes"])
            state["rss_stats"]["max_relative_error"] = max(
                state["rss_stats"]["max_relative_error"],
                result["rss_stats"]["max_relative_error"])
            segment_manifest = {"segment_index": index, "path": segment["name"],
                "count": segment["count"], "requested_samples": segment["requested_samples"],
                "complete": segment["complete"], "seq_range": segment["seq_range"],
                "time_range_ns": segment["time_range_ns"],
                "source_sha256": segment["source_sha256"],
                "source_json_sha256": result["source_json_sha256"],
                "source_json_bytes": result["source_json_bytes"]}
            state["segments"].append(segment_manifest)
            part_records.append({"path": result["path"],
                "part_manifest_sha256": result["part_manifest_sha256"],
                "source_json_sha256": result["source_json_sha256"],
                "source_json_bytes": result["source_json_bytes"]})
            session["completed_parts"] = part_records
            _write_json(output / "session.json", session, replace=True)
            current_part = None
            if progress:
                progress(_progress_record("part", started=started, child_before=child_before,
                    state_count=len(state["previous"]), segment_index=index,
                    observations=result["row_count"], points=result["point_count"],
                    event_count=result["event_count"], cache_bytes=_cache_bytes(output)))
        state["part_records"] = part_records
        if (len(part_records) != len(capture["segments"]) or
                state["source_json_bytes"] < 1 or
                sum(item["row_count"] for item in state["blocks"]) != capture["total_samples"]):
            raise ValueError("final capture coverage reconciliation failed")
        if not state["blocks"] or state["blocks"][0]["seq_range"][0] != capture["segments"][0]["seq_range"][0] or \
                state["blocks"][-1]["seq_range"][1] != capture["segments"][-1]["seq_range"][1]:
            raise ValueError("final sequence coverage reconciliation failed")
        manifest = _new_root_manifest(capture, state)
        _check_budget(output, max_cache_bytes, min_free_bytes)
        manifest_path = output / "manifest.json"
        if manifest_path.exists():
            _private_file(manifest_path)
            try:
                published = _read_json(manifest_path)
            except json.JSONDecodeError:
                published = None  # Recover an interrupted legacy non-atomic publication.
            if published is not None and published != manifest:
                raise ValueError("published manifest differs from verified checkpoints")
        _write_json(manifest_path, manifest, replace=True)
        _write_json(output / "status.json", {"status": "complete", "observations": capture["total_samples"],
                                             "blocks": len(state["blocks"])}, replace=True)
        return manifest
    except BaseException as exc:
        if current_part is not None and current_part.exists():
            # A shard is complete only after its session checkpoint is durable.
            if current_part.is_dir() and not current_part.is_symlink():
                checkpointed = False
                try:
                    saved = _read_json(output / "session.json")
                    checkpointed = any(item.get("path") == f"parts/{current_part.name}"
                                       for item in saved.get("completed_parts", []))
                except (OSError, ValueError, AttributeError):
                    pass
                if not checkpointed:
                    shutil.rmtree(current_part)
        if lock_fd is not None and output.exists() and output.is_dir() and not output.is_symlink():
            try:
                _write_json(output / "status.json", {"status": "failed", "error": str(exc)}, replace=True)
            except OSError:
                pass
        raise
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args(argv)

    def report(event):
        print(json.dumps(event, sort_keys=True), flush=True)

    try:
        manifest = prepare_capture(args.capture_root, args.output_dir, resume=args.resume,
                                   progress=report)
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(json.dumps({"event": "status", "status": "failed", "error": str(exc)}),
              file=sys.stderr, flush=True)
        parser.error(str(exc))
    print(json.dumps({"status": "complete", "manifest": str(args.output_dir / "manifest.json"),
                      "observations": manifest["source"]["observations"],
                      "blocks": len(manifest["blocks"]),
                      "cpu_component_discontinuity_count": manifest["cpu_component_discontinuity_count"]},
                     sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
