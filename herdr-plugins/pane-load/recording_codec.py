"""Experimental lossless sparse codec for process recording rows."""

FIELDS = {"seq", "wall_start_ns", "scan_start_ns", "scan_end_ns", "processes"}
NEW, MISSING, NAME, PPID, USER, SYSTEM, RSS, RETURN = 1, 2, 4, 8, 16, 32, 64, 128
KNOWN_MASK = NEW | MISSING | NAME | PPID | USER | SYSTEM | RSS | RETURN


def _integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{label} must be an integer")
    return value


def _checked_row(row):
    if not isinstance(row, dict) or set(row) != FIELDS:
        raise ValueError("row must contain exactly seq, wall_start_ns, scan_start_ns, scan_end_ns, processes")
    seq = _integer(row["seq"], "seq")
    wall = _integer(row["wall_start_ns"], "wall_start_ns")
    scan_start = _integer(row["scan_start_ns"], "scan_start_ns")
    scan_end = _integer(row["scan_end_ns"], "scan_end_ns")
    if scan_end < scan_start:
        raise ValueError("scan duration cannot be negative")
    processes = row["processes"]
    if not isinstance(processes, (list, tuple)):
        raise ValueError("processes must be a list")
    checked = []
    identities = set()
    for process in processes:
        if not isinstance(process, (list, tuple)) or len(process) != 8:
            raise ValueError("each process must contain eight fields")
        pid, ppid, startsec, startusec, name, user, system, rss = process
        numeric = [pid, ppid, startsec, startusec, user, system, rss]
        for value in numeric:
            _integer(value, "process number")
            if value < 0:
                raise ValueError("process numbers cannot be negative")
        if not isinstance(name, str):
            raise ValueError("process name must be a string")
        identity = (pid, startsec, startusec)
        if identity in identities:
            raise ValueError("duplicate process identity in row")
        identities.add(identity)
        checked.append([pid, ppid, startsec, startusec, name, user, system, rss])
    return {"seq": seq, "wall_start_ns": wall, "scan_start_ns": scan_start,
            "scan_end_ns": scan_end, "processes": checked}


def canonical_row(row):
    """Return a validated copy with processes sorted by stable process identity."""
    result = _checked_row(row)
    result["processes"].sort(key=lambda p: (p[0], p[2], p[3]))
    return result


def sparse_frames(rows):
    """Convert rows to compact array frames; state and slots are chunk-local."""
    frames = []
    slots = []
    by_identity = {}
    active = set()
    previous_seq = previous_wall = previous_scan = 0

    for raw in rows:
        row = canonical_row(raw)
        seq, wall, scan = row["seq"], row["wall_start_ns"], row["scan_start_ns"]
        duration = row["scan_end_ns"] - scan
        current = { (p[0], p[2], p[3]): p for p in row["processes"] }
        changes = []
        for identity in active - current.keys():
            changes.append([by_identity[identity], MISSING])

        next_active = set(current)
        for identity, process in current.items():
            slot = by_identity.get(identity)
            if slot is None:
                slot = len(slots)
                by_identity[identity] = slot
                slots.append(process[:])
                changes.append([slot, NEW, process[0], process[2], process[3],
                                process[1], process[4], process[5], process[6], process[7]])
                continue

            old = slots[slot]
            mask, payload = (RETURN if identity not in active else 0), []
            if process[4] != old[4]:
                mask |= NAME
                payload.append(process[4])
            if process[1] != old[1]:
                mask |= PPID
                payload.append(process[1] - old[1])
            for bit, index in ((USER, 5), (SYSTEM, 6), (RSS, 7)):
                if process[index] != old[index]:
                    mask |= bit
                    payload.append(process[index] - old[index])
            if mask:
                changes.append([slot, mask, *payload])
            slots[slot] = process[:]

        changes.sort(key=lambda change: change[0])
        frames.append([seq - previous_seq, wall - previous_wall,
                       scan - previous_scan, duration, changes])
        previous_seq, previous_wall, previous_scan = seq, wall, scan
        active = next_active
    return frames


def _frame_integer(value, signed, label):
    value = _integer(value, label)
    if not signed and value < 0:
        raise ValueError(f"{label} cannot be negative")
    return value


