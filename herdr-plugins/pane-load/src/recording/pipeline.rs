//! Shared validated streaming pipeline for live observations and imported JSONL sources.
use super::model::{
    Context, Identity, LiveMessage, MAX_BLOCK_BYTES, MAX_POINTS, MemoryColumn, MemoryEncoding,
    Observation, OutputFormat, Process, Profile, RecordOptions, Result, Timebase,
};
use super::ownership;
use super::source::{self, RawWriter};
use super::store::{ArchiveWriter, CodecFrameAccumulator, StoreOptions};
use super::wire::encode_block_with_memory;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

const DEFAULT_BLOCK_ROWS: usize = 300;
const DEFAULT_FRAME_BYTES: usize = 16 * 1024 * 1024;
const DEFAULT_MAX_BYTES: u64 = 8 * 1024 * 1024 * 1024;
const DEFAULT_MIN_FREE_BYTES: u64 = 20 * 1024 * 1024 * 1024;
const MAX_LIVE_IDENTITIES: usize = 100_000;
const LIVE_STATE_GRACE_NS: u64 = 30_000_000_000;
const MAX_BLOCK_AGE_NS: u64 = 30_000_000_000;
const MAX_FRAME_AGE_NS: u64 = 3_600_000_000_000;
static STATUS_TEMP_ID: AtomicU64 = AtomicU64::new(0);

#[path = "pipeline_bulk.rs"]
mod bulk;

#[derive(Clone, Debug, Default, Serialize)]
pub struct RunStats {
    /// Provided source was orderly and completely verified; partial imports print false.
    pub complete: bool,
    pub scans: u64,
    pub readings: u64,
    pub blocks: u64,
    pub flagged_events: u64,
    pub raw_encoded_bytes: u64,
    #[serde(default)]
    pub codec_input_bytes: u64,
    #[serde(default)]
    pub codec_compressed_bytes: u64,
    #[serde(default)]
    pub codec_encoder_cpu_seconds: f64,
    #[serde(default)]
    pub codec_encoder_wall_seconds: f64,
    #[serde(default)]
    pub codec_frames: u64,
    #[serde(default)]
    pub codec_repeats: u64,
    #[serde(default)]
    pub codec_max_input_bytes: u64,
    pub wall_seconds: f64,
    pub own_cpu_seconds: f64,
    pub child_cpu_seconds: f64,
    pub peak_rss_bytes: u64,
    pub endpoint_mismatches: u64,
    pub positive_intervals_lost: u64,
    pub precision_violations: u64,
    pub rss_floor_violations: u64,
    #[serde(default)]
    pub source_hashes: Vec<SourceHashStats>,
    #[serde(default)]
    pub recovery: Vec<String>,
    #[serde(default)]
    pub end_quality: Vec<Value>,
    #[serde(default)]
    pub end_reason: Option<String>,
    #[serde(default)]
    pub verification_enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bulk_workers: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoding_workers: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_passes: Option<u8>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SourceHashStats {
    pub path: String,
    pub scans: u64,
    pub readings: u64,
    pub input_bytes: u64,
    pub expanded_bytes: u64,
    pub expanded_sha256: String,
    pub first_seq: Option<u64>,
    pub last_seq: Option<u64>,
    pub first_scan_start_ns: Option<u64>,
    pub last_scan_start_ns: Option<u64>,
}

#[derive(Clone, Copy)]
struct Usage {
    user: f64,
    child: f64,
    peak: u64,
}

fn usage() -> Usage {
    let mut own = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    let mut children = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    let own_ok = unsafe { libc::getrusage(libc::RUSAGE_SELF, own.as_mut_ptr()) } == 0;
    let child_ok = unsafe { libc::getrusage(libc::RUSAGE_CHILDREN, children.as_mut_ptr()) } == 0;
    let own = if own_ok {
        unsafe { own.assume_init() }
    } else {
        unsafe { std::mem::zeroed() }
    };
    let children = if child_ok {
        unsafe { children.assume_init() }
    } else {
        unsafe { std::mem::zeroed() }
    };
    let seconds = |time: libc::timeval| time.tv_sec as f64 + time.tv_usec as f64 / 1_000_000.0;
    #[cfg(target_os = "macos")]
    let peak = own.ru_maxrss.max(0) as u64;
    #[cfg(not(target_os = "macos"))]
    let peak = (own.ru_maxrss.max(0) as u64).saturating_mul(1024);
    Usage {
        user: seconds(own.ru_utime) + seconds(own.ru_stime),
        child: seconds(children.ru_utime) + seconds(children.ru_stime),
        peak,
    }
}

fn finish_metrics(stats: &mut RunStats, start: Instant, before: Usage) {
    let after = usage();
    stats.wall_seconds = start.elapsed().as_secs_f64();
    stats.own_cpu_seconds = (after.user - before.user).max(0.0);
    stats.child_cpu_seconds = (after.child - before.child).max(0.0);
    stats.peak_rss_bytes = after.peak;
}

#[derive(Clone, Copy)]
struct Previous {
    user: u64,
    system: u64,
    seq: u64,
    stamp: u64,
}

/// One validator owns global clock order and independent U/S continuity. Offline audit
/// keeps all identities; live input expires state after one source-clock grace window.
struct Validator {
    previous: HashMap<Identity, Previous>,
    last_seq: Option<u64>,
    last_stamp: Option<u64>,
    last_expiry_check: Option<u64>,
    bounded: bool,
}

impl Validator {
    fn new(bounded: bool) -> Self {
        Self {
            previous: HashMap::new(),
            last_seq: None,
            last_stamp: None,
            last_expiry_check: None,
            bounded,
        }
    }

    fn validate(&mut self, row: &mut Observation) -> Result<bool> {
        row.validate()?;
        if self.last_seq.is_some_and(|seq| row.seq <= seq) {
            return Err(format!(
                "global observation sequence is not strictly increasing at {}",
                row.seq
            ));
        }
        if self
            .last_stamp
            .is_some_and(|stamp| row.scan_start_ns <= stamp)
        {
            return Err(format!(
                "global scan clock is not strictly increasing at {}",
                row.scan_start_ns
            ));
        }
        if self.bounded
            && self
                .last_expiry_check
                .is_none_or(|stamp| row.scan_start_ns.saturating_sub(stamp) >= 1_000_000_000)
        {
            let cutoff = row.scan_start_ns.saturating_sub(LIVE_STATE_GRACE_NS);
            self.previous.retain(|_, value| value.stamp >= cutoff);
            self.last_expiry_check = Some(row.scan_start_ns);
        }
        // Raw replay carries acquisition-time continuity decisions. Reset those identities
        // before comparing counters so an old, bounded-window unknown baseline cannot become
        // a new offline regression merely because replay itself is unbounded.
        for identity in row.quality.iter().filter_map(continuity_unknown_identity) {
            self.previous.remove(&identity);
        }
        let mut boundary = row.quality.iter().any(|quality| {
            quality.get("kind").and_then(Value::as_str) == Some("cpu-component-regression")
        });
        for process in &row.processes {
            let id = process.identity();
            let mut old = self.previous.get(&id).copied();
            if self.bounded
                && old.is_some_and(|state| {
                    row.scan_start_ns.saturating_sub(state.stamp) > LIVE_STATE_GRACE_NS
                })
            {
                self.previous.remove(&id);
                old = None;
            }
            if let Some(previous) = old {
                for (component, before, after) in [
                    ("user", previous.user, process.user),
                    ("system", previous.system, process.system),
                ] {
                    if after < before {
                        let event = regression_event(component, process, previous, row);
                        if !row
                            .quality
                            .iter()
                            .any(|quality| same_regression(quality, &event))
                        {
                            row.quality.push(event);
                        }
                        boundary = true;
                    }
                }
            } else if self.bounded {
                // A fresh baseline has no rate to report, but is not a component-regression
                // boundary. If the state cap prevents tracking it, make that loss explicit and
                // cut so bounded state never hides a counter discontinuity inside a block.
                let can_track = self.previous.len() < MAX_LIVE_IDENTITIES;
                let event = if can_track {
                    json!({"kind":"cpu-continuity-unknown","reason":"new-or-expired-live-baseline",
                        "identity":{"pid":process.pid,"start_sec":process.start_sec,"start_usec":process.start_usec},
                        "seq":row.seq,"scan_start_ns":row.scan_start_ns,"unavailable_rate":true})
                } else {
                    boundary = true;
                    json!({"kind":"cpu-continuity-unknown","reason":"live-baseline-state-capacity",
                        "identity":{"pid":process.pid,"start_sec":process.start_sec,"start_usec":process.start_usec},
                        "seq":row.seq,"scan_start_ns":row.scan_start_ns,"unavailable_rate":true})
                };
                if !row.quality.iter().any(|quality| quality == &event) {
                    row.quality.push(event);
                }
            }
            if !self.bounded
                || self.previous.contains_key(&id)
                || self.previous.len() < MAX_LIVE_IDENTITIES
            {
                self.previous.insert(
                    id,
                    Previous {
                        user: process.user,
                        system: process.system,
                        seq: row.seq,
                        stamp: row.scan_start_ns,
                    },
                );
            }
        }
        self.last_seq = Some(row.seq);
        self.last_stamp = Some(row.scan_start_ns);
        Ok(boundary)
    }
}

fn continuity_unknown_identity(quality: &Value) -> Option<Identity> {
    if quality.get("kind").and_then(Value::as_str) != Some("cpu-continuity-unknown") {
        return None;
    }
    let identity = quality.get("identity")?;
    let (pid, start_sec, start_usec) = (
        identity.get("pid")?.as_u64()?,
        identity.get("start_sec")?.as_u64()?,
        identity.get("start_usec")?.as_u64()?,
    );
    Some((
        u32::try_from(pid).ok()?,
        start_sec,
        u32::try_from(start_usec).ok()?,
    ))
}

fn regression_event(
    component: &str,
    process: &Process,
    previous: Previous,
    row: &Observation,
) -> Value {
    let identity =
        json!({"pid":process.pid,"start_sec":process.start_sec,"start_usec":process.start_usec});
    json!({"kind":"cpu-component-regression","component":component,"identity":identity,
        "before":{"identity":identity,"seq":previous.seq,"scan_start_ns":previous.stamp,
            "cpu_unit":"native_ticks","user":previous.user,"system":previous.system},
        "after":{"identity":identity,"seq":row.seq,"scan_start_ns":row.scan_start_ns,
            "cpu_unit":"native_ticks","user":process.user,"system":process.system},
        "unavailable_rate":true,
        "restart_inference":"unknown; counter decrease is not proof of process restart"})
}

fn same_regression(existing: &Value, expected: &Value) -> bool {
    existing.get("kind") == expected.get("kind")
        && existing.get("component") == expected.get("component")
        && existing.get("identity") == expected.get("identity")
        && existing.get("before") == expected.get("before")
        && existing.get("after") == expected.get("after")
}

struct BlockBuilder {
    context: Context,
    rows: Vec<Observation>,
    points: usize,
}
impl BlockBuilder {
    fn new(context: &Context) -> Self {
        Self {
            context: context.clone(),
            rows: Vec::new(),
            points: 0,
        }
    }
    fn should_cut(&self, context: &Context, row: &Observation, options: &RecordOptions) -> bool {
        if self.rows.is_empty() {
            return false;
        }
        if context != &self.context
            || self.rows.len() >= options.block_rows
            || self.points.saturating_add(row.processes.len()) > MAX_POINTS
        {
            return true;
        }
        let start = self
            .rows
            .first()
            .map(|r| r.scan_start_ns)
            .unwrap_or(row.scan_start_ns);
        row.scan_start_ns.saturating_sub(start) >= MAX_BLOCK_AGE_NS
    }
    fn push(&mut self, row: Observation) {
        self.points += row.processes.len();
        self.rows.push(row);
    }
    fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }
}

#[derive(Clone, Copy, Default)]
struct AuditCounts {
    endpoint_mismatches: u64,
    positive_intervals_lost: u64,
    precision_violations: u64,
    rss_floor_violations: u64,
}

