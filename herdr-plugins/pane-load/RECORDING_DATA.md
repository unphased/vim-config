# Process-history bytes: from source records to compressed frames

The long worked tutorial below remains the measured **Python fixed-profile
prototype** reference; it is not the current Rust adaptive layout or a proposed
standard. Its original examples and measurements are retained. The concise Rust
wire summary at the end describes the implemented format. See
[RECORDING_RESULTS.md](RECORDING_RESULTS.md) for provisional Rust first-shard
validation and the separate historical full 41-hour prototype comparison.

This guide's size example uses the earlier verified 8.5-hour corpus: 306,000 scans,
326,450,656 process readings and 886,984 identities. The worked source examples
come from the earlier ten-minute capture, SHA256
`033d51988cc605a51d57a8d893e0bed71fbe3cb7747849790466e5daa95809b2`, using the same
representation. **Names, PIDs, parent PIDs and timestamps below are original,
unshifted and not anonymized.** These are selected excerpts, not the entire capture.

## 1. How much reduction has already happened?

Same 8.5-hour observations throughout; Brotli-5 uses 16 MiB input frames and a
1 MiB match window, with one compression worker:

| Stage | Exact bytes | Readable size | Reduction versus raw JSONL |
| --- | ---: | ---: | ---: |
| Original, expanded JSONL | 25,233,101,842 | 23.50 GiB | 1× |
| Independent binary encoding blocks | 139,950,768 | 133.47 MiB | 180.30× |
| Binary blocks plus compression-frame wrappers | 139,953,873 | 133.47 MiB | 180.30× |
| Brotli-5 output | 37,252,743 | 35.53 MiB | **677.35×** |

The representation reduces the original JSONL by **~180×**. Brotli then reduces
its binary input by **3.7569×**. Together that is **677.35×**, or **99.852% fewer
bytes than the original JSONL**. Ratios are rounded, so rounded factors need not
multiply to the final printed digits.

**The first stage is not entirely lossless compression.** It combines removal of
repeated information with intentional CPU/RSS precision changes and omission of
the user/system CPU split. Brotli itself is lossless relative to those binary
bytes. We have not isolated the lossless-only portion of that 180× on this corpus.

The expanded JSONL does not occupy 23.50 GiB on disk: acquisition already stores
it losslessly as zstd-3 source segments, totaling 583,888,358 bytes (556.84 MiB).
The final Brotli binary is 15.67× smaller than that source archive, but also has
lower fidelity. The size table excludes separate acquisition diagnostics,
indexes/catalogs and filesystem overhead. Source byte counts include each
segment's header and newlines; every segment was streamed, counted and checked
against its recorded decompressed SHA256, without writing an expanded corpus.

Here, **CPU seconds/input GiB** means CPU needed for 1,073,741,824 bytes of the
uncompressed, already encoded/quantized binary entering Brotli—not source JSON,
compressed output or process memory. One input GiB represents ~65 recorded hours
at this run's data rate. Actual input was 133.47 MiB; GiB costs are normalized.
This is codec-only CPU cost, excluding acquisition and building the binary data.

## 2. What does one original observation look like?

A scan is one sampler pass over readable processes. This is scan 0 with the two
processes discussed below selected from its much larger `processes` array.
**Every field of these two records, and all scan metadata, is unchanged.**

```json
{
  "seq": 0,
  "wall_start_ns": 1791944979753882000,
  "scan_start_ns": 22000,
  "scan_end_ns": 3535125,
  "processes": [
    [87412, 86529, 1791944979, 612630, "procstats-recording-probe", 1189125, 1912500, 1540096],
    [17970, 1, 1790145305, 564952, "ghostty", 122921800301458, 15420500223791, 502120448]
  ]
}
```

The outer fields mean:

| Field | Meaning |
| --- | --- |
| `seq` | Global scan sequence number; it does not reset at a source-file rotation. |
| `wall_start_ns` | Observed wall-clock timestamp, nanoseconds since the Unix epoch. |
| `scan_start_ns` | Elapsed monotonic scan-clock time since this sampler's origin. Not an epoch timestamp. |
| `scan_end_ns` | Same clock, after acquisition. Subtract start to obtain scan duration. |

Every process tuple has these **eight positions**, in this order:

| Position | Field | Meaning / unit |
| ---: | --- | --- |
| 0 | PID | Numeric process ID. |
| 1 | PPID | Observed parent PID. |
| 2 | Start seconds | Process birth timestamp's Unix-epoch seconds. |
| 3 | Start microseconds | Fractional part of that birth timestamp, in microseconds. |
| 4 | Name | Observed process name, not argv or environment. |
| 5 | User CPU | Cumulative user execution time, normalized to integer nanoseconds. |
| 6 | System CPU | Cumulative system execution time, normalized to integer nanoseconds. |
| 7 | RSS | Resident memory, in bytes. |

