# What the compressor actually sees

Current benchmarks use the verified **8.5-hour corpus**: 306,000 scans,
326,450,656 readings and 886,984 identities. See [the scorecard](RECORDING_RESULTS.md)
for current codec/CPU results and the source-counter anomaly that limits this prefix.

The detailed snippets below come from the earlier ten-minute capture
(`033d5198…95809b2`), using the same representation—not generated workloads.
Process identities/names are anonymized; absolute PID/birth timestamps are shifted
or omitted. Numeric deltas retain their measured values. These excerpts are not
the benchmark input; benchmarks use the unchanged private data.

## Layers — JSON is not the current compressor input

```text
source JSONL: seq, wall/start/end ns, [pid,ppid,start_sec,start_usec,name,user_ns,system_ns,RSS]
    ↓ representation
~30s independent binary blocks:
    header JSON + framing (~223 bytes/block)
    CPU: shared actual clock, identities, observation runs, baseline + sparse changes
    metadata: sparse identity/name/parent/RSS/availability changes + exact scan/wall markers
    ↓ group into codec-input byte frames
zstd / Brotli
```

In the current **8.5-hour, 256 KiB-RSS variant**, before outer compression:
**CPU 74,074,701 bytes; metadata 65,648,607 bytes; block headers/framing 227,460 bytes**.
That is ~53% CPU / 47% metadata, not their shares of compressed output. The verbose
JSON block headers are only ~0.16%; removing them cannot fix the budget. CPU and
metadata repeat some identities/clocks; separate compressed sizes are not additive.

The 1,020 encoding blocks average **~134 KiB each**. A 256 KiB–1 MiB match window
can reach nearby blocks; this fits the observed lack of gains from huge windows,
but does not prove the remaining data incompressible. Larger compression frames
still contain independent 30s baselines—they do not extend the encoding region.

In the long corpus's **first 30s block only**, 95.6% of successive observed CPU
readings had no whole-millisecond counter change. Zero changes are already omitted;
the compressor is not being fed dense arrays of all those unchanged readings.

## CPU: some streams really are almost constant

A real process, first 16 polls. Cumulative total CPU is quantized to 1 ms;
these are its **15 successive increments**, not utilization percentages:

```text
CPU increments (ms): [4,4,4,3,4,4,4,4,4,4,4,4,4,4,4]
baseline quotient:   3 ms
sparse pairs:        (sample-index delta, CPU increment)
                     [(1,4),(1,4),(1,4),(1,3),(1,4), ...]
uvarint pair bytes:  01 04 01 04 01 04 01 03 01 04 ...
```

Zero increments are omitted; index deltas locate later changes. Missing readings
are represented by coverage runs, not fabricated zeros. The same process's native
CPU remainders at the **full 30s block** endpoints were `[2439, 13400]` ticks.
Those additional values preserve exact endpoints despite coarse intermediate points.
One native tick here is 125/3 ns; the CPU quantum is 24,000 ticks, not 1,000,000.

A less regular real process in the same polls:

```text
CPU increments (ms): [12,35,28,10,16,9,9,42,28,22,39,16,38,45,45]
```

A constant average is not interchangeable with this sequence. Smoothing it is a
fidelity decision; byte reordering/differencing can instead be lossless.

## RSS: long repeats, then small changes

The less regular process above, first eight polls:

```text
RSS in 4 KiB units:   [122588,122596,122616,122636,122652,122664,122672,122672]
changes (4 KiB):      [8,20,20,16,12,8,0]
floored 256 KiB units:[1915,1915,1915,1916,1916,1916,1916,1916]
```

The fixed-precision variant stores only that `+1` change after the baseline.
This preserves an error bound, not the exact allocation trajectory or every spike.
4 KiB is an observed common unit, not an assertion about hardware page size.

## The clock is not a string of 100,000,000s

```text
successive scan-start gaps (ns):
[105013000,97383500,98328333,101935042,99607000,101305500,99037250]
scan durations (ns):
[3513125,3390792,3470917,3205167,3260542,3440583,3333375,3475667]
change in (wall minus scan-start) offset from first poll (ns):
[0,-4000,-7500,-11833,-15875,-18875,-23375,-26625]
```

There is both cadence jitter and wall/monotonic drift. Replacing these with a
nominal period loses information. An affine predictor plus exact residuals could
be lossless; using coarser timestamps would be a separately declared tradeoff.
Scan bounds do not provide per-process read timestamps or nanosecond accuracy.

## Churn: six actual newly observed `sleep` processes

PID and start-time offsets share a common subtracted origin, preserving gaps.
Each identity appeared in one scan within the inspected first 30 seconds. CPU
below is its **first observed cumulative total**, rounded for display—not an
observed lifetime total or a before/after increment.

| Scan | PID offset | Birth offset µs | CPU ms | RSS KiB |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0 | 0 | 4.183167 | 1216 |
| 1 | 1 | 3527 | 1.641542 | 1184 |
| 1 | 2 | 60964 | 4.225708 | 1184 |
| 2 | 3 | 119007 | 4.505042 | 1184 |
| 2 | 4 | 120485 | 4.679333 | 1184 |
| 2 | 5 | 171944 | 6.680125 | 1184 |

Names/RSS repeat; PIDs are near-sequential; birth-time and fractional CPU details
vary. A name dictionary alone doesn't eliminate those varying integers. Single
observations cannot establish exit time or recover CPU used after the last read.

## Useful representation questions

- Can one identity table and shared clock cover a much larger encoding region,
  instead of repeating baselines every 30s and across CPU/metadata planes?
- Can clock drift and quasi-regular counters use exact prediction residuals?
- Can recurring child-process templates separate repeated fields from varying
  PID/birth/CPU values without losing identities, coverage or small unusual jobs?
- How much space belongs to native endpoint corrections? Omitting them changes
  CPU fidelity, even when the displayed precision still says “1 ms”.

The larger source capture retains raw fields so these ideas can be replayed later.
No representation above has been selected as a production format.
