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
from statistics import median

MAGIC = b"PCR1"
SECTIONS_MAGIC = b"PCR2"
DEFAULT_FRAMES = (30, 120, 600)
DEFAULT_FRAME_BYTES = (256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024)


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


def _pst1_sections(block):
    block = bytes(block)
    if not block.startswith(b"PST1"):
        raise ValueError("sections layout requires PST1 blocks")
    offset, parts = 4, []
    for _ in range(3):
        size, offset = _read_uvarint(block, offset)
        if size > len(block) - offset:
            raise ValueError("truncated PST1 section")
        parts.append(block[offset:offset + size])
        offset += size
    if offset != len(block):
        raise ValueError("trailing PST1 bytes")
    return tuple(parts)


def pack_frame(blocks, layout="blocks"):
    blocks = [bytes(block) for block in blocks]
    if layout == "blocks":
        result = bytearray(MAGIC + _uvarint(len(blocks)))
        for block in blocks:
            result += _uvarint(len(block)) + block
        return bytes(result)
    if layout != "sections":
        raise ValueError("layout must be blocks or sections")
    parts = [_pst1_sections(block) for block in blocks]
    result = bytearray(SECTIONS_MAGIC + _uvarint(len(blocks)))
    for column in range(3):
        result += b"".join(_uvarint(len(row[column])) for row in parts)
    for column in range(3):
        result += b"".join(row[column] for row in parts)
    return bytes(result)


def unpack_frame(data):
    data = bytes(data)
    if data.startswith(MAGIC):
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
    if not data.startswith(SECTIONS_MAGIC):
        raise ValueError("invalid PCR frame header")
    count, offset = _read_uvarint(data, len(SECTIONS_MAGIC))
    if count > (len(data) - offset) // 3:
        raise ValueError("invalid PCR2 block count")
    lengths = [[0] * count for _ in range(3)]
    for column in range(3):
        for index in range(count):
            lengths[column][index], offset = _read_uvarint(data, offset)
    parts = [[b"", b"", b""] for _ in range(count)]
    for column in range(3):
        total = sum(lengths[column])
        if total > len(data) - offset:
            raise ValueError("truncated PCR2 section")
        for index, size in enumerate(lengths[column]):
            parts[index][column] = data[offset:offset + size]
            offset += size
    if offset != len(data):
        raise ValueError("trailing PCR2 bytes")
    return [b"PST1" + b"".join(_uvarint(len(section)) + section for section in row)
            for row in parts]


def default_configs():
    return ([{"codec": codec, "level": level, "window_log": window}
             for codec, levels in (("zstd", (1, 3, 9)), ("brotli", (4, 6, 9)))
             for level in levels for window in (16, 20, 24)])


def finalist_configs():
    return ([{"codec": "zstd", "level": level, "window_log": 24}
             for level in (15, 19)] +
            [{"codec": "brotli", "level": 11, "window_log": 24}])


def _config(config):
    required = {'codec', 'level', 'window_log'}
    if (not isinstance(config, dict) or not required <= config.keys() or
            config.keys() - required - {'threads', 'large_window', 'long_distance'}):
        raise ValueError('each config needs codec, level, and window_log')
    codec, level, window = config["codec"], config["level"], config["window_log"]
    if codec not in ("zstd", "brotli") or type(level) is not int or type(window) is not int:
        raise ValueError("invalid compression config")
    if (codec == "zstd" and not 1 <= level <= 22) or (codec == "brotli" and not 0 <= level <= 11):
        raise ValueError("compression level out of range")
    threads = config.get('threads', 1)
    large = config.get('large_window', False)
    long_distance = config.get('long_distance', False)
    if type(long_distance) is not bool or (long_distance and codec != 'zstd'):
        raise ValueError('long_distance is a zstd-only boolean')
    if type(threads) is not int or threads < 1 or (codec == 'brotli' and threads != 1):
        raise ValueError('invalid codec thread count')
    if type(large) is not bool or (large and codec != 'brotli'):
        raise ValueError('large_window is a Brotli-only boolean')
    if not 10 <= window <= (31 if codec == 'zstd' else 30 if large else 24):
        raise ValueError('window log out of range')
    return {'codec': codec, 'level': level, 'window_log': window,
            'threads': threads, 'large_window': large, 'long_distance': long_distance}


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
        threading = '--single-thread' if config['threads'] == 1 else f"-T{config['threads']}"
        return (["zstd", "-q", threading, f"--stream-size={size}",
                 f'--zstd=wlog={window}', *([f'--long={window}'] if config['long_distance'] else []),
                 *(['--ultra'] if level > 19 else []),
                 f"-{level}", "-c"],
                ["zstd", "-q", "-d", "-c"])
    window_args = [f'--large_window={window}'] if config['large_window'] else ['-w', str(window)]
    return (['brotli', '-q', str(level), *window_args, '-c'],
            ['brotli', *([f'--large_window={window}'] if config['large_window'] else []), '-d', '-c'])


