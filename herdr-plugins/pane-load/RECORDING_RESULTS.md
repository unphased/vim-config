# Process-history storage: current scorecard

Goal: ~10 MB/day encoded, ideally ~1 MB/day compressed. **Not met.** The Rust
recording CLI is standalone and manual; no production sampler/config/startup or
automatic deployment changes. Older rundowns remain in Git history.

```text
real observations -> named precision profile -> independent byte-sized frames
                  -> codec / level / match window / workers -> size vs CPU
```

Rank storage against **compression CPU-seconds/input GiB**; wall time is separate.
Read costs do not constrain frames. Decompression only verifies correctness.

## Rust fixed-1-ms control and all-core bulk validation

The requested old-semantics control **returns to ~100 MiB/day**. Same stopped
41h19m44s source, fixed 1 ms cumulative CPU, 256 KiB RSS, original logical 10 Hz
observations/clocks/membership, all 14 component decreases retained. No new capture.

| Encoder/profile and Brotli-5 backend | Full-corpus compressed bytes | MiB/day |
| --- | ---: | ---: |
| Historical Python fixed-1-ms + C Brotli 1.2.0 | 182,080,781 | 100.837 |
| Rust fixed-1-ms + same C Brotli 1.2.0 | 182,084,756 | **100.839** |
| Rust fixed-1-ms + pure-Rust Brotli 8.0.4 | 179,986,772 | **99.677** |
| Rust adaptive + pure-Rust Brotli, byte-only frames | 708,297,357 | 392.258 |

All rows use a 16 MiB PCR1 input target and a 1 MiB Brotli window. These are
codec payloads, not archive filesystem totals. The C-backend control is within
**0.0022%** of the original result; pure Rust produces 1.15% fewer bytes on the
fixed-profile input. Thus Rust itself did not cause the ~4× storage increase.
Adaptive adds finer CPU fidelity **and** a different CPU layout; this control does
not separately apportion their costs. Polling/time resolution is unchanged.

### How long Rust takes

`transform --profile legacy-1ms --verify --workers auto` used 10 parsing/encoding
workers and processed **248 shards / 1,487,845 host scans / 1,413,925,731 process
observations**, yielding 4,973 blocks, with zero retained-value/endpoint/RSS-bound
violations. The all-core path is opt-in; live recording and default serial replay
are unchanged.

- Whole Rust command: **446.009 s wall (7m26s)**, including initial preflight.
- Measured pipeline: 437.171 s; whole-process CPU **3,246.315 s (54m06s)** summed
  over threads; peak RSS **1,678,426,112 B (~1.56 GiB)**.
- Historical Python preparation: **4h37m16s wall**, ~4h37m14s CPU. Rust's wall
  comparison includes parallelism; it is not a single-core language speed claim.
- The separate single-worker cached codec benchmark took 306.282 s including
  complete archive decoding/validation plus three repeats per frame. Brotli
  encoding itself was **14.387 CPU s**, **23.992 CPU-s/actual compact-input GiB**,
  summed per-frame medians. Input was 643,878,564 B over 39 frames, no padding.
  The extra C-backend size control was one pass, not a median-performance score.

### Fidelity and parity checks

Rust emitted 643,863,423 PST1 bytes versus Python's 643,849,941. Of 4,973 blocks,
**4,949 are entirely byte-identical**; 14 differ only in richer quality headers.
Ten blocks in one shard shift a boundary by one observation because Rust also
honors a 30-second block-age limit. All timestamps/readings remain present and
CPU/RSS precision semantics remain the same, but this is not a claim that every
historical byte or quantized interior point is identical.

The fixed control quantized **128,914,597 positive CPU intervals to zero** within
blocks; adaptive lost none in the full source audit. Near a 0.1%-of-one-core rate
at 100 ms spacing, adaptive's quantum is ~10.67 us versus 1 ms: about **94× finer
quantization**, without more frequent polling. This is not increased physical
kernel measurement accuracy; the improvement varies with CPU consumption.

