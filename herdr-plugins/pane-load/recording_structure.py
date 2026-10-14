"""Lossless columnar codec for zero-CPU process recordings."""

from recording_codec import _read_uvarint, _uvarint, canonical_row, encode_sparse

MAGIC = b"PSS1"
MAX_FRAMES = MAX_POINTS = MAX_IDENTITIES = 1_000_000
_MAX_VARINT_BYTES = 64


def _put_u(output, value):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value.bit_length() > 7 * _MAX_VARINT_BYTES:
        raise ValueError("unsigned value outside wire range")
    output.extend(_uvarint(value))


def _zigzag(value):
    return value * 2 if value >= 0 else -value * 2 - 1


def _unzigzag(value):
    return (value >> 1) ^ -(value & 1)


def _put_s(output, value):
    _put_u(output, _zigzag(value))


def _read(data, offset):
    start = offset
    try:
        value, end = _read_uvarint(data[:min(len(data), offset + _MAX_VARINT_BYTES + 1)], offset)
    except (ValueError, IndexError) as exc:
        raise ValueError("truncated or oversized varint") from exc
    if end - start > _MAX_VARINT_BYTES or bytes(_uvarint(value)) != bytes(data[start:end]):
        raise ValueError("noncanonical varint")
    return value, end


def _read_s(data, offset):
    value, offset = _read(data, offset)
    return _unzigzag(value), offset


def _column(output, events, baseline_frame, signed=False):
    _put_u(output, len(events))
    previous = baseline_frame
    for frame, _ in events:
        _put_u(output, frame - previous)
        previous = frame
    for _, value in events:
        (_put_s if signed else _put_u)(output, value)


def _runs(frames):
    result = []
    for frame in frames:
        if result and frame == result[-1][0] + result[-1][1]:
            start, length = result[-1]
            result[-1] = (start, length + 1)
        else:
            result.append((frame, 1))
    return result


def encode_structure(rows):
    """Encode canonical rows with user/system CPU fields equal to zero."""
    try:
        iterator = iter(rows)
    except TypeError as exc:
        raise ValueError("rows must be iterable") from exc

    checked_rows, observations, all_names = [], {}, set()
    total_points = 0
    for raw in iterator:
        if len(checked_rows) >= MAX_FRAMES:
            raise ValueError("frame limit exceeded")
        row = canonical_row(raw)
        frame = len(checked_rows)
        for process in row["processes"]:
            if process[5] != 0 or process[6] != 0:
                raise ValueError("structure codec requires zero user and system CPU")
            if process[3] > 999_999:
                raise ValueError("start_usec must be in 0..999999")
            identity = (process[0], process[2], process[3])
            observations.setdefault(identity, []).append((frame, process))
            all_names.add(process[4])
            total_points += 1
            if total_points > MAX_POINTS:
                raise ValueError("point limit exceeded")
        checked_rows.append(row)

    identities = sorted(observations, key=lambda item: (item[1], item[2], item[0]))
    if len(identities) > MAX_IDENTITIES:
        raise ValueError("identity limit exceeded")
    names = sorted(all_names)
    name_index = {name: index for index, name in enumerate(names)}
    clock = encode_sparse([{key: value for key, value in row.items() if key != "processes"}
                           | {"processes": []} for row in checked_rows])

    output = bytearray(MAGIC)
    _put_u(output, len(clock))
    output.extend(clock)
    _put_u(output, total_points)
    _put_u(output, len(identities))
    _put_u(output, len(names))
    for name in names:
        try:
            encoded = name.encode("utf-8")
        except UnicodeEncodeError as exc:
            raise ValueError("process name is not valid UTF-8") from exc
        _put_u(output, len(encoded))
        output.extend(encoded)

    previous_start = previous_pid = 0
    for identity in identities:
        pid, startsec, startusec = identity
        start = startsec * 1_000_000 + startusec
        _put_u(output, start - previous_start)
        _put_s(output, pid - previous_pid)
        previous_start, previous_pid = start, pid

        samples = observations[identity]
        indices = [frame for frame, _ in samples]
        _put_u(output, len(samples))
        runs = _runs(indices)
        _put_u(output, len(runs))
        previous_end = 0
        for start_frame, length in runs:
            _put_u(output, start_frame - previous_end)
            _put_u(output, length)
            previous_end = start_frame + length

        first = samples[0][1]
        _put_u(output, name_index[first[4]])
        _put_u(output, first[1])
        _put_u(output, first[7])
        changes = [[], [], []]
        previous = first
        for frame, process in samples[1:]:
            if process[4] != previous[4]:
                changes[0].append((frame, name_index[process[4]]))
            if process[1] != previous[1]:
                changes[1].append((frame, process[1] - previous[1]))
            if process[7] != previous[7]:
                changes[2].append((frame, process[7] - previous[7]))
            previous = process
        baseline_frame = indices[0]
        _column(output, changes[0], baseline_frame)
        _column(output, changes[1], baseline_frame, signed=True)
        _column(output, changes[2], baseline_frame, signed=True)
    return bytes(output)