def _version(codec):
    result = subprocess.run([codec, "--version"], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=True)
    return result.stdout.decode(errors="replace").strip()


def compare(directory, frame_seconds=DEFAULT_FRAMES, configs=None, *, frame_bytes=None,
            repeats=1, layout="blocks"):
    if type(repeats) is not int or repeats < 1:
        raise ValueError("repeats must be a positive integer")
    if layout not in ("blocks", "sections"):
        raise ValueError("layout must be blocks or sections")
    if frame_bytes is None:
        frames = tuple(frame_seconds)
        if (not frames or any(type(s) is not int or s <= 0 for s in frames) or
                len(set(frames)) != len(frames)):
            raise ValueError("frame_seconds must contain unique positive integers")
    else:
        frames = tuple(frame_bytes)
        if (not frames or any(type(n) is not int or n <= 0 for n in frames) or
                len(set(frames)) != len(frames)):
            raise ValueError("frame_bytes must contain unique positive integers")
    blocks, _origin, duration, manifest = _load_dataset(directory)
    configs = default_configs() if configs is None else configs
    configs = [_config(c) for c in configs]
    if len({(c['codec'], c['level'], c['window_log'], c['threads'], c['large_window'], c['long_distance'])
            for c in configs}) != len(configs):
        raise ValueError("duplicate compression config")
    section_parts = [_pst1_sections(blob) for _, _, blob in blocks] if layout == "sections" else None
    versions = {codec: _version(codec) for codec in {c["codec"] for c in configs}}
    records = []
    for target in frames:
        groups, statuses = [], []
        if frame_bytes is None:
            for index, (start, end, _data) in enumerate(blocks):
                if not groups or end - blocks[groups[-1][0]][0] > target * 1_000_000_000:
                    groups.append([])
                groups[-1].append(index)
            statuses = ["time"] * len(groups)
        else:
            current = []
            def envelope_size(indices):
                count_size = len(_uvarint(len(indices)))
                if layout == "blocks":
                    return 4 + count_size + sum(len(_uvarint(len(blocks[i][2]))) +
                                                len(blocks[i][2]) for i in indices)
                return (4 + count_size +
                        sum(len(_uvarint(len(section_parts[i][column])))
                            for column in range(3) for i in indices) +
                        sum(len(section_parts[i][column]) for column in range(3)
                            for i in indices))
            for index in range(len(blocks)):
                if current and envelope_size(current + [index]) > target:
                    groups.append(current); statuses.append("full")
                    current = []
                if envelope_size([index]) > target:
                    groups.append([index]); statuses.append("oversize")
                else:
                    current.append(index)
            if current:
                groups.append(current); statuses.append("partial")
        frame_payloads = [pack_frame([blocks[i][2] for i in group], layout=layout)
                          for group in groups]
        spans = [(blocks[group[-1]][1] - blocks[group[0]][0]) / 1e9 for group in groups]
        input_sizes = [len(payload) for payload in frame_payloads]
        raw_total = sum(input_sizes)
        max_span = max(spans)
        for config in configs:
            encode_times, encode_cpus = [], []
            compressed_sizes, size_totals = [], []
            max_compressed = 0
            for repeat in range(repeats):
                enc_s = enc_cpu = 0.0
                repeat_sizes, seen = [], []
                for group, payload in zip(groups, frame_payloads):
                    encoder, decoder = _commands(config, len(payload))
                    compressed, elapsed, cpu = _run(encoder, payload)
                    decoded, _, _ = _run(decoder, compressed)
                    if decoded != payload or unpack_frame(decoded) != [blocks[i][2] for i in group]:
                        raise ValueError("compressed frame roundtrip or block coverage failed")
                    seen.extend(group)
                    enc_s += elapsed
                    enc_cpu += cpu
                    repeat_sizes.append(len(compressed))
                    max_compressed = max(max_compressed, len(compressed))
                if sorted(seen) != list(range(len(blocks))):
                    raise ValueError("frame grouping omitted or duplicated a block")
                encode_times.append(enc_s)
                encode_cpus.append(enc_cpu)
                size_totals.append(sum(repeat_sizes))
                if repeat == 0:
                    compressed_sizes = repeat_sizes
            encode_s, encode_cpu = median(encode_times), median(encode_cpus)
            compressed_total = median(size_totals)
            mib = raw_total / (1024 * 1024)
            hours = duration / 3_600_000_000_000
            record = {'input_sha256': manifest.get('input_sha256'),
                      'rss_scheme': manifest.get('rss', {}).get('scheme'),
                      'metadata_layout': manifest.get('layout'),
                      'layout': layout,
                      'max_observed_frame_span_seconds': max_span,
                      "codec": config["codec"], "version": versions[config["codec"]],
                      "level": config["level"], 'threads': config['threads'],
                      'zstd_long_distance': config['long_distance'],
                      'brotli_format': ('large-window extension' if config['large_window'] else 'RFC 7932')
                          if config['codec'] == 'brotli' else None,
                      "requested_window_log": config["window_log"],
                      "requested_window_bytes": (1 << config['window_log']) -
                          (16 if config['codec'] == 'brotli' else 0),
                      "frame_seconds": target if frame_bytes is None else None,
                      "frame_bytes_target": target if frame_bytes is not None else None,
                      "frame_count": len(groups), "block_count": len(blocks),
                      "duration_ns": duration, "repeats": repeats,
                      "raw_bytes": raw_total, "compressed_bytes": compressed_total,
                      'compression_ratio': raw_total / compressed_total if compressed_total else None,
                      'compression_cpu_seconds_per_input_gib': encode_cpu / mib * 1024 if mib else None,
                      'compression_wall_seconds_per_input_gib': encode_s / mib * 1024 if mib else None,
                      "compressed_bytes_per_second": (compressed_total * 1e9 / duration
                                                       if duration else None),
                      "compressed_mib_per_day": (compressed_total * 86400 * 1_000_000_000 /
                          (1024 * 1024 * duration) if duration else None),
                      "size_reduction_percent": (1 - compressed_total / raw_total) * 100,
                      'encode_seconds': encode_s, 'encode_child_cpu_seconds': encode_cpu,
                      'encode_seconds_by_repeat': encode_times,
                      'encode_child_cpu_seconds_by_repeat': encode_cpus,
                      'compressed_bytes_by_repeat': size_totals,
                      'encode_child_cpu_seconds_per_input_mib': encode_cpu / mib if mib else None,
                      'encode_child_cpu_seconds_per_recorded_hour': encode_cpu / hours if hours else None,
                      "frame_input_bytes": input_sizes, "frame_span_seconds": spans,
                      'first_repeat_frame_compressed_bytes': compressed_sizes,
                      "full_target_frame_count": statuses.count("full"),
                      "partial_frame_count": statuses.count("partial"),
                      "oversize_frame_count": statuses.count("oversize"),
                      "max_frame_input_bytes": max(input_sizes),
                      'max_frame_compressed_bytes': max_compressed,
                      'decompression_scope': 'correctness verification only'}
            records.append(record)
    return records


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    grouping = parser.add_mutually_exclusive_group()
    grouping.add_argument("--frames", type=int, nargs="+")
    grouping.add_argument("--frame-bytes", type=int, nargs="+")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--layout", choices=("blocks", "sections"), default="blocks")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--codecs", nargs="+", choices=("zstd", "brotli"), default=("zstd", "brotli"))
    parser.add_argument("--zstd-levels", type=int, nargs="+", default=(1, 3, 9))
    parser.add_argument('--brotli-levels', type=int, nargs='+', default=(4, 6, 9))
    parser.add_argument('--zstd-threads', type=int, nargs='+', default=(1,))
    parser.add_argument('--zstd-long-distance', action='store_true')
    parser.add_argument('--brotli-large-window', action='store_true',
                        help='explicitly allow nonstandard Brotli window logs up to 30')
    parser.add_argument("--windows", type=int, nargs="+", default=(16, 20, 24))
    parser.add_argument("--finalists", action="store_true")
    args = parser.parse_args(argv)
    fd = None
    try:
        if args.finalists:
            configs = finalist_configs()
        else:
            levels = {"zstd": args.zstd_levels, "brotli": args.brotli_levels}
            configs = [{'codec': codec, 'level': level, 'window_log': window,
                        'threads': threads,
                        'large_window': args.brotli_large_window if codec == 'brotli' else False,
                        'long_distance': args.zstd_long_distance if codec == 'zstd' else False}
                       for codec in args.codecs for level in levels[codec] for window in args.windows
                       for threads in (args.zstd_threads if codec == 'zstd' else (1,))]
        if args.output:
            fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.fchmod(fd, 0o600)
        records = compare(args.input_dir, args.frames or DEFAULT_FRAMES, configs,
                          frame_bytes=args.frame_bytes or (DEFAULT_FRAME_BYTES
                              if args.frames is None else None),
                          repeats=args.repeats, layout=args.layout)
        lines = "".join(json.dumps(record, sort_keys=True) + "\n" for record in records)
        if fd is not None:
            output = os.fdopen(fd, 'w', encoding='utf-8')
            fd = None
            with output:
                output.write(lines)
        else:
            sys.stdout.write(lines)
            sys.stdout.flush()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        parser.error(str(exc))
    finally:
        if fd is not None:
            os.close(fd)


if __name__ == "__main__":
    main()
