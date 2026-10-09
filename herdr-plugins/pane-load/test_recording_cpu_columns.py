import unittest

from recording_cpu_columns import encode_series, decode_series, quantize_cumulative


LAYOUTS = ("interleaved", "columns", "runs", "grouped", "both-runs")
CODECS = ("uvarint", "uint64le")


def series_from_deltas(cpu_deltas, periods, cpu0=17, time0=100):
    cpu = [cpu0]
    times = [time0]
    for dcpu, dt in zip(cpu_deltas, periods):
        cpu.append(cpu[-1] + dcpu)
        times.append(times[-1] + dt)
    return cpu, times


class CpuSeriesTests(unittest.TestCase):
    def assert_roundtrip(self, cpu_deltas, periods, cpu0=17, time0=100):
        cpu, times = series_from_deltas(cpu_deltas, periods, cpu0, time0)
        for layout in LAYOUTS:
            for codec in CODECS:
                with self.subTest(layout=layout, codec=codec):
                    encoded = encode_series(cpu, times, layout, codec)
                    self.assertEqual(decode_series(encoded), (cpu, times))
                    self.assertEqual(encode_series(cpu, times, layout, codec), encoded)

    def test_example_runs_and_stable_cadence(self):
        self.assert_roundtrip([1, 10, 20, 12, 1, 0, 5], [2, 2, 2, 2, 4, 4, 4])
        self.assert_roundtrip([0] * 7, [5] * 7, cpu0=0, time0=0)

    def test_variable_cadence_including_a_b_a(self):
        self.assert_roundtrip([2, 0, 7, 3, 1, 9], [3, 8, 3, 8, 8, 3])

    def test_baseline_gaps_and_multicore_cpu_delta(self):
        self.assert_roundtrip([0, 2_000_000_000, 4], [3, 7, 1], cpu0=900, time0=50_000)

    def test_arbitrary_precision_varints_and_uint64_bounds(self):
        huge = 1 << 100
        cpu, times = series_from_deltas([huge, 1], [huge + 2, 3], cpu0=huge, time0=huge)
        self.assertEqual(decode_series(encode_series(cpu, times, "columns", "uvarint")), (cpu, times))
        with self.assertRaises(ValueError):
            encode_series(cpu, times, "columns", "uint64le")
        maximum = (1 << 64) - 1
        self.assertEqual(decode_series(encode_series([maximum], [maximum], "columns", "uint64le")),
                         ([maximum], [maximum]))
        with self.assertRaises(ValueError):
            encode_series([maximum, maximum + 1], [0, 1], "runs", "uint64le")

    def test_cumulative_quantization_preserves_small_increments(self):
        unit = 10
        values = [0, 1, 2, 3, 11, 12, 29]
        quotients, remainders = quantize_cumulative(values, unit)
        self.assertEqual(quotients, [0, 0, 0, 0, 1, 1, 2])
        self.assertEqual(remainders, [0, 1, 2, 3, 1, 2, 9])
        self.assertEqual(unit * (quotients[-1] - quotients[0]) + remainders[-1] - remainders[0],
                         values[-1] - values[0])
        # Repeated sub-unit increments still accumulate in the cumulative quotient.
        values = list(range(101))
        quotients, remainders = quantize_cumulative(values, 10)
        self.assertEqual(10 * (quotients[-1] - quotients[0]) + remainders[-1] - remainders[0], 100)

    def test_both_runs_compresses_idle_series_before_secondary_compression(self):
        cpu,times=series_from_deltas([0]*10000,[1000]*10000,cpu0=0,time0=0)
        small=encode_series(cpu,times,'both-runs','uvarint')
        self.assertLess(len(small),40)
        self.assertEqual(decode_series(small),(cpu,times))
        with self.assertRaises(ValueError):
            decode_series(small,max_samples=100)

    def test_rejects_invalid_series_and_options(self):
        bad = [
            ([1], []),
            ([], [1]),
            ([1], [1, 2]),
            ([True], [1]),
            ([1, True], [1, 2]),
            ([-1], [1]),
            ([1, 0], [1, 2]),
            ([1], [1, 1]),
            ([1], [1, 0]),
        ]
        for cpu, times in bad:
            with self.subTest(cpu=cpu, times=times), self.assertRaises(ValueError):
                encode_series(cpu, times, "columns", "uvarint")
        for layout, codec in (("unknown", "uvarint"), ("columns", "unknown")):
            with self.subTest(layout=layout, codec=codec), self.assertRaises(ValueError):
                encode_series([0], [1], layout, codec)
        for values, quantum in (([0, 1], 0), ([0, 1], -1), ([0, True], 1), ([2, 1], 1)):
            with self.subTest(values=values, quantum=quantum), self.assertRaises(ValueError):
                quantize_cumulative(values, quantum)

    def test_binary_rejects_header_truncation_trailing_and_unknown_ids(self):
        encoded = encode_series([5, 7], [10, 13], "columns", "uvarint")
        for malformed in (b"NOPE" + encoded[4:], encoded[:-1], encoded + b"x",
                          encoded[:4] + b"\xff" + encoded[5:],
                          encoded[:5] + b"\xff" + encoded[6:]):
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                decode_series(malformed)

    def test_rejects_impossible_counts_and_invalid_period_layouts(self):
        # A count too large for the available payload must be rejected before allocation.
        encoded = encode_series([0], [0], "columns", "uvarint")
        with self.assertRaises(ValueError):
            decode_series(encoded[:6] + b"\xff" * 10)
        cpu, times = series_from_deltas([1, 1], [2, 3, 4])
        encoded = encode_series(cpu, times, "runs", "uvarint")
        # Corrupt one byte of the initial run index from zero to one.
        malformed = bytearray(encoded)
        malformed[-4] = 1
        with self.assertRaises(ValueError):
            decode_series(bytes(malformed))


if __name__ == "__main__":
    unittest.main()
