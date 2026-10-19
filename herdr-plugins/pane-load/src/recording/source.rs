//! Streaming JSONL source and lossless raw-reference writer.
use super::model::{Context, MAX_BLOCK_BYTES, MAX_POINTS, Observation, Process, Result, Timebase};
use serde::de::{self, IgnoredAny, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::marker::PhantomData;
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SourceStats {
    pub scans: u64,
    pub readings: u64,
    /// Compressed/plain source file length from its filesystem metadata.
    pub input_bytes: u64,
    /// Exact number of bytes in the decompressed JSONL stream.
    pub expanded_bytes: u64,
    /// SHA-256 of the exact expanded stream, including all original line endings.
    pub expanded_sha256: String,
    pub first_seq: Option<u64>,
    pub last_seq: Option<u64>,
    pub first_scan_start_ns: Option<u64>,
    pub last_scan_start_ns: Option<u64>,
    pub context: Context,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyRow {
    seq: u64,
    wall_start_ns: i64,
    scan_start_ns: u64,
    scan_end_ns: u64,
    processes: BoundedVec<LegacyProcess>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRow {
    seq: u64,
    wall_start_ns: i64,
    scan_start_ns: u64,
    scan_end_ns: u64,
    processes: BoundedVec<RawProcess>,
    quality: Vec<Value>,
}

#[derive(Deserialize)]
struct LegacyProcess(u32, u32, u64, u32, String, u64, u64, u64);

#[derive(Deserialize)]
#[serde(untagged)]
#[allow(clippy::type_complexity)] // Positional raw JSONL wire tuples.
enum RawProcess {
    Plain((u32, u32, u64, u32, String, u64, u64, u64)),
    Memory(
        (
            u32,
            u32,
            u64,
            u32,
            String,
            u64,
            u64,
            u64,
            Option<u64>,
            Option<u64>,
            Option<u64>,
        ),
    ),
}

impl RawProcess {
    fn into_process(self) -> Process {
        let (pid, ppid, start_sec, start_usec, name, user, system, rss, owned, peak, evicted) =
            match self {
                Self::Plain((pid, ppid, sec, usec, name, user, system, rss)) => (
                    pid, ppid, sec, usec, name, user, system, rss, None, None, None,
                ),
                Self::Memory(fields) => fields,
            };
        Process {
            pid,
            ppid,
            start_sec,
            start_usec,
            name,
            user,
            system,
            rss,
            owned,
            peak,
            evicted,
        }
    }
}

struct BoundedVec<T>(Vec<T>);

impl<'de, T: Deserialize<'de>> Deserialize<'de> for BoundedVec<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        struct BoundedVisitor<T>(PhantomData<T>);

        impl<'de, T: Deserialize<'de>> Visitor<'de> for BoundedVisitor<T> {
            type Value = BoundedVec<T>;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(formatter, "an array of at most {MAX_POINTS} processes")
            }

            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut sequence: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let capacity = sequence.size_hint().unwrap_or(0).min(MAX_POINTS);
                let mut values = Vec::with_capacity(capacity);
                loop {
                    if values.len() == MAX_POINTS {
                        return match sequence.next_element::<IgnoredAny>()? {
                            Some(_) => Err(de::Error::custom(format!(
                                "process count exceeds {MAX_POINTS}"
                            ))),
                            None => Ok(BoundedVec(values)),
                        };
                    }
                    match sequence.next_element()? {
                        Some(value) => values.push(value),
                        None => return Ok(BoundedVec(values)),
                    }
                }
            }
        }

        deserializer.deserialize_seq(BoundedVisitor(PhantomData))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ContextWire {
    hz: u64,
    capture_run_id: Option<String>,
    boot_id: Option<String>,
    clock: String,
    cpu_timebase: Timebase,
    #[serde(default)]
    source_headers: Vec<Value>,
}

#[derive(Clone, Copy)]
enum Format {
    Legacy(Timebase),
    Raw,
}