struct EncodedBlock {
    bytes: Vec<u8>,
    first_stamp: u64,
    last_stamp: u64,
    audit: AuditCounts,
}

enum Sink {
    Binary(ArchiveWriter),
    Raw(Box<RawSegments>),
}
struct RawSegments {
    root: PathBuf,
    context: Context,
    options: StoreOptions,
    capacity: RootCapacity,
    writer: Option<RawWriter>,
    path: PathBuf,
    segment: u64,
    segment_start_ns: Option<u64>,
}
impl RawSegments {
    fn new(
        run_root: &Path,
        store_root: &Path,
        context: &Context,
        options: StoreOptions,
    ) -> Result<Self> {
        Ok(Self {
            root: run_root.to_path_buf(),
            context: context.clone(),
            options,
            capacity: RootCapacity::new(
                store_root,
                archive_options_for_root(store_root, None, options, STATUS_CAPACITY_RESERVE)?,
            ),
            writer: None,
            path: run_root.join("source-000000.jsonl.zst"),
            segment: 0,
            segment_start_ns: None,
        })
    }
    fn write_block(&mut self, rows: &[Observation]) -> Result<u64> {
        let mut estimate = 0u64;
        for row in rows {
            let value = source::row_to_value(row)?;
            let mut bytes = serde_json::to_vec(&value)
                .map_err(|e| format!("serialize raw observation: {e}"))?;
            bytes.push(b'\n');
            estimate = estimate
                .checked_add(bytes.len() as u64)
                .ok_or_else(|| "raw input size overflow".to_string())?;
        }
        let compression_bound = estimate
            .saturating_add(estimate >> 8)
            .saturating_add(if estimate < 128 * 1024 {
                (128 * 1024 - estimate) >> 11
            } else {
                0
            })
            .saturating_add(4096);
        self.capacity.check(compression_bound)?;
        let old_size = fs::metadata(&self.path).map_or(0, |metadata| metadata.len());
        if self.writer.is_none() {
            self.writer = Some(RawWriter::create(&self.path, &self.context)?);
        }
        let writer = self
            .writer
            .as_mut()
            .ok_or_else(|| "raw source writer is closed".to_string())?;
        for row in rows {
            writer.write(row)?;
        }
        writer.checkpoint()?;
        let new_size = fs::metadata(&self.path)
            .map_err(|e| format!("stat raw segment after write: {e}"))?
            .len();
        self.capacity
            .record_growth(new_size.saturating_sub(old_size))?;
        if self.segment_start_ns.is_none() {
            self.segment_start_ns = rows.first().map(|r| r.scan_start_ns);
        }
        let end = rows.last().map(|r| r.scan_start_ns).unwrap_or(0);
        let age = end.saturating_sub(self.segment_start_ns.unwrap_or(end));
        let size = fs::metadata(&self.path)
            .map_err(|e| format!("stat raw segment: {e}"))?
            .len();
        let rotate = age >= MAX_FRAME_AGE_NS || size >= self.options.frame_bytes as u64;
        if rotate {
            let old = self
                .writer
                .take()
                .ok_or_else(|| "raw source writer is closed".to_string())?;
            self.capacity.check(4096)?;
            old.finish()?;
            let finished_size = fs::metadata(&self.path)
                .map_err(|e| format!("stat completed raw segment: {e}"))?
                .len();
            self.capacity
                .record_growth(finished_size.saturating_sub(new_size))?;
            self.segment = self
                .segment
                .checked_add(1)
                .ok_or_else(|| "raw segment number exhausted".to_string())?;
            self.path = self
                .root
                .join(format!("source-{:06}.jsonl.zst", self.segment));
            self.segment_start_ns = None;
        }
        Ok(estimate)
    }
    fn finish(mut self) -> Result<()> {
        if let Some(writer) = self.writer.take() {
            self.capacity.check(4096)?;
            let before = fs::metadata(&self.path)
                .map_err(|e| format!("stat raw segment before finish: {e}"))?
                .len();
            writer.finish()?;
            let after = fs::metadata(&self.path)
                .map_err(|e| format!("stat raw segment after finish: {e}"))?
                .len();
            self.capacity.record_growth(after.saturating_sub(before))?;
        }
        Ok(())
    }
}

const STATUS_CAPACITY_RESERVE: u64 = 64 * 1024;

fn recording_tree_bytes(path: &Path) -> Result<u64> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|e| format!("inspect recording store path {}: {e}", path.display()))?;
    if metadata.file_type().is_symlink() {
        return Err("unsafe symlink in recording store".into());
    }
    if metadata.is_file() {
        return Ok(metadata.len());
    }
    if !metadata.is_dir() {
        return Err("unsafe entry in recording store".into());
    }
    let mut used = 0_u64;
    for entry in fs::read_dir(path).map_err(|e| format!("measure recording store: {e}"))? {
        let entry = entry.map_err(|e| format!("read recording store entry: {e}"))?;
        used = used
            .checked_add(recording_tree_bytes(&entry.path())?)
            .ok_or_else(|| "recording store size overflow".to_string())?;
    }
    Ok(used)
}

fn check_free_space(root: &Path, options: StoreOptions, addition: u64) -> Result<()> {
    let path = std::ffi::CString::new(root.as_os_str().as_encoded_bytes())
        .map_err(|_| "recording path contains NUL")?;
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    if unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } != 0 {
        return Err(format!(
            "statvfs recording store: {}",
            std::io::Error::last_os_error()
        ));
    }
    let stat = unsafe { stat.assume_init() };
    let unit = if stat.f_frsize == 0 {
        stat.f_bsize
    } else {
        stat.f_frsize
    };
    let free = u64::from(stat.f_bavail).saturating_mul(unit);
    if free < addition.saturating_add(options.min_free_bytes) {
        return Err("recording store free-space reserve reached".into());
    }
    Ok(())
}

fn guard_capacity(root: &Path, options: StoreOptions, addition: u64) -> Result<()> {
    let used = recording_tree_bytes(root)?;
    if used
        .checked_add(addition)
        .is_none_or(|n| n > options.max_bytes)
    {
        return Err("recording store byte limit reached".into());
    }
    check_free_space(root, options, addition)
}

fn archive_options_for_root(
    root: &Path,
    archive: Option<&Path>,
    options: StoreOptions,
    reserve: u64,
) -> Result<StoreOptions> {
    let root_used = recording_tree_bytes(root)?;
    let outside_archive = if let Some(archive) = archive {
        root_used.saturating_sub(recording_tree_bytes(archive)?)
    } else {
        root_used
    };
    let max_bytes = options
        .max_bytes
        .checked_sub(outside_archive)
        .and_then(|remaining| remaining.checked_sub(reserve))
        .filter(|remaining| *remaining > 0)
        .ok_or_else(|| "recording store byte limit reached".to_string())?;
    let min_free_bytes = options
        .min_free_bytes
        .checked_add(reserve)
        .ok_or_else(|| "recording free-space reserve overflow".to_string())?;
    Ok(StoreOptions {
        max_bytes,
        min_free_bytes,
        ..options
    })
}

struct RootCapacity {
    root: PathBuf,
    options: StoreOptions,
    used: u64,
}

impl RootCapacity {
    fn new(root: &Path, options: StoreOptions) -> Self {
        // `options` is the remaining allocation: older root history and the
        // status reserve were already subtracted by archive_options_for_root.
        Self {
            root: root.to_path_buf(),
            options,
            used: 0,
        }
    }

    fn check(&self, addition: u64) -> Result<()> {
        if self
            .used
            .checked_add(addition)
            .is_none_or(|projected| projected > self.options.max_bytes)
        {
            return Err("recording store byte limit reached".into());
        }
        check_free_space(&self.root, self.options, addition)
    }

    fn record_growth(&mut self, growth: u64) -> Result<()> {
        self.used = self
            .used
            .checked_add(growth)
            .ok_or_else(|| "recording store size overflow".to_string())?;
        Ok(())
    }
}

fn open_sink(
    root: &Path,
    run_id: &str,
    context: &Context,
    options: &RecordOptions,
) -> Result<(Sink, PathBuf, Vec<String>)> {
    let run_dir = root.join(format!("run-{run_id}"));
    let store_options = StoreOptions {
        frame_bytes: options.frame_bytes,
        max_bytes: options.max_bytes,
        min_free_bytes: options.min_free_bytes,
    };
    // Reserve for the run/archive directory entries before creating them; all later
    // checks account for the complete recording root, including existing runs.
    guard_capacity(root, store_options, 3 * 4096)?;
    if fs::symlink_metadata(&run_dir).is_ok() {
        return Err(format!(
            "recording run already exists: {}",
            run_dir.display()
        ));
    }
    ownership::create_private_directory(&run_dir)
        .map_err(|e| format!("create recording run directory: {e}"))?;
    write_initial_status(
        &run_dir,
        "live-native",
        "live capture has not recorded an orderly end; trailing observations may be unavailable",
    )?;
    let mut recovery = Vec::new();
    let sink = match options.format {
        OutputFormat::Binary => {
            let archive = run_dir.join("archive");
            let archive_options =
                archive_options_for_root(root, None, store_options, STATUS_CAPACITY_RESERVE)?;
            let writer = ArchiveWriter::open(&archive, context, options.profile, archive_options)?;
            recovery.extend_from_slice(writer.recovery_report());
            Sink::Binary(writer)
        }
        OutputFormat::JsonlZstd => Sink::Raw(Box::new(RawSegments::new(
            &run_dir,
            root,
            context,
            store_options,
        )?)),
    };
    Ok((sink, run_dir, recovery))
}

fn prepare_root(path: &Path) -> Result<(PathBuf, File)> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        create_private_dirs(parent)?;
    }
    let created = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => {
            return Err("recording root must not be a symlink".into());
        }
        Ok(meta) if !meta.is_dir() => return Err("recording root is not a directory".into()),
        Ok(_) => false,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            ownership::create_private_directory(path)
                .map_err(|e| format!("create recording root: {e}"))?;
            true
        }
        Err(e) => return Err(format!("inspect recording root: {e}")),
    };
    let meta = fs::symlink_metadata(path).map_err(|e| format!("inspect recording root: {e}"))?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err("recording root must be a non-symlink directory".into());
    }
    #[cfg(unix)]
    if meta.uid() != ownership::expected_uid() || (!created && meta.mode() & 0o077 != 0) {
        return Err("existing recording root must be owned and private".into());
    }
    let lock_path = path.join("record.lock");
    let mut open = OpenOptions::new();
    open.read(true).write(true).create_new(true);
    #[cfg(unix)]
    open.mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let lock = match open.open(&lock_path) {
        Ok(lock) => {
            if let Err(error) = ownership::chown_created_file(&lock) {
                drop(lock);
                let _ = fs::remove_file(&lock_path);
                return Err(format!("set recording root lock owner: {error}"));
            }
            lock
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            open.create_new(false);
            open.open(&lock_path)
                .map_err(|e| format!("open recording root lock: {e}"))?
        }
        Err(e) => return Err(format!("create recording root lock: {e}")),
    };
    #[cfg(unix)]
    {
        let lock_meta = lock
            .metadata()
            .map_err(|e| format!("inspect recording root lock: {e}"))?;
        if !lock_meta.is_file()
            || lock_meta.uid() != ownership::expected_uid()
            || lock_meta.nlink() != 1
            || lock_meta.mode() & 0o077 != 0
        {
            return Err("recording root lock must be an owned private regular file".into());
        }
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("recording root already has an active writer".into());
        }
    }
    Ok((
        fs::canonicalize(path).map_err(|e| format!("resolve recording root: {e}"))?,
        lock,
    ))
}

fn create_private_dirs(path: &Path) -> Result<()> {
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component);
        match fs::metadata(&current) {
            Ok(meta) if meta.is_dir() => {}
            Ok(_) => {
                return Err(format!(
                    "recording parent is not a directory: {}",
                    current.display()
                ));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                match ownership::create_private_directory(&current) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                        if !fs::metadata(&current).is_ok_and(|meta| meta.is_dir()) {
                            return Err(format!(
                                "recording parent is not a directory: {}",
                                current.display()
                            ));
                        }
                    }
                    Err(error) => {
                        return Err(format!(
                            "create recording parent {}: {error}",
                            current.display()
                        ));
                    }
                }
            }
            Err(error) => {
                return Err(format!(
                    "inspect recording parent {}: {error}",
                    current.display()
                ));
            }
        }
    }
    Ok(())
}

