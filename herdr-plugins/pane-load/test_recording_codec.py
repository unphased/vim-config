import unittest

from recording_codec import (
    canonical_row,
    decode_sparse,
    encode_sparse,
    restore_sparse,
    sparse_frames,
)


def _uvarint(value):
    output = bytearray()
    while value >= 0x80:
        output.append((value & 0x7f) | 0x80)
        value >>= 7
    output.append(value)
    return output


def _svarint(value):
    return _uvarint(value * 2 if value >= 0 else -value * 2 - 1)


def _pae1(vectors, bad_tag_at=None):
    """Build PAE1 bytes from typed vectors for malformed-wire tests."""
    output = bytearray(b"PAE1")
    output.extend(_uvarint(len(vectors)))
    previous = {}
    time_indexes = {1: range(2, 6), 2: range(2, 10), 3: range(2, 6)}
    for vector_index, vector in enumerate(vectors):
        output.extend(_uvarint(len(vector)))
        kind, slot = vector[:2]
        for index, value in enumerate(vector):
            if isinstance(value, str):
                tag, encoded = 1, value.encode("utf-8")
                output.append(tag)
                output.extend(_uvarint(len(encoded)))
                output.extend(encoded)
            else:
                output.append(7 if bad_tag_at == (vector_index, index) else 0)
                if kind != 0 and index >= 2:
                    key = ((kind, index) if index in time_indexes[kind]
                           else (kind, slot, index))
                    old = previous.get(key, 0)
                    previous[key] = value
                    value -= old
                output.extend(_svarint(value))
    return bytes(output)


def row(seq, wall, scan_start, processes=(), duration=10):
    return {
        "seq": seq,
        "wall_start_ns": wall,
        "scan_start_ns": scan_start,
        "scan_end_ns": scan_start + duration,
        "processes": [list(process) for process in processes],
    }


