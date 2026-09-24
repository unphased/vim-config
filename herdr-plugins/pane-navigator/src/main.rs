use serde_json::Value;
use std::env;
use std::error::Error;
use std::io::{self, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

type Result<T> = std::result::Result<T, Box<dyn Error>>;

const PLUGIN_ID: &str = "local.pane-navigator";
const ENTRYPOINT: &str = "minimap";

fn herdr(args: &[&str]) -> Result<Value> {
    let output = Command::new(env::var("HERDR_BIN_PATH").unwrap_or_else(|_| "herdr".into()))
        .args(args)
        .env_remove("HERDR_PANE_ID")
        .output()?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr)
            .trim()
            .to_owned()
            .into());
    }
    Ok(serde_json::from_slice(&output.stdout)?)
}

fn value_str<'a>(value: &'a Value, path: &[&str]) -> Result<&'a str> {
    let mut current = value;
    for key in path {
        current = &current[*key];
    }
    current
        .as_str()
        .ok_or_else(|| format!("missing Herdr field {}", path.join(".")).into())
}

fn current_pane() -> Result<Value> {
    Ok(herdr(&["pane", "current", "--current"])?["result"]["pane"].clone())
}

fn current_pane_id() -> Result<String> {
    Ok(value_str(&current_pane()?, &["pane_id"])?.to_owned())
}

fn pane_layout(pane_id: &str) -> Result<Value> {
    Ok(herdr(&["pane", "layout", "--pane", pane_id])?["result"]["layout"].clone())
}

fn should_show(layout: &Value) -> bool {
    layout["zoomed"].as_bool() == Some(true)
        && layout["panes"]
            .as_array()
            .is_some_and(|panes| panes.len() > 1)
}

fn move_focus(direction: &str, pane_id: &str) -> Result<()> {
    let helper = env::var_os("HERDR_FOCUS_HELPER")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../herdr-focus.sh"));
    let output = Command::new(helper)
        .arg(direction)
        .env("HERDR_PANE_ID", pane_id)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr)
            .trim()
            .to_owned()
            .into());
    }
    Ok(())
}

fn arrow(direction: &str) -> char {
    match direction {
        "left" => '←',
        "right" => '→',
        "up" => '↑',
        "down" => '↓',
        _ => '●',
    }
}

fn crossed_tab_or_workspace(source_layout: &Value, destination: &Value) -> bool {
    source_layout["workspace_id"] != destination["workspace_id"]
        || source_layout["tab_id"] != destination["tab_id"]
}

fn open_popup(pane_id: &str, previous: Option<(&str, &str)>) -> Result<()> {
    let pane_env = format!("HERDR_NAV_PANE_ID={pane_id}");
    if let Some((previous_pane_id, direction)) = previous {
        let previous_env = format!("HERDR_NAV_PREVIOUS_PANE_ID={previous_pane_id}");
        let direction_env = format!("HERDR_NAV_TRANSITION_DIRECTION={direction}");
        herdr(&[
            "plugin",
            "pane",
            "open",
            "--plugin",
            PLUGIN_ID,
            "--entrypoint",
            ENTRYPOINT,
            "--env",
            &pane_env,
            "--env",
            &previous_env,
            "--env",
            &direction_env,
        ])?;
    } else {
        herdr(&[
            "plugin",
            "pane",
            "open",
            "--plugin",
            PLUGIN_ID,
            "--entrypoint",
            ENTRYPOINT,
            "--env",
            &pane_env,
        ])?;
    }
    Ok(())
}

fn show_after_move(direction: &str, pane_id: &str) -> Result<()> {
    let destination = current_pane()?;
    let destination_id = value_str(&destination, &["pane_id"])?;
    let source_layout = pane_layout(pane_id)?;
    let transition = crossed_tab_or_workspace(&source_layout, &destination);
    if should_show(&source_layout) {
        open_popup(destination_id, transition.then_some((pane_id, direction)))?;
    } else if transition && should_show(&pane_layout(destination_id)?) {
        open_popup(destination_id, None)?;
    }
    Ok(())
}

fn navigate_once(direction: &str) -> Result<()> {
    let pane_id = env::var("HERDR_PANE_ID").or_else(|_| current_pane_id())?;
    move_focus(direction, &pane_id)?;
    show_after_move(direction, &pane_id)
}

