# Rust image preview dogfood

Pure-Rust JPEG, PNG, and Sony ARW previews: orientation, SIMD resize, fast zlib
compression, and direct Kitty graphics transmission. No kitten, Perl, Unicode
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

- **JPEG:** pure-Rust decoding and EXIF orientation, RGB protocol output.
- **PNG:** pure-Rust decoding; alpha preserved as RGBA with alpha-aware resizing.
  Grayscale and 16-bit input are converted to terminal RGB/RGBA.
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

## Initial JPEG measurements

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
commands there can deadlock quitting under backpressure. Packet boundaries and
cursor save/restore are preserved; lf's greedy octal-escape parsing is accounted
for. No placeholders, display delays, or persistent protocol cache are involved.

Socket discovery matches lf r42: `$XDG_RUNTIME_DIR/lf.sock`, otherwise
`${TMPDIR:-/tmp}/lf-UID/lf.sock`. `lf -single` has no server and retains raw tty
output (and therefore does not get the synchronization guarantee). Standalone
CLI rendering is unchanged. SIGKILL can leave temporary files, as with other
process-owned temporary resources.
