import unittest

from recording_adaptive import adaptive_records


NS = 1_000_000_000


def make_row(seq, processes, *, time=None):
    time = seq if time is None else time
    return {
        "seq": seq,
        "wall_start_ns": 10_000 + time * NS,
        "scan_start_ns": time * NS,
        "scan_end_ns": time * NS + 1,
        "processes": processes,
    }


def process(pid=10, user_ns=0, rss=100, *, start=(1, 2), ppid=1, name="worker",
            system_ns=0):
    return [pid, ppid, start[0], start[1], name, user_ns, system_ns, rss]


def single_process_rows(rates, *, rss_values=None, metadata=None):
    rows = []
    cpu_ns = 0
    for seq, rate in enumerate(rates):
        if seq:
            cpu_ns += round(rate * NS)
        ppid, name = (metadata or {}).get(seq, (1, "worker"))
        rss = (rss_values or {}).get(seq, 100)
        rows.append(make_row(seq, [process(user_ns=cpu_ns, rss=rss, ppid=ppid, name=name)]))
    return rows


def collect(rows, **kwargs):
    stats = {}
    events = list(adaptive_records(rows, stats=stats, **kwargs))
    return events, stats


def full_sequences(events, identity=(10, 1, 2)):
    return {event["seq"] for event in events
            if event["type"] == "sample" and event["identity"] == list(identity)}