`(PID, start seconds, start microseconds)` is the identity within this capture.
PID alone is unsafe because the OS reuses it. A future multi-host archive also
needs host/boot scope; this experiment uses one continuous capture run.

CPU values are **counters**, not utilization percentages. Differences between
two readings give observed CPU-time increments. Divide by actual elapsed time
and multiply by 100 for CPU%; multicore processes can exceed 100%. A first
counter value is a baseline, not CPU newly consumed since the previous scan.
Nanosecond representation does not imply nanosecond measurement accuracy, and
the scan is not an atomic snapshot: individual processes are read at different
times between its bounds. We do not have their individual read timestamps.

## 3. Three different sizes: scans, blocks and frames

```text
raw JSONL scans, nominally 10 per second
    |
    | restore native CPU counters; sum user + system; quantize CPU and RSS
    v
~30s ENCODING BLOCKS, each independently decodable
    +-- CPU section: shared clock + identities + coverage + counter changes
    +-- metadata section: scan times + identity/name/parent/RSS changes
    |
    | group whole blocks; no new sampling or precision change here
    v
COMPRESSION FRAME, e.g. 16 MiB of binary input (~one hour here)
    |
    | Brotli-5, e.g. 1 MiB MATCH WINDOW
    v
compressed bytes, much smaller than the 16 MiB input
```

- **Scan:** one observation pass, roughly every 100 ms in this capture.
- **Encoding block:** normally 300 scans, about 30 seconds. Identity/baseline
  state starts afresh in each block. A point-count safety limit can end it sooner.
- **Compression frame:** several already encoded blocks compressed together.
  A 16 MiB target is input bytes, not output bytes or a 16-minute time period.
  Whole blocks are indivisible; the final frame can be short, and a block larger
  than the target would be retained alone rather than discarded.
- **Match window:** how far backward the compressor can refer to matching bytes
  within its stream. It is **not** how much process history we keep. A 1 MiB
  window can compress a frame hundreds of MiB long; older history is not lost.

The 1,020 encoding blocks average ~134 KiB. A 256 KiB–1 MiB window can therefore
reach nearby blocks with repeated identities and baselines. This fits the
measured lack of gains from huge windows, but is not proof of an entropy floor.
**Larger compression frames do not remove the 30s baseline resets.** Changing
those resets is a separate representation experiment.

In the long corpus's first 30s block only, 95.6% of successive observed CPU
readings had no whole-millisecond counter change. We already omit those zero
quotient changes. Brotli is not being fed dense arrays of all unchanged readings.

## 4. The basic tools: integers, differences, runs and masks

The format does not write a JSON object for every process on every scan. It uses
small integers and remembers enough prior state to reconstruct later observations.

**Unsigned variable-length integer (`U` below).** Seven value bits per byte;
the high bit says whether another byte follows. Small numbers take one byte.
For example, decimal 300 becomes hexadecimal `ac 02`:
`44 + 2 × 128 = 300`. It is not the text characters `"300"` or a fixed 8-byte integer.

**Signed variable-length integer (`S`).** First map signed values to unsigned
ones: `0 -> 0`, `-1 -> 1`, `+1 -> 2`, `-2 -> 3`, `+2 -> 4`; then use `U`.
Thus a metadata change of `+1` is byte `02`, while unsigned CPU increment 1 is
byte `01`. The tables below distinguish these two encodings.

**Difference.** Instead of repeating an absolute counter, store a baseline and
how much it changes. RSS can fall, so its changes are signed. Validated cumulative
CPU quotients do not fall, so their changes are unsigned.

**Run.** Represent consecutive observed positions with a start and length.
For a process present at all 300 scans, one run replaces a list of 300 positions.
Runs preserve which scans actually contain a reading; they do not invent readings
where a process was absent.

**Mask.** A small integer whose bits say which fields changed. If only RSS
changed, there is no reason to repeat the name, parent and other values.

**Length prefix.** Before a variable-sized byte string, write its byte count.
The reader can then locate the next section without searching for a separator.
Names use UTF-8 byte lengths, not character counts. No JSON key strings are
repeated for these fields; encoder and decoder agree on their order.

## 5. CPU: baseline + sparse changes + exact endpoint fractions

CPU is stored separately from metadata because many processes can share one
scan clock, and most counters do not change by a whole millisecond at every poll.

### Native ticks and the deliberate 1 ms tradeoff

Think of CPU time as a distance, and the OS counter as a ruler that uses its own
small units. A **native tick** is one unit on that ruler. It is not one CPU
instruction, one processor cycle, or one sampler poll.

