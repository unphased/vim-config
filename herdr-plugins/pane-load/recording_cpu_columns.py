"""Exploratory lossless codecs for cumulative per-process CPU/time series."""

import struct

from recording_codec import _read_uvarint, _uvarint

_MAGIC = b"CPD1"
_LAYOUTS = {"interleaved": 1, "columns": 2, "runs": 3, "grouped": 4, "both-runs": 5,
            "cpu-runs": 6, "cumulative-columns": 7, "cumulative-interleaved": 8}
_CODECS = {"uvarint": 1, "uint64le": 2}
_MAX_U64 = (1 << 64) - 1


def _integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{label} must be an integer")
    return value


def _checked_series(cpu_cumulative, time_cumulative):
    try:
        cpu = list(cpu_cumulative)
        times = list(time_cumulative)
    except TypeError as exc:
        raise ValueError("CPU and time series must be iterable") from exc
    if not cpu or len(cpu) != len(times):
        raise ValueError("CPU and time series must have equal nonzero lengths")
    for i, value in enumerate(cpu):
        _integer(value, "CPU counter")
        if value < 0 or (i and value < cpu[i - 1]):
            raise ValueError("CPU counters must be nonnegative and monotone")
    for i, value in enumerate(times):
        _integer(value, "time counter")
        if value < 0 or (i and value <= times[i - 1]):
            raise ValueError("time counters must be nonnegative and strictly increasing")
    return cpu, times


def _put(output, value, codec):
    if codec == "uvarint":
        output.extend(_uvarint(value))
    else:
        if value > _MAX_U64:
            raise ValueError("integer exceeds uint64")
        output.extend(struct.pack("<Q", value))


def _get(data, offset, codec):
    if codec == "uvarint":
        value, end = _read_uvarint(data, offset)
        if bytes(data[offset:end]) != bytes(_uvarint(value)):
            raise ValueError("noncanonical varint")
        return value, end
    if offset + 8 > len(data):
        raise ValueError("truncated uint64")
    return struct.unpack_from("<Q", data, offset)[0], offset + 8


def _put_many(output, values, codec):
    for value in values:
        _put(output, value, codec)


def _runs(values):
    runs = []
    for index, value in enumerate(values):
        if not runs or runs[-1][1] != value:
            runs.append((index, value))
    return runs


def _put_runs(output, values, codec):
    runs = _runs(values)
    _put(output, len(runs), codec)
    for index, value in runs:
        _put(output, index, codec)
        _put(output, value, codec)


def encode_series(cpu_cumulative, time_cumulative, layout, integer_codec):
    """Encode counters using delta/absolute columns or indexed CPU/time runs."""
    if layout not in _LAYOUTS:
        raise ValueError("unknown series layout")
    if integer_codec not in _CODECS:
        raise ValueError("unknown integer codec")
    cpu, times = _checked_series(cpu_cumulative, time_cumulative)
    dcpu = [b - a for a, b in zip(cpu, cpu[1:])]
    dtime = [b - a for a, b in zip(times, times[1:])]
    if integer_codec == "uint64le" and any(value > _MAX_U64 for value in cpu + times):
        raise ValueError("integer exceeds uint64")

    output = bytearray(_MAGIC)
    output.extend((_LAYOUTS[layout], _CODECS[integer_codec]))
    _put(output, len(cpu), integer_codec)
    _put(output, cpu[0], integer_codec)
    _put(output, times[0], integer_codec)
    cpu_values = cpu[1:] if layout.startswith("cumulative-") else dcpu
    if layout == "both-runs":
        _put_runs(output, dcpu, integer_codec)
        _put_runs(output, dtime, integer_codec)
    elif layout == "cpu-runs":
        _put_runs(output, dcpu, integer_codec)
        _put_many(output, dtime, integer_codec)
    elif layout in ("interleaved", "cumulative-interleaved"):
        for cpu_value, time_delta in zip(cpu_values, dtime):
            _put(output, cpu_value, integer_codec)
            _put(output, time_delta, integer_codec)
    elif layout in ("columns", "cumulative-columns"):
        _put_many(output, cpu_values, integer_codec)
        _put_many(output, dtime, integer_codec)
    else:
        _put_many(output, dcpu, integer_codec)
        runs = _runs(dtime)
        if layout == "runs":
            _put(output, len(runs), integer_codec)
            for index, period in runs:
                _put(output, index, integer_codec)
                _put(output, period, integer_codec)
        else:
            groups = {}
            for index, period in runs:
                groups.setdefault(period, []).append(index)
            _put(output, len(groups), integer_codec)
            for period, indexes in sorted(groups.items()):
                _put(output, period, integer_codec)
                _put(output, len(indexes), integer_codec)
                _put_many(output, indexes, integer_codec)
    return bytes(output)