def _column_read(data, offset, baseline, point_count, frame_count, covered, signed=False):
    count, offset = _read(data, offset)
    if count > point_count - 1:
        raise ValueError("event count exceeds identity coverage")
    positions, frame = [], baseline
    for _ in range(count):
        gap, offset = _read(data, offset)
        if gap == 0:
            raise ValueError("event positions must increase")
        frame += gap
        if frame >= frame_count or frame not in covered:
            raise ValueError("event position outside identity coverage")
        positions.append(frame)
    events = []
    for frame in positions:
        value, offset = (_read_s if signed else _read)(data, offset)
        events.append((frame, value))
    return events, offset


def _decode_clock(data):
    """Parse only clock fields: reject process changes before any expansion."""
    if len(data) < 5 or bytes(data[:4]) != b'PSD1':
        raise ValueError('invalid shared clock')
    count, offset = _read(data, 4)
    if count > MAX_FRAMES or count > (len(data) - offset) // 5:
        raise ValueError('frame limit exceeded or truncated shared clock')
    rows = []
    seq = wall = scan = 0
    for _ in range(count):
        ds, offset = _read_s(data, offset)
        dw, offset = _read_s(data, offset)
        dt, offset = _read_s(data, offset)
        duration, offset = _read(data, offset)
        changes, offset = _read(data, offset)
        if changes:
            raise ValueError('shared clock must not contain process changes')
        seq += ds
        wall += dw
        scan += dt
        rows.append({'seq': seq, 'wall_start_ns': wall, 'scan_start_ns': scan,
                     'scan_end_ns': scan + duration, 'processes': []})
    if offset != len(data):
        raise ValueError('trailing shared clock bytes')
    return rows


