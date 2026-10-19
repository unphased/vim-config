# Memory metrics: what the recorder should sample

**Status: accepted 2026-10-19 (all four columns); implementation plan below.** Today the recorder stores
one memory value, RSS (`pti_resident_size`, floored to 256 KiB). Measurements below
come from an M1 Max (macOS 15.7.4, 64 GB, ~1170 pids, ~940 readable unprivileged)
and the NAS (Linux 6.18 x86_64, ~1170 pids). Probe sources: [`probes/memory/`](probes/memory/).

## Problem

RSS answers "what is in RAM right now", not "what does this process use":

- **It drops when pages are evicted.** On macOS a process can have far more in the
  compressor than in RAM (one VM process here: 456 MB resident, 9.9 GB compressed).
- **It counts shared and clean file pages** (libraries, mmapped files) that the OS can
  drop and re-read at any time.
- **A point sample misses spikes** between samples, and that gets worse when the
  interval goes from 100 ms to 500 ms.

VSZ is worse still. It counts address space that was reserved but never touched.

```mermaid
flowchart TD
  VSZ["Virtual size: all reserved address space"] --> UNT["Never touched: no RAM, no swap. Ignore."]
  VSZ --> TCH[Touched pages]
  TCH --> RES["Resident (RSS): in RAM now"]
  TCH --> OUT["Evicted but still owed: swap / compressor"]
  RES --> PRIV["Private dirty: the process made it"]
  RES --> CLEAN["Clean file-backed / shared: OS can re-read"]
  PRIV --> OWN(("Owned"))
  OUT --> OWN
```

What we want is **owned** memory: private dirty pages plus evicted pages. The diagram
shows why that is neither RSS nor VSZ.

## Recommendation: four columns

