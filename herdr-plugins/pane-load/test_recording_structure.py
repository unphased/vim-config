import unittest

from recording_codec import _uvarint, canonical_row, encode_sparse
from recording_structure import decode_structure, encode_structure


def row(seq, wall, processes, scan=100):
    return {
        "seq": seq,
        "wall_start_ns": wall,
        "scan_start_ns": scan,
        "scan_end_ns": scan + 7,
        "processes": processes,
    }


def proc(pid, startsec, startusec=0, name="worker", ppid=1, rss=100,
         user=0, system=0):
    return [pid, ppid, startsec, startusec, name, user, system, rss]


def u(value):
    return bytes(_uvarint(value))


def svar(value):
    return u(value * 2 if value >= 0 else -value * 2 - 1)


def fixture(clock, total_points, identities, names, payload):
    return (b"PSS1" + u(len(clock)) + clock + u(total_points) +
            u(identities) + u(names) + payload)


class RecordingStructureTests(unittest.TestCase):
    def test_exact_round_trip_preserves_clock_identity_and_observation_coverage(self):
        rows = [
            row(3, 90_000, [proc(12, 5, 8, "old", ppid=2, rss=300),
                            proc(8, 5, 8, "same pid later", rss=4)]),
            row(9, 100_000, [proc(12, 5, 8, "new name", ppid=7, rss=80),
                             proc(44, 5, 10, "singleton", ppid=3, rss=0)]),
            row(25, 70_000, [proc(12, 5, 8, "new name", ppid=7, rss=20),
                             proc(8, 5, 8, "same pid later", rss=5)]),
        ]
        expected = [canonical_row(item) for item in rows]
        self.assertEqual(decode_structure(encode_structure(rows)), expected)

    def test_gap_is_by_row_ordinal_and_wall_clock_steps_are_exact(self):
        rows = [
            row(1, 700, [proc(2, 10, rss=8)], scan=500),
            row(50, 100, [], scan=2_000),
            row(99, 600, [proc(2, 10, rss=3)], scan=900),
        ]
        self.assertEqual(decode_structure(encode_structure(rows)),
                         [canonical_row(item) for item in rows])

    def test_independent_chunks_have_independent_baselines(self):
        first = [row(4, 100, [proc(1, 8, name="first", ppid=9, rss=900)])]
        second = [row(4, 100, [proc(1, 8, name="second", ppid=2, rss=4)])]
        self.assertEqual(decode_structure(encode_structure(first)),
                         [canonical_row(item) for item in first])
        self.assertEqual(decode_structure(encode_structure(second)),
                         [canonical_row(item) for item in second])

    def test_repeated_static_processes_use_columnar_compression(self):
        rows = []
        for frame in range(12):
            processes = [proc(pid, 1 + pid // 10, pid % 1_000_000,
                              name="shared", ppid=1, rss=64)
                         for pid in range(100, 200)]
            rows.append(row(frame * 3 + 2, frame * 1_000, processes,
                            scan=frame * 100))
        actual = encode_structure(rows)
        self.assertEqual(decode_structure(actual), [canonical_row(item) for item in rows])
        self.assertLess(len(actual), len(encode_sparse(rows)))

    def test_rejects_nonzero_cpu_and_invalid_source_identity(self):
        with self.assertRaises(ValueError):
            encode_structure([row(0, 0, [proc(1, 1, user=1)])])
        with self.assertRaises(ValueError):
            encode_structure([row(0, 0, [proc(1, 1, startusec=1_000_000)])])
        with self.assertRaises(ValueError):
            encode_structure([row(0, 0, [proc(1, 1, rss=-1)])])

    def test_rejects_bad_headers_counts_truncation_and_trailing_data(self):
        clock = encode_sparse([row(0, 0, [])])
        bad_count = fixture(clock, 1, 2, 0, b"")
        with self.assertRaises(ValueError):
            decode_structure(bad_count)

        valid = encode_structure([row(0, 0, [proc(1, 1)])])
        for malformed in (valid[:-1], valid + b"x", b"BAD!" + valid[4:]):
            with self.subTest(malformed=malformed[:8]):
                with self.assertRaises(ValueError):
                    decode_structure(malformed)

    def test_embedded_clock_rejects_process_payload_before_expansion(self):
        clock = encode_sparse([row(i, i, [proc(1, 1)]) for i in range(10)])
        with self.assertRaisesRegex(ValueError, 'clock.*process'):
            decode_structure(fixture(clock, 0, 0, 0, b''))

    def test_rejects_duplicate_wire_identity(self):
        clock = encode_sparse([row(0, 0, [])])
        # Each identity record has one point, one run, and only baseline fields.
        identity = (u(0) + svar(1) + u(1) + u(1) + u(0) + u(1) +
                    u(0) + u(0) + u(0))
        payload = u(0) + u(0) + identity + identity
        encoded = fixture(clock, 2, 2, 1, u(0) + u(0))
        # The name table above contains one empty UTF-8 name; append records.
        encoded += payload
        with self.assertRaises(ValueError):
            decode_structure(encoded)

    def test_rejects_rss_delta_that_becomes_negative(self):
        clock = encode_sparse([row(0, 0, []), row(1, 1, [])])
        # One identity observed twice; its RSS baseline is zero and its second
        # RSS sample is encoded as a -1 delta.
        identity = (u(0) + svar(1) + u(2) + u(1) + u(0) + u(2) +
                    u(0) + u(0) + u(0) + u(0) + u(1) + u(1) + svar(-1))
        encoded = fixture(clock, 2, 1, 1, u(0)) + identity
        with self.assertRaises(ValueError):
            decode_structure(encoded)

    def test_rejects_non_bytes_and_invalid_utf8_name(self):
        with self.assertRaises(ValueError):
            decode_structure("PSS1")
        clock = encode_sparse([row(0, 0, [])])
        # One invalid name dictionary entry; no identity records are needed.
        encoded = fixture(clock, 0, 0, 1, u(1) + b"\xff")
        with self.assertRaises(ValueError):
            decode_structure(encoded)


if __name__ == "__main__":
    unittest.main()
