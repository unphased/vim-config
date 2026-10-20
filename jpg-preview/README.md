# Rust image preview dogfood

Pure-Rust JPEG, PNG, and Sony ARW previews: orientation, SIMD resize, fast PNG
encoding, and direct Kitty graphics transmission. No kitten, Perl, Unicode
placeholders, terminal-response queries, temporary JPEGs, persistent image cache,
or background preloading on lf's image path. The executable keeps its original
`jpg-preview` name for compatibility.

```sh
make -C ~/.vim/jpg-preview
~/.vim/jpg-preview/target/release/jpg-preview photo.ARW 40 20 60 1
```

Arguments are `[--lf-id ID] IMAGE WIDTH HEIGHT X Y`, with dimensions/position in
terminal cells. Standalone output is a Kitty graphics stream on stdout.
`bat-lf-previewer` supplies lf's client ID and selects this binary for JPEG, PNG,
and case-insensitive `.arw` paths. Other image formats report unsupported rather
than implicitly falling back to legacy tools.

Build on each machine running lf (Rust 1.93+). The binary can also be installed
as `jpg-preview` on PATH. Root `make all` builds it; `make test` runs its tests.
With lf installed and the release binary built, run the isolated real-LF PTY
smoke test with `LF_REAL_SMOKE=1 python3 ~/.vim/test-lf-previewer.py`. It checks
PNG transmission above the 64 KiB remote-line threshold, acknowledgement, quit,
and resource cleanup; this fast-sink check does not replace visual Ghostty tests.

- **JPEG:** pure-Rust decoding and EXIF orientation, lossless PNG protocol output.
- **PNG:** pure-Rust decoding; alpha preserved as RGBA with alpha-aware resizing.
  Grayscale and 16-bit input are converted to 8-bit RGB/RGBA inside the PNG.
- **Sony ARW:** seek to classic TIFF IFD0 tags `0x0201`/`0x0202` and read only the
  embedded JPEG. Valid outer TIFF orientation overrides embedded JPEG orientation
  once. Missing/unsupported preview layouts fail explicitly; no full-RAW decode.

Cell pixel dimensions use the controlling tty's `TIOCGWINSZ` values, falling back
to 10×20 pixels when unavailable. `LF_IMAGE_CELL_PIXELS=10x20` overrides this for
repeatable headless benchmarks. Aspect ratio is retained; images are not enlarged.
Decoded images above 64 million pixels and encoded input above 128 MiB are
rejected. The encoded bound applies to the embedded JPEG, not the entire ARW;
large RAW pixel data is neither scanned nor loaded. Reads are bounded before
decoder construction. Image ID remains 424242 so the existing lf cleaner works.

## Live lf timings

Normal lf previews reserve the first preview row for one stdout diagnostic line;
image sizing uses the remaining height and placement starts one row lower. For
example (all stage values are rounded milliseconds):

```text
total=85ms lf-wait=42 compress=11 read=10 decode=10 resize=6 protocol=2 file=1 notify=0 orientation=0 782KiB>4.9MiB 1338x1784
```

- `total`: elapsed Rust invocation time, including acknowledged delivery.
- `file`: private command-file/FIFO setup and writing the prepared stream.
- `notify`: send the small source request and wait for server forwarding.
- `lf-wait`: remaining time until LF executes the image write and acknowledges it;
  includes scheduling, source parsing, tty backpressure, and starting the ack shell.
  LF work can begin during `notify`; this is not an isolated LF CPU measurement.
- `decode`: image decoding, including orientation metadata lookup.
- `read`: file read / ARW JPEG extraction, format detection, decoder construction.
- `orientation`: applying orientation; `resize`: color conversion and resizing.
- `compress`: lossless PNG Fast/Paeth encoding; `protocol`: base64/Kitty assembly.
- `782KiB>4.9MiB`: encoded input bytes → actual Kitty-stream bytes. For ARW,
  input size is the embedded JPEG, not the RAW file.
- Final dimensions: resized image pixels. Stages are sorted by descending cost
  after total, so narrow panes show the largest bottlenecks before clipping.

The row is finalized after lf acknowledges its writes, since delivery cannot be
measured in advance. lf publishes preview stdout after the helper exits; text
therefore appears above, without repainting over the image. `lf-wait` is **not** a
Ghostty display acknowledgement: SSH/terminal buffering and final rendering can
continue afterward. Total excludes the shell's MIME detection/startup and lf's
later stdout publication. Stage sums can differ slightly from total due to
rounding and other overhead. A one-row pane reports insufficient image space.
Standalone and `lf -single` keep their previous raw-output behavior.

Photo JPEGs can still expand when converted to lossless PNG and base64;
flat-color screenshots compress much better. The wire byte count helps
distinguish this cost from decoding rather than inferring from file size.

## PNG versus raw RGB: measured optimization

At identical pixels, PNG row prediction substantially beats the previous raw
RGB + fast zlib transport. We use PNG Fast/Paeth (`f=100`), with no extra `o=z`
compression. This does not change the resized pixels or add temporary PNG files.

```text
JPEG/PNG/ARW → decode/orient → resize → PNG Fast/Paeth → base64 → LF → terminal
```

