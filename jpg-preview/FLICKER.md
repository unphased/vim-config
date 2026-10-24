# Herdr / SSH preview flicker investigation

## Result

The controlled reproduction exposed **two interacting behaviors**, not a JPEG
conversion problem:

```text
selection → preview → LF tty-write → FIFO acknowledgement
                                    └─ LF &shell exit → load → preview again

Herdr presentation: first image → same-ID replacement starts → empty scene → image
Direct Ghostty:     the intervening blank was not visible in this control
```

Our acknowledgement command is `&printf x > <private FIFO>`. LF automatically
runs `load` when an asynchronous shell command exits. That can happen while the
original preview is still marked loading. LF then launches the previewer again
for the **same file and geometry**. The original helper finishes and publishes
its stdout independently of that reload.

Both renders transmit `a=T` with image ID `424242`. There is **no explicit
per-render delete in Rust**. However, Herdr's vendored Ghostty core removes an
existing image and its placements when the **first replacement chunk** arrives,
before the replacement's last chunk. Herdr can publish that temporary empty scene
as a real deletion to the outer terminal, after the first image has appeared.

## Evidence

Tested 2026-10-24 with installed Herdr **0.9.3**, LF **r42** on macOS/NAS, and
Ghostty **1.3.0-main+685daee01**. A dedicated Ghostty instance attached to a
throwaway named local Herdr session; no user's pane or server was altered.
Remote topology was **local Herdr pane → SSH → NAS LF**, not `herdr --remote`.

Two synthetic 1400×1200 PNGs (red/green noisy pixels, about 4.3 MiB encoded each)
made transitions identifiable without using personal photos. Six alternating
selections were observed per condition. Window-scoped ScreenCaptureKit sampling
requested 60 Hz and classified a small region inside the image; `macwin shot`
verified actual rendered image content and geometry.

A flicker here means **new image visible → blank → same new image visible**.
The ordinary clearing of the previous selection before the new image first
appears is not counted.

| Condition | Selections with post-appearance blink | Median observed blank interval |
|---|---:|---:|
| Local LF inside Herdr, production renderer | 6/6 | 72 ms |
| NAS LF over SSH inside Herdr, production renderer | 6/6 | 114 ms |
| NAS LF over SSH in direct Ghostty, production renderer | 0/6 | — |
| Herdr + SSH, fixed pre-encoded replay, ordinary stream | 5/6 | 97 ms |
| Same replay, synchronized-output wrapping | 0/6 | — |

Thus SSH is **not strictly required**: a sufficiently large local fixture also
exposes the problem. This does not contradict smaller/local photos looking
stable. Size, arrival timing, and presentation scheduling matter. These small
samples are not a universal Ghostty/Herdr guarantee. Sparse/dropped capture frames
can miss a shorter blink. The direct case had a wider LF pane and slightly larger
payload; this is a visibility comparison, not a matched latency benchmark.

Separate local tracing confirmed duplicate invocations across two settled
selection changes. NAS tracing recorded **12 helper invocations for six switches**
in both Herdr and direct Ghostty, excluding startup. Replay tracing likewise
recorded duplicate calls with and without sync wrapping. Startup geometry changes
can legitimately add previews and are not attributed to the acknowledgement.

The owned outer terminal's capture also records Herdr's host commands. For one
native SSH selection, relative to the input action:

```text
 35 ms   delete previous host image
212 ms   upload first new host image, using local RGBA file transport
214 ms   place it
232 ms   delete that host image again
344 ms   upload the same selected image again
345 ms   place it again
```

The host upload IDs differ from LF's pane-local ID because Herdr remaps them.
Capture timestamps indicate output arrival, not GPU completion; the independent
window samples establish the visible blink. The detailed division between SSH
chunking, Herdr scheduling, and asset delivery was not separately isolated.

## Source corroboration

- [LF r42 `runShell`](https://github.com/gokcehan/lf/blob/r42/app.go#L675-L681)
  queues `load` after an `&` command completes.
- [LF `load`](https://github.com/gokcehan/lf/blob/r42/eval.go#L1288-L1290)
  calls `ui.loadFile(app, false)`;
  [loading cache entries](https://github.com/gokcehan/lf/blob/r42/nav.go#L963-L979)
  can start another preview even on that non-volatile load.
- Herdr v0.9.3's vendored test
  [`kittygfx retransmit same id removes image on first chunk`](https://github.com/herdrdev/herdr/blob/v0.9.3/vendor/libghostty-vt/src/terminal/kitty/graphics_exec.zig#L1747-L1790)
  explicitly checks the old placements disappear before final upload completion.
- Herdr's [per-read graphics settling](https://github.com/herdrdev/herdr/blob/v0.9.3/src/pane/terminal.rs#L2537-L2551)
  is a 20 ms backstop, not an atomic-upload guarantee. Its
  [surface renderer defers synchronized output](https://github.com/herdrdev/herdr/blob/v0.9.3/src/server/client_shell.rs#L300-L330).

## Confirmed mitigation, not deployed

The replay control kept identical pre-encoded pixels, Kitty chunks, native LF
source delivery and FIFO acknowledgement, adding only `CSI ?2026h` / `CSI ?2026l`
around each complete graphics stream. It eliminated the observed post-appearance
blink without placeholders, terminal queries, or a rendering delay. **It did not
eliminate duplicate preview calls.**

This is a candidate for production atomicity, not a completed fix: native-renderer
regressions, interruption/quit, truncated streams and SSH-disconnect recovery need
validation first. Do not assume Herdr's headless terminal has Ghostty-the-app's
synchronized-output timeout behavior. No installed renderer, LF binary, persistent
config, or update channel was changed.

The separate acknowledgement-induced reload deserves attention before declaring
the application path optimized. It repeats decoding, resizing, PNG encoding and
transmission in the native control. That is avoidable work, **not a measured
promise of a 2× end-to-end improvement**. Any replacement acknowledgement must
retain bounded resource cleanup and safe quitting; dropping the fence or adding
a server-global blocking query is not an established safe fix.

Scripts, frame samples, invocation logs, graphics-event trace and screenshots
are retained under `/var/tmp/lf-herdr-flicker.06UZIQ/`. Generated bulk fixtures,
source clones, disposable sessions and remote test files were cleaned up; normal
automatic capture history follows the user's existing retention policy.