Ten small bulk integration fixtures compare workers 1/2/4 with serial PST bytes,
flags and ordered provenance, including cross-shard regression/gaps, absent-ID
resets, context boundaries, empties, corrupt input and out-of-order workload.
Additional private helper tests cover between-pass mutation and failure cleanup.
**157 Rust + 142 Python tests** passed, with fmt/Clippy/release checks. Opus 5.5 on
`work2` accepted the bulk-path closeout after independent review fixes.

Private reproducible run: `.recordings/rust-legacy1ms-bulk-20261019T013315Z/`,
pinned code `64959f7`, source/code/binary hashes, external per-process resource
metrics, complete archive, codec cases and block-difference audit. Bulk uses two
source passes and bounded batches; it trades total CPU for elapsed time, not fidelity.

## Canonical Rust adaptive profile: full 41-hour validation

Completed 2026-10-18: **all 248 shards, 1,487,845 scans and 1,413,925,731
process readings**, producing 4,973 PST2 blocks. All source hashes/counts/ranges
were checked against the frozen capture. Every decoded observation was compared
with source identity/name/PPID/clocks/quality/RSS and native CPU values. Native
track endpoints were exact; point/interval bounds, zero/positive classification
and RSS-floor checks had **zero violations**. All **14 component decreases** remain
flagged with unavailable-rate semantics, not a restart inference.

This is the finer **adaptive-v1 policy, CSH2 wire version 2**, total CPU and 256 KiB
RSS. It preserves every positive observed CPU interval, unlike the fixed control's
sub-quantum plateaus. It is not an equal-fidelity compression comparison with the
historical fixed-1-ms profile below.

| Stage | Exact bytes |
| --- | ---: |
| Lossless source zstd JSONL | 2,778,751,489 |
| Expanded source JSONL, counted not stored | 109,018,766,562 |
| Emitted PST2 blocks, stored inside compressed archive | 4,108,298,001 |
| Archive PCR1 input, 265 frames (16 MiB target / 1-hour age bound) | 4,108,314,245 |
| Archive Brotli-5 payload | 708,668,994 |
| Whole frame files, including headers/checksums | 709,274,577 |

The archive's Brotli payload projects to **392.46 MiB/day**; whole frame files to
**392.80 MiB/day**, excluding catalog/status/filesystem overhead. The storage goal
remains unmet. Do not substitute the old fixed-profile 100.84 MiB/day for this
richer profile. Native CPU units are representation, not physical accuracy.

### Replay/preparation cost versus codec-only cost

`transform --verify` took **1,868.035 s wall (31m08s)** and **1,818.228 own CPU s**,
0 child CPU, with peak RSS **882,704,384 B (841.81 MiB)**. This includes replay,
quantization, retained-value decode verification and durable archive writing, not
just encoding or compression. It excludes initial CLI capture-metadata preflight;
the enclosing job took **1,891.399 s (31m31s)** end-to-end. Pipeline CPU is about
**1.22% of one core per recorded hour** at this source rate, not a native live
acquisition measurement. Offline all-history identity state grows; live state is
bounded separately. The earlier Python fixed-profile preparation was ~4h37m;
profiles and verification work differ, so this is not a pure-encoder speed ratio.

A separate cached-binary pass decoded/verified the full archive, then measured
Brotli-5/window-log-20 on actual PCR1 input, one worker, three sequential repeats
per frame. It repacked by bytes alone: **252 frames**, retained tail, maximum
actual input **16,772,263 B** against the 16 MiB target, no padding/repeated corpus.

- Actual codec input: **4,108,314,180 B (3.826166 GiB)**.
- Compressed payload: **708,297,357 B**, 5.8003× codec reduction.
- Encoder-only CPU: **58.676 s**, or **15.335 CPU-s/input GiB**; encoder wall sum
  **58.792 s**. These are sums of per-frame three-repeat medians, not a full-corpus
  median. Packing, hashing, source preparation and decode checks are outside the
  encoder timing. Total benchmark wall was 466.765 s, own CPU 464.643 s.
- The archive's one-hour age cap explains its extra frames and slightly larger
  payload. Backend: pure-Rust `brotli` 8.0.4; do not compare its CPU figure with
  historical C Brotli on different encoded input as an implementation speed claim.

### Independent controls and native closure

