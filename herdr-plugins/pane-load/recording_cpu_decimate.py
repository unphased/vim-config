"""Offline, bounded-error decimation of cumulative native CPU counters.

Only the observed samples are simplified; interpolation describes an estimate
of the recorded values, not CPU activity between polls or future workloads.
"""
from bisect import bisect_left, bisect_right
from fractions import Fraction

DEFAULT_MAX_SPAN_NS = 10_000_000_000


def _integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _validate(samples):
    try:
        points = list(samples)
    except TypeError as exc:
        raise ValueError("samples must be an iterable of triples") from exc
    previous = None
    for point in points:
        if not isinstance(point, (tuple, list)) or len(point) != 3:
            raise ValueError("each sample must be (seq, cpu, time_ns)")
        seq, cpu, stamp = point
        if not all(_integer(v) for v in point):
            raise ValueError("sample fields must be integers, not bools")
        if min(seq,cpu,stamp) < 0 or (previous is not None and
                       (seq <= previous[0] or stamp <= previous[2] or cpu < previous[1])):
            raise ValueError("CPU must be nonnegative/monotone; seq and time must increase")
        previous = point
    return points


def _runs(points):
    start = 0
    for i in range(1, len(points)):
        if points[i][0] - points[i - 1][0] > 1:
            yield points[start:i]
            start = i
    if points:
        yield points[start:]


def _rdp(points, lo, hi, tolerance, keep):
    stack = [(lo, hi)]
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        dt = points[b][2] - points[a][2]
        dy = points[b][1] - points[a][1]
        best_num, best_den, best_i = -1, 1, None
        for i in range(a + 1, b):
            num = abs((points[i][1] - points[a][1]) * dt - dy * (points[i][2] - points[a][2]))
            den = dt
            if num * best_den > best_num * den:
                best_num, best_den, best_i = num, den, i
        if best_i is not None and best_num > tolerance * best_den:
            keep.add(best_i)
            stack.extend(((a, best_i), (best_i, b)))


def simplify(samples, tolerance, max_span_ns=DEFAULT_MAX_SPAN_NS):
    """Return original samples whose linear interpolation is within tolerance."""
    points = _validate(samples)
    if not _integer(tolerance) or tolerance < 0:
        raise ValueError("tolerance must be a nonnegative integer native CPU count")
    if not _integer(max_span_ns) or max_span_ns <= 0:
        raise ValueError("max_span_ns must be a positive integer")
    keep = set()
    offset = 0
    for run in _runs(points):
        n = len(run)
        if n:
            keep.update((offset, offset + n - 1))
            anchors = [0]
            times = [p[2] for p in run]
            current = 0
            while current < n - 1:
                limit = times[current] + max_span_ns
                farthest = bisect_right(times, limit, current + 1) - 1
                if farthest == current:  # An adjacent observed pair itself exceeds the span.
                    farthest = current + 1
                if farthest < n - 1:
                    anchors.append(farthest)
                current = farthest
            anchors.append(n - 1)
            keep.update(offset + i for i in anchors)
            for a, b in zip(anchors, anchors[1:]):
                _rdp(run, a, b, tolerance, local := set())
                keep.update(offset + i for i in local)
        offset += n
    return [point for i, point in enumerate(points) if i in keep]


def _interpolate(points, stamp, check_gaps, times=None):
    if times is None:
        times = [p[2] for p in points]
    i = bisect_left(times, stamp)
    if i < len(points) and times[i] == stamp:
        return Fraction(points[i][1])
    if i == 0 or i == len(points):
        raise ValueError("time is outside sample range")
    left, right = points[i - 1], points[i]
    if check_gaps and right[0] - left[0] > 1:
        raise ValueError("cannot interpolate across a sequence gap")
    return Fraction(left[1]) + Fraction((right[1] - left[1]) * (stamp - left[2]), right[2] - left[2])


def interpolate(samples, t_ns):
    """Interpolate recorded samples exactly; reject out-of-range times and gaps."""
    points = _validate(samples)
    if not _integer(t_ns):
        raise ValueError("t_ns must be an integer, not bool")
    return _interpolate(points, t_ns, True)


def audit(original, retained, *, allow_estimated=False):
    """Measure interpolation loss against the raw piecewise-linear observations."""
    raw, selected = _validate(original), _validate(retained)
    positions = {p[0]: i for i, p in enumerate(raw)}
    indices = []
    for p in selected:
        i = positions.get(p[0])
        matches = i is not None and (raw[i] == p or
                  (allow_estimated and raw[i][0] == p[0] and raw[i][2] == p[2]))
        if not matches or (indices and i <= indices[-1]):
            raise ValueError("retained samples must be an ordered subset of original samples")
        indices.append(i)
    selected_by_seq = {p[0]: p for p in selected}
    max_error = Fraction(0)
    max_rate = Fraction(0)
    win_errors = {100_000_000: Fraction(0), 1_000_000_000: Fraction(0)}
    endpoint_ok = True
    raw_count = len(raw)
    for run in _runs(raw):
        reduced = [selected_by_seq[p[0]] for p in run if p[0] in selected_by_seq]
        endpoint_ok &= bool(reduced) and reduced[0] == run[0] and reduced[-1] == run[-1]
        if not reduced or reduced[0][0]!=run[0][0] or reduced[-1][0]!=run[-1][0]:
            raise ValueError("retained curve must cover each observed run")
        rtimes = [p[2] for p in reduced]
        raw_times = [p[2] for p in run]
        for p in run:
            err = abs(_interpolate(reduced, p[2], False, rtimes) - p[1])
            max_error = max(max_error, err)
        for left, right in zip(run, run[1:]):
            j = bisect_right(rtimes, left[2]) - 1
            slope = Fraction(reduced[j + 1][1] - reduced[j][1], reduced[j + 1][2] - reduced[j][2])
            raw_slope = Fraction(right[1] - left[1], right[2] - left[2])
            max_rate = max(max_rate, abs(slope - raw_slope))
        knots = sorted({p[2] for p in run} | set(rtimes))
        start, end = run[0][2], run[-1][2]
        for window in win_errors:
            if end - start < window:
                continue
            candidates = {start, end - window}
            candidates.update(t for t in knots if start <= t <= end - window)
            candidates.update(t - window for t in knots if start + window <= t <= end)
            for t in candidates:
                raw_delta = _interpolate(run, t + window, False, raw_times) - _interpolate(run, t, False, raw_times)
                reduced_delta = _interpolate(reduced, t + window, False, rtimes) - _interpolate(reduced, t, False, rtimes)
                win_errors[window] = max(win_errors[window], abs(reduced_delta - raw_delta) / window)
    return {
        "max_counter_error": float(max_error),
        "retained_point_count": len(selected),
        "raw_point_count": raw_count,
        "exact_cpu_endpoints": bool(endpoint_ok),
        "max_interval_cpu_rate_error": float(max_rate),
        "max_100ms_cpu_rate_error": float(win_errors[100_000_000]) if raw and any(r[-1][2] - r[0][2] >= 100_000_000 for r in _runs(raw)) else None,
        "max_1s_cpu_rate_error": float(win_errors[1_000_000_000]) if raw and any(r[-1][2] - r[0][2] >= 1_000_000_000 for r in _runs(raw)) else None,
    }