def restore_sparse(frames):
    """Restore canonical row dictionaries from sparse array frames."""
    try:
        iterator = iter(frames)
    except TypeError as exc:
        raise ValueError("frames must be iterable") from exc
    result = []
    slots = []
    by_identity = {}
    active = set()
    seq = wall = scan = 0
    for frame in iterator:
        if not isinstance(frame, (list, tuple)) or len(frame) != 5:
            raise ValueError("each frame must contain five fields")
        seq += _frame_integer(frame[0], True, "seq delta")
        wall += _frame_integer(frame[1], True, "wall delta")
        scan += _frame_integer(frame[2], True, "scan-start delta")
        duration = _frame_integer(frame[3], False, "duration")
        changes = frame[4]
        if not isinstance(changes, (list, tuple)):
            raise ValueError("frame changes must be a list")
        seen_slots = set()
        previous_slot = -1
        for change in changes:
            if not isinstance(change, (list, tuple)) or len(change) < 2:
                raise ValueError("change must contain slot and mask")
            slot = _frame_integer(change[0], False, "slot")
            mask = _frame_integer(change[1], False, "mask")
            if slot <= previous_slot:
                raise ValueError("changes must have unique slots in ascending order")
            seen_slots.add(slot)
            previous_slot = slot
            if mask == 0 or mask & ~KNOWN_MASK:
                raise ValueError("invalid change mask")
            if mask & NEW:
                if mask != NEW or slot != len(slots) or len(change) != 10:
                    raise ValueError("invalid new-process change")
                pid, startsec, startusec, ppid, name, user, system, rss = change[2:]
                numbers = [pid, startsec, startusec, ppid, user, system, rss]
                for value in numbers:
                    if _frame_integer(value, False, "new process number") < 0:
                        raise ValueError("new process number cannot be negative")
                if not isinstance(name, str):
                    raise ValueError("process name must be a string")
                identity = (pid, startsec, startusec)
                if identity in by_identity:
                    raise ValueError("process identity was allocated more than once")
                process = [pid, ppid, startsec, startusec, name, user, system, rss]
                by_identity[identity] = slot
                slots.append(process)
                active.add(slot)
                continue
            if mask & MISSING:
                if mask != MISSING or len(change) != 2 or slot >= len(slots) or slot not in active:
                    raise ValueError("invalid missing-process change")
                active.remove(slot)
                continue
            if slot >= len(slots):
                raise ValueError("change references unknown slot")
            returning = bool(mask & RETURN)
            if returning:
                if slot in active:
                    raise ValueError("RETURN requires an inactive process")
                active.add(slot)
            elif slot not in active:
                raise ValueError("inactive process update requires RETURN")
            process = slots[slot]
            offset = 2
            for bit, index, signed, label in (
                (NAME, 4, False, "name"), (PPID, 1, True, "ppid delta"),
                (USER, 5, True, "user delta"), (SYSTEM, 6, True, "system delta"),
                (RSS, 7, True, "rss delta"),
            ):
                if mask & bit:
                    if offset >= len(change):
                        raise ValueError("truncated change fields")
                    value = change[offset]
                    offset += 1
                    if bit == NAME:
                        if not isinstance(value, str):
                            raise ValueError("name update must be a string")
                        process[index] = value
                    else:
                        delta = _frame_integer(value, signed, label)
                        updated = process[index] + delta
                        if updated < 0:
                            raise ValueError("process number update becomes negative")
                        process[index] = updated
            if offset != len(change):
                raise ValueError("unexpected change fields")

        processes = [slots[slot][:] for slot in active]
        processes.sort(key=lambda p: (p[0], p[2], p[3]))
        result.append({"seq": seq, "wall_start_ns": wall, "scan_start_ns": scan,
                       "scan_end_ns": scan + duration, "processes": processes})
    return result


def _uvarint(value):
    if value < 0:
        raise ValueError("unsigned varint cannot encode negative values")
    output = bytearray()
    while value >= 0x80:
        output.append((value & 0x7f) | 0x80)
        value >>= 7
    output.append(value)
    return output


def _svarint(value):
    return _uvarint(value * 2 if value >= 0 else -value * 2 - 1)


def _read_uvarint(data, offset):
    value = shift = 0
    while offset < len(data):
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7f) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
    raise ValueError("truncated varint")