All **20 real first-shard legacy PST1 blocks were byte-identical** to the preserved
Python cache. On those same 6,431,392 readings, fixed-1-ms verification counted
553,558 positive intervals quantized to zero; adaptive counted zero. First-shard
CSH2 v2 used 18,450,076 B versus prototype v1's 22,158,587 B, saving 16.7% through
exact endpoint deltas without changing fidelity; v1 remains readable.

Finite native tests with process churn gave 30 scans / 28,235 readings in one block;
raw output gave 30 / 28,203 in one block. SIGTERM flushed 7 scans / 6,580 readings.
SIGKILL recovery preserved two durable scans and correctly remained incomplete.
A 31-second default-cadence test recorded **310 scans / 296,642 readings in two
blocks**, with a durable journal observed before clean completion. Its whole
observer/writer pipeline used 1.948 CPU s over 31.040 s (~6.28% of one core),
peak RSS 55,754,752 B; this short sample is not a long-run steady-state estimate.
An explicitly run native-reference test proved common-core live/replay PST byte
parity on actual native observations. These were finite tests, not a new campaign.

Opus 5.5 on `work2` reviewed architecture/design and follow-up fixes: **no remaining
production blockers**. Findings fixed include live new-PID block cuts, historical
startup revalidation, upstream incomplete raw status, exact endpoint storage,
publication capacity accounting and raw budget double-counting. Current validation:
**141 Rust tests + 142 Python tests**, optimized Python, fmt and strict Clippy;
the additional native-reference test is ignored by default and was run explicitly.

Private job `.recordings/rust-full-41h-20261018T213049Z/` retains source/code/binary
hashes, pinned `c38ff62` code, complete validation metrics, archive and codec results.
Subsequent fixes affect raw-output budgeting/status diagnostics, not this binary
profile. [Plan/status](RECORDING_PLAN.md) lists deployment boundaries.

## Historical Python prototype full-capture results: 41.33 hours

Completed 2026-10-17 in the fixed-profile prototype: **all 248 source shards**,
1,487,845 scans, **1,413,925,731 process readings**, 4,300,060 identities and
4,973 cached blocks.
Scan-clock duration is 148,784.400128417s. No source records were dropped.
This remains **fixed 1 ms total CPU / 256 KiB RSS**, not adaptive precision.

There were **14 observed component decreases**. The review ends a block before
each affected row, starts a native-exact baseline, and embeds original before/after
counters and unavailable-rate semantics in the following PST1 header. Those flag
bytes count in compression. This preserves observations, not a claim that counters
are globally monotone; rates across affected process intervals are unknown. The
strict reference preparer is unchanged. Extra cuts also create exact endpoints.

| Stage | Exact bytes | Size |
| --- | ---: | ---: |
| Expanded source JSONL, counted not stored | 109,018,766,562 | 101.532 GiB |
| Cached PST1 blocks, including quality flags | 643,849,941 | 614.023 MiB |
| PCR1 input, 16 MiB frame target | 643,865,082 | 614.038 MiB |
| Brotli-5 output, 1 MiB window | 182,080,781 | **173.646 MiB** |

That is **169.32× representation reduction**, then **3.536× codec compression**,
**598.74× overall**. Representation includes the declared precision/content losses.
Source acquisition files occupy 2,778,751,489 bytes of lossless zstd JSONL.

### Brotli-5 frame sweep

Same full cache, 1 MiB match window, one compression worker, three-repeat medians.
CPU is encoder-child seconds per actual uncompressed compact-input GiB.

| Frame input target | Frames | MiB/day | CPU s/input GiB |
| --- | ---: | ---: | ---: |
| 1 MiB | 655 | 107.908 | 21.72 |
| 4 MiB | 156 | 102.179 | 19.20 |
| 16 MiB | 39 | **100.837** | **18.43** |
| 64 MiB | 10 | 100.503 | 17.86 |
| 256 MiB | 3 | 100.425 | 17.88 |
| Whole actual 614.037 MiB | 1 | 100.400 | 17.92 |