def decode_structure(encoded):
    """Decode PSS1 bytes to validated canonical rows; rejects malformed input."""
    if not isinstance(encoded, (bytes, bytearray, memoryview)):
        raise ValueError("encoded data must be bytes-like")
    try:
        data = memoryview(encoded).cast("B")
    except (TypeError, ValueError) as exc:
        raise ValueError("encoded data must be contiguous bytes-like data") from exc
    if len(data) < 4 or bytes(data[:4]) != MAGIC:
        raise ValueError("invalid PSS1 header")
    offset = 4
    clock_length, offset = _read(data, offset)
    if clock_length > len(data) - offset:
        raise ValueError("truncated clock blob")
    clock_end = offset + clock_length
    clock_data = data[offset:clock_end]
    offset = clock_end
    rows = _decode_clock(clock_data)
    frame_count = len(rows)

    total_points, offset = _read(data, offset)
    identity_count, offset = _read(data, offset)
    name_count, offset = _read(data, offset)
    if total_points > MAX_POINTS or identity_count > MAX_IDENTITIES:
        raise ValueError("point or identity limit exceeded")
    if identity_count > total_points or name_count > total_points:
        raise ValueError("impossible structure counts")

    names, previous_name = [], None
    for _ in range(name_count):
        length, offset = _read(data, offset)
        if length > len(data) - offset:
            raise ValueError("truncated name")
        try:
            name = bytes(data[offset:offset + length]).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError("invalid UTF-8 name") from exc
        offset += length
        if previous_name is not None and name <= previous_name:
            raise ValueError("duplicate or unsorted name dictionary")
        names.append(name)
        previous_name = name

    decoded_by_frame = [[] for _ in range(frame_count)]
    previous_start = previous_pid = 0
    observed_total = 0
    previous_identity = None
    for _ in range(identity_count):
        start_delta, offset = _read(data, offset)
        pid_delta, offset = _read_s(data, offset)
        start = previous_start + start_delta
        pid = previous_pid + pid_delta
        previous_start, previous_pid = start, pid
        if start.bit_length() > 7 * _MAX_VARINT_BYTES or pid < 0 or pid.bit_length() > 7 * _MAX_VARINT_BYTES:
            raise ValueError("invalid process identity")
        startsec, startusec = divmod(start, 1_000_000)
        identity = (start, pid)
        if previous_identity is not None and identity <= previous_identity:
            raise ValueError("duplicate or unsorted process identity")
        previous_identity = identity

        point_count, offset = _read(data, offset)
        run_count, offset = _read(data, offset)
        if point_count == 0 or point_count > frame_count or run_count == 0 or run_count > point_count:
            raise ValueError("invalid identity coverage counts")
        if observed_total + point_count > total_points:
            raise ValueError("identity points exceed declared total")
        indices, previous_end = [], 0
        for run_index in range(run_count):
            gap, offset = _read(data, offset)
            length, offset = _read(data, offset)
            start_frame = previous_end + gap
            end_frame = start_frame + length
            if length == 0 or end_frame > frame_count or (run_index and gap == 0):
                raise ValueError("invalid coverage run")
            if len(indices) + length > point_count:
                raise ValueError("coverage exceeds declared point count")
            indices.extend(range(start_frame, end_frame))
            previous_end = end_frame
        if len(indices) != point_count:
            raise ValueError("coverage point count mismatch")
        covered = set(indices)
        baseline_frame = indices[0]
        name_id, offset = _read(data, offset)
        ppid, offset = _read(data, offset)
        rss, offset = _read(data, offset)
        if name_id >= len(names):
            raise ValueError("unknown baseline name")
        name_events, offset = _column_read(data, offset, baseline_frame, point_count,
                                           frame_count, covered)
        ppid_events, offset = _column_read(data, offset, baseline_frame, point_count,
                                           frame_count, covered, signed=True)
        rss_events, offset = _column_read(data, offset, baseline_frame, point_count,
                                          frame_count, covered, signed=True)
        events = {}
        for field, column in enumerate((name_events, ppid_events, rss_events)):
            for frame, value in column:
                events.setdefault(frame, [None, None, None])[field] = value

        for frame in indices:
            update = events.get(frame)
            if update is not None:
                if update[0] is not None:
                    if update[0] >= len(names):
                        raise ValueError("unknown name update")
                    name_id = update[0]
                if update[1] is not None:
                    ppid += update[1]
                if update[2] is not None:
                    rss += update[2]
                if ppid < 0 or rss < 0:
                    raise ValueError("process number update becomes negative")
            decoded_by_frame[frame].append([pid, ppid, startsec, startusec,
                                            names[name_id], 0, 0, rss])
        observed_total += point_count
    if observed_total != total_points:
        raise ValueError("declared total point count mismatch")
    if offset != len(data):
        raise ValueError("trailing bytes")
    for index, row in enumerate(rows):
        row["processes"] = decoded_by_frame[index]
        row["processes"].sort(key=lambda process: (process[0], process[2], process[3]))
        rows[index] = canonical_row(row)
    return rows