fn recover_owned_archives(root: &Path, options: &RecordOptions) -> Result<Vec<String>> {
    let mut reports = Vec::new();
    let entries = fs::read_dir(root).map_err(|e| format!("list recording root: {e}"))?;
    let mut active = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("read recording root entry: {e}"))?;
        if !entry.file_name().to_string_lossy().starts_with("run-") {
            continue;
        }
        let run_path = entry.path();
        let meta = fs::symlink_metadata(&run_path).map_err(|e| format!("inspect old run: {e}"))?;
        if meta.file_type().is_symlink() || !meta.is_dir() {
            return Err("unsafe entry in recording root".into());
        }
        #[cfg(unix)]
        if meta.uid() != ownership::expected_uid() || meta.mode() & 0o077 != 0 {
            return Err("recording run is not an owned private directory".into());
        }

        let complete = recovery_status(&run_path.join("complete.json"), "complete", &mut reports)?
            .is_some_and(|value| value.get("complete").and_then(Value::as_bool) == Some(true));
        if complete {
            continue;
        }
        let partial_exists =
            recovery_status(&run_path.join("partial.json"), "partial", &mut reports)?.is_some();
        let archive = run_path.join("archive");
        let archive_meta = match fs::symlink_metadata(&archive) {
            Ok(meta) if meta.file_type().is_symlink() || !meta.is_dir() => {
                return Err("unsafe archive entry in recording run".into());
            }
            Ok(meta) => {
                #[cfg(unix)]
                if meta.uid() != ownership::expected_uid() || meta.mode() & 0o077 != 0 {
                    return Err("recording archive is not an owned private directory".into());
                }
                Some(meta)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(format!("inspect old archive: {error}")),
        };
        let Some(_) = archive_meta else {
            continue;
        };
        let journal = archive.join("active.journal");
        let has_journal = match fs::symlink_metadata(&journal) {
            Ok(meta) => {
                if meta.file_type().is_symlink() || !meta.is_file() {
                    return Err("unsafe active journal in recording archive".into());
                }
                #[cfg(unix)]
                if meta.uid() != ownership::expected_uid() || meta.mode() & 0o077 != 0 {
                    return Err("active journal is not an owned private file".into());
                }
                true
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(error) => return Err(format!("inspect active journal: {error}")),
        };
        if partial_exists || has_journal {
            validate_owned_archive_entries(&archive)?;
            active.push(archive);
        }
    }
    active.sort();
    for archive in active {
        let recovery = (|| -> Result<Vec<String>> {
            let meta_path = archive.join("archive.json");
            let bytes = read_owned_metadata(&meta_path, 1024 * 1024)?;
            #[derive(Deserialize)]
            struct Metadata {
                context: Context,
                profile: Profile,
            }
            let metadata: Metadata = serde_json::from_slice(&bytes)
                .map_err(|e| format!("decode archive recovery metadata: {e}"))?;
            let store_options = StoreOptions {
                frame_bytes: options.frame_bytes,
                max_bytes: options.max_bytes,
                min_free_bytes: options.min_free_bytes,
            };
            let store_options = archive_options_for_root(
                root,
                Some(&archive),
                store_options,
                STATUS_CAPACITY_RESERVE,
            )?;
            let writer =
                ArchiveWriter::open(&archive, &metadata.context, metadata.profile, store_options)?;
            let messages = writer.recovery_report().to_vec();
            writer.finish()?;
            Ok(messages)
        })();
        match recovery {
            Ok(messages) if messages.is_empty() => reports.push(format!(
                "{}: active archive recovery checked",
                archive.display()
            )),
            Ok(messages) => reports.extend(
                messages
                    .into_iter()
                    .map(|message| format!("{}: {message}", archive.display())),
            ),
            Err(error) => reports.push(format!(
                "{}: recovery warning; continuing without repair: {error}",
                archive.display()
            )),
        }
    }
    Ok(reports)
}

fn recovery_status(path: &Path, label: &str, reports: &mut Vec<String>) -> Result<Option<Value>> {
    if fs::symlink_metadata(path).is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound) {
        return Ok(None);
    }
    let bytes = read_owned_metadata(path, 64 * 1024)?;
    match serde_json::from_slice(&bytes) {
        Ok(value) => Ok(Some(value)),
        Err(error) => {
            reports.push(format!(
                "{}: ignoring malformed {label} status: {error}",
                path.display()
            ));
            // A malformed partial marker still means the run is not known complete.
            Ok(Some(Value::Null))
        }
    }
}

fn validate_owned_archive_entries(archive: &Path) -> Result<()> {
    for entry in fs::read_dir(archive).map_err(|e| format!("list active archive: {e}"))? {
        let entry = entry.map_err(|e| format!("read active archive entry: {e}"))?;
        let meta = fs::symlink_metadata(entry.path())
            .map_err(|e| format!("inspect active archive entry: {e}"))?;
        if meta.file_type().is_symlink() || !meta.is_file() {
            return Err("unsafe entry in active recording archive".into());
        }
        #[cfg(unix)]
        if meta.uid() != ownership::expected_uid() || meta.mode() & 0o077 != 0 {
            return Err("active archive entry is not an owned private file".into());
        }
    }
    Ok(())
}

fn read_owned_metadata(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let before = fs::symlink_metadata(path)
        .map_err(|e| format!("inspect owned metadata {}: {e}", path.display()))?;
    if before.file_type().is_symlink() || !before.is_file() || before.len() > limit {
        return Err(format!(
            "unsafe or oversized owned metadata: {}",
            path.display()
        ));
    }
    #[cfg(unix)]
    if before.uid() != ownership::expected_uid()
        || before.nlink() != 1
        || before.mode() & 0o077 != 0
    {
        return Err(format!("owned metadata is not private: {}", path.display()));
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let file = options
        .open(path)
        .map_err(|e| format!("open owned metadata {}: {e}", path.display()))?;
    let after = file
        .metadata()
        .map_err(|e| format!("stat owned metadata {}: {e}", path.display()))?;
    #[cfg(unix)]
    if !after.is_file()
        || after.dev() != before.dev()
        || after.ino() != before.ino()
        || after.uid() != ownership::expected_uid()
        || after.nlink() != 1
        || after.mode() & 0o077 != 0
    {
        return Err(format!(
            "owned metadata changed during open: {}",
            path.display()
        ));
    }
    if after.len() > limit {
        return Err(format!("owned metadata exceeds limit: {}", path.display()));
    }
    let mut bytes = Vec::with_capacity(after.len() as usize);
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("read owned metadata {}: {e}", path.display()))?;
    if bytes.len() as u64 > limit {
        return Err(format!("owned metadata exceeds limit: {}", path.display()));
    }
    Ok(bytes)
}

pub(crate) fn validate_record_options(options: &RecordOptions) -> Result<()> {
    if options.hz == 0 || options.hz > 1000 {
        return Err("--hz must be in 1..=1000".into());
    }
    if let Some(duration) = options.duration
        && (!duration.is_finite()
            || duration <= 0.0
            || Duration::try_from_secs_f64(duration).is_err())
    {
        return Err("--duration must be finite, positive, and representable".into());
    }
    if options.block_rows == 0 || options.block_rows > MAX_POINTS {
        return Err("--block-rows must be in 1..=1000000".into());
    }
    if options.frame_bytes == 0 || options.frame_bytes > MAX_BLOCK_BYTES {
        return Err(format!("--frame-bytes must be in 1..={MAX_BLOCK_BYTES}"));
    }
    if options.max_bytes == 0 {
        return Err("--max-bytes must be positive".into());
    }
    options.memory.validate()?;
    Ok(())
}

/// Consume one native run. The producer closes the channel on stop; orderly EOF always
/// commits the final block tail. Runtime scheduling never determines source block cuts.
pub fn consume_live(
    options: &RecordOptions,
    context: &Context,
    rx: Receiver<LiveMessage>,
) -> Result<RunStats> {
    validate_record_options(options)?;
    context.validate()?;
    let run_id = context
        .capture_run_id
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| "live recording context requires a unique capture_run_id".to_string())?;
    if run_id == "."
        || run_id == ".."
        || run_id.len() > 180
        || !run_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    {
        return Err("capture_run_id is not a safe run directory name".into());
    }
    let (root, _lock) = prepare_root(&options.output)?;
    let mut recovery = recover_owned_archives(&root, options)?;
    let (mut sink, run_dir, opened_recovery) = open_sink(&root, run_id, context, options)?;
    recovery.extend(opened_recovery);
    let start = Instant::now();
    let before = usage();
    let mut stats = RunStats {
        recovery,
        ..RunStats::default()
    };
    let mut validator = Validator::new(true);
    let mut builder = BlockBuilder::new(context);
    let mut frame_start = None;
    let mut saw_end = false;
    let mut failure = None;
    loop {
        match rx.recv() {
            Ok(LiveMessage::Observation(mut row)) => {
                let result = (|| {
                    let flagged_boundary = validator.validate(&mut row)?;
                    stats.scans = stats.scans.saturating_add(1);
                    stats.readings = stats.readings.saturating_add(row.processes.len() as u64);
                    stats.flagged_events = stats
                        .flagged_events
                        .saturating_add(row.quality.len() as u64);
                    if builder.should_cut(context, &row, options) || flagged_boundary {
                        append_block(
                            &mut builder,
                            &mut sink,
                            &mut stats,
                            &mut frame_start,
                            options,
                        )?;
                    }
                    builder.push(row);
                    Ok(())
                })();
                if let Err(error) = result {
                    failure = Some(error);
                    break;
                }
            }
            Ok(LiveMessage::End { quality, error }) => {
                saw_end = true;
                stats.flagged_events = stats.flagged_events.saturating_add(quality.len() as u64);
                stats.end_quality = quality;
                if let Some(error) = error {
                    failure = Some(error);
                }
                break;
            }
            Err(_) => break,
        }
    }
    if !saw_end {
        failure.get_or_insert_with(|| {
            "producer channel closed without an explicit End message".into()
        });
    }
    if let Err(error) = append_block(
        &mut builder,
        &mut sink,
        &mut stats,
        &mut frame_start,
        options,
    ) {
        failure.get_or_insert(error);
    }
    if let Err(error) = finish_sink(sink) {
        failure.get_or_insert(error);
    }
    finish_metrics(&mut stats, start, before);
    if let Some(error) = failure {
        stats.end_reason = Some(error.clone());
        write_run_status(&run_dir, "partial.json", &stats, "live-native")?;
        return Err(error);
    }
    stats.complete = true;
    write_run_status(&run_dir, "complete.json", &stats, "live-native")?;
    remove_partial_status(&run_dir)?;
    Ok(stats)
}

fn append_block(
    builder: &mut BlockBuilder,
    sink: &mut Sink,
    stats: &mut RunStats,
    frame_start: &mut Option<u64>,
    options: &RecordOptions,
) -> Result<()> {
    if builder.is_empty() {
        return Ok(());
    }
    let encoded = encode_finished_block(builder, options)?;
    apply_audit_counts(stats, encoded.audit);
    match sink {
        Sink::Binary(_) => append_binary_bytes(
            &encoded.bytes,
            encoded.first_stamp,
            encoded.last_stamp,
            sink,
            frame_start,
            stats,
        )?,
        Sink::Raw(writer) => {
            stats.raw_encoded_bytes = stats
                .raw_encoded_bytes
                .saturating_add(writer.write_block(&builder.rows)?);
            stats.blocks = stats.blocks.saturating_add(1);
        }
    }
    builder.rows.clear();
    builder.points = 0;
    Ok(())
}

