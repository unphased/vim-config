use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::env;
use std::ffi::{CStr, CString, OsStr};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const PLUGIN_ID: &str = "local.pane-load";
const SOURCE: &str = "plugin:local.pane-load";
const TTL_MS: u64 = 15_000;
const FAST_SAMPLE_SECONDS: f64 = 0.5;
const SLOW_SAMPLE_SECONDS: f64 = 3.0;
const HEARTBEAT_SECONDS: f64 = 5.0;
const PLUGIN_REFRESH_SECONDS: f64 = 15.0;
const MAX_RECONNECTS: usize = 8;
const RPC_TIMEOUT: Duration = Duration::from_secs(2);
const CONTROL_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_LINE_BUFFER: usize = 1 << 20;

type Identity = (i32, u64, u64);

#[derive(Debug)]
enum AppError {
    ServerUnavailable(String),
    Herdr(String),
    Other(String),
}

impl std::fmt::Display for AppError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ServerUnavailable(message) | Self::Herdr(message) | Self::Other(message) => {
                f.write_str(message)
            }
        }
    }
}

impl std::error::Error for AppError {}

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
        processes: &[Process],
        now: f64,
        previous_time: Option<f64>,
    ) -> HashMap<Identity, f64> {
        let wall = previous_time.map_or(0.0, |previous| (now - previous).max(0.0));
        let mut current = HashMap::with_capacity(processes.len());
        let mut result = HashMap::with_capacity(processes.len());
        for process in processes {
            let key = process.identity();
            let counter = (process.user_ns, process.system_ns);
            current.insert(key, counter);
            let cpu = match (self.previous.get(&key), wall > 0.0) {
                (Some(old), true) => {
                    let delta =
                        (counter.0 as i128 - old.0 as i128) + (counter.1 as i128 - old.1 as i128);
                    (delta.max(0) as f64) / (wall * 1_000_000_000.0) * 100.0
                }
                _ => 0.0,
            };
            result.insert(key, cpu);
        }
        self.previous = current;
        result
    }
}

fn quantize_cpu(percent: f64) -> u64 {
    if !percent.is_finite() || percent <= 0.0 {
        0
    } else {
        (percent + 0.5).floor() as u64
    }
}

fn sample_interval(global_cpu: f64) -> f64 {
    if global_cpu > 50.0 && global_cpu <= 800.0 {
        FAST_SAMPLE_SECONDS
    } else {
        SLOW_SAMPLE_SECONDS
    }
}

fn format_memory(byte_count: i64) -> String {
    let byte_count = byte_count.max(0) as f64;
    if byte_count < 1024.0 {
        return format!("{byte_count:.0}B");
    }
    let (value, unit) = if byte_count < 1024.0_f64.powi(2) {
        (byte_count / 1024.0, "KB")
    } else if byte_count < 1024.0_f64.powi(3) {
        (byte_count / 1024.0_f64.powi(2), "MB")
    } else {
        (byte_count / 1024.0_f64.powi(3), "GB")
    };
    let mut number = if value >= 1000.0 {
        format!("{}", (value / 10.0).round() as u64 * 10)
    } else if value < 10.0 {
        format!("{value:.2}")
    } else if value < 100.0 {
        format!("{value:.1}")
    } else {
        format!("{value:.0}")
    };
    while number.ends_with('0') && number.contains('.') {
        number.pop();
    }
    if number.ends_with('.') {
        number.pop();
    }
    number + unit
}

const FRACTIONAL_BLOCKS: [&str; 8] = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];
const BRAILLE_FRACTIONS: [&str; 8] = ["", "⡀", "⡄", "⡆", "⡇", "⣇", "⣧", "⣷"];
const BRAILLE_FULL: &str = "⣿";
const BRAILLE_QUARTER_TICK: &str = "⡿";

fn scaled_cpu_bar(
    percent: f64,
    cells_per_hundred: usize,
    quarter_ticks: bool,
    hundred_tick_eighths: usize,
) -> String {
    assert!(
        cells_per_hundred > 0,
        "cells_per_hundred must be a positive integer"
    );
    assert!(
        !quarter_ticks || cells_per_hundred.is_multiple_of(4),
        "quarter ticks require cells_per_hundred divisible by four"
    );
    assert!(
        (1..=7).contains(&hundred_tick_eighths),
        "hundred_tick_eighths must be an integer from one through seven"
    );

    let cpu = quantize_cpu(percent);
    let units = (u128::from(cpu) * cells_per_hundred as u128 * 8 + 50) / 100;
    let hundred_units = (cpu / 100) as u128 * cells_per_hundred as u128 * 8;
    let units = if !cpu.is_multiple_of(100) && units == hundred_units {
        units + 1
    } else {
        units
    };
    let full = (units / 8) as usize;
    let partial = (units % 8) as usize;
    let mut bar: Vec<char> = std::iter::repeat_n('█', full).collect();
    bar.extend(FRACTIONAL_BLOCKS[partial].chars());
    let mut boundary = 25_u64;
    while boundary < cpu {
        let marker = if boundary.is_multiple_of(100) {
            Some(FRACTIONAL_BLOCKS[hundred_tick_eighths])
        } else if quarter_ticks {
            Some("▉")
        } else {
            None
        };
        if let Some(marker) = marker {
            let position = (boundary as usize * cells_per_hundred / 100).saturating_sub(1);
            if position < bar.len() {
                bar.splice(position..=position, marker.chars());
            }
        }
        boundary += 25;
    }
    bar.into_iter().collect()
}

fn memory_share_bar(value: f64, total: f64) -> String {
    let percent = quantize_cpu(if total > 0.0 {
        value / total * 100.0
    } else {
        0.0
    });
    let units = (percent * 8 * 8 + 50) / 100;
    let full = units / 8;
    let partial = units % 8;
    let mut bar: Vec<char> = BRAILLE_FULL.repeat(full as usize).chars().collect();
    bar.extend(BRAILLE_FRACTIONS[partial as usize].chars());
    let mut boundary = 25_u64;
    while boundary < percent {
        let position = (boundary as usize * 8 / 100).saturating_sub(1);
        if position < bar.len() {
            bar.splice(position..=position, BRAILLE_QUARTER_TICK.chars());
        }
        boundary += 25;
    }
    bar.into_iter().collect()
}

fn format_cpu_meter(
    percent: f64,
    cells_per_hundred: usize,
    quarter_ticks: bool,
    hundred_tick_eighths: usize,
) -> String {
    let cpu = quantize_cpu(percent);
    let bar = scaled_cpu_bar(
        cpu as f64,
        cells_per_hundred,
        quarter_ticks,
        hundred_tick_eighths,
    );
    if bar.is_empty() {
        format!("{cpu}%")
    } else {
        format!("{cpu}% {bar}")
    }
}

fn cpu_meter(percent: f64) -> String {
    format_cpu_meter(percent, 8, true, 5)
}

fn pane_title(percent: f64, memory: &str, tree: &str) -> String {
    format!("{} {} {}", cpu_meter(percent), memory, tree)
}

fn workspace_cpu_meter(percent: f64) -> String {
    format_cpu_meter(percent, 2, false, 7)
}

fn workspace_cpu_tokens(percent: f64) -> Map<String, Value> {
    let cpu = quantize_cpu(percent);
    let meter = workspace_cpu_meter(cpu as f64);
    let active = if cpu == 0 {
        "cpu_idle"
    } else if cpu < 25 {
        "cpu_cool"
    } else if cpu < 100 {
        "cpu_active"
    } else if cpu < 200 {
        "cpu_warm"
    } else if cpu < 400 {
        "cpu_hot"
    } else {
        "cpu_very_hot"
    };
    let mut tokens = Map::new();
    tokens.insert("cpu".into(), Value::String(meter.clone()));
    for name in [
        "cpu_idle",
        "cpu_cool",
        "cpu_active",
        "cpu_warm",
        "cpu_hot",
        "cpu_very_hot",
    ] {
        tokens.insert(
            name.into(),
            if name == active {
                Value::String(meter.clone())
            } else {
                Value::Null
            },
        );
    }
    tokens
}

fn process_display_name(process: &Process, command: Option<&str>) -> String {
    if process.name == "term-capture" {
        "tcap".into()
    } else {
        command.unwrap_or(&process.name).into()
    }
}

fn command_from_procargs(data: &[u8]) -> Option<String> {
    let int_size = std::mem::size_of::<libc::c_int>();
    if data.len() < int_size {
        return None;
    }
    let argc = i32::from_ne_bytes(data[..int_size].try_into().ok()?);
    if argc < 1 {
        return None;
    }
    let executable_end = data[int_size..].iter().position(|byte| *byte == 0)? + int_size;
    let mut offset = executable_end + 1;
    while offset < data.len() && data[offset] == 0 {
        offset += 1;
    }
    let argv_end = data[offset..].iter().position(|byte| *byte == 0)? + offset;
    let argv0 = String::from_utf8_lossy(&data[offset..argv_end]);
    let basename = argv0.rsplit('/').next().unwrap_or(&argv0);
    let command = basename.trim_start_matches('-').trim();
    (!command.is_empty()).then(|| command.to_string())
}

#[derive(Clone, Debug)]
struct ProcessIndex {
    processes: Vec<Process>,
    by_pid: HashMap<i32, Process>,
    children: HashMap<i32, Vec<Process>>,
}

fn build_process_index<I: IntoIterator<Item = Process>>(processes: I) -> ProcessIndex {
    let values: Vec<Process> = processes.into_iter().collect();
    let mut by_pid = HashMap::new();
    for process in &values {
        by_pid.entry(process.pid).or_insert_with(|| process.clone());
    }
    let unique: Vec<Process> = values
        .iter()
        .filter(|process| {
            by_pid
                .get(&process.pid)
                .is_some_and(|selected| selected.identity() == process.identity())
        })
        .cloned()
        .collect();
    let mut children: HashMap<i32, Vec<Process>> = HashMap::new();
    for process in &values {
        if by_pid
            .get(&process.pid)
            .is_some_and(|selected| selected.identity() == process.identity())
        {
            children
                .entry(process.ppid)
                .or_default()
                .push(process.clone());
        }
    }
    for values in children.values_mut() {
        values.sort_by_key(|process| (process.pid, process.identity()));
    }
    ProcessIndex {
        processes: unique,
        by_pid,
        children,
    }
}

fn assign_process_owners(
    index: &ProcessIndex,
    roots: &HashMap<String, i32>,
) -> (HashMap<Identity, String>, HashMap<String, Vec<Process>>) {
    let mut owners = HashMap::new();
    let mut distances = HashMap::new();
    let mut queue = VecDeque::new();
    for (pane_id, pid) in roots {
        if let Some(root) = index.by_pid.get(pid) {
            let identity = root.identity();
            if let std::collections::hash_map::Entry::Vacant(entry) = owners.entry(identity) {
                entry.insert(pane_id.clone());
                distances.insert(identity, 0_usize);
                queue.push_back((root.clone(), pane_id.clone(), 0_usize));
            }
        }
    }
    while let Some((process, pane_id, distance)) = queue.pop_front() {
        let identity = process.identity();
        if distances.get(&identity) != Some(&distance) || owners.get(&identity) != Some(&pane_id) {
            continue;
        }
        if let Some(children) = index.children.get(&process.pid) {
            for child in children {
                let child_identity = child.identity();
                let next_distance = distance + 1;
                if next_distance < *distances.get(&child_identity).unwrap_or(&usize::MAX) {
                    owners.insert(child_identity, pane_id.clone());
                    distances.insert(child_identity, next_distance);
                    queue.push_back((child.clone(), pane_id.clone(), next_distance));
                }
            }
        }
    }
    let mut owned: HashMap<String, Vec<Process>> = roots
        .keys()
        .map(|pane_id| (pane_id.clone(), Vec::new()))
        .collect();
    for process in &index.processes {
        if let Some(pane_id) = owners.get(&process.identity()) {
            owned
                .entry(pane_id.clone())
                .or_default()
                .push(process.clone());
        }
    }
    (owners, owned)
}