The 256 MiB case now has **two near-target full frames plus a retained tail**
(maximum actual input 255.987 MiB). No repeated/padded data. At 16 MiB, maximum
observed frame coverage is 68.5 minutes; at 256 MiB, 17.42 hours. Whole covers all
41.33 hours. **16 MiB -> whole saves only 0.433%**; 4–16 MiB captures most benefit.
The preferred 16 MiB case is ~0.52% larger per day than the earlier 8.5-hour result.

At the same 16 MiB frame target:

| Codec / match window | MiB/day | CPU s/input GiB |
| --- | ---: | ---: |
| Brotli-6 / 1 MiB | 99.868 | 20.87 |
| zstd-3 / 16 MiB | 114.745 | 5.22 |
| zstd-9 / 16 MiB | 107.511 | 15.57 |

Brotli-6 saves **0.96%** versus 5 for **13.25% more encoder CPU**. All nine cases
round-tripped exactly; each repeated output size was identical.

### Preparation, not compression, is the CPU bottleneck

Python validation/encoding/verification took **4h37m16s wall**, ~4h37m14s total
CPU and **1.99 GiB peak self RSS**. That is 402.49 CPU-seconds per recorded hour
(~11.18% of one core at this data rate), not a production recorder benchmark.
The global identity-validation map grows with churn; bounded blocks do not imply
bounded total state. Brotli-5 at 16 MiB used only **11.05 encoder CPU-seconds** per
complete corpus pass. This supports prioritizing the Rust transform over codec tuning.

The complete finite job took ~4h47m, including nine codec cases with three repeats.
Cache, manifests, checkpoints, raw-source hashes, metrics and results are retained
under private, gitignored `.recordings/review-41h-python/` (`REPORT.md`,
`comparison.jsonl`, `cache/manifest.json`). Binary blocks are reusable without
reparsing the 101.5 GiB JSONL. Payload projections exclude catalogs/diagnostic
duplicates/filesystem overhead; quality flags themselves are included.

## Reference corpus for complementary sweeps: 8.5 hours

Measured 2026-10-15: **8.5 scan-clock hours**, 306,000 scans at nominal 10 Hz,
326,450,656 process readings, 886,984 identities; 51 continuous source segments.
The snapshot ends at sequence 305,999. Wall span was 8h31m30s; both clocks are
retained. All daily figures below project from the 30,599.902s scan-clock span,
not an observed day (wall-span normalization would be ~0.29% lower).

Representation is unchanged across every case: all observations/coverage,
names/PPID and observed wall/scan bounds; total CPU with <1ms interior error and
exact native **30s encoding-block** endpoints; RSS floored to 256 KiB. User/system
split is omitted. Small RSS changes can disappear. No churn or singleton filter.

### Overall reduction, not just the final codec ratio

Same observations; Brotli-5 here uses 16 MiB frames and a 1 MiB window:

| Stage | Exact bytes | Size | Reduction versus original JSONL |
| --- | ---: | ---: | ---: |
| Expanded source JSONL | 25,233,101,842 | 23.50 GiB | 1× |
| Framed compact binary | 139,953,873 | 133.47 MiB | 180.30× |
| Brotli-5 output | 37,252,743 | 35.53 MiB | **677.35×** |

Binary representation gives ~180× reduction; Brotli adds **3.7569×**, for
**677.35× overall (99.852% fewer bytes)**. The first stage includes the precision
tradeoffs above; its lossless-only contribution has not been isolated. Binary
blocks themselves occupy 139,950,768 bytes; frame wrappers add 3,105 bytes.

JSONL sizes were streamed/count-checked against all 51 decompressed source hashes,
including headers/newlines, excluding separate diagnostics. The source is already
stored losslessly as zstd-3, using 583,888,358 bytes (556.84 MiB), not 23.50 GiB of
expanded files. The smaller final representation also retains less native fidelity.
See [the format walkthrough](RECORDING_DATA.md) for original unredacted records,
worked CPU/RSS encodings, byte layouts and decoding order.