fn defer_show_after_move(direction: &str, pane_id: &str) -> Result<()> {
    let executable = env::current_exe()?;
    let mut command = Command::new(executable);
    command
        .args(["after-move", direction, pane_id])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.spawn()?;
    Ok(())
}

fn number(value: &Value, key: &str) -> Result<usize> {
    value[key]
        .as_u64()
        .map(|number| number as usize)
        .ok_or_else(|| format!("missing numeric layout field {key}").into())
}

fn add_edge(grid: &mut [Vec<u8>], x1: usize, y1: usize, x2: usize, y2: usize) {
    if y1 == y2 {
        for x in x1..x2 {
            grid[y1][x] |= 2;
            grid[y1][x + 1] |= 8;
        }
    } else {
        for y in y1..y2 {
            grid[y][x1] |= 4;
            grid[y + 1][x1] |= 1;
        }
    }
}

fn box_character(bits: u8) -> char {
    match bits {
        1 => '╵',
        2 => '╶',
        3 => '└',
        4 => '╷',
        5 => '│',
        6 => '┌',
        7 => '├',
        8 => '╴',
        9 => '┘',
        10 => '─',
        11 => '┴',
        12 => '┐',
        13 => '┤',
        14 => '┬',
        15 => '┼',
        _ => ' ',
    }
}

fn minimap(layout: &Value, width: usize, height: usize, marker: char) -> Result<String> {
    let width = width.max(12);
    let height = height.max(5);
    let area = &layout["area"];
    let area_x = number(area, "x")?;
    let area_y = number(area, "y")?;
    let area_width = number(area, "width")?;
    let area_height = number(area, "height")?;
    let focused = layout["focused_pane_id"].as_str().unwrap_or_default();
    let panes = layout["panes"].as_array().ok_or("missing layout panes")?;
    let mut grid = vec![vec![0_u8; width]; height];
    let mut boxes = Vec::with_capacity(panes.len());

    let scale = |value: usize, origin: usize, extent: usize, target: usize| {
        ((value - origin) * (target - 1) + extent / 2) / extent
    };

    for pane in panes {
        let rect = &pane["rect"];
        let rect_x = number(rect, "x")?;
        let rect_y = number(rect, "y")?;
        let mut x1 = scale(rect_x, area_x, area_width, width);
        let mut y1 = scale(rect_y, area_y, area_height, height);
        let mut x2 = scale(rect_x + number(rect, "width")?, area_x, area_width, width);
        let mut y2 = scale(
            rect_y + number(rect, "height")?,
            area_y,
            area_height,
            height,
        );
        x1 = x1.min(width - 1);
        y1 = y1.min(height - 1);
        x2 = x2.max(x1 + 1).min(width - 1);
        y2 = y2.max(y1 + 1).min(height - 1);
        add_edge(&mut grid, x1, y1, x2, y1);
        add_edge(&mut grid, x1, y2, x2, y2);
        add_edge(&mut grid, x1, y1, x1, y2);
        add_edge(&mut grid, x2, y1, x2, y2);
        boxes.push((pane["pane_id"].as_str().unwrap_or_default(), x1, y1, x2, y2));
    }

    let mut canvas: Vec<Vec<char>> = grid
        .into_iter()
        .map(|row| row.into_iter().map(box_character).collect())
        .collect();
    let selected = boxes
        .iter()
        .find(|pane| pane.0 == focused)
        .map(|pane| (pane.1, pane.2, pane.3, pane.4));
    if let Some((x1, y1, x2, y2)) = selected {
        canvas[(y1 + y2) / 2][(x1 + x2) / 2] = marker;
    }

    let pane_style = if marker == '●' {
        "\x1b[48;2;137;180;250m\x1b[38;2;30;30;46m"
    } else {
        "\x1b[48;2;249;226;175m\x1b[38;2;30;30;46m"
    };
    Ok(canvas
        .into_iter()
        .enumerate()
        .map(|(y, row)| {
            let visible_end = row
                .iter()
                .rposition(|character| *character != ' ')
                .map_or(0, |x| x + 1);
            let Some((x1, y1, x2, y2)) = selected else {
                return row[..visible_end].iter().collect();
            };
            if !(y1..=y2).contains(&y) {
                return row[..visible_end].iter().collect();
            }
            let mut line = String::new();
            for (x, character) in row.into_iter().take(visible_end.max(x2 + 1)).enumerate() {
                if x == x1 {
                    line.push_str(pane_style);
                }
                line.push(character);
                if x == x2 {
                    line.push_str("\x1b[0m");
                }
            }
            line
        })
        .collect::<Vec<_>>()
        .join("\n"))
}

