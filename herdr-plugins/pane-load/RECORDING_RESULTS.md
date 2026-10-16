# Process-history storage: current scorecard

Goal: ~10 MB/day encoded, ideally ~1 MB/day compressed. **Not met.** No
production sampler/config/startup changes. Older rundowns remain in Git history.

```text
real observations -> fixed representation -> independent byte-sized frames
                  -> codec / level / match window / workers -> size vs CPU
```

Rank storage against **compression CPU-seconds/input GiB**; wall time is separate.
Read costs do not constrain frames. Decompression only verifies correctness.

## Corpus and fidelity

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

## How large do frames need to be?

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

## Storage / compression-CPU tradeoffs

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

## Neighboring Brotli levels and windows

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
**Brotli-5's window sweep is complete at 16 MiB frames; its frame-size sweep has
not been run.** The frame-size plateau above was measured with 6/11 and zstd.

## Integrity, limitations, next lever

The original frozen snapshot covered nine hours. At 8h36m one process's system
counter decreased ~0.237ms while user CPU increased. The strict replay rejected
it. This sweep uses the **unchanged contiguous first 8.5 hours**, not selected
"good" records with an undisclosed hole. Original source and anomaly details
remain private/intact. Within that 8.5-hour prefix, all tested source/block hashes,
coverage and cross-segment component monotonicity passed; all 326 million retained
readings were verified in preparation. No fidelity rule was relaxed.

The longer diagnostic was stopped by request at 41h19m44s and preserved compressed
locally. This scorecard and its semantic-validation claims have not been extended
to that full span.

Encoded input still projects to **376.85 MiB/day**, compressed best **81.82**.
Indexes/catalogs, persisted health diagnostics, retention and filesystem overhead
are outside these payload numbers. Native scans are not atomic and visibility
is incomplete. More hours per frame will not close the measured budget gap;
representation/precision is the next useful lever, not waiting for 72 hours.

Next-work scope and approval questions live only in the [plan](RECORDING_PLAN.md).
Adaptive CPU precision is planned research, not implemented or measured here;
Rust buildout awaits scope review and user approval. See [real data examples](RECORDING_DATA.md).

43 frame/settings cases plus 20 neighboring-Brotli measurements (including two
control rechecks) and fixed source/block manifests are private under
`procstats-nine-hours-bxwo_imv`; provenance digest starts `d4079a2e84413c7d` (SHA256
of the ordered compressed-source digest list, not a single expanded JSON file).
Private `prepare_part.py`, `merge_prepared.py`, `analyze.py` and
`brotli_midlevels.py` reproduce this snapshot using the existing storage/compression
modules; no new public framework.
