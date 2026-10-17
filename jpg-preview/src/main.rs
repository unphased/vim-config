use std::error::Error;
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, BufWriter, Cursor, Read, Write};
use std::path::PathBuf;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use fast_image_resize as fir;
use flate2::write::ZlibEncoder;
use flate2::Compression;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits};

const MAX_PIXELS: u64 = 64_000_000;
const MAX_DECODE_BYTES: u64 = 512 * 1024 * 1024;
const MAX_ENCODED_BYTES: u64 = 128 * 1024 * 1024;
const IMAGE_ID: u32 = 424_242;
const BASE64_CHUNK: usize = 4096;
const FALLBACK_CELL_PIXELS: (usize, usize) = (10, 20);

struct CliArgs {
    image: PathBuf,
    width_cells: usize,
    height_cells: usize,
    x: usize,
    y: usize,
}

struct PreparedImage {
    width: u32,
    height: u32,
    compressed_rgb: Vec<u8>,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("jpg-preview: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let args = parse_args(std::env::args_os().skip(1))?;
    let (cell_width, cell_height) = cell_pixels()?;
    let max_width = args
        .width_cells
        .checked_mul(cell_width)
        .ok_or("requested pixel width overflow")?;
    let max_height = args
        .height_cells
        .checked_mul(cell_height)
        .ok_or("requested pixel height overflow")?;
    let prepared = prepare_path(&args.image, max_width, max_height)?;

    let mut output = BufWriter::with_capacity(64 * 1024, io::stdout().lock());
    emit_kitty(&mut output, &prepared, args.x, args.y)?;
    output.flush()?;
    Ok(())
}

fn parse_args(args: impl Iterator<Item = OsString>) -> Result<CliArgs, Box<dyn Error>> {
    let args: Vec<_> = args.collect();
    if args.len() != 5 {
        return Err("usage: jpg-preview IMAGE WIDTH HEIGHT X Y".into());
    }
    let number = |index: usize, name: &str| -> Result<usize, Box<dyn Error>> {
        let value = args[index]
            .to_str()
            .ok_or_else(|| format!("{name} must be a non-negative integer"))?;
        let value = value.parse::<usize>()?;
        if (index == 1 || index == 2) && value == 0 {
            return Err(format!("{name} must be greater than zero").into());
        }
        Ok(value)
    };
    Ok(CliArgs {
        image: PathBuf::from(&args[0]),
        width_cells: number(1, "WIDTH")?,
        height_cells: number(2, "HEIGHT")?,
        x: number(3, "X")?,
        y: number(4, "Y")?,
    })
}

fn cell_pixels() -> Result<(usize, usize), Box<dyn Error>> {
    if let Some(value) = std::env::var_os("LF_IMAGE_CELL_PIXELS") {
        let value = value.to_str().ok_or("LF_IMAGE_CELL_PIXELS must be WxH")?;
        return parse_cell_pixels(value).map_err(Into::into);
    }

    let Ok(tty) = File::open("/dev/tty") else {
        return Ok(FALLBACK_CELL_PIXELS);
    };
    let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
    // TIOCGWINSZ only writes the winsize structure and issues no terminal query.
    let result = unsafe {
        libc::ioctl(
            std::os::fd::AsRawFd::as_raw_fd(&tty),
            libc::TIOCGWINSZ,
            &mut size,
        )
    };
    if result != 0 || size.ws_col == 0 || size.ws_row == 0 {
        return Ok(FALLBACK_CELL_PIXELS);
    }
    let width = usize::from(size.ws_xpixel) / usize::from(size.ws_col);
    let height = usize::from(size.ws_ypixel) / usize::from(size.ws_row);
    if width == 0 || height == 0 {
        Ok(FALLBACK_CELL_PIXELS)
    } else {
        Ok((width, height))
    }
}

fn parse_cell_pixels(value: &str) -> Result<(usize, usize), String> {
    let (width, height) = value
        .split_once('x')
        .ok_or_else(|| "LF_IMAGE_CELL_PIXELS must be WxH".to_owned())?;
    let width = width
        .parse::<usize>()
        .map_err(|_| "LF_IMAGE_CELL_PIXELS must be positive WxH".to_owned())?;
    let height = height
        .parse::<usize>()
        .map_err(|_| "LF_IMAGE_CELL_PIXELS must be positive WxH".to_owned())?;
    if width == 0 || height == 0 {
        return Err("LF_IMAGE_CELL_PIXELS must be positive WxH".to_owned());
    }
    Ok((width, height))
}

fn prepare_path(
    path: &PathBuf,
    max_width: usize,
    max_height: usize,
) -> Result<PreparedImage, Box<dyn Error>> {
    // image's JPEG decoder buffers its input before checking decoded limits.
    // Bound the actual read, not just metadata (which could change underneath us).
    let encoded = read_bounded(File::open(path)?, MAX_ENCODED_BYTES)?;
    let mut reader = ImageReader::new(Cursor::new(encoded)).with_guessed_format()?;
    if reader.format() != Some(ImageFormat::Jpeg) {
        return Err("input is not a JPEG image".into());
    }
    let mut limits = Limits::default();
    limits.max_image_width = Some(u16::MAX.into());
    limits.max_image_height = Some(u16::MAX.into());
    limits.max_alloc = Some(MAX_DECODE_BYTES);
    reader.limits(limits);
    prepare(reader.into_decoder()?, max_width, max_height)
}

fn read_bounded(input: impl Read, max_bytes: u64) -> io::Result<Vec<u8>> {
    let mut encoded = Vec::new();
    input.take(max_bytes + 1).read_to_end(&mut encoded)?;
    if encoded.len() as u64 > max_bytes {
        return Err(io::Error::other("encoded JPEG exceeds input size limit"));
    }
    Ok(encoded)
}

fn prepare(
    mut decoder: impl ImageDecoder,
    max_width: usize,
    max_height: usize,
) -> Result<PreparedImage, Box<dyn Error>> {
    let (source_width, source_height) = decoder.dimensions();
    if u64::from(source_width) * u64::from(source_height) > MAX_PIXELS {
        return Err(format!("JPEG exceeds the {MAX_PIXELS}-pixel safety limit").into());
    }
    if max_width == 0 || max_height == 0 {
        return Err("target pixel dimensions must be greater than zero".into());
    }

    let orientation = decoder.orientation()?;
    let mut decoded = DynamicImage::from_decoder(decoder)?;
    decoded.apply_orientation(orientation);
    let source = decoded.into_rgb8();
    let (width, height) = fit_dimensions(source.width(), source.height(), max_width, max_height);
    let pixels = if width == source.width() && height == source.height() {
        source.into_raw()
    } else {
        let src = fir::images::Image::from_vec_u8(
            source.width(),
            source.height(),
            source.into_raw(),
            fir::PixelType::U8x3,
        )?;
        let mut dst = fir::images::Image::new(width, height, fir::PixelType::U8x3);
        let options = fir::ResizeOptions::new()
            .resize_alg(fir::ResizeAlg::Convolution(fir::FilterType::Bilinear));
        fir::Resizer::new().resize(&src, &mut dst, Some(&options))?;
        dst.into_vec()
    };
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(&pixels)?;
    Ok(PreparedImage {
        width,
        height,
        compressed_rgb: encoder.finish()?,
    })
}

fn fit_dimensions(
    source_width: u32,
    source_height: u32,
    max_width: usize,
    max_height: usize,
) -> (u32, u32) {
    let scale = (max_width as f64 / f64::from(source_width))
        .min(max_height as f64 / f64::from(source_height))
        .min(1.0);
    let width = (f64::from(source_width) * scale).round().max(1.0) as u32;
    let height = (f64::from(source_height) * scale).round().max(1.0) as u32;
    (width, height)
}

fn emit_kitty(
    output: &mut impl Write,
    image: &PreparedImage,
    x: usize,
    y: usize,
) -> io::Result<()> {
    let column = x
        .checked_add(1)
        .ok_or_else(|| io::Error::other("X coordinate overflow"))?;
    let row = y
        .checked_add(1)
        .ok_or_else(|| io::Error::other("Y coordinate overflow"))?;
    output.write_all(b"\x1b7")?;
    write!(output, "\x1b[{row};{column}H")?;

    let chunk_size = (BASE64_CHUNK / 4) * 3;
    let chunk_count = image.compressed_rgb.len().div_ceil(chunk_size);
    for (index, chunk) in image.compressed_rgb.chunks(chunk_size).enumerate() {
        let more = usize::from(index + 1 < chunk_count);
        if index == 0 {
            write!(
                output,
                "\x1b_Ga=T,f=24,s={},v={},i={},q=2,C=1,o=z,m={more};",
                image.width, image.height, IMAGE_ID
            )?;
        } else {
            write!(output, "\x1b_Gm={more};")?;
        }
        output.write_all(STANDARD.encode(chunk).as_bytes())?;
        output.write_all(b"\x1b\\")?;
    }
    output.write_all(b"\x1b8")
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::read::ZlibDecoder;
    use image::codecs::jpeg::JpegEncoder;
    use image::RgbImage;
    use std::io::Cursor;
    use std::io::Read;

    fn jpeg_with_orientation(width: u32, height: u32, orientation: u16) -> Vec<u8> {
        let image = RgbImage::from_fn(width, height, |x, y| {
            image::Rgb([(x * 51) as u8, (y * 83) as u8, ((x + y) * 37) as u8])
        });
        let mut jpeg = Vec::new();
        JpegEncoder::new_with_quality(&mut jpeg, 100)
            .encode_image(&DynamicImage::ImageRgb8(image))
            .unwrap();
        let exif = [
            b'E',
            b'x',
            b'i',
            b'f',
            0,
            0,
            b'I',
            b'I',
            42,
            0,
            8,
            0,
            0,
            0,
            1,
            0,
            0x12,
            0x01,
            3,
            0,
            1,
            0,
            0,
            0,
            orientation as u8,
            (orientation >> 8) as u8,
            0,
            0,
            0,
            0,
            0,
            0,
        ];
        let mut with_exif = vec![0xff, 0xd8, 0xff, 0xe1, 0, exif.len() as u8 + 2];
        with_exif.extend_from_slice(&exif);
        with_exif.extend_from_slice(&jpeg[2..]);
        with_exif
    }

    fn decode_test_jpeg(bytes: &[u8], max_width: usize, max_height: usize) -> PreparedImage {
        let reader = ImageReader::new(Cursor::new(bytes))
            .with_guessed_format()
            .unwrap();
        prepare(reader.into_decoder().unwrap(), max_width, max_height).unwrap()
    }

    fn parse_protocol(output: &[u8]) -> (String, Vec<u8>) {
        let text = String::from_utf8(output.to_vec()).unwrap();
        let mut encoded = String::new();
        let mut header = String::new();
        for (index, packet) in text.split("\x1b_G").skip(1).enumerate() {
            let (fields, rest) = packet.split_once(';').unwrap();
            if index == 0 {
                header = fields.to_owned();
            }
            let (chunk, _) = rest.split_once("\x1b\\").unwrap();
            encoded.push_str(chunk);
        }
        (header, STANDARD.decode(encoded).unwrap())
    }

    fn inflate_zlib(data: &[u8]) -> Vec<u8> {
        let mut decoder = ZlibDecoder::new(Cursor::new(data));
        let mut output = Vec::new();
        decoder.read_to_end(&mut output).unwrap();
        output
    }

    #[test]
    fn applies_exif_orientation_and_resizes_to_cell_pixels() {
        let jpeg = jpeg_with_orientation(3, 2, 6);
        let prepared = decode_test_jpeg(&jpeg, 10, 10);
        assert_eq!((prepared.width, prepared.height), (2, 3));
        assert_eq!(inflate_zlib(&prepared.compressed_rgb).len(), 2 * 3 * 3);
        let mut terminal = Vec::new();
        emit_kitty(&mut terminal, &prepared, 0, 0).unwrap();
        let (header, compressed) = parse_protocol(&terminal);
        assert!(header.contains("s=2,v=3"));
        assert_eq!(inflate_zlib(&compressed).len(), 2 * 3 * 3);

        let smaller = decode_test_jpeg(&jpeg, 1, 2);
        assert_eq!((smaller.width, smaller.height), (1, 2));
        assert_eq!(inflate_zlib(&smaller.compressed_rgb).len(), 6);
    }

    #[test]
    fn emits_cursor_position_and_reassemblable_bounded_packets() {
        let raw = (0u32..50_000)
            .map(|i| (i.wrapping_mul(1_664_525).wrapping_add(1_013_904_223) >> 16) as u8)
            .collect::<Vec<_>>();
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::fast());
        encoder.write_all(&raw).unwrap();
        let compressed_rgb = encoder.finish().unwrap();
        let image = PreparedImage {
            width: 4,
            height: 3,
            compressed_rgb,
        };
        let mut output = Vec::new();
        emit_kitty(&mut output, &image, 7, 2).unwrap();
        assert!(
            output.starts_with(b"\x1b7\x1b[3;8H\x1b_Ga=T,f=24,s=4,v=3,i=424242,q=2,C=1,o=z,m=1;")
        );
        assert!(output.ends_with(b"\x1b8"));

        let text = String::from_utf8(output.clone()).unwrap();
        for (index, packet) in text.split("\x1b_G").skip(1).enumerate() {
            let (fields, rest) = packet.split_once(';').unwrap();
            let (chunk, _) = rest.split_once("\x1b\\").unwrap();
            assert!(chunk.len() <= BASE64_CHUNK);
            assert_eq!(
                fields.ends_with("m=1"),
                (index + 1) * ((BASE64_CHUNK / 4) * 3) < image.compressed_rgb.len()
            );
        }
        let (header, inflated) = parse_protocol(&output);
        assert!(header.starts_with("a=T,f=24,s=4,v=3,i=424242,q=2,C=1,o=z,m=1"));
        assert_eq!(inflate_zlib(&inflated), raw);
    }