On this Mac, the OS supplies a conversion factor: **one tick = 125/3 nanoseconds**,
about **41.67 ns**. That is nanoseconds, **not milliseconds**. We measured/verified
this host's scale; we did not choose it, and it is not universal. The numerator
125 and denominator 3 are the tick-to-nanosecond scale reported by macOS's
`mach_timebase_info`. A nanosecond is a billionth of a second; a millisecond is a
thousandth, so **1 ms = 1,000,000 ns**. These units describe representation, not a
promise that the CPU measurement is accurate to one tick.

Separately, **we choose 1 ms as the interior CPU-counter precision** to save space.
That choice means keeping whole milliseconds instead of every tiny fraction.
How many OS ticks make one of our chosen 1 ms units?

```text
1,000,000 ns ÷ (125/3 ns per tick) = 24,000 ticks
```

So none of these numbers is a secret protocol rule:

| Number | Where it comes from | Meaning |
| --- | --- | --- |
| 125/3 ns per tick | This Mac's OS timebase | Converts its native CPU units to familiar time. |
| 1 ms | Our storage/detail tradeoff | The chosen whole-unit precision for interior CPU readings. |
| 24,000 ticks | Calculated from the two above | One whole millisecond, expressed in this Mac's units. |

We call that group size **Q** (the quantization unit). Lowercase **q** is the number
of whole groups, and **r** is the leftover ticks. The format records Q and the
conversion factor so the reader does not have to guess them.

The probe's source fields have already been converted to integer nanoseconds.
Preparation restores the original native counts and checks that converting them
back reproduces the source values. The inverse needs rounding upward when the
original conversion rounded down; this avoids losing the exact native endpoints.

For `procstats-recording-probe`, PID **87412**, at scan 0:

```text
source user CPU:    1,189,125 ns -> 28,539 native ticks
source system CPU: 1,912,500 ns -> 45,900 native ticks
combined counter:                74,439 native ticks

Q = 24,000 ticks = exactly 1 ms
74,439 = 3 × 24,000 + 2,439
         quotient q   remainder r
```

We store the **total**, not separate user/system histories. Each cumulative total
is divided by Q. Quotient 3 means the whole-millisecond portion is 3 ms, not that
the source counter was exactly 3 ms: it was **3.101625 ms**. In ruler terms:
**three whole 1 ms groups, plus a 0.101625 ms leftover**. We save that leftover
at block endpoints so those counters remain exact.

We round the **cumulative counter**, not each little increment separately. Tiny
increments still accumulate in the original counter; once they cross a whole-ms
boundary, q advances. We do not repeatedly round small increments down to zero
and forget them. Also, **1 ms precision is not a 1 ms sampling interval**: this
capture polls about every 100 ms, independently of the CPU rounding choice.

The first 16 quotient values and their 15 differences are:

```text
q (whole ms): [3,7,11,15,18,22,26,30,34,38,42,46,50,54,58,62]
q increments: [4,4,4,3,4,4,4,4,4,4,4,4,4,4,4]
```

The wire starts with quotient 3 and stores nonzero changes as pairs:

```text
(sample-position delta, quotient increment): (1,4), (1,4), (1,4), (1,3), ...
actual pair bytes, hexadecimal:               01 04  01 04  01 04  01 03 ...
```

A position delta of 1 means the next change is at the next observation of this
process, not one millisecond later. The clock and observation runs supply time.
A zero quotient increment produces no change pair; a later position delta skips
past unchanged observations. These are differences of whole-ms quotients, **not
exact differences of endpoint-corrected CPU counters**.

At the first/last observations of this process in the full 30s block, native
remainders are **2,439 / 13,400 ticks**. Both are stored. The reader reconstructs
those endpoint counters exactly as `q × Q + r`. Interior values normally use
`q × Q`; the reader also prevents a decrease below its prior reconstructed value
when the exact first endpoint lies above a quotient boundary. Interior error
remains `0 <= source - decoded < 1 ms`.

**Exact endpoints do not mean exact CPU at every poll.** The endpoint rule is per
identity per encoding block, not per compression frame and not an exact exit total.
An identity observed only once retains its entire native counter exactly.

### A real singleton, all the way to bytes

`sleep`, PID **87417**, birth **1791944979 seconds + 757674 microseconds**, appears
only at scan 1 within this block. Its original record is:

```json
[87417,32239,1791944979,757674,"sleep",1993708,2189458,1245184]
```

Its restored total is **100,396 ticks = 4 × 24,000 + 4,396**. In the shared CPU
clock, scan 1 is position 1. This is the actual 21-byte per-process CPU record
inside that block; the shared header/clock is outside this record:

| Field, in wire order | Decimal value | Actual hexadecimal bytes |
| --- | ---: | --- |
| PID | 87417 | `f9 aa 05` |
| Start seconds | 1791944979 | `93 d2 bb d6 06` |
| Start microseconds | 757674 | `aa 9f 2e` |
| Number of observations | 1 | `01` |
| Number of coverage runs | 1 | `01` |
| First run's gap from position 0 | 1 | `01` |
| Run length | 1 | `01` |
| First CPU quotient | 4 | `04` |
| Number of quotient changes | 0 | `00` |
| First native remainder | 4396 | `ac 22` |
| Last native remainder | 4396 | `ac 22` |

Every field here is `U`. The two equal remainders really are stored twice in the
current format; that is not a proposed optimization. PPID, name and RSS live in
the other section. A single observation cannot prove when this process exited
or recover CPU used after its last reading.

## 6. Metadata: keep state, emit only what changes

The metadata section assigns each newly observed identity a small **slot number**
within the block. It initially stores the identity, parent, name and RSS baseline.
Later scans normally reference that slot instead of repeating the full identity.

In this default **mask layout**, there is no separate process-name dictionary.
A name is written at identity creation and on a name change; outer compression
can reuse repeated strings such as `sleep`. The CPU section has its own identity
list, so identities and scan clocks currently repeat across the two sections.

For each subsequent scan:

- Same observed process, unchanged metadata: emit no process update; retain state.
- Changed name/parent/RSS: emit the slot, change mask and just the changed values.
- Previously observed process absent now: emit `MISSING`, remove it from the
  active observed set, but keep its identity/state for a possible return.
- Same identity observed again: emit `RETURN`, optionally with changed fields.
- Reused PID with a different birth timestamp: allocate a different identity/slot.

For an **active** slot, no update means it was observed with unchanged metadata.
An inactive slot stays absent until `RETURN`. `MISSING` changes a slot from active
to absent; absence does not prove exit. We retain every scan and its observed
process set; sparse encoding is not a sampling or lifetime filter.

### Actual RSS example: `ghostty`, PID 17970

RSS is read alongside CPU in every nominal **10 Hz scan**, not on a slower
schedule. Each readable-process observation has a point-in-time RSS reading;
it is not a 100 ms average. Sparse encoding omits unchanged quantized values,
not their observations or actual scan timestamps.

This process's birth is **1790145305 seconds + 564952 microseconds**, PPID **1**.
Here are its original RSS bytes and what the 256 KiB variant stores:

| Scan | Original RSS bytes | Stored integer `floor(RSS / 262144)` |
| ---: | ---: | ---: |
| 0 | 502120448 | 1915 |
| 1 | 502153216 | 1915 |
| 2 | 502235136 | 1915 |
| 3 | 502317056 | 1916 |
| 4 | 502382592 | 1916 |
| 5 | 502431744 | 1916 |
| 6 | 502464512 | 1916 |
| 7 | 502464512 | 1916 |

After baseline 1915, only a `+1` RSS change is needed for these eight scans.
The block header says one stored unit is 262,144 bytes. Decoded RSS is
`stored_integer × 262144`, underestimating the source by less than 256 KiB.
This loses small changes/spikes; it does not preserve the exact allocation curve.

In the actual metadata encoding, `ghostty` is slot **270**. At scan 3 the previous
changed slot is 78, so the gap is `270 - (78 + 1) = 191`. This RSS update is:

```text
slot gap U(191)    RSS mask U(64)    RSS increment S(+1)
bf 01             40                02
```

**Four bytes**, rather than another full process record. The slot gap is relative
to the previous changed slot in this scan, not relative to the PID or scan number.
The user/system fields of metadata are zero placeholders because CPU is in its
own section; these zeros must not be interpreted as the process having zero CPU.

For contrast, the same `ghostty` process has less regular whole-ms CPU increments:

```text
[12,35,28,10,16,9,9,42,28,22,39,16,38,45,45]
```

Replacing that sequence with a constant average would change fidelity. Encoding
its differences differently need not do so.

## 7. Clocks and short-lived processes are real data too

These are the original, unshifted clock fields of the first eight source scans.
Elapsed scan times are naturally relative to the sampler origin, not redacted:

| Scan | Wall start, Unix ns | Scan start, elapsed ns | Scan end, elapsed ns |
| ---: | ---: | ---: | ---: |
| 0 | 1791944979753882000 | 22000 | 3535125 |
| 1 | 1791944979858891000 | 105035000 | 108425792 |
| 2 | 1791944979956271000 | 202418500 | 205889417 |
| 3 | 1791944980054595000 | 300746833 | 303952000 |
| 4 | 1791944980156526000 | 402681875 | 405942417 |
| 5 | 1791944980256130000 | 502288875 | 505729458 |
| 6 | 1791944980357431000 | 603594375 | 606927750 |
| 7 | 1791944980456465000 | 702631625 | 706107292 |