fn safe_name(name: &str) -> String {
    let result: String = name
        .chars()
        .map(|ch| {
            if ch.is_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '_'
            }
        })
        .collect();
    if result.is_empty() {
        "?".into()
    } else {
        result
    }
}

fn tree_payload(
    root_pid: i32,
    processes: &[Process],
    cpus: &HashMap<Identity, f64>,
    index: Option<&ProcessIndex>,
    display_names: &HashMap<Identity, String>,
) -> (f64, String, HashSet<Identity>) {
    let owned_index;
    let index = match index {
        Some(index) => index,
        None => {
            owned_index = build_process_index(processes.iter().cloned());
            &owned_index
        }
    };
    let allowed: HashSet<Identity> = processes.iter().map(Process::identity).collect();
    let Some(root) = index.by_pid.get(&root_pid) else {
        return (0.0, String::new(), HashSet::new());
    };
    if !allowed.contains(&root.identity()) {
        return (0.0, String::new(), HashSet::new());
    }

    // One deterministic breadth-first spanning tree prevents malformed parent
    // cycles from inflating totals or rendering a process more than once.
    let mut nodes = Vec::new();
    let mut child_map: HashMap<Identity, Vec<Process>> = HashMap::new();
    let mut seen = HashSet::from([root.identity()]);
    let mut queue = VecDeque::from([root.clone()]);
    while let Some(process) = queue.pop_front() {
        let identity = process.identity();
        nodes.push(process.clone());
        let children = child_map.entry(identity).or_default();
        if let Some(index_children) = index.children.get(&process.pid) {
            for child in index_children {
                let child_identity = child.identity();
                if !allowed.contains(&child_identity) || !seen.insert(child_identity) {
                    continue;
                }
                children.push(child.clone());
                queue.push_back(child.clone());
            }
        }
    }

    let mut cpu_totals = HashMap::new();
    let mut memory_totals = HashMap::new();
    for process in nodes.iter().rev() {
        let identity = process.identity();
        let cpu = cpus.get(&identity).copied().unwrap_or(0.0)
            + child_map
                .get(&identity)
                .into_iter()
                .flatten()
                .map(|child| {
                    cpu_totals
                        .get(&child.identity())
                        .copied()
                        .unwrap_or_else(|| cpus.get(&child.identity()).copied().unwrap_or(0.0))
                })
                .sum::<f64>();
        let memory = process.resident_bytes
            + child_map
                .get(&identity)
                .into_iter()
                .flatten()
                .map(|child| {
                    memory_totals
                        .get(&child.identity())
                        .copied()
                        .unwrap_or(child.resident_bytes)
                })
                .sum::<u64>();
        cpu_totals.insert(identity, cpu);
        memory_totals.insert(identity, memory);
    }
    let total_cpu: f64 = nodes
        .iter()
        .map(|process| cpus.get(&process.identity()).copied().unwrap_or(0.0))
        .sum();
    let total_memory: f64 = nodes
        .iter()
        .map(|process| process.resident_bytes as f64)
        .sum();
    let branch_share = |process: &Process| {
        let cpu_share = if total_cpu > 0.0 {
            cpu_totals.get(&process.identity()).copied().unwrap_or(0.0) / total_cpu * 100.0
        } else {
            0.0
        };
        let memory_share = if total_memory > 0.0 {
            memory_totals.get(&process.identity()).copied().unwrap_or(0) as f64 / total_memory
                * 100.0
        } else {
            0.0
        };
        cpu_share.max(memory_share)
    };

    let mut main = Vec::new();
    let mut main_ids = HashSet::new();
    let mut current = Some(root.clone());
    while let Some(process) = current {
        if !main_ids.insert(process.identity()) {
            break;
        }
        let next = child_map
            .get(&process.identity())
            .into_iter()
            .flatten()
            .max_by(|left, right| {
                branch_share(left)
                    .total_cmp(&branch_share(right))
                    .then_with(|| right.pid.cmp(&left.pid))
            })
            .cloned();
        main.push(process);
        current = next;
    }
    let mut selected = main_ids.clone();
    let mut optional_roots = Vec::new();
    for parent in &main {
        if let Some(children) = child_map.get(&parent.identity()) {
            for child in children {
                if !main_ids.contains(&child.identity()) && branch_share(child) >= 5.0 {
                    optional_roots.push((parent.clone(), child.clone()));
                }
            }
        }
    }
    optional_roots.sort_by(|left, right| {
        branch_share(&left.1)
            .total_cmp(&branch_share(&right.1))
            .then_with(|| left.1.pid.cmp(&right.1.pid))
    });
    for (_, branch) in optional_roots {
        let mut stack = vec![branch];
        while let Some(process) = stack.pop() {
            if !selected.insert(process.identity()) || main_ids.contains(&process.identity()) {
                continue;
            }
            if let Some(children) = child_map.get(&process.identity()) {
                stack.extend(children.iter().cloned());
            }
        }
    }

    let mut order = Vec::new();
    let mut rendered_seen = HashSet::new();
    let mut stack = vec![root.clone()];
    while let Some(process) = stack.pop() {
        if !selected.contains(&process.identity()) || !rendered_seen.insert(process.identity()) {
            continue;
        }
        order.push(process.clone());
        if let Some(children) = child_map.get(&process.identity()) {
            stack.extend(
                children
                    .iter()
                    .filter(|child| selected.contains(&child.identity()))
                    .rev()
                    .cloned(),
            );
        }
    }
    let mut rendered: HashMap<Identity, String> = HashMap::new();
    for process in order.iter().rev() {
        let identity = process.identity();
        let name = safe_name(
            display_names
                .get(&identity)
                .map(String::as_str)
                .unwrap_or(&process.name),
        );
        let cpu_bar = scaled_cpu_bar(
            cpus.get(&identity).copied().unwrap_or(0.0) / total_cpu * 100.0,
            8,
            true,
            5,
        );
        let memory_bar = memory_share_bar(process.resident_bytes as f64, total_memory);
        let mut here = name;
        if !cpu_bar.is_empty() || !memory_bar.is_empty() {
            here.push(':');
            here.push_str(&cpu_bar);
            here.push_str(&memory_bar);
        }
        let children_text: Vec<String> = child_map
            .get(&identity)
            .into_iter()
            .flatten()
            .filter_map(|child| rendered.get(&child.identity()).cloned())
            .collect();
        if !children_text.is_empty() {
            here.push('(');
            here.push_str(&children_text.join(","));
            here.push(')');
        }
        rendered.insert(identity, here);
    }
    (
        total_cpu,
        rendered.remove(&root.identity()).unwrap_or_default(),
        selected,
    )
}

#[allow(dead_code)]
fn process_tree(
    root_pid: i32,
    processes: &[Process],
    cpus: &HashMap<Identity, f64>,
    display_names: &HashMap<Identity, String>,
) -> (f64, String) {
    let (total, tree, _) = tree_payload(root_pid, processes, cpus, None, display_names);
    (total, tree)
}