/// Stream a single plain or zstd-compressed JSONL file, validating and visiting each row.
/// The first physical line is a `probe_capture: 1` legacy header or a
/// `recording_source: 1` raw-reference header. Legacy normalized CPU values require an
/// explicitly declared source timebase or `legacy_timebase`; the local host is never used.
pub fn visit_source(
    path: &Path,
    legacy_timebase: Option<Timebase>,
    mut callback: impl FnMut(&Context, Observation) -> Result<()>,
) -> Result<SourceStats> {
    let metadata =
        fs::symlink_metadata(path).map_err(|e| format!("stat source {}: {e}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!(
            "source is not a regular non-symlink file: {}",
            path.display()
        ));
    }
    let file = open_source(path).map_err(|e| format!("open source {}: {e}", path.display()))?;
    let metadata = file
        .metadata()
        .map_err(|e| format!("stat opened source {}: {e}", path.display()))?;
    if !metadata.is_file() {
        return Err(format!("source is not a regular file: {}", path.display()));
    }
    let input_bytes = metadata.len();
    let is_zstd = path.extension().and_then(|s| s.to_str()) == Some("zst");
    let mut reader: Box<dyn BufRead> = if is_zstd {
        let decoder = zstd::stream::read::Decoder::new(file)
            .map_err(|e| format!("open zstd source {}: {e}", path.display()))?;
        Box::new(BufReader::new(decoder))
    } else {
        Box::new(BufReader::new(file))
    };

    let mut hasher = Sha256::new();
    let mut expanded_bytes = 0u64;
    let header_line = read_bounded_line(&mut *reader)?
        .ok_or_else(|| "source is empty; expected one JSONL header".to_string())?;
    account_bytes(&mut hasher, &mut expanded_bytes, &header_line)?;
    let header_value = parse_json_line(&header_line, "source header")?;
    let (mut context, format) = parse_header(&header_value, legacy_timebase)?;
    // Native reference headers already contain the exact canonical Context. Adding
    // that wrapper back into it would break live/replay parity and recursively nest
    // provenance on every raw round trip.
    if matches!(format, Format::Legacy(_)) {
        context.source_headers.push(header_value);
    }

    let mut stats = SourceStats {
        scans: 0,
        readings: 0,
        input_bytes,
        expanded_bytes: 0,
        expanded_sha256: String::new(),
        first_seq: None,
        last_seq: None,
        first_scan_start_ns: None,
        last_scan_start_ns: None,
        context,
    };
    let mut previous_seq = None;
    let mut previous_scan_start = None;

    while let Some(line) = read_bounded_line(&mut *reader)? {
        account_bytes(&mut hasher, &mut expanded_bytes, &line)?;
        let mut observation = match format {
            Format::Legacy(timebase) => parse_legacy_row(&line, timebase)?,
            Format::Raw => parse_raw_row(&line)?,
        };
        observation.validate()?;
        if previous_seq.is_some_and(|previous| observation.seq <= previous) {
            return Err("source sequence numbers must increase strictly".into());
        }
        if previous_scan_start.is_some_and(|previous| observation.scan_start_ns <= previous) {
            return Err("source scan_start_ns values must increase strictly".into());
        }
        previous_seq = Some(observation.seq);
        previous_scan_start = Some(observation.scan_start_ns);

        observation.processes.sort_by_key(Process::identity);
        stats.readings = stats
            .readings
            .checked_add(observation.processes.len() as u64)
            .ok_or_else(|| "source reading count overflow".to_string())?;
        stats.scans = stats
            .scans
            .checked_add(1)
            .ok_or_else(|| "source scan count overflow".to_string())?;
        if stats.first_seq.is_none() {
            stats.first_seq = Some(observation.seq);
            stats.first_scan_start_ns = Some(observation.scan_start_ns);
        }
        stats.last_seq = Some(observation.seq);
        stats.last_scan_start_ns = Some(observation.scan_start_ns);
        callback(&stats.context, observation)?;
    }

    stats.expanded_bytes = expanded_bytes;
    stats.expanded_sha256 = format!("{:x}", hasher.finalize());
    Ok(stats)
}

fn parse_header(value: &Value, legacy_timebase: Option<Timebase>) -> Result<(Context, Format)> {
    let object = value
        .as_object()
        .ok_or_else(|| "source header must be a JSON object".to_string())?;
    if let Some(version) = object.get("recording_source") {
        if version.as_u64() != Some(1) {
            return Err(format!("unsupported recording_source version: {version}"));
        }
        if object.get("cpu_unit").and_then(Value::as_str) != Some("native_ticks") {
            return Err("raw source header requires cpu_unit 'native_ticks'".into());
        }
        let context_value = object
            .get("context")
            .ok_or_else(|| "raw source header is missing context".to_string())?;
        let wire: ContextWire = serde_json::from_value(context_value.clone())
            .map_err(|e| format!("invalid raw source context: {e}"))?;
        let context = Context {
            hz: wire.hz,
            capture_run_id: wire.capture_run_id,
            boot_id: wire.boot_id,
            clock: wire.clock,
            cpu_timebase: wire.cpu_timebase,
            source_headers: wire.source_headers,
        };
        validate_context(&context).map_err(|e| format!("invalid raw source context: {e}"))?;
        Ok((context, Format::Raw))
    } else if let Some(version) = object.get("probe_capture") {
        if version.as_u64() != Some(1) {
            return Err(format!("unsupported probe_capture version: {version}"));
        }
        let hz = object
            .get("hz")
            .and_then(Value::as_u64)
            .filter(|hz| (1..=1000).contains(hz))
            .ok_or_else(|| "legacy capture header requires integer hz in 1..=1000".to_string())?;
        let declared_timebase = legacy_header_timebase(object)?;
        if let (Some(option), Some(declared)) = (legacy_timebase, declared_timebase) {
            option.validate()?;
            if option != declared {
                return Err("legacy_timebase conflicts with the source header CPU timebase".into());
            }
        }
        let timebase = legacy_timebase.or(declared_timebase).ok_or_else(|| {
            "legacy CPU fields are normalized nanoseconds, but the source declares no CPU timebase; pass an explicit legacy_timebase (never inferred from this host)".to_string()
        })?;
        timebase.validate()?;
        if timebase.numer < timebase.denom {
            return Err("legacy normalized CPU values cannot be restored exactly with a non-injective source timebase".into());
        }
        let mut context = Context::new(timebase);
        context.hz = hz;
        context.capture_run_id = header_optional_string(object, "capture_run_id")?;
        context.boot_id = header_optional_string(object, "boot_id")?;
        if let Some(clock) = object.get("clock") {
            context.clock = clock
                .as_str()
                .ok_or_else(|| "legacy capture clock metadata must be a string".to_string())?
                .to_owned();
        }
        validate_context(&context)?;
        Ok((context, Format::Legacy(timebase)))
    } else {
        Err("unsupported source header: expected recording_source: 1 or probe_capture: 1".into())
    }
}

