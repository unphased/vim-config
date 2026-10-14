# Process-history storage: current scorecard

Goal: ~10 MB/day encoded, ideally ~1 MB/day compressed, useful for RCA and cheap
enough to record continuously. **Not met.** No production sampler/config/startup
changes. Old experiment rundowns are in Git history, not reproduced here.

## What we are comparing

```text
real observations -> fixed representation/precision -> codec-input byte frames
                  -> codec + level + window + zstd workers -> size / CPU frontier
```

Rank **compressed bytes versus compression CPU-seconds per input GiB**. Report
wall-seconds/GiB separately: parallelism can improve throughput without improving
CPU efficiency. Read latency does not constrain frame size or enter the ranking;
decompression verifies correctness. Do not repeat captured data to fill a frame.

## Current evidence — only ten minutes

599.9007s at nominal 10 Hz; 6,334,450 readings, 19,963 identities. The fixed input
below retains all observed identities/availability, names/PPID and exact wall/scan
bounds. Total CPU has 1 ms point precision with exact native 30s-block endpoints;
RSS is floored to 256 KiB (underestimate <256 KiB). User/system split is omitted.
This is a precision tradeoff, not full native fidelity. Small RSS spikes can vanish.

The **entire compact binary input is only 2.68 MiB**, not the 466 MiB source JSON.
The figures below are medians of three runs, normalized from that small corpus;
**they are not GiB-scale throughput measurements or observed daily totals**.
CLI startup is included. Codec versions: zstd 1.5.7, Brotli 1.2.0.

| Codec/level | Window log | Ratio¹ | MiB/day² | CPU s/GiB | Wall s/GiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| zstd-1 | 24 | 2.31 | 166.75 | 5.4 | 8.1 |
| zstd-3 | 24 | 3.05 | 126.70 | 6.9 | 8.6 |
| zstd-9 | 24 | 3.21 | 120.13 | 15.3 | 14.5 |
| zstd-19 | 24 | 3.48 | 110.84 | 226.7 | 226.0 |
| Brotli-4 | 20 | 3.09 | 124.83 | 14.5 | 19.4 |
| Brotli-6 | 20 | 3.49 | 110.66 | 22.0 | 26.9 |
| Brotli-9 | 24 | 3.54 | 108.89 | 58.2 | 62.9 |
| Brotli-11 | 24 | 4.18 | **92.29** | 1,506.9 | 1,514.0 |

¹ Codec input / output; larger is better. Same block-major input, single-thread.
² Short-capture projection, excluding archive catalogs/indexes/filesystem overhead.
Fast-case timings are noisy at this corpus size; CPU/wall medians are independent.

**Useful provisional result:** Brotli-6 matched zstd-19's size at about one-tenth
the compression CPU. Brotli-11 saved another ~17% versus Brotli-6, at ~69 times
the CPU. There is a tradeoff frontier, not one universal codec winner.

Byte-target tests used 256 KiB / 1 MiB / 4 MiB. Whole ~30s encoding blocks are
indivisible: actual maximum frame inputs were 149,336 / 985,198 / 2,809,693 bytes.
The 4 MiB target was **underfilled**; it is not evidence for larger frames.
Regrouping headers/CPU/metadata into separate lanes was lossless but did not
consistently help (-1.5% to +6.0% across selected cases). Existing sparse masks
also beat the smaller raw lifecycle-column encoding under the strongest Brotli.

Other current findings: 64/256 KiB RSS precision saved ~7.5%/~12.8% versus exact
RSS on the same mask layout. ~1,892 identities/minute were newly observed; 78% of
identities appeared in one scan, but only 13 existing identities changed PPID.
Missing does not prove exit; polling misses some complete short lifetimes.

## Longer acquisition and next sweep

A **finite 72-hour, 10 Hz capture started 2026-10-14 20:51 UTC**, using one native
sampler across losslessly compressed 10-minute source segments. Raw fields are
preserved for future representations. Private files; 24 GiB capture budget,
20 GiB free-space guard; SIGTERM stops/reaps it. No restart/daemon installation.
The corpus includes actual development/benchmark activity, not a quiet workload.
Sleep can extend wall-clock completion; actual wall/scan markers are retained.
At the prior binary rate, ~1 GiB of compact input needs 2–3 days; acquisition is
still in progress. Do not advertise an underfilled large target as a full test.

Staged comparison, holding representation/precision constant:
- Byte targets: **1 / 4 / 16 / 64 / 256 / 1,024 MiB**, then larger if data permits.
- Locate the frame-size plateau before sweeping every other parameter.
- Sweep codec levels and window limits around the useful frontier. Explicitly
  label nonstandard Brotli large-window streams; test zstd long-distance matching.
- Compare zstd 1/2/4/8 workers on sufficiently large inputs. On today's 2.68 MiB
  input, extra workers mostly add overhead and cannot establish scaling.
- Retain all tails, framing overhead and real time coverage. Use repeated total
  child CPU (user+system, all threads), not elapsed time as a CPU substitute.

**Representation examples and brainstorming:** [RECORDING_DATA.md](RECORDING_DATA.md).
The 30s identity/CPU baselines are a separate axis from compression-frame size.
No higher-resolution detail is silently discarded to improve a codec result.

## Reproduce

From this directory; captures/results are private and refuse overwrites.
`recording_storage.py` also reads completed `.jsonl.zst` source segments directly,
without expanding whole source files. Joining their prepared manifests and the
long-corpus sweep are pending acquisition, not completed results.

```sh
python3 recording-probe.py --samples 2592000 --interval .1 --capture-dir /private/source
python3 recording_compression.py --input-dir /private/prepared \
  --frame-bytes 1048576 4194304 16777216 67108864 268435456 1073741824 \
  --zstd-levels 3 9 19 --brotli-levels 6 9 11 --windows 20 24 \
  --repeats 3 --output /private/comparison.jsonl
# Test zstd parallelism separately on shortlisted large frames:
# --codecs zstd --zstd-threads 1 2 4 8
# --zstd-long-distance; or --brotli-large-window with --windows 27 30
```

Binary preparation remains an offline Python experiment, not a production
encoder; its CPU/validation cost is excluded from the codec-only table. Native
sampling has scan skew and incomplete visibility. Seek catalogs, host/boot
metadata, retention policy and total service resource costs remain unmeasured.