fn encode_finished_block(builder: &BlockBuilder, options: &RecordOptions) -> Result<EncodedBlock> {
    let bytes = encode_block_with_memory(
        &builder.context,
        &builder.rows,
        options.profile,
        options.memory.clone(),
    )?;
    let mut audit = RunStats::default();
    if options.verify {
        audit_source_block(
            &builder.context,
            &builder.rows,
            options.profile,
            &options.memory,
            &bytes,
            &mut audit,
        )?;
        if audit.endpoint_mismatches != 0
            || audit.precision_violations != 0
            || audit.rss_floor_violations != 0
            || options.profile == Profile::Adaptive && audit.positive_intervals_lost != 0
        {
            return Err("source fidelity verification failed".into());
        }
    }
    Ok(EncodedBlock {
        bytes,
        first_stamp: builder.rows.first().map_or(0, |row| row.scan_start_ns),
        last_stamp: builder.rows.last().map_or(0, |row| row.scan_start_ns),
        audit: AuditCounts {
            endpoint_mismatches: audit.endpoint_mismatches,
            positive_intervals_lost: audit.positive_intervals_lost,
            precision_violations: audit.precision_violations,
            rss_floor_violations: audit.rss_floor_violations,
        },
    })
}

fn apply_audit_counts(stats: &mut RunStats, audit: AuditCounts) {
    stats.endpoint_mismatches = stats
        .endpoint_mismatches
        .saturating_add(audit.endpoint_mismatches);
    stats.positive_intervals_lost = stats
        .positive_intervals_lost
        .saturating_add(audit.positive_intervals_lost);
    stats.precision_violations = stats
        .precision_violations
        .saturating_add(audit.precision_violations);
    stats.rss_floor_violations = stats
        .rss_floor_violations
        .saturating_add(audit.rss_floor_violations);
}

fn append_binary_bytes(
    bytes: &[u8],
    first_stamp: u64,
    last_stamp: u64,
    sink: &mut Sink,
    frame_start: &mut Option<u64>,
    stats: &mut RunStats,
) -> Result<()> {
    let Sink::Binary(writer) = sink else {
        return Err("encoded binary block requires archive writer".into());
    };
    if !writer.has_active_frame() {
        *frame_start = None;
    }
    if frame_start.is_some_and(|start| first_stamp.saturating_sub(start) >= MAX_FRAME_AGE_NS) {
        writer.flush_frame()?;
        *frame_start = None;
    }
    writer.append(bytes)?;
    if writer.has_active_frame() {
        if frame_start.is_none() {
            *frame_start = Some(first_stamp);
        }
        if frame_start.is_some_and(|start| last_stamp.saturating_sub(start) >= MAX_FRAME_AGE_NS) {
            writer.flush_frame()?;
            *frame_start = None;
        }
    } else {
        *frame_start = None;
    }
    stats.blocks = stats.blocks.saturating_add(1);
    stats.raw_encoded_bytes = stats.raw_encoded_bytes.saturating_add(bytes.len() as u64);
    Ok(())
}

fn finish_sink(sink: Sink) -> Result<()> {
    match sink {
        Sink::Binary(writer) => writer.finish(),
        Sink::Raw(writer) => writer.finish(),
    }
}

fn write_initial_status(run: &Path, kind: &str, reason: &str) -> Result<()> {
    let value = json!({"kind":kind,"complete":false,"status":"in-progress","end_reason":reason});
    let bytes =
        serde_json::to_vec_pretty(&value).map_err(|e| format!("encode initial run status: {e}"))?;
    publish_status(run, "partial.json", &bytes, false)
}

fn write_run_status(run: &Path, name: &str, stats: &RunStats, kind: &str) -> Result<()> {
    let mut value = serde_json::to_value(stats).map_err(|e| format!("encode run status: {e}"))?;
    let status = value
        .as_object_mut()
        .ok_or_else(|| "run status is not a JSON object".to_string())?;
    let complete = name == "complete.json";
    status.insert("kind".into(), json!(kind));
    status.insert("complete".into(), json!(complete));
    status.insert(
        "status".into(),
        json!(if complete { "complete" } else { "failed" }),
    );
    let bytes = serde_json::to_vec_pretty(&value).map_err(|e| format!("encode run status: {e}"))?;
    publish_status(run, name, &bytes, !complete)
}

fn publish_status(run: &Path, name: &str, bytes: &[u8], replace: bool) -> Result<()> {
    let path = run.join(name);
    if replace {
        validate_owned_status(&path, true)?;
    }
    let (temp, mut file) = loop {
        let id = STATUS_TEMP_ID.fetch_add(1, Ordering::Relaxed);
        let temp = run.join(format!(".{name}.{}.{}.tmp", std::process::id(), id));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        match options.open(&temp) {
            Ok(file) => {
                if let Err(error) = ownership::chown_created_file(&file) {
                    drop(file);
                    let _ = fs::remove_file(&temp);
                    return Err(format!("set run status temp owner: {error}"));
                }
                break (temp, file);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("create run status temp: {error}")),
        }
    };
    let result = (|| -> Result<()> {
        file.write_all(bytes)
            .map_err(|e| format!("write run status: {e}"))?;
        file.sync_all()
            .map_err(|e| format!("sync run status: {e}"))?;
        drop(file);
        if replace {
            validate_owned_status(&path, true)?;
            fs::rename(&temp, &path).map_err(|e| format!("replace run status: {e}"))?;
        } else {
            fs::hard_link(&temp, &path).map_err(|e| format!("publish run status: {e}"))?;
            fs::remove_file(&temp).map_err(|e| format!("remove run status temp: {e}"))?;
        }
        File::open(run)
            .and_then(|directory| directory.sync_all())
            .map_err(|e| format!("sync run directory: {e}"))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

fn validate_owned_status(path: &Path, required: bool) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if !required && error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("inspect run status {}: {error}", path.display())),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!("unsafe run status: {}", path.display()));
    }
    #[cfg(unix)]
    if metadata.uid() != ownership::expected_uid()
        || metadata.nlink() != 1
        || metadata.mode() & 0o077 != 0
    {
        return Err(format!(
            "run status is not an owned private file: {}",
            path.display()
        ));
    }
    Ok(())
}

fn remove_partial_status(run: &Path) -> Result<()> {
    let path = run.join("partial.json");
    validate_owned_status(&path, false)?;
    match fs::remove_file(&path) {
        Ok(()) => File::open(run)
            .and_then(|directory| directory.sync_all())
            .map_err(|e| format!("sync run directory after status cleanup: {e}")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("remove partial run status: {error}")),
    }
}

/// Import ordered JSONL files through the exact live validator/encoder. Output is a
/// private root containing `archive/`; `complete.json` is published only after every
/// source stream has reached a clean EOF and its decompression/hash accounting succeeds.
pub fn transform_sources(
    inputs: &[PathBuf],
    output: &Path,
    options: &RecordOptions,
    legacy_timebase: Option<Timebase>,
) -> Result<RunStats> {
    transform_sources_impl(inputs, output, options, legacy_timebase, None)
}

/// Opt-in bulk transform using bounded source-summary and encode worker pools.
pub fn transform_sources_with_workers(
    inputs: &[PathBuf],
    output: &Path,
    options: &RecordOptions,
    legacy_timebase: Option<Timebase>,
    workers: usize,
) -> Result<RunStats> {
    if workers == 0 {
        return Err("--workers must be positive".into());
    }
    transform_sources_impl(inputs, output, options, legacy_timebase, Some(workers))
}