fn terminal_size() -> (usize, usize) {
    let mut size = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let ok = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) } == 0;
    if ok && size.ws_col > 0 && size.ws_row > 0 {
        (size.ws_col as usize, size.ws_row as usize)
    } else {
        (42, 16)
    }
}

fn draw(pane_id: &str, marker: char, legend: &str) -> Result<()> {
    let pane = herdr(&["pane", "get", pane_id])?;
    let pane = &pane["result"]["pane"];
    let layout = pane_layout(pane_id)?;
    let (columns, rows) = terminal_size();
    let mut header = format!(
        "Workspace {}  Tab {}  {marker} {legend}",
        pane["workspace_id"].as_str().unwrap_or("?"),
        pane["tab_id"].as_str().unwrap_or("?")
    );
    header = header
        .chars()
        .take(columns.saturating_sub(1).max(1))
        .collect();
    let picture = minimap(
        &layout,
        columns.saturating_sub(2),
        rows.saturating_sub(2),
        marker,
    )?;
    print!("\x1b[2J\x1b[H{header}\n{picture}");
    io::stdout().flush()?;
    Ok(())
}

struct TerminalMode(Option<libc::termios>);

impl TerminalMode {
    fn cbreak() -> Result<Self> {
        if unsafe { libc::isatty(libc::STDIN_FILENO) } != 1 {
            return Ok(Self(None));
        }
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        let mut mode = original;
        mode.c_lflag &= !(libc::ICANON | libc::ECHO | libc::ISIG | libc::IEXTEN);
        mode.c_iflag &= !(libc::IXON | libc::ICRNL | libc::INLCR | libc::IGNCR);
        mode.c_cc[libc::VMIN] = 1;
        mode.c_cc[libc::VTIME] = 0;
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &mode) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        Ok(Self(Some(original)))
    }
}

impl Drop for TerminalMode {
    fn drop(&mut self) {
        if let Some(original) = &self.0 {
            unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original) };
        }
    }
}

fn direction(byte: u8) -> Option<&'static str> {
    match byte {
        8 | 127 => Some("left"),
        10 => Some("down"),
        11 => Some("up"),
        12 => Some("right"),
        _ => None,
    }
}

fn input_ready(timeout: Duration) -> Result<bool> {
    let milliseconds = timeout.as_millis().min(i32::MAX as u128) as i32;
    let mut descriptor = libc::pollfd {
        fd: libc::STDIN_FILENO,
        events: libc::POLLIN,
        revents: 0,
    };
    let ready = unsafe { libc::poll(&mut descriptor, 1, milliseconds) };
    if ready < 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(ready > 0)
}

fn wait_for_input(timeout: Duration) -> Result<Option<Vec<u8>>> {
    if !input_ready(timeout)? {
        return Ok(None);
    }

    let mut input = Vec::new();
    let mut buffer = [0_u8; 4096];
    loop {
        let read = io::stdin().read(&mut buffer)?;
        if read == 0 {
            break;
        }
        input.extend_from_slice(&buffer[..read]);
        if !input_ready(Duration::from_millis(2))? {
            break;
        }
    }
    Ok((!input.is_empty()).then_some(input))
}

fn forward_input(pane_id: &str, input: &[u8]) -> Result<()> {
    if input == [0] {
        herdr(&["pane", "send-keys", pane_id, "ctrl+space"])?;
        return Ok(());
    }
    let text = std::str::from_utf8(input)?;
    herdr(&["pane", "send-text", pane_id, text])?;
    Ok(())
}

