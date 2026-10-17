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

Arguments are `IMAGE WIDTH HEIGHT X Y`, with dimensions/position in terminal
cells. Output is a Kitty graphics stream on stdout. `bat-lf-previewer` selects
this binary for JPEG, PNG, and case-insensitive `.arw` paths. Other image formats
report unsupported rather than implicitly falling back to legacy tools.

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

Direct tty placements still share ordering with lf's UI clears. Initial-open
blanking was reproduced and remains a known issue: this format extension does
not claim to fix it. No Unicode placeholders are used as a workaround.