For example, successive scan-start differences are
`105013000, 97383500, 98328333, 101935042, 99607000, 101305500, 99037250` ns,
not a string of 100,000,000s. We preserve observed timing jitter and wall/scan-clock
relationships. A predictor plus exact residuals could change the encoding without
losing these values; replacing them with a nominal period would lose information.

The six previously illustrated newly observed `sleep` processes are below with
**all original tuple fields, no shifted identities or rounded CPU displays**.
Each line is `[scan_sequence, original_process_tuple]`; each appeared once within
the inspected first 30 seconds. These are first observed cumulative counters,
not before/after CPU increments or final lifetime totals:

```json
[1,[87417,32239,1791944979,757674,"sleep",1993708,2189458,1245184]]
[1,[87418,31014,1791944979,761201,"sleep",842375,799166,1212416]]
[1,[87419,30489,1791944979,818638,"sleep",2335916,1889791,1212416]]
[2,[87420,32239,1791944979,876681,"sleep",2397958,2107083,1212416]]
[2,[87421,31014,1791944979,878159,"sleep",2255291,2424041,1212416]]
[2,[87422,30489,1791944979,929618,"sleep",3833250,2846875,1212416]]
```

Names and much of RSS repeat; PIDs are near-sequential. Birth microseconds and
fractional CPU values vary. A name dictionary or a larger match window does not
automatically remove those varying integers. They may still have useful structure;
we have not established that they are irreducible noise.

## 8. Exact wire layout: how a reader finds each field

The four-byte labels below are just this experiment's version markers, **not
standard formats**. `PCR1` means the experimental compression-frame wrapper,
not a compressor. `PST1` wraps a storage block; `CSH1` and `PSD1` are its CPU and
metadata sections. The benchmark uses this mask layout and block-major wrapper;
other experimental layouts exist but are not described as if selected here.

`U` and `S` mean the integer encodings from section 4. Literal labels are ASCII
bytes. Counts, lengths and units are actual stored numbers, not explanatory text.

### Frame and block envelopes

After Brotli decompression, read in this order:

```text
"PCR1"
U(number of encoding blocks)
for each block:
    U(block byte length)
    that many bytes, containing:
        "PST1"
        U(header byte length),   header JSON bytes
        U(CPU byte length),      CSH1 bytes
        U(metadata byte length), PSD1 bytes
```

The benchmark knows each compressed frame's boundary because it passes separate
byte strings to the compressor. It does **not** yet define a file container or
seek index for a collection of compressed frames. Do not assume concatenating
Brotli streams supplies that missing archive layer.

The compact block JSON describes `layout="mask"`, `rss_scheme="256k"`,
`rss_unit_bytes=262144`, `cpu_quantum_native_ticks=24000`,
`cpu_timebase_mach=[125,3]`, `timestamp_unit_ns=1`,
`all_observations_kept=true`, and `schema="recording-storage-block-v1"`.
It tells the reader how to interpret integers; it is not the per-process data.
In the 8.5-hour input, CPU occupies 74,074,701 bytes, metadata 65,648,607 bytes and
block headers/framing 227,460 bytes (~0.16%). Their compressed shares are not
additive because joint compression can reuse patterns across sections.

### CPU section, current `changes` layout

```text
"CSH1", layout byte 0
U(quantum), U(clock unit ns), U(timebase numerator), U(timebase denominator)
U(scan-clock entry count), U(identity count), U(total observation count)

shared clock entries, each: U(sequence delta), U(scan-start delta in clock units)

identities sorted by (PID, start seconds, start microseconds), each:
    U(PID), U(start seconds), U(start microseconds), U(observation count)
    U(coverage run count)
    for each run: U(gap from previous run's exclusive end), U(run length)
    U(first CPU quotient)
    U(number of nonzero quotient changes)
    for each change: U(observation-position delta), U(quotient increment)
    U(first native remainder), U(last native remainder)
```

The first clock delta is from zero; subsequent ones are from the previous entry.
The current clock unit is 1 ns. A shared clock entry exists where at least one
process has a reading; metadata still keeps completely empty scans. Code calls
these clock entries `frames`, but they are **scans**, not outer compression frames.

Coverage uses positions in this shared clock, starting at zero. Runs measure gaps
from the previous run's exclusive end, initially zero. CPU change positions instead
index **that identity's observations**, also starting at zero; each change delta is
from the previous change position, initially zero. Keeping these two index spaces
separate is essential when an identity is missing from some scans.

### Sparse metadata section

