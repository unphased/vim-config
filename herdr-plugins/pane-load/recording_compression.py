#!/usr/bin/env python3
"""Compare independent zstd/Brotli frames over private PST recording blocks."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import resource
import subprocess
import sys
import time

MAGIC = b"PCR1"
DEFAULT_FRAMES = (30, 120, 600)


def _uvarint(value):
    if type(value) is not int or not 0 <= value < 1 << 64:
        raise ValueError("invalid frame integer")
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def _read_uvarint(data, offset):
    value = shift = 0
    for _ in range(10):
        if offset >= len(data):
            raise ValueError("truncated frame integer")
        byte = data[offset]
        offset += 1
        if shift == 63 and byte > 1:
            raise ValueError("frame integer overflow")
        value |= (byte & 127) << shift
        if byte < 128:
            if _uvarint(value) != data[offset - ((shift // 7) + 1):offset]:
                raise ValueError("non-canonical frame integer")
            return value, offset
        shift += 7
    raise ValueError("frame integer too long")


def pack_frame(blocks):
    blocks = list(blocks)
    result = bytearray(MAGIC + _uvarint(len(blocks)))
    for block in blocks:
        block = bytes(block)
        result += _uvarint(len(block)) + block
    return bytes(result)


def unpack_frame(data):
    data = bytes(data)
    if not data.startswith(MAGIC):
        raise ValueError("invalid PCR1 frame header")
    count, offset = _read_uvarint(data, len(MAGIC))
    if count > len(data) - offset:
        raise ValueError("invalid PCR1 block count")
    blocks = []
    for _ in range(count):
        size, offset = _read_uvarint(data, offset)
        if size > len(data) - offset:
            raise ValueError("truncated PCR1 block")
        blocks.append(data[offset:offset + size])
        offset += size
    if offset != len(data):
        raise ValueError("trailing PCR1 bytes")
    return blocks


def default_configs():
    return ([{"codec": codec, "level": level, "window_log": window}
             for codec, levels in (("zstd", (1, 3, 9)), ("brotli", (4, 6, 9)))
             for level in levels for window in (16, 20, 24)])


def finalist_configs():
    return ([{"codec": "zstd", "level": level, "window_log": 24}
             for level in (15, 19)] +
            [{"codec": "brotli", "level": 11, "window_log": 24}])


def _config(config):
    if not isinstance(config, dict) or set(config) != {"codec", "level", "window_log"}:
        raise ValueError("each config needs codec, level, and window_log")
    codec, level, window = config["codec"], config["level"], config["window_log"]
    if codec not in ("zstd", "brotli") or type(level) is not int or type(window) is not int:
        raise ValueError("invalid compression config")
    if (codec == "zstd" and not 1 <= level <= 22) or (codec == "brotli" and not 0 <= level <= 11):
        raise ValueError("compression level out of range")
    if not 10 <= window <= (31 if codec == "zstd" else 24):
        raise ValueError("window log out of range")
    return {"codec": codec, "level": level, "window_log": window}


def _load_dataset(directory):
    root = Path(directory).resolve()
    with (root / "manifest.json").open("r", encoding="utf-8") as source:
        manifest = json.load(source)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("blocks"), list) or not manifest["blocks"]:
        raise ValueError("manifest must contain a nonempty blocks list")
    source_info = manifest.get("source")
    if not isinstance(source_info, dict):
        raise ValueError("manifest source is missing")
    duration = source_info.get("duration_ns")
    if type(duration) is not int or duration < 0:
        raise ValueError("invalid source duration_ns")
    first = source_info.get('first_scan_start_ns')
    last = source_info.get('last_scan_start_ns')
    expected_rows, expected_points = source_info.get('observations'), source_info.get('points')
    if (type(first) is not int or first < 0 or type(last) is not int or
            last != first + duration or type(expected_rows) is not int or expected_rows < 1 or
            type(expected_points) is not int or expected_points < 0):
        raise ValueError('invalid source coverage counts or timestamps')
    blocks, paths = [], set()
    row_total = point_total = 0
    previous_end = previous_seq = None
    for item in manifest["blocks"]:
        if not isinstance(item, dict):
            raise ValueError("invalid block entry")
        name = item.get("path")
        if (not isinstance(name, str) or not name or "\\" in name or "\0" in name or
                PurePosixPath(name).is_absolute() or PureWindowsPath(name).is_absolute() or
                PureWindowsPath(name).drive or ".." in PurePosixPath(name).parts):
            raise ValueError("unsafe block path")
        if name in paths:
            raise ValueError('duplicate block path')
        paths.add(name)
        path = root / name
        try:
            path.resolve().relative_to(root)
        except ValueError as exc:
            raise ValueError("block path escapes input directory") from exc
        if not path.is_file():
            raise ValueError("block file is missing")
        times = item.get("time_range_ns")
        if (not isinstance(times, list) or len(times) != 2 or
                any(type(t) is not int or t < 0 for t in times) or times[1] < times[0]):
            raise ValueError("invalid block time_range_ns")
        count, points, seqs = item.get('row_count'), item.get('point_count'), item.get('seq_range')
        if (type(count) is not int or count < 1 or type(points) is not int or points < 0 or
                not isinstance(seqs, list) or len(seqs) != 2 or
                any(type(v) is not int for v in seqs) or seqs[1] < seqs[0] or
                count > seqs[1] - seqs[0] + 1 or
                (previous_end is not None and (times[0] <= previous_end or seqs[0] <= previous_seq))):
            raise ValueError('invalid or overlapping block coverage')
        blob = path.read_bytes()
        if item.get('raw_bytes') != len(blob) or item.get('sha256') != hashlib.sha256(blob).hexdigest():
            raise ValueError('block digest or length mismatch')
        blocks.append((times[0], times[1], blob))
        row_total += count
        point_total += points
        previous_end, previous_seq = times[1], seqs[1]
    if (blocks[0][0] != first or blocks[-1][1] != last or
            manifest['blocks'][0]['seq_range'][0] != source_info.get('first_seq') or
            previous_seq != source_info.get('last_seq') or
            row_total != expected_rows or point_total != expected_points):
        raise ValueError('prepared block coverage differs from source manifest')
    return blocks, first, duration, manifest


def _run(command, payload):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.perf_counter()
    result = subprocess.run(command, input=payload, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    elapsed = time.perf_counter() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if result.returncode:
        message = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"{command[0]} failed ({result.returncode}): {message}")
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    return result.stdout, elapsed, cpu


def _commands(config, size):
    codec, level, window = config["codec"], config["level"], config["window_log"]
    if codec == "zstd":
        return (["zstd", "-q", "--single-thread", f"--stream-size={size}",
                 f"--zstd=wlog={window}", *( ["--ultra"] if level > 19 else []),
                 f"-{level}", "-c"],
                ["zstd", "-q", "-d", "-c"])
    return (["brotli", "-q", str(level), "-w", str(window), "-c"],
            ["brotli", "-d", "-c"])


def _version(codec):
    result = subprocess.run([codec, "--version"], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=True)
    return result.stdout.decode(errors="replace").strip()


def compare(directory, frame_seconds=DEFAULT_FRAMES, configs=None):
    blocks, _origin, duration, manifest = _load_dataset(directory)
    frames = tuple(frame_seconds)
    if not frames or any(type(s) is not int or s <= 0 for s in frames) or len(set(frames)) != len(frames):
        raise ValueError("frame_seconds must contain unique positive integers")
    configs = default_configs() if configs is None else [_config(c) for c in configs]
    configs = [_config(c) for c in configs]
    if len({(c["codec"], c["level"], c["window_log"]) for c in configs}) != len(configs):
        raise ValueError("duplicate compression config")
    versions = {codec: _version(codec) for codec in {c["codec"] for c in configs}}
    records = []
    for seconds in frames:
        frame_blocks = []
        for index, (start, end, data) in enumerate(blocks):
            if not frame_blocks or end - blocks[frame_blocks[-1][0][0]][0] > seconds * 1_000_000_000:
                frame_blocks.append([])
            frame_blocks[-1].append((index, data))
        max_span = max((blocks[entries[-1][0]][1] - blocks[entries[0][0]][0]) / 1e9
                       for entries in frame_blocks)
        for config in configs:
            raw_total = compressed_total = encode_s = decode_s = encode_cpu = decode_cpu = 0
            decode_latencies = []
            max_input = max_compressed = max_decoded = 0
            seen = []
            for entries in frame_blocks:
                payload = pack_frame([blob for _, blob in entries])
                encoder, decoder = _commands(config, len(payload))
                compressed, elapsed, cpu = _run(encoder, payload)
                decoded, dec_elapsed, dec_cpu = _run(decoder, compressed)
                parsed = unpack_frame(decoded)
                expected = [blob for _, blob in entries]
                if decoded != payload or parsed != expected:
                    raise ValueError("compressed frame roundtrip or block coverage failed")
                seen.extend(index for index, _ in entries)
                raw_total += len(payload); compressed_total += len(compressed)
                encode_s += elapsed; decode_s += dec_elapsed
                encode_cpu += cpu; decode_cpu += dec_cpu
                decode_latencies.append(dec_elapsed)
                max_input = max(max_input, len(payload))
                max_compressed = max(max_compressed, len(compressed))
                max_decoded = max(max_decoded, len(decoded))
            if sorted(seen) != list(range(len(blocks))):
                raise ValueError("frame grouping omitted or duplicated a block")
            sorted_decode = sorted(decode_latencies)
            record = {'input_sha256': manifest.get('input_sha256'),
                      'rss_scheme': manifest.get('rss', {}).get('scheme'),
                      'metadata_layout': manifest.get('layout'),
                      'max_observed_frame_span_seconds': max_span,
                      "codec": config["codec"], "version": versions[config["codec"]],
                      "level": config["level"], "requested_window_log": config["window_log"],
                      "requested_window_bytes": (1 << config['window_log']) -
                          (16 if config['codec'] == 'brotli' else 0),
                      "frame_seconds": seconds, "frame_count": len(frame_blocks),
                      "block_count": len(blocks), "duration_ns": duration,
                      "raw_bytes": raw_total, "compressed_bytes": compressed_total,
                      "compressed_mib_per_day": (compressed_total * 86400 * 1_000_000_000 /
                          (1024 * 1024 * duration) if duration else None),
                      "encode_seconds": encode_s, "decode_seconds": decode_s,
                      "encode_child_cpu_seconds": encode_cpu,
                      "decode_child_cpu_seconds": decode_cpu,
                      "max_frame_input_bytes": max_input,
                      "max_frame_compressed_bytes": max_compressed,
                      "max_decode_frame_bytes": max_decoded,
                      "decode_frame_p50_seconds": sorted_decode[(len(sorted_decode)-1)//2],
                      "max_decode_frame_seconds": max(decode_latencies),
                      "decode_latency_scope": "whole compression frame; subprocess startup included, not query latency"}
            records.append(record)
    return records


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--frames", type=int, nargs="+", default=list(DEFAULT_FRAMES))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--codecs", nargs="+", choices=("zstd", "brotli"), default=("zstd", "brotli"))
    parser.add_argument("--zstd-levels", type=int, nargs="+", default=(1, 3, 9))
    parser.add_argument("--brotli-levels", type=int, nargs="+", default=(4, 6, 9))
    parser.add_argument("--windows", type=int, nargs="+", default=(16, 20, 24))
    parser.add_argument("--finalists", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.finalists:
            configs = finalist_configs()
        else:
            levels = {"zstd": args.zstd_levels, "brotli": args.brotli_levels}
            configs = [{"codec": codec, "level": level, "window_log": window}
                       for codec in args.codecs for level in levels[codec] for window in args.windows]
        records = compare(args.input_dir, args.frames, configs)
        lines = "".join(json.dumps(record, sort_keys=True) + "\n" for record in records)
        if args.output:
            fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                output.write(lines)
        else:
            sys.stdout.write(lines)
            sys.stdout.flush()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
