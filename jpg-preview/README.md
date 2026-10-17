# JPEG preview dogfood

Pure-Rust JPEG decode, EXIF orientation, SIMD resize, fast zlib compression,
and direct Kitty graphics transmission. No kitten, Perl, Unicode placeholders,
terminal-response queries, persistent cache, or background preloading on this path.

```sh
make -C ~/.vim/jpg-preview
~/.vim/jpg-preview/target/release/jpg-preview photo.jpg 40 20 60 1
```

Arguments are `IMAGE WIDTH HEIGHT X Y`, with dimensions/position in terminal
cells. Output is a Kitty graphics stream on stdout. `bat-lf-previewer` selects
this binary for `image/jpeg`; PNG and ARW retain their existing implementation.
The binary must be built on each machine running lf (Rust 1.93+). It can also
be installed as `jpg-preview` on PATH. Root `make all` builds it, and `make test`
runs its tests.

Cell pixel dimensions use the controlling tty's `TIOCGWINSZ` values, falling back
to 10×20 pixels when unavailable. `LF_IMAGE_CELL_PIXELS=10x20` overrides this for
repeatable headless benchmarks. Aspect ratio is retained; images are not enlarged.
JPEGs above 64 million pixels or 128 MiB encoded input are rejected. Encoded
reads are bounded before decoder construction. The image ID remains 424242 so the
existing lf cleaner works.

## Initial measurements

NAS `/six_fourteen/SCREENCAPS/IMG_1795.jpg`: 800,048 bytes, 1512×2016.
Release build, warm files, stdout redirected to a temporary file:

| Target bound | Rust | kitten builtin | Rust protocol bytes |
|---|---:|---:|---:|
| 400×300 | 22–23 ms | 407–426 ms | 231,049 |
| 1280×1500 | 55–57 ms | 467–485 ms | 5,169,266 |

The first Rust small-preview run was 77 ms. These numbers **exclude** SSH
transport and terminal rendering. Large raw-RGB protocol payloads still matter;
measure before claiming equivalent end-to-end speedups. A real NAS JPEG was
visually checked in Ghostty → Herdr → SSH → lf.

This is a JPEG-first dogfood implementation, not a general image framework.
Direct tty placements still share ordering with lf's UI clears; the rewrite does
not claim to solve every initial-open/redraw race. Future work can address native
lf presentation ordering and benchmark PNG payloads, PNG input, and direct ARW
embedded-JPEG extraction. Do not reintroduce Unicode placeholder cells as a
workaround.
