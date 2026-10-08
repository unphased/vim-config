import unittest

from recording_codec import (
    canonical_row,
    decode_sparse,
    encode_sparse,
    restore_sparse,
    sparse_frames,
)


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


if __name__ == "__main__":
    unittest.main()