fn validate_context(context: &Context) -> Result<()> {
    context.validate()?;
    if context.clock.trim().is_empty() {
        return Err("source clock metadata must not be empty".into());
    }
    Ok(())
}

fn header_optional_string(object: &Map<String, Value>, key: &str) -> Result<Option<String>> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(format!(
            "legacy capture metadata {key} must be a string or null"
        )),
    }
}

fn legacy_header_timebase(object: &Map<String, Value>) -> Result<Option<Timebase>> {
    let mut found = None;
    for (key, pair) in [("cpu_timebase", false), ("cpu_timebase_mach", true)] {
        let Some(value) = object.get(key) else {
            continue;
        };
        let timebase = if pair {
            parse_timebase_pair(value, key)?
        } else {
            parse_timebase(value, key)?
        };
        timebase.validate()?;
        if found.is_some_and(|previous| previous != timebase) {
            return Err("legacy source header declares conflicting CPU timebases".into());
        }
        found = Some(timebase);
    }
    Ok(found)
}

fn parse_timebase(value: &Value, label: &str) -> Result<Timebase> {
    if let Some(pair) = value.as_array() {
        if pair.len() != 2 {
            return Err(format!("{label} must contain numerator and denominator"));
        }
        return Ok(Timebase {
            numer: pair[0]
                .as_u64()
                .ok_or_else(|| format!("{label} numerator must be a positive integer"))?,
            denom: pair[1]
                .as_u64()
                .ok_or_else(|| format!("{label} denominator must be a positive integer"))?,
        });
    }
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Pair {
        numer: u64,
        denom: u64,
    }
    let pair: Pair =
        serde_json::from_value(value.clone()).map_err(|e| format!("invalid {label}: {e}"))?;
    Ok(Timebase {
        numer: pair.numer,
        denom: pair.denom,
    })
}

fn parse_timebase_pair(value: &Value, label: &str) -> Result<Timebase> {
    let pair = value
        .as_array()
        .filter(|pair| pair.len() == 2)
        .ok_or_else(|| format!("{label} must be a [numerator, denominator] array"))?;
    Ok(Timebase {
        numer: pair[0]
            .as_u64()
            .ok_or_else(|| format!("{label} numerator must be a positive integer"))?,
        denom: pair[1]
            .as_u64()
            .ok_or_else(|| format!("{label} denominator must be a positive integer"))?,
    })
}

fn parse_legacy_row(line: &[u8], timebase: Timebase) -> Result<Observation> {
    let row: LegacyRow = serde_json::from_slice(json_content(line))
        .map_err(|e| format!("invalid legacy capture row: {e}"))?;
    let mut processes = Vec::with_capacity(row.processes.0.len());
    for LegacyProcess(pid, ppid, start_sec, start_usec, name, user_ns, system_ns, rss) in
        row.processes.0
    {
        processes.push(Process {
            pid,
            ppid,
            start_sec,
            start_usec,
            name,
            user: timebase.restore_ns(user_ns)?,
            system: timebase.restore_ns(system_ns)?,
            rss,
            owned: None,
            peak: None,
            evicted: None,
        });
    }
    Ok(Observation {
        seq: row.seq,
        wall_start_ns: row.wall_start_ns,
        scan_start_ns: row.scan_start_ns,
        scan_end_ns: row.scan_end_ns,
        processes,
        quality: Vec::new(),
    })
}