fn transform_sources_impl(
    inputs: &[PathBuf],
    output: &Path,
    options: &RecordOptions,
    legacy_timebase: Option<Timebase>,
    bulk_workers: Option<usize>,
) -> Result<RunStats> {
    validate_record_options(options)?;
    if inputs.is_empty() {
        return Err("transform needs at least one source file".into());
    }
    let start = Instant::now();
    let before = usage();
    let upstream_status = source_run_status(inputs)?;
    for input in inputs {
        let meta =
            fs::symlink_metadata(input).map_err(|e| format!("inspect transform source: {e}"))?;
        if meta.file_type().is_symlink() || !meta.is_file() {
            return Err(format!(
                "transform source must be a regular non-symlink file: {}",
                input.display()
            ));
        }
    }
    let capture_ledger = capture_ledger_for_inputs(inputs)?;
    if fs::symlink_metadata(output).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err("transform output must not be a symlink".into());
    }
    let output_abs = if output.exists() {
        fs::canonicalize(output).map_err(|e| format!("resolve transform output: {e}"))?
    } else {
        let parent = output
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        fs::canonicalize(parent)
            .map_err(|e| format!("resolve transform output parent: {e}"))?
            .join(
                output
                    .file_name()
                    .ok_or_else(|| "output has no final component".to_string())?,
            )
    };
    for input in inputs {
        let source_abs =
            fs::canonicalize(input).map_err(|e| format!("resolve transform source: {e}"))?;
        if output_abs == source_abs || source_abs.starts_with(&output_abs) {
            return Err("transform input and output trees must not overlap".into());
        }
    }
    match fs::symlink_metadata(output) {
        Ok(meta) if !meta.is_dir() => return Err("transform output is not a directory".into()),
        Ok(_)
            if fs::read_dir(output)
                .map_err(|e| format!("inspect transform output: {e}"))?
                .next()
                .is_some() =>
        {
            return Err("transform output must be a new or empty directory".into());
        }
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            return Err(format!("inspect transform output: {e}"));
        }
        _ => {}
    }
    let (root, _lock) = prepare_root(output)?;
    let entries = fs::read_dir(&root).map_err(|e| format!("inspect transform output: {e}"))?;
    for entry in entries {
        let name = entry
            .map_err(|e| format!("inspect transform output entry: {e}"))?
            .file_name();
        if name != "record.lock" {
            return Err("transform output must be a new or empty directory".into());
        }
    }
    write_initial_status(
        &root,
        "source-import",
        "source EOF and integrity verification are pending; imported data is not yet trusted",
    )?;
    let archive_path = root.join("archive");
    let mut checked_segments = if capture_ledger.is_some() {
        let path = root.join("checkedsegments.jsonl");
        let mut open = OpenOptions::new();
        open.write(true).create_new(true);
        #[cfg(unix)]
        open.mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        let file = open
            .open(&path)
            .map_err(|e| format!("create checked segment ledger: {e}"))?;
        if let Err(error) = ownership::chown_created_file(&file) {
            drop(file);
            let _ = fs::remove_file(&path);
            return Err(format!("set checked segment ledger owner: {error}"));
        }
        Some(file)
    } else {
        None
    };
    let mut stats = RunStats {
        verification_enabled: options.verify,
        bulk_workers: bulk_workers.map(|workers| workers.min(inputs.len()).max(1)),
        encoding_workers: bulk_workers.map(|_| 1),
        source_passes: bulk_workers.map(|_| 1),
        ..RunStats::default()
    };
    let mut first_context: Option<Context> = None;
    let mut active_context: Option<Context> = None;
    let mut sink: Option<Sink> = None;
    let mut builder: Option<BlockBuilder> = None;
    let mut validator = Validator::new(false);
    let mut frame_start = None;
    let base_store_options = StoreOptions {
        frame_bytes: options.frame_bytes,
        max_bytes: options.max_bytes,
        min_free_bytes: options.min_free_bytes,
    };
    let ledger_reserve = if let Some(ledger) = &capture_ledger {
        inputs.iter().try_fold(0_u64, |reserve, input| {
            let relative = relative_to_capture(&ledger.root, input)?;
            reserve
                .checked_add(1024 + (relative.len() as u64).saturating_mul(6))
                .ok_or_else(|| "checked segment ledger reserve overflow".to_string())
        })?
    } else {
        0
    };
    let source_status_reserve = inputs.iter().try_fold(0_u64, |reserve, input| {
        reserve
            .checked_add(
                1024 + (input.as_os_str().as_encoded_bytes().len() as u64).saturating_mul(6),
            )
            .ok_or_else(|| "source status reserve overflow".to_string())
    })?;
    let end_quality_reserve = upstream_status
        .as_ref()
        .map(|status| serde_json::to_vec(&status.end_quality).map(|bytes| bytes.len() as u64))
        .transpose()
        .map_err(|error| format!("size upstream end quality: {error}"))?
        .unwrap_or(0);
    let output_reserve = STATUS_CAPACITY_RESERVE
        .checked_add(ledger_reserve)
        .and_then(|reserve| reserve.checked_add(source_status_reserve))
        .and_then(|reserve| reserve.checked_add(end_quality_reserve))
        .ok_or_else(|| "transform output reserve overflow".to_string())?;
    let store_options = archive_options_for_root(&root, None, base_store_options, output_reserve)?;
    if let Some(requested_workers) = bulk_workers.filter(|workers| *workers > 1 && inputs.len() > 1)
    {
        let result = run_bulk_transform(BulkTransformSetup {
            inputs,
            legacy_timebase,
            options,
            requested_workers,
            archive_path: &archive_path,
            store_options,
            capture_ledger: capture_ledger.as_ref(),
            checked_segments,
            stats,
        });
        return match result {
            Ok(mut stats) => {
                if let Some(status) = &upstream_status {
                    stats.end_quality = status.end_quality.clone();
                    stats.flagged_events = stats
                        .flagged_events
                        .saturating_add(stats.end_quality.len() as u64);
                    stats.end_reason = status.end_reason.clone();
                }
                finish_metrics(&mut stats, start, before);
                if upstream_status
                    .as_ref()
                    .is_some_and(|status| status.partial)
                {
                    write_run_status(&root, "partial.json", &stats, "source-import")?;
                } else {
                    stats.complete = true;
                    write_run_status(&root, "complete.json", &stats, "source-import")?;
                    remove_partial_status(&root)?;
                }
                Ok(stats)
            }
            Err(error) => {
                write_failure_marker(&root, &error)?;
                Err(error)
            }
        };
    }
    let mut failure: Option<String> = None;
    for (input_index, input) in inputs.iter().enumerate() {
        if let Some(ledger) = &capture_ledger
            && let Err(error) = verify_capture_source_hash(ledger, input_index, input)
        {
            failure = Some(error);
            break;
        }
        let mut file_context: Option<Context> = None;
        let result = source::visit_source(input, legacy_timebase, |context, mut row| {
            if let Some(old) = &file_context {
                if old != context {
                    return Err("source context changed within one file".into());
                }
            } else {
                file_context = Some(context.clone());
            }
            if let Some(first) = &first_context {
                if !first.same_stream(context) {
                    return Err(
                        "source hz/timebase/run/boot context is not stable across files".into(),
                    );
                }
            } else {
                first_context = Some(context.clone());
                ownership::create_private_directory(&archive_path)
                    .map_err(|e| format!("create transformed archive: {e}"))?;
                sink = Some(Sink::Binary(ArchiveWriter::open(
                    &archive_path,
                    context,
                    options.profile,
                    store_options,
                )?));
                active_context = Some(context.clone());
                builder = Some(BlockBuilder::new(context));
            }
            if active_context.as_ref() != Some(context) {
                if let (Some(builder), Some(sink)) = (builder.as_mut(), sink.as_mut()) {
                    append_block(builder, sink, &mut stats, &mut frame_start, options)?;
                }
                active_context = Some(context.clone());
                builder = Some(BlockBuilder::new(context));
            }
            let flagged = validator.validate(&mut row)?;
            stats.scans = stats.scans.saturating_add(1);
            stats.readings = stats.readings.saturating_add(row.processes.len() as u64);
            stats.flagged_events = stats
                .flagged_events
                .saturating_add(row.quality.len() as u64);
            let builder_ref = builder
                .as_mut()
                .ok_or_else(|| "transform block builder not initialized".to_string())?;
            if builder_ref.should_cut(context, &row, options) || flagged {
                append_block(
                    builder_ref,
                    sink.as_mut()
                        .ok_or_else(|| "transform writer not initialized".to_string())?,
                    &mut stats,
                    &mut frame_start,
                    options,
                )?;
            }
            builder_ref.push(row);
            Ok(())
        });
        match result {
            Ok(source_stats) => {
                let compressed_hash = if let Some(ledger) = &capture_ledger {
                    match verify_capture_segment(ledger, input_index, input, &source_stats) {
                        Ok(hash) => Some(hash),
                        Err(error) => {
                            failure = Some(error);
                            break;
                        }
                    }
                } else {
                    None
                };
                if let Some(first) = &first_context {
                    if !first.same_stream(&source_stats.context) {
                        failure = Some(format!(
                            "{}: source context is not stable across files",
                            input.display()
                        ));
                        break;
                    }
                } else {
                    first_context = Some(source_stats.context.clone());
                    ownership::create_private_directory(&archive_path)
                        .map_err(|e| format!("create transformed archive: {e}"))?;
                    sink = Some(Sink::Binary(ArchiveWriter::open(
                        &archive_path,
                        &source_stats.context,
                        options.profile,
                        store_options,
                    )?));
                    active_context = Some(source_stats.context.clone());
                    builder = Some(BlockBuilder::new(&source_stats.context));
                }
                if let (Some(ledger), Some(hash), Some(file)) = (
                    &capture_ledger,
                    compressed_hash.as_deref(),
                    checked_segments.as_mut(),
                ) {
                    match checked_segment_line(ledger, input_index, input, &source_stats, hash)
                        .and_then(|line| {
                            file.write_all(&line)
                                .map_err(|e| format!("write checked segment: {e}"))
                        }) {
                        Ok(()) => {}
                        Err(error) => {
                            failure = Some(error);
                            break;
                        }
                    }
                }
                stats.source_hashes.push(SourceHashStats {
                    path: input.to_string_lossy().into_owned(),
                    scans: source_stats.scans,
                    readings: source_stats.readings,
                    input_bytes: source_stats.input_bytes,
                    expanded_bytes: source_stats.expanded_bytes,
                    expanded_sha256: source_stats.expanded_sha256,
                    first_seq: source_stats.first_seq,
                    last_seq: source_stats.last_seq,
                    first_scan_start_ns: source_stats.first_scan_start_ns,
                    last_scan_start_ns: source_stats.last_scan_start_ns,
                });
            }
            Err(error) => {
                failure = Some(format!("{}: {error}", input.display()));
                break;
            }
        }
    }
    if let Some(file) = checked_segments.as_mut()
        && let Err(error) = file.sync_all()
    {
        failure.get_or_insert_with(|| format!("sync checked segment ledger: {error}"));
    }
    if let (Some(builder), Some(sink)) = (builder.as_mut(), sink.as_mut())
        && let Err(error) = append_block(builder, sink, &mut stats, &mut frame_start, options)
    {
        failure.get_or_insert(error);
    }
    if let Some(sink) = sink.take()
        && let Err(error) = finish_sink(sink)
    {
        failure.get_or_insert(error);
    }
    if let Some(error) = failure {
        write_failure_marker(&root, &error)?;
        return Err(error);
    }
    if first_context.is_none() {
        let message = "all source files failed before a valid source context was available";
        write_failure_marker(&root, message)?;
        return Err(message.into());
    }
    if let Some(status) = &upstream_status {
        stats.end_quality = status.end_quality.clone();
        stats.flagged_events = stats
            .flagged_events
            .saturating_add(stats.end_quality.len() as u64);
        stats.end_reason = status.end_reason.clone();
    }
    finish_metrics(&mut stats, start, before);
    if upstream_status
        .as_ref()
        .is_some_and(|status| status.partial)
    {
        write_run_status(&root, "partial.json", &stats, "source-import")?;
    } else {
        stats.complete = true;
        write_run_status(&root, "complete.json", &stats, "source-import")?;
        remove_partial_status(&root)?;
    }
    Ok(stats)
}

struct BulkTransformSetup<'a> {
    inputs: &'a [PathBuf],
    legacy_timebase: Option<Timebase>,
    options: &'a RecordOptions,
    requested_workers: usize,
    archive_path: &'a Path,
    store_options: StoreOptions,
    capture_ledger: Option<&'a CaptureLedger>,
    checked_segments: Option<File>,
    stats: RunStats,
}

fn run_bulk_transform(setup: BulkTransformSetup<'_>) -> Result<RunStats> {
    run_bulk_transform_with_group_limit(setup, bulk::MAX_GROUP_ENCODED_BYTES)
}

fn run_bulk_transform_with_group_limit(
    setup: BulkTransformSetup<'_>,
    max_group_encoded_bytes: usize,
) -> Result<RunStats> {
    let BulkTransformSetup {
        inputs,
        legacy_timebase,
        options,
        requested_workers,
        archive_path,
        store_options,
        capture_ledger,
        mut checked_segments,
        mut stats,
    } = setup;
    let plan = bulk::build_plan(inputs, legacy_timebase, capture_ledger, requested_workers)?;
    let encoding_workers = requested_workers.min(plan.groups.len()).max(1);
    stats.bulk_workers = Some(plan.parser_workers);
    stats.encoding_workers = Some(encoding_workers);
    stats.source_passes = Some(2);

    ownership::create_private_directory(archive_path)
        .map_err(|e| format!("create transformed archive: {e}"))?;
    let mut sink = Sink::Binary(ArchiveWriter::open(
        archive_path,
        &plan.first_context,
        options.profile,
        store_options,
    )?);
    let mut frame_start = None;

    let transform_result = (|| {
        if plan.groups.len() == 1 {
            let cancel = std::sync::atomic::AtomicBool::new(false);
            let replay = bulk::ReplayInput {
                inputs,
                expected_sources: &plan.sources,
                expected_compressed_hashes: &plan.compressed_hashes,
                legacy_timebase,
                ledger: capture_ledger,
                options,
                cancel: &cancel,
            };
            let group_stats = bulk::replay_group(&plan.groups[0], &replay, |block| {
                apply_audit_counts(&mut stats, block.audit);
                append_binary_bytes(
                    &block.bytes,
                    block.first_stamp,
                    block.last_stamp,
                    &mut sink,
                    &mut frame_start,
                    &mut stats,
                )
            })?;
            commit_group_stats(
                group_stats,
                inputs,
                capture_ledger,
                checked_segments.as_mut(),
                &mut stats,
            )?;
        } else {
            for batch_start in (0..plan.groups.len()).step_by(encoding_workers) {
                let batch_end = (batch_start + encoding_workers).min(plan.groups.len());
                let cancel = std::sync::atomic::AtomicBool::new(false);
                let outputs = std::thread::scope(|scope| {
                    let mut handles = Vec::with_capacity(batch_end - batch_start);
                    let mut spawn_error = None;
                    for group_index in batch_start..batch_end {
                        let cancel = &cancel;
                        let group = &plan.groups[group_index];
                        let replay = bulk::ReplayInput {
                            inputs,
                            expected_sources: &plan.sources,
                            expected_compressed_hashes: &plan.compressed_hashes,
                            legacy_timebase,
                            ledger: capture_ledger,
                            options,
                            cancel,
                        };
                        match std::thread::Builder::new()
                            .name(format!("bulk-encode-{group_index}"))
                            .spawn_scoped(scope, move || {
                                let result =
                                    if max_group_encoded_bytes == bulk::MAX_GROUP_ENCODED_BYTES {
                                        bulk::encode_group(group, &replay)
                                    } else {
                                        bulk::encode_group_with_limit(
                                            group,
                                            &replay,
                                            max_group_encoded_bytes,
                                        )
                                    };
                                if result.is_err() {
                                    cancel.store(true, Ordering::Release);
                                }
                                result
                            }) {
                            Ok(handle) => handles.push((group_index, handle)),
                            Err(error) => {
                                cancel.store(true, Ordering::Release);
                                spawn_error = Some(format!(
                                    "spawn bulk encode worker for group {group_index}: {error}"
                                ));
                                break;
                            }
                        }
                    }
                    let mut results = Vec::with_capacity(handles.len());
                    let mut failure = spawn_error;
                    for (group_index, handle) in handles {
                        match handle.join() {
                            Ok(Ok(output)) => results.push((group_index, Some(output))),
                            Ok(Err(error)) => {
                                if !error.contains("cancelled after a peer failure")
                                    && failure.is_none()
                                {
                                    failure = Some(error);
                                }
                                results.push((group_index, None));
                            }
                            Err(_) => {
                                cancel.store(true, Ordering::Release);
                                failure.get_or_insert_with(|| {
                                    format!("bulk encode worker for group {group_index} panicked")
                                });
                                results.push((group_index, None));
                            }
                        }
                    }
                    (results, failure)
                });
                if let Some(error) = outputs.1 {
                    return Err(error);
                }
                for (group_index, output) in outputs.0 {
                    let output = output.ok_or_else(|| {
                        format!("bulk encode group {group_index} cancelled after a peer failure")
                    })?;
                    for block in output.blocks {
                        apply_audit_counts(&mut stats, block.audit);
                        append_binary_bytes(
                            &block.bytes,
                            block.first_stamp,
                            block.last_stamp,
                            &mut sink,
                            &mut frame_start,
                            &mut stats,
                        )?;
                    }
                    commit_group_stats(
                        output.stats,
                        inputs,
                        capture_ledger,
                        checked_segments.as_mut(),
                        &mut stats,
                    )?;
                }
            }
        }
        Ok(())
    })();

    let mut failure = transform_result.err();
    if let Some(file) = checked_segments.as_mut()
        && let Err(error) = file.sync_all()
    {
        let cleanup = format!("sync checked segment ledger: {error}");
        if let Some(primary) = &mut failure {
            primary.push_str(&format!("; additionally, {cleanup}"));
        } else {
            failure = Some(cleanup);
        }
    }
    if let Err(error) = finish_sink(sink) {
        let cleanup = format!("finish transformed archive: {error}");
        if let Some(primary) = &mut failure {
            primary.push_str(&format!("; additionally, {cleanup}"));
        } else {
            failure = Some(cleanup);
        }
    }
    match failure {
        Some(error) => Err(error),
        None => Ok(stats),
    }
}

