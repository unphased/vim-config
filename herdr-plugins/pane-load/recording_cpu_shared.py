"""Experimental chunk-local codec sharing a sparse CPU series clock axis.

CPU values are the supplied native-tick total (typically user + system); the
component split is unavailable. ``quantum > 1`` stores cumulative floors,
keeps exact endpoints, and estimates interior values downward with error < Q.
"""
from collections.abc import Mapping

from recording_codec import _read_uvarint, _uvarint

MAGIC = b"CSH1"
MAX_FRAMES = 1_000_000
MAX_POINTS = 1_000_000
_MAX_VARINT_BYTES = 64
_LAYOUTS = {"changes": 0, "points": 1}


def _integer(value, label, *, minimum=0):
    if (isinstance(value, bool) or not isinstance(value, int) or value < minimum or
            value.bit_length() > 7 * _MAX_VARINT_BYTES):
        raise ValueError(f"{label} must be an integer >= {minimum} within the wire width")
    return value


def _metadata_values(layout, quantum, clock_unit_ns, numerator, denominator):
    return {
        "layout": layout,
        "quantum": quantum,
        "clock_unit_ns": clock_unit_ns,
        "clock_exact": True,
        "cpu_timebase": (numerator, denominator),
        "cpu_unit": "native_ticks",
        "cpu_exact": quantum == 1,
        "cpu_estimate": "exact" if quantum == 1 else "floor-with-exact-endpoints",
        "cpu_component": "user+system total; split not preserved",
    }


