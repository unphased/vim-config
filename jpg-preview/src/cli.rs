use super::*;
use std::ffi::OsString;
use std::io::BufWriter;
use std::path::PathBuf;

const FALLBACK_CELL_PIXELS: (usize, usize) = (10, 20);

pub(super) struct CliArgs {
    pub(super) lf_id: Option<u32>,
    pub(super) image: PathBuf,
    pub(super) width_cells: usize,
    pub(super) height_cells: usize,
    pub(super) x: usize,
    pub(super) y: usize,
}

impl CliArgs {
    pub(super) fn image_area(&self) -> Result<Option<(usize, usize)>, Box<dyn Error>> {
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

#[doc(hidden)]
pub(super) fn cli_main() {
    if let Err(error) = run() {
        eprintln!("jpg-preview: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let raw_args: Vec<_> = std::env::args_os().skip(1).collect();
    if let Some((clear, id)) = parse_control_args(&raw_args)? {
        let _lock = lf::lock_preview(id)?;
        if clear {
            lf::clear_image(id)?;
        } else {
            lf::forget_receipt(id)?;
        }
        return Ok(());
    }
    let started = Instant::now();
    let args = parse_args(raw_args.into_iter())?;
    // Serialize lookup, terminal mutation, and publication for this LF client.
    // Otherwise an older helper could place a newer helper's resident pixels.
    let _lock = args.lf_id.map(lf::lock_preview).transpose()?;
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
    let resident_key = args
        .lf_id
        .and_then(|id| lf::ReceiptKey::for_preview(id, &args.image, [0; 8]));
    let placement = |width, height| {
        fitted_cells(
            width,
            height,
            max_width,
            max_height,
            args.width_cells,
            height_cells,
        )
    };
    if let (Some(id), Some(key)) = (args.lf_id, resident_key.as_ref()) {
        if let Some((status, (width, height))) = lf::resident_status(id, key) {
            lf::place_image(placement(width, height), args.x, image_y, id)?;
            // A geometry receipt represents acknowledged placement, not merely
            // resident pixels. The ACK-triggered reload can then be a no-op.
            if lf::ReceiptKey::for_preview(id, &args.image, [0; 8]).as_ref() == Some(key) {
                if let Some(display_key) = receipt_key.as_ref() {
                    let _ = lf::save_receipt(id, display_key, &status);
                }
            }
            println!("reused {status}");
            return Ok(());
        }
    }
    let prepared = prepare_path(&args.image, usize::MAX, usize::MAX)?;
    let cells = placement(prepared.width, prepared.height);

    if let Some(id) = args.lf_id {
        // Replacing the one terminal image invalidates even an old resident
        // receipt when delivery fails halfway through the new upload.
        lf::forget_receipt(id)?;
        let mut timings = prepared.timings;
        lf::emit_kitty(&prepared, args.x, image_y, id, cells, &mut timings)?;
        timings.total = started.elapsed();
        let status = timings.line(prepared.width, prepared.height);
        // Publish only after LF acknowledged the complete UI-thread write. A
        // metadata failure must not turn a successful display into an error.
        if let Some(key) = receipt_key.as_ref() {
            let current_key = lf::ReceiptKey::for_preview(id, &args.image, geometry);
            if current_key.as_ref() == Some(key) {
                if let Some(resident_key) = resident_key.as_ref() {
                    let _ = lf::save_resident(id, resident_key, &status);
                }
                let _ = lf::save_receipt(id, key, &status);
            }
        }
        println!("{status}");
    } else {
        let mut output = BufWriter::with_capacity(64 * 1024, io::stdout().lock());
        emit_kitty_placement(
            &mut output,
            &prepared,
            args.x,
            args.y,
            IMAGE_ID,
            Some(cells),
        )?;
        output.flush()?;
    }
    Ok(())
}

// Specify only the limiting axis: rounding both axes to whole cells stretches
// the image, especially with non-square terminal cells. Zero axes mean native.
fn fitted_cells(
    width: u32,
    height: u32,
    max_width: usize,
    max_height: usize,
    width_cells: usize,
    height_cells: usize,
) -> (usize, usize) {
    if width as usize <= max_width && height as usize <= max_height {
        (0, 0)
    } else if (max_width as u128) * u128::from(height) <= (max_height as u128) * u128::from(width) {
        (width_cells, 0)
    } else {
        (0, height_cells)
    }
}

pub(super) fn parse_control_args(args: &[OsString]) -> Result<Option<(bool, u32)>, Box<dyn Error>> {
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

pub(super) fn parse_args(args: impl Iterator<Item = OsString>) -> Result<CliArgs, Box<dyn Error>> {
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

pub(super) fn parse_cell_pixels(value: &str) -> Result<(usize, usize), String> {
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

#[cfg(test)]
mod tests {
    use super::fitted_cells;

    #[test]
    fn placement_uses_only_limiting_axis_without_upscaling() {
        // 10x20-pixel cells: a square in a tall box must not become 400x440.
        assert_eq!(fitted_cells(512, 512, 400, 440, 40, 22), (40, 0));
        assert_eq!(fitted_cells(512, 512, 600, 440, 60, 22), (0, 22));
        assert_eq!(fitted_cells(10, 10, 400, 440, 40, 22), (0, 0));
        assert_eq!(fitted_cells(800, 200, 400, 440, 40, 22), (40, 0));
        assert_eq!(fitted_cells(200, 800, 400, 440, 40, 22), (0, 22));
    }
}
