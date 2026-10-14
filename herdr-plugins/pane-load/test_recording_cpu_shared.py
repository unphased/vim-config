import unittest

from recording_codec import _read_uvarint, _uvarint
from recording_cpu_shared import (
    MAX_FRAMES,
    MAX_POINTS,
    decode_shared,
    encode_shared,
    shared_metadata,
)


class SharedCpuTests(unittest.TestCase):
    def test_zero_cpu_singletons_share_the_clock_axis_and_keep_identity(self):
        series = {
            (91, 4, 2): [(0, 0, 10), (1, 0, 20), (2, 0, 30)],
            (15, 7, 3): [(0, 0, 10), (2, 0, 30)],
            (700, 0, 0): [(1, 0, 20)],
            (800, 1, 0): [(3, 0, 40)],
        }
        encoded = encode_shared(series)
        self.assertEqual(decode_shared(encoded), series)
        metadata = shared_metadata(encoded)
        self.assertEqual(metadata["cpu_timebase"], (125, 3))
        self.assertTrue(metadata["cpu_exact"])
        self.assertEqual(metadata["cpu_component"], "user+system total; split not preserved")
        # Axis is shared: raw encoding grows by one frame entry, not once per identity.
        separate = sum(len(encode_shared({identity: samples})) for identity, samples in series.items())
        self.assertLess(len(encoded), separate)

    def test_partial_lifespans_gaps_and_selected_points_are_not_filled(self):
        series = {
            (1, 10, 0): [(2, 0, 200), (4, 7, 400), (7, 7, 700)],
            (2, 11, 0): [(1, 3, 100), (7, 11, 700)],
            (3, 12, 0): [(5, 19, 500)],
        }
        for layout in ("changes", "points"):
            with self.subTest(layout=layout):
                self.assertEqual(decode_shared(encode_shared(series, layout=layout)), series)

    def test_quantized_cpu_carries_across_small_increments_and_keeps_endpoints(self):
        source = {
            (42, 9, 1): [(0, 29, 100), (1, 31, 200), (2, 38, 300), (3, 40, 400)],
            (43, 9, 2): [(1, 7, 200), (2, 12, 300)],
        }
        for layout in ("changes", "points"):
            encoded = encode_shared(source, layout=layout, quantum=10,
                                    cpu_timebase=(125, 3))
            decoded = decode_shared(encoded)
            self.assertEqual([decoded[(42, 9, 1)][0][1], decoded[(42, 9, 1)][-1][1]], [29, 40])
            for identity, samples in source.items():
                restored = decoded[identity]
                self.assertEqual([item[0] for item in restored], [item[0] for item in samples])
                self.assertEqual([item[2] for item in restored], [item[2] for item in samples])
                cpus = [item[1] for item in restored]
                self.assertEqual(cpus, sorted(cpus))
                self.assertEqual(cpus[0], samples[0][1])
                self.assertEqual(cpus[-1], samples[-1][1])
                self.assertTrue(all(abs(actual - approximate) < 10
                                    for (_, actual, _), (_, approximate, _) in zip(samples, restored)))
            metadata = shared_metadata(encoded)
            self.assertEqual(metadata["quantum"], 10)
            self.assertFalse(metadata["cpu_exact"])
            self.assertEqual(metadata["cpu_estimate"], "floor-with-exact-endpoints")

    def test_clock_unit_is_exact_and_native_cpu_timebase_is_metadata(self):
        source = {(5, 6, 7): [(3, 100, 120), (5, 105, 180)]}
        data = encode_shared(source, clock_unit_ns=20, cpu_timebase=(125, 3))
        self.assertEqual(decode_shared(data), source)
        self.assertEqual(shared_metadata(data)["clock_exact"], True)
        with self.assertRaisesRegex(ValueError, "divisible"):
            encode_shared({(5, 6, 7): [(0, 1, 11)]}, clock_unit_ns=10)

    def test_chunks_are_independently_decodable_without_cross_chunk_state(self):
        identity = (25, 5, 1)
        first = {identity: [(10, 90, 1000), (11, 95, 1100)]}
        second = {identity: [(20, 3, 2000), (21, 9, 2100)]}
        for chunk in (first, second):
            encoded = encode_shared(chunk, quantum=4)
            self.assertEqual(decode_shared(encoded)[identity], chunk[identity])

    def test_malformed_header_counts_truncation_trailing_and_limits(self):
        encoded = encode_shared({(1, 0, 0): [(0, 0, 1), (2, 3, 3)]})
        with self.assertRaises(ValueError):
            decode_shared(encoded[:-1])
        with self.assertRaisesRegex(ValueError, "trailing"):
            decode_shared(encoded + b"x")
        with self.assertRaisesRegex(ValueError, "frame limit"):
            decode_shared(encoded, max_frames=1)
        with self.assertRaisesRegex(ValueError, "point limit"):
            decode_shared(encoded, max_points=1)
        with self.assertRaisesRegex(ValueError, "frame limit"):
            decode_shared(_replace_header_count(encoded, 0, MAX_FRAMES + 1))
        with self.assertRaisesRegex(ValueError, "point limit"):
            decode_shared(_replace_header_count(encoded, 2, MAX_POINTS + 1))

    def test_duplicate_identities_and_duplicate_positions_are_rejected(self):
        duplicate = encode_shared({
            (1, 0, 0): [(0, 0, 10)],
            (2, 0, 0): [(0, 0, 10)],
        })
        identity_start = _identity_start(duplicate)
        second_pid_offset = _skip_identity(duplicate, identity_start)
        # The second identity's pid is one one-byte varint; replace it with the first pid.
        malformed = duplicate[:second_pid_offset] + b"\x01" + duplicate[second_pid_offset + 1:]
        with self.assertRaisesRegex(ValueError, "duplicate identity"):
            decode_shared(malformed)

        points = encode_shared({(1, 0, 0): [(0, 1, 10), (1, 2, 20)]}, layout="points")
        # In points layout the second frame-position delta follows the first one.
        positions = _identity_start(points) + 4  # pid, startsec, startusec, point count
        positions += 1  # first frame position delta
        malformed = points[:positions] + b"\x00" + points[positions + 1:]
        with self.assertRaisesRegex(ValueError, "frame positions"):
            decode_shared(malformed)

    def test_sparse_coverage_can_decode_more_points_than_payload_bytes(self):
        source={(pid,0,0):[(i,0,i+1) for i in range(100)] for pid in range(100)}
        data=encode_shared(source)
        self.assertLess(len(data),10000)
        self.assertEqual(decode_shared(data),source)

    def test_encode_rejects_bad_series_and_decode_rejects_noncanonical_varints(self):
        bad = [
            {(True, 0, 0): [(0, 1, 1)]},
            {(1, 0, 0): [(0, 1, 2), (0, 2, 3)]},
            {(1, 0, 0): [(0, 3, 2), (1, 2, 3)]},
            {(1, 0, 0): [(0, 1, 3), (1, 2, 2)]},
            {(1, 0, 0): [(0, 1, 1)], (2, 0, 0): [(0, 1, 2)]},
        ]
        for source in bad:
            with self.subTest(source=source), self.assertRaises(ValueError):
                encode_shared(source)
        encoded = encode_shared({(1, 0, 0): [(0, 0, 1)]})
        # Header's quantum is encoded as the single canonical byte 1.
        malformed = encoded[:5] + b"\x81\x00" + encoded[6:]
        with self.assertRaisesRegex(ValueError, "canonical"):
            decode_shared(malformed)
        for kwargs in ({"quantum": 0}, {"quantum": True}, {"layout": "unknown"},
                       {"cpu_timebase": (1, 0)}, {"clock_unit_ns": 0}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                encode_shared({(1, 0, 0): [(0, 0, 1)]}, **kwargs)


def _header_offsets(data):
    """Return offsets for the three header counts: frames, identities, points."""
    offset = 5  # magic + layout byte
    for _ in range(4):  # quantum, clock unit, timebase numerator, denominator
        _, offset = _read_uvarint(data, offset)
    offsets = []
    for _ in range(3):
        offsets.append(offset)
        _, offset = _read_uvarint(data, offset)
    return offsets, offset


def _replace_header_count(data, field, value):
    offsets, _ = _header_offsets(data)
    start = offsets[field]
    _, end = _read_uvarint(data, start)
    return data[:start] + bytes(_uvarint(value)) + data[end:]


def _identity_start(data):
    # Axis stores seq and clock deltas as pairs after ALL three header counts.
    offsets, axis_offset = _header_offsets(data)
    frame_count, _ = _read_uvarint(data, offsets[0])
    for _ in range(frame_count * 2):
        _, axis_offset = _read_uvarint(data, axis_offset)
    return axis_offset


def _skip_identity(data, offset):
    for _ in range(3):
        _, offset = _read_uvarint(data, offset)
    count, offset = _read_uvarint(data, offset)
    runs, offset = _read_uvarint(data, offset)
    for _ in range(2*runs):
        _, offset = _read_uvarint(data, offset)
    _, offset = _read_uvarint(data, offset)  # baseline quotient
    changes, offset = _read_uvarint(data, offset)
    for _ in range(2*changes+2):  # changes + endpoint remainders
        _, offset = _read_uvarint(data, offset)
    return offset


if __name__ == "__main__":
    unittest.main()
