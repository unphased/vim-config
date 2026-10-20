use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

pub type Result<T> = std::result::Result<T, String>;
pub type Identity = (u32, u64, u32);
pub const RSS_QUANTUM: u64 = 256 * 1024;
pub const MAX_POINTS: usize = 1_000_000;
pub const MAX_BLOCK_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_NAME_BYTES: usize = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Timebase {
    pub numer: u64,
    pub denom: u64,
}
impl Timebase {
    pub fn validate(self) -> Result<()> {
        if self.numer == 0 || self.denom == 0 {
            return Err("invalid CPU timebase".into());
        }
        Ok(())
    }
    pub fn ns(self, ticks: u64) -> Result<u64> {
        self.validate()?;
        u64::try_from(u128::from(ticks) * u128::from(self.numer) / u128::from(self.denom))
            .map_err(|_| "CPU normalization overflow".into())
    }
    pub fn restore_ns(self, ns: u64) -> Result<u64> {
        self.validate()?;
        if self.numer < self.denom {
            return Err("legacy ns cannot restore a non-injective native timebase".into());
        }
        let ticks = (u128::from(ns) * u128::from(self.denom)).div_ceil(u128::from(self.numer));
        let ticks = u64::try_from(ticks).map_err(|_| "native CPU counter overflow")?;
        if self.ns(ticks)? != ns {
            return Err("CPU ns does not round-trip to native ticks".into());
        }
        Ok(ticks)
    }
    pub fn quantum(self, ns: u64) -> Result<u64> {
        self.validate()?;
        u64::try_from((u128::from(ns) * u128::from(self.denom) / u128::from(self.numer)).max(1))
            .map_err(|_| "CPU quantum overflow".into())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Context {
    pub hz: u64,
    pub capture_run_id: Option<String>,
    pub boot_id: Option<String>,
    pub clock: String,
    pub cpu_timebase: Timebase,
    #[serde(default)]
    pub source_headers: Vec<Value>,
}
impl Context {
    pub fn new(cpu_timebase: Timebase) -> Self {
        Self {
            hz: 10,
            capture_run_id: None,
            boot_id: None,
            clock: "legacy-unspecified-monotonic-ns".into(),
            cpu_timebase,
            source_headers: vec![],
        }
    }
    /// Source-file provenance may differ between shards of one logical stream.
    pub fn same_stream(&self, other: &Self) -> bool {
        self.hz == other.hz
            && self.capture_run_id == other.capture_run_id
            && self.boot_id == other.boot_id
            && self.clock == other.clock
            && self.cpu_timebase == other.cpu_timebase
    }
    pub fn validate(&self) -> Result<()> {
        self.cpu_timebase.validate()?;
        if self.hz == 0 || self.hz > 1000 {
            return Err("sampling frequency outside supported limits".into());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MemoryColumn {
    Owned,
    Peak,
    Evicted,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemoryEncoding {
    pub columns: Vec<MemoryColumn>,
    pub unit_bytes: u64,
}
impl MemoryEncoding {
    pub const NONE: Self = Self {
        columns: Vec::new(),
        unit_bytes: RSS_QUANTUM,
    };

    pub fn validate(&self) -> Result<()> {
        if self.unit_bytes == 0 {
            return Err("memory unit must be at least one byte".into());
        }
        if self.columns.windows(2).any(|pair| pair[0] >= pair[1]) {
            return Err("memory columns must be unique and in canonical order".into());
        }
        Ok(())
    }
}
impl Default for MemoryEncoding {
    fn default() -> Self {
        Self {
            columns: vec![
                MemoryColumn::Owned,
                MemoryColumn::Peak,
                MemoryColumn::Evicted,
            ],
            unit_bytes: RSS_QUANTUM,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Process {
    pub pid: u32,
    pub ppid: u32,
    pub start_sec: u64,
    pub start_usec: u32,
    pub name: String,
    pub user: u64,
    pub system: u64,
    pub rss: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owned: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peak: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evicted: Option<u64>,
}
impl Process {
    pub fn identity(&self) -> Identity {
        (self.pid, self.start_sec, self.start_usec)
    }
    pub fn total(&self) -> Result<u64> {
        self.user
            .checked_add(self.system)
            .ok_or_else(|| "CPU total overflow".into())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Observation {
    pub seq: u64,
    pub wall_start_ns: i64,
    pub scan_start_ns: u64,
    pub scan_end_ns: u64,
    pub processes: Vec<Process>,
    #[serde(default)]
    pub quality: Vec<Value>,
}
impl Observation {
    pub fn validate(&self) -> Result<()> {
        if self.scan_end_ns < self.scan_start_ns || self.processes.len() > MAX_POINTS {
            return Err("invalid scan bounds or process count".into());
        }
        let mut seen = BTreeSet::new();
        for p in &self.processes {
            if p.pid == 0
                || p.pid > i32::MAX as u32
                || p.ppid > i32::MAX as u32
                || p.start_usec >= 1_000_000
                || p.name.len() > MAX_NAME_BYTES
                || !seen.insert(p.identity())
            {
                return Err("invalid/duplicate process identity or name".into());
            }
            p.total()?;
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Profile {
    Legacy1ms,
    Fixed100us,
    Adaptive,
    AdaptiveInverse,
    AdaptiveLog,
}
impl Profile {
    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "legacy-1ms" | "fixed-1ms" => Ok(Self::Legacy1ms),
            "fixed-100us" => Ok(Self::Fixed100us),
            "adaptive" | "adaptive-v1" => Ok(Self::Adaptive),
            "adaptive-inverse" => Ok(Self::AdaptiveInverse),
            "adaptive-log" => Ok(Self::AdaptiveLog),
            _ => Err(format!("unknown recording profile: {s}")),
        }
    }
}

/// A source interval ending at a retained CPU checkpoint. `delta` and `error_bound`
/// are in native cumulative CPU ticks; endpoint timestamps come from source rows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CpuInterval {
    pub start_seq: u64,
    pub start_time_ns: u64,
    pub end_time_ns: u64,
    pub duration_ns: u64,
    pub delta: u64,
    pub error_bound: u64,
}

/// Total-only CPU reading; components remain unavailable for binary totals.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CpuCheckpoint {
    pub total: u64,
    pub error_bound: u64,
    pub components: Option<[u64; 2]>,
    pub interval: Option<CpuInterval>,
}

/// Deliberately distinct from raw Process: CPU may be unavailable on metadata-only rows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DecodedProcess {
    pub pid: u32,
    pub ppid: u32,
    pub start_sec: u64,
    pub start_usec: u32,
    pub name: String,
    pub cpu: Option<CpuCheckpoint>,
    pub rss: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owned: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peak: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evicted: Option<u64>,
}
impl DecodedProcess {
    pub fn identity(&self) -> Identity {
        (self.pid, self.start_sec, self.start_usec)
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DecodedObservation {
    pub seq: u64,
    pub wall_start_ns: i64,
    pub scan_start_ns: u64,
    pub scan_end_ns: u64,
    pub processes: Vec<DecodedProcess>,
    #[serde(default)]
    pub quality: Vec<Value>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct DecodedBlock {
    pub context: Context,
    pub profile: Profile,
    pub rows: Vec<DecodedObservation>,
    pub memory: Option<MemoryEncoding>,
}

/// A producer must explicitly confirm orderly completion; channel loss is not proof
/// that acquisition ended successfully. End quality is metadata, never a fake scan.
#[derive(Clone, Debug)]
pub enum LiveMessage {
    Observation(Observation),
    End {
        quality: Vec<Value>,
        error: Option<String>,
    },
}
impl From<Observation> for LiveMessage {
    fn from(value: Observation) -> Self {
        Self::Observation(value)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputFormat {
    Binary,
    JsonlZstd,
}
#[derive(Clone, Debug)]
pub struct RecordOptions {
    pub output: std::path::PathBuf,
    pub duration: Option<f64>,
    pub hz: u64,
    pub profile: Profile,
    pub format: OutputFormat,
    pub frame_bytes: usize,
    pub max_bytes: u64,
    pub min_free_bytes: u64,
    pub block_rows: usize,
    pub memory: MemoryEncoding,
    /// Offline source fidelity verification; independent of codec round-trip checks.
    pub verify: bool,
}