class RecordingCodecTests(unittest.TestCase):
    def test_exact_roundtrip_and_canonical_order(self):
        rows = [
            row(4, 900, 100, [(20, 2, 3, 4, "λ", 50, 60, 70), (10, 1, 2, 3, "雪", 4, 5, 6)]),
            row(7, 850, 130, [(10, 1, 2, 3, "雪", 4, 5, 6), (20, 9, 3, 4, "λ🦊", 45, 62, 72)], 12),
        ]
        expected = [dict(item, processes=sorted(item["processes"], key=lambda p: (p[0], p[2], p[3]))) for item in rows]
        self.assertEqual(canonical_row(rows[0]), expected[0])
        self.assertEqual(restore_sparse(sparse_frames(rows)), expected)
        self.assertEqual(decode_sparse(encode_sparse(rows)), expected)

    def test_unchanged_processes_are_sparse(self):
        snapshot = row(0, 1000, 2000, [(1, 0, 10, 20, "shell", 30, 40, 50)])
        rows = [dict(snapshot, seq=i, wall_start_ns=1000 + i, scan_start_ns=2000 + i,
                     scan_end_ns=2010 + i) for i in range(100)]
        self.assertLess(len(encode_sparse(rows)), len(repr(rows).encode()))
        self.assertEqual(decode_sparse(encode_sparse(rows)), rows)
        frames = sparse_frames(rows)
        self.assertTrue(all(frame[4] == [] for frame in frames[1:]))

    def test_pid_reuse_gets_new_identity_slot(self):
        rows = [row(0, 0, 0, [(42, 1, 100, 0, "old", 1, 2, 3)]),
                row(1, 1, 1, [(42, 1, 101, 0, "new", 0, 0, 0)])]
        frames = sparse_frames(rows)
        self.assertEqual([change[:2] for change in frames[1][4]], [[0, 2], [1, 1]])
        self.assertEqual(decode_sparse(encode_sparse(rows)), rows)

    def test_missing_return_and_cached_values(self):
        proc = (1, 2, 3, 4, "proc", 5, 6, 7)
        rows = [row(0, 10, 20, [proc]), row(1, 11, 21), row(2, 12, 22, [proc])]
        frames = sparse_frames(rows)
        self.assertEqual(frames[1][4], [[0, 2]])
        self.assertEqual(frames[2][4], [[0, 128]])
        self.assertEqual(decode_sparse(encode_sparse(rows)), rows)

    def test_single_field_updates_resets_and_backward_clock(self):
        original = (5, 1, 2, 3, "a", 100, 200, 300)
        changed = (5, 9, 2, 3, "β", 90, 205, 299)
        rows = [row(10, 1000, 100, [original]), row(11, 900, 95, [changed])]
        frame = sparse_frames(rows)[1]
        self.assertEqual(frame[:4], [1, -100, -5, 10])
        self.assertEqual(frame[4], [[0, 4 | 8 | 16 | 32 | 64, "β", 8, -10, 5, -1]])
        self.assertEqual(decode_sparse(encode_sparse(rows)), rows)

    def test_arbitrary_precision_integers_are_lossless(self):
        huge = 1 << 180
        rows = [row(huge, -huge, huge, [(huge, huge - 1, huge - 2, huge - 3,
                                         "大きなプロセス", huge, huge + 1, huge + 2)], huge + 4)]
        self.assertEqual(decode_sparse(encode_sparse(rows)), rows)

    def test_chunks_are_independent(self):
        rows = [row(8, 100, 200, [(2, 1, 3, 4, "x", 5, 6, 7)]),
                row(9, 101, 201, [(2, 1, 3, 4, "x", 5, 6, 7)])]
        one, two = rows[:1], rows[1:]
        self.assertEqual(decode_sparse(encode_sparse(one)), one)
        self.assertEqual(decode_sparse(encode_sparse(two)), two)

    def test_deterministic_ordering(self):
        a = row(0, 0, 0, [(9, 1, 1, 1, "z", 1, 1, 1), (2, 1, 1, 1, "b", 1, 1, 1)])
        b = row(0, 0, 0, list(reversed(a["processes"])))
        self.assertEqual(sparse_frames([a]), sparse_frames([b]))
        self.assertEqual(encode_sparse([a]), encode_sparse([b]))

    def test_rejects_invalid_rows(self):
        invalid = [
            row(0, 0, 0, [(-1, 0, 0, 0, "x", 0, 0, 0)]),
            row(0, 0, 0, [(1, 0, 0, 0, "x", 0, 0, 0), (1, 0, 0, 0, "y", 0, 0, 0)]),
            row(0, 0, 2, [], -1),
            {"seq": 0, "wall_start_ns": 0, "scan_start_ns": 0, "scan_end_ns": 0, "processes": [], "extra": 1},
        ]
        for item in invalid:
            with self.subTest(item=item), self.assertRaises(ValueError):
                sparse_frames([item])

    def test_binary_rejects_bad_header_truncation_trailing_and_bad_masks(self):
        payload = encode_sparse([row(0, 0, 0)])
        for malformed in (b"NOPE" + payload[4:], payload[:-1], payload + b"x"):
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                decode_sparse(malformed)
        # PSD1, one frame, zero deltas/duration, one change, gap=0, unknown mask bit.
        with self.assertRaises(ValueError):
            decode_sparse(b"PSD1\x01\x00\x00\x00\x00\x01\x00\x00")

    def test_binary_rejects_bad_references_and_duplicate_identity(self):
        # A missing change cannot reference slot zero before it has been created.
        with self.assertRaises(ValueError):
            decode_sparse(b"PSD1\x01\x00\x00\x00\x00\x01\x00\x02")
        duplicate = row(0, 0, 0, [(1, 0, 2, 3, "a", 0, 0, 0), (1, 0, 2, 3, "b", 0, 0, 0)])
        with self.assertRaises(ValueError):
            encode_sparse([duplicate])