def _read_count(data, offset, codec, upper, label, minimum_items=0):
    count, offset = _get(data, offset, codec)
    if count > upper:
        raise ValueError(f"impossible {label} count")
    width = 1 if codec == "uvarint" else 8
    if minimum_items and count > (len(data) - offset) // (minimum_items * width):
        raise ValueError(f"impossible {label} count")
    return count, offset


def _expand_runs(data, offset, codec, intervals, positive):
    count, offset = _read_count(data, offset, codec, intervals, "run", minimum_items=2)
    if bool(intervals) != bool(count):
        raise ValueError("invalid run count")
    starts = []
    previous_index = -1
    previous_value = None
    for _ in range(count):
        index, offset = _get(data, offset, codec)
        value, offset = _get(data, offset, codec)
        if (index >= intervals or index <= previous_index or
                (previous_index == -1 and index != 0) or value == previous_value or
                (positive and value == 0)):
            raise ValueError("invalid run")
        starts.append((index, value))
        previous_index, previous_value = index, value
    output = []
    for n, (start, value) in enumerate(starts):
        end = starts[n+1][0] if n+1 < len(starts) else intervals
        output.extend([value]*(end-start))
    return output, offset


def decode_series(encoded, max_samples=1_000_000):
    """Decode CPD1 bytes to exact cumulative (CPU, time) integer arrays."""
    if _integer(max_samples, "sample limit") < 1:
        raise ValueError("sample limit must be positive")
    if not isinstance(encoded, (bytes, bytearray, memoryview)):
        raise ValueError("encoded series must be bytes")
    data = memoryview(encoded)
    if len(data) < 6 or bytes(data[:4]) != _MAGIC:
        raise ValueError("invalid CPD1 header")
    layout_id, codec_id = data[4], data[5]
    layouts = {value: key for key, value in _LAYOUTS.items()}
    codecs = {value: key for key, value in _CODECS.items()}
    if layout_id not in layouts or codec_id not in codecs:
        raise ValueError("unknown CPD1 layout or integer codec")
    layout, codec = layouts[layout_id], codecs[codec_id]
    offset = 6
    count, offset = _get(data, offset, codec)
    if count < 1 or count > max_samples:
        raise ValueError("sample count outside decoded-size limit")
    cpu0, offset = _get(data, offset, codec)
    time0, offset = _get(data, offset, codec)
    intervals = count - 1
    width = 1 if codec == "uvarint" else 8
    minimum_values = ((6 if intervals else 2) if layout == "both-runs" else
                      intervals + (3 if intervals else 1) if layout == "cpu-runs" else
                      2 * intervals if layout in ("interleaved", "columns", "cumulative-columns", "cumulative-interleaved") else
                      intervals + (3 if layout == "runs" and intervals else
                                   4 if intervals else 0))
    if minimum_values * width > len(data) - offset:
        raise ValueError("impossible sample count")

    def read_values(number):
        nonlocal offset
        values = []
        for _ in range(number):
            value, offset = _get(data, offset, codec)
            values.append(value)
        return values

    if layout == "both-runs":
        dcpu, offset = _expand_runs(data, offset, codec, intervals, False)
        dtime, offset = _expand_runs(data, offset, codec, intervals, True)
    elif layout == "cpu-runs":
        dcpu, offset = _expand_runs(data, offset, codec, intervals, False)
        dtime = read_values(intervals)
    elif layout in ("interleaved", "cumulative-interleaved"):
        dcpu, dtime = [], []
        for _ in range(intervals):
            cpu_delta, offset = _get(data, offset, codec)
            time_delta, offset = _get(data, offset, codec)
            dcpu.append(cpu_delta)
            dtime.append(time_delta)
    elif layout in ("columns", "cumulative-columns"):
        dcpu = read_values(intervals)
        dtime = read_values(intervals)
    else:
        dcpu = read_values(intervals)
        if layout == "runs":
            dtime, offset = _expand_runs(data, offset, codec, intervals, True)
        else:
            dtime = [0] * intervals
            group_count, offset = _read_count(data, offset, codec, intervals,
                                              "period group", minimum_items=2)
            if (intervals == 0 and group_count != 0) or (intervals and group_count == 0):
                raise ValueError("invalid period group count")
            previous_period = 0
            assigned = 0
            starts = []
            seen_indexes = set()
            for _ in range(group_count):
                period, offset = _get(data, offset, codec)
                if period == 0 or period <= previous_period:
                    raise ValueError("period groups must be sorted positive values")
                indexes_count, offset = _read_count(data, offset, codec, intervals - assigned,
                                                    "period index", minimum_items=1)
                if indexes_count == 0:
                    raise ValueError("period group cannot be empty")
                previous_index = -1
                for _ in range(indexes_count):
                    index, offset = _get(data, offset, codec)
                    if index >= intervals or index <= previous_index or index in seen_indexes:
                        raise ValueError("invalid or duplicate period index")
                    starts.append((index, period))
                    seen_indexes.add(index)
                    previous_index = index
                assigned += indexes_count
                previous_period = period
            starts.sort()
            if intervals and (not starts or starts[0][0] != 0):
                raise ValueError("period indexes must begin at zero")
            for run_index, (start, period) in enumerate(starts):
                end = starts[run_index + 1][0] if run_index + 1 < len(starts) else intervals
                if run_index and starts[run_index - 1][1] == period:
                    raise ValueError("adjacent period runs must differ")
                dtime[start:end] = [period] * (end - start)

    if offset != len(data):
        raise ValueError("trailing bytes after CPU series")
    if layout.startswith("cumulative-"):
        dcpu = [b-a for a,b in zip([cpu0]+dcpu,dcpu)]
        if any(value<0 for value in dcpu):
            raise ValueError("absolute CPU counters decreased")
    cpu = [cpu0]
    times = [time0]
    for cpu_delta, time_delta in zip(dcpu, dtime):
        if time_delta == 0:
            raise ValueError("time periods must be positive")
        cpu.append(cpu[-1] + cpu_delta)
        times.append(times[-1] + time_delta)
        if codec == "uint64le" and (cpu[-1] > _MAX_U64 or times[-1] > _MAX_U64):
            raise ValueError("decoded cumulative counter exceeds uint64")
    return cpu, times


def quantize_cumulative(values, quantum):
    """Split monotone cumulative integers into quotient and remainder series."""
    quantum = _integer(quantum, "quantum")
    if quantum <= 0:
        raise ValueError("quantum must be positive")
    try:
        checked = list(values)
    except TypeError as exc:
        raise ValueError("values must be iterable") from exc
    if not checked:
        raise ValueError("values must not be empty")
    previous = -1
    for value in checked:
        _integer(value, "cumulative value")
        if value < 0 or value < previous:
            raise ValueError("values must be nonnegative and monotone")
        previous = value
    pairs = [divmod(value, quantum) for value in checked]
    return [quotient for quotient, _ in pairs], [remainder for _, remainder in pairs]
