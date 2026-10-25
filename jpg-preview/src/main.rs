use std::error::Error;
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, BufWriter, Cursor, Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

mod arw;
mod lf;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use fast_image_resize as fir;
use image::codecs::png::{CompressionType, FilterType, PngEncoder};
use image::{
    ColorType, DynamicImage, ImageDecoder, ImageEncoder, ImageFormat, ImageReader, Limits,
};

const MAX_PIXELS: u64 = 64_000_000;
const MAX_DECODE_BYTES: u64 = 512 * 1024 * 1024;
const MAX_ENCODED_BYTES: u64 = 128 * 1024 * 1024;
const IMAGE_ID: u32 = 424_242;
const BASE64_CHUNK: usize = 4096;
const FALLBACK_CELL_PIXELS: (usize, usize) = (10, 20);

struct CliArgs {
    lf_id: Option<u32>,
    image: PathBuf,
    width_cells: usize,
    height_cells: usize,
    x: usize,
    y: usize,
}

struct PreparedImage {
    width: u32,
    height: u32,
    payload: Vec<u8>,
    timings: Timings,
}

#[derive(Clone, Copy, Debug, Default)]
struct Timings {
    read: Duration,
    decode: Duration,
    orient: Duration,
    resize: Duration,
    compress: Duration,
    encode: Duration,
    stage_file: Duration,
    notify: Duration,
    lf_wait: Duration,
    total: Duration,
    input_bytes: usize,
    wire_bytes: usize,
}

impl Timings {
    fn line(&self, width: u32, height: u32) -> String {
        let ms = |duration: Duration| (duration.as_secs_f64() * 1000.0).round() as u64;
        let mut stages = [
            ("lf-wait", self.lf_wait),
            ("protocol", self.encode),
            ("compress", self.compress),
            ("resize", self.resize),
            ("orientation", self.orient),
            ("decode", self.decode),
            ("file", self.stage_file),
            ("read", self.read),
            ("notify", self.notify),
        ];
        stages.sort_by_key(|(_, duration)| std::cmp::Reverse(*duration));
        let stages = stages
            .map(|(name, duration)| format!("{name}={}", ms(duration)))
            .join(" ");
        format!(
            "total={}ms {stages} {}>{} {}x{}",
            ms(self.total),
            byte_size(self.input_bytes),
            byte_size(self.wire_bytes),
            width,
            height,
        )
    }
}

fn byte_size(bytes: usize) -> String {
    if bytes >= 1024 * 1024 {
        format!("{:.1}MiB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{}KiB", bytes.div_ceil(1024))
    } else {
        format!("{bytes}B")
    }
}