| Column | Meaning | macOS source | Linux source (`/proc/pid/status`) |
|---|---|---|---|
| **owned** | private memory, including evicted | `ri_phys_footprint` | `RssAnon` + `VmSwap` |
| **resident** | in RAM now (today's RSS) | `ri_resident_size` | `VmRSS` |
| **peak** | highest value since the previous sample | `ri_interval_max_phys_footprint`, then reset | `VmHWM`, then `clear_refs` reset |
| **evicted** | owned pages not in RAM, pre-compression bytes | `TASK_VM_INFO.compressed` | `VmSwap` |

Why each column earns its place:

- **owned** is the primary metric, and the one that answers the original finding.
- **resident** keeps continuity with existing recordings. The gap between owned and
  resident is the paging signal.
- **peak** makes 500 ms sampling safe. Probe: a child that touched 300 MB and unmapped
  it between samples read footprint 0.8 MB but interval max 301 MB on macOS, and
  RSS 0 MB but VmHWM 300 MB on Linux. Both resets then worked.
- **evicted** explains *why* resident dropped. It costs nothing on Linux and is the
  only optional extra call on macOS (see cost).

## Acquisition and cost

```mermaid
flowchart LR
  subgraph macOS["macOS, per pid"]
    B[PROC_PIDTBSDINFO identity] --> R["proc_pid_rusage V6: CPU ticks, resident, footprint, peak"]
    R --> X[proc_reset_footprint_interval]
    R -. optional .-> V["task_name_for_pid + TASK_VM_INFO: compressed"]
  end
  subgraph Linux["Linux, per pid"]
    S["read status: VmRSS, RssAnon, VmSwap, VmHWM, PPid"] --> C["write 5 to clear_refs"]
  end
```

On macOS, `proc_pid_rusage(RUSAGE_INFO_V6)` **replaces** `PROC_PIDTASKINFO` rather than
adding a call. It returns the same CPU counters in the same native ticks
(`ri_user_time` = `pti_total_user`, timebase 125/3) and an identical resident size.
On Linux, every column comes from the `status` read the sampler needs anyway.

Measured full-system sweep cost (medians of repeated sweeps):

| Step | macOS (~1170 pids) | Linux NAS (1170 pids) |
|---|---|---|
| Base read | `PROC_PIDTASKINFO` 1.85 ms, `proc_pid_rusage` 1.84 ms | `status` 9.6 ms |
| Peak reset | 0.38 ms (~0.4 µs/pid) | ~3–4 µs/pid (own pids only unprivileged) |
| Compressed | +2.35 ms (`TASK_VM_INFO`) | free (`VmSwap`) |

At 500 ms this is about 1% of a core on macOS (~4.6 ms of memory calls, all
options on) and under 3% on Linux (≤14 ms when root resets every pid).

## Caveats

1. **The macOS peak reset is a private API.** `proc_reset_footprint_interval` is
   exported from libSystem but absent from SDK headers. If it disappears,
   `ri_lifetime_max_phys_footprint` (public) still catches new all-time peaks.
2. **Resets are shared per-process state.** Only one sampler may reset. If the UI
   sampler and the recorder both reset, each steals the other's peaks.
3. **Linux "peak" is peak RSS, not peak owned.** `VmHWM` includes file pages, so the
   macOS and Linux peak columns are not identical. Interpret them per OS.
4. **Compressed is not nested inside footprint.** 39 of 933 readable macOS processes
   report compressed > footprint (mostly by a few MB; the VM process 9.9 GB vs
   6.0 GB). Store columns independently and never derive one from the other.
5. **Coverage matches today's.** macOS unprivileged reads cover own-user pids
   (~940 of ~1170), the same set `PROC_PIDTASKINFO` covers now. Linux `status` covers
   all pids, but `clear_refs` resets only own pids unless root.
6. **Linux `RssShmem` is left out of owned.** Shared-memory buffers (browsers, GPU
   clients) are real but ambiguous to attribute. Revisit if they matter.
7. **Sums are not a RAM total.** macOS footprint summed to ~80 GB on a 64 GB machine,
   largely because compressed memory counts at its uncompressed size
   (`vm_stat`: ~74 GB stored in a ~25 GB compressor).

## Encoding notes

- Floor all four columns to the existing 256 KiB unit.
- Store **peak as excess over owned** (`peak − owned ≥ 0`). It is zero whenever
  memory did not spike or fall, so it compresses to almost nothing.
- **evicted** is zero for most Linux processes and for idle macOS ones.
- Each new column needs its own change-mask bit next to the current `RSS` bit, which
  means a wire version bump. Add all of them in one bump.

## Open decisions

- Include **evicted** on macOS (one extra call per pid)? Recommended: yes.
- Accept the private reset API, or use lifetime max only?
- Accept the macOS/Linux semantic mismatch in **peak**?

## Implementation plan

Decisions: keep all four columns. **resident** stays the existing PSD1 `rss`
unchanged. **owned**, **peak**, **evicted** are new, macOS acquisition only (Linux
acquisition does not exist yet), each switchable for compression experiments.

```mermaid
flowchart LR
  A["sample_scan (inside BSD/task/BSD bracket)"] --> P["Process {.., rss, owned?, peak?, evicted?}"]
  P --> RAW["raw JSONL source: 11-field process row when any memory value is set"]
  P --> ENC["encode_block(.., MemoryEncoding)"]
  ENC --> S3["PST2: header + CSH2 + PSD1 (unchanged)"]
  ENC --> S4["+ optional 4th section PMM1, declared by header.memory"]
```

**Invariant: with no memory selected, or no memory values in a block, every byte
written is identical to today** (PST1, PST2 and raw JSONL). Existing tests and
Python parity must pass unmodified.

1. **Model** (`model.rs`). `Process` and `DecodedProcess` gain `owned`, `peak`,
   `evicted: Option<u64>` in bytes (`serde(default, skip_serializing_if = "Option::is_none")`).
   `peak` keeps its raw meaning (bytes); "excess over owned" is only a wire encoding.
2. **Selection.** `MemoryEncoding { columns: {owned, peak, evicted} subset, unit_bytes }`,
   `MemoryEncoding::NONE` = current behavior. CLI on `record`, `transform`, `bench`:
   `--memory-columns owned,peak,evicted|none` (default: all three) and
   `--memory-unit-bytes N` (default 262144, must be ≥1). `record` only performs the
   acquisition calls for selected columns.
3. **Wire** (`wire.rs`, PST2 only; PST1/`legacy-1ms` ignores memory and stays
   byte-identical). A column is written iff selected **and** at least one process
   in the block has a value. If none qualify: no header field, 3 sections, today's
   bytes. Otherwise header gains
   `memory: {"columns": [...in order owned, peak, evicted], "unit_bytes": N}` and a 4th
   section `PMM1`:
   - For each declared column, for each row, with the row's processes in identity
     order (same order PSD1 encodes them): `uvarint absent_count`, then the absent
     process indices as gap-coded uvarints, then for each present process
     `svarint(units − previous_units)`. `units = floor(bytes / unit_bytes)`;
     `previous_units` is that identity's last present value in this column within the
     block, else 0. Blocks stay independent.
   - **peak** encodes `peak_units − owned_units` when owned is declared and present
     for that point, else `peak_units`; signed, so `peak < owned` is lossless.
   - Decoder: header `memory` ⇔ 4th section; reject unknown/duplicate/out-of-order
     columns, `unit_bytes == 0`, bad absent indices, count mismatches, trailing bytes,
     overflow. Decoded values are `units × unit_bytes` (floored).
4. **Raw source** (`source.rs`). Process rows stay the 8-tuple when all three are
   `None`; otherwise an 11-tuple with `null` for absent. Both parse.
   `recording_source: 1` stays; no-memory sources are byte-identical.
5. **Acquisition** (`recording_native.rs::sample_scan`, macOS), between the task read
   and the second BSD read so the identity bracket covers it:
   - owned or peak: `proc_pid_rusage(pid, RUSAGE_INFO_V6)` → `ri_phys_footprint`,
     `ri_interval_max_phys_footprint`.
   - peak: then `proc_reset_footprint_interval(pid)` (private libproc export;
     declare `extern "C"`). The first sample of an identity is a peak since process
     start or the last external reset; document, do not special-case.
   - evicted: `task_name_for_pid` + `task_info(TASK_VM_INFO).compressed`; always
     deallocate the port.
   - A failed memory read sets that column `None` for that process; never drops the
     process. Count failures in row quality like `task-read-failures`
     (`memory-read-failures`, `peak-reset-failures`, `evicted-read-failures`).
   - Source header `acquisition` gains a `memory` object naming each selected
     column's source call, the reset, and that the reset is a private API. Omitted
     when no columns are selected.
6. **Inspect/export**: decoded JSONL includes `owned/peak/evicted` bytes plus
   `memory_unit_bytes` when present.
7. **sudo ownership** (separate commit): when `geteuid() == 0` and `SUDO_UID`/`SUDO_GID`
   parse, `chown` every directory/file the recorder creates under `--output` to that
   user, right after creation. No flag. Unit-test the env decision; e2e is manual.

Tests first (commit red, then green), at minimum:

- **byte invariance**: `MemoryEncoding::NONE` vs. all columns selected with no
  values: identical PST2 bytes; PST1 identical even when rows carry memory.
- **round trip**: new, missing, returning, renamed processes; absent values;
  unit flooring; `peak < owned`; peak without owned; each column subset.
- **decoder rejection** for every case in step 3.
- **raw source** round trip with and without memory; legacy 8-tuple files unchanged.
- **CLI**: `--memory-columns none` produces no `memory` header; default `record`
  on macOS yields `owned > 0` for the recorder's own pid.
- **tracer bullet** (macOS): two scans with the sampler; between them, mmap, touch
  and munmap 64 MiB in the test process. The second scan's own-pid `peak − owned`
  is ≥ 64 MiB and `owned` is not.

Deferred: replacing `PROC_PIDTASKINFO` with `proc_pid_rusage` (same ticks, one fewer
call); Linux acquisition; system-wide pressure series.

## Reproduce

```sh
cd probes/memory
cc -O2 -o /tmp/sweep sweep_cost.c && /tmp/sweep    # both OSes: sweep cost
cc -O2 -o /tmp/api macos_api_probe.c && /tmp/api   # units parity, call costs
cc -O2 -o /tmp/spk macos_spike.c && /tmp/spk       # interval max catches spike
cc -O2 -o /tmp/cmp macos_compressed.c && /tmp/cmp  # compressed vs footprint
cc -O2 -o /tmp/rst macos_reset_cost.c && /tmp/rst  # reset sweep cost
cc -O2 -o /tmp/lsp linux_spike.c && /tmp/lsp       # Linux: VmHWM + clear_refs
```