def encode_shared(series, layout="changes", quantum=1, clock_unit_ns=1,
                  cpu_timebase=(125, 3)):
    """Encode identity -> [(seq, native_cpu, timestamp_ns), ...] as one chunk.

    The timestamp unit must divide every source timestamp; timestamps are then
    encoded exactly in that unit. Input sequence numbers and CPU totals are
    nonnegative, and each identity's sequence, timestamp, and CPU are monotone.
    """
    if not isinstance(series, Mapping):
        raise ValueError("series must be a mapping")
    if layout not in _LAYOUTS:
        raise ValueError("unknown layout")
    quantum = _integer(quantum, "quantum", minimum=1)
    clock_unit_ns = _integer(clock_unit_ns, "clock_unit_ns", minimum=1)
    if not isinstance(cpu_timebase, (tuple, list)) or len(cpu_timebase) != 2:
        raise ValueError("cpu_timebase must be a numerator/denominator pair")
    numerator = _integer(cpu_timebase[0], "timebase numerator", minimum=1)
    denominator = _integer(cpu_timebase[1], "timebase denominator", minimum=1)

    checked = []
    axis = {}
    total_points = 0
    for raw_identity, raw_samples in series.items():
        if not isinstance(raw_identity, tuple) or len(raw_identity) != 3:
            raise ValueError("identity must be (pid, startsec, startusec)")
        identity = tuple(_integer(v, "identity field") for v in raw_identity)
        if not isinstance(raw_samples, (list, tuple)) or not raw_samples:
            raise ValueError("each identity must have at least one sample")
        samples = []
        previous = None
        for raw in raw_samples:
            if not isinstance(raw, (list, tuple)) or len(raw) != 3:
                raise ValueError("sample must be (seq, cpu, timestamp_ns)")
            seq, cpu, stamp = (_integer(v, label) for v, label in zip(
                raw, ("seq", "cpu", "timestamp_ns")))
            if stamp % clock_unit_ns:
                raise ValueError("timestamp must be divisible by clock_unit_ns")
            if previous is not None and not (seq > previous[0] and stamp > previous[2]
                                             and cpu >= previous[1]):
                raise ValueError("sequence/timestamp must increase and CPU must be monotone")
            if seq in axis and axis[seq] != stamp:
                raise ValueError("a sequence number cannot have multiple timestamps")
            axis[seq] = stamp
            samples.append((seq, cpu, stamp))
            previous = (seq, cpu, stamp)
        checked.append((identity, samples))
        total_points += len(samples)
        if total_points > MAX_POINTS:
            raise ValueError("point limit exceeded")
    checked.sort(key=lambda pair: pair[0])
    if any(checked[i - 1][0] == checked[i][0] for i in range(1, len(checked))):
        raise ValueError("duplicate identity")
    frames = sorted(axis.items())
    if len(frames) > MAX_FRAMES:
        raise ValueError("frame limit exceeded")
    if any(frames[i][1] <= frames[i - 1][1] for i in range(1, len(frames))):
        raise ValueError("timestamps must increase with sequence numbers")
    positions = {seq: index for index, (seq, _) in enumerate(frames)}

    output = bytearray(MAGIC)
    output.append(_LAYOUTS[layout])
    for value in (quantum, clock_unit_ns, numerator, denominator,
                  len(frames), len(checked), total_points):
        output.extend(_uvarint(value))
    prev_seq = prev_stamp = 0
    for seq, stamp in frames:
        output.extend(_uvarint(seq - prev_seq))
        output.extend(_uvarint(stamp // clock_unit_ns - prev_stamp))
        prev_seq, prev_stamp = seq, stamp // clock_unit_ns

    for identity, samples in checked:
        output.extend(_uvarint(identity[0]))
        output.extend(_uvarint(identity[1]))
        output.extend(_uvarint(identity[2]))
        output.extend(_uvarint(len(samples)))
        indices = [positions[sample[0]] for sample in samples]
        quotients = [sample[1] // quantum for sample in samples]
        remainders = [sample[1] % quantum for sample in samples]
        if layout == "changes":
            runs = []
            for index in indices:
                if runs and index == runs[-1][0] + runs[-1][1]:
                    start, length = runs[-1]
                    runs[-1] = (start, length + 1)
                else:
                    runs.append((index, 1))
            output.extend(_uvarint(len(runs)))
            previous_end = 0
            for start, length in runs:
                output.extend(_uvarint(start - previous_end))
                output.extend(_uvarint(length))
                previous_end = start + length
            output.extend(_uvarint(quotients[0]))
            changes = [(i, quotients[i] - quotients[i - 1])
                       for i in range(1, len(quotients))
                       if quotients[i] != quotients[i - 1]]
            output.extend(_uvarint(len(changes)))
            previous_index = 0
            for index, delta in changes:
                output.extend(_uvarint(index - previous_index))
                output.extend(_uvarint(delta))
                previous_index = index
        else:
            previous = 0
            for index in indices:
                output.extend(_uvarint(index - previous))
                previous = index
            output.extend(_uvarint(quotients[0]))
            for before, after in zip(quotients, quotients[1:]):
                output.extend(_uvarint(after - before))
        output.extend(_uvarint(remainders[0]))
        output.extend(_uvarint(remainders[-1]))
    return bytes(output)


def _read(data, offset):
    start = offset
    try:
        value, end = _read_uvarint(data[:offset + _MAX_VARINT_BYTES + 1], offset)
    except (ValueError, IndexError) as exc:
        raise ValueError("truncated or oversized varint") from exc
    if end - start > _MAX_VARINT_BYTES or bytes(_uvarint(value)) != data[start:end]:
        raise ValueError("noncanonical varint")
    return value, end


def _limit(value, label):
    return _integer(value, label)


def _decode(data, max_frames, max_points):
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise ValueError("data must be bytes-like")
    data = memoryview(data).cast("B")
    if len(data) < 5 or data[:4] != MAGIC:
        raise ValueError("invalid shared CPU header")
    layout_id = data[4]
    if layout_id not in (0, 1):
        raise ValueError("unknown shared CPU layout")
    layout = "changes" if layout_id == 0 else "points"
    offset = 5
    values = []
    for _ in range(7):
        value, offset = _read(data, offset)
        values.append(value)
    quantum, clock_unit, numerator, denominator, frame_count, identity_count, point_count = values
    if min(quantum, clock_unit, numerator, denominator) < 1:
        raise ValueError("invalid zero codec metadata")
    if frame_count > max_frames:
        raise ValueError("frame limit exceeded")
    if point_count > max_points:
        raise ValueError("point limit exceeded")
    if point_count > MAX_POINTS or frame_count > MAX_FRAMES:
        raise ValueError("configured hard limit exceeded")
    if identity_count > point_count or identity_count > max_points:
        raise ValueError("impossible identity count")
    if frame_count > point_count:
        raise ValueError("impossible frame count")
    # Sparse coverage can represent many points with a tiny run. Only frames
    # require per-entry payload; decoded point counts have their separate cap.
    if 2 * frame_count > len(data) - offset:
        raise ValueError("impossible payload count")
    frames = []
    seq = stamp_units = 0
    for _ in range(frame_count):
        ds, dt = [], []
        for target in (ds, dt):
            value, offset = _read(data, offset)
            target.append(value)
        if frames and (ds[0] == 0 or dt[0] == 0):
            raise ValueError("frame sequence and timestamps must increase")
        seq += ds[0]
        stamp_units += dt[0]
        frames.append((seq, stamp_units * clock_unit))
    result = {}
    used_frames = set()
    previous_identity = None
    observed_points = 0
    for _ in range(identity_count):
        fields = []
        for _ in range(4):
            value, offset = _read(data, offset)
            fields.append(value)
        identity = tuple(fields[:3])
        count = fields[3]
        if count == 0 or count > frame_count:
            raise ValueError("invalid identity sample count")
        if previous_identity is not None and identity <= previous_identity:
            raise ValueError("duplicate identity or noncanonical identity order")
        previous_identity = identity
        observed_points += count
        if observed_points > point_count or observed_points > max_points:
            raise ValueError("point count mismatch or limit exceeded")
        indices = []
        quotients = []
        if layout == "changes":
            run_count, offset = _read(data, offset)
            if run_count == 0 or run_count > count or run_count > len(data) - offset:
                raise ValueError("invalid coverage run count")
            previous_end = 0
            for run_index in range(run_count):
                gap, offset = _read(data, offset)
                length, offset = _read(data, offset)
                start = previous_end + gap
                if (length == 0 or length > count-len(indices) or
                        start + length > frame_count or (run_index and gap == 0)):
                    raise ValueError("invalid coverage runs")
                indices.extend(range(start, start + length))
                previous_end = start + length
            if len(indices) != count:
                raise ValueError("coverage count mismatch")
            baseline, offset = _read(data, offset)
            quotients = [baseline] * count
            change_count, offset = _read(data, offset)
            if change_count > count - 1 or change_count > len(data) - offset:
                raise ValueError("invalid CPU change count")
            previous_position = 0
            for _ in range(change_count):
                delta_position, offset = _read(data, offset)
                delta_cpu, offset = _read(data, offset)
                position = previous_position + delta_position
                if delta_position == 0 or delta_cpu == 0 or position >= count:
                    raise ValueError("invalid CPU change position/delta")
                for index in range(previous_position, position):
                    quotients[index + 1] = quotients[index]
                quotients[position] = quotients[position - 1] + delta_cpu
                previous_position = position
            for index in range(previous_position, count - 1):
                quotients[index + 1] = quotients[index]
        else:
            previous_index = 0
            for sample in range(count):
                delta, offset = _read(data, offset)
                index = previous_index + delta
                if (sample == 0 and delta >= frame_count) or (sample and delta == 0) or index >= frame_count:
                    raise ValueError("frame positions must increase")
                indices.append(index)
                previous_index = index
            baseline, offset = _read(data, offset)
            quotients = [baseline]
            for _ in range(count - 1):
                delta, offset = _read(data, offset)
                quotients.append(quotients[-1] + delta)
        if any(a > b for a, b in zip(quotients, quotients[1:])):
            raise ValueError("CPU counters must be monotone")
        first_remainder, offset = _read(data, offset)
        last_remainder, offset = _read(data, offset)
        if first_remainder >= quantum or last_remainder >= quantum:
            raise ValueError("invalid CPU endpoint remainder")
        if count == 1 and first_remainder != last_remainder:
            raise ValueError("singleton endpoint remainders differ")
        cpus = [quotients[0] * quantum + first_remainder]
        for quotient in quotients[1:-1]:
            cpus.append(max(cpus[-1], quotient * quantum))
        if count > 1:
            last_cpu = quotients[-1] * quantum + last_remainder
            if last_cpu < cpus[-1]:
                raise ValueError("CPU endpoints are nonmonotone")
            cpus.append(last_cpu)
        if any(a > b for a, b in zip(cpus, cpus[1:])):
            raise ValueError("CPU counters must be monotone")
        used_frames.update(indices)
        result[identity] = [(frames[index][0], cpu, frames[index][1])
                            for index, cpu in zip(indices, cpus)]
    if observed_points != point_count:
        raise ValueError("point count mismatch")
    if len(used_frames) != frame_count:
        raise ValueError("unused shared clock entries")
    if offset != len(data):
        raise ValueError("trailing shared CPU bytes")
    metadata = _metadata_values(layout, quantum, clock_unit, numerator, denominator)
    return result, metadata


def decode_shared(data, *, max_frames=MAX_FRAMES, max_points=MAX_POINTS):
    """Decode a chunk to identity -> retained (seq, CPU, timestamp_ns) points.

    Limits are checked before allocating from encoded counts. Decoding preserves
    all retained points, never inserts synthetic zero-CPU observations.
    """
    return _decode(data, _limit(max_frames, "max_frames"),
                   _limit(max_points, "max_points"))[0]


def shared_metadata(data, *, max_frames=MAX_FRAMES, max_points=MAX_POINTS):
    """Validate a chunk and return its CPU/time precision and source metadata."""
    return _decode(data, _limit(max_frames, "max_frames"),
                   _limit(max_points, "max_points"))[1]