**Input GiB = 1,073,741,824 bytes of this uncompressed binary after representation
and quantization**, not raw JSON, compressed output or process RAM. One input GiB
represents ~65 recorded hours at this rate; CPU costs are normalized from 133.47 MiB.
Encoding blocks remain fixed while compression frames change. Codec versions:
zstd 1.5.7 / Brotli 1.2.0. Three-repeat medians, except expensive zstd-19/Brotli-11
cases: one complete corpus pass each. All compressed frames round-trip exactly.

## Complementary 8.5-hour frame/strong-codec sweep

Same entire corpus, one compression worker, requested match window 16 MiB (log 24).
All codec columns are projected **MiB/day**; — means not measured.

| Frame input target | Maximum scan-clock coverage | zstd-3 | zstd-9 | zstd-19 | Brotli-6 | Brotli-11 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 256 KiB | 1 min | 184.33 | 179.06 | — | 165.20 | — |
| 1 MiB | 3.5 min | 124.01 | 118.76 | — | 108.46 | — |
| 4 MiB | 15.5 min | 116.15 | 109.73 | 100.86 | 101.02 | 83.71 |
| 16 MiB | 62.5 min | 114.49 | 107.13 | 97.51 | 99.84 | 82.39 |
| 64 MiB | 4.1 hours | 114.31 | 106.44 | — | 99.48 | — |
| Whole corpus: **133.47 MiB actual** | 8.5 hours | 114.24 | 106.21 | 96.01 | 99.37 | **81.82** |

Whole-corpus tests used a 256 MiB target but **did not fill it**. They are not
256 MiB or GiB-scale frame measurements. Whole ~30s blocks are indivisible; all
tails and framing bytes are retained, and achieved frame sizes are recorded.

**Most gains arrive at 4–16 MiB: roughly 15–60 minutes on this host/workload.**
- Brotli-6: 15 minutes -> whole corpus saves another **1.63%**; one hour -> whole
  saves **0.47%**. Larger frames also lowered measured encoder CPU here, so they
  are not worse on the stated objectives—just diminishing storage returns.
- Brotli-11: 15 minutes -> whole saves **2.26%**, for **22% more encoder CPU**.
  One hour -> whole saves **0.69%**, for 4.4% more CPU.
- zstd-9: 15 minutes -> whole saves 3.2%; one hour -> whole saves 0.85%.
  zstd-19 gains more: 4.8% / 1.53%, respectively, but uses more CPU as frames grow.

Thus an hour-sized frame captures nearly all measured benefit; ten-hour frames
are not necessary for the bulk saving. Longer frames remain legitimate when the
last fraction of storage matters. This is not a read-cost cutoff or a universal
plateau across representations/workloads.

## Complementary 8.5-hour codec CPU/window/thread tradeoffs

Whole-corpus frames; window log 24 unless marked. Ratio = codec input / output.

| Codec | Ratio | MiB/day | CPU s/GiB | Wall s/GiB |
| --- | ---: | ---: | ---: | ---: |
| zstd-3 | 3.30 | 114.24 | 5.8 | 6.4 |
| zstd-9 | 3.55 | 106.21 | 16.8 | 14.8 |
| zstd-9, 2 workers | 3.59 | 105.01 | 17.5 | 13.4 |
| Brotli-6, **1 MiB window** | 3.81 | 98.79 | 20.7 | 24.7 |
| zstd-19 | 3.93 | 96.01 | 388.2 | 388.1 |
| Brotli-11 | 4.61 | **81.82** | 1,687.3 | 1,698.1 |

Brotli-11 saves 17.2% versus the best tested Brotli-6 setting, costing ~82x the
CPU. That is ~26 encoder CPU-seconds per recorded hour (~0.72% of one core).
These are **encoder-process** user+system CPU costs, including child startup and
all workers; preparation, parent-side framing and verification are excluded.
Wall timings include CLI setup/IPC; default CLI I/O settings are retained.
Normalized GiB units are not measured GiB frames. Memory costs and complete
production recorder costs are not benchmarked.

A frame's length and its **match window** are separate:
- Brotli-6 whole-corpus output: 1 / 16 / 128 MiB requested windows gave
  **98.79 / 99.37 / 99.36 MiB/day**. A wider dictionary did not help this case.