#[allow(dead_code)]
fn token_payload(
    root_pid: i32,
    processes: &[Process],
    cpus: &HashMap<Identity, f64>,
    display_names: &HashMap<Identity, String>,
) -> (String, String) {
    let (total, tree, _) = tree_payload(root_pid, processes, cpus, None, display_names);
    (quantize_cpu(total).to_string(), tree)
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct ProcBsdInfo {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    reserved: u32,
    comm: [libc::c_char; 16],
    name: [libc::c_char; 32],
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    tdev: u32,
    tpgid: u32,
    nice: i32,
    start_sec: u64,
    start_usec: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct ProcTaskInfo {
    virtual_size: u64,
    resident_size: u64,
    total_user: u64,
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow_faults: i32,
    messages_sent: i32,
    messages_received: i32,
    syscalls_mach: i32,
    syscalls_unix: i32,
    csw: i32,
    threadnum: i32,
    numrunning: i32,
    priority: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MachTimebase {
    numer: u32,
    denom: u32,
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn proc_listpids(
        type_: u32,
        typeinfo: u32,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
    fn proc_pidinfo(
        pid: libc::c_int,
        flavor: libc::c_int,
        arg: u64,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
    fn sysctl(
        name: *mut libc::c_int,
        namelen: libc::c_uint,
        oldp: *mut libc::c_void,
        oldlenp: *mut libc::size_t,
        newp: *mut libc::c_void,
        newlen: libc::size_t,
    ) -> libc::c_int;
    fn mach_timebase_info(info: *mut MachTimebase) -> libc::c_int;
}

trait ProcessSampler {
    fn enumerate(&mut self) -> Vec<Process>;
    fn command(&mut self, pid: i32) -> Option<String>;
}

struct MacProcessSampler {
    #[cfg(target_os = "macos")]
    timebase: MachTimebase,
}

impl MacProcessSampler {
    #[allow(clippy::needless_return)]
    fn new() -> Result<Self, AppError> {
        #[cfg(target_os = "macos")]
        {
            let mut timebase = MachTimebase::default();
            // SAFETY: the OS writes exactly one MachTimebase value.
            let result = unsafe { mach_timebase_info(&mut timebase) };
            if result != 0 || timebase.denom == 0 {
                return Err(AppError::Other("cannot read Mach CPU timebase".into()));
            }
            return Ok(Self { timebase });
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err(AppError::Other(
                "local.pane-load supports macOS only".into(),
            ))
        }
    }

    #[cfg(target_os = "macos")]
    fn pids(&self) -> Vec<i32> {
        let mut size = 4096_i32;
        let mut last = Vec::new();
        for _ in 0..4 {
            let mut buffer = vec![0_u32; (size as usize) / 4];
            // proc_listpids type 1 is PROC_ALL_PIDS; its result is bytes.
            let count = unsafe { proc_listpids(1, 0, buffer.as_mut_ptr().cast(), size) };
            if count < 0 {
                return Vec::new();
            }
            last = buffer
                .iter()
                .take((count as usize) / 4)
                .filter_map(|pid| (*pid != 0).then_some(*pid as i32))
                .collect();
            if count < size {
                return last;
            }
            size = size.saturating_mul(2);
        }
        last
    }

    #[cfg(target_os = "macos")]
    fn native_command(&self, pid: i32) -> Option<String> {
        let mut mib = [1_i32, 49_i32, pid]; // CTL_KERN, KERN_PROCARGS2, pid.
        let mut size = 0_usize;
        // SAFETY: null oldp with a valid oldlenp requests the required size.
        if unsafe {
            sysctl(
                mib.as_mut_ptr(),
                3,
                std::ptr::null_mut(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        } != 0
            || size < std::mem::size_of::<libc::c_int>()
            || size > 1 << 20
        {
            return None;
        }
        let mut buffer = vec![0_u8; size];
        let mut actual = size;
        // SAFETY: buffer has the exact size returned by the first sysctl call.
        if unsafe {
            sysctl(
                mib.as_mut_ptr(),
                3,
                buffer.as_mut_ptr().cast(),
                &mut actual,
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            return None;
        }
        command_from_procargs(&buffer[..actual.min(buffer.len())])
    }
}

impl ProcessSampler for MacProcessSampler {
    fn enumerate(&mut self) -> Vec<Process> {
        #[cfg(target_os = "macos")]
        {
            let mut result = Vec::new();
            for pid in self.pids() {
                let mut bsd = ProcBsdInfo::default();
                let mut task = ProcTaskInfo::default();
                // Flavor 3 is proc_pidinfo(PROC_PIDTBSDINFO).
                let bsd_size = unsafe {
                    proc_pidinfo(
                        pid,
                        3,
                        0,
                        (&mut bsd as *mut ProcBsdInfo).cast(),
                        std::mem::size_of::<ProcBsdInfo>() as i32,
                    )
                };
                if bsd_size != std::mem::size_of::<ProcBsdInfo>() as i32 {
                    continue;
                }
                // Flavor 4 is proc_pidinfo(PROC_PIDTASKINFO).
                let task_size = unsafe {
                    proc_pidinfo(
                        pid,
                        4,
                        0,
                        (&mut task as *mut ProcTaskInfo).cast(),
                        std::mem::size_of::<ProcTaskInfo>() as i32,
                    )
                };
                if task_size != std::mem::size_of::<ProcTaskInfo>() as i32 {
                    continue;
                }
                let raw = c_string(&bsd.name).or_else(|| c_string(&bsd.comm));
                let name = raw
                    .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
                    .unwrap_or_else(|| "?".into());
                let convert = |ticks: u64| {
                    ((ticks as u128 * self.timebase.numer as u128) / self.timebase.denom as u128)
                        as u64
                };
                result.push(Process {
                    pid,
                    ppid: bsd.ppid as i32,
                    start: (bsd.start_sec, bsd.start_usec),
                    user_ns: convert(task.total_user),
                    system_ns: convert(task.total_system),
                    name,
                    resident_bytes: task.resident_size,
                });
            }
            result
        }
        #[cfg(not(target_os = "macos"))]
        {
            Vec::new()
        }
    }

    fn command(&mut self, pid: i32) -> Option<String> {
        #[cfg(target_os = "macos")]
        {
            self.native_command(pid)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = pid;
            None
        }
    }
}

fn c_string(bytes: &[libc::c_char]) -> Option<Vec<u8>> {
    let bytes: Vec<u8> = bytes.iter().map(|byte| *byte as u8).collect();
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    (end > 0).then(|| bytes[..end].to_vec())
}

fn set_fd_cloexec(fd: RawFd, enabled: bool) -> io::Result<()> {
    // SAFETY: fcntl only accesses the flags of this caller-owned descriptor.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let updated = if enabled {
        flags | libc::FD_CLOEXEC
    } else {
        flags & !libc::FD_CLOEXEC
    };
    if unsafe { libc::fcntl(fd, libc::F_SETFD, updated) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn set_fd_nonblocking(fd: RawFd, enabled: bool) -> io::Result<()> {
    // SAFETY: fcntl only accesses the flags of this caller-owned descriptor.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let updated = if enabled {
        flags | libc::O_NONBLOCK
    } else {
        flags & !libc::O_NONBLOCK
    };
    if unsafe { libc::fcntl(fd, libc::F_SETFL, updated) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn connect_unix(path: &str, timeout: Duration) -> io::Result<UnixStream> {
    let bytes = path.as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.is_empty() || bytes.contains(&0) || bytes.len() >= address.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Unix socket path is too long or invalid",
        ));
    }
    address.sun_family = libc::AF_UNIX as _;
    for (slot, byte) in address.sun_path.iter_mut().zip(bytes) {
        *slot = *byte as libc::c_char;
    }
    let address_len =
        (std::mem::size_of_val(&address.sun_family) + bytes.len() + 1) as libc::socklen_t;
    // SAFETY: socket returns a fresh descriptor owned immediately by OwnedFd.
    let raw_fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if raw_fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: raw_fd is a newly-created valid descriptor.
    let fd = unsafe { OwnedFd::from_raw_fd(raw_fd) };
    set_fd_nonblocking(fd.as_raw_fd(), true)?;
    // SAFETY: address points to a valid sockaddr_un with its initialized length.
    let result = unsafe {
        libc::connect(
            fd.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            address_len,
        )
    };
    if result < 0 {
        let error = io::Error::last_os_error();
        let pending = error.raw_os_error().is_some_and(|code| {
            code == libc::EINPROGRESS || code == libc::EALREADY || code == libc::EINTR
        });
        if !pending {
            return Err(error);
        }
        let deadline = Instant::now()
            .checked_add(timeout)
            .unwrap_or_else(Instant::now);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Unix socket connect timed out",
                ));
            }
            let millis = remaining.as_millis().min(i32::MAX as u128).max(1) as i32;
            let mut poll_fd = libc::pollfd {
                fd: fd.as_raw_fd(),
                events: libc::POLLOUT,
                revents: 0,
            };
            // SAFETY: poll_fd points to one valid writable pollfd.
            let polled = unsafe { libc::poll(&mut poll_fd, 1, millis) };
            if polled == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Unix socket connect timed out",
                ));
            }
            if polled < 0 {
                let poll_error = io::Error::last_os_error();
                if poll_error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(poll_error);
            }
            let mut socket_error = 0_i32;
            let mut length = std::mem::size_of_val(&socket_error) as libc::socklen_t;
            // SAFETY: getsockopt writes one c_int into socket_error.
            if unsafe {
                libc::getsockopt(
                    fd.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    (&mut socket_error as *mut i32).cast(),
                    &mut length,
                )
            } < 0
            {
                return Err(io::Error::last_os_error());
            }
            if socket_error != 0 {
                return Err(io::Error::from_raw_os_error(socket_error));
            }
            break;
        }
    }
    set_fd_nonblocking(fd.as_raw_fd(), false)?;
    // Transfer ownership to UnixStream; the descriptor remains blocking so
    // callers can establish their read/write timeouts or event semantics.
    let raw_fd = fd.into_raw_fd();
    // SAFETY: raw_fd is transferred exactly once from OwnedFd.
    Ok(unsafe { UnixStream::from_raw_fd(raw_fd) })
}

struct RPCClient {
    path: String,
    timeout: Duration,
    sequence: u64,
}

impl RPCClient {
    fn new(path: String) -> Self {
        Self {
            path,
            timeout: RPC_TIMEOUT,
            sequence: 0,
        }
    }

    fn call(&mut self, method: &str, params: Value) -> Result<Value, AppError> {
        self.sequence += 1;
        let request = json!({
            "id": format!("pane-load-{}", self.sequence),
            "method": method,
            "params": params,
        });
        let mut conn = connect_unix(&self.path, self.timeout)
            .map_err(|error| AppError::ServerUnavailable(error.to_string()))?;
        conn.set_read_timeout(Some(self.timeout))
            .and_then(|_| conn.set_write_timeout(Some(self.timeout)))
            .map_err(|error| AppError::ServerUnavailable(error.to_string()))?;
        let mut encoded = serde_json::to_vec(&request)
            .map_err(|error| AppError::ServerUnavailable(error.to_string()))?;
        encoded.push(b'\n');
        conn.write_all(&encoded)
            .map_err(|error| AppError::ServerUnavailable(error.to_string()))?;
        let _ = conn.shutdown(std::net::Shutdown::Write);
        let data = read_until_newline(&mut conn)?;
        let line = data
            .split(|byte| *byte == b'\n')
            .next()
            .filter(|line| !line.is_empty())
            .ok_or_else(|| AppError::ServerUnavailable("empty Herdr response".into()))?;
        let response: Value = serde_json::from_slice(line)
            .map_err(|_| AppError::ServerUnavailable("invalid Herdr response".into()))?;
        if let Some(error) = response.get("error") {
            let code = error.get("code").and_then(Value::as_str).unwrap_or("error");
            let message = error.get("message").and_then(Value::as_str).unwrap_or("");
            return Err(AppError::Herdr(format!("{code}: {message}")));
        }
        Ok(response.get("result").cloned().unwrap_or_else(|| json!({})))
    }
}

fn read_until_newline(stream: &mut UnixStream) -> Result<Vec<u8>, AppError> {
    let mut data = Vec::new();
    let mut chunk = [0_u8; 65_536];
    loop {
        if data.contains(&b'\n') {
            return Ok(data);
        }
        if data.len() == MAX_LINE_BUFFER {
            return Err(AppError::ServerUnavailable(
                "Herdr response exceeds 1MiB".into(),
            ));
        }
        let size = (MAX_LINE_BUFFER - data.len()).min(chunk.len());
        match stream.read(&mut chunk[..size]) {
            Ok(0) => return Ok(data),
            Ok(count) => data.extend_from_slice(&chunk[..count]),
            Err(error) => return Err(AppError::ServerUnavailable(error.to_string())),
        }
    }
}

trait Api {
    fn call(&mut self, method: &str, params: Value) -> Result<Value, AppError>;
}

impl Api for RPCClient {
    fn call(&mut self, method: &str, params: Value) -> Result<Value, AppError> {
        RPCClient::call(self, method, params)
    }
}

const EVENTS: [&str; 6] = [
    "pane.created",
    "pane.closed",
    "pane.moved",
    "pane.exited",
    "workspace.closed",
    "tab.closed",
];

struct EventStream {
    path: String,
    timeout: Duration,
    sock: Option<UnixStream>,
    buffer: Vec<u8>,
}

impl EventStream {
    fn new(path: String) -> Self {
        Self {
            path,
            timeout: RPC_TIMEOUT,
            sock: None,
            buffer: Vec::new(),
        }
    }

    fn connect(&mut self) -> Result<(), AppError> {
        self.close();
        let mut sock = connect_unix(&self.path, self.timeout)
            .map_err(|error| AppError::ServerUnavailable(error.to_string()))?;
        let result = (|| {
            sock.set_read_timeout(Some(self.timeout))?;
            sock.set_write_timeout(Some(self.timeout))?;
            let subscriptions: Vec<Value> =
                EVENTS.iter().map(|event| json!({"type": event})).collect();
            let request = json!({
                "id": "pane-load-events",
                "method": "events.subscribe",
                "params": {"subscriptions": subscriptions},
            });
            let mut encoded = serde_json::to_vec(&request).map_err(io::Error::other)?;
            encoded.push(b'\n');
            sock.write_all(&encoded)?;
            let data = read_until_newline(&mut sock)
                .map_err(|error| io::Error::other(error.to_string()))?;
            let Some(newline) = data.iter().position(|byte| *byte == b'\n') else {
                return Err(io::Error::other("event subscription was not acknowledged"));
            };
            let response: Value = serde_json::from_slice(&data[..newline])
                .map_err(|_| io::Error::other("event subscription was not acknowledged"))?;
            if response.get("result").and_then(|result| result.get("type"))
                != Some(&Value::String("subscription_started".into()))
            {
                return Err(io::Error::other("event subscription was not acknowledged"));
            }
            let rest = &data[newline + 1..];
            if rest.len() > MAX_LINE_BUFFER {
                return Err(io::Error::other("event buffer exceeds 1MiB"));
            }
            self.buffer.extend_from_slice(rest);
            Ok::<(), io::Error>(())
        })();
        if let Err(error) = result {
            self.close();
            return Err(AppError::ServerUnavailable(error.to_string()));
        }
        sock.set_nonblocking(true)
            .map_err(|error| AppError::ServerUnavailable(error.to_string()))?;
        self.sock = Some(sock);
        Ok(())
    }

    fn poll(&mut self) -> Result<Vec<Value>, AppError> {
        let Some(mut sock) = self.sock.take() else {
            return Err(AppError::ServerUnavailable("event stream is closed".into()));
        };
        let result = self.poll_connected(&mut sock);
        self.sock = Some(sock);
        result
    }

