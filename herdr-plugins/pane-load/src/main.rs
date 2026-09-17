use std::collections::HashMap;

const FAST_SAMPLE_SECONDS: f64 = 0.5;
const SLOW_SAMPLE_SECONDS: f64 = 3.0;

type Identity = (i32, u64, u64);

#[derive(Clone, Debug, PartialEq, Eq)]
struct Process {
    pid: i32,
    ppid: i32,
    start: (u64, u64),
    user_ns: u64,
    system_ns: u64,
    name: String,
    resident_bytes: u64,
}

impl Process {
    fn identity(&self) -> Identity {
        (self.pid, self.start.0, self.start.1)
    }
}

#[derive(Default)]
struct CpuTracker {
    previous: HashMap<Identity, (u64, u64)>,
}

impl CpuTracker {
    fn values(
        &mut self,
        _processes: &[Process],
        _now: f64,
        _previous_time: Option<f64>,
    ) -> HashMap<Identity, f64> {
        todo!("port CPU tracking")
    }
}

fn quantize_cpu(_percent: f64) -> u64 {
    todo!("port positive half-up CPU rounding")
}

fn sample_interval(_global_cpu: f64) -> f64 {
    todo!("port adaptive sample interval")
}

fn format_memory(_byte_count: i64) -> String {
    todo!("port compact binary memory formatting")
}

fn scaled_cpu_bar(
    _percent: f64,
    _cells_per_hundred: usize,
    _quarter_ticks: bool,
    _hundred_tick_eighths: usize,
) -> String {
    todo!("port fractional CPU bars")
}

fn memory_share_bar(_value: f64, _total: f64) -> String {
    todo!("port Braille memory bars")
}

fn pane_title(_percent: f64, _memory: &str, _tree: &str) -> String {
    todo!("port pane title formatting")
}

fn command_from_procargs(_data: &[u8]) -> Option<String> {
    todo!("port KERN_PROCARGS2 argv parsing")
}

fn token_payload(
    _root_pid: i32,
    _processes: &[Process],
    _cpus: &HashMap<Identity, f64>,
    _display_names: &HashMap<Identity, String>,
) -> (String, String) {
    todo!("port process ownership and tree rendering")
}

fn main() {
    eprintln!("Rust pane-load migration is not active yet");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: i32, ppid: i32, start: u64, name: &str, resident_bytes: u64) -> Process {
        Process {
            pid,
            ppid,
            start: (2, start),
            user_ns: 0,
            system_ns: 0,
            name: name.into(),
            resident_bytes,
        }
    }

    #[test]
    fn cpu_delta_is_wall_based_and_pid_reuse_safe() {
        let mut tracker = CpuTracker::default();
        let first = process(10, 1, 1, "zsh", 0);
        assert_eq!(tracker.values(std::slice::from_ref(&first), 10.0, None)[&first.identity()], 0.0);

        let mut second = first.clone();
        second.system_ns = 2_000_000_000;
        assert_eq!(tracker.values(std::slice::from_ref(&second), 12.0, Some(10.0))[&second.identity()], 100.0);

        let mut reused = process(10, 1, 99, "new-exec", 0);
        reused.system_ns = 99_000_000_000;
        assert_eq!(tracker.values(std::slice::from_ref(&reused), 13.0, Some(12.0))[&reused.identity()], 0.0);
    }

    #[test]
    fn quantization_and_sampling_match_the_python_contract() {
        assert_eq!(quantize_cpu(0.4), 0);
        assert_eq!(quantize_cpu(0.5), 1);
        assert_eq!(quantize_cpu(2.5), 3);
        assert_eq!(sample_interval(50.0), SLOW_SAMPLE_SECONDS);
        assert_eq!(sample_interval(50.1), FAST_SAMPLE_SECONDS);
        assert_eq!(sample_interval(800.0), FAST_SAMPLE_SECONDS);
        assert_eq!(sample_interval(800.1), SLOW_SAMPLE_SECONDS);
    }

    #[test]
    fn memory_uses_three_significant_binary_figures_without_padding() {
        let kib = 1024_i64;
        let mib = 1024 * kib;
        let gib = 1024 * mib;
        assert_eq!(format_memory(0), "0B");
        assert_eq!(format_memory((5.3 * kib as f64).round() as i64), "5.3KB");
        assert_eq!(format_memory(24 * kib), "24KB");
        assert_eq!(format_memory((24.4 * kib as f64).round() as i64), "24.4KB");
        assert_eq!(format_memory(433 * kib), "433KB");
        assert_eq!(format_memory((1.14 * gib as f64).round() as i64), "1.14GB");
        assert_eq!(format_memory(10 * gib), "10GB");
        assert_eq!(format_memory((10.49 * gib as f64).round() as i64), "10.5GB");
        assert_eq!(format_memory(-4), "0B");
    }

    #[test]
    fn cpu_and_memory_bars_preserve_exact_glyph_contract() {
        assert_eq!(scaled_cpu_bar(25.0, 8, true, 5), "██");
        assert_eq!(scaled_cpu_bar(51.0, 8, true, 5), "█▉█▉▏");
        assert_eq!(scaled_cpu_bar(100.0, 8, true, 5), "█▉█▉█▉██");
        assert_eq!(scaled_cpu_bar(101.0, 8, true, 5), "█▉█▉█▉█▋▏");
        assert_eq!(scaled_cpu_bar(238.0, 2, false, 7), "█▉█▉▊");
        assert_eq!(memory_share_bar(26.0, 100.0), "⣿⡿⡀");
        assert_eq!(memory_share_bar(84.0, 100.0), "⣿⡿⣿⡿⣿⡿⣧");
        assert_eq!(memory_share_bar(100.0, 100.0), "⣿⡿⣿⡿⣿⡿⣿⣿");
    }

    #[test]
    fn process_tree_uses_normalized_cpu_and_memory_bars() {
        let kib = 1024_u64;
        let mib = 1024 * kib;
        let root = process(20, 1, 1, "zsh", 704 * kib);
        let parent = process(21, 20, 2, "node", 940 * mib);
        let child = process(22, 21, 3, "node", 183 * mib);
        let processes = vec![root.clone(), parent.clone(), child.clone()];
        let cpus = HashMap::from([
            (root.identity(), 0.0),
            (parent.identity(), 11.0),
            (child.identity(), 0.0),
        ]);
        let names = HashMap::from([
            (parent.identity(), "pi".into()),
            (child.identity(), "pi".into()),
        ]);
        assert_eq!(
            token_payload(root.pid, &processes, &cpus, &names),
            ("11".into(), "zsh(pi:█▉█▉█▉██⣿⡿⣿⡿⣿⡿⣧(pi:⣿⡄))".into())
        );
    }

    #[test]
    fn procargs_uses_the_trimmed_argv_zero_basename() {
        let mut data = 3_i32.to_ne_bytes().to_vec();
        data.extend_from_slice(b"/Users/slu/.n/bin/node\0\0pi   \0--flag\0value\0");
        assert_eq!(command_from_procargs(&data).as_deref(), Some("pi"));
        assert_eq!(command_from_procargs(b"bad"), None);
    }

    #[test]
    fn pane_title_uses_the_compact_top_level_scale() {
        assert_eq!(pane_title(25.0, "640MB", "zsh"), "25% ██ 640MB zsh");
    }
}