```text
"PSD1", U(scan count)
for each scan:
    S(sequence delta), S(wall-start delta ns), S(scan-start delta ns)
    U(scan duration ns), U(number of process changes)
    for each change, sorted by slot:
        U(slot - previous_changed_slot - 1), U(change mask)
        mask-selected payload
```

Previous sequence/wall/start values begin at zero for each encoding block.
`previous_changed_slot` begins at -1 for each scan. The mask bits are:

| Name | Value | Payload / action |
| --- | ---: | --- |
| NEW | 1 | New slot: U(PID), U(start seconds), U(start microseconds), U(PPID), length-prefixed UTF-8 name, U(user), U(system), U(RSS). These are baselines, not deltas. |
| MISSING | 2 | No payload; remove from the active observed set. |
| NAME | 4 | Length-prefixed new name, not a string delta. |
| PPID | 8 | S(parent PID change). |
| USER | 16 | S(user change); unused for updates in this split-CPU representation. |
| SYSTEM | 32 | S(system change); unused for updates in this split-CPU representation. |
| RSS | 64 | S(RSS change), in the block header's stored unit. |
| RETURN | 128 | Reactivate a previously absent slot; may accompany other changed fields. |

NEW and MISSING stand alone. Other selected payloads appear in the order
NAME, PPID, USER, SYSTEM, RSS. The initial user/system baselines are both zero
in this metadata section. Slots are allocated on first observation within the
block, not globally, and are not necessarily the CPU section's identity indexes.

### Putting the two sections back together

1. Decompress the outer frame, then split PCR1 and PST1 using their byte lengths.
2. Decode the CPU clock, identities, runs, quotient changes and endpoint corrections.
3. Decode metadata scans, applying slot creation, signed changes, missing and return.
4. Join CPU observations to metadata **by identity and sequence**, not by assuming
   that CPU identity index equals metadata slot or that every process has every scan.
5. Convert CPU ticks using the timebase and RSS integers using the header's unit.
   Keep missing observations missing; the omitted user/system split cannot be rebuilt.

There is no name catalog or seek index hidden in these wrappers. Manifests outside
the payload hold block digests and coverage totals. Readers reject bad lengths,
unknown layouts/masks, impossible counts and malformed/trailing data; CPU decoding
also has explicit expansion limits. These are experimental checks, not a claim
that every metadata-decoding path is production-hardened.

## 9. What is preserved, what is lost, and what could improve?

| Item | Current behavior |
| --- | --- |
| Observed identities and process sets | Preserved; no singleton/churn filter. Missing does not mean exited. |
| Original JSON formatting / process-array order | Not retained; decoding returns canonical identity order, not the original text. |
| Names and observed PPID | Preserved, including changes; PPID is not proof of historical causality. |
| Scan sequence, wall/start/end values | Preserved as observed, not replaced with nominal cadence. |
| CPU user/system split | Deliberately omitted; only total is retained. |
| Total CPU within a block | Interior error <1 ms; each identity's first/last observed native totals exact. |
| RSS | Floored to 256 KiB, with <256 KiB point underestimate; small spikes can disappear. |
| Never-observed processes / CPU after last read | Unavailable from polling; not invented by decoding. |

The outer compressor loses none of the encoded bytes. The representation's
precision tradeoffs happen **before** it. Avoiding duplicate identity/clock
information, predicting exact clock residuals, or encoding baselines differently
could be lossless. Removing endpoint corrections or coarsening observations
would change fidelity and must be measured separately.

Useful next questions are therefore concrete: can one identity table serve both
sections; can counters carry across more than 30 seconds without repeating full
baselines; can native endpoint corrections be stored less redundantly; can clock
prediction expose smaller exact residuals? Huge compression frames alone do not
implement any of these changes. No production format has been selected.

## Current Rust recorder format (concise wire summary)

This section describes the implemented Rust format; the tutorial above stays the
historical prototype reference. These versioned bytes are project formats, not an
external standard.

- Raw reference output is JSONL (optionally zstd-compressed), headed by
  `recording_source: 1` and `cpu_unit: "native_ticks"`. Its `context` declares
  clock/timebase and run metadata; source metadata retains clock origin/acquisition
  details. Rows retain accepted native user and
  system CPU counters separately, RSS, scan bounds and quality: this is the
  lossless reference for those observations.
- A binary archive frame is `HFR1`, a little-endian JSON-header length and frame
  metadata, Brotli-5 bytes, then a SHA-256 digest. Decompression yields `PCR1`,
  a uvarint block count and length-prefixed blocks. `adaptive`, `adaptive-inverse`,
  and `adaptive-log` use PST2 with a JSON header/context, CSH2 CPU data, and PSD1
  metadata; the PST2 profile names the CPU policy. If memory values are present,
  a fourth PMM1 section is added and declared by the header's `memory` object.
  `legacy-1ms` retains PST1/CSH1; `fixed-100us` is a dense PST2/CSH2 control.