    fn poll_connected(&mut self, sock: &mut UnixStream) -> Result<Vec<Value>, AppError> {
        let mut events = Vec::new();
        loop {
            while let Some(newline) = self.buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = self.buffer.drain(..=newline).collect();
                if let Ok(item) = serde_json::from_slice::<Value>(&line[..newline])
                    && item.get("event").is_some()
                {
                    events.push(item);
                }
            }
            if self.buffer.len() == MAX_LINE_BUFFER {
                return Err(AppError::ServerUnavailable(
                    "event buffer exceeds 1MiB".into(),
                ));
            }
            let mut chunk = [0_u8; 65_536];
            let size = (MAX_LINE_BUFFER - self.buffer.len()).min(chunk.len());
            match sock.read(&mut chunk[..size]) {
                Ok(0) => {
                    return if events.is_empty() {
                        Err(AppError::ServerUnavailable("event stream closed".into()))
                    } else {
                        Ok(events)
                    };
                }
                Ok(count) => self.buffer.extend_from_slice(&chunk[..count]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(events),
                Err(error) => return Err(AppError::ServerUnavailable(error.to_string())),
            }
        }
    }

    #[allow(dead_code)]
    fn has_buffered_event(&self) -> bool {
        self.buffer.contains(&b'\n')
    }

    fn close(&mut self) {
        self.sock = None;
        self.buffer.clear();
    }
}

trait EventSource {
    fn connect(&mut self) -> Result<(), AppError>;
    fn poll(&mut self) -> Result<Vec<Value>, AppError>;
    fn close(&mut self);
    fn raw_fd(&self) -> Option<RawFd>;
}

impl EventSource for EventStream {
    fn connect(&mut self) -> Result<(), AppError> {
        EventStream::connect(self)
    }

    fn poll(&mut self) -> Result<Vec<Value>, AppError> {
        EventStream::poll(self)
    }

    fn close(&mut self) {
        EventStream::close(self)
    }

    fn raw_fd(&self) -> Option<RawFd> {
        self.sock.as_ref().map(AsRawFd::as_raw_fd)
    }
}

struct Worker {
    socket_path: String,
    state_dir: PathBuf,
    server_dir: PathBuf,
    lock: Option<File>,
    rpc: Box<dyn Api>,
    events: Box<dyn EventSource>,
    sampler: Box<dyn ProcessSampler>,
    tracker: CpuTracker,
    root_identities: HashMap<String, Identity>,
    last_sent: HashMap<String, (String, String, String, f64)>,
    last_workspace_sent: HashMap<String, (String, String, f64)>,
    roots: HashMap<String, i32>,
    pane_workspaces: HashMap<String, String>,
    workspaces: HashSet<String>,
    stop_requested: bool,
    dirty: bool,
    next_snapshot: f64,
    next_plugin_check: f64,
    control: Option<UnixListener>,
}

impl Worker {
    fn new(socket_path: String, state_dir: PathBuf, lock: File) -> Result<Self, AppError> {
        let rpc = Box::new(RPCClient::new(socket_path.clone()));
        let events = Box::new(EventStream::new(socket_path.clone()));
        let sampler = Box::new(MacProcessSampler::new()?);
        Ok(Self::with_components(
            socket_path,
            state_dir,
            Some(lock),
            rpc,
            events,
            sampler,
        ))
    }

    fn with_components(
        socket_path: String,
        state_dir: PathBuf,
        lock: Option<File>,
        rpc: Box<dyn Api>,
        events: Box<dyn EventSource>,
        sampler: Box<dyn ProcessSampler>,
    ) -> Self {
        let server_dir = server_dir(&socket_path, &state_dir);
        Self {
            socket_path,
            state_dir,
            server_dir,
            lock,
            rpc,
            events,
            sampler,
            tracker: CpuTracker::default(),
            root_identities: HashMap::new(),
            last_sent: HashMap::new(),
            last_workspace_sent: HashMap::new(),
            roots: HashMap::new(),
            pane_workspaces: HashMap::new(),
            workspaces: HashSet::new(),
            stop_requested: false,
            dirty: false,
            next_snapshot: 0.0,
            next_plugin_check: 0.0,
            control: None,
        }
    }

    fn snapshot(&mut self) -> Result<(), AppError> {
        let result = self.rpc.call("session.snapshot", json!({}))?;
        let snapshot = result.get("snapshot").cloned().unwrap_or(result);
        let empty = Vec::new();
        let workspaces = snapshot
            .get("workspaces")
            .and_then(Value::as_array)
            .unwrap_or(&empty);
        let panes = snapshot
            .get("panes")
            .and_then(Value::as_array)
            .unwrap_or(&empty);
        let mut workspace_ids: HashSet<String> = workspaces
            .iter()
            .filter_map(|item| item.get("workspace_id").and_then(Value::as_str))
            .map(str::to_owned)
            .collect();
        let mut roots = HashMap::new();
        let mut pane_workspaces = HashMap::new();
        for pane in panes {
            let Some(pane_id) = pane.get("pane_id").and_then(Value::as_str) else {
                continue;
            };
            if pane_id.is_empty() {
                continue;
            }
            if let Some(workspace_id) = pane.get("workspace_id").and_then(Value::as_str) {
                pane_workspaces.insert(pane_id.into(), workspace_id.into());
                workspace_ids.insert(workspace_id.into());
            }
            let info = match self
                .rpc
                .call("pane.process_info", json!({"pane_id": pane_id}))
            {
                Ok(info) => info,
                Err(AppError::Herdr(_)) => continue,
                Err(error) => return Err(error),
            };
            let process_info = info.get("process_info").cloned().unwrap_or(info);
            let Some(pid) = process_info
                .get("shell_pid")
                .and_then(Value::as_i64)
                .and_then(|pid| i32::try_from(pid).ok())
                .filter(|pid| *pid > 0)
            else {
                continue;
            };
            roots.insert(pane_id.into(), pid);
        }
        for pane_id in self.roots.keys() {
            if !roots.contains_key(pane_id) {
                self.root_identities.remove(pane_id);
                self.last_sent.remove(pane_id);
            }
        }
        for workspace_id in self.workspaces.difference(&workspace_ids) {
            self.last_workspace_sent.remove(workspace_id);
        }
        for (pane_id, pid) in &roots {
            if self.roots.get(pane_id) != Some(pid) {
                self.root_identities.remove(pane_id);
            }
        }
        self.roots = roots;
        self.pane_workspaces = pane_workspaces;
        self.workspaces = workspace_ids;
        self.dirty = false;
        Ok(())
    }

    fn report(
        &mut self,
        pane_id: &str,
        cpu: &str,
        tree: &str,
        memory: &str,
    ) -> Result<bool, AppError> {
        let percent = cpu
            .parse::<f64>()
            .map_err(|error| AppError::Other(error.to_string()))?;
        let params = json!({
            "pane_id": pane_id,
            "source": SOURCE,
            "title": pane_title(percent, memory, tree),
            "tokens": {"cpu": cpu, "cpu_tree": tree, "memory": memory},
            "ttl_ms": TTL_MS,
        });
        match self.rpc.call("pane.report_metadata", params) {
            Ok(_) => Ok(true),
            Err(AppError::Herdr(error)) => {
                log_message(&format!("metadata report failed for {pane_id}: {error}"));
                Ok(false)
            }
            Err(error) => Err(error),
        }
    }

    fn report_workspace(
        &mut self,
        workspace_id: &str,
        cpu: &str,
        memory: &str,
    ) -> Result<bool, AppError> {
        let percent = cpu
            .parse::<f64>()
            .map_err(|error| AppError::Other(error.to_string()))?;
        let mut tokens = workspace_cpu_tokens(percent);
        tokens.insert("memory".into(), Value::String(memory.into()));
        let params = json!({
            "workspace_id": workspace_id,
            "source": SOURCE,
            "tokens": tokens,
            "ttl_ms": TTL_MS,
        });
        match self.rpc.call("workspace.report_metadata", params) {
            Ok(_) => Ok(true),
            Err(AppError::Herdr(error)) => {
                log_message(&format!(
                    "workspace metadata report failed for {workspace_id}: {error}"
                ));
                Ok(false)
            }
            Err(error) => Err(error),
        }
    }

    fn plugin_enabled(&mut self) -> Result<bool, AppError> {
        let result = self.rpc.call("plugin.list", json!({}))?;
        Ok(result
            .get("plugins")
            .and_then(Value::as_array)
            .is_some_and(|plugins| {
                plugins.iter().any(|plugin| {
                    plugin.get("plugin_id").and_then(Value::as_str) == Some(PLUGIN_ID)
                        && plugin.get("enabled").and_then(Value::as_bool) == Some(true)
                })
            }))
    }

    fn setup_control(&mut self) -> Result<(), AppError> {
        fs::create_dir_all(&self.server_dir).map_err(|error| AppError::Other(error.to_string()))?;
        let path = control_path(&self.socket_path, &self.state_dir);
        remove_runtime_files(&self.server_dir, &path)
            .map_err(|error| AppError::Other(error.to_string()))?;
        let listener =
            UnixListener::bind(&path).map_err(|error| AppError::Other(error.to_string()))?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .map_err(|error| AppError::Other(error.to_string()))?;
        listener
            .set_nonblocking(true)
            .map_err(|error| AppError::Other(error.to_string()))?;
        self.control = Some(listener);
        write_status(
            &self.server_dir,
            &json!({
                "pid": std::process::id(),
                "control": path,
                "started": unix_time(),
            }),
        )?;
        Ok(())
    }

    fn handle_control(&mut self) {
        let Some(listener) = self.control.as_ref() else {
            return;
        };
        let accepted = listener.accept();
        let Ok((mut conn, _)) = accepted else {
            return;
        };
        let _ = conn.set_read_timeout(Some(Duration::from_secs(1)));
        let mut message = [0_u8; 64];
        if conn
            .read(&mut message)
            .is_ok_and(|count| message[..count].trim_ascii_start().trim_ascii_end() == b"stop")
        {
            self.stop_requested = true;
            let _ = conn.write_all(b"ok\n");
        }
    }

    fn reconnect_snapshot(&mut self) -> bool {
        self.events.close();
        for attempt in 0..MAX_RECONNECTS {
            if self.stop_requested || STOP_REQUESTED.load(Ordering::Relaxed) {
                return false;
            }
            match self.events.connect().and_then(|()| {
                self.last_sent.clear();
                self.last_workspace_sent.clear();
                self.root_identities.clear();
                self.snapshot()?;
                if !self.events.poll()?.is_empty() {
                    self.dirty = true;
                }
                Ok(())
            }) {
                Ok(()) => return true,
                Err(error @ AppError::Herdr(_)) | Err(error @ AppError::ServerUnavailable(_)) => {
                    self.events.close();
                    log_message(&format!(
                        "Herdr unavailable ({}/{MAX_RECONNECTS}): {error}",
                        attempt + 1
                    ));
                    thread::sleep(Duration::from_secs_f64(
                        (0.25 * (attempt + 1) as f64).min(5.0),
                    ));
                }
                Err(error) => {
                    self.events.close();
                    log_message(&format!("Herdr unavailable: {error}"));
                    return false;
                }
            }
        }
        false
    }