    #[test]
    fn validates_cli_and_cell_pixel_override() {
        assert!(parse_args(
            ["file.jpg", "0", "2", "0", "0"]
                .map(OsString::from)
                .into_iter()
        )
        .is_err());
        assert!(parse_args(["file.jpg", "2"].map(OsString::from).into_iter()).is_err());
        assert!(parse_args(
            ["file.jpg", "wide", "2", "0", "0"]
                .map(OsString::from)
                .into_iter()
        )
        .is_err());
        assert_eq!(parse_cell_pixels("11x22").unwrap(), (11, 22));
        assert!(parse_cell_pixels("0x22").is_err());
        assert!(parse_cell_pixels("11").is_err());
    }

    #[test]
    fn bounds_encoded_reads_before_decoder_construction() {
        assert!(read_bounded(io::repeat(0xff), 128).is_err());
        assert_eq!(read_bounded(Cursor::new(b"jpeg"), 4).unwrap(), b"jpeg");
    }

    #[test]
    fn rejects_non_jpeg_content() {
        let reader = ImageReader::new(Cursor::new(b"not a jpeg".to_vec()))
            .with_guessed_format()
            .unwrap();
        assert_ne!(reader.format(), Some(ImageFormat::Jpeg));
        assert!(reader.into_decoder().is_err());
    }
}