def _read_svarint(data, offset):
    value, offset = _read_uvarint(data, offset)
    return (value >> 1) ^ -(value & 1), offset


def _put_string(output, value):
    encoded = value.encode("utf-8")
    output.extend(_uvarint(len(encoded)))
    output.extend(encoded)


def _get_string(data, offset):
    length, offset = _read_uvarint(data, offset)
    end = offset + length
    if end > len(data):
        raise ValueError("truncated UTF-8 string")
    try:
        value = data[offset:end].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("invalid UTF-8 string") from exc
    return value, end


def encode_sparse(rows):
    """Encode rows as PSD1 header, frame count, then fixed-schema varints."""
    frames = sparse_frames(rows)
    output = bytearray(b"PSD1")
    output.extend(_uvarint(len(frames)))
    for seq_delta, wall_delta, scan_delta, duration, changes in frames:
        previous_slot = -1
        output.extend(_svarint(seq_delta))
        output.extend(_svarint(wall_delta))
        output.extend(_svarint(scan_delta))
        output.extend(_uvarint(duration))
        output.extend(_uvarint(len(changes)))
        for change in changes:
            slot, mask = change[:2]
            output.extend(_uvarint(slot - (previous_slot + 1)))
            output.extend(_uvarint(mask))
            previous_slot = slot
            if mask & NEW:
                for value in (change[2], change[3], change[4], change[5]):
                    output.extend(_uvarint(value))
                _put_string(output, change[6])
                for value in change[7:10]:
                    output.extend(_uvarint(value))
            elif not mask & MISSING:
                offset = 2
                for bit in (NAME, PPID, USER, SYSTEM, RSS):
                    if mask & bit:
                        value = change[offset]
                        offset += 1
                        if bit == NAME:
                            _put_string(output, value)
                        else:
                            output.extend(_svarint(value))
    return bytes(output)


def decode_sparse(data):
    """Decode PSD1 bytes; rejects malformed, truncated, and trailing data."""
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise ValueError("encoded data must be bytes-like")
    data = bytes(data)
    if len(data) < 4 or data[:4] != b"PSD1":
        raise ValueError("invalid PSD1 header")
    offset = 4
    frame_count, offset = _read_uvarint(data, offset)
    if frame_count > (len(data) - offset) // 5:
        raise ValueError("truncated frame list")
    frames = []
    for _ in range(frame_count):
        seq, offset = _read_svarint(data, offset)
        wall, offset = _read_svarint(data, offset)
        scan, offset = _read_svarint(data, offset)
        duration, offset = _read_uvarint(data, offset)
        count, offset = _read_uvarint(data, offset)
        if count > (len(data) - offset) // 2:
            raise ValueError("truncated changes list")
        changes = []
        previous_slot = -1
        for _ in range(count):
            gap, offset = _read_uvarint(data, offset)
            slot = previous_slot + gap + 1
            mask, offset = _read_uvarint(data, offset)
            if mask == 0 or mask & ~KNOWN_MASK or mask & NEW and mask != NEW or mask & MISSING and mask != MISSING:
                raise ValueError("invalid change mask")
            change = [slot, mask]
            if mask == NEW:
                values = []
                for _ in range(4):
                    value, offset = _read_uvarint(data, offset)
                    values.append(value)
                name, offset = _get_string(data, offset)
                for _ in range(3):
                    value, offset = _read_uvarint(data, offset)
                    values.append(value)
                change.extend((values[0], values[1], values[2], values[3], name,
                               values[4], values[5], values[6]))
            elif mask != MISSING:
                for bit in (NAME, PPID, USER, SYSTEM, RSS):
                    if mask & bit:
                        if bit == NAME:
                            value, offset = _get_string(data, offset)
                        else:
                            value, offset = _read_svarint(data, offset)
                        change.append(value)
            changes.append(change)
            previous_slot = slot
        frames.append([seq, wall, scan, duration, changes])
    if offset != len(data):
        raise ValueError("trailing bytes")
    return restore_sparse(frames)


def _event_int(value, label, nonnegative=False):
    value = _integer(value, label)
    if nonnegative and value < 0:
        raise ValueError(f"{label} cannot be negative")
    return value