fn parse_raw_row(line: &[u8]) -> Result<Observation> {
    let row: RawRow = serde_json::from_slice(json_content(line))
        .map_err(|e| format!("invalid raw source row: {e}"))?;
    let processes = row
        .processes
        .0
        .into_iter()
        .map(RawProcess::into_process)
        .collect();
    Ok(Observation {
        seq: row.seq,
        wall_start_ns: row.wall_start_ns,
        scan_start_ns: row.scan_start_ns,
        scan_end_ns: row.scan_end_ns,
        processes,
        quality: row.quality,
    })
}

fn json_content(line: &[u8]) -> &[u8] {
    let content = line.strip_suffix(b"\n").unwrap_or(line);
    content.strip_suffix(b"\r").unwrap_or(content)
}

fn parse_json_line(line: &[u8], label: &str) -> Result<Value> {
    serde_json::from_slice(json_content(line)).map_err(|e| format!("invalid {label}: {e}"))
}

fn read_bounded_line(reader: &mut dyn BufRead) -> Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf().map_err(|e| format!("read source: {e}"))?;
        if available.is_empty() {
            return if line.is_empty() {
                Ok(None)
            } else {
                Ok(Some(line))
            };
        }
        let count = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        if line
            .len()
            .checked_add(count)
            .is_none_or(|length| length > MAX_BLOCK_BYTES)
        {
            return Err(format!("source JSONL line exceeds {MAX_BLOCK_BYTES} bytes"));
        }
        let has_newline = available[count - 1] == b'\n';
        line.extend_from_slice(&available[..count]);
        reader.consume(count);
        if has_newline {
            return Ok(Some(line));
        }
    }
}

fn account_bytes(hasher: &mut Sha256, expanded_bytes: &mut u64, bytes: &[u8]) -> Result<()> {
    *expanded_bytes = expanded_bytes
        .checked_add(bytes.len() as u64)
        .ok_or_else(|| "expanded source byte count overflow".to_string())?;
    hasher.update(bytes);
    Ok(())
}

/// Produce the one-line raw-reference header used by [`RawWriter`].
pub fn header_value(context: &Context) -> Result<Value> {
    validate_context(context)?;
    let mut object = Map::new();
    object.insert("recording_source".into(), Value::from(1));
    object.insert("cpu_unit".into(), Value::from("native_ticks"));
    object.insert(
        "context".into(),
        serde_json::to_value(context).map_err(|e| format!("serialize source context: {e}"))?,
    );
    Ok(Value::Object(object))
}

/// Produce a canonical JSON value for one lossless raw-reference observation.
pub fn row_to_value(row: &Observation) -> Result<Value> {
    row.validate()?;
    let mut processes = row.processes.iter().collect::<Vec<_>>();
    processes.sort_by_key(|process| process.identity());
    let processes = processes
        .into_iter()
        .map(|process| {
            let mut fields = vec![
                Value::from(process.pid),
                Value::from(process.ppid),
                Value::from(process.start_sec),
                Value::from(process.start_usec),
                Value::from(process.name.clone()),
                Value::from(process.user),
                Value::from(process.system),
                Value::from(process.rss),
            ];
            if process.owned.is_some() || process.peak.is_some() || process.evicted.is_some() {
                fields.extend([
                    Value::from(process.owned),
                    Value::from(process.peak),
                    Value::from(process.evicted),
                ]);
            }
            Value::Array(fields)
        })
        .collect();
    let mut object = Map::new();
    object.insert("seq".into(), Value::from(row.seq));
    object.insert("wall_start_ns".into(), Value::from(row.wall_start_ns));
    object.insert("scan_start_ns".into(), Value::from(row.scan_start_ns));
    object.insert("scan_end_ns".into(), Value::from(row.scan_end_ns));
    object.insert("processes".into(), Value::Array(processes));
    object.insert(
        "quality".into(),
        serde_json::to_value(&row.quality).map_err(|e| format!("serialize row quality: {e}"))?,
    );
    Ok(Value::Object(object))
}

enum Output {
    Plain(File),
    Zstd(Option<zstd::stream::write::Encoder<'static, File>>),
}

/// Exclusive-create JSONL or zstd JSONL writer. A `.zst` suffix selects zstd.
/// Each checkpoint closes and syncs a complete zstd frame; subsequent writes begin
/// another concatenated frame and never repeat the one physical-file header.
pub struct RawWriter {
    path: std::path::PathBuf,
    parent_path: std::path::PathBuf,
    parent_synced: bool,
    output: Output,
}

impl RawWriter {
    pub fn create(path: &Path, context: &Context) -> Result<Self> {
        let header = header_value(context)?;
        let header_bytes = serialize_json_line(&header, "source header")?;
        let file = open_private_exclusive(path)?;
        let compressed = path.extension().and_then(|s| s.to_str()) == Some("zst");
        let output = if compressed {
            match checksum_encoder(file) {
                Ok(encoder) => Output::Zstd(Some(encoder)),
                Err(error) => {
                    let _ = fs::remove_file(path);
                    return Err(format!("create zstd source writer: {error}"));
                }
            }
        } else {
            Output::Plain(file)
        };
        let parent_path = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf();
        let mut writer = Self {
            path: path.to_path_buf(),
            parent_path,
            parent_synced: false,
            output,
        };
        if let Err(error) = writer.write_bytes(&header_bytes) {
            drop(writer);
            let _ = fs::remove_file(path);
            return Err(error);
        }
        Ok(writer)
    }