fn commit_group_stats(
    group: bulk::GroupStats,
    inputs: &[PathBuf],
    ledger: Option<&CaptureLedger>,
    mut checked_segments: Option<&mut File>,
    stats: &mut RunStats,
) -> Result<()> {
    stats.scans = stats.scans.saturating_add(group.scans);
    stats.readings = stats.readings.saturating_add(group.readings);
    stats.flagged_events = stats.flagged_events.saturating_add(group.flagged_events);
    for source in group.sources {
        let index = source.index;
        let source_stats = source.stats;
        stats.source_hashes.push(SourceHashStats {
            path: inputs[index].to_string_lossy().into_owned(),
            scans: source_stats.scans,
            readings: source_stats.readings,
            input_bytes: source_stats.input_bytes,
            expanded_bytes: source_stats.expanded_bytes,
            expanded_sha256: source_stats.expanded_sha256.clone(),
            first_seq: source_stats.first_seq,
            last_seq: source_stats.last_seq,
            first_scan_start_ns: source_stats.first_scan_start_ns,
            last_scan_start_ns: source_stats.last_scan_start_ns,
        });
        if let (Some(ledger), Some(file)) = (ledger, checked_segments.as_deref_mut()) {
            let line = checked_segment_line(
                ledger,
                index,
                &inputs[index],
                &source_stats,
                &source.compressed_hash,
            )?;
            file.write_all(&line)
                .map_err(|e| format!("write checked segment: {e}"))?;
        }
    }
    Ok(())
}

#[derive(Clone, Debug)]
struct UpstreamStatus {
    partial: bool,
    end_quality: Vec<Value>,
    end_reason: Option<String>,
}

fn source_run_status(inputs: &[PathBuf]) -> Result<Option<UpstreamStatus>> {
    let mut parents = inputs
        .iter()
        .filter_map(|path| path.parent().map(Path::to_path_buf))
        .collect::<Vec<_>>();
    parents.sort();
    parents.dedup();
    let mut found = None;
    for parent in parents {
        let complete_path = parent.join("complete.json");
        let complete = read_upstream_status_file(&complete_path)?;
        let known_complete = complete.as_ref().is_some_and(|value| {
            value.get("kind").and_then(Value::as_str) == Some("live-native")
                && value.get("complete").and_then(Value::as_bool) == Some(true)
        });
        let selected = if known_complete {
            complete
        } else {
            let partial = read_upstream_status_file(&parent.join("partial.json"))?;
            partial.filter(|value| {
                value.get("kind").and_then(Value::as_str) == Some("live-native")
                    && value.get("complete").and_then(Value::as_bool) != Some(true)
            })
        };
        let Some(value) = selected else {
            continue;
        };
        let partial = value.get("complete").and_then(Value::as_bool) != Some(true);
        let end_quality = value
            .get("end_quality")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let end_reason = value
            .get("end_reason")
            .or_else(|| value.get("error"))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| {
                partial.then(|| {
                    "upstream live recording did not publish an orderly complete status".into()
                })
            });
        let status = UpstreamStatus {
            partial,
            end_quality,
            end_reason,
        };
        if found.as_ref().is_some_and(|old: &UpstreamStatus| {
            old.partial != status.partial
                || old.end_quality != status.end_quality
                || old.end_reason != status.end_reason
        }) {
            return Err("source files have conflicting live-run status metadata".into());
        }
        found = Some(status);
    }
    Ok(found)
}

fn read_upstream_status_file(path: &Path) -> Result<Option<Value>> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("inspect upstream run status: {error}")),
        Ok(_) => {
            let bytes = read_owned_metadata(path, 64 * 1024)?;
            let value = serde_json::from_slice(&bytes)
                .map_err(|e| format!("decode upstream run status {}: {e}", path.display()))?;
            Ok(Some(value))
        }
    }
}

fn write_failure_marker(root: &Path, message: &str) -> Result<()> {
    let value = json!({"kind":"source-import","complete":false,"status":"failed","error":message});
    let bytes = serde_json::to_vec(&value).map_err(|e| format!("encode partial marker: {e}"))?;
    publish_status(root, "partial.json", &bytes, true)
}

#[derive(Clone, Debug, Deserialize)]
struct CaptureSegment {
    path: String,
    segment_index: u64,
    count: u64,
    #[serde(default)]
    requested_samples: Option<u64>,
    seq_range: [u64; 2],
    time_range_ns: [u64; 2],
    complete: bool,
    capture_run_id: String,
    #[serde(default)]
    source_sha256: Option<String>,
    #[serde(default)]
    expanded_sha256: Option<String>,
}
#[derive(Clone, Debug)]
struct FrozenFile {
    bytes: u64,
    sha256: String,
}
struct CaptureLedger {
    root: PathBuf,
    source_root: PathBuf,
    run_id: String,
    hz: Option<u64>,
    segments: Vec<CaptureSegment>,
    frozen: HashMap<String, FrozenFile>,
}
const MAX_CAPTURE_METADATA_BYTES: u64 = 16 * 1024 * 1024;

fn capture_source_root(input: &Path) -> PathBuf {
    [input.join("capture/source"), input.join("source")]
        .into_iter()
        .find(|path| path.is_dir())
        .unwrap_or_else(|| input.to_path_buf())
}

fn load_capture_ledger(input: &Path) -> Result<Option<CaptureLedger>> {
    let source_root = capture_source_root(input);
    let ledger_path = source_root.join("segments.jsonl");
    let ledger_meta = match fs::symlink_metadata(&ledger_path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            if [
                input.join("PRESERVATION.json"),
                input.join("run.json"),
                source_root.join("PRESERVATION.json"),
                source_root.join("run.json"),
            ]
            .iter()
            .any(|path| path.exists())
            {
                return Err("capture root is missing source/segments.jsonl".into());
            }
            return Ok(None);
        }
        Err(error) => return Err(format!("inspect capture ledger: {error}")),
    };
    if ledger_meta.file_type().is_symlink()
        || !ledger_meta.is_file()
        || ledger_meta.len() > MAX_CAPTURE_METADATA_BYTES
    {
        return Err("capture segment ledger is not a bounded regular file".into());
    }
    let mut open = OpenOptions::new();
    open.read(true);
    #[cfg(unix)]
    open.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let file = open
        .open(&ledger_path)
        .map_err(|e| format!("open capture ledger: {e}"))?;
    let opened = file
        .metadata()
        .map_err(|e| format!("stat capture ledger: {e}"))?;
    if !opened.is_file() || opened.len() != ledger_meta.len() {
        return Err("capture segment ledger changed during open".into());
    }
    let mut reader = BufReader::new(file);
    let mut digest = Sha256::new();
    let mut ledger_bytes = 0_u64;
    let mut segments = Vec::new();
    let mut names = HashSet::new();
    let mut run_id: Option<String> = None;
    let mut previous_seq = None;
    let mut previous_stamp = None;
    let mut line = Vec::new();
    loop {
        line.clear();
        let size = reader
            .read_until(b'\n', &mut line)
            .map_err(|e| format!("read capture ledger: {e}"))?;
        if size == 0 {
            break;
        }
        if size > 1024 * 1024 || line.last() != Some(&b'\n') {
            return Err("capture segment ledger has an oversized or torn line".into());
        }
        digest.update(&line);
        ledger_bytes = ledger_bytes
            .checked_add(size as u64)
            .ok_or_else(|| "capture ledger byte count overflow".to_string())?;
        if line.len() == 1 {
            return Err("blank line in capture segment ledger".into());
        }
        let segment: CaptureSegment = serde_json::from_slice(&line[..line.len() - 1])
            .map_err(|e| format!("invalid capture segment ledger entry: {e}"))?;
        if segment.segment_index != segments.len() as u64
            || segment.count == 0
            || segment.capture_run_id.trim().is_empty()
            || !names.insert(segment.path.clone())
        {
            return Err("duplicate or invalid capture segment index/path".into());
        }
        let basename = Path::new(&segment.path)
            .file_name()
            .and_then(|name| name.to_str())
            == Some(segment.path.as_str());
        if !basename || segment.path == "." || segment.path == ".." {
            return Err("capture segment path must be a basename".into());
        }
        if run_id
            .as_ref()
            .is_some_and(|old| old != &segment.capture_run_id)
        {
            return Err("capture run ID changes in segment ledger".into());
        }
        run_id.get_or_insert_with(|| segment.capture_run_id.clone());
        if segment.seq_range[1] < segment.seq_range[0]
            || segment.time_range_ns[1] < segment.time_range_ns[0]
            || segment.count
                > segment.seq_range[1]
                    .saturating_sub(segment.seq_range[0])
                    .saturating_add(1)
            || previous_seq.is_some_and(|last| segment.seq_range[0] <= last)
            || previous_stamp.is_some_and(|last| segment.time_range_ns[0] <= last)
        {
            return Err("invalid or overlapping source sequence/time coverage in ledger".into());
        }
        if let Some(requested) = segment.requested_samples
            && (requested == 0
                || segment.count > requested
                || segment.complete != (segment.count == requested))
        {
            return Err("capture segment count/complete fields disagree".into());
        }
        previous_seq = Some(segment.seq_range[1]);
        previous_stamp = Some(segment.time_range_ns[1]);
        segments.push(segment);
    }
    if segments.is_empty()
        || segments[..segments.len() - 1]
            .iter()
            .any(|part| !part.complete)
    {
        return Err("empty ledger or incomplete non-final source segment".into());
    }
    let run_id = run_id.ok_or_else(|| "capture segment ledger has no run ID".to_string())?;
    let mut capture_root = source_root.parent().unwrap_or(&source_root).to_path_buf();
    for candidate in [
        input.to_path_buf(),
        source_root.clone(),
        capture_root.clone(),
    ] {
        if candidate.join("PRESERVATION.json").is_file() {
            capture_root = candidate;
            break;
        }
    }
    let mut frozen = HashMap::new();
    let mut hz = None;
    let preservation_path = capture_root.join("PRESERVATION.json");
    if preservation_path.exists() {
        let bytes = read_bounded_file(&preservation_path, 4 * 1024 * 1024)?;
        let preservation: Value = serde_json::from_slice(&bytes)
            .map_err(|e| format!("decode preservation manifest: {e}"))?;
        if preservation.get("capture_run_id").and_then(Value::as_str) != Some(run_id.as_str()) {
            return Err("preservation capture run ID differs from segment ledger".into());
        }
        let files = preservation
            .get("files")
            .and_then(Value::as_array)
            .ok_or_else(|| "preservation manifest has no frozen file list".to_string())?;
        for item in files {
            let path = item
                .get("path")
                .and_then(Value::as_str)
                .ok_or_else(|| "invalid preservation file path".to_string())?;
            if path.starts_with('/') || path.split('/').any(|part| part == ".." || part.is_empty())
            {
                return Err("unsafe path in preservation manifest".into());
            }
            let bytes = item
                .get("bytes")
                .and_then(Value::as_u64)
                .ok_or_else(|| "invalid preserved byte count".to_string())?;
            let sha256 = item
                .get("sha256")
                .and_then(Value::as_str)
                .filter(|hash| hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()))
                .ok_or_else(|| "invalid preserved SHA-256".to_string())?
                .to_owned();
            if frozen
                .insert(path.to_owned(), FrozenFile { bytes, sha256 })
                .is_some()
            {
                return Err("duplicate path in preservation manifest".into());
            }
        }
        let ledger_relative = relative_to_capture(&capture_root, &ledger_path)?;
        check_frozen_file(
            &capture_root,
            &ledger_relative,
            &frozen,
            Some((ledger_bytes, format!("{:x}", digest.finalize()))),
        )?;
        let run_path = capture_root.join("run.json");
        if run_path.exists() {
            let run_relative = relative_to_capture(&capture_root, &run_path)?;
            let run_bytes = read_bounded_file(&run_path, 1024 * 1024)?;
            let run: Value = serde_json::from_slice(&run_bytes)
                .map_err(|e| format!("decode run metadata: {e}"))?;
            if run
                .get("capture_run_id")
                .and_then(Value::as_str)
                .is_some_and(|id| id != run_id)
            {
                return Err("run metadata capture ID differs from preservation manifest".into());
            }
            hz = run.get("hz").and_then(Value::as_u64);
            check_frozen_file(&capture_root, &run_relative, &frozen, None)?;
        }
        let total = segments
            .iter()
            .try_fold(0_u64, |sum, part| sum.checked_add(part.count))
            .ok_or_else(|| "capture sample count overflow".to_string())?;
        if preservation.get("segments").and_then(Value::as_u64) != Some(segments.len() as u64)
            || preservation.get("actual_samples").and_then(Value::as_u64) != Some(total)
        {
            return Err("preservation counts differ from segment ledger".into());
        }
    } else {
        let run_path = capture_root.join("run.json");
        if run_path.exists() {
            let run: Value = serde_json::from_slice(&read_bounded_file(&run_path, 1024 * 1024)?)
                .map_err(|e| format!("decode run metadata: {e}"))?;
            if run
                .get("capture_run_id")
                .and_then(Value::as_str)
                .is_some_and(|id| id != run_id)
            {
                return Err("run metadata capture ID differs from segment ledger".into());
            }
            hz = run.get("hz").and_then(Value::as_u64);
        }
    }
    let paths = segments
        .iter()
        .map(|part| source_root.join(&part.path))
        .collect::<Vec<_>>();
    let mut discovered = Vec::new();
    collect_sources(&source_root, &mut discovered)?;
    let mut expected = paths.clone();
    discovered.sort();
    expected.sort();
    if discovered != expected {
        return Err("capture contains missing or unclaimed source segments".into());
    }
    let claimed = paths.iter().cloned().collect::<HashSet<_>>();
    reject_unclaimed_capture_artifacts(&source_root, &claimed)?;
    for (part, path) in segments.iter().zip(&paths) {
        let relative = relative_to_capture(&capture_root, path)?;
        let (bytes, hash) = hash_source_file(path)?;
        if part
            .source_sha256
            .as_deref()
            .is_some_and(|expected| expected != hash)
        {
            return Err(format!(
                "source hash differs from ledger: {}",
                path.display()
            ));
        }
        if !frozen.is_empty() {
            check_frozen_file(&capture_root, &relative, &frozen, Some((bytes, hash)))?;
        }
    }
    Ok(Some(CaptureLedger {
        root: capture_root,
        source_root,
        run_id,
        hz,
        segments,
        frozen,
    }))
}