- zstd-9: 1 -> 16 MiB window saved 1.45%; 128 MiB added no further saving.
  At 128 MiB, long-distance matching made size and CPU slightly worse.
- zstd-9 whole-corpus 2/4/8 workers produced the same size and ~13.3s/GiB wall,
  versus 14.8 single-thread, but ~17.5 vs 16.8 CPU s/GiB. No scaling beyond two
  with these job defaults. At 16 MiB frames, extra workers were slower.
- Brotli's 128 MiB window used its explicitly nonstandard large-window extension.
  Requested limits are not allocation or effective-match-distance measurements.

## Complementary 8.5-hour Brotli levels and windows

20 additional measurements: same corpus, **16 MiB frames**, one worker, three-run
medians. Each cell is **projected MiB/day / encoder CPU s/input GiB**.

| Match window | Level 4 | Level 5 | Level 6 | Level 7 | Level 8 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 256 KiB | 112.81 / 12.6 | 100.37 / 18.2 | 99.59 / 20.7 | 99.04 / 30.7 | 98.93 / 34.8 |
| 1 MiB | 112.71 / 12.9 | 100.31 / 18.3 | 99.33 / 21.0 | 98.44 / 36.5 | 98.26 / 44.9 |
| 4 MiB | 112.85 / 13.3 | 100.46 / 18.7 | 99.50 / 21.8 | 98.21 / 48.7 | 97.89 / 69.4 |
| 16 MiB | 113.06 / 14.1 | 100.81 / 20.6 | 99.84 / 23.8 | 98.63 / 58.5 | 98.23 / 94.9 |

At a 1 MiB window, level 5 is ~1% larger than 6 but uses **13% less CPU**;
7 saves another 0.9% versus 6 for **74% more CPU**. Levels 5/6 are attractive
background candidates, not a claim that 6 is uniquely optimal. Wider windows
barely help 4–6. Levels 7/8 gain a little at 4 MiB, at sharply higher CPU; 16 MiB
is worse than 4 MiB on both objectives for every tested level. These CPU ratios
remain small absolute costs: level 5/6/7 at 1 MiB use 0.28/0.32/0.56 CPU-seconds
per recorded hour. Acquisition and representation preparation remain excluded.
Brotli-5's window sweep here uses 16 MiB frames. Its **full 41-hour frame-size
sweep is now above**; this older frame/strong-codec table uses 6/11 and zstd.

## Integrity, limitations, next lever

The original frozen snapshot covered nine hours. At 8h36m one process's system
counter decreased ~0.237ms while user CPU increased. The strict replay rejected
it. This sweep uses the **unchanged contiguous first 8.5 hours**, not selected
"good" records with an undisclosed hole. Original source and anomaly details
remain private/intact. Within that 8.5-hour prefix, all tested source/block hashes,
coverage and cross-segment component monotonicity passed; all 326 million retained
readings were verified in preparation. No fidelity rule was relaxed.

The full 41-hour review above is a separate, explicitly flagged profile: it retains
the anomalous observations and marks unavailable-rate intervals rather than
silently weakening the strict checks or claiming global component monotonicity.

Encoded input still projects to **376.85 MiB/day**, compressed best **81.82**.
Indexes/catalogs, persisted health diagnostics, retention and filesystem overhead
are outside these payload numbers. Native scans are not atomic and visibility
is incomplete. More hours per frame will not close the measured budget gap;
representation/precision is the next useful lever, not waiting for 72 hours.

The Rust recorder's full-corpus adaptive validation and Opus closeout review are
complete, as recorded above and in the [plan](RECORDING_PLAN.md). Historical
prototype measurements remain valid for their stated source and settings. See
[real data examples](RECORDING_DATA.md).

43 frame/settings cases plus 20 neighboring-Brotli measurements (including two
control rechecks) and fixed source/block manifests are private under
`procstats-nine-hours-bxwo_imv`; provenance digest starts `d4079a2e84413c7d` (SHA256
of the ordered compressed-source digest list, not a single expanded JSON file).
Private `prepare_part.py`, `merge_prepared.py`, `analyze.py` and
`brotli_midlevels.py` reproduce this snapshot using the existing storage/compression
modules; no new public framework.