def _event_vectors(events):
    try:
        events = iter(events)
    except TypeError as exc:
        raise ValueError("events must be iterable") from exc
    slots, vectors = {}, []
    for event in events:
        if not isinstance(event, dict) or not isinstance(event.get("type"), str):
            raise ValueError("invalid adaptive event")
        kind = event["type"]
        common = {"type", "identity"}
        identity = event.get("identity")
        if not isinstance(identity, (list, tuple)) or len(identity) != 3:
            raise ValueError("identity must contain pid and start fields")
        identity = tuple(_event_int(v, "identity field", True) for v in identity)
        if identity not in slots:
            slots[identity] = len(slots)
            vectors.append([0, slots[identity], *identity])
        slot = slots[identity]
        if kind == "sample":
            keys = common | {"seq", "wall_start_ns", "scan_start_ns", "scan_end_ns", "process"}
            if "reason" in event:
                keys.add("reason")
            if set(event) != keys:
                raise ValueError("invalid sample event fields")
            seq, wall, start, end = (_event_int(event[k], k) for k in
                ("seq", "wall_start_ns", "scan_start_ns", "scan_end_ns"))
            p = event["process"]
            if not isinstance(p, (list, tuple)) or len(p) != 8:
                raise ValueError("sample process must contain eight fields")
            pid, ppid, startsec, startusec, name, user, system, rss = p
            for value in (pid, startsec, startusec, ppid, user, system, rss):
                _event_int(value, "process field", True)
            if (pid, startsec, startusec) != identity or not isinstance(name, str):
                raise ValueError("sample process fields do not match identity")
            reason = event.get("reason", "")
            if not isinstance(reason, str) or ("reason" in event and not reason) or end < start:
                raise ValueError("invalid sample duration or reason")
            vectors.append([1,slot,seq,wall,start,end-start,ppid,name,user,system,rss,reason])
        elif kind == "summary":
            keys = common | {"first_seq", "last_seq", "first_wall_start_ns", "last_wall_start_ns",
                "first_scan_start_ns", "last_scan_start_ns", "first_scan_end_ns", "last_scan_end_ns",
                "metadata", "user_ns_start", "user_ns_end", "system_ns_start", "system_ns_end",
                "rss_min_bytes", "rss_max_bytes", "rss_end_bytes", "observations"}
            if set(event) != keys:
                raise ValueError("invalid summary event fields")
            m = event["metadata"]
            if not isinstance(m, (list, tuple)) or len(m) != 2 or not isinstance(m[1], str):
                raise ValueError("invalid summary metadata")
            values = [_event_int(event[k], k) for k in ("first_seq", "last_seq",
                "first_wall_start_ns", "last_wall_start_ns", "first_scan_start_ns",
                "last_scan_start_ns", "first_scan_end_ns", "last_scan_end_ns")]
            a,b,wa,wb,sa,sb,ea,eb = values
            counters = [_event_int(event[k], k, True) for k in ("user_ns_start", "user_ns_end",
                "system_ns_start", "system_ns_end", "rss_min_bytes", "rss_max_bytes",
                "rss_end_bytes", "observations")]
            ua,ub,ca,cb,lo,hi,rss,count = counters
            ppid = _event_int(m[0], "ppid", True)
            if (a > b or sa > sb or ea < sa or eb < sb or ea > eb or count == 0 or
                    lo > hi or not lo <= rss <= hi):
                raise ValueError("invalid summary bounds")
            vectors.append([2,slot,a,b,wa,wb,sa,sb,ea-sa,eb-sb,ppid,m[1],ua,ub,ca,cb,lo,hi,rss,count])
        elif kind == "not_observed":
            keys = common | {"seq", "wall_start_ns", "scan_start_ns", "scan_end_ns", "reason"}
            if set(event) != keys:
                raise ValueError("invalid not_observed event fields")
            seq,wall,start,end = (_event_int(event[k], k) for k in
                ("seq", "wall_start_ns", "scan_start_ns", "scan_end_ns"))
            if end < start or not isinstance(event["reason"], str):
                raise ValueError("invalid not_observed duration or reason")
            vectors.append([3,slot,seq,wall,start,end-start,event["reason"]])
        else:
            raise ValueError("unknown adaptive event")
    return vectors


