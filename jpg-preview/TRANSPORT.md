# Bulk terminal transport investigation

Production remains **resize → fast PNG → synchronized LF delivery**. No production
renderer or persistent SSH/Ghostty/capture settings were changed.

**Follow-up correction:** [the flicker investigation](FLICKER.md) found that our
FIFO-acknowledgement shell can trigger a second renderer invocation per selection.
The LF rows below describe individual replay completions, not verified per-switch
latency or exactly one transmission per selected file. There is therefore
application-owned duplicate work to address before treating this path as optimized.

## What was measured

```text
pre-encoded PNG ──┬─ PTY → fast drain
                 ├─ Ghostty: discard APC / load PNG / display PNG
                 ├─ SSH → fast drain / Ghostty
                 └─ LF source + tty-write → fast drain / Ghostty, local and SSH
```

The fixed image was synthetic RGB noise (Python `Random(405)`), 2400×2200
(5.28 MP), encoded by the
production PNG Fast/Paeth path **before** timing: PNG 15,843,473 bytes; Kitty
stream 21,171,111 bytes (~20.19 MiB), 5,158 base64 chunks of at most 4096 bytes.
The discarded-APC control changes the APC command identifier, not the byte count.
Display placement was constrained to 40 columns; full pixels still crossed the
terminal connection. This is a large-transfer stress test, not the user's exact
photo or the normal resized preview.

Installed Ghostty: `1.3.0-main+685daee01`, macOS 15.7.4 arm64. LF was the installed
binary on each host. Main terminal tests used a dedicated `--command='/bin/zsh -f'`
window, bypassing automatic shell/capture startup. The NAS SSH tests used the
currently reachable `nas-eth` endpoint while retaining `HostKeyAlias=nas` and
normal host-key validation. No security settings were weakened.

Direct PTY/terminal conditions used one warmup followed by three measured
repetitions. LF controllers selected four replay completions and omitted the first,
but did not distinguish an acknowledgement-triggered duplicate from the next
requested selection. Their medians remain historical per-invocation observations,
not a validated warmup plus three distinct user switches. No competing bulk benchmark was intentionally run
during the final corrected comparisons. Window visibility/App Nap and other
desktop activity were not rigorously controlled. These are exploratory timings,
not a quiet-machine or foreground-rendering throughput ceiling.

## Results

| Path / completion point | Median |
|---|---:|
| macOS raw PTY → fast drain, producer write | 0.136 s |
| macOS output-processed PTY → fast drain, producer write | 0.134 s |
| Direct Ghostty, ignored APC, parser fence | 0.523 s |
| Direct Ghostty, PNG upload without placement, parser fence | 0.638 s |
| Direct Ghostty, PNG display, parser fence | 0.649 s |
| SSH → Ghostty, PNG display, parser fence | 0.697 s |
| Local LF → fast-draining PTY, LF wait | 0.202 s |
| NAS LF → fast-draining PTY, LF wait | 0.086 s |
| Local LF → Ghostty, LF wait | 0.529 s |
| NAS LF → SSH → Ghostty, LF wait | 0.632 s |

**These rows are not additive and their clocks differ.** Direct terminal timing
runs from writing the fixed stream through a cursor-report parser fence and,
for valid PNG, an image `OK` reply. This proves parsing/acceptance, not completion
of GPU rendering or scanout. Queries were used only in the standalone probe,
**never while LF owned terminal input**.

LF wait starts after the tiny source notification is forwarded and ends at the
private FIFO acknowledgement after LF's tty write. It excludes replay-file load
and setup and may finish before the terminal consumes/decodes the buffered tail.
The replay uses Python to prepare the same native `source` / literal `tty-write`
command as production, not the Rust codec pipeline. The senders also use different
I/O implementations. Do not interpret LF's lower figure as negative LF overhead.
LF's observed tty output processing was disabled on both hosts.

### SSH / crypto control

A separate fast-pipe receiver measured exactly 20 MiB of base64-encoded random
bytes, excluding generation and SSH startup:

| Mode | Compression | Cipher | Receive median |
|---|---|---|---:|
| No remote PTY | off | chacha20-poly1305 | 0.381 s (52.5 MiB/s) |
| Raw remote PTY | off | chacha20-poly1305 | 0.435 s (46.0 MiB/s) |
| No remote PTY | on | chacha20-poly1305 | 0.598 s |
| Raw remote PTY | on | chacha20-poly1305 | 0.694 s |
| No remote PTY | off | aes128-gcm | 0.421 s |
| Raw remote PTY | off | aes128-gcm | 0.446 s |

SSH compression increased receive time on this route. Extra CPU work is a
possible cause, but CPU consumption was not isolated by that probe. AES did not
provide a useful win in these small samples. Neither was
enabled. Startup to readiness was ~0.23–0.27 s on the direct connection. Normal
proxy fallback first tried two unavailable endpoints (~6.4 s startup in one
trial); that is separate from transfer time in an already-established SSH session.
These are SSH+reader measurements, not a raw-NIC benchmark or every NAS route.

## Profiles and interpretation

A short macOS `sample` during discarded APC input identified Ghostty's
`terminal.stream.Stream(...).nextNonUtf8` as the main active I/O-reader stack
(313 of 712 samples on that thread), alongside reads/polls, renderer-lock waits,
and notifications. This is a concrete lead in **bulk terminal ingestion/parsing
and coordination**, before PNG decoding. It does not prove one function accounts
for all wall time, nor is a discarded APC identical to valid Kitty handling.
A second sample during valid PNG display corroborated the lead: 618 direct plus
87 delegated samples under `nextNonUtf8` out of 1,523 reader-thread samples,
alongside buffer growth/copying and lock/wake calls. Explicit PNG/base64 decoder
stacks appeared much less often. These are short, per-thread stack samples,
not whole-process CPU percentages or a precise cost decomposition.

The NAS LF CPU profile during the SSH/display controller run sampled 480 ms of
client CPU over ~4.98 s, with 220 ms cumulative in parsing. The controller retained
four completions; the actual invocation count was not independently verified. That includes startup, redraw,
allocation and syscalls. Parsing is real work, but it does not explain all of the
~0.63 s per-preview LF wait; downstream backpressure can occupy that same bucket.

In a direct-terminal trial, synchronized-output wrapping (`CSI ?2026h/l`) changed
PNG parser-fence time from 0.659 s to 0.527 s (~20% less). **That did not translate
into a demonstrated LF improvement**: a fresh-namespace LF replay measured
0.549 s wait versus 0.529 s without the added wrapper. It was not deployed.

### Capture and harness caveats

An automatically captured normal login-shell session initially took 3–4 s.
Controlled manual capture in the bare-shell window instead measured ~0.54 s for
discarded APC with a private output directory and ~0.77 s using the default
capture directory. Thus the initial slowdown is **not proof that capture alone
always causes it**. Shell/startup, visibility/scheduling and capture configuration
need a separate controlled investigation; capture was not disabled globally.

An early fast-drain controller checked a log file after every small PTY read,
which throttled the reader and inflated LF waits. Those numbers are excluded
above; final controls continuously drain data and rate-limit metadata polling.
An initial overlapping PTY trial also gave a much slower output-processed result;
it did not reproduce in the final serialized run, so no OPOST tuning is proposed.
One repeated-run LF test hit an unconnected-client error; it was excluded and
rerun in a fresh private server namespace, not treated as a sync-mode result.

## Bottom line

- Keeping fit-sized PNG payloads is justified: bytes alone have a substantial
  cost even without LF, SSH, or image decoding.
- LF is not established as the sole or dominant cause. Ghostty's bulk APC/input
  path and read/render coordination are the strongest new profiling lead.
- SSH compression, cipher changes, and extra sync wrapping are not supported
  production fixes from these measurements.
- Bulk Ghostty ingestion remains a profiling lead, but the subsequent verified
  acknowledgement-induced duplicate render is an application integration issue
  worth addressing first. No Ghostty patch was made here.

JSON samples, bounded SSH logs, scripts and process samples were retained under
`/tmp/lf-bulk-evidence/`; large generated PNG/stream files, private capture fixtures,
and disposable terminal sessions were removed. Normal automatic capture history
was left to the user's existing retention policy. Reproduction requires the same terminal version,
payload size, capture/shell setup and acknowledgement endpoints—not merely `cat`
of arbitrary printable text into a terminal.