    fn sample(&mut self, now: f64, previous: Option<f64>) -> Result<f64, AppError> {
        let processes = self.sampler.enumerate();
        let index = build_process_index(processes.iter().cloned());
        let cpus = self.tracker.values(&processes, now, previous);
        let global_cpu: f64 = cpus.values().sum();
        let mut valid_roots = HashMap::new();
        for (pane_id, pid) in &self.roots {
            if let Some(process) = index.by_pid.get(pid) {
                let expected = self.root_identities.get(pane_id);
                if expected.is_none_or(|identity| *identity == process.identity()) {
                    self.root_identities
                        .entry(pane_id.clone())
                        .or_insert_with(|| process.identity());
                    valid_roots.insert(pane_id.clone(), *pid);
                }
            }
        }
        let (_, owned) = assign_process_owners(&index, &valid_roots);
        let mut workspace_totals: HashMap<String, f64> = self
            .workspaces
            .iter()
            .map(|workspace| (workspace.clone(), 0.0))
            .collect();
        let mut workspace_memory: HashMap<String, u64> = self
            .workspaces
            .iter()
            .map(|workspace| (workspace.clone(), 0))
            .collect();
        let root_items: Vec<(String, i32)> = self
            .roots
            .iter()
            .map(|(pane_id, pid)| (pane_id.clone(), *pid))
            .collect();
        for (pane_id, pid) in root_items {
            let relevant = owned.get(&pane_id).cloned().unwrap_or_default();
            if !valid_roots.contains_key(&pane_id) || relevant.is_empty() {
                self.last_sent.remove(&pane_id);
                continue;
            }
            let mut display_names = HashMap::new();
            for process in &relevant {
                let command = (process.name != "term-capture")
                    .then(|| self.sampler.command(process.pid))
                    .flatten();
                let display_name = process_display_name(process, command.as_deref());
                if display_name != process.name {
                    display_names.insert(process.identity(), display_name);
                }
            }
            let (total, tree, _) =
                tree_payload(pid, &relevant, &cpus, Some(&index), &display_names);
            let memory_bytes: u64 = relevant.iter().map(|process| process.resident_bytes).sum();
            let memory = format_memory(memory_bytes.min(i64::MAX as u64) as i64);
            if let Some(workspace_id) = self.pane_workspaces.get(&pane_id) {
                *workspace_totals.entry(workspace_id.clone()).or_default() += total;
                *workspace_memory.entry(workspace_id.clone()).or_default() += memory_bytes;
            }
            if tree.is_empty() {
                continue;
            }
            let cpu = quantize_cpu(total).to_string();
            let unchanged = self.last_sent.get(&pane_id).is_some_and(|old| {
                old.0 == cpu && old.1 == tree && old.2 == memory && now - old.3 < HEARTBEAT_SECONDS
            });
            if unchanged {
                continue;
            }
            if self.report(&pane_id, &cpu, &tree, &memory)? {
                self.last_sent.insert(pane_id, (cpu, tree, memory, now));
            }
        }
        let mut workspace_ids: Vec<_> = self.workspaces.iter().cloned().collect();
        workspace_ids.sort();
        for workspace_id in workspace_ids {
            let cpu =
                quantize_cpu(*workspace_totals.get(&workspace_id).unwrap_or(&0.0)).to_string();
            let memory = format_memory(
                workspace_memory
                    .get(&workspace_id)
                    .copied()
                    .unwrap_or(0)
                    .min(i64::MAX as u64) as i64,
            );
            let unchanged = self
                .last_workspace_sent
                .get(&workspace_id)
                .is_some_and(|old| {
                    old.0 == cpu && old.1 == memory && now - old.2 < HEARTBEAT_SECONDS
                });
            if unchanged {
                continue;
            }
            if self.report_workspace(&workspace_id, &cpu, &memory)? {
                self.last_workspace_sent
                    .insert(workspace_id, (cpu, memory, now));
            }
        }
        Ok(global_cpu)
    }

    fn close(&mut self) {
        self.events.close();
        if let Some(control) = self.control.take() {
            drop(control);
        }
        let _ = remove_runtime_files(
            &self.server_dir,
            &control_path(&self.socket_path, &self.state_dir),
        );
        self.root_identities.clear();
        self.last_sent.clear();
        self.last_workspace_sent.clear();
        self.pane_workspaces.clear();
        self.workspaces.clear();
        // Keep the lock file alive until all worker cleanup is complete.
        let _ = self.lock.as_ref().map(AsRawFd::as_raw_fd);
    }

    fn run(&mut self) -> i32 {
        if let Err(error) = self.setup_control() {
            log_message(&format!("cannot set up pane-load control: {error}"));
            self.close();
            return 1;
        }
        if !self.reconnect_snapshot() {
            self.close();
            return 1;
        }
        let mut previous = None;
        let mut next_sample = 0.0;
        while !self.stop_requested && !STOP_REQUESTED.load(Ordering::Relaxed) {
            let mut now = monotonic_seconds();
            let mut buffered = false;
            if self.events.raw_fd().is_some() {
                match self.events.poll() {
                    Ok(events) if !events.is_empty() => {
                        buffered = true;
                        self.dirty = true;
                        self.next_snapshot = now + 0.2;
                    }
                    Ok(_) => {}
                    Err(_) => {
                        if !self.reconnect_snapshot() {
                            break;
                        }
                        previous = None;
                        continue;
                    }
                }
            }
            let (control_ready, event_ready) = self.wait_inputs(if buffered { 0 } else { 250 });
            if control_ready {
                self.handle_control();
            }
            if event_ready {
                match self.events.poll() {
                    Ok(events) if !events.is_empty() => {
                        self.dirty = true;
                        self.next_snapshot = now + 0.2;
                    }
                    Ok(_) => {}
                    Err(_) => {
                        if !self.reconnect_snapshot() {
                            break;
                        }
                        previous = None;
                        continue;
                    }
                }
            }
            if self.dirty && now >= self.next_snapshot {
                if self.snapshot().is_err() && !self.reconnect_snapshot() {
                    break;
                }
                if self.stop_requested {
                    break;
                }
            }
            // Snapshot RPCs and input waits may block; timestamp the native
            // sample after them, not at the start of the loop.
            now = monotonic_seconds();
            if now >= next_sample {
                match self.sample(now, previous) {
                    Ok(global_cpu) => {
                        previous = Some(now);
                        next_sample = now + sample_interval(global_cpu);
                    }
                    Err(AppError::ServerUnavailable(error)) => {
                        log_message(&format!("Herdr unavailable while reporting: {error}"));
                        if !self.reconnect_snapshot() {
                            break;
                        }
                        previous = None;
                        next_sample = monotonic_seconds() + SLOW_SAMPLE_SECONDS;
                    }
                    Err(error) => {
                        log_message(&format!("sampling failed: {error}"));
                        break;
                    }
                }
            }
            if now >= self.next_plugin_check {
                match self.plugin_enabled() {
                    Ok(true) => {}
                    Ok(false) => break,
                    Err(AppError::ServerUnavailable(_)) | Err(AppError::Herdr(_)) => {
                        if !self.reconnect_snapshot() {
                            break;
                        }
                        previous = None;
                    }
                    Err(_) => break,
                }
                self.next_plugin_check = now + PLUGIN_REFRESH_SECONDS;
            }
        }
        self.close();
        0
    }

    fn wait_inputs(&self, timeout_ms: i32) -> (bool, bool) {
        let control_fd = self.control.as_ref().map(AsRawFd::as_raw_fd);
        let event_fd = self.events.raw_fd();
        let mut fds = Vec::new();
        if let Some(fd) = control_fd {
            fds.push(libc::pollfd {
                fd,
                events: libc::POLLIN,
                revents: 0,
            });
        }
        if let Some(fd) = event_fd {
            fds.push(libc::pollfd {
                fd,
                events: libc::POLLIN,
                revents: 0,
            });
        }
        if fds.is_empty() {
            thread::sleep(Duration::from_millis(timeout_ms.max(0) as u64));
            return (false, false);
        }
        // SAFETY: fds points to a live, writable pollfd array for this call.
        let result = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout_ms) };
        if result <= 0 {
            return (false, false);
        }
        let mut index = 0;
        let control_ready = if control_fd.is_some() {
            let ready = fds[index].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0;
            index += 1;
            ready
        } else {
            false
        };
        let event_ready = event_fd.is_some()
            && fds[index].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0;
        (control_ready, event_ready)
    }
}

fn path_hash(socket_path: &str, state_dir: &Path) -> String {
    let input = format!("{}\0{}", state_dir.to_string_lossy(), socket_path);
    format!("{:x}", Sha256::digest(input.as_bytes()))
}

fn server_dir(socket_path: &str, state_dir: &Path) -> PathBuf {
    let hash = path_hash(socket_path, state_dir);
    state_dir.join("servers").join(&hash[..20])
}

fn control_path(socket_path: &str, state_dir: &Path) -> PathBuf {
    let uid = unsafe { libc::geteuid() };
    let hash = path_hash(socket_path, state_dir);
    PathBuf::from(format!("/tmp/herdr-pane-load-{uid}-{}.sock", &hash[..24]))
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn remove_runtime_files(directory: &Path, control: &Path) -> io::Result<()> {
    remove_if_present(&directory.join("status.json"))?;
    remove_if_present(control)
}

fn read_status(directory: &Path) -> Option<Value> {
    serde_json::from_slice(&fs::read(directory.join("status.json")).ok()?).ok()
}

fn status_is_ready(directory: &Path, control: &Path, pid: u32) -> bool {
    let Some(status) = read_status(directory) else {
        return false;
    };
    status.get("pid").and_then(Value::as_u64) == Some(u64::from(pid))
        && status.get("control").and_then(Value::as_str) == control.to_str()
        && control.exists()
}

fn wait_for_pid_exit(directory: &Path, pid: u32, timeout: Duration) -> bool {
    let deadline = Instant::now()
        .checked_add(timeout)
        .unwrap_or_else(Instant::now);
    loop {
        if read_status(directory)
            .and_then(|status| status.get("pid").and_then(Value::as_u64))
            .is_some_and(|current| current != u64::from(pid))
        {
            return true;
        }
        // SAFETY: signal zero only checks whether this process ID still exists.
        let alive = unsafe { libc::kill(pid as i32, 0) } == 0
            || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
        if !alive {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn write_status(directory: &Path, value: &Value) -> Result<(), AppError> {
    let path = directory.join("status.json");
    let temporary = directory.join("status.json.tmp");
    let mut file = File::create(&temporary).map_err(|error| AppError::Other(error.to_string()))?;
    serde_json::to_writer(&mut file, value).map_err(|error| AppError::Other(error.to_string()))?;
    file.write_all(b"\n")
        .map_err(|error| AppError::Other(error.to_string()))?;
    drop(file);
    fs::rename(temporary, path).map_err(|error| AppError::Other(error.to_string()))
}

fn unix_time() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |duration| duration.as_secs_f64())
}

static MONOTONIC_START: OnceLock<Instant> = OnceLock::new();
static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);

fn monotonic_seconds() -> f64 {
    MONOTONIC_START
        .get_or_init(Instant::now)
        .elapsed()
        .as_secs_f64()
}

extern "C" fn handle_sigterm(_: libc::c_int) {
    STOP_REQUESTED.store(true, Ordering::Relaxed);
}

#[allow(clippy::fn_to_numeric_cast)]
fn install_signal_handler() {
    // SAFETY: handler only stores an atomic flag and has a C ABI.
    unsafe {
        libc::signal(
            libc::SIGTERM,
            handle_sigterm as *const () as libc::sighandler_t,
        );
    }
}

fn open_lock(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC)
        .open(path)
}