def _restore_events(vectors):
    identities, events, declared = {}, [], set()
    for vector in vectors:
        kind, slot, *fields = vector
        if kind == 0:
            if (slot != len(identities) or len(fields) != 3 or
                    any(not isinstance(v, int) or v < 0 for v in fields)):
                raise ValueError("invalid event identity")
            identity = tuple(fields)
            if identity in declared:
                raise ValueError("duplicate event identity")
            declared.add(identity)
            identities[slot] = fields
            continue
        if slot not in identities:
            raise ValueError("unknown event identity")
        identity = identities[slot]
        event = {"identity":identity[:]}
        if kind in (1,3):
            seq, wall, start, duration, *rest = fields
            event.update(seq=seq,wall_start_ns=wall,scan_start_ns=start,scan_end_ns=start+duration)
            if kind == 1:
                ppid,name,user,system,rss,reason = rest
                if not isinstance(reason, str):
                    raise ValueError("sample reason must be a string")
                event.update(type="sample",process=[identity[0],ppid,identity[1],identity[2],
                                                    name,user,system,rss])
                if reason:
                    event["reason"] = reason
            else:
                event.update(type="not_observed",reason=rest[0])
        elif kind == 2:
            a,b,wa,wb,sa,sb,da,db,ppid,name,ua,ub,ca,cb,lo,hi,end,count = fields
            event.update(type="summary",first_seq=a,last_seq=b,first_wall_start_ns=wa,
                last_wall_start_ns=wb,first_scan_start_ns=sa,last_scan_start_ns=sb,
                first_scan_end_ns=sa+da,last_scan_end_ns=sb+db,metadata=[ppid,name],
                user_ns_start=ua,user_ns_end=ub,system_ns_start=ca,system_ns_end=cb,
                rss_min_bytes=lo,rss_max_bytes=hi,rss_end_bytes=end,observations=count)
        else:
            raise ValueError("unknown event kind")
        events.append(event)
    _event_vectors(events)
    return events


def _event_delta_key(kind, slot, index):
    # Timestamps are shared across processes; counters are identity-local.
    time_indexes = {1:range(2,6),2:range(2,10),3:range(2,6)}
    return (kind,index) if index in time_indexes.get(kind,()) else (kind,slot,index)


def encode_events(events):
    """Diagnostic flat typed vectors, with exact integer deltas (not fixed ABI)."""
    vectors = _event_vectors(events)
    output = bytearray(b"PAE1")
    output.extend(_uvarint(len(vectors)))
    previous = {}
    for vector in vectors:
        output.extend(_uvarint(len(vector)))
        kind, slot = vector[:2]
        for index, value in enumerate(vector):
            if isinstance(value, str):
                output.append(1); _put_string(output,value)
            else:
                value = _integer(value,"event value")
                output.append(0)
                if kind != 0 and index >= 2:
                    key = _event_delta_key(kind,slot,index)
                    old = previous.get(key,0)
                    previous[key] = value
                    value -= old
                output.extend(_svarint(value))
    return bytes(output)


def decode_events(data):
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise ValueError("encoded data must be bytes-like")
    data = bytes(data)
    if len(data) < 4 or data[:4] != b"PAE1":
        raise ValueError("invalid PAE1 header")
    count, offset = _read_uvarint(data,4)
    vectors, previous = [], {}
    for _ in range(count):
        length, offset = _read_uvarint(data,offset)
        if length not in (5,7,12,20):
            raise ValueError("invalid event vector length")
        vector = []
        for index in range(length):
            if offset >= len(data):
                raise ValueError("truncated event vector")
            tag, offset = data[offset], offset+1
            if tag == 1:
                value, offset = _get_string(data,offset)
            elif tag == 0:
                value, offset = _read_svarint(data,offset)
                if index >= 2 and vector[0] != 0:
                    key = _event_delta_key(vector[0],vector[1],index)
                    value += previous.get(key,0)
                    previous[key] = value
            else:
                raise ValueError("invalid event value tag")
            vector.append(value)
        kind = vector[0]
        if kind not in (0,1,2,3) or length != (5,12,20,7)[kind]:
            raise ValueError("invalid event kind/length")
        vectors.append(vector)
    if offset != len(data):
        raise ValueError("trailing event bytes")
    try:
        return _restore_events(vectors)
    except (TypeError,IndexError) as exc:
        raise ValueError("invalid event fields") from exc
