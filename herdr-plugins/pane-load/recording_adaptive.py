"""Experimental per-process bounded-history recording policy.

Input rows have the sampler's raw cumulative counters; output events are lossy
summaries outside identity-local transition windows. This is not a live recorder.
"""
from collections import deque
from fractions import Fraction
import math

_NS = 1_000_000_000


def adaptive_records(rows, pre_seconds=2, post_seconds=2, summary_seconds=10,
                     cpu_threshold=0.20, rss_threshold_bytes=4 * 1024 * 1024,
                     stats=None, max_buffered_per_process=4096):
    """Yield sample, summary, and not_observed events from streamed sampler rows.

    CPU threshold is an absolute change in process CPU cores (e.g. .20 is 20%
    of one core); RSS uses an absolute byte delta. References stay fixed until
    their own threshold triggers, so gradual ramps and plateau changes are caught.
    """
    if (isinstance(max_buffered_per_process, bool) or
            not isinstance(max_buffered_per_process, int) or max_buffered_per_process < 1):
        raise ValueError("buffer cap must be a positive integer")
    if any(not math.isfinite(value) or value < 0 for value in
           (pre_seconds, post_seconds, summary_seconds, cpu_threshold, rss_threshold_bytes)):
        raise ValueError("durations and thresholds must be finite and non-negative")
    pre_ns, post_ns, summary_ns = (int(pre_seconds * _NS), int(post_seconds * _NS),
                                   int(summary_seconds * _NS))
    stats = stats if stats is not None else {}
    stats.update(peak_buffered_observations=0, triggers=0, full_samples=0, summaries=0)
    live = {}
    buffered_count = 0
    threshold = Fraction(str(cpu_threshold))
    previous_seq = previous_time = None

    def sample_event(identity, obs, reason=None):
        event = {"type": "sample", "identity": list(identity), "seq": obs["seq"],
                 "wall_start_ns": obs["wall_start_ns"],
                 "scan_start_ns": obs["scan_start_ns"], "scan_end_ns": obs["scan_end_ns"],
                 "process": list(obs["process"])}
        if reason:
            event["reason"] = reason
        stats["full_samples"] += 1
        return event

    def flush_summary(identity, state):
        summary = state["summary"]
        if summary is None:
            return None
        first, last = summary["first"], summary["last"]
        a, b = first["process"], last["process"]
        event = {"type": "summary", "identity": list(identity),
                 "metadata": [b[1], b[4]], "first_seq": first["seq"],
                 "last_seq": last["seq"],
                 "first_wall_start_ns": first["wall_start_ns"],
                 "last_wall_start_ns": last["wall_start_ns"],
                 "first_scan_start_ns": first["scan_start_ns"],
                 "last_scan_start_ns": last["scan_start_ns"],
                 "first_scan_end_ns": first["scan_end_ns"],
                 "last_scan_end_ns": last["scan_end_ns"],
                 "user_ns_start": a[5], "user_ns_end": b[5],
                 "system_ns_start": a[6], "system_ns_end": b[6],
                 "rss_min_bytes": summary["rss_min"],
                 "rss_max_bytes": summary["rss_max"], "rss_end_bytes": b[7],
                 "observations": summary["count"]}
        state["summary"] = None
        stats["summaries"] += 1
        return event

    def add_summary(identity, state, obs):
        current = state["summary"]
        if current is not None and obs["scan_start_ns"] - current["first"]["scan_start_ns"] >= summary_ns:
            event = flush_summary(identity, state)
        else:
            event = None
        p = obs["process"]
        if state["summary"] is None:
            state["summary"] = {"first": obs, "last": obs, "count": 1,
                                 "rss_min": p[7], "rss_max": p[7]}
        else:
            current = state["summary"]
            current["last"] = obs
            current["count"] += 1
            current["rss_min"] = min(current["rss_min"], p[7])
            current["rss_max"] = max(current["rss_max"], p[7])
        return event

    def emit_full(identity, obs, reason=None):
        if obs["full"]:
            return None
        obs["full"] = True
        return sample_event(identity, obs, reason)

    for row in rows:
        now = row["scan_start_ns"]
        if (previous_time is not None and (now <= previous_time or row["seq"] <= previous_seq)
                or row["scan_end_ns"] < now):
            raise ValueError("acquisition sequence/time must increase with valid scan bounds")
        previous_seq, previous_time = row["seq"], now
        current = {}
        output = []
        for process in row["processes"]:
            identity = (process[0], process[2], process[3])
            current[identity] = process
            state = live.get(identity)
            if state is None:
                state = {"buffer": deque(), "summary": None, "last": None,
                         "metadata": None, "cpu_reference": None, "rss_reference": process[7],
                         "full_until": -1}
                live[identity] = state
                reasons = ["birth"]
            else:
                reasons = []
            previous = state["last"]
            obs = {"seq": row["seq"], "wall_start_ns": row["wall_start_ns"],
                   "scan_start_ns": now, "scan_end_ns": row["scan_end_ns"],
                   "process": process, "full": False}
            state["buffer"].append(obs)
            buffered_count += 1
            stats["peak_buffered_observations"] = max(
                stats["peak_buffered_observations"], buffered_count)
            if previous is not None:
                old = previous["process"]
                if (process[1], process[4]) != (old[1], old[4]):
                    reasons.append("metadata")
                old_cpu, cpu = old[5] + old[6], process[5] + process[6]
                if process[5] < old[5] or process[6] < old[6]:
                    reasons.append("counter_reset")
                    state["cpu_reference"] = None
                else:
                    elapsed = now - previous["scan_start_ns"]
                    if elapsed > 0:
                        rate = (cpu - old_cpu, elapsed)
                        reference = state["cpu_reference"]
                        if reference is None:
                            state["cpu_reference"] = rate
                        else:
                            difference = abs(rate[0]*reference[1] - reference[0]*rate[1])
                            if difference and difference*threshold.denominator >= (
                                    threshold.numerator*rate[1]*reference[1]):
                                reasons.append("cpu")
                                state["cpu_reference"] = rate
                rss_reference = state["rss_reference"]
                if process[7] != rss_reference and abs(process[7] - rss_reference) >= rss_threshold_bytes:
                    reasons.append("rss")
                    state["rss_reference"] = process[7]
            state["last"] = obs
            state["metadata"] = (process[1], process[4])

            cutoff = now - pre_ns
            while state["buffer"] and state["buffer"][0]["scan_start_ns"] < cutoff:
                expired = state["buffer"].popleft()
                buffered_count -= 1
                if not expired["full"]:
                    event = add_summary(identity, state, expired)
                    if event:
                        output.append(event)
            if len(state["buffer"]) > max_buffered_per_process:
                raise ValueError("pre-window exceeds configured per-process buffer cap")
            stats["peak_buffered_observations"] = max(
                stats["peak_buffered_observations"], buffered_count)

            if reasons:
                stats["triggers"] += 1
                event = flush_summary(identity, state)
                if event:
                    output.append(event)
                for buffered in state["buffer"]:
                    item = emit_full(identity, buffered,
                                     reasons[0] if buffered is obs else None)
                    if item:
                        output.append(item)
                state["full_until"] = max(state["full_until"], now + post_ns)
                # Already-emitted full samples do not need retrospective storage.
                buffered_count -= len(state["buffer"])
                state["buffer"].clear()
            elif now <= state["full_until"]:
                item = emit_full(identity, obs)
                if item:
                    output.append(item)
                state["buffer"].pop()
                buffered_count -= 1

        # A missing observation is explicit, forces its recent pre-window full,
        # and retires state immediately; a later appearance starts a fresh window.
        for identity in list(live):
            if identity in current:
                continue
            state = live.pop(identity)
            cutoff = now - pre_ns
            while state["buffer"]:
                buffered = state["buffer"].popleft()
                buffered_count -= 1
                if buffered["scan_start_ns"] >= cutoff:
                    item = emit_full(identity, buffered)
                    if item:
                        output.append(item)
                elif not buffered["full"]:
                    event = add_summary(identity, state, buffered)
                    if event:
                        output.append(event)
            event = flush_summary(identity, state)
            if event:
                output.append(event)
            output.append({"type": "not_observed", "identity": list(identity),
                           "seq": row["seq"], "wall_start_ns": row["wall_start_ns"],
                           "scan_start_ns": now, "scan_end_ns": row["scan_end_ns"],
                           "reason": "missing"})
            stats["triggers"] += 1
        for event in output:
            yield event

    # Finish buffered stable observations and summaries; never retain dead states.
    for identity, state in list(live.items()):
        while state["buffer"]:
            obs = state["buffer"].popleft()
            buffered_count -= 1
            if not obs["full"]:
                event = add_summary(identity, state, obs)
                if event:
                    yield event
        event = flush_summary(identity, state)
        if event:
            yield event