impl CliArgs {
    fn image_area(&self) -> Result<Option<(usize, usize)>, Box<dyn Error>> {
        let reserved = usize::from(self.lf_id.is_some());
        let height = self.height_cells.saturating_sub(reserved);
        if height == 0 {
            return Ok(None);
        }
        Ok(Some((
            height,
            self.y
                .checked_add(reserved)
                .ok_or("Y coordinate overflow")?,
        )))
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("jpg-preview: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let raw_args: Vec<_> = std::env::args_os().skip(1).collect();
    if let Some((clear, id)) = parse_control_args(&raw_args)? {
        if clear {
            lf::clear_image(id)?;
        } else {
            lf::forget_receipt(id)?;
        }
        return Ok(());
    }
    let started = Instant::now();
    let args = parse_args(raw_args.into_iter())?;
    let Some((height_cells, image_y)) = args.image_area()? else {
        println!("Image preview needs 2 rows (timing + image)");
        return Ok(());
    };
    let (cell_width, cell_height) = cell_pixels()?;
    let max_width = args
        .width_cells
        .checked_mul(cell_width)
        .ok_or("requested pixel width overflow")?;
    let max_height = height_cells
        .checked_mul(cell_height)
        .ok_or("requested pixel height overflow")?;
    let geometry = [
        args.x,
        image_y,
        args.width_cells,
        height_cells,
        cell_width,
        cell_height,
        max_width,
        max_height,
    ];
    let receipt_key = args
        .lf_id
        .and_then(|id| lf::ReceiptKey::for_preview(id, &args.image, geometry));
    if let (Some(id), Some(key)) = (args.lf_id, receipt_key.as_ref()) {
        if let Some(status) = lf::receipt_status(id, key) {
            println!("reused {status}");
            return Ok(());
        }
    }
    let prepared = prepare_path(&args.image, max_width, max_height)?;

    if let Some(id) = args.lf_id {
        let mut timings = prepared.timings;
        lf::emit_kitty(&prepared, args.x, image_y, id, &mut timings)?;
        timings.total = started.elapsed();
        let status = timings.line(prepared.width, prepared.height);
        // Publish only after LF acknowledged the complete UI-thread write. A
        // metadata failure must not turn a successful display into an error.
        if let Some(key) = receipt_key.as_ref() {
            let current_key = lf::ReceiptKey::for_preview(id, &args.image, geometry);
            if current_key.as_ref() == Some(key) {
                let _ = lf::save_receipt(id, key, &status);
            }
        }
        println!("{status}");
    } else {
        let mut output = BufWriter::with_capacity(64 * 1024, io::stdout().lock());
        emit_kitty(&mut output, &prepared, args.x, args.y)?;
        output.flush()?;
    }
    Ok(())
}

fn parse_control_args(args: &[OsString]) -> Result<Option<(bool, u32)>, Box<dyn Error>> {
    let Some(mode) = args.first().and_then(|value| value.to_str()) else {
        return Ok(None);
    };
    if mode != "--lf-clear" && mode != "--lf-forget" {
        return Ok(None);
    }
    if args.len() != 2 {
        return Err(format!("{mode} requires one numeric client ID").into());
    }
    let id = args[1]
        .to_str()
        .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))
        .ok_or("lf client ID must be a numeric u32")?
        .parse::<u32>()?;
    Ok(Some((mode == "--lf-clear", id)))
}