NAS, release build, five-run codec medians; source `IMG_1795.jpg`, resized to
1338×1784 (2379×1784 bounds), same Cargo.lock as production:

| Encoding | Encode time | Payload bytes | Base64 bytes (before framing) |
|---|---:|---:|---:|
| Raw RGB + fast zlib (old) | 36.2 ms | 5,373,789 | 7,165,052 |
| PNG Fast/Paeth | 9.7 ms | 3,807,354 | 5,076,472 |
| PNG balanced/adaptive | 377.8 ms | 3,246,976 | 4,329,304 |

The fast PNG wins CPU time and traffic (29% fewer bytes). Stronger PNG
compression saves more bytes but is counterproductive for latency. Separate
local ARW-embedded-JPEG and synthetic alpha-screen tests also favored Fast/Paeth;
outputs were decoded and checked pixel-for-pixel, including alpha.

A real NAS LF client benchmark continuously drained a PTY to a fast sink, so it
measures the LF/helper path **without SSH/Ghostty rendering**. Eight warm image
switches after one warmup, identical 1338×1784 pixels, CPU profiling enabled:

| Pipeline | Median Rust total | Protocol assembly | LF client CPU samples over 9 previews |
|---|---:|---:|---:|
| Old raw RGB + escaped batches | 152 ms | 32–33 ms | 540 ms |
| PNG + escaped batches | 102.5 ms | 22–24 ms | 420 ms |
| PNG + one literal source command | 83.5 ms | 2–3 ms | 270 ms |

LF parsing is a real cost, not the whole delivery bucket: sampled parser CPU
fell from 150 ms to 70 ms across the nine previews. These profiles also include
startup, UI redraw, GC, and tty syscalls; do not treat CPU samples as wall times
or infer the original 252 ms delivery was all LF. File setup was 1–2 ms and
notification rounded to 0 ms. A real terminal/SSH path can add backpressure and
rendering time. Your own larger photo is not this benchmark sample.

For an actual display-path LF CPU profile, quit normally to finalize the file:

```sh
lf -cpuprofile /tmp/lf.cpu /path/to/photo.jpg
go tool pprof -top -cum /tmp/lf.cpu
```

## Direct JPEG probe in Ghostty

On installed Ghostty `1.3.0-main+685daee01`, a separate raw-TTY probe (no LF,
SSH, or multiplexer) displayed a 152,985-byte PNG through `f=100` and returned
`OK`. The corresponding 35,217-byte JPEG did not display. A valid 1,173-byte
JPEG fitting in one Kitty packet explicitly returned `EINVAL: invalid data`
under `f=100`; its dimensions were independently decoded successfully by macOS.
Both single- and multi-packet PNG controls worked. JPEG under speculative
`f=200` also did not display (no reply). These are installed-build results, not
a claim about every possible future extension: this build does not accept JPEG
transparently in its PNG slot, so changing JPEG quality alone cannot enable
JPEG passthrough on the current path.

## Historical raw-RGB JPEG measurements

NAS `/six_fourteen/SCREENCAPS/IMG_1795.jpg`: 800,048 bytes, 1512×2016.
Release build, warm files, stdout redirected to a temporary file:

| Target bound | Rust | kitten builtin | Rust protocol bytes |
|---|---:|---:|---:|
| 400×300 | 22–23 ms | 407–426 ms | 231,049 |
| 1280×1500 | 55–57 ms | 467–485 ms | 5,169,266 |

The first Rust small-preview run was 77 ms. These numbers **exclude** SSH
transport and terminal rendering. Large raw-RGB protocol payloads still matter;
measure before claiming equivalent end-to-end speedups.

## lf redraw synchronization

Direct `/dev/tty` writes race lf's UI drawing: the previewer runs on a separate
thread. This reproduced as a blank JPEG locally in plain Ghostty, without SSH or
Herdr. In normal lf mode, transmission and cleanup now use native `tty-write` on
lf's UI thread. The local opening/selection/full-redraw reproducer passes.

```text
Rust → private command file → one small lf source request → UI-thread tty-write
                              ← consumption acknowledgement ← shell builtin
```

The helper waits for acknowledgement through a private FIFO, then removes the
command file, FIFO, and private directory. Rejection and a five-second timeout
also clean up. Only a short notification crosses lf's server socket; bulk image
commands there can deadlock quitting under backpressure. The source file uses
one literal, single-quoted `tty-write` command, avoiding bulk escaping/copying.
Generated Kitty/base64 streams contain no apostrophes (checked before writing).
Source files do not have the remote socket scanner's 64 KiB line limit. Kitty
packets remain at most 4096 base64 bytes, with cursor save/restore around the
whole stream. Only the short source pathname needs double-quote escaping.
No placeholders, display delays, or persistent protocol cache are involved.

Socket discovery matches lf r42: `$XDG_RUNTIME_DIR/lf.sock`, otherwise
`${TMPDIR:-/tmp}/lf-UID/lf.sock`. `lf -single` has no server and retains raw tty
output (and therefore does not get the synchronization guarantee). Standalone
CLI rendering is unchanged apart from its PNG wire encoding. Abrupt termination
(e.g. SIGKILL/SIGHUP) can leave temporary files, as with other process-owned
temporary resources.