class AdaptiveRecordingTests(unittest.TestCase):
    def test_plateau_keeps_transition_windows_full_but_summarizes_stable_load(self):
        rates = [0.05] * 31
        for seq in range(8, 19):
            rates[seq] = 0.8
        events, stats = collect(single_process_rows(rates), pre_seconds=2,
                                post_seconds=2, summary_seconds=10)

        self.assertEqual(full_sequences(events),
                         set(range(0, 3)) | set(range(6, 11)) | set(range(17, 22)))
        self.assertTrue(any(event["type"] == "summary" and event["observations"] > 1
                            for event in events))
        self.assertEqual(stats["triggers"], 3)  # birth, load rise, return to quiet

    def test_one_sample_cpu_pulse_gets_both_transition_windows(self):
        rates = [0.05] * 12
        rates[5] = 0.8
        events, _ = collect(single_process_rows(rates), pre_seconds=2, post_seconds=2)

        self.assertEqual(full_sequences(events), set(range(0, 3)) | set(range(3, 9)))
        trigger_reasons = {event.get("reason") for event in events
                           if event["type"] == "sample" and event.get("reason")}
        self.assertIn("cpu", trigger_reasons)

    def test_stable_history_is_sparse_and_summaries_have_actual_endpoints(self):
        events, _ = collect(single_process_rows([0.05] * 40), pre_seconds=2,
                            post_seconds=2, summary_seconds=10)
        summaries = [event for event in events if event["type"] == "summary"]

        self.assertGreaterEqual(len(summaries), 3)
        for event in summaries:
            self.assertLessEqual(event["first_scan_start_ns"], event["last_scan_start_ns"])
            self.assertGreaterEqual(event["observations"], 1)
            self.assertIn("user_ns_start", event)
            self.assertIn("user_ns_end", event)
            self.assertIn("rss_min_bytes", event)
            self.assertIn("rss_max_bytes", event)
            self.assertIn("rss_end_bytes", event)

    def test_noisy_process_does_not_force_neighbor_full_rate(self):
        rows = []
        noisy_cpu = quiet_cpu = 0
        for seq in range(15):
            if seq:
                noisy_cpu += round((0.8 if seq == 6 else 0.05) * NS)
                quiet_cpu += round(0.02 * NS)
            rows.append(make_row(seq, [process(pid=10, user_ns=noisy_cpu),
                                       process(pid=11, user_ns=quiet_cpu, start=(3, 4))]))
        events, _ = collect(rows, pre_seconds=1, post_seconds=1)

        quiet_full = full_sequences(events, identity=(11, 3, 4))
        self.assertEqual(quiet_full, {0, 1})
        self.assertTrue(any(event["type"] == "summary" and event["identity"] == [11, 3, 4]
                            for event in events))

    def test_slow_rss_ramp_triggers_against_fixed_reference(self):
        rss = {seq: 100 + seq * 1_000_000 for seq in range(12)}
        events, _ = collect(single_process_rows([0.05] * 12, rss_values=rss),
                            pre_seconds=1, post_seconds=1, rss_threshold_bytes=4_000_000)

        self.assertIn(5, full_sequences(events))
        self.assertTrue(any(event.get("reason") == "rss" and event["seq"] == 4
                            for event in events if event["type"] == "sample"))

    def test_changes_within_high_load_and_memory_growth_trigger_independently(self):
        rates = [0.05] * 24
        for seq in range(5, 12):
            rates[seq] = 0.50
        for seq in range(12, 18):
            rates[seq] = 0.95
        rss = {seq: 100 + max(0, seq - 7) * 1_000_000 for seq in range(24)}
        events, _ = collect(single_process_rows(rates, rss_values=rss),
                            pre_seconds=1, post_seconds=1, rss_threshold_bytes=4_000_000)
        triggers = {e["seq"] for e in events if e["type"] == "sample" and e.get("reason")}
        self.assertTrue({5, 11, 12, 15, 18, 19, 23} <= triggers)

    def test_reset_of_one_cpu_counter_is_detected_even_if_total_increases(self):
        rows = [make_row(0, [process(user_ns=100, system_ns=0)]),
                make_row(1, [process(user_ns=200, system_ns=100)]),
                make_row(2, [process(user_ns=10, system_ns=500)])]
        events, _ = collect(rows)
        self.assertTrue(any(e.get("reason") == "counter_reset" and e["seq"] == 2
                            for e in events))

    def test_exact_cpu_threshold_boundary_is_not_lost_to_float_rounding(self):
        events, _ = collect(single_process_rows([.7] * 6 + [.5] * 6),
                            pre_seconds=1, post_seconds=1, cpu_threshold=.2)
        self.assertTrue(any(e.get("reason") == "cpu" and e["seq"] == 6 for e in events))

    def test_invalid_time_progression_and_buffer_overflow_are_rejected(self):
        for rows in ([make_row(0,[process()]), make_row(1,[process()],time=0)],
                     [make_row(0,[process()]), make_row(1,[process()],time=-1)]):
            with self.assertRaises(ValueError):
                collect(rows)
        with self.assertRaises(ValueError):
            collect(single_process_rows([.05]*40),pre_seconds=100,
                    post_seconds=0,max_buffered_per_process=8)

    def test_pid_reuse_is_a_distinct_identity(self):
        rows = [make_row(0, [process(pid=20, start=(1, 2))]),
                make_row(1, [process(pid=20, user_ns=50_000_000, start=(1, 2))]),
                make_row(2, [process(pid=20, start=(9, 8))]),
                make_row(3, [process(pid=20, user_ns=50_000_000, start=(9, 8))])]
        events, _ = collect(rows, pre_seconds=1, post_seconds=1)

        self.assertTrue(any(e["type"] == "sample" and e["identity"] == [20, 1, 2]
                            and e.get("reason") == "birth" for e in events))
        self.assertTrue(any(e["type"] == "sample" and e["identity"] == [20, 9, 8]
                            and e.get("reason") == "birth" for e in events))
        self.assertTrue(any(e["type"] == "not_observed" and e["identity"] == [20, 1, 2]
                            for e in events))

    def test_missing_then_reappearing_process_is_retired_and_retriggered(self):
        rows = [make_row(0, [process()]), make_row(1, [process(user_ns=50_000_000)]),
                make_row(2, []), make_row(3, []),
                make_row(4, [process(user_ns=200_000_000)]),
                make_row(5, [process(user_ns=250_000_000)])]
        events, _ = collect(rows, pre_seconds=1, post_seconds=1)

        self.assertTrue(any(e["type"] == "not_observed" and e["seq"] == 2
                            for e in events))
        self.assertTrue(any(e["type"] == "sample" and e["seq"] == 4
                            and e.get("reason") == "birth" for e in events))

    def test_metadata_change_forces_a_window(self):
        rows = single_process_rows([0.05] * 9, metadata={4: (2, "renamed")})
        events, _ = collect(rows, pre_seconds=1, post_seconds=1)

        self.assertTrue(any(e["type"] == "sample" and e["seq"] == 4
                            and e.get("reason") == "metadata" for e in events))
        self.assertIn(3, full_sequences(events))
        self.assertIn(5, full_sequences(events))

    def test_counter_decrease_forces_event_and_rebaselines_cpu(self):
        values = [0, 50_000_000, 100_000_000, 150_000_000,
                  200_000_000, 10_000_000, 60_000_000, 110_000_000]
        rows = [make_row(seq, [process(user_ns=value)]) for seq, value in enumerate(values)]
        events, _ = collect(rows, pre_seconds=1, post_seconds=1)

        self.assertTrue(any(e["type"] == "sample" and e["seq"] == 5
                            and e.get("reason") == "counter_reset" for e in events))
        self.assertIn(6, full_sequences(events))

    def test_bounded_history_exact_coverage_no_double_count_and_final_flush(self):
        count = 500
        events, stats = collect(single_process_rows([0.05] * count), pre_seconds=2,
                                post_seconds=2, summary_seconds=10)
        samples = [event for event in events if event["type"] == "sample"]
        summaries = [event for event in events if event["type"] == "summary"]
        covered = len(samples) + sum(event["observations"] for event in summaries)
        sample_seqs = [event["seq"] for event in samples]

        self.assertEqual(covered, count)
        self.assertEqual(len(sample_seqs), len(set(sample_seqs)))
        self.assertEqual(stats["full_samples"], len(samples))
        self.assertEqual(stats["summaries"], len(summaries))
        self.assertLessEqual(stats["peak_buffered_observations"], 4)
        self.assertIn(count - 1, sample_seqs + [summaries[-1]["last_seq"]])
        self.assertLess(len(samples), count // 5)

    def test_final_stable_observations_are_flushed(self):
        events, _ = collect(single_process_rows([0.05] * 4), pre_seconds=10,
                            post_seconds=2, summary_seconds=10)
        summaries = [event for event in events if event["type"] == "summary"]
        self.assertEqual(sum(event["observations"] for event in summaries), 1)
        self.assertEqual(summaries[-1]["last_seq"], 3)


if __name__ == "__main__":
    unittest.main()