fn interrupt_popup(pane_id: &str, timeout: Duration) -> Result<bool> {
    let Some(input) = wait_for_input(timeout)? else {
        return Ok(false);
    };
    if input.len() == 1
        && let Some(next_direction) = direction(input[0])
    {
        // The popup owns terminal input while visible. Replay a captured
        // navigation chord, then exit immediately. A detached follow-up opens
        // the resulting minimap after this modal has gone away.
        move_focus(next_direction, pane_id)?;
        defer_show_after_move(next_direction, pane_id)?;
    } else {
        // Any other bytes were intended for the tiled terminal underneath.
        forward_input(pane_id, &input)?;
    }
    Ok(true)
}

fn popup() -> Result<()> {
    let pane_id = env::var("HERDR_NAV_PANE_ID").or_else(|_| current_pane_id())?;
    let previous = env::var("HERDR_NAV_PREVIOUS_PANE_ID").ok();
    let transition_direction = env::var("HERDR_NAV_TRANSITION_DIRECTION").ok();
    let show_previous = match previous.as_deref() {
        Some(pane) => should_show(&pane_layout(pane)?),
        None => false,
    };
    let show_current = should_show(&pane_layout(&pane_id)?);
    if !show_previous && !show_current {
        return Ok(());
    }

    let timeout = env::var("HERDR_MINIMAP_TIMEOUT")
        .ok()
        .and_then(|value| value.parse::<f64>().ok())
        .map(Duration::from_secs_f64)
        .unwrap_or(Duration::from_millis(500));
    let _terminal = TerminalMode::cbreak()?;
    print!("\x1b[?25l");
    io::stdout().flush()?;

    let result = (|| -> Result<()> {
        if show_previous && let Some(previous) = previous.as_deref() {
            draw(
                previous,
                arrow(transition_direction.as_deref().unwrap_or_default()),
                "previous",
            )?;
            if interrupt_popup(&pane_id, timeout)? {
                return Ok(());
            }
        }
        if show_current {
            draw(&pane_id, '●', "current")?;
            interrupt_popup(&pane_id, timeout)?;
        }
        Ok(())
    })();

    print!("\x1b[?25h");
    io::stdout().flush()?;
    result
}

fn run() -> Result<()> {
    let arguments: Vec<String> = env::args().collect();
    match arguments.get(1).map(String::as_str) {
        Some(direction @ ("left" | "right" | "up" | "down")) => navigate_once(direction),
        Some("popup") => popup(),
        Some("after-move") if arguments.len() == 4 => {
            std::thread::sleep(Duration::from_millis(20));
            show_after_move(&arguments[2], &arguments[3])
        }
        _ => Err(
            "usage: herdr-pane-navigator {left|right|up|down|popup|after-move DIRECTION PANE}"
                .into(),
        ),
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn layout(zoomed: bool, panes: usize) -> Value {
        let mut pane_values = vec![json!({
            "pane_id": "w1:p1",
            "rect": {"height": 40, "width": 60, "x": 0, "y": 0}
        })];
        if panes > 1 {
            pane_values.push(json!({
                "pane_id": "w1:p2",
                "rect": {"height": 40, "width": 40, "x": 60, "y": 0}
            }));
        }
        json!({
            "area": {"height": 40, "width": 100, "x": 0, "y": 0},
            "focused_pane_id": "w1:p2",
            "panes": pane_values,
            "zoomed": zoomed
        })
    }

    #[test]
    fn popup_requires_zoom_and_multiple_panes() {
        assert!(should_show(&layout(true, 2)));
        assert!(!should_show(&layout(false, 2)));
        assert!(!should_show(&layout(true, 1)));
    }

    #[test]
    fn minimap_colors_the_current_pane_blue() {
        let output = minimap(&layout(true, 2), 30, 8, '●').unwrap();
        assert_eq!(output.matches("\x1b[48;2;137;180;250m").count(), 8);
        assert!(!output.contains("\x1b[48;2;249;226;175m"));
        assert_eq!(output.matches("\x1b[0m").count(), 8);
        assert_eq!(output.matches('●').count(), 1);
    }

    #[test]
    fn minimap_colors_the_previous_pane_yellow() {
        let output = minimap(&layout(true, 2), 30, 8, '→').unwrap();
        assert_eq!(output.matches("\x1b[48;2;249;226;175m").count(), 8);
        assert!(!output.contains("\x1b[48;2;137;180;250m"));
        assert_eq!(output.matches("\x1b[0m").count(), 8);
        assert_eq!(output.matches('→').count(), 1);
    }
}