- Dense CSH2 begins `CSH2`, version byte `2`, then row/identity/point counts; the
  reader also supports prototype version 1. Each sorted identity track stores its
  identity, observation count and row-index deltas, an exact first total, then
  maximal CPU-quantum runs. A run stores interval count, Q, quantized interior
  offsets from its exact starting anchor, and an exact end delta from that anchor
  (version 1 stored the absolute end total). Dense `adaptive` Q is interval-derived,
  capped at 1 ms in native ticks; Q=1 is exact. The opt-in temporal profiles use
  the same CSH2 v2 tag but a profile-specific body: continuous identity segments,
  selected row-index deltas, exact segment/run anchors and quantum runs. No protocol
  version bump or compatibility framework was introduced.
- PSD1 carries row clocks, process identities/names/PPIDs, sparse presence and
  changes, and RSS in floored 256 KiB units. Optional memory metadata has the shape
  `{"columns":["owned","peak","evicted"],"unit_bytes":262144}` (the columns
  list may be a canonical subset). For each declared column and row, PMM1 uses the
  processes in identity order, writes a uvarint absent count and gap-coded absent
  process indices (first index absolute, then `index - previous_index - 1`), then
  signed varint deltas of present `floor(bytes / unit_bytes)` values from
  that identity's previous present value in the column within the block (or zero).
  `peak` is encoded as a signed `peak_units - owned_units` when owned is declared and
  present at that point; otherwise it is absolute peak units. This preserves even
  a negative excess. Header metadata and PMM1 appear together; if no selected values
  exist, both are omitted and the usual three-section PST2 bytes are retained.
- Raw-source process rows retain the 8-field tuple when all memory values are
  absent. If any is present, the row is an 11-field tuple in the order
  `[pid,ppid,start_sec,start_usec,name,user,system,rss,owned,peak,evicted]`, with
  `null` for absent memory values; these raw values are bytes, without wire flooring.
  Both shapes parse. Decoded binary JSONL exports memory as `owned_bytes`,
  `peak_bytes`, `evicted_bytes` and `memory_unit_bytes` when available. Binary CPU
  is user+system total only. Dense profiles have a checkpoint for every process
  reading; temporal profiles retain metadata/RSS at every source row but may emit
  `"cpu": null` when no CPU checkpoint exists. A checkpoint reports total native
  ticks, `components: null`, a native-tick error bound, and either a null baseline
  interval or an interval with actual start/end scan times, duration, decoded delta
  and native-tick error bound. Omitted CPU is never replaced by zero or
  interpolation. Binary export cannot reconstruct raw user/system components or
  finer source values; block export is not a replacement for the raw reference.

## Current temporal CPU profiles (opt-in)

Only CPU checkpoint retention changes. Source acquisition still observes process
presence, metadata, RSS and timestamps at 10 Hz; raw reference rows retain exact
native user/system counters. The default `adaptive` profile remains dense, and
`legacy-1ms` / `fixed-100us` controls are unchanged.

For each continuous identity segment, the encoder estimates the latest adjacent
raw CPU delta over its actual elapsed scan time, normalized to 100 ms. That estimate
selects Q from the existing power-of-two ladder capped at the native-tick equivalent
of 1 ms; Q=1 is exact. Let `Qbusy` be the ladder quantum at 1 ms of CPU per 100 ms,
`R = max(1, Qbusy / Q)` and `1 <= R <= Qbusy` (the minimum quantum is one tick). Targets
are calculated with integer-time arithmetic:

- `adaptive-inverse`: `T = min(5 s, 100 ms * R)`.
- `adaptive-log`: `T = 100 ms + 4.9 s * log2(R) / log2(Qbusy)`.

The pending deadline only tightens as new raw intervals arrive. If a busier interval
requires a shorter window than an already accumulated prefix, the checkpoint is
placed at the previous raw point; the new interval is not smeared across the quiet
prefix. Lower-rate jitter may still be averaged. There is no all-zero/nonzero or
4x-change guard. Quantization Q is based on the completed window's CPU average
normalized to 100 ms; for a forced sub-100 ms interval, Q is capped by its actual
CPU amount so a positive interval cannot vanish.