class AdaptiveWireTests(unittest.TestCase):
    def test_adaptive_events_roundtrip_including_delayed_summaries(self):
        from recording_adaptive import adaptive_records
        from recording_codec import encode_events, decode_events
        rows = []
        for seq in range(100):
            cpu = min(max(seq - 10, 0), 50) * 50_000_000
            rows.append({"seq":seq,"wall_start_ns":10**18+seq*100_000_000,
                         "scan_start_ns":seq*100_000_000,"scan_end_ns":seq*100_000_000+10,
                         "processes":[[10,1,2,3,"worker",cpu,seq,1000]]})
        events = list(adaptive_records(rows, pre_seconds=.2, post_seconds=.2, summary_seconds=1))
        self.assertTrue(any(e["type"] == "summary" for e in events))
        self.assertEqual(decode_events(encode_events(events)), events)

    def test_adaptive_events_reject_corruption(self):
        from recording_codec import encode_events, decode_events
        data = encode_events([])
        for bad in [b"", data[:-1], data+b"x", b"PAE1\\x01\\x01\\xff"]:
            with self.assertRaises(ValueError):
                decode_events(bad)

    def test_adaptive_wire_rejects_invalid_field_schemas(self):
        from recording_codec import decode_events
        identity = [0, 0, 1, 2, 3]
        sample = [1, 0, 10, 20, 30, 5, 4, "x", 1, 2, 3, "birth"]
        summary = [2, 0, 1, 2, 100, 200, 10, 20, 5, 6, 3, "x", 1, 2,
                   3, 4, 5, 8, 7, 2]
        missing = [3, 0, 10, 20, 30, 5, "missing"]
        invalid = [
            [[0, 0, -1, 2, 3]],
            [identity, sample[:2] + ["10"] + sample[3:]],
            [identity, sample[:5] + [-1] + sample[6:]],
            [identity, sample[:6] + [-1] + sample[7:]],
            [identity, sample[:7] + [1] + sample[8:]],
            [identity, sample[:8] + [-1] + sample[9:]],
            [identity, sample[:11] + [4]],
            [identity, summary[:2] + [2, 1] + summary[4:]],
            [identity, summary[:8] + [-1] + summary[9:]],
            [identity, summary[:12] + [-1] + summary[13:]],
            [identity, summary[:16] + [9] + summary[17:]],
            [identity, summary[:19] + [0]],
            [identity, missing[:6] + [3]],
            [identity, sample, [0, 1, 1, 2, 3]],
            [sample],  # referenced identity has not been declared
        ]
        for vectors in invalid:
            with self.subTest(vectors=vectors), self.assertRaises(ValueError):
                decode_events(_pae1(vectors))
        with self.assertRaises(ValueError):
            decode_events(_pae1([identity, sample], bad_tag_at=(1, 2)))

    def test_encode_events_rejects_invalid_inputs(self):
        from copy import deepcopy
        from recording_codec import encode_events
        valid = {"type": "sample", "identity": [1, 2, 3], "seq": 10,
                 "wall_start_ns": 20, "scan_start_ns": 30, "scan_end_ns": 35,
                 "process": [1, 4, 2, 3, "x", 5, 6, 7]}
        invalid = []
        for key, value in (("seq", 1.5), ("wall_start_ns", "20"),
                           ("scan_end_ns", 29), ("reason", 7), ("extra", 1)):
            event = deepcopy(valid)
            event[key] = value
            invalid.append([event])
        event = deepcopy(valid)
        event["identity"] = [1, 2, -3]
        invalid.append([event])
        event = deepcopy(valid)
        event["process"][5] = -1
        invalid.append([event])
        event = deepcopy(valid)
        event["process"][4] = 4
        invalid.append([event])
        for events in invalid:
            with self.subTest(events=events), self.assertRaises(ValueError):
                encode_events(events)


if __name__ == "__main__":
    unittest.main()