    pub fn write(&mut self, row: &Observation) -> Result<()> {
        let value = row_to_value(row)?;
        let bytes = serialize_json_line(&value, "source row")?;
        self.write_bytes(&bytes)
    }

    pub fn checkpoint(&mut self) -> Result<()> {
        match &mut self.output {
            Output::Plain(file) => {
                file.flush().map_err(|e| format!("flush source: {e}"))?;
                file.sync_all().map_err(|e| format!("sync source: {e}"))?;
            }
            Output::Zstd(encoder) => {
                let current = encoder.take().ok_or_else(|| {
                    "zstd source writer is not usable after a failed checkpoint".to_string()
                })?;
                let file = current
                    .finish()
                    .map_err(|e| format!("finish zstd source frame: {e}"))?;
                file.sync_all()
                    .map_err(|e| format!("sync zstd source: {e}"))?;
                *encoder = Some(
                    checksum_encoder(file)
                        .map_err(|e| format!("start next zstd source frame: {e}"))?,
                );
            }
        }
        self.sync_parent_once()
    }

    pub fn finish(mut self) -> Result<()> {
        match &mut self.output {
            Output::Plain(file) => {
                file.flush().map_err(|e| format!("flush source: {e}"))?;
                file.sync_all().map_err(|e| format!("sync source: {e}"))?;
            }
            Output::Zstd(encoder) => {
                let current = encoder
                    .take()
                    .ok_or_else(|| "zstd source writer has no active frame".to_string())?;
                let file = current
                    .finish()
                    .map_err(|e| format!("finish zstd source frame: {e}"))?;
                file.sync_all()
                    .map_err(|e| format!("sync zstd source: {e}"))?;
            }
        }
        self.sync_parent_once()
    }

    fn sync_parent_once(&mut self) -> Result<()> {
        if !self.parent_synced {
            File::open(&self.parent_path)
                .and_then(|directory| directory.sync_all())
                .map_err(|e| {
                    format!("sync source directory {}: {e}", self.parent_path.display())
                })?;
            self.parent_synced = true;
        }
        Ok(())
    }

