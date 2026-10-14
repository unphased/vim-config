import unittest
from fractions import Fraction

from recording_cpu_decimate import audit, interpolate, simplify


class CpuDecimateTests(unittest.TestCase):
    def test_long_idle_plateau_reduces_to_endpoints_without_losing_cpu(self):
        samples = [(i, 700, i * 100_000_000) for i in range(101)]
        retained = simplify(samples, tolerance=0)
        self.assertEqual(retained, [samples[0], samples[-1]])
        self.assertEqual(retained[0][1], samples[0][1])
        self.assertEqual(retained[-1][1] - retained[0][1], 0)

    def test_linear_high_load_reduces_exactly(self):
        samples = [(i, 1000 + 250 * i, i * 100_000_000) for i in range(101)]
        self.assertEqual(simplify(samples, tolerance=0), [samples[0], samples[-1]])

    def test_alternating_small_noise_is_bounded_and_decimated(self):
        samples = [(i, 10 * i + (i % 2), i * 100_000_000) for i in range(101)]
        retained = simplify(samples, tolerance=1)
        result = audit(samples, retained)
        self.assertLess(len(retained), len(samples) // 4)
        self.assertLessEqual(result["max_counter_error"], 1)

    def test_brief_cpu_burst_larger_than_tolerance_is_preserved(self):
        samples = [(i, cpu, i * 100_000_000) for i, cpu in enumerate([0, 0, 50, 100, 100, 100])]
        retained = simplify(samples, tolerance=1)
        self.assertIn(samples[3], retained)
        self.assertEqual(retained[-1][1], 100)
        self.assertLessEqual(audit(samples, retained)["max_counter_error"], 1)

    def test_hours_of_plateau_activity_then_quiet_remain_monotone_and_bounded(self):
        # Two synthetic hours at one-second polling: quiet for an hour, 1 CPU-s
        # per second for a minute, then quiet for an hour.
        samples = []
        for i in range(7201):
            cpu = max(0, min(i - 3600, 60))
            samples.append((i, cpu, i * 1_000_000_000))
        retained = simplify(samples, tolerance=0, max_span_ns=600_000_000_000)
        result = audit(samples, retained)
        self.assertLess(len(retained), len(samples) // 5)
        self.assertLessEqual(result["max_counter_error"], 0)
        self.assertEqual(retained[0], samples[0])
        self.assertEqual(retained[-1], samples[-1])

    def test_rational_error_boundary_is_compared_exactly(self):
        # The middle point differs from the endpoint chord by exactly 1/3.
        samples = [(0, 0, 0), (1, 1, 1), (2, 2, 3)]
        self.assertEqual(simplify(samples, tolerance=0), samples)
        retained = simplify(samples, tolerance=1)
        self.assertEqual(retained, [samples[0], samples[-1]])
        self.assertEqual(audit(samples, retained)["max_counter_error"], 1 / 3)

    def test_gaps_are_split_and_interpolation_does_not_bridge_them(self):
        samples = [(0, 0, 0), (1, 10, 10), (3, 100, 100), (4, 110, 110)]
        retained = simplify(samples, tolerance=100)
        self.assertEqual(retained, [samples[0], samples[1], samples[2], samples[3]])
        with self.assertRaisesRegex(ValueError, "gap"):
            interpolate(samples, 50)
        self.assertLessEqual(audit(samples, retained)["max_counter_error"], 0)

    def test_singleton_is_retained_and_interpolates_only_at_its_time(self):
        sample = (9, 123, 456)
        self.assertEqual(simplify([sample], tolerance=10), [sample])
        self.assertEqual(interpolate([sample], 456), Fraction(123))
        with self.assertRaises(ValueError):
            interpolate([sample], 455)

    def test_max_span_forces_original_points_and_allows_impossible_adjacent_span(self):
        samples = [(i, 0, i * 10) for i in range(7)]
        retained = simplify(samples, tolerance=0, max_span_ns=25)
        self.assertTrue(all(b[2] - a[2] <= 25 for a, b in zip(retained, retained[1:])))
        self.assertTrue(all(sample in samples for sample in retained))
        sparse = [(0, 0, 0), (1, 5, 100), (2, 5, 110)]
        sparse_retained = simplify(sparse, tolerance=10, max_span_ns=20)
        self.assertIn(sparse[1], sparse_retained)
        self.assertTrue(any(a == sparse[0] and b == sparse[1]
                            for a, b in zip(sparse_retained, sparse_retained[1:])))

    def test_interpolate_is_exact_and_rejects_outside_range(self):
        samples = [(0, 10, 0), (1, 12, 3)]
        self.assertEqual(interpolate(samples, 1), Fraction(32, 3))
        self.assertEqual(interpolate(samples, 3), Fraction(12))
        for stamp in (-1, 4):
            with self.assertRaises(ValueError):
                interpolate(samples, stamp)

    def test_audit_reports_endpoint_and_interval_rate_metrics(self):
        samples = [(0, 0, 0), (1, 2, 100_000_000), (2, 2, 200_000_000)]
        retained = simplify(samples, tolerance=1)
        result = audit(samples, retained)
        self.assertEqual(result["retained_point_count"], 2)
        self.assertEqual(result["raw_point_count"], 3)
        self.assertTrue(result["exact_cpu_endpoints"])
        self.assertEqual(result["max_counter_error"], 1.0)
        self.assertEqual(result["max_interval_cpu_rate_error"], 1e-8)
        self.assertEqual(result["max_100ms_cpu_rate_error"], 1e-8)
        self.assertIsNone(result["max_1s_cpu_rate_error"])

    def test_invalid_samples_and_options_are_rejected(self):
        bad_series = [
            [(0, -1, 0)],
            [(0, 0, 0), (0, 1, 1)],
            [(0, 0, 0), (1, 1, 0)],
            [(0, 2, 0), (1, 1, 1)],
            [(False, 0, 0)],
            [(0, True, 0)],
            [(0, 0, False)],
        ]
        for samples in bad_series:
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                simplify(samples, tolerance=0)
        valid = [(0, 0, 0)]
        for tolerance, max_span in [(-1, 10), (True, 10), (0, 0), (0, False)]:
            with self.subTest(tolerance=tolerance, max_span=max_span), self.assertRaises(ValueError):
                simplify(valid, tolerance=tolerance, max_span_ns=max_span)
        with self.assertRaises(ValueError):
            interpolate(valid, True)


if __name__ == "__main__":
    unittest.main()