#[allow(unreachable_patterns)]
fn try_flock(file: &File) -> io::Result<bool> {
    // SAFETY: file owns a valid lock-file descriptor.
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        Ok(true)
    } else if matches!(
        io::Error::last_os_error().raw_os_error(),
        Some(libc::EWOULDBLOCK) | Some(libc::EAGAIN)
    ) {
        Ok(false)
    } else {
        Err(io::Error::last_os_error())
    }
}

fn normalize_path(path: &Path) -> PathBuf {
    path.components()
        .filter(|component| !matches!(component, Component::CurDir))
        .collect()
}

fn wait_for_lock(file: &File, timeout: Duration) -> io::Result<bool> {
    let deadline = Instant::now()
        .checked_add(timeout)
        .unwrap_or_else(Instant::now);
    loop {
        if try_flock(file)? {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn passwd_home(user: Option<&str>) -> Option<PathBuf> {
    let entry = unsafe {
        match user {
            Some(user) => {
                let user = CString::new(user).ok()?;
                libc::getpwnam(user.as_ptr())
            }
            None => libc::getpwuid(libc::getuid()),
        }
    };
    if entry.is_null() {
        return None;
    }
    // SAFETY: entry was checked above and points to a passwd record.
    let directory = unsafe { (*entry).pw_dir };
    if directory.is_null() {
        return None;
    }
    // SAFETY: passwd entries keep pw_dir valid until the next passwd lookup;
    // copy it immediately before returning.
    let bytes = unsafe { CStr::from_ptr(directory) }.to_bytes();
    Some(PathBuf::from(OsStr::from_bytes(bytes)))
}

fn expand_state_path(value: &str) -> PathBuf {
    let expanded = if let Some(value) = value.strip_prefix('~') {
        let (user, rest) = value.split_once('/').unwrap_or((value, ""));
        let home = if user.is_empty() {
            env::var_os("HOME")
                .map(|home| {
                    if home.is_empty() {
                        PathBuf::from("/")
                    } else {
                        PathBuf::from(home)
                    }
                })
                .or_else(|| passwd_home(None))
        } else {
            passwd_home(Some(user))
        };
        home.map_or_else(
            || PathBuf::from(format!("~{value}")),
            |home| home.join(rest),
        )
    } else {
        PathBuf::from(value)
    };
    normalize_path(&expanded)
}

fn env_paths() -> Result<(String, PathBuf), AppError> {
    let socket = env::var("HERDR_SOCKET_PATH")
        .map_err(|_| AppError::Other("HERDR_SOCKET_PATH is required".into()))?;
    let state = expand_state_path(
        &env::var("HERDR_PLUGIN_STATE_DIR")
            .unwrap_or_else(|_| "~/.config/herdr/plugins/local.pane-load/state".into()),
    );
    fs::create_dir_all(&state).map_err(|error| AppError::Other(error.to_string()))?;
    Ok((socket, state))
}

fn start() -> i32 {
    if !cfg!(target_os = "macos") {
        log_message("local.pane-load supports macOS only");
        return 1;
    }
    let (socket_path, state_dir) = match env_paths() {
        Ok(paths) => paths,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    let directory = server_dir(&socket_path, &state_dir);
    if let Err(error) = fs::create_dir_all(&directory) {
        log_message(&error.to_string());
        return 1;
    }
    let lock_path = directory.join("sampler.lock");
    let lock = match open_lock(&lock_path) {
        Ok(lock) => lock,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    match try_flock(&lock) {
        Ok(true) => {}
        Ok(false) => match wait_for_lock(&lock, Duration::from_secs(1)) {
            Ok(true) => {}
            Ok(false) => return 0,
            Err(error) => {
                log_message(&error.to_string());
                return 1;
            }
        },
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    }
    let control = control_path(&socket_path, &state_dir);
    if let Err(error) = remove_runtime_files(&directory, &control) {
        log_message(&error.to_string());
        return 1;
    }
    if let Err(error) = set_fd_cloexec(lock.as_raw_fd(), false) {
        log_message(&error.to_string());
        return 1;
    }
    let log_path = directory.join("sampler.log");
    let log_file = match OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(log_path)
    {
        Ok(file) => file,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    let stdout = match log_file.try_clone() {
        Ok(file) => file,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    let executable = match env::current_exe() {
        Ok(path) => path,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    let child = unsafe {
        use std::os::unix::process::CommandExt;
        Command::new(executable)
            .arg("worker")
            .arg("--lock-fd")
            .arg(lock.as_raw_fd().to_string())
            .stdin(Stdio::null())
            .stdout(stdout)
            .stderr(log_file)
            .pre_exec(|| {
                if libc::setsid() < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(())
                }
            })
            .spawn()
    };
    match child {
        Ok(mut child) => {
            let ready = (0..100).any(|_| {
                if status_is_ready(&directory, &control, child.id()) {
                    true
                } else {
                    thread::sleep(Duration::from_millis(20));
                    false
                }
            });
            if !ready {
                // SAFETY: child.id() names the worker process just spawned here.
                unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
                let _ = child.wait();
                let _ = remove_runtime_files(&directory, &control);
                drop(lock);
                log_message("pane-load worker failed to become ready");
                return 1;
            }
            drop(lock);
            log_message(&format!("started pane-load worker {}", child.id()));
            0
        }
        Err(error) => {
            log_message(&error.to_string());
            1
        }
    }
}

fn stop() -> i32 {
    let (socket_path, state_dir) = match env_paths() {
        Ok(paths) => paths,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    let directory = server_dir(&socket_path, &state_dir);
    if let Err(error) = fs::create_dir_all(&directory) {
        log_message(&error.to_string());
        return 1;
    }
    let lock = match open_lock(&directory.join("sampler.lock")) {
        Ok(lock) => lock,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    match try_flock(&lock) {
        Ok(true) => {
            match remove_runtime_files(&directory, &control_path(&socket_path, &state_dir)) {
                Ok(()) => 0,
                Err(error) => {
                    log_message(&error.to_string());
                    1
                }
            }
        }
        Ok(false) => {
            let path = control_path(&socket_path, &state_dir);
            let stopped_pid = read_status(&directory)
                .and_then(|status| status.get("pid").and_then(Value::as_u64))
                .and_then(|pid| u32::try_from(pid).ok());
            for _ in 0..3 {
                match connect_unix(path.to_string_lossy().as_ref(), CONTROL_TIMEOUT) {
                    Ok(mut conn) => {
                        let _ = conn.set_read_timeout(Some(CONTROL_TIMEOUT));
                        let _ = conn.set_write_timeout(Some(CONTROL_TIMEOUT));
                        if conn.write_all(b"stop\n").is_err() {
                            continue;
                        }
                        let mut response = [0_u8; 16];
                        if conn.read(&mut response).is_err() {
                            continue;
                        }
                        return if stopped_pid.is_none_or(|pid| {
                            wait_for_pid_exit(&directory, pid, Duration::from_secs(5))
                        }) {
                            0
                        } else {
                            log_message("pane-load worker did not stop before timeout");
                            1
                        };
                    }
                    Err(_) => thread::sleep(Duration::from_millis(100)),
                }
            }
            log_message("pane-load worker is running but its control socket is unavailable");
            1
        }
        Err(error) => {
            log_message(&error.to_string());
            1
        }
    }
}

fn inherited_lock(fd: RawFd) -> io::Result<File> {
    if fd < 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid lock fd",
        ));
    }
    // SAFETY: F_GETFD only validates the inherited descriptor.
    if unsafe { libc::fcntl(fd, libc::F_GETFD) } < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the descriptor was supplied by the parent and is now owned here.
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn worker(lock_fd: RawFd) -> i32 {
    let lock = match inherited_lock(lock_fd) {
        Ok(lock) => lock,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    let (socket_path, state_dir) = match env_paths() {
        Ok(paths) => paths,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    let directory = server_dir(&socket_path, &state_dir);
    if let Err(error) = fs::create_dir_all(&directory) {
        log_message(&error.to_string());
        return 1;
    }
    install_signal_handler();
    let mut worker = match Worker::new(socket_path, state_dir, lock) {
        Ok(worker) => worker,
        Err(error) => {
            log_message(&error.to_string());
            return 1;
        }
    };
    worker.run()
}

fn log_message(message: &str) {
    eprintln!("{message}");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let status = match args.get(1).map(String::as_str) {
        Some("start") if args.len() == 2 => start(),
        Some("stop") if args.len() == 2 => stop(),
        Some("worker") if args.len() == 4 && args[2] == "--lock-fd" => {
            match args[3].parse::<RawFd>() {
                Ok(fd) if fd >= 0 => worker(fd),
                _ => {
                    eprintln!("worker requires a valid --lock-fd");
                    1
                }
            }
        }
        Some("format-title") if args.len() == 5 => match args[2].parse::<f64>() {
            Ok(cpu) => {
                println!("{}", pane_title(cpu, &args[3], &args[4]));
                0
            }
            Err(_) => 1,
        },
        _ => {
            eprintln!(
                "usage: pane-load <start|stop|worker --lock-fd N|format-title CPU MEMORY TREE>"
            );
            1
        }
    };
    if status != 0 {
        std::process::exit(status);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

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

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).into()).collect()
    }

    #[test]
    fn benchmark_options_have_short_safe_defaults() {
        let options = parse_benchmark_options(&[], 42).unwrap();
        assert_eq!(options.duration, Duration::from_secs(5));
        assert_eq!(options.sid, 42);
        assert_eq!(options.discovery_interval, Duration::from_secs(1));
        assert_eq!(options.sample_interval, Duration::from_millis(500));
    }

    #[test]
    fn benchmark_options_parse_intervals_and_sid() {
        let options = parse_benchmark_options(
            &strings(&[
                "--duration",
                "2.5",
                "--sid",
                "123",
                "--discovery-ms",
                "750",
                "--sample-ms",
                "100",
            ]),
            42,
        )
        .unwrap();
        assert_eq!(options.duration, Duration::from_millis(2500));
        assert_eq!(options.sid, 123);
        assert_eq!(options.discovery_interval, Duration::from_millis(750));
        assert_eq!(options.sample_interval, Duration::from_millis(100));
    }

    #[test]
    fn benchmark_options_reject_zero_and_unknown_values() {
        assert!(parse_benchmark_options(&strings(&["--duration", "0"]), 42).is_err());
        assert!(parse_benchmark_options(&strings(&["--sample-ms", "0"]), 42).is_err());
        assert!(parse_benchmark_options(&strings(&["--wat"]), 42).is_err());
    }

    #[test]
    fn cpu_delta_is_wall_based_and_pid_reuse_safe() {
        let mut tracker = CpuTracker::default();
        let first = process(10, 1, 1, "zsh", 0);
        assert_eq!(
            tracker.values(std::slice::from_ref(&first), 10.0, None)[&first.identity()],
            0.0
        );

        let mut second = first.clone();
        second.system_ns = 2_000_000_000;
        assert_eq!(
            tracker.values(std::slice::from_ref(&second), 12.0, Some(10.0))[&second.identity()],
            100.0
        );

        let mut reused = process(10, 1, 99, "new-exec", 0);
        reused.system_ns = 99_000_000_000;
        assert_eq!(
            tracker.values(std::slice::from_ref(&reused), 13.0, Some(12.0))[&reused.identity()],
            0.0
        );
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

    #[test]
    fn names_refresh_and_exits_are_benign() {
        let processes = vec![
            process(10, 1, 1, "zsh", 0),
            process(11, 10, 2, "python-long-name", 0),
            process(12, 10, 3, "sleep", 0),
        ];
        let mut tracker = CpuTracker::default();
        tracker.values(&processes, 1.0, None);
        let current = vec![process(10, 1, 1, "new-shell", 0), processes[1].clone()];
        let values = tracker.values(&current, 2.0, Some(1.0));
        assert!(values.contains_key(&current[0].identity()));
        assert!(!values.contains_key(&processes[2].identity()));
        assert_eq!(current[0].name, "new-shell");
    }

    #[test]
    fn process_tree_prefers_command_and_keeps_nested_edges() {
        let processes = vec![
            process(10, 1, 1, "zsh", 0),
            process(11, 10, 2, "python-long-name", 0),
            process(12, 10, 3, "sleep", 0),
            process(13, 11, 4, "nested", 0),
        ];
        let cpus = HashMap::from([
            (processes[0].identity(), 0.0),
            (processes[1].identity(), 10.0),
            (processes[2].identity(), 0.0),
            (processes[3].identity(), 10.0),
        ]);
        let names = HashMap::from([(processes[1].identity(), "pi".into())]);
        let (cpu, tree) = token_payload(10, &processes, &cpus, &names);
        assert_eq!(cpu, "20");
        assert!(tree.contains("pi") && !tree.contains("python-long-name"));
        assert!(tree.contains("nested") && tree.contains('('));
    }

    #[test]
    fn term_capture_and_procargs_names_match_native_contract() {
        let capture = process(20, 1, 1, "term-capture", 0);
        let node = process(21, 20, 2, "node", 0);
        assert_eq!(process_display_name(&capture, Some("pi")), "tcap");
        assert_eq!(process_display_name(&node, Some("pi")), "pi");
        assert_eq!(process_display_name(&node, None), "node");
        let login = {
            let mut data = 1_i32.to_ne_bytes().to_vec();
            data.extend_from_slice(b"/bin/zsh\0\0-zsh\0");
            data
        };
        assert_eq!(command_from_procargs(&login).as_deref(), Some("zsh"));
    }

    #[test]
    fn memory_selects_main_and_optional_branches() {
        let mib = 1024 * 1024;
        let root = process(20, 1, 1, "root", 0);
        let cpu_child = process(21, 20, 2, "cpu", 4 * mib);
        let memory_child = process(22, 20, 3, "memory", 96 * mib);
        let cpus = HashMap::from([
            (root.identity(), 96.0),
            (cpu_child.identity(), 4.0),
            (memory_child.identity(), 0.0),
        ]);
        let (_, tree) = token_payload(
            20,
            &[root.clone(), cpu_child, memory_child],
            &cpus,
            &HashMap::new(),
        );
        assert!(tree.contains("memory:") && !tree.contains("cpu:"));
        let hot_memory = process(23, 20, 4, "hot-memory", 10 * mib);
        let main_cpu = process(24, 20, 5, "main-cpu", 90 * mib);
        let cpus = HashMap::from([
            (root.identity(), 0.0),
            (hot_memory.identity(), 0.0),
            (main_cpu.identity(), 100.0),
        ]);
        let (_, tree) = token_payload(20, &[root, hot_memory, main_cpu], &cpus, &HashMap::new());
        assert!(tree.contains("hot-memory:⣧") && tree.contains("main-cpu:"));
    }

    #[test]
    fn bars_cover_fractional_values_and_reject_bad_layouts() {
        for (percent, expected) in [
            (1.0, "⡀"),
            (3.0, "⡄"),
            (4.0, "⡆"),
            (6.0, "⡇"),
            (8.0, "⣇"),
            (9.0, "⣧"),
            (11.0, "⣷"),
            (12.0, "⣿"),
        ] {
            assert_eq!(memory_share_bar(percent, 100.0), expected);
        }
        assert_eq!(cpu_meter(0.0), "0%");
        assert_eq!(cpu_meter(51.0), "51% █▉█▉▏");
        assert_eq!(workspace_cpu_meter(100.0), "100% ██");
        assert_eq!(workspace_cpu_meter(101.0), "101% █▉▏");
        assert_eq!(workspace_cpu_meter(238.0), "238% █▉█▉▊");
        assert_eq!(scaled_cpu_bar(238.0, 5, false, 5), "████▋████▋█▉");
        assert_eq!(scaled_cpu_bar(238.0, 7, false, 5), "██████▋██████▋██▋");
        assert!(std::panic::catch_unwind(|| scaled_cpu_bar(50.0, 0, false, 5)).is_err());
        assert!(std::panic::catch_unwind(|| scaled_cpu_bar(50.0, 5, true, 5)).is_err());
        assert!(std::panic::catch_unwind(|| scaled_cpu_bar(50.0, 8, false, 8)).is_err());
    }

    #[test]
    fn tree_is_unbounded_and_names_are_delimiter_safe() {
        let processes: Vec<_> = (1..60)
            .map(|pid| {
                process(
                    pid,
                    pid - 1,
                    pid as u64,
                    "very-long-process-name",
                    1536 * 1024 * 1024,
                )
            })
            .collect();
        let cpus: HashMap<_, _> = processes.iter().map(|p| (p.identity(), 5.0)).collect();
        let (_, tree) = token_payload(1, &processes, &cpus, &HashMap::new());
        assert!(
            tree.len() > 80 && !tree.contains("...") && tree.starts_with("very-long-process-name")
        );
        assert_eq!(safe_name("bad():, name"), "bad_____name");
    }

    #[test]
    fn sub_one_percent_cpu_still_selects_a_hot_branch_and_cycles_terminate() {
        let root = process(20, 1, 1, "root", 0);
        let idle = process(21, 20, 2, "idle", 0);
        let busy = process(22, 20, 3, "busy", 0);
        let cpus = HashMap::from([
            (root.identity(), 0.0),
            (idle.identity(), 0.0),
            (busy.identity(), 0.4),
        ]);
        let (cpu, tree) = token_payload(20, &[root, idle, busy], &cpus, &HashMap::new());
        assert_eq!(cpu, "0");
        assert_eq!(tree, "root(busy:█▉█▉█▉██)");
        let first = process(1, 2, 1, "first", 0);
        let second = process(2, 1, 2, "cycle-back", 0);
        let sibling = process(3, 1, 3, "sibling", 0);
        let cycle_cpus = HashMap::from([
            (first.identity(), 10.0),
            (second.identity(), 0.4),
            (sibling.identity(), 2.6),
        ]);
        let (total, tree) =
            process_tree(1, &[first, second, sibling], &cycle_cpus, &HashMap::new());
        assert_eq!(total, 13.0);
        assert_eq!(tree.matches("first").count(), 1);
        assert!(tree.contains("sibling") && !tree.contains("cycle-back"));
    }

    struct SharedApi {
        calls: Arc<Mutex<Vec<(String, Value)>>>,
        responses: VecDeque<Result<Value, AppError>>,
    }

    impl Api for SharedApi {
        fn call(&mut self, method: &str, params: Value) -> Result<Value, AppError> {
            self.calls.lock().unwrap().push((method.into(), params));
            self.responses.pop_front().unwrap_or_else(|| Ok(json!({})))
        }
    }

    struct TestSampler {
        processes: Vec<Process>,
        commands: HashMap<i32, Option<String>>,
    }

    impl ProcessSampler for TestSampler {
        fn enumerate(&mut self) -> Vec<Process> {
            self.processes.clone()
        }

        fn command(&mut self, pid: i32) -> Option<String> {
            self.commands.get(&pid).cloned().flatten()
        }
    }

    struct TestEvents {
        calls: Arc<Mutex<Vec<&'static str>>>,
        connected: bool,
    }

    impl EventSource for TestEvents {
        fn connect(&mut self) -> Result<(), AppError> {
            self.calls.lock().unwrap().push("subscribe");
            self.connected = true;
            Ok(())
        }
        fn poll(&mut self) -> Result<Vec<Value>, AppError> {
            self.calls.lock().unwrap().push("poll");
            Ok(Vec::new())
        }
        fn close(&mut self) {
            self.connected = false;
        }
        fn raw_fd(&self) -> Option<RawFd> {
            None
        }
    }

    #[allow(clippy::type_complexity)]
    fn test_worker_with_responses(
        processes: Vec<Process>,
        responses: Vec<Result<Value, AppError>>,
    ) -> (
        Worker,
        Arc<Mutex<Vec<(String, Value)>>>,
        Arc<Mutex<Vec<&'static str>>>,
    ) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let sampler = TestSampler {
            processes,
            commands: HashMap::new(),
        };
        let event_calls = Arc::new(Mutex::new(Vec::new()));
        let events = TestEvents {
            calls: event_calls.clone(),
            connected: false,
        };
        let worker = Worker::with_components(
            "/tmp/herdr-test.sock".into(),
            env::temp_dir(),
            None,
            Box::new(SharedApi {
                calls: calls.clone(),
                responses: responses.into_iter().collect(),
            }),
            Box::new(events),
            Box::new(sampler),
        );
        (worker, calls, event_calls)
    }

    #[allow(clippy::type_complexity)]
    fn test_worker(processes: Vec<Process>) -> (Worker, Arc<Mutex<Vec<(String, Value)>>>) {
        let (worker, calls, _) = test_worker_with_responses(processes, Vec::new());
        (worker, calls)
    }

    #[test]
    fn sampling_suppresses_unchanged_reports_until_heartbeat() {
        let root = process(10, 1, 1, "zsh", 0);
        let (mut worker, calls) = test_worker(vec![root.clone()]);
        worker.roots.insert("pane".into(), 10);
        worker.sample(100.0, None).unwrap();
        worker.sample(101.0, Some(100.0)).unwrap();
        worker.sample(104.999, Some(103.999)).unwrap();
        worker.sample(105.0, Some(104.0)).unwrap();
        let reports = calls
            .lock()
            .unwrap()
            .iter()
            .filter(|(method, _)| method == "pane.report_metadata")
            .count();
        assert_eq!(reports, 2);
    }

    #[test]
    fn ownership_partitions_nested_roots_and_pid_reuse_is_rejected() {
        let outer = process(100, 1, 1, "outer", 0);
        let inner = process(101, 100, 2, "inner", 0);
        let leaf = process(102, 101, 3, "leaf", 0);
        let index = build_process_index([outer.clone(), inner.clone(), leaf.clone()]);
        let (owners, owned) = assign_process_owners(
            &index,
            &HashMap::from([("outer-pane".into(), 100), ("inner-pane".into(), 101)]),
        );
        assert_eq!(owners[&outer.identity()], "outer-pane");
        assert_eq!(owners[&inner.identity()], "inner-pane");
        assert_eq!(owners[&leaf.identity()], "inner-pane");
        assert_eq!(owned["outer-pane"].len(), 1);
        assert_eq!(owned["inner-pane"].len(), 2);
        let old = process(42, 1, 10, "old-shell", 0);
        let reused = process(42, 1, 20, "new-shell", 0);
        let (mut worker, calls) = test_worker(vec![reused]);
        worker.roots.insert("pane".into(), 42);
        worker.root_identities.insert("pane".into(), old.identity());
        worker.sample(100.0, None).unwrap();
        assert!(calls.lock().unwrap().is_empty());
    }

    #[test]
    fn workspace_tokens_have_exclusive_heat_ranges() {
        for (cpu, expected) in [
            (0, "cpu_idle"),
            (1, "cpu_cool"),
            (24, "cpu_cool"),
            (25, "cpu_active"),
            (99, "cpu_active"),
            (100, "cpu_warm"),
            (199, "cpu_warm"),
            (200, "cpu_hot"),
            (399, "cpu_hot"),
            (400, "cpu_very_hot"),
        ] {
            let tokens = workspace_cpu_tokens(cpu as f64);
            assert!(tokens[expected].is_string());
            for name in [
                "cpu_idle",
                "cpu_cool",
                "cpu_active",
                "cpu_warm",
                "cpu_hot",
                "cpu_very_hot",
            ] {
                if name != expected {
                    assert!(tokens[name].is_null());
                }
            }
        }
    }

    #[test]
    fn report_shapes_own_title_and_workspace_metadata() {
        let (mut worker, calls) = test_worker(Vec::new());
        assert!(worker.report("w1:p1", "25", "zsh", "640MB").unwrap());
        assert!(worker.report_workspace("w1", "125", "1.5GB").unwrap());
        let calls = calls.lock().unwrap();
        let pane = &calls[0].1;
        assert_eq!(pane["ttl_ms"], json!(15_000));
        assert_eq!(
            pane["tokens"],
            json!({"cpu":"25", "cpu_tree":"zsh", "memory":"640MB"})
        );
        assert_eq!(pane["title"], json!("25% ██ 640MB zsh"));
        assert_eq!(calls[1].0, "workspace.report_metadata");
        assert_eq!(calls[1].1["tokens"]["cpu"], json!("125% █▉▌"));
        assert_eq!(calls[1].1["tokens"]["memory"], json!("1.5GB"));
    }

    #[test]
    fn stable_paths_are_short_and_deterministic() {
        let state = Path::new("/tmp/a/state");
        let first = path_hash("/tmp/herdr.sock", state);
        assert_eq!(first, path_hash("/tmp/herdr.sock", state));
        assert_eq!(
            first,
            "03555bbd2ce0a15c967821a12b3455b022aa6d7b0efb413e0cce7ea7828f2952"
        );
        assert!(server_dir("/tmp/herdr.sock", state).ends_with("03555bbd2ce0a15c9678"));
        assert_eq!(expand_state_path("/tmp/a/./state/"), state);
        if let Some(home) = env::var_os("HOME") {
            let home = if home.is_empty() {
                PathBuf::from("/")
            } else {
                PathBuf::from(home)
            };
            assert_eq!(expand_state_path("~"), home);
        }
        if let Ok(user) = env::var("USER")
            && let Some(home) = passwd_home(Some(&user))
        {
            assert_eq!(
                expand_state_path(&format!("~{user}/./pane-load/")),
                home.join("pane-load")
            );
        }
        assert!(
            control_path("/tmp/herdr.sock", state)
                .to_string_lossy()
                .ends_with(".sock")
        );
    }

    #[test]
    fn rpc_connections_are_short_lived_and_events_are_persistent() {
        let socket_path = env::temp_dir().join(format!(
            "pane-load-test-{}-{}.sock",
            std::process::id(),
            &path_hash(&format!("{:?}", Instant::now()), Path::new("/tmp"))[..16]
        ));
        let listener = UnixListener::bind(&socket_path).unwrap();
        let methods = Arc::new(Mutex::new(Vec::new()));
        let seen_methods = methods.clone();
        let server = thread::spawn(move || {
            for _ in 0..3 {
                let (mut conn, _) = listener.accept().unwrap();
                let mut line = Vec::new();
                let mut byte = [0_u8; 1];
                while conn.read(&mut byte).unwrap_or(0) == 1 {
                    line.push(byte[0]);
                    if byte[0] == b'\n' {
                        break;
                    }
                }
                if line.is_empty() {
                    continue;
                }
                let request: Value = serde_json::from_slice(&line).unwrap();
                let method = request["method"].as_str().unwrap().to_string();
                seen_methods.lock().unwrap().push(method.clone());
                if method == "events.subscribe" {
                    conn.write_all(b"{\"id\":\"pane-load-events\",\"result\":{\"type\":\"subscription_started\"}}\n{\"event\":\"pane.created\",\"data\":{}}\n").unwrap();
                } else if method == "pane.report_metadata" {
                    conn.write_all(b"{\"result\":{\"ok\":true}}\n").unwrap();
                } else {
                    conn.write_all(b"{\"result\":{\"type\":\"session_snapshot\"}}\n")
                        .unwrap();
                }
            }
        });
        let mut rpc = RPCClient::new(socket_path.to_string_lossy().into_owned());
        assert_eq!(
            rpc.call("session.snapshot", json!({})).unwrap()["type"],
            "session_snapshot"
        );
        assert!(
            rpc.call("pane.report_metadata", json!({"pane_id":"p1"}))
                .unwrap()["ok"]
                .as_bool()
                .unwrap()
        );
        let mut events = EventStream::new(socket_path.to_string_lossy().into_owned());
        events.connect().unwrap();
        assert_eq!(events.poll().unwrap()[0]["event"], "pane.created");
        assert!(events.sock.is_some());
        events.close();
        server.join().unwrap();
        assert_eq!(
            *methods.lock().unwrap(),
            vec![
                "session.snapshot",
                "pane.report_metadata",
                "events.subscribe"
            ]
        );
        let _ = fs::remove_file(socket_path);
    }

    #[test]
    fn failed_report_is_not_cached_for_the_next_sample() {
        let root = process(10, 1, 1, "zsh", 0);
        let (mut worker, calls, _) = test_worker_with_responses(
            vec![root.clone()],
            vec![Err(AppError::Herdr("rejected".into())), Ok(json!({}))],
        );
        worker.roots.insert("pane".into(), root.pid);
        worker.sample(100.0, None).unwrap();
        assert!(!worker.last_sent.contains_key("pane"));
        worker.sample(101.0, Some(100.0)).unwrap();
        assert_eq!(
            calls
                .lock()
                .unwrap()
                .iter()
                .filter(|(method, _)| method == "pane.report_metadata")
                .count(),
            2
        );
    }

    #[test]
    fn workspace_aggregation_excludes_unowned_processes() {
        let mut first = process(20, 1, 1, "first", 512 * 1024 * 1024);
        let mut second = process(30, 1, 1, "second", 1024 * 1024 * 1024);
        let mut unrelated = process(40, 1, 1, "unrelated", 2048 * 1024 * 1024);
        first.user_ns = 254_000_000;
        second.user_ns = 752_000_000;
        unrelated.user_ns = 9_000_000_000;
        let (mut worker, calls) = test_worker(vec![first, second, unrelated]);
        worker.roots = HashMap::from([(String::from("p1"), 20), (String::from("p2"), 30)]);
        worker.pane_workspaces = HashMap::from([
            (String::from("p1"), String::from("w1")),
            (String::from("p2"), String::from("w1")),
        ]);
        worker.workspaces = HashSet::from([String::from("w1"), String::from("w2")]);
        worker.tracker.previous = worker
            .sampler
            .enumerate()
            .into_iter()
            .map(|process| (process.identity(), (0, 0)))
            .collect();
        worker.sample(100.0, Some(99.0)).unwrap();
        let calls = calls.lock().unwrap();
        let workspace = calls
            .iter()
            .find(|(method, _)| method == "workspace.report_metadata")
            .map(|(_, params)| params)
            .unwrap();
        assert_eq!(workspace["workspace_id"], "w1");
        assert_eq!(workspace["tokens"]["memory"], "1.5GB");
        assert_eq!(workspace["tokens"]["cpu"], "101% █▉▏");
    }

    #[test]
    fn snapshot_tracks_workspace_membership_and_roots() {
        let (mut worker, _, _) = test_worker_with_responses(
            Vec::new(),
            vec![
                Ok(
                    json!({"snapshot":{"workspaces":[{"workspace_id":"w1"}],"panes":[{"pane_id":"p1","workspace_id":"w1"}]}}),
                ),
                Ok(json!({"process_info":{"shell_pid":42}})),
            ],
        );
        worker.snapshot().unwrap();
        assert_eq!(worker.workspaces, HashSet::from([String::from("w1")]));
        assert_eq!(worker.pane_workspaces["p1"], "w1");
        assert_eq!(worker.roots["p1"], 42);
    }

    #[test]
    fn event_buffer_is_bounded_and_connect_failure_cleans_up() {
        let mut events = EventStream::new("/no/such/socket".into());
        events.buffer.extend_from_slice(b"stale");
        assert!(events.connect().is_err());
        assert!(events.sock.is_none());
        assert!(events.buffer.is_empty());
        let (peer, server) = UnixStream::pair().unwrap();
        peer.set_nonblocking(true).unwrap();
        events.sock = Some(peer);
        events.buffer = b"{\"event\":\"pane.closed\"}\n".to_vec();
        assert_eq!(events.poll().unwrap().len(), 1);
        events.buffer.resize(MAX_LINE_BUFFER, b'x');
        assert!(events.poll().is_err());
        drop(server);
    }

    #[test]
    fn reconnect_subscribes_before_snapshot_and_disabled_plugin_is_false() {
        let (mut worker, _, event_calls) = test_worker_with_responses(
            Vec::new(),
            vec![Ok(json!({"snapshot":{"workspaces":[],"panes":[]}}))],
        );
        assert!(worker.reconnect_snapshot());
        assert_eq!(*event_calls.lock().unwrap(), vec!["subscribe", "poll"]);
        let (mut worker, _, _) = test_worker_with_responses(
            Vec::new(),
            vec![Ok(
                json!({"plugins":[{"plugin_id":PLUGIN_ID,"enabled":false}]}),
            )],
        );
        assert!(!worker.plugin_enabled().unwrap());
    }

    #[test]
    fn control_stop_sets_flag_and_removes_socket() {
        let (mut worker, _) = test_worker(Vec::new());
        worker.setup_control().unwrap();
        let path = control_path(&worker.socket_path, &worker.state_dir);
        let mut client = UnixStream::connect(&path).unwrap();
        client.write_all(b"stop\n").unwrap();
        worker.handle_control();
        let mut response = [0_u8; 3];
        client.read_exact(&mut response).unwrap();
        assert_eq!(&response, b"ok\n");
        assert!(worker.stop_requested);
        worker.close();
        assert!(!path.exists());
    }

    #[test]
    fn lock_and_status_helpers_distinguish_live_and_stale_state() {
        let directory = env::temp_dir().join(format!("pane-load-lock-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("lock");
        let first = open_lock(&path).unwrap();
        let second = open_lock(&path).unwrap();
        assert!(try_flock(&first).unwrap());
        assert!(!try_flock(&second).unwrap());
        let releaser = thread::spawn(move || {
            thread::sleep(Duration::from_millis(40));
            drop(first);
        });
        assert!(wait_for_lock(&second, Duration::from_secs(1)).unwrap());
        releaser.join().unwrap();
        let control = directory.join("control.sock");
        write_status(&directory, &json!({"pid":7,"control":control})).unwrap();
        assert!(!status_is_ready(&directory, &control, 7));
        drop(second);
        let _ = fs::remove_dir_all(directory);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_libproc_abi_and_busy_self_counter() {
        assert_eq!(std::mem::size_of::<ProcBsdInfo>(), 136);
        assert_eq!(std::mem::size_of::<ProcTaskInfo>(), 96);
        let mut sampler = MacProcessSampler::new().unwrap();
        assert!(sampler.command(std::process::id() as i32).is_some());
        let before = sampler
            .enumerate()
            .into_iter()
            .find(|process| process.pid == std::process::id() as i32)
            .unwrap();
        let started = Instant::now();
        while started.elapsed() < Duration::from_millis(50) {
            std::hint::spin_loop();
        }
        let after = sampler
            .enumerate()
            .into_iter()
            .find(|process| process.pid == std::process::id() as i32)
            .unwrap();
        assert_eq!(before.identity(), after.identity());
        let delta = after.user_ns + after.system_ns - before.user_ns - before.system_ns;
        assert!(delta > 40_000_000 && delta < 500_000_000);
        assert!(after.resident_bytes > 0);
    }
}