fn parse_args(args: impl Iterator<Item = OsString>) -> Result<CliArgs, Box<dyn Error>> {
    let args: Vec<_> = args.collect();
    let (lf_id, offset) = if args.first().is_some_and(|arg| arg == "--lf-id") {
        if args.len() < 2 {
            return Err("--lf-id requires a numeric client ID".into());
        }
        let id = args[1]
            .to_str()
            .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))
            .ok_or("--lf-id must be a numeric u32")?
            .parse::<u32>()?;
        (Some(id), 2)
    } else {
        (None, 0)
    };
    if args.len() != offset + 5 {
        return Err("usage: jpg-preview [--lf-id ID] IMAGE WIDTH HEIGHT X Y".into());
    }
    let number = |index: usize, name: &str| -> Result<usize, Box<dyn Error>> {
        let value = args[offset + index]
            .to_str()
            .ok_or_else(|| format!("{name} must be a non-negative integer"))?;
        let value = value.parse::<usize>()?;
        if (index == 1 || index == 2) && value == 0 {
            return Err(format!("{name} must be greater than zero").into());
        }
        Ok(value)
    };
    Ok(CliArgs {
        lf_id,
        image: PathBuf::from(&args[offset]),
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
    let started = Instant::now();
    let is_arw = path
        .extension()
        .is_some_and(|extension| extension.to_string_lossy().eq_ignore_ascii_case("arw"));
    if is_arw {
        let extracted = arw::extract(&mut File::open(path)?)?;
        let input_bytes = extracted.bytes.len();
        let mut reader = ImageReader::new(Cursor::new(extracted.bytes)).with_guessed_format()?;
        if reader.format() != Some(ImageFormat::Jpeg) {
            return Err("ARW embedded payload is not a JPEG image".into());
        }
        reader.limits(decode_limits());
        let decoder = reader.into_decoder()?;
        let read = started.elapsed();
        let mut prepared =
            prepare_with_orientation(decoder, max_width, max_height, extracted.orientation)?;
        prepared.timings.read = read;
        prepared.timings.input_bytes = input_bytes;
        return Ok(prepared);
    }

    // Bound actual reads because image decoders buffer input before checking limits.
    let encoded = read_bounded(File::open(path)?, MAX_ENCODED_BYTES)?;
    let input_bytes = encoded.len();
    let mut reader = ImageReader::new(Cursor::new(encoded)).with_guessed_format()?;
    if !matches!(reader.format(), Some(ImageFormat::Jpeg | ImageFormat::Png)) {
        return Err("input is not a supported JPEG or PNG image".into());
    }
    reader.limits(decode_limits());
    let decoder = reader.into_decoder()?;
    let read = started.elapsed();
    let mut prepared = prepare(decoder, max_width, max_height)?;
    prepared.timings.read = read;
    prepared.timings.input_bytes = input_bytes;
    Ok(prepared)
}

fn decode_limits() -> Limits {
    let mut limits = Limits::default();
    limits.max_image_width = Some(u16::MAX.into());
    limits.max_image_height = Some(u16::MAX.into());
    limits.max_alloc = Some(MAX_DECODE_BYTES);
    limits
}

fn read_bounded(input: impl Read, max_bytes: u64) -> io::Result<Vec<u8>> {
    let mut encoded = Vec::new();
    input.take(max_bytes + 1).read_to_end(&mut encoded)?;
    if encoded.len() as u64 > max_bytes {
        return Err(io::Error::other("encoded image exceeds input size limit"));
    }
    Ok(encoded)
}

fn prepare(
    decoder: impl ImageDecoder,
    max_width: usize,
    max_height: usize,
) -> Result<PreparedImage, Box<dyn Error>> {
    prepare_with_orientation(decoder, max_width, max_height, None)
}

fn prepare_with_orientation(
    mut decoder: impl ImageDecoder,
    max_width: usize,
    max_height: usize,
    orientation_override: Option<image::metadata::Orientation>,
) -> Result<PreparedImage, Box<dyn Error>> {
    let (source_width, source_height) = decoder.dimensions();
    if u64::from(source_width) * u64::from(source_height) > MAX_PIXELS {
        return Err(format!("image exceeds the {MAX_PIXELS}-pixel safety limit").into());
    }
    if max_width == 0 || max_height == 0 {
        return Err("target pixel dimensions must be greater than zero".into());
    }

    let mut timings = Timings::default();
    let started = Instant::now();
    let orientation = match orientation_override {
        Some(orientation) => orientation,
        None => decoder.orientation()?,
    };
    let mut decoded = DynamicImage::from_decoder(decoder)?;
    timings.decode = started.elapsed();
    let started = Instant::now();
    decoded.apply_orientation(orientation);
    timings.orient = started.elapsed();
    let started = Instant::now();
    let has_alpha = decoded.color().has_alpha();
    let (width, height) = fit_dimensions(decoded.width(), decoded.height(), max_width, max_height);
    let (pixels, color_type) = if has_alpha {
        let source = decoded.into_rgba8();
        let pixels = if width == source.width() && height == source.height() {
            source.into_raw()
        } else {
            let src = fir::images::Image::from_vec_u8(
                source.width(),
                source.height(),
                source.into_raw(),
                fir::PixelType::U8x4,
            )?;
            let mut dst = fir::images::Image::new(width, height, fir::PixelType::U8x4);
            let options = fir::ResizeOptions::new()
                .resize_alg(fir::ResizeAlg::Convolution(fir::FilterType::Bilinear));
            fir::Resizer::new().resize(&src, &mut dst, Some(&options))?;
            dst.into_vec()
        };
        (pixels, ColorType::Rgba8)
    } else {
        let source = decoded.into_rgb8();
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
        (pixels, ColorType::Rgb8)
    };
    timings.resize = started.elapsed();
    let started = Instant::now();
    let mut payload = Vec::new();
    PngEncoder::new_with_quality(&mut payload, CompressionType::Fast, FilterType::Paeth)
        .write_image(&pixels, width, height, color_type.into())?;
    timings.compress = started.elapsed();
    Ok(PreparedImage {
        width,
        height,
        payload,
        timings,
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
    let chunk_count = image.payload.len().div_ceil(chunk_size);
    for (index, chunk) in image.payload.chunks(chunk_size).enumerate() {
        let more = usize::from(index + 1 < chunk_count);
        if index == 0 {
            write!(
                output,
                "\x1b_Ga=T,f=100,s={},v={},i={},q=2,C=1,m={more};",
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
    use image::codecs::jpeg::JpegEncoder;
    use image::RgbImage;
    use std::io::Cursor;

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

    fn decode_png(data: &[u8]) -> DynamicImage {
        ImageReader::new(Cursor::new(data))
            .with_guessed_format()
            .unwrap()
            .decode()
            .unwrap()
    }

    fn png(width: u32, height: u32, bytes: &[u8], color: ColorType) -> Vec<u8> {
        let mut encoded = Vec::new();
        PngEncoder::new_with_quality(&mut encoded, CompressionType::Fast, FilterType::Paeth)
            .write_image(bytes, width, height, color.into())
            .unwrap();
        encoded
    }

    fn decode_test_image(bytes: &[u8], max_width: usize, max_height: usize) -> PreparedImage {
        let reader = ImageReader::new(Cursor::new(bytes))
            .with_guessed_format()
            .unwrap();
        prepare(reader.into_decoder().unwrap(), max_width, max_height).unwrap()
    }

    #[test]
    fn kitty_payload_uses_lossless_png_transport() {
        let rgba = [255, 0, 0, 0, 0, 0, 255, 255];
        let encoded = png(2, 1, &rgba, ColorType::Rgba8);
        let prepared = decode_test_image(&encoded, 2, 1);
        let mut output = Vec::new();
        emit_kitty(&mut output, &prepared, 0, 0).unwrap();
        let (header, payload) = parse_protocol(&output);
        assert!(header.starts_with("a=T,f=100,s=2,v=1"));

        let decoded = decode_png(&payload).into_rgba8();
        assert_eq!(decoded.into_raw(), rgba);
    }

    #[test]
    fn png_rgba_is_preserved_at_native_size_and_alpha_correct_when_resized() {
        let rgba = [255, 0, 0, 0, 0, 0, 255, 255];
        let encoded = png(2, 1, &rgba, ColorType::Rgba8);
        let native = decode_test_image(&encoded, 2, 1);
        assert_eq!(decode_png(&native.payload).into_rgba8().into_raw(), rgba);
        let mut output = Vec::new();
        emit_kitty(&mut output, &native, 0, 0).unwrap();
        let (header, payload) = parse_protocol(&output);
        assert!(header.contains("f=100"));
        assert_eq!(decode_png(&payload).into_rgba8().into_raw(), rgba);

        let resized = decode_test_image(&encoded, 1, 1);
        let pixels = decode_png(&resized.payload).into_rgba8().into_raw();
        assert_eq!(pixels.len(), 4);
        assert!(
            pixels[0] < 10,
            "transparent red contaminated output: {pixels:?}"
        );
        assert!(pixels[2] > 240, "opaque blue was lost: {pixels:?}");
        assert!(
            (120..=136).contains(&pixels[3]),
            "unexpected output alpha: {pixels:?}"
        );
    }

    #[test]
    fn decodes_png_grayscale_and_sixteen_bit_pixels() {
        let gray = png(2, 1, &[32, 192], ColorType::L8);
        let decoded = decode_test_image(&gray, 2, 1);
        assert_eq!(
            decode_png(&decoded.payload).into_rgb8().into_raw(),
            [32, 32, 32, 192, 192, 192]
        );

        let values = [0x1234u16, 0xabcd];
        let raw = values
            .iter()
            .flat_map(|value| value.to_ne_bytes())
            .collect::<Vec<_>>();
        let sixteen = png(2, 1, &raw, ColorType::L16);
        let decoded = decode_test_image(&sixteen, 2, 1);
        let pixels = decode_png(&decoded.payload).into_rgb8().into_raw();
        assert_eq!(pixels.len(), 6);
        assert_eq!(&pixels[0..3], &[pixels[0]; 3]);
        assert_eq!(&pixels[3..6], &[pixels[3]; 3]);
        assert!(pixels[0] < pixels[3]);
    }

    #[test]
    fn all_eight_orientation_overrides_match_reference_pixel_positions() {
        let jpeg = jpeg_with_orientation(3, 2, 6);
        let reader = ImageReader::new(Cursor::new(jpeg.clone()))
            .with_guessed_format()
            .unwrap();
        let raw = DynamicImage::from_decoder(reader.into_decoder().unwrap())
            .unwrap()
            .into_rgb8();
        for exif in 1..=8 {
            let orientation = image::metadata::Orientation::from_exif(exif).unwrap();
            let mut expected = DynamicImage::ImageRgb8(raw.clone());
            expected.apply_orientation(orientation);
            let reader = ImageReader::new(Cursor::new(jpeg.clone()))
                .with_guessed_format()
                .unwrap();
            let prepared =
                prepare_with_orientation(reader.into_decoder().unwrap(), 10, 10, Some(orientation))
                    .unwrap();
            assert_eq!(
                (prepared.width, prepared.height),
                (expected.width(), expected.height())
            );
            assert_eq!(
                decode_png(&prepared.payload).into_rgb8().into_raw(),
                expected.into_rgb8().into_raw()
            );
        }
    }

    #[test]
    fn arw_orientation_overrides_embedded_jpeg_orientation_once() {
        let jpeg = jpeg_with_orientation(3, 2, 3);
        let jpeg_reader = ImageReader::new(Cursor::new(jpeg.clone()))
            .with_guessed_format()
            .unwrap();
        let mut expected = DynamicImage::from_decoder(jpeg_reader.into_decoder().unwrap()).unwrap();
        expected.apply_orientation(image::metadata::Orientation::Rotate90);
        let expected_pixels = expected.into_rgb8().into_raw();
        let ifd_offset = 8usize;
        let jpeg_offset = 64u32;
        let mut arw = vec![0; ifd_offset];
        arw[..2].copy_from_slice(b"II");
        arw[2..4].copy_from_slice(&42u16.to_le_bytes());
        arw[4..8].copy_from_slice(&(ifd_offset as u32).to_le_bytes());
        arw.extend_from_slice(&3u16.to_le_bytes());
        for (tag, kind, value) in [
            (0x0201u16, 4u16, jpeg_offset),
            (0x0202, 4, jpeg.len() as u32),
            (0x0112, 3, 6),
        ] {
            arw.extend_from_slice(&tag.to_le_bytes());
            arw.extend_from_slice(&kind.to_le_bytes());
            arw.extend_from_slice(&1u32.to_le_bytes());
            if kind == 3 {
                arw.extend_from_slice(&(value as u16).to_le_bytes());
                arw.extend_from_slice(&[0, 0]);
            } else {
                arw.extend_from_slice(&value.to_le_bytes());
            }
        }
        arw.extend_from_slice(&[0; 4]);
        arw.resize(jpeg_offset as usize, 0);
        arw.extend_from_slice(&jpeg);
        let extracted = arw::extract(&mut Cursor::new(arw)).unwrap();
        let reader = ImageReader::new(Cursor::new(extracted.bytes))
            .with_guessed_format()
            .unwrap();
        let prepared = prepare_with_orientation(
            reader.into_decoder().unwrap(),
            10,
            10,
            extracted.orientation,
        )
        .unwrap();
        assert_eq!((prepared.width, prepared.height), (2, 3));
        assert_eq!(
            decode_png(&prepared.payload).into_rgb8().into_raw(),
            expected_pixels
        );
    }

    #[test]
    fn applies_exif_orientation_and_resizes_to_cell_pixels() {
        let jpeg = jpeg_with_orientation(3, 2, 6);
        let prepared = decode_test_jpeg(&jpeg, 10, 10);
        assert_eq!((prepared.width, prepared.height), (2, 3));
        assert_eq!(
            decode_png(&prepared.payload).into_rgb8().into_raw().len(),
            2 * 3 * 3
        );
        let mut terminal = Vec::new();
        emit_kitty(&mut terminal, &prepared, 0, 0).unwrap();
        let (header, payload) = parse_protocol(&terminal);
        assert!(header.contains("s=2,v=3"));
        assert_eq!(decode_png(&payload).into_rgb8().into_raw().len(), 2 * 3 * 3);

        let smaller = decode_test_jpeg(&jpeg, 1, 2);
        assert_eq!((smaller.width, smaller.height), (1, 2));
        assert_eq!(decode_png(&smaller.payload).into_rgb8().into_raw().len(), 6);
    }

    #[test]
    fn emits_cursor_position_and_reassemblable_bounded_packets() {
        let mut state = 0x1234_5678u32;
        let raw = (0..160 * 160 * 3)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                state as u8
            })
            .collect::<Vec<_>>();
        let payload = png(160, 160, &raw, ColorType::Rgb8);
        let image = PreparedImage {
            width: 160,
            height: 160,
            payload,
            timings: Timings::default(),
        };
        let mut output = Vec::new();
        emit_kitty(&mut output, &image, 7, 2).unwrap();
        assert!(
            output.starts_with(b"\x1b7\x1b[3;8H\x1b_Ga=T,f=100,s=160,v=160,i=424242,q=2,C=1,m=1;")
        );
        assert!(output.ends_with(b"\x1b8"));

        let text = String::from_utf8(output.clone()).unwrap();
        for (index, packet) in text.split("\x1b_G").skip(1).enumerate() {
            let (fields, rest) = packet.split_once(';').unwrap();
            let (chunk, _) = rest.split_once("\x1b\\").unwrap();
            assert!(chunk.len() <= BASE64_CHUNK);
            assert_eq!(
                fields.ends_with("m=1"),
                (index + 1) * ((BASE64_CHUNK / 4) * 3) < image.payload.len()
            );
        }
        let (header, reassembled_payload) = parse_protocol(&output);
        assert!(header.starts_with("a=T,f=100,s=160,v=160,i=424242,q=2,C=1,m=1"));
        assert!(!header.contains("o=z"));
        assert_eq!(reassembled_payload, image.payload);
        assert_eq!(decode_png(&reassembled_payload).into_rgb8().into_raw(), raw);
    }

    #[test]
    fn timing_row_reserves_exactly_one_cell_row_without_changing_raw_geometry() {
        let parse = |args: &[&str]| parse_args(args.iter().map(OsString::from)).unwrap();
        let raw = parse(&["image.jpg", "40", "20", "60", "1"]);
        assert_eq!(raw.image_area().unwrap(), Some((20, 1)));
        let mut native = parse(&["--lf-id", "17", "image.jpg", "40", "20", "60", "1"]);
        assert_eq!(native.image_area().unwrap(), Some((19, 2)));
        assert_eq!(fit_dimensions(800, 1000, 400, 19 * 20), (304, 380));
        native.height_cells = 1;
        assert_eq!(native.image_area().unwrap(), None);
        native.height_cells = 2;
        assert_eq!(native.image_area().unwrap(), Some((1, 2)));
        native.y = usize::MAX;
        assert!(native.image_area().is_err());
    }

    #[test]
    fn timing_line_uses_readable_labels_sorted_by_cost_in_one_ascii_row() {
        let ms = Duration::from_millis;
        let timings = Timings {
            read: ms(1),
            decode: ms(2),
            orient: ms(3),
            resize: ms(4),
            compress: ms(5),
            encode: ms(6),
            stage_file: ms(2),
            notify: ms(1),
            lf_wait: ms(8),
            total: ms(32),
            input_bytes: 1024 * 1024,
            wire_bytes: 2 * 1024 * 1024,
        };
        let line = timings.line(400, 300);
        assert_eq!(line, "total=32ms lf-wait=8 protocol=6 compress=5 resize=4 orientation=3 decode=2 file=2 read=1 notify=1 1.0MiB>2.0MiB 400x300");
        assert!(line
            .bytes()
            .all(|byte| byte.is_ascii_graphic() || byte == b' '));
        assert_eq!(byte_size(128), "128B");
        assert_eq!(byte_size(1025), "2KiB");
        assert_eq!(byte_size(1024 * 1024), "1.0MiB");
    }

    #[test]
    fn path_preparation_records_actual_input_and_nonoverlapping_stage_timings() {
        let path = std::env::temp_dir().join(format!("jpg-timing-{}.png", std::process::id()));
        let bytes = png(2, 1, &[255, 0, 0, 0, 0, 0, 255, 255], ColorType::Rgba8);
        std::fs::write(&path, &bytes).unwrap();
        let started = Instant::now();
        let result = prepare_path(&path, 1, 1);
        std::fs::remove_file(path).unwrap();
        let prepared = result.unwrap();
        let timings = prepared.timings;
        assert_eq!(timings.input_bytes, bytes.len());
        assert!(
            timings.read + timings.decode + timings.orient + timings.resize + timings.compress
                <= started.elapsed()
        );
        assert_eq!((prepared.width, prepared.height), (1, 1));
    }

    #[test]
    fn validates_optional_lf_client_id_without_changing_legacy_arguments() {
        let legacy = parse_args(
            ["file.jpg", "2", "3", "4", "5"]
                .map(OsString::from)
                .into_iter(),
        )
        .unwrap();
        assert_eq!(legacy.lf_id, None);
        assert_eq!(
            (legacy.width_cells, legacy.height_cells, legacy.x, legacy.y),
            (2, 3, 4, 5)
        );

        let synchronized = parse_args(
            ["--lf-id", "4294967295", "file.jpg", "2", "3", "4", "5"]
                .map(OsString::from)
                .into_iter(),
        )
        .unwrap();
        assert_eq!(synchronized.lf_id, Some(u32::MAX));
        for invalid in ["-1", "4294967296", "1;quit", "1\\n"] {
            assert!(parse_args(
                ["--lf-id", invalid, "file.jpg", "2", "3", "4", "5"]
                    .map(OsString::from)
                    .into_iter()
            )
            .is_err());
        }
        assert!(parse_args(["--lf-id"].map(OsString::from).into_iter()).is_err());
    }

    #[test]
    fn cleanup_commands_accept_only_one_numeric_client_id() {
        let parse = |args: &[&str]| {
            parse_control_args(&args.iter().map(OsString::from).collect::<Vec<_>>())
        };
        assert_eq!(parse(&["--lf-clear", "17"]).unwrap(), Some((true, 17)));
        assert_eq!(parse(&["--lf-forget", "17"]).unwrap(), Some((false, 17)));
        assert_eq!(parse(&["file.jpg", "1", "1", "0", "0"]).unwrap(), None);
        for flag in ["--lf-clear", "--lf-forget"] {
            assert!(parse(&[flag]).is_err());
            assert!(parse(&[flag, "17", "extra"]).is_err());
            for id in ["", "-1", "1;quit", "4294967296"] {
                assert!(parse(&[flag, id]).is_err());
            }
        }
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