    fn write_bytes(&mut self, bytes: &[u8]) -> Result<()> {
        match &mut self.output {
            Output::Plain(file) => file
                .write_all(bytes)
                .map_err(|e| format!("write source {}: {e}", self.path.display())),
            Output::Zstd(Some(encoder)) => encoder
                .write_all(bytes)
                .map_err(|e| format!("write zstd source {}: {e}", self.path.display())),
            Output::Zstd(None) => Err("zstd source writer has no active frame".into()),
        }
    }
}

fn open_source(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    options.open(path)
}

fn open_private_exclusive(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let file = options
        .open(path)
        .map_err(|e| format!("create source {} exclusively: {e}", path.display()))?;
    let metadata = file
        .metadata()
        .map_err(|e| format!("stat created source {}: {e}", path.display()))?;
    if !metadata.is_file() {
        return Err(format!(
            "created source is not a regular file: {}",
            path.display()
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err(format!(
                "created source is not owned by the current user: {}",
                path.display()
            ));
        }
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("protect source {}: {e}", path.display()))?;
    }
    Ok(file)
}

struct LimitedVecWriter {
    bytes: Vec<u8>,
}

impl Write for LimitedVecWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let Some(length) = self.bytes.len().checked_add(bytes.len()) else {
            return Err(io::Error::other("serialized JSONL line length overflow"));
        };
        if length > MAX_BLOCK_BYTES {
            return Err(io::Error::other(format!(
                "serialized JSONL line exceeds {MAX_BLOCK_BYTES} bytes"
            )));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn serialize_json_line(value: &Value, label: &str) -> Result<Vec<u8>> {
    let mut writer = LimitedVecWriter { bytes: Vec::new() };
    serde_json::to_writer(&mut writer, value).map_err(|e| format!("serialize {label}: {e}"))?;
    writer
        .write_all(b"\n")
        .map_err(|e| format!("serialize {label}: {e}"))?;
    Ok(writer.bytes)
}

fn checksum_encoder(file: File) -> io::Result<zstd::stream::write::Encoder<'static, File>> {
    let mut encoder = zstd::stream::write::Encoder::new(file, 3)?;
    encoder.include_checksum(true)?;
    Ok(encoder)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let id = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("pane-load-source-{}-{id}", std::process::id()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn path(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn context() -> Context {
        let mut context = Context::new(Timebase {
            numer: 125,
            denom: 3,
        });
        context.hz = 10;
        context.capture_run_id = Some("run-test".into());
        context.boot_id = Some("boot-test".into());
        context.clock = "mach_continuous_time".into();
        context
    }

    fn process(pid: u32, name: &str, user: u64, system: u64) -> Process {
        Process {
            pid,
            ppid: 1,
            start_sec: 42,
            start_usec: pid,
            name: name.into(),
            user,
            system,
            rss: 4096,
            owned: None,
            peak: None,
            evicted: None,
        }
    }

    fn observation(seq: u64, wall: i64, scan: u64, processes: Vec<Process>) -> Observation {
        Observation {
            seq,
            wall_start_ns: wall,
            scan_start_ns: scan,
            scan_end_ns: scan + 5,
            processes,
            quality: vec![serde_json::json!({"kind":"enumeration-warning","count":2})],
        }
    }

    fn legacy_header(timebase: Option<[u64; 2]>) -> Value {
        let mut value =
            serde_json::json!({"probe_capture":1,"hz":10,"capture_run_id":"legacy-run"});
        if let Some([numer, denom]) = timebase {
            value["cpu_timebase_mach"] = serde_json::json!([numer, denom]);
        }
        value
    }

    fn write_jsonl(path: &Path, header: &Value, rows: &[Value], endings: &[&[u8]]) -> Vec<u8> {
        let mut bytes = Vec::new();
        let mut lines = vec![header];
        lines.extend(rows);
        for (index, value) in lines.iter().enumerate() {
            bytes.extend(serde_json::to_vec(value).unwrap());
            if let Some(ending) = endings.get(index) {
                bytes.extend_from_slice(ending);
            }
        }
        fs::write(path, &bytes).unwrap();
        bytes
    }

    #[test]
    fn legacy_import_restores_each_cpu_component_sorts_and_hashes_exact_bytes() {
        let temp = TempDir::new();
        let path = temp.path("legacy.jsonl");
        let rows = [
            serde_json::json!({
                "seq":4,"wall_start_ns":100,"scan_start_ns":10,"scan_end_ns":12,
                "processes":[
                    [9,1,5,9,"nine",2000,3000,8192],
                    [2,1,5,2,"二",1000,0,4096]
                ]
            }),
            serde_json::json!({
                "seq":5,"wall_start_ns":-10,"scan_start_ns":20,"scan_end_ns":20,"processes":[]
            }),
        ];
        let bytes = write_jsonl(
            &path,
            &legacy_header(Some([125, 3])),
            &rows,
            &[b"\r\n", b"\n", b""],
        );
        let mut seen = Vec::new();
        let stats = visit_source(&path, None, |context, row| {
            assert_eq!(context.capture_run_id.as_deref(), Some("legacy-run"));
            seen.push(row);
            Ok(())
        })
        .unwrap();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0].processes[0].pid, 2);
        assert_eq!(seen[0].processes[0].user, 24);
        assert_eq!(seen[0].processes[1].user, 48);
        assert_eq!(seen[0].processes[1].system, 72);
        assert!(seen[1].processes.is_empty());
        assert_eq!(seen[1].wall_start_ns, -10); // wall-clock steps are retained
        assert_eq!(stats.scans, 2);
        assert_eq!(stats.readings, 2);
        assert_eq!(stats.input_bytes, bytes.len() as u64);
        assert_eq!(stats.expanded_bytes, bytes.len() as u64);
        assert_eq!(
            stats.expanded_sha256,
            format!("{:x}", Sha256::digest(&bytes))
        );
        assert_eq!(stats.first_seq, Some(4));
        assert_eq!(stats.last_seq, Some(5));
        assert_eq!(
            stats.context.source_headers,
            vec![legacy_header(Some([125, 3]))]
        );
    }

    #[test]
    fn legacy_import_requires_declared_or_explicit_timebase_and_rejects_conflicts() {
        let temp = TempDir::new();
        let path = temp.path("legacy.jsonl");
        write_jsonl(&path, &legacy_header(None), &[], &[b"\n"]);
        let error = visit_source(&path, None, |_, _| Ok(())).unwrap_err();
        assert!(error.contains("pass an explicit legacy_timebase"));

        let stats = visit_source(
            &path,
            Some(Timebase {
                numer: 125,
                denom: 3,
            }),
            |_, _| Ok(()),
        )
        .unwrap();
        assert_eq!(stats.scans, 0);

        write_jsonl(&path, &legacy_header(Some([125, 3])), &[], &[b"\n"]);
        let error =
            visit_source(&path, Some(Timebase { numer: 1, denom: 1 }), |_, _| Ok(())).unwrap_err();
        assert!(error.contains("conflicts"));
    }

    #[test]
    fn native_writer_roundtrips_quality_and_concatenated_zstd_frames() {
        let temp = TempDir::new();
        let path = temp.path("raw.jsonl.zst");
        let first = observation(
            0,
            300,
            10,
            vec![process(9, "nine", u64::MAX - 3, 3), process(2, "二", 0, 7)],
        );
        let empty = observation(1, 250, 20, vec![]);
        let original_context = context();
        {
            let mut writer = RawWriter::create(&path, &original_context).unwrap();
            writer.write(&first).unwrap();
            writer.checkpoint().unwrap();
            writer.write(&empty).unwrap();
            writer.finish().unwrap();
        }
        let expected = [
            header_value(&context()).unwrap(),
            row_to_value(&first).unwrap(),
            row_to_value(&empty).unwrap(),
        ]
        .iter()
        .flat_map(|value| {
            let mut line = serde_json::to_vec(value).unwrap();
            line.push(b'\n');
            line
        })
        .collect::<Vec<_>>();
        let mut rows = Vec::new();
        let stats = visit_source(&path, None, |got_context, row| {
            assert_eq!(got_context, &original_context);
            rows.push(row);
            Ok(())
        })
        .unwrap();
        let mut canonical_first = first.clone();
        canonical_first.processes.sort_by_key(Process::identity);
        assert_eq!(rows, vec![canonical_first, empty.clone()]);
        // Input process arrays are canonicalized by identity on both writer and reader.
        assert_eq!(rows[0].processes[0].pid, 2);
        assert_eq!(stats.expanded_bytes, expected.len() as u64);
        assert_eq!(
            stats.expanded_sha256,
            format!("{:x}", Sha256::digest(&expected))
        );
        assert_eq!(stats.input_bytes, fs::metadata(&path).unwrap().len());
        assert_eq!(stats.scans, 2);
        assert_eq!(stats.readings, 2);

        let second_path = temp.path("second-roundtrip.jsonl.zst");
        RawWriter::create(&second_path, &stats.context)
            .unwrap()
            .finish()
            .unwrap();
        let second_stats = visit_source(&second_path, None, |_, _| Ok(())).unwrap();
        assert_eq!(second_stats.context, original_context);
    }

    #[test]
    fn native_header_context_and_row_helpers_are_versioned_and_lossless() {
        let context = context();
        let header = header_value(&context).unwrap();
        assert_eq!(header["recording_source"], 1);
        assert_eq!(header["cpu_unit"], "native_ticks");
        assert_eq!(header["context"]["cpu_timebase"]["numer"], 125);
        let row = observation(3, -8, 10, vec![process(4, "λ", u64::MAX - 9, 9)]);
        let value = row_to_value(&row).unwrap();
        assert_eq!(
            value["quality"],
            serde_json::to_value(&row.quality).unwrap()
        );
        assert_eq!(value["processes"][0][4], "λ");
        assert_eq!(value["processes"][0][5], u64::MAX - 9);
        let mut invalid_name = row;
        invalid_name.processes[0].name = "x".repeat(super::super::model::MAX_NAME_BYTES + 1);
        assert!(row_to_value(&invalid_name).is_err());
    }

    #[test]
    fn malformed_rows_duplicates_and_nonmonotonic_ranges_are_errors() {
        let temp = TempDir::new();
        let path = temp.path("bad.jsonl");
        let duplicate = serde_json::json!({
            "seq":0,"wall_start_ns":0,"scan_start_ns":1,"scan_end_ns":1,
            "processes":[[1,1,1,0,"a",0,0,0],[1,1,1,0,"b",0,0,0]]
        });
        write_jsonl(
            &path,
            &legacy_header(Some([1, 1])),
            &[duplicate],
            &[b"\n", b"\n"],
        );
        let error = visit_source(&path, None, |_, _| Ok(())).unwrap_err();
        assert!(error.contains("duplicate"));

        let a = serde_json::json!({"seq":2,"wall_start_ns":0,"scan_start_ns":5,"scan_end_ns":5,"processes":[]});
        let b = serde_json::json!({"seq":1,"wall_start_ns":0,"scan_start_ns":6,"scan_end_ns":6,"processes":[]});
        write_jsonl(
            &path,
            &legacy_header(Some([1, 1])),
            &[a, b],
            &[b"\n", b"\n", b"\n"],
        );
        assert!(
            visit_source(&path, None, |_, _| Ok(()))
                .unwrap_err()
                .contains("sequence")
        );

        let a = serde_json::json!({"seq":1,"wall_start_ns":0,"scan_start_ns":6,"scan_end_ns":6,"processes":[]});
        let same_time = serde_json::json!({"seq":2,"wall_start_ns":0,"scan_start_ns":6,"scan_end_ns":6,"processes":[]});
        write_jsonl(
            &path,
            &legacy_header(Some([1, 1])),
            &[a, same_time],
            &[b"\n", b"\n", b"\n"],
        );
        assert!(
            visit_source(&path, None, |_, _| Ok(()))
                .unwrap_err()
                .contains("scan_start_ns")
        );
    }

    #[test]
    fn zstd_frames_include_checksum_and_checksum_corruption_is_rejected() {
        let temp = TempDir::new();
        let path = temp.path("checksum.jsonl.zst");
        RawWriter::create(&path, &context())
            .unwrap()
            .finish()
            .unwrap();
        let mut bytes = fs::read(&path).unwrap();
        assert_eq!(&bytes[..4], &[0x28, 0xb5, 0x2f, 0xfd]);
        assert_ne!(bytes[4] & 0x04, 0, "zstd frame checksum flag is set");
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        fs::write(&path, bytes).unwrap();
        let error = visit_source(&path, None, |_, _| Ok(())).unwrap_err();
        assert!(error.contains("checksum") || error.contains("zstd"));
    }

    #[test]
    fn truncated_zstd_frame_is_not_treated_as_clean_eof() {
        let temp = TempDir::new();
        let path = temp.path("truncated.jsonl.zst");
        let mut writer = RawWriter::create(&path, &context()).unwrap();
        writer.write(&observation(0, 0, 1, vec![])).unwrap();
        writer.finish().unwrap();
        let mut bytes = fs::read(&path).unwrap();
        bytes.truncate(bytes.len() - 3);
        fs::write(&path, bytes).unwrap();
        assert!(visit_source(&path, None, |_, _| Ok(())).is_err());
    }

    #[test]
    fn writer_is_private_and_exclusive() {
        let temp = TempDir::new();
        let path = temp.path("private.jsonl");
        RawWriter::create(&path, &context())
            .unwrap()
            .finish()
            .unwrap();
        assert!(RawWriter::create(&path, &context()).is_err());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn oversized_header_and_quality_are_rejected_by_reader_and_writer() {
        let temp = TempDir::new();

        let mut oversized_context = context();
        oversized_context
            .source_headers
            .push(Value::String("x".repeat(MAX_BLOCK_BYTES)));
        let rejected_header = temp.path("rejected-header.jsonl");
        assert!(RawWriter::create(&rejected_header, &oversized_context).is_err());
        assert!(!rejected_header.exists());

        let oversized_header_input = temp.path("oversized-header-input.jsonl");
        let header = header_value(&oversized_context).unwrap();
        let mut file = File::create(&oversized_header_input).unwrap();
        serde_json::to_writer(&mut file, &header).unwrap();
        file.write_all(b"\n").unwrap();
        drop(file);
        assert!(
            visit_source(&oversized_header_input, None, |_, _| Ok(()))
                .unwrap_err()
                .contains("exceeds")
        );

        let mut oversized_row = observation(0, 0, 1, vec![]);
        oversized_row.quality = vec![Value::String("q".repeat(MAX_BLOCK_BYTES))];
        let writer_path = temp.path("oversized-quality.jsonl");
        let mut writer = RawWriter::create(&writer_path, &context()).unwrap();
        assert!(
            writer
                .write(&oversized_row)
                .unwrap_err()
                .contains("exceeds")
        );
        writer.finish().unwrap();
        assert_eq!(
            visit_source(&writer_path, None, |_, _| Ok(()))
                .unwrap()
                .scans,
            0
        );

        let reader_path = temp.path("oversized-quality-input.jsonl");
        let mut file = File::create(&reader_path).unwrap();
        serde_json::to_writer(&mut file, &header_value(&context()).unwrap()).unwrap();
        file.write_all(b"\n").unwrap();
        serde_json::to_writer(&mut file, &row_to_value(&oversized_row).unwrap()).unwrap();
        file.write_all(b"\n").unwrap();
        drop(file);
        assert!(
            visit_source(&reader_path, None, |_, _| Ok(()))
                .unwrap_err()
                .contains("exceeds")
        );
    }

    #[cfg(unix)]
    #[test]
    fn source_reader_rejects_symlinks() {
        use std::os::unix::fs::symlink;

        let temp = TempDir::new();
        let target = temp.path("target.jsonl");
        write_jsonl(&target, &legacy_header(Some([1, 1])), &[], &[b"\n"]);
        let link = temp.path("link.jsonl");
        symlink(&target, &link).unwrap();
        assert!(
            visit_source(&link, None, |_, _| Ok(()))
                .unwrap_err()
                .contains("non-symlink")
        );
    }

    #[test]
    fn oversized_lines_are_rejected_before_json_deserialization() {
        let temp = TempDir::new();
        let path = temp.path("large.jsonl");
        let header = serde_json::to_vec(&legacy_header(Some([1, 1]))).unwrap();
        let mut bytes = header;
        bytes.push(b'\n');
        bytes.extend(std::iter::repeat_n(b' ', MAX_BLOCK_BYTES + 1));
        fs::write(&path, bytes).unwrap();
        assert!(
            visit_source(&path, None, |_, _| Ok(()))
                .unwrap_err()
                .contains("exceeds")
        );
    }
}