Checkpoints use actual observed timestamps, not nominal 100 ms timestamps. A
baseline has `interval: null`; subsequent interval DTOs report actual start/end
scan-start times, elapsed duration, decoded CPU delta and native-tick error bound.
Missing process readings, sequence/acquisition or clock-coverage gaps, and
continuity-unknown quality boundaries start a new exact-baseline segment; no CPU
interval bridges a gap. State/error bounds are block-local (blocks are roughly 30 s).
The binary CSH2 v2 body stores continuous segments and selected row indices/quantum
runs, identified by the PST2 profile; it does not change the CSH2 version tag.

No Strands/frontend consumer is wired yet. A later consumer can use the unchanged
10 Hz metadata/RSS rows plus these optional interval DTOs after the contract settles.

Native records declare the source clock/timebase; legacy inputs without a timebase
require an explicit import argument (for the documented legacy source,
`--timebase 125/3`). The [plan](RECORDING_PLAN.md) tracks scope and boundaries; the
[scorecard](RECORDING_RESULTS.md) separates temporal sanity from full-source dense
adaptive validation and historical controls.

## Historical Python CPU-window design example (not current Rust behavior)

This pre-implementation Python design model is retained as historical research; its
blanket zero/nonzero and >=4x-change guard is **not** used by the current Rust
`adaptive-inverse` or `adaptive-log` profiles.
Research artifacts are private under `.recordings/window-design-example-v2/`:
`model.py`, exact synthetic input, actual Rust baseline, assumptions/summary JSON,
and `window-rules.svg` / `burst-guard.svg`. Comparison charts show only the three
reconstructed outputs. **Exact unquantized 100ms input is exclusively in the separate
`input-truth.svg`**, with matching panels/axes, so black input curves cannot obscure
the colored outputs. This is encoder-input ground truth, not sub-100ms execution
timing. Three chart checks validate input/output separation, the 12 input curves,
and equality with the actual raw input rather than quantized output.
This historical model did not change production source; its charts are SVG only.

Each case is 20 seconds at 10 Hz, with average CPU 0.005%, 0.05%, 0.5% or 5% of one
core. Four patterns have identical totals at each intensity: steady, evenly spaced
30 events/sec, uneven 30 events/sec (100ms-bin event counts `[2,5,1,4,3,2,6,1,4,2]`),
and one burst every 2 seconds. User/system counters split 80/20; their sum drives
this experiment. All models retain exact case totals. The dense baseline reconstruction uses the
pinned Rust binary from `rust-legacy1ms-bulk-20261019T013315Z`; it is not a second
implementation of the temporal profiles described above. The two window alternatives
are historical Python design models.

Window decisions reference the **original 100ms CPU increment**, avoiding feedback
between a growing interval and Q. Let `Qb=2048` native ticks (the Q at nominal 1%
CPU), `R=max(1,Qb/Q)`, minimum tick `Qmin=1`, and `T0=0.1s`. Candidate windows,
rounded up to the 100ms grid:

- Linear in precision gain: `T=min(5s,T0*R)` (inverse in Q, not direct `T∝Q`).
- Log-inverse: `T=T0+(5s-T0)*log2(R)/log2(Qb/Qmin)`.
- A pending deadline may shorten but never extend. Stored-counter Q references
  the completed window's average normalized back to 100ms, not its larger raw
  accumulated amount. Displayed long spans are interval averages, not recovered
  subinterval execution timing. RSS/process observation cadence remains 10 Hz.

| Steady mean | Current spacing | Inverse-Q target | Log-inverse target |
| ---: | ---: | ---: | ---: |
| 0.005% | 0.1s | 5s | 3.7s |
| 0.05% | 0.1s | 1.6s | 1.9s |
| 0.5% | 0.1s | 0.2s | 0.6s |
| 5% | 0.1s | 0.1s | 0.1s |

At steady 0.005%, retained CPU intervals fall from 200 to 4 / 6 over 20 seconds,
while the reconstructed average stays 0.005%. Evenly spaced 30Hz events produce
**identical source counters** to steady work here: 10Hz cannot recover those
individual events. Uneven 30Hz events do produce visible 100ms variability;
coalescing largely removes it even though CPU totals remain exact.

The isolated-burst result is more important. At average 0.005%, each 2s burst
consumes 100us CPU and appears as 0.1% over its source 100ms interval. Window rules
alone reduce peak displayed interval averages to 0.00769% / 0.00667%, nearly hiding
the pulse. Even a target that shortens to 100ms **after** a larger burst arrives
cannot undo the preceding accumulated quiet interval.

An additional illustrative guard retains source endpoints before/after zero/nonzero
edges and >=4x upward changes. Then both historical alternatives preserve the
isolated pulse's 0.1% peak with 31 / 32 intervals instead of 200. This guard does
not preserve all uneven 30Hz variation; it is not a general error-bound contract
and is not in the current Rust implementation. Retained point counts are **not
compressed bytes**; no storage improvement is claimed from this model.