fn reject_unclaimed_capture_artifacts(root: &Path, claimed: &HashSet<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(root).map_err(|e| format!("list capture source root: {e}"))? {
        let entry = entry.map_err(|e| format!("read capture source entry: {e}"))?;
        let path = entry.path();
        let metadata =
            fs::symlink_metadata(&path).map_err(|e| format!("inspect capture artifact: {e}"))?;
        if metadata.file_type().is_symlink() {
            return Err("capture source tree contains a symlink".into());
        }
        if metadata.is_dir() {
            reject_unclaimed_capture_artifacts(&path, claimed)?;
            continue;
        }
        let name = entry.file_name();
        let source_like = name == "source.jsonl"
            || name == "source.jsonl.zst"
            || name.to_string_lossy().starts_with("source-");
        if source_like && !claimed.contains(&path) {
            return Err(format!(
                "unclaimed capture source artifact: {}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn read_bounded_file(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|e| format!("inspect metadata {}: {e}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() > limit {
        return Err(format!(
            "unsafe or oversized metadata file: {}",
            path.display()
        ));
    }
    let mut open = OpenOptions::new();
    open.read(true);
    #[cfg(unix)]
    open.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let file = open
        .open(path)
        .map_err(|e| format!("open metadata {}: {e}", path.display()))?;
    let after = file
        .metadata()
        .map_err(|e| format!("stat metadata {}: {e}", path.display()))?;
    if !after.is_file() || after.len() != metadata.len() {
        return Err("metadata changed during open".into());
    }
    let mut bytes = Vec::with_capacity(after.len() as usize);
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("read metadata {}: {e}", path.display()))?;
    if bytes.len() as u64 > limit {
        return Err("metadata exceeds size limit".into());
    }
    Ok(bytes)
}
fn relative_to_capture(root: &Path, path: &Path) -> Result<String> {
    path.strip_prefix(root)
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .map_err(|_| format!("capture path escapes root: {}", path.display()))
}
fn hash_source_file(path: &Path) -> Result<(u64, String)> {
    let metadata =
        fs::symlink_metadata(path).map_err(|e| format!("inspect source segment: {e}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("source segment is not a regular file".into());
    }
    let mut open = OpenOptions::new();
    open.read(true);
    #[cfg(unix)]
    open.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let mut file = open
        .open(path)
        .map_err(|e| format!("open source segment: {e}"))?;
    let opened = file
        .metadata()
        .map_err(|e| format!("stat source segment: {e}"))?;
    if !opened.is_file() || opened.len() != metadata.len() {
        return Err("source segment changed during open".into());
    }
    let mut digest = Sha256::new();
    let mut total = 0_u64;
    let mut buffer = [0u8; 65536];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|e| format!("hash source segment: {e}"))?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
        total = total
            .checked_add(count as u64)
            .ok_or_else(|| "source size overflow".to_string())?;
    }
    if total != opened.len() {
        return Err("source segment changed while hashing".into());
    }
    Ok((total, format!("{:x}", digest.finalize())))
}
fn check_frozen_file(
    root: &Path,
    relative: &str,
    frozen: &HashMap<String, FrozenFile>,
    actual: Option<(u64, String)>,
) -> Result<()> {
    let expected = frozen
        .get(relative)
        .ok_or_else(|| format!("file absent from preservation manifest: {relative}"))?;
    let actual = match actual {
        Some(actual) => actual,
        None => hash_source_file(&root.join(relative))?,
    };
    if actual.0 != expected.bytes || actual.1 != expected.sha256 {
        return Err(format!("preserved source digest mismatch: {relative}"));
    }
    Ok(())
}
fn capture_ledger_for_inputs(inputs: &[PathBuf]) -> Result<Option<CaptureLedger>> {
    let Some(first) = inputs.first() else {
        return Ok(None);
    };
    let parent = first.parent().unwrap_or(Path::new("."));
    if !parent.join("segments.jsonl").exists() {
        return Ok(None);
    }
    let Some(mut ledger) = load_capture_ledger(parent)? else {
        return Ok(None);
    };
    let expected = ledger
        .segments
        .iter()
        .map(|part| ledger.source_root.join(&part.path))
        .collect::<Vec<_>>();
    let offset = expected
        .windows(inputs.len())
        .position(|window| window == inputs)
        .ok_or_else(|| {
            "transform inputs must be a contiguous ordered capture-ledger subset".to_string()
        })?;
    let end = offset + inputs.len();
    ledger.segments = ledger.segments[offset..end].to_vec();
    Ok(Some(ledger))
}
fn verify_capture_source_hash(ledger: &CaptureLedger, index: usize, path: &Path) -> Result<()> {
    let part = ledger
        .segments
        .get(index)
        .ok_or_else(|| "capture segment index out of range".to_string())?;
    if path != ledger.source_root.join(&part.path) {
        return Err("source path differs from capture ledger".into());
    }
    let (bytes, hash) = hash_source_file(path)?;
    if part
        .source_sha256
        .as_deref()
        .is_some_and(|expected| expected != hash)
    {
        return Err(format!(
            "source hash differs from ledger: {}",
            path.display()
        ));
    }
    let relative = relative_to_capture(&ledger.root, path)?;
    if let Some(expected) = ledger.frozen.get(&relative)
        && (expected.bytes != bytes || expected.sha256 != hash)
    {
        return Err(format!("preserved source digest mismatch: {relative}"));
    }
    Ok(())
}
fn verify_capture_segment(
    ledger: &CaptureLedger,
    index: usize,
    path: &Path,
    stats: &source::SourceStats,
) -> Result<String> {
    let part = ledger
        .segments
        .get(index)
        .ok_or_else(|| "capture segment index out of range".to_string())?;
    if path != ledger.source_root.join(&part.path)
        || stats.context.capture_run_id.as_deref() != Some(&ledger.run_id)
        || ledger.hz.is_some_and(|hz| hz != stats.context.hz)
        || stats.scans != part.count
        || stats.first_seq != Some(part.seq_range[0])
        || stats.last_seq != Some(part.seq_range[1])
        || stats.first_scan_start_ns != Some(part.time_range_ns[0])
        || stats.last_scan_start_ns != Some(part.time_range_ns[1])
    {
        return Err(format!(
            "source segment disagrees with capture ledger: {}",
            path.display()
        ));
    }
    if part
        .expanded_sha256
        .as_deref()
        .is_some_and(|hash| hash != stats.expanded_sha256)
    {
        return Err(format!(
            "expanded source hash differs from ledger: {}",
            path.display()
        ));
    }
    verify_capture_source_hash(ledger, index, path)?;
    Ok(hash_source_file(path)?.1)
}
fn checked_segment_line(
    ledger: &CaptureLedger,
    index: usize,
    path: &Path,
    source: &source::SourceStats,
    compressed_hash: &str,
) -> Result<Vec<u8>> {
    let part = &ledger.segments[index];
    let value = json!({"segment_index":part.segment_index,"path":relative_to_capture(&ledger.root,path)?,
        "capture_run_id":ledger.run_id,"source_sha256":compressed_hash,"source_bytes":source.input_bytes,
        "expanded_sha256":source.expanded_sha256,"expanded_bytes":source.expanded_bytes,
        "scans":source.scans,"readings":source.readings,
        "seq_range":[source.first_seq,source.last_seq],
        "time_range_ns":[source.first_scan_start_ns,source.last_scan_start_ns]});
    let mut bytes =
        serde_json::to_vec(&value).map_err(|e| format!("encode checked segment: {e}"))?;
    bytes.push(b'\n');
    Ok(bytes)
}

/// Collect lexically ordered source shards from a frozen capture source directory or a file.
pub fn source_files(input: &Path) -> Result<Vec<PathBuf>> {
    let meta = fs::symlink_metadata(input).map_err(|e| format!("inspect source input: {e}"))?;
    if meta.file_type().is_symlink() {
        return Err("source input must not be a symlink".into());
    }
    if meta.is_file() {
        return Ok(vec![input.to_path_buf()]);
    }
    if !meta.is_dir() {
        return Err("source input must be a regular file or directory".into());
    }
    if let Some(ledger) = load_capture_ledger(input)? {
        return Ok(ledger
            .segments
            .iter()
            .map(|segment| ledger.source_root.join(&segment.path))
            .collect());
    }
    let source_root = capture_source_root(input);
    let mut files = Vec::new();
    collect_sources(&source_root, &mut files)?;
    files.sort_by(|a, b| {
        let index = |path: &Path| {
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                return u64::MAX;
            };
            if name == "source.jsonl" || name == "source.jsonl.zst" {
                return 0;
            }
            name.strip_prefix("source-")
                .and_then(|name| name.split('-').next())
                .and_then(|digits| digits.parse::<u64>().ok())
                .unwrap_or(u64::MAX)
        };
        index(a).cmp(&index(b)).then_with(|| a.cmp(b))
    });
    files.dedup();
    if files.is_empty() {
        return Err(format!(
            "no source-*.jsonl[.zst] files under {}",
            source_root.display()
        ));
    }
    Ok(files)
}
fn collect_sources(root: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(root).map_err(|e| format!("list source directory: {e}"))? {
        let entry = entry.map_err(|e| format!("read source directory entry: {e}"))?;
        let path = entry.path();
        let meta = fs::symlink_metadata(&path).map_err(|e| format!("inspect source entry: {e}"))?;
        if meta.file_type().is_symlink() {
            return Err(format!("source tree contains symlink: {}", path.display()));
        }
        if meta.is_dir() {
            collect_sources(&path, out)?;
            continue;
        }
        if !meta.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == "source.jsonl"
            || name == "source.jsonl.zst"
            || name.starts_with("source-")
                && (name.ends_with(".jsonl") || name.ends_with(".jsonl.zst"))
        {
            out.push(path);
        }
    }
    Ok(())
}

pub fn default_record_options(output: PathBuf) -> RecordOptions {
    RecordOptions {
        output,
        duration: None,
        hz: 10,
        profile: Profile::Adaptive,
        format: OutputFormat::Binary,
        frame_bytes: DEFAULT_FRAME_BYTES,
        max_bytes: DEFAULT_MAX_BYTES,
        min_free_bytes: DEFAULT_MIN_FREE_BYTES,
        block_rows: DEFAULT_BLOCK_ROWS,
        verify: false,
        memory: MemoryEncoding::default(),
    }
}

/// Same-source encode/decode benchmark with a lightweight retained-value fidelity audit.
pub fn benchmark_sources(
    inputs: &[PathBuf],
    profile: Profile,
    legacy_timebase: Option<Timebase>,
    frame_bytes: usize,
) -> Result<RunStats> {
    benchmark_sources_with_memory(
        inputs,
        profile,
        legacy_timebase,
        frame_bytes,
        MemoryEncoding::default(),
    )
}

/// Benchmark source transformation with the selected memory columns and precision.
pub fn benchmark_sources_with_memory(
    inputs: &[PathBuf],
    profile: Profile,
    legacy_timebase: Option<Timebase>,
    frame_bytes: usize,
    memory: MemoryEncoding,
) -> Result<RunStats> {
    if inputs.is_empty() {
        return Err("benchmark needs at least one source file".into());
    }
    memory.validate()?;
    let start = Instant::now();
    let before = usage();
    let mut options = default_record_options(PathBuf::new());
    options.profile = profile;
    options.memory = memory;
    let mut stats = RunStats {
        verification_enabled: true,
        ..RunStats::default()
    };
    let mut validator = Validator::new(false);
    let mut codec = CodecFrameAccumulator::new(frame_bytes)?;
    let mut current_context: Option<Context> = None;
    let mut builder: Option<BlockBuilder> = None;
    for input in inputs {
        let source_stats = source::visit_source(input, legacy_timebase, |context, mut row| {
            if current_context.as_ref() != Some(context) {
                if let Some(old) = builder.as_mut() {
                    benchmark_block(old, profile, &options.memory, &mut stats, &mut codec)?;
                }
                current_context = Some(context.clone());
                builder = Some(BlockBuilder::new(context));
            }
            let flagged = validator.validate(&mut row)?;
            stats.scans = stats.scans.saturating_add(1);
            stats.readings = stats.readings.saturating_add(row.processes.len() as u64);
            stats.flagged_events = stats
                .flagged_events
                .saturating_add(row.quality.len() as u64);
            let block = builder
                .as_mut()
                .ok_or_else(|| "benchmark block not initialized".to_string())?;
            if block.should_cut(context, &row, &options) || flagged {
                benchmark_block(block, profile, &options.memory, &mut stats, &mut codec)?;
            }
            block.push(row);
            Ok(())
        })?;
        stats.source_hashes.push(SourceHashStats {
            path: input.to_string_lossy().into_owned(),
            scans: source_stats.scans,
            readings: source_stats.readings,
            input_bytes: source_stats.input_bytes,
            expanded_bytes: source_stats.expanded_bytes,
            expanded_sha256: source_stats.expanded_sha256,
            first_seq: source_stats.first_seq,
            last_seq: source_stats.last_seq,
            first_scan_start_ns: source_stats.first_scan_start_ns,
            last_scan_start_ns: source_stats.last_scan_start_ns,
        });
    }
    if let Some(block) = builder.as_mut() {
        benchmark_block(block, profile, &options.memory, &mut stats, &mut codec)?;
    }
    codec.finish()?;
    stats.codec_input_bytes = codec.input_bytes;
    stats.codec_compressed_bytes = codec.compressed_bytes;
    stats.codec_encoder_cpu_seconds = codec.encoder_cpu_seconds;
    stats.codec_encoder_wall_seconds = codec.encoder_wall_seconds;
    stats.codec_frames = codec.frames;
    stats.codec_repeats = codec.repeats;
    stats.codec_max_input_bytes = codec.max_input_bytes;
    finish_metrics(&mut stats, start, before);
    Ok(stats)
}

fn benchmark_block(
    builder: &mut BlockBuilder,
    profile: Profile,
    memory: &MemoryEncoding,
    stats: &mut RunStats,
    codec: &mut CodecFrameAccumulator,
) -> Result<()> {
    if builder.is_empty() {
        return Ok(());
    }
    let bytes = encode_block_with_memory(&builder.context, &builder.rows, profile, memory.clone())?;
    audit_source_block(
        &builder.context,
        &builder.rows,
        profile,
        memory,
        &bytes,
        stats,
    )?;
    codec.push(&bytes)?;
    stats.blocks = stats.blocks.saturating_add(1);
    stats.raw_encoded_bytes = stats.raw_encoded_bytes.saturating_add(bytes.len() as u64);
    builder.rows.clear();
    builder.points = 0;
    Ok(())
}

fn audit_source_block(
    context: &Context,
    rows: &[Observation],
    profile: Profile,
    memory: &MemoryEncoding,
    bytes: &[u8],
    stats: &mut RunStats,
) -> Result<()> {
    let decoded = super::wire::decode_block(bytes)?;
    // PST1 predates run/header provenance; that context belongs to the archive,
    // not the byte-parity control block. Its CPU timebase is still retained.
    if decoded.profile != profile
        || decoded.context.cpu_timebase != context.cpu_timebase
        || (profile != Profile::Legacy1ms && decoded.context != *context)
    {
        stats.precision_violations += 1;
    }
    if decoded.rows.len() != rows.len() {
        stats.precision_violations += 1;
    }
    if profile != Profile::Legacy1ms {
        let available_columns = [
            MemoryColumn::Owned,
            MemoryColumn::Peak,
            MemoryColumn::Evicted,
        ]
        .into_iter()
        .filter(|column| {
            memory.columns.contains(column)
                && rows
                    .iter()
                    .flat_map(|row| &row.processes)
                    .any(|process| match column {
                        MemoryColumn::Owned => process.owned.is_some(),
                        MemoryColumn::Peak => process.peak.is_some(),
                        MemoryColumn::Evicted => process.evicted.is_some(),
                    })
        })
        .collect::<Vec<_>>();
        let expected_memory = (!available_columns.is_empty()).then_some(MemoryEncoding {
            columns: available_columns,
            unit_bytes: memory.unit_bytes,
        });
        if decoded.memory != expected_memory {
            stats.precision_violations += 1;
        }
    }
    let mut prior: HashMap<super::model::Identity, (u64, u64)> = HashMap::new();
    let mut endpoints: HashMap<super::model::Identity, (u64, u64, u64, u64)> = HashMap::new();
    for (row, decoded_row) in rows.iter().zip(&decoded.rows) {
        if row.seq != decoded_row.seq
            || row.wall_start_ns != decoded_row.wall_start_ns
            || row.scan_start_ns != decoded_row.scan_start_ns
            || row.scan_end_ns != decoded_row.scan_end_ns
            || row.quality != decoded_row.quality
            || row.processes.len() != decoded_row.processes.len()
        {
            stats.precision_violations += 1;
        }
        let mut actuals: Vec<_> = row.processes.iter().collect();
        let mut restored: Vec<_> = decoded_row.processes.iter().collect();
        if !actuals
            .windows(2)
            .all(|pair| pair[0].identity() <= pair[1].identity())
        {
            actuals.sort_by_key(|process| process.identity());
        }
        if !restored
            .windows(2)
            .all(|pair| pair[0].identity() <= pair[1].identity())
        {
            restored.sort_by_key(|process| process.identity());
        }
        for (process, decoded_process) in actuals.into_iter().zip(restored) {
            let id = process.identity();
            if id != decoded_process.identity() {
                stats.precision_violations += 1;
                continue;
            }
            if process.name != decoded_process.name || process.ppid != decoded_process.ppid {
                stats.precision_violations += 1;
            }
            if profile != Profile::Legacy1ms {
                let expected = |column, value: Option<u64>| {
                    if memory.columns.contains(&column) {
                        value.map(|bytes| bytes / memory.unit_bytes * memory.unit_bytes)
                    } else {
                        None
                    }
                };
                if decoded_process.owned != expected(MemoryColumn::Owned, process.owned)
                    || decoded_process.peak != expected(MemoryColumn::Peak, process.peak)
                    || decoded_process.evicted != expected(MemoryColumn::Evicted, process.evicted)
                {
                    stats.precision_violations += 1;
                }
            }
            let actual = process.total()?;
            let decoded_total = decoded_process.cpu_total;
            if actual < decoded_total
                || actual.abs_diff(decoded_total) > decoded_process.cpu_error_bound
            {
                stats.precision_violations += 1;
            }
            let expected_rss = process.rss / super::model::RSS_QUANTUM * super::model::RSS_QUANTUM;
            if decoded_process.rss != expected_rss {
                stats.rss_floor_violations += 1;
            }
            if decoded_process.components.is_some() {
                stats.precision_violations += 1;
            }
            if let Some((previous_actual, previous_decoded)) = prior.get(&id) {
                let actual_delta = actual.checked_sub(*previous_actual);
                let decoded_delta = decoded_total.checked_sub(*previous_decoded);
                let (Some(actual_delta), Some(decoded_delta)) = (actual_delta, decoded_delta)
                else {
                    stats.precision_violations += 1;
                    prior.insert(id, (actual, decoded_total));
                    endpoints
                        .entry(id)
                        .and_modify(|state| {
                            state.2 = actual;
                            state.3 = decoded_total;
                        })
                        .or_insert((actual, decoded_total, actual, decoded_total));
                    continue;
                };
                if actual_delta > 0 && decoded_delta == 0 {
                    stats.positive_intervals_lost += 1;
                }
                if profile == Profile::Adaptive
                    && ((actual_delta == 0) != (decoded_delta == 0)
                        || actual_delta > 0
                            && 8u128 * u128::from(actual_delta.abs_diff(decoded_delta))
                                >= u128::from(actual_delta))
                {
                    stats.precision_violations += 1;
                }
            }
            prior.insert(id, (actual, decoded_total));
            endpoints
                .entry(id)
                .and_modify(|state| {
                    state.2 = actual;
                    state.3 = decoded_total;
                })
                .or_insert((actual, decoded_total, actual, decoded_total));
        }
    }
    for (first_actual, first_decoded, last_actual, last_decoded) in endpoints.values() {
        if first_actual != first_decoded {
            stats.endpoint_mismatches += 1;
        }
        if last_actual != last_decoded {
            stats.endpoint_mismatches += 1;
        }
    }
    Ok(())
}
