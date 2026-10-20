//! Canonical, bounded recording block wire formats.
//!
//! PST1/PSD1/CSH1 is the byte-compatible legacy 1 ms control. PST2 keeps PSD1
//! sparse metadata, adds context and row quality, and uses independently versioned CSH2 CPU runs.
use super::model::{
    Context, CpuCheckpoint, CpuInterval, DecodedBlock, DecodedObservation, DecodedProcess,
    MAX_BLOCK_BYTES, MAX_NAME_BYTES, MAX_POINTS, MemoryColumn, MemoryEncoding, Observation,
    Process, Profile, RSS_QUANTUM, Result, Timebase,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::{self, Write};

const PST1: &[u8; 4] = b"PST1";
const PST2: &[u8; 4] = b"PST2";
const PSD1: &[u8; 4] = b"PSD1";
const PMM1: &[u8; 4] = b"PMM1";
const CSH1: &[u8; 4] = b"CSH1";
const CSH2: &[u8; 4] = b"CSH2";
const CSH2_ABSOLUTE_ENDPOINT_VERSION: u8 = 1;
const CSH2_VERSION: u8 = 2;
const RSS_UNITS: u64 = RSS_QUANTUM;
const MAX_DECODED_BYTES: usize = 256 * 1024 * 1024;
const LEGACY_CPU_NS: u64 = 1_000_000;
const FIXED_100US_NS: u64 = 100_000;
const NEW: u64 = 1;
const MISSING: u64 = 2;
const NAME: u64 = 4;
const PPID: u64 = 8;
const USER: u64 = 16;
const SYSTEM: u64 = 32;
const RSS: u64 = 64;
const RETURN: u64 = 128;
const KNOWN_MASK: u64 = NEW | MISSING | NAME | PPID | USER | SYSTEM | RSS | RETURN;

/// Encode one bounded block in the selected named profile without memory columns.
pub fn encode_block(context: &Context, rows: &[Observation], profile: Profile) -> Result<Vec<u8>> {
    encode_block_with_memory(context, rows, profile, MemoryEncoding::NONE)
}

/// Encode a PST2 block with the requested optional memory columns.
/// PST1 remains the byte-compatible legacy format and ignores memory values.
pub fn encode_block_with_memory(
    context: &Context,
    rows: &[Observation],
    profile: Profile,
    memory: MemoryEncoding,
) -> Result<Vec<u8>> {
    memory.validate()?;
    validate_context(context)?;
    let point_count = validate_rows(context, rows)?;
    match profile {
        Profile::Legacy1ms => encode_legacy(context, rows, point_count),
        Profile::Fixed100us
        | Profile::Adaptive
        | Profile::AdaptiveInverse
        | Profile::AdaptiveLog => encode_v2(context, rows, profile, point_count, &memory),
    }
}

/// Decode PST1 or PST2 without trusting encoded counts or lengths.
pub fn decode_block(bytes: &[u8]) -> Result<DecodedBlock> {
    if bytes.len() > MAX_BLOCK_BYTES {
        return Err("recording block exceeds the 64 MiB limit".into());
    }
    if bytes.len() < 4 {
        return Err("truncated recording block magic".into());
    }
    if &bytes[..4] == PST1 {
        decode_legacy(bytes)
    } else if &bytes[..4] == PST2 {
        decode_v2(bytes)
    } else {
        Err("unsupported recording block magic/version".into())
    }
}

fn validate_context(context: &Context) -> Result<()> {
    context.validate()?;
    if context.clock.len() > MAX_NAME_BYTES
        || context
            .capture_run_id
            .as_ref()
            .is_some_and(|s| s.len() > MAX_NAME_BYTES)
        || context
            .boot_id
            .as_ref()
            .is_some_and(|s| s.len() > MAX_NAME_BYTES)
    {
        return Err("recording context string exceeds the supported limit".into());
    }
    Ok(())
}

fn validate_rows(context: &Context, rows: &[Observation]) -> Result<usize> {
    if rows.len() > MAX_POINTS {
        return Err("recording row limit exceeded".into());
    }
    let mut points = 0usize;
    let mut expanded_bytes = 0usize;
    let mut previous_seq = None;
    let mut previous_scan = None;
    let mut counters: HashMap<(u32, u64, u32), (u64, u64)> = HashMap::new();
    for row in rows {
        row.validate()?;
        if previous_seq.is_some_and(|seq| row.seq <= seq)
            || previous_scan.is_some_and(|stamp| row.scan_start_ns <= stamp)
        {
            return Err("row sequence and scan-start clocks must increase strictly".into());
        }
        previous_seq = Some(row.seq);
        previous_scan = Some(row.scan_start_ns);
        let reset = counters
            .keys()
            .copied()
            .filter(|identity| temporal_quality_boundary(row, *identity))
            .collect::<Vec<_>>();
        for identity in reset {
            counters.remove(&identity);
        }
        points = points
            .checked_add(row.processes.len())
            .ok_or_else(|| "recording point count overflow".to_string())?;
        if points > MAX_POINTS {
            return Err("recording point limit exceeded".into());
        }
        expanded_bytes = add_psd1_row_expansion(
            expanded_bytes,
            row.processes.iter().map(|process| Ok(process.name.len())),
        )?;
        for process in &row.processes {
            let key = process.identity();
            if let Some((user, system)) = counters.get(&key)
                && (process.user < *user || process.system < *system)
            {
                return Err("CPU component counter regressed inside a block".into());
            }
            counters.insert(key, (process.user, process.system));
            process.total()?;
        }
    }
    context.cpu_timebase.validate()?;
    Ok(points)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyHeader {
    all_observations_kept: bool,
    cpu_quantum_native_ticks: u64,
    cpu_timebase_mach: [u64; 2],
    layout: String,
    rss_scheme: String,
    rss_unit_bytes: u64,
    schema: String,
    timestamp_unit_ns: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cpu_component_discontinuities_before: Option<Vec<Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    quality: Option<Vec<Vec<Value>>>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireContext {
    hz: u64,
    capture_run_id: Option<String>,
    boot_id: Option<String>,
    clock: String,
    cpu_timebase: Timebase,
    #[serde(default)]
    source_headers: Vec<Value>,
}
#[derive(Serialize)]
struct WireContextRef<'a> {
    hz: u64,
    capture_run_id: Option<&'a str>,
    boot_id: Option<&'a str>,
    clock: &'a str,
    cpu_timebase: Timebase,
    source_headers: &'a [Value],
}
impl<'a> From<&'a Context> for WireContextRef<'a> {
    fn from(value: &'a Context) -> Self {
        Self {
            hz: value.hz,
            capture_run_id: value.capture_run_id.as_deref(),
            boot_id: value.boot_id.as_deref(),
            clock: &value.clock,
            cpu_timebase: value.cpu_timebase,
            source_headers: &value.source_headers,
        }
    }
}
impl From<WireContext> for Context {
    fn from(value: WireContext) -> Self {
        Self {
            hz: value.hz,
            capture_run_id: value.capture_run_id,
            boot_id: value.boot_id,
            clock: value.clock,
            cpu_timebase: value.cpu_timebase,
            source_headers: value.source_headers,
        }
    }
}

#[derive(Serialize)]
struct V2HeaderRef<'a> {
    all_observations_kept: bool,
    context: WireContextRef<'a>,
    cpu_timebase_mach: [u64; 2],
    profile: &'a str,
    rss_scheme: &'static str,
    rss_unit_bytes: u64,
    row_count: u64,
    schema: &'static str,
    timestamp_unit_ns: u64,
    version: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    quality: Option<Vec<&'a [Value]>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    memory: Option<&'a MemoryEncoding>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct V2Header {
    all_observations_kept: bool,
    context: WireContext,
    cpu_timebase_mach: [u64; 2],
    profile: String,
    rss_scheme: String,
    rss_unit_bytes: u64,
    row_count: u64,
    schema: String,
    timestamp_unit_ns: u64,
    version: u64,
    #[serde(default)]
    quality: Option<Vec<Vec<Value>>>,
    #[serde(default, deserialize_with = "deserialize_memory_encoding")]
    memory: Option<MemoryEncoding>,
}

fn deserialize_memory_encoding<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<MemoryEncoding>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    MemoryEncoding::deserialize(deserializer).map(Some)
}

fn encode_legacy(context: &Context, rows: &[Observation], point_count: usize) -> Result<Vec<u8>> {
    let q = context.cpu_timebase.quantum(LEGACY_CPU_NS)?;
    let (cpu_component_discontinuities_before, quality) = legacy_quality(rows);
    let header = LegacyHeader {
        all_observations_kept: true,
        cpu_quantum_native_ticks: q,
        cpu_timebase_mach: [context.cpu_timebase.numer, context.cpu_timebase.denom],
        layout: "mask".into(),
        rss_scheme: "256k".into(),
        rss_unit_bytes: RSS_UNITS,
        schema: "recording-storage-block-v1".into(),
        timestamp_unit_ns: 1,
        cpu_component_discontinuities_before,
        quality,
    };
    let header = json_bytes(&header, MAX_BLOCK_BYTES)?;
    json_expansion_cost(&header)?;
    let cpu = encode_csh1(rows, q, context.cpu_timebase, point_count)?;
    let metadata = encode_psd1(rows, point_count)?;
    pack_sections(PST1, &header, &cpu, &metadata)
}

fn legacy_quality(rows: &[Observation]) -> (Option<Vec<Value>>, Option<Vec<Vec<Value>>>) {
    if rows.iter().all(|row| row.quality.is_empty()) {
        return (None, None);
    }
    if let Some(first) = rows.first()
        && !first.quality.is_empty()
        && first.quality.iter().all(is_cpu_component_decrease)
        && rows.iter().skip(1).all(|row| row.quality.is_empty())
    {
        return (Some(first.quality.clone()), None);
    }
    (
        None,
        Some(rows.iter().map(|row| row.quality.clone()).collect()),
    )
}

fn is_cpu_component_decrease(value: &Value) -> bool {
    value.get("kind").and_then(Value::as_str) == Some("cpu_component_decrease")
}

fn selected_memory(memory: &MemoryEncoding, rows: &[Observation]) -> Option<MemoryEncoding> {
    let columns: Vec<_> = memory
        .columns
        .iter()
        .copied()
        .filter(|column| {
            rows.iter()
                .flat_map(|row| &row.processes)
                .any(|process| process_memory_value(process, *column).is_some())
        })
        .collect();
    (!columns.is_empty()).then_some(MemoryEncoding {
        columns,
        unit_bytes: memory.unit_bytes,
    })
}

fn process_memory_value(process: &Process, column: MemoryColumn) -> Option<u64> {
    match column {
        MemoryColumn::Owned => process.owned,
        MemoryColumn::Peak => process.peak,
        MemoryColumn::Evicted => process.evicted,
    }
}

fn encode_pmm1(rows: &[Observation], memory: &MemoryEncoding) -> Result<Vec<u8>> {
    let mut out = PMM1.to_vec();
    for column in &memory.columns {
        let mut previous_values = BTreeMap::<(u32, u64, u32), i128>::new();
        for row in rows {
            let processes = sorted_processes(&row.processes);
            let absent: Vec<_> = processes
                .iter()
                .enumerate()
                .filter_map(|(index, process)| {
                    process_memory_value(process, *column)
                        .is_none()
                        .then_some(index)
                })
                .collect();
            put_uvarint(
                &mut out,
                u64::try_from(absent.len()).map_err(|_| "PMM1 absent count overflow")?,
            )?;
            let mut previous_index: Option<usize> = None;
            for index in absent {
                let gap = match previous_index {
                    Some(previous) => index
                        .checked_sub(previous)
                        .and_then(|delta| delta.checked_sub(1))
                        .ok_or_else(|| "PMM1 absent index order error".to_string())?,
                    None => index,
                };
                put_uvarint(
                    &mut out,
                    u64::try_from(gap).map_err(|_| "PMM1 absent index overflow")?,
                )?;
                previous_index = Some(index);
            }
            for process in processes {
                let Some(value) = process_memory_value(process, *column) else {
                    continue;
                };
                let units = value / memory.unit_bytes;
                let units = if *column == MemoryColumn::Peak
                    && memory.columns.contains(&MemoryColumn::Owned)
                {
                    if let Some(owned) = process.owned {
                        i128::from(units)
                            .checked_sub(i128::from(owned / memory.unit_bytes))
                            .ok_or_else(|| "PMM1 peak excess overflow".to_string())?
                    } else {
                        i128::from(units)
                    }
                } else {
                    i128::from(units)
                };
                let previous = previous_values
                    .get(&process.identity())
                    .copied()
                    .unwrap_or(0);
                put_svarint(
                    &mut out,
                    units
                        .checked_sub(previous)
                        .ok_or_else(|| "memory delta overflow".to_string())?,
                )?;
                previous_values.insert(process.identity(), units);
            }
            check_wire_size(&out)?;
        }
    }
    Ok(out)
}

fn encode_v2(
    context: &Context,
    rows: &[Observation],
    profile: Profile,
    point_count: usize,
    memory: &MemoryEncoding,
) -> Result<Vec<u8>> {
    let profile_name = match profile {
        Profile::Adaptive => "adaptive-v1",
        Profile::AdaptiveInverse => "adaptive-inverse",
        Profile::AdaptiveLog => "adaptive-log",
        Profile::Fixed100us => "fixed-100us-v1",
        Profile::Legacy1ms => return Err("legacy profile cannot use PST2".into()),
    };
    let quality = rows
        .iter()
        .any(|row| !row.quality.is_empty())
        .then(|| rows.iter().map(|row| row.quality.as_slice()).collect());
    let memory = selected_memory(memory, rows);
    let header = V2HeaderRef {
        all_observations_kept: true,
        context: WireContextRef::from(context),
        cpu_timebase_mach: [context.cpu_timebase.numer, context.cpu_timebase.denom],
        profile: profile_name,
        rss_scheme: "256k",
        rss_unit_bytes: RSS_UNITS,
        row_count: rows.len() as u64,
        schema: "recording-storage-block-v2",
        timestamp_unit_ns: 1,
        version: 2,
        quality,
        memory: memory.as_ref(),
    };
    let header = json_bytes(&header, MAX_BLOCK_BYTES)?;
    let header_expansion = json_expansion_cost(&header)?;
    let name_bytes =
        rows.iter()
            .flat_map(|row| &row.processes)
            .try_fold(0usize, |size, process| {
                size.checked_add(process.name.len())
                    .ok_or_else(|| "PST2 name-size estimate overflow".to_string())
            })?;
    check_v2_decoded_budget(
        rows.len(),
        point_count,
        name_bytes,
        rows.iter()
            .map(|row| row.processes.len())
            .max()
            .unwrap_or(0),
        memory.as_ref().map_or(0, |memory| memory.columns.len()),
        header_expansion,
        matches!(profile, Profile::AdaptiveInverse | Profile::AdaptiveLog),
    )?;
    let memory_section = memory
        .as_ref()
        .map(|encoding| encode_pmm1(rows, encoding))
        .transpose()?;
    let cpu = if matches!(profile, Profile::AdaptiveInverse | Profile::AdaptiveLog) {
        encode_csh2_temporal(rows, profile, context.cpu_timebase, point_count)?
    } else {
        encode_csh2(rows, profile, context.cpu_timebase, point_count)?
    };
    let metadata = encode_psd1(rows, point_count)?;
    pack_sections_with_optional_fourth(PST2, &header, &cpu, &metadata, memory_section.as_deref())
}

fn pack_sections(magic: &[u8; 4], header: &[u8], cpu: &[u8], metadata: &[u8]) -> Result<Vec<u8>> {
    pack_sections_with_optional_fourth(magic, header, cpu, metadata, None)
}

fn pack_sections_with_optional_fourth(
    magic: &[u8; 4],
    header: &[u8],
    cpu: &[u8],
    metadata: &[u8],
    fourth: Option<&[u8]>,
) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(
        4usize
            .saturating_add(header.len())
            .saturating_add(cpu.len())
            .saturating_add(metadata.len())
            .saturating_add(fourth.map_or(0, |section| section.len()))
            .min(MAX_BLOCK_BYTES),
    );
    out.extend_from_slice(magic);
    for section in [Some(header), Some(cpu), Some(metadata), fourth]
        .into_iter()
        .flatten()
    {
        put_uvarint(
            &mut out,
            u64::try_from(section.len()).map_err(|_| "section length overflow")?,
        )?;
        put_bytes(&mut out, section)?;
    }
    Ok(out)
}

fn unpack_sections(bytes: &[u8]) -> Result<[&[u8]; 3]> {
    let mut offset = 4usize;
    let mut sections = [&[][..]; 3];
    for section in &mut sections {
        *section = read_section(bytes, &mut offset)?;
    }
    if offset != bytes.len() {
        return Err("trailing recording block bytes".into());
    }
    Ok(sections)
}

#[allow(clippy::type_complexity)] // Three required wire sections and one optional section.
fn unpack_v2_sections(bytes: &[u8]) -> Result<(&[u8], &[u8], &[u8], Option<&[u8]>)> {
    let mut offset = 4usize;
    let header = read_section(bytes, &mut offset)?;
    let cpu = read_section(bytes, &mut offset)?;
    let metadata = read_section(bytes, &mut offset)?;
    let memory = if offset < bytes.len() {
        Some(read_section(bytes, &mut offset)?)
    } else {
        None
    };
    if offset != bytes.len() {
        return Err("trailing recording block bytes".into());
    }
    Ok((header, cpu, metadata, memory))
}

fn read_section<'a>(bytes: &'a [u8], offset: &mut usize) -> Result<&'a [u8]> {
    let length = usize::try_from(read_uvarint(bytes, offset)?)
        .map_err(|_| "section length does not fit this platform")?;
    let end = offset
        .checked_add(length)
        .ok_or_else(|| "section length overflow".to_string())?;
    let section = bytes
        .get(*offset..end)
        .ok_or_else(|| "truncated recording block section".to_string())?;
    *offset = end;
    Ok(section)
}

fn decode_legacy(bytes: &[u8]) -> Result<DecodedBlock> {
    let [header_bytes, cpu_bytes, metadata_bytes] = unpack_sections(bytes)?;
    let header: LegacyHeader = parse_json(header_bytes)?;
    if !header.all_observations_kept
        || header.schema != "recording-storage-block-v1"
        || header.layout != "mask"
        || header.rss_scheme != "256k"
        || header.rss_unit_bytes != RSS_UNITS
        || header.timestamp_unit_ns != 1
        || header.cpu_quantum_native_ticks == 0
        || header.cpu_timebase_mach[0] == 0
        || header.cpu_timebase_mach[1] == 0
    {
        return Err("unsupported or inconsistent PST1 header".into());
    }
    let context = Context::new(Timebase {
        numer: header.cpu_timebase_mach[0],
        denom: header.cpu_timebase_mach[1],
    });
    context.validate()?;
    if header.cpu_quantum_native_ticks != context.cpu_timebase.quantum(LEGACY_CPU_NS)? {
        return Err("PST1 CPU quantum disagrees with its timebase".into());
    }
    let mut rows = decode_psd1(metadata_bytes, 0)?;
    if let Some(quality) = header.quality {
        if quality.len() != rows.len() {
            return Err("PST1 row quality count does not match metadata".into());
        }
        for (row, values) in rows.iter_mut().zip(quality) {
            row.quality = values;
        }
    }
    if let Some(flags) = header.cpu_component_discontinuities_before
        && !flags.is_empty()
    {
        let first = rows
            .first_mut()
            .ok_or_else(|| "PST1 component discontinuity has no first row".to_string())?;
        first.quality.extend(flags);
    }
    let point_count = rows
        .iter()
        .try_fold(0usize, |n, row| n.checked_add(row.processes.len()))
        .ok_or_else(|| "metadata point count overflow".to_string())?;
    if point_count > MAX_POINTS {
        return Err("metadata point limit exceeded".into());
    }
    decode_csh1(
        cpu_bytes,
        header.cpu_quantum_native_ticks,
        context.cpu_timebase,
        &mut rows,
        point_count,
    )?;
    finish_decoded_rows(rows, context, Profile::Legacy1ms)
}

fn decode_v2(bytes: &[u8]) -> Result<DecodedBlock> {
    let (header_bytes, cpu_bytes, metadata_bytes, memory_bytes) = unpack_v2_sections(bytes)?;
    let header_expansion = json_expansion_cost(header_bytes)?;
    let header: V2Header = parse_json(header_bytes)?;
    let memory = header.memory;
    if memory.is_some() != memory_bytes.is_some() {
        return Err("PST2 memory header and PMM1 section must appear together".into());
    }
    if let Some(memory) = &memory {
        memory.validate()?;
        if memory.columns.is_empty() {
            return Err("PST2 memory header must declare at least one column".into());
        }
    }
    let context = Context::from(header.context);
    validate_context(&context)?;
    if !header.all_observations_kept
        || header.schema != "recording-storage-block-v2"
        || header.version != 2
        || header.rss_scheme != "256k"
        || header.rss_unit_bytes != RSS_UNITS
        || header.timestamp_unit_ns != 1
        || header.cpu_timebase_mach != [context.cpu_timebase.numer, context.cpu_timebase.denom]
    {
        return Err("unsupported or inconsistent PST2 header".into());
    }
    let profile = match header.profile.as_str() {
        "adaptive-v1" => Profile::Adaptive,
        "fixed-100us-v1" => Profile::Fixed100us,
        "adaptive-inverse" => Profile::AdaptiveInverse,
        "adaptive-log" => Profile::AdaptiveLog,
        _ => return Err("unsupported PST2 CPU profile".into()),
    };
    let declared_rows =
        usize::try_from(header.row_count).map_err(|_| "row count does not fit this platform")?;
    if declared_rows > MAX_POINTS {
        return Err("row limit exceeded".into());
    }
    let mut metadata = decode_psd1(metadata_bytes, header_expansion)?;
    if metadata.len() != declared_rows {
        return Err("PST2 row count does not match metadata".into());
    }
    if let Some(quality) = header.quality {
        if quality.len() != declared_rows {
            return Err("PST2 row quality count does not match header".into());
        }
        for (row, values) in metadata.iter_mut().zip(quality) {
            row.quality = values;
        }
    }
    let mut total_points = 0usize;
    let mut name_bytes = 0usize;
    let mut max_row_points = 0usize;
    for row in &metadata {
        total_points = total_points
            .checked_add(row.processes.len())
            .ok_or_else(|| "PST2 point count overflow".to_string())?;
        name_bytes = row.processes.iter().try_fold(name_bytes, |size, process| {
            size.checked_add(process.name.len())
                .ok_or_else(|| "PST2 name-size estimate overflow".to_string())
        })?;
        max_row_points = max_row_points.max(row.processes.len());
        if total_points > MAX_POINTS {
            return Err("PST2 point limit exceeded".into());
        }
    }
    check_v2_decoded_budget(
        metadata.len(),
        total_points,
        name_bytes,
        max_row_points,
        memory.as_ref().map_or(0, |memory| memory.columns.len()),
        header_expansion,
        matches!(profile, Profile::AdaptiveInverse | Profile::AdaptiveLog),
    )?;
    let mut decoded = Vec::with_capacity(metadata.len());
    for row in metadata {
        let processes = row
            .processes
            .into_iter()
            .map(MetaProcess::decoded_for_csh2)
            .collect::<Result<Vec<_>>>()?;
        decoded.push(DecodedObservation {
            seq: row.seq,
            wall_start_ns: row.wall_start_ns,
            scan_start_ns: row.scan_start_ns,
            scan_end_ns: row.scan_end_ns,
            processes,
            quality: row.quality,
        });
    }
    if matches!(profile, Profile::AdaptiveInverse | Profile::AdaptiveLog) {
        decode_csh2_temporal(
            cpu_bytes,
            profile,
            context.cpu_timebase,
            &mut decoded,
            total_points,
        )?;
    } else {
        decode_csh2(
            cpu_bytes,
            profile,
            context.cpu_timebase,
            &mut decoded,
            total_points,
        )?;
    }
    if let (Some(memory), Some(memory_bytes)) = (&memory, memory_bytes) {
        decode_pmm1(memory_bytes, memory, &mut decoded)?;
    }
    Ok(DecodedBlock {
        context,
        profile,
        rows: decoded,
        memory,
    })
}

fn decode_pmm1(
    bytes: &[u8],
    memory: &MemoryEncoding,
    rows: &mut [DecodedObservation],
) -> Result<()> {
    if bytes.len() < PMM1.len() || &bytes[..PMM1.len()] != PMM1 {
        return Err("invalid PMM1 memory section magic".into());
    }
    let mut offset = PMM1.len();
    for column in &memory.columns {
        let mut previous_values = BTreeMap::<(u32, u64, u32), i128>::new();
        let mut any_present = false;
        for row in rows.iter_mut() {
            let process_count = row.processes.len();
            let absent_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
                .map_err(|_| "PMM1 absent count overflow")?;
            if absent_count > process_count {
                return Err("PMM1 absent count exceeds row process count".into());
            }
            let mut absent = vec![false; process_count];
            let mut previous_index: Option<usize> = None;
            for _ in 0..absent_count {
                let gap = usize::try_from(read_uvarint(bytes, &mut offset)?)
                    .map_err(|_| "PMM1 absent index overflow")?;
                let index = match previous_index {
                    Some(previous) => previous
                        .checked_add(gap)
                        .and_then(|n| n.checked_add(1))
                        .ok_or_else(|| "PMM1 absent index overflow".to_string())?,
                    None => gap,
                };
                if index >= process_count {
                    return Err("PMM1 absent process index is out of range".into());
                }
                absent[index] = true;
                previous_index = Some(index);
            }
            for (index, process) in row.processes.iter_mut().enumerate() {
                if absent[index] {
                    continue;
                }
                any_present = true;
                let delta = read_svarint(bytes, &mut offset)?;
                let previous = previous_values
                    .get(&process.identity())
                    .copied()
                    .unwrap_or(0);
                let encoded_units = previous
                    .checked_add(delta)
                    .ok_or_else(|| "PMM1 memory delta overflow".to_string())?;
                previous_values.insert(process.identity(), encoded_units);
                let units = if *column == MemoryColumn::Peak
                    && memory.columns.contains(&MemoryColumn::Owned)
                {
                    if let Some(owned) = process.owned {
                        encoded_units
                            .checked_add(i128::from(owned / memory.unit_bytes))
                            .ok_or_else(|| "PMM1 peak unit overflow".to_string())?
                    } else {
                        encoded_units
                    }
                } else {
                    encoded_units
                };
                let units =
                    u64::try_from(units).map_err(|_| "PMM1 memory units outside u64 range")?;
                let value = units
                    .checked_mul(memory.unit_bytes)
                    .ok_or_else(|| "PMM1 memory byte value overflow".to_string())?;
                match column {
                    MemoryColumn::Owned => process.owned = Some(value),
                    MemoryColumn::Peak => process.peak = Some(value),
                    MemoryColumn::Evicted => process.evicted = Some(value),
                }
            }
        }
        if !any_present {
            return Err("PMM1 declares a column with no present values".into());
        }
    }
    if offset != bytes.len() {
        return Err("trailing PMM1 memory bytes".into());
    }
    Ok(())
}

#[derive(Clone)]
struct MetaProcess {
    pid: u32,
    ppid: u32,
    start_sec: u64,
    start_usec: u32,
    name: String,
    rss_units: u64,
    cpu: Option<(u64, u64)>, // native total, strict absolute error bound
}
impl MetaProcess {
    fn identity(&self) -> (u32, u64, u32) {
        (self.pid, self.start_sec, self.start_usec)
    }
    fn decoded_for_csh2(self) -> Result<DecodedProcess> {
        Ok(DecodedProcess {
            pid: self.pid,
            ppid: self.ppid,
            start_sec: self.start_sec,
            start_usec: self.start_usec,
            name: self.name,
            cpu: None,
            rss: self
                .rss_units
                .checked_mul(RSS_UNITS)
                .ok_or_else(|| "RSS decode overflow".to_string())?,
            owned: None,
            peak: None,
            evicted: None,
        })
    }
    fn decoded(self) -> Result<DecodedProcess> {
        let (total, error_bound) = self
            .cpu
            .ok_or_else(|| "missing CPU sample for metadata process".to_string())?;
        Ok(DecodedProcess {
            pid: self.pid,
            ppid: self.ppid,
            start_sec: self.start_sec,
            start_usec: self.start_usec,
            name: self.name,
            cpu: Some(CpuCheckpoint {
                total,
                error_bound,
                components: None,
                interval: None,
            }),
            rss: self
                .rss_units
                .checked_mul(RSS_UNITS)
                .ok_or_else(|| "RSS decode overflow".to_string())?,
            owned: None,
            peak: None,
            evicted: None,
        })
    }
}
struct MetaRow {
    seq: u64,
    wall_start_ns: i64,
    scan_start_ns: u64,
    scan_end_ns: u64,
    processes: Vec<MetaProcess>,
    quality: Vec<Value>,
}

fn check_v2_decoded_budget(
    row_count: usize,
    point_count: usize,
    name_bytes: usize,
    max_row_points: usize,
    memory_columns: usize,
    header_expansion: usize,
    temporal: bool,
) -> Result<()> {
    let mut expanded = header_expansion;
    let mut add = |count: usize, size: usize| -> Result<()> {
        expanded = expanded
            .checked_add(
                count
                    .checked_mul(size)
                    .ok_or_else(|| "PST2 decoded-size estimate overflow".to_string())?,
            )
            .ok_or_else(|| "PST2 decoded-size estimate overflow".to_string())?;
        Ok(())
    };
    // Metadata and final DTOs overlap during conversion; names are moved, not cloned.
    add(row_count, std::mem::size_of::<MetaRow>())?;
    add(point_count, std::mem::size_of::<MetaProcess>())?;
    add(row_count, std::mem::size_of::<DecodedObservation>())?;
    add(point_count, std::mem::size_of::<DecodedProcess>())?;
    add(name_bytes, 1)?;
    add(
        point_count,
        std::mem::size_of::<MetaProcess>()
            + std::mem::size_of::<(u32, u64, u32)>()
            + 8 * std::mem::size_of::<usize>(),
    )?;
    add(name_bytes, 1)?;
    if temporal {
        add(
            point_count,
            std::mem::size_of::<usize>() + 3 * std::mem::size_of::<u64>(),
        )?;
        add(
            point_count,
            std::mem::size_of::<TemporalSpan>()
                + std::mem::size_of::<(u32, u64, u32)>()
                + 4 * std::mem::size_of::<usize>(),
        )?;
    }
    if memory_columns > 0 {
        add(
            point_count,
            std::mem::size_of::<((u32, u64, u32), i128)>() + 4 * std::mem::size_of::<usize>(),
        )?;
        add(max_row_points, std::mem::size_of::<bool>())?;
    }
    if expanded > MAX_DECODED_BYTES {
        return Err("PST2 decoded expansion exceeds the bounded output limit".into());
    }
    Ok(())
}

fn add_psd1_row_expansion(
    expanded_bytes: usize,
    name_lengths: impl IntoIterator<Item = Result<usize>>,
) -> Result<usize> {
    let row_bytes =
        name_lengths
            .into_iter()
            .try_fold(std::mem::size_of::<MetaRow>(), |size, name_len| {
                let name_len = name_len?;
                size.checked_add(std::mem::size_of::<MetaProcess>())
                    .and_then(|n| n.checked_add(name_len))
                    .ok_or_else(|| "PSD1 decoded-size estimate overflow".to_string())
            })?;
    let expanded_bytes = expanded_bytes
        .checked_add(row_bytes)
        .ok_or_else(|| "PSD1 decoded-size estimate overflow".to_string())?;
    if expanded_bytes > MAX_DECODED_BYTES {
        return Err("PSD1 decoded expansion exceeds the bounded output limit".into());
    }
    Ok(expanded_bytes)
}

fn encode_psd1(rows: &[Observation], point_count: usize) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(PSD1);
    put_uvarint(&mut out, rows.len() as u64)?;
    let mut slots: Vec<MetaProcess> =
        Vec::with_capacity(point_count.min(rows.len().saturating_mul(4)));
    let mut slot_by_id = BTreeMap::new();
    let mut active = BTreeSet::new();
    let mut previous_seq = 0u64;
    let mut previous_wall = 0i64;
    let mut previous_scan = 0u64;
    for row in rows {
        put_svarint(&mut out, i128::from(row.seq) - i128::from(previous_seq))?;
        put_svarint(
            &mut out,
            i128::from(row.wall_start_ns) - i128::from(previous_wall),
        )?;
        put_svarint(
            &mut out,
            i128::from(row.scan_start_ns) - i128::from(previous_scan),
        )?;
        put_uvarint(&mut out, row.scan_end_ns - row.scan_start_ns)?;
        previous_seq = row.seq;
        previous_wall = row.wall_start_ns;
        previous_scan = row.scan_start_ns;

        let mut changes: Vec<MetaChange> = Vec::new();
        let current: BTreeSet<_> = row.processes.iter().map(Process::identity).collect();
        for slot in active.difference(&current_slots(&current, &slot_by_id)) {
            changes.push(MetaChange::Missing(*slot));
        }
        // The set above uses slots of currently present known identities; newly
        // allocated identities cannot be active, so this is exactly the missing set.
        let mut next_active = BTreeSet::new();
        for process in sorted_processes(&row.processes) {
            let identity = process.identity();
            if let Some(slot) = slot_by_id.get(&identity).copied() {
                let state = slots
                    .get_mut(slot)
                    .ok_or_else(|| "invalid internal metadata slot".to_string())?;
                let returning = !active.contains(&slot);
                let mut mask = if returning { RETURN } else { 0 };
                let mut fields = Vec::new();
                if process.name != state.name {
                    mask |= NAME;
                    fields.push(MetaField::Name(process.name.clone()));
                    state.name = process.name.clone();
                }
                if process.ppid != state.ppid {
                    mask |= PPID;
                    fields.push(MetaField::Signed(
                        i128::from(process.ppid) - i128::from(state.ppid),
                    ));
                    state.ppid = process.ppid;
                }
                let rss_units = process.rss / RSS_UNITS;
                if rss_units != state.rss_units {
                    mask |= RSS;
                    fields.push(MetaField::Signed(
                        i128::from(rss_units) - i128::from(state.rss_units),
                    ));
                    state.rss_units = rss_units;
                }
                if mask != 0 {
                    changes.push(MetaChange::Update(slot, mask, fields));
                }
                next_active.insert(slot);
            } else {
                let slot = slots.len();
                let rss_units = process.rss / RSS_UNITS;
                let state = MetaProcess {
                    pid: process.pid,
                    ppid: process.ppid,
                    start_sec: process.start_sec,
                    start_usec: process.start_usec,
                    name: process.name.clone(),
                    rss_units,
                    cpu: None,
                };
                slots.push(state);
                slot_by_id.insert(identity, slot);
                changes.push(MetaChange::New(
                    slot,
                    process.pid,
                    process.start_sec,
                    process.start_usec,
                    process.ppid,
                    process.name.clone(),
                    rss_units,
                ));
                next_active.insert(slot);
            }
        }
        active = next_active;
        changes.sort_by_key(MetaChange::slot);
        put_uvarint(&mut out, changes.len() as u64)?;
        let mut previous_slot: Option<usize> = None;
        for change in changes {
            let slot = change.slot();
            let gap = match previous_slot {
                Some(old) => slot.checked_sub(old + 1),
                None => Some(slot),
            }
            .ok_or_else(|| "metadata change slots are not sorted".to_string())?;
            put_uvarint(
                &mut out,
                u64::try_from(gap).map_err(|_| "slot gap overflow")?,
            )?;
            match change {
                MetaChange::Missing(_) => put_uvarint(&mut out, MISSING)?,
                MetaChange::New(_, pid, start_sec, start_usec, ppid, name, rss_units) => {
                    put_uvarint(&mut out, NEW)?;
                    for value in [
                        u64::from(pid),
                        start_sec,
                        u64::from(start_usec),
                        u64::from(ppid),
                    ] {
                        put_uvarint(&mut out, value)?;
                    }
                    put_string(&mut out, &name)?;
                    put_uvarint(&mut out, 0)?;
                    put_uvarint(&mut out, 0)?;
                    put_uvarint(&mut out, rss_units)?;
                }
                MetaChange::Update(_, mask, fields) => {
                    put_uvarint(&mut out, mask)?;
                    for field in fields {
                        match field {
                            MetaField::Name(name) => put_string(&mut out, &name)?,
                            MetaField::Signed(value) => put_svarint(&mut out, value)?,
                        }
                    }
                }
            }
            previous_slot = Some(slot);
        }
        check_wire_size(&out)?;
    }
    Ok(out)
}

fn current_slots(
    current: &BTreeSet<(u32, u64, u32)>,
    slots: &BTreeMap<(u32, u64, u32), usize>,
) -> BTreeSet<usize> {
    current
        .iter()
        .filter_map(|id| slots.get(id).copied())
        .collect()
}
fn sorted_processes(processes: &[Process]) -> Vec<&Process> {
    let mut sorted: Vec<_> = processes.iter().collect();
    sorted.sort_by_key(|process| process.identity());
    sorted
}
enum MetaField {
    Name(String),
    Signed(i128),
}
enum MetaChange {
    Missing(usize),
    New(usize, u32, u64, u32, u32, String, u64),
    Update(usize, u64, Vec<MetaField>),
}
impl MetaChange {
    fn slot(&self) -> usize {
        match self {
            Self::Missing(s) | Self::New(s, ..) | Self::Update(s, ..) => *s,
        }
    }
}

fn decode_psd1(bytes: &[u8], budget_reserve: usize) -> Result<Vec<MetaRow>> {
    if bytes.len() < 5 || &bytes[..4] != PSD1 {
        return Err("invalid PSD1 metadata magic".into());
    }
    let mut offset = 4;
    let frame_count = read_uvarint(bytes, &mut offset)?;
    let frame_count = usize::try_from(frame_count).map_err(|_| "PSD1 row count overflow")?;
    if frame_count > MAX_POINTS || frame_count > bytes.len().saturating_sub(offset) / 5 {
        return Err("PSD1 row count exceeds limits or payload".into());
    }
    let budget_reserve = budget_reserve
        .checked_add(
            frame_count
                .checked_mul(
                    std::mem::size_of::<MetaRow>() + std::mem::size_of::<DecodedObservation>(),
                )
                .ok_or_else(|| "PSD1 decoded-size estimate overflow".to_string())?,
        )
        .ok_or_else(|| "PSD1 decoded-size estimate overflow".to_string())?;
    if budget_reserve > MAX_DECODED_BYTES {
        return Err("PSD1 decoded expansion exceeds the bounded output limit".into());
    }
    let mut slots: Vec<MetaProcess> = Vec::new();
    let mut declared_ids = BTreeSet::new();
    let mut active = BTreeSet::new();
    let mut rows = Vec::with_capacity(frame_count);
    let (mut seq, mut wall, mut scan) = (0u64, 0i64, 0u64);
    let mut total_points = 0usize;
    let mut expanded_bytes = 0usize;
    let mut identity_scratch_bytes = 0usize;
    for _ in 0..frame_count {
        seq = add_signed_u64(seq, read_svarint(bytes, &mut offset)?, "sequence")?;
        wall = add_signed_i64(wall, read_svarint(bytes, &mut offset)?, "wall clock")?;
        scan = add_signed_u64(scan, read_svarint(bytes, &mut offset)?, "scan clock")?;
        let duration = read_uvarint(bytes, &mut offset)?;
        let end = scan
            .checked_add(duration)
            .ok_or_else(|| "scan end overflow".to_string())?;
        let change_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
            .map_err(|_| "PSD1 change count overflow")?;
        if change_count > MAX_POINTS || change_count > bytes.len().saturating_sub(offset) / 2 {
            return Err("PSD1 change count exceeds limits or payload".into());
        }
        let mut previous_slot = None;
        for _ in 0..change_count {
            let gap = usize::try_from(read_uvarint(bytes, &mut offset)?)
                .map_err(|_| "PSD1 slot index overflow")?;
            let slot = previous_slot.map_or_else(
                || gap,
                |old: usize| {
                    old.checked_add(gap)
                        .and_then(|n| n.checked_add(1))
                        .unwrap_or(usize::MAX)
                },
            );
            if slot == usize::MAX || previous_slot.is_some_and(|old| slot <= old) {
                return Err("PSD1 slot index overflow or unsorted changes".into());
            }
            let mask = read_uvarint(bytes, &mut offset)?;
            if mask == 0
                || mask & !KNOWN_MASK != 0
                || (mask & NEW != 0 && mask != NEW)
                || (mask & MISSING != 0 && mask != MISSING)
            {
                return Err("invalid PSD1 change mask".into());
            }
            match mask {
                NEW => {
                    if slot != slots.len() {
                        return Err("PSD1 new-process slot is not next".into());
                    }
                    let pid = to_u32(read_uvarint(bytes, &mut offset)?, "pid")?;
                    let start_sec = read_uvarint(bytes, &mut offset)?;
                    let start_usec = to_u32(read_uvarint(bytes, &mut offset)?, "start_usec")?;
                    let ppid = to_u32(read_uvarint(bytes, &mut offset)?, "ppid")?;
                    let name = read_string(bytes, &mut offset)?;
                    let user = read_uvarint(bytes, &mut offset)?;
                    let system = read_uvarint(bytes, &mut offset)?;
                    let rss_units = read_uvarint(bytes, &mut offset)?;
                    if user != 0 || system != 0 {
                        return Err("PST1 metadata cannot contain CPU components".into());
                    }
                    validate_meta_process(pid, ppid, start_sec, start_usec, &name)?;
                    if !declared_ids.insert((pid, start_sec, start_usec)) {
                        return Err("PSD1 identity was allocated more than once".into());
                    }
                    identity_scratch_bytes = identity_scratch_bytes
                        .checked_add(
                            std::mem::size_of::<MetaProcess>()
                                .checked_add(name.len())
                                .and_then(|size| {
                                    size.checked_add(std::mem::size_of::<(u32, u64, u32)>())
                                })
                                .and_then(|size| size.checked_add(8 * std::mem::size_of::<usize>()))
                                .ok_or_else(|| {
                                    "PSD1 identity-size estimate overflow".to_string()
                                })?,
                        )
                        .ok_or_else(|| "PSD1 identity-size estimate overflow".to_string())?;
                    slots.push(MetaProcess {
                        pid,
                        ppid,
                        start_sec,
                        start_usec,
                        name,
                        rss_units,
                        cpu: None,
                    });
                    active.insert(slot);
                }
                MISSING => {
                    if slot >= slots.len() || !active.remove(&slot) {
                        return Err("invalid PSD1 missing-process change".into());
                    }
                }
                _ => {
                    if slot >= slots.len() {
                        return Err("PSD1 update references unknown slot".into());
                    }
                    let returning = mask & RETURN != 0;
                    if returning {
                        if active.contains(&slot) {
                            return Err("PSD1 RETURN requires inactive slot".into());
                        }
                        active.insert(slot);
                    } else if !active.contains(&slot) {
                        return Err("inactive PSD1 update requires RETURN".into());
                    }
                    if mask & (USER | SYSTEM) != 0 {
                        return Err("PST1 metadata cannot update CPU components".into());
                    }
                    let process = slots
                        .get_mut(slot)
                        .ok_or_else(|| "invalid PSD1 process slot".to_string())?;
                    if mask & NAME != 0 {
                        process.name = read_string(bytes, &mut offset)?;
                    }
                    if mask & PPID != 0 {
                        let delta = read_svarint(bytes, &mut offset)?;
                        let updated = i128::from(process.ppid)
                            .checked_add(delta)
                            .ok_or_else(|| "PSD1 PPID update overflow".to_string())?;
                        process.ppid =
                            u32::try_from(updated).map_err(|_| "PSD1 PPID update outside range")?;
                    }
                    if mask & RSS != 0 {
                        process.rss_units = add_signed_u64(
                            process.rss_units,
                            read_svarint(bytes, &mut offset)?,
                            "RSS update",
                        )?;
                    }
                    validate_meta_process(
                        process.pid,
                        process.ppid,
                        process.start_sec,
                        process.start_usec,
                        &process.name,
                    )?;
                }
            }
            previous_slot = Some(slot);
            if slots.len() > MAX_POINTS {
                return Err("PSD1 identity limit exceeded".into());
            }
        }
        total_points = total_points
            .checked_add(active.len())
            .ok_or_else(|| "PSD1 point count overflow".to_string())?;
        if total_points > MAX_POINTS {
            return Err("PSD1 point limit exceeded".into());
        }
        expanded_bytes = add_psd1_row_expansion(
            expanded_bytes,
            active.iter().map(|slot| {
                slots
                    .get(*slot)
                    .map(|process| process.name.len())
                    .ok_or_else(|| "PSD1 active slot out of range".to_string())
            }),
        )?;
        if budget_reserve > 0 {
            let parsed_rows = rows.len() + 1;
            let row_structs = parsed_rows
                .checked_mul(std::mem::size_of::<MetaRow>())
                .ok_or_else(|| "PSD1 decoded-size estimate overflow".to_string())?;
            let metadata_processes = expanded_bytes
                .checked_sub(row_structs)
                .ok_or_else(|| "PSD1 decoded-size estimate underflow".to_string())?;
            let combined = budget_reserve
                .checked_add(metadata_processes)
                .and_then(|size| size.checked_add(identity_scratch_bytes))
                .ok_or_else(|| "PSD1 decoded-size estimate overflow".to_string())?;
            if combined > MAX_DECODED_BYTES {
                return Err("PST2 decoded expansion exceeds the bounded output limit".into());
            }
        }
        let mut processes: Vec<_> = active
            .iter()
            .map(|slot| {
                slots
                    .get(*slot)
                    .cloned()
                    .ok_or_else(|| "PSD1 active slot out of range".to_string())
            })
            .collect::<Result<Vec<_>>>()?;
        processes.sort_by_key(MetaProcess::identity);
        rows.push(MetaRow {
            seq,
            wall_start_ns: wall,
            scan_start_ns: scan,
            scan_end_ns: end,
            processes,
            quality: Vec::new(),
        });
    }
    if offset != bytes.len() {
        return Err("trailing PSD1 metadata bytes".into());
    }
    validate_meta_clocks(&rows)?;
    Ok(rows)
}

fn encode_csh1(
    rows: &[Observation],
    quantum: u64,
    timebase: Timebase,
    point_count: usize,
) -> Result<Vec<u8>> {
    let mut tracks: BTreeMap<(u32, u64, u32), Vec<(u64, u64)>> = BTreeMap::new();
    let mut axis_by_seq = BTreeMap::new();
    for row in rows {
        for process in &row.processes {
            axis_by_seq.insert(row.seq, row.scan_start_ns);
            tracks
                .entry(process.identity())
                .or_default()
                .push((row.seq, process.total()?));
        }
    }
    let axis: Vec<_> = axis_by_seq.into_iter().collect();
    let positions: BTreeMap<u64, usize> = axis
        .iter()
        .enumerate()
        .map(|(index, (seq, _))| (*seq, index))
        .collect();
    let mut out = Vec::new();
    out.extend_from_slice(CSH1);
    out.push(0); // CSH1 "changes" layout; frozen legacy control.
    for value in [
        quantum,
        1,
        timebase.numer,
        timebase.denom,
        axis.len() as u64,
        tracks.len() as u64,
        point_count as u64,
    ] {
        put_uvarint(&mut out, value)?;
    }
    let (mut prior_seq, mut prior_stamp) = (0u64, 0u64);
    for (seq, stamp) in &axis {
        put_uvarint(
            &mut out,
            seq.checked_sub(prior_seq)
                .ok_or_else(|| "sequence regression".to_string())?,
        )?;
        put_uvarint(
            &mut out,
            stamp
                .checked_sub(prior_stamp)
                .ok_or_else(|| "timestamp regression".to_string())?,
        )?;
        prior_seq = *seq;
        prior_stamp = *stamp;
    }
    let mut point_sum = 0usize;
    for (identity, source_samples) in tracks {
        let samples: Vec<(usize, u64)> = source_samples
            .into_iter()
            .map(|(seq, cpu)| {
                positions
                    .get(&seq)
                    .copied()
                    .map(|index| (index, cpu))
                    .ok_or_else(|| "CPU sample is missing from shared clock axis".to_string())
            })
            .collect::<Result<Vec<_>>>()?;
        point_sum = point_sum
            .checked_add(samples.len())
            .ok_or_else(|| "CPU point count overflow".to_string())?;
        for value in [
            u64::from(identity.0),
            identity.1,
            u64::from(identity.2),
            samples.len() as u64,
        ] {
            put_uvarint(&mut out, value)?;
        }
        let mut coverage_runs = Vec::<(usize, usize)>::new();
        for (index, _) in &samples {
            match coverage_runs.last_mut() {
                Some((start, length)) if start.checked_add(*length) == Some(*index) => *length += 1,
                _ => coverage_runs.push((*index, 1)),
            }
        }
        put_uvarint(&mut out, coverage_runs.len() as u64)?;
        let mut previous_end = 0usize;
        for (start, length) in coverage_runs {
            let gap = start
                .checked_sub(previous_end)
                .ok_or_else(|| "noncanonical CPU coverage".to_string())?;
            put_uvarint(&mut out, gap as u64)?;
            put_uvarint(&mut out, length as u64)?;
            previous_end = start + length;
        }
        let quotients: Vec<u64> = samples.iter().map(|(_, cpu)| cpu / quantum).collect();
        let baseline = *quotients
            .first()
            .ok_or_else(|| "empty CPU track".to_string())?;
        put_uvarint(&mut out, baseline)?;
        let changes: Vec<_> = quotients
            .iter()
            .enumerate()
            .skip(1)
            .filter_map(|(index, value)| {
                (quotients[index - 1] != *value).then_some((index, *value - quotients[index - 1]))
            })
            .collect();
        put_uvarint(&mut out, changes.len() as u64)?;
        let mut previous_index = 0usize;
        for (index, delta) in changes {
            put_uvarint(
                &mut out,
                index
                    .checked_sub(previous_index)
                    .ok_or_else(|| "CPU change index regression".to_string())?
                    as u64,
            )?;
            put_uvarint(&mut out, delta)?;
            previous_index = index;
        }
        let first = samples
            .first()
            .ok_or_else(|| "empty CPU track".to_string())?
            .1;
        let last = samples
            .last()
            .ok_or_else(|| "empty CPU track".to_string())?
            .1;
        put_uvarint(&mut out, first % quantum)?;
        put_uvarint(&mut out, last % quantum)?;
        check_wire_size(&out)?;
    }
    if point_sum != point_count {
        return Err("internal CSH1 point count mismatch".into());
    }
    check_wire_size(&out)?;
    Ok(out)
}

fn decode_csh1(
    bytes: &[u8],
    expected_quantum: u64,
    expected_timebase: Timebase,
    rows: &mut [MetaRow],
    expected_points: usize,
) -> Result<()> {
    if bytes.len() < 5 || &bytes[..4] != CSH1 || bytes[4] != 0 {
        return Err("unsupported CSH1 header or layout".into());
    }
    let mut offset = 5;
    let quantum = read_uvarint(bytes, &mut offset)?;
    let clock_unit = read_uvarint(bytes, &mut offset)?;
    let numer = read_uvarint(bytes, &mut offset)?;
    let denom = read_uvarint(bytes, &mut offset)?;
    let frame_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
        .map_err(|_| "CSH1 frame count overflow")?;
    let identity_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
        .map_err(|_| "CSH1 identity count overflow")?;
    let point_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
        .map_err(|_| "CSH1 point count overflow")?;
    if quantum != expected_quantum
        || clock_unit != 1
        || numer != expected_timebase.numer
        || denom != expected_timebase.denom
        || quantum == 0
        || frame_count > MAX_POINTS
        || point_count != expected_points
        || point_count > MAX_POINTS
        || identity_count > point_count
        || frame_count > point_count
        || frame_count > rows.len()
        || frame_count > bytes.len().saturating_sub(offset) / 2
    {
        return Err("inconsistent CSH1 metadata/counts".into());
    }
    let mut axis = Vec::with_capacity(frame_count);
    let (mut seq, mut stamp) = (0u64, 0u64);
    for index in 0..frame_count {
        let ds = read_uvarint(bytes, &mut offset)?;
        let dt = read_uvarint(bytes, &mut offset)?;
        if index > 0 && (ds == 0 || dt == 0) {
            return Err("CSH1 clocks are not strictly increasing".into());
        }
        seq = seq
            .checked_add(ds)
            .ok_or_else(|| "CSH1 sequence overflow".to_string())?;
        stamp = stamp
            .checked_add(
                dt.checked_mul(clock_unit)
                    .ok_or_else(|| "CSH1 timestamp overflow".to_string())?,
            )
            .ok_or_else(|| "CSH1 timestamp overflow".to_string())?;
        axis.push((seq, stamp));
    }
    let row_by_seq: BTreeMap<u64, usize> =
        rows.iter().enumerate().map(|(i, r)| (r.seq, i)).collect();
    let mut identity_previous = None;
    let mut point_sum = 0usize;
    let mut used_frames = vec![false; frame_count];
    for _ in 0..identity_count {
        let pid = to_u32(read_uvarint(bytes, &mut offset)?, "CSH1 pid")?;
        let start_sec = read_uvarint(bytes, &mut offset)?;
        let start_usec = to_u32(read_uvarint(bytes, &mut offset)?, "CSH1 start_usec")?;
        validate_meta_process(pid, 0, start_sec, start_usec, "")?;
        let identity = (pid, start_sec, start_usec);
        if identity_previous.is_some_and(|old| identity <= old) {
            return Err("CSH1 identities are not sorted".into());
        }
        identity_previous = Some(identity);
        let count = usize::try_from(read_uvarint(bytes, &mut offset)?)
            .map_err(|_| "CSH1 sample count overflow")?;
        if count == 0 || count > frame_count || count > expected_points.saturating_sub(point_sum) {
            return Err("invalid CSH1 sample count".into());
        }
        point_sum = point_sum
            .checked_add(count)
            .ok_or_else(|| "CSH1 point count overflow".to_string())?;
        let run_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
            .map_err(|_| "CSH1 coverage count overflow")?;
        if run_count == 0 || run_count > count || run_count > bytes.len().saturating_sub(offset) / 2
        {
            return Err("invalid CSH1 coverage run count".into());
        }
        let mut indices = Vec::with_capacity(count);
        let mut previous_end = 0usize;
        for run in 0..run_count {
            let gap = usize::try_from(read_uvarint(bytes, &mut offset)?)
                .map_err(|_| "CSH1 coverage gap overflow")?;
            let length = usize::try_from(read_uvarint(bytes, &mut offset)?)
                .map_err(|_| "CSH1 coverage length overflow")?;
            let start = previous_end
                .checked_add(gap)
                .ok_or_else(|| "CSH1 coverage overflow".to_string())?;
            let end = start
                .checked_add(length)
                .ok_or_else(|| "CSH1 coverage overflow".to_string())?;
            if length == 0
                || (run > 0 && gap == 0)
                || end > frame_count
                || length > count.saturating_sub(indices.len())
            {
                return Err("invalid CSH1 coverage".into());
            }
            indices.extend(start..end);
            previous_end = end;
        }
        if indices.len() != count {
            return Err("CSH1 coverage count mismatch".into());
        }
        let baseline = read_uvarint(bytes, &mut offset)?;
        let change_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
            .map_err(|_| "CSH1 change count overflow")?;
        if change_count > count.saturating_sub(1)
            || change_count > bytes.len().saturating_sub(offset) / 2
        {
            return Err("invalid CSH1 CPU change count".into());
        }
        let mut quotients = vec![baseline; count];
        let mut previous_index = 0usize;
        let mut current_q = baseline;
        let mut next_fill = 0usize;
        for _ in 0..change_count {
            let delta_index = usize::try_from(read_uvarint(bytes, &mut offset)?)
                .map_err(|_| "CSH1 change index overflow")?;
            let delta_cpu = read_uvarint(bytes, &mut offset)?;
            let index = previous_index
                .checked_add(delta_index)
                .ok_or_else(|| "CSH1 change index overflow".to_string())?;
            if delta_index == 0 || delta_cpu == 0 || index >= count {
                return Err("invalid CSH1 CPU change".into());
            }
            quotients[next_fill..index].fill(current_q);
            current_q = current_q
                .checked_add(delta_cpu)
                .ok_or_else(|| "CSH1 CPU quotient overflow".to_string())?;
            quotients[index] = current_q;
            next_fill = index + 1;
            previous_index = index;
        }
        quotients[next_fill..count].fill(current_q);
        let first_remainder = read_uvarint(bytes, &mut offset)?;
        let last_remainder = read_uvarint(bytes, &mut offset)?;
        if first_remainder >= quantum
            || last_remainder >= quantum
            || (count == 1 && first_remainder != last_remainder)
        {
            return Err("invalid CSH1 endpoint remainder".into());
        }
        let mut cpus = Vec::with_capacity(count);
        let first = quotients[0]
            .checked_mul(quantum)
            .and_then(|v| v.checked_add(first_remainder))
            .ok_or_else(|| "CSH1 CPU total overflow".to_string())?;
        cpus.push(first);
        for quotient in quotients.iter().take(count.saturating_sub(1)).skip(1) {
            let point = quotient
                .checked_mul(quantum)
                .ok_or_else(|| "CSH1 CPU total overflow".to_string())?;
            let prior = *cpus
                .last()
                .ok_or_else(|| "empty CSH1 CPU track".to_string())?;
            cpus.push(point.max(prior));
        }
        if count > 1 {
            let last = quotients[count - 1]
                .checked_mul(quantum)
                .and_then(|v| v.checked_add(last_remainder))
                .ok_or_else(|| "CSH1 CPU total overflow".to_string())?;
            cpus.push(last);
        }
        for i in 1..cpus.len() {
            if cpus[i] < cpus[i - 1] {
                return Err("CSH1 CPU counter regressed".into());
            }
        }
        for (sample_index, (point, cpu)) in indices.into_iter().zip(cpus).enumerate() {
            let used = used_frames
                .get_mut(point)
                .ok_or_else(|| "CSH1 frame index out of range".to_string())?;
            *used = true;
            let (point_seq, point_stamp) = *axis
                .get(point)
                .ok_or_else(|| "CSH1 frame index out of range".to_string())?;
            let row_index = *row_by_seq
                .get(&point_seq)
                .ok_or_else(|| "CSH1 sequence absent from metadata".to_string())?;
            let row = rows
                .get_mut(row_index)
                .ok_or_else(|| "CSH1 row index out of range".to_string())?;
            if row.scan_start_ns != point_stamp {
                return Err("CSH1 clock disagrees with PSD1 metadata".into());
            }
            let pindex = row
                .processes
                .binary_search_by_key(&identity, MetaProcess::identity)
                .map_err(|_| "CSH1 identity absent from PSD1 metadata")?;
            let process = row
                .processes
                .get_mut(pindex)
                .ok_or_else(|| "CSH1 process index out of range".to_string())?;
            let bound = if sample_index == 0 || sample_index + 1 == count {
                0
            } else {
                quantum - 1
            };
            if process.cpu.replace((cpu, bound)).is_some() {
                return Err("duplicate CSH1 CPU sample".into());
            }
        }
    }
    if point_sum != expected_points {
        return Err("CSH1 total point count mismatch".into());
    }
    if used_frames.iter().any(|used| !used) {
        return Err("unused CSH1 shared clock entry".into());
    }
    if offset != bytes.len() {
        return Err("trailing CSH1 bytes".into());
    }
    for row in rows {
        for process in &row.processes {
            if process.cpu.is_none() {
                return Err("PSD1 process has no CSH1 CPU sample".into());
            }
        }
    }
    Ok(())
}

#[derive(Clone)]
struct TemporalSegment {
    identity: (u32, u64, u32),
    samples: Vec<(usize, u64)>,
}

fn encode_csh2_temporal(
    rows: &[Observation],
    profile: Profile,
    timebase: Timebase,
    metadata_points: usize,
) -> Result<Vec<u8>> {
    let mut by_identity = BTreeMap::<(u32, u64, u32), Vec<(usize, u64)>>::new();
    for (row_index, row) in rows.iter().enumerate() {
        for process in &row.processes {
            by_identity
                .entry(process.identity())
                .or_default()
                .push((row_index, process.total()?));
        }
    }

    let mut segments = Vec::new();
    for (identity, samples) in by_identity {
        let mut current = Vec::<(usize, u64)>::new();
        for (row_index, total) in samples {
            let split = current.last().is_some_and(|(previous_index, _)| {
                let previous = &rows[*previous_index];
                row_index != previous_index + 1
                    || rows[row_index].seq != previous.seq.saturating_add(1)
                    || temporal_quality_boundary(&rows[row_index], identity)
            });
            if split {
                segments.push(TemporalSegment {
                    identity,
                    samples: std::mem::take(&mut current),
                });
            }
            current.push((row_index, total));
        }
        if !current.is_empty() {
            segments.push(TemporalSegment {
                identity,
                samples: current,
            });
        }
    }

    let cap = timebase.quantum(LEGACY_CPU_NS)?;
    let qbusy = adaptive_quantum(u128::from(cap), cap);
    let mut selected_segments = Vec::<TemporalSegment>::new();
    let mut checkpoint_count = 0usize;
    for segment in segments {
        let chosen = select_temporal_points(
            rows,
            &segment.samples,
            segment.identity,
            cap,
            qbusy,
            profile,
        )?;
        checkpoint_count = checkpoint_count
            .checked_add(chosen.len())
            .ok_or_else(|| "temporal CPU checkpoint count overflow".to_string())?;
        selected_segments.push(TemporalSegment {
            identity: segment.identity,
            samples: chosen,
        });
    }
    if checkpoint_count > metadata_points {
        return Err("temporal CPU checkpoints exceed metadata points".into());
    }

    let mut out = Vec::new();
    out.extend_from_slice(CSH2);
    out.push(CSH2_VERSION);
    for value in [
        rows.len() as u64,
        selected_segments.len() as u64,
        checkpoint_count as u64,
    ] {
        put_uvarint(&mut out, value)?;
    }
    for segment in selected_segments {
        for value in [
            u64::from(segment.identity.0),
            segment.identity.1,
            u64::from(segment.identity.2),
            segment.samples.len() as u64,
        ] {
            put_uvarint(&mut out, value)?;
        }
        let mut previous_row = None;
        for (row_index, _) in &segment.samples {
            let delta = previous_row.map_or(*row_index, |previous| row_index - previous);
            if previous_row.is_some() && delta == 0 {
                return Err("duplicate temporal CPU checkpoint row".into());
            }
            put_uvarint(&mut out, delta as u64)?;
            previous_row = Some(*row_index);
        }
        let first = segment
            .samples
            .first()
            .ok_or_else(|| "empty temporal CPU segment".to_string())?;
        put_uvarint(&mut out, first.1)?;

        let mut quanta = Vec::with_capacity(segment.samples.len().saturating_sub(1));
        for pair in segment.samples.windows(2) {
            let delta = pair[1]
                .1
                .checked_sub(pair[0].1)
                .ok_or_else(|| "temporal CPU total regressed".to_string())?;
            let duration = rows[pair[1].0]
                .scan_start_ns
                .checked_sub(rows[pair[0].0].scan_start_ns)
                .filter(|duration| *duration > 0)
                .ok_or_else(|| "temporal CPU interval has invalid duration".to_string())?;
            quanta.push(temporal_quantum(delta, duration, cap)?);
        }
        let mut runs = Vec::<(usize, usize, u64)>::new();
        let mut start = 0usize;
        while start < quanta.len() {
            let q = quanta[start];
            let mut end = start + 1;
            while end < quanta.len() && quanta[end] == q {
                end += 1;
            }
            runs.push((start, end - start, q));
            start = end;
        }
        put_uvarint(&mut out, runs.len() as u64)?;
        for (start, length, q) in runs {
            put_uvarint(&mut out, length as u64)?;
            put_uvarint(&mut out, q)?;
            let anchor = segment.samples[start].1;
            let end_point = start + length;
            for (_, cpu) in segment.samples.iter().take(end_point).skip(start + 1) {
                let quotient = cpu
                    .checked_sub(anchor)
                    .ok_or_else(|| "temporal CPU anchor regression".to_string())?
                    / q;
                put_uvarint(&mut out, quotient)?;
            }
            let endpoint_delta = segment.samples[end_point]
                .1
                .checked_sub(anchor)
                .ok_or_else(|| "temporal CPU endpoint regression".to_string())?;
            put_uvarint(&mut out, endpoint_delta)?;
        }
        check_wire_size(&out)?;
    }
    check_wire_size(&out)?;
    Ok(out)
}

fn select_temporal_points(
    rows: &[Observation],
    samples: &[(usize, u64)],
    identity: (u32, u64, u32),
    cap: u64,
    qbusy: u64,
    profile: Profile,
) -> Result<Vec<(usize, u64)>> {
    if samples.len() <= 2 {
        return Ok(samples.to_vec());
    }
    let mut selected = vec![samples[0]];
    let mut anchor = 0usize;
    let mut pending_ns = 5_000_000_000u64;
    for index in 1..samples.len() {
        let (previous_row, previous_total) = samples[index - 1];
        let (row_index, total) = samples[index];
        let adjacent_elapsed = rows[row_index]
            .scan_start_ns
            .checked_sub(rows[previous_row].scan_start_ns)
            .filter(|duration| *duration > 0)
            .ok_or_else(|| "temporal CPU source time did not advance".to_string())?;
        let adjacent_delta = total
            .checked_sub(previous_total)
            .ok_or_else(|| "temporal CPU source total regressed".to_string())?;
        let q = temporal_quantum(adjacent_delta, adjacent_elapsed, cap)?;
        let desired = temporal_target(q, qbusy, profile)?;

        let anchor_row = samples[anchor].0;
        let elapsed_from_anchor = rows[row_index]
            .scan_start_ns
            .checked_sub(rows[anchor_row].scan_start_ns)
            .filter(|duration| *duration > 0)
            .ok_or_else(|| "temporal CPU source time did not advance".to_string())?;
        if desired < pending_ns && index > anchor + 1 && elapsed_from_anchor > desired {
            let previous = samples[index - 1];
            if selected.last().is_none_or(|last| last.0 != previous.0) {
                selected.push(previous);
            }
            anchor = index - 1;
            pending_ns = 5_000_000_000;
        }
        pending_ns = pending_ns.min(desired);

        let since_anchor = rows[row_index]
            .scan_start_ns
            .checked_sub(rows[samples[anchor].0].scan_start_ns)
            .ok_or_else(|| "temporal CPU source time regressed".to_string())?;
        let metadata_change = rows[row_index]
            .processes
            .iter()
            .find(|process| process.identity() == identity)
            .zip(
                rows[previous_row]
                    .processes
                    .iter()
                    .find(|process| process.identity() == identity),
            )
            .is_some_and(|(current, previous)| {
                current.name != previous.name || current.ppid != previous.ppid
            });
        if since_anchor >= pending_ns || metadata_change {
            if selected.last().is_none_or(|last| last.0 != row_index) {
                selected.push((row_index, total));
            }
            anchor = index;
            pending_ns = 5_000_000_000;
        }
    }
    let last = *samples
        .last()
        .ok_or_else(|| "empty temporal CPU segment".to_string())?;
    if selected.last().is_none_or(|sample| sample.0 != last.0) {
        selected.push(last);
    }
    Ok(selected)
}

fn temporal_quality_boundary(row: &Observation, identity: (u32, u64, u32)) -> bool {
    row.quality.iter().any(|quality| {
        let kind = quality.get("kind").and_then(Value::as_str).unwrap_or("");
        let id = quality.get("identity");
        let targeted = id.is_some_and(|id| {
            id.get("pid").and_then(Value::as_u64) == Some(u64::from(identity.0))
                && id.get("start_sec").and_then(Value::as_u64) == Some(identity.1)
                && id.get("start_usec").and_then(Value::as_u64) == Some(u64::from(identity.2))
        });
        let continuity_unknown = kind.contains("continuity-unknown");
        targeted && (continuity_unknown || kind == "cpu-component-regression")
            || continuity_unknown && id.is_none()
            || kind.contains("acquisition-gap")
            || matches!(kind, "gap" | "source-gap" | "sequence-gap") && id.is_none()
    })
}

fn temporal_quantum(delta: u64, elapsed_ns: u64, cap: u64) -> Result<u64> {
    if elapsed_ns == 0 || cap == 0 {
        return Err("temporal CPU interval duration/cap is zero".into());
    }
    let scaled = u128::from(delta)
        .checked_mul(100_000_000)
        .ok_or_else(|| "temporal CPU normalization overflow".to_string())?;
    let per_100ms = scaled / u128::from(elapsed_ns);
    Ok(adaptive_quantum(per_100ms, cap))
}

fn adaptive_quantum(per_100ms: u128, cap: u64) -> u64 {
    let eighth = per_100ms / 8;
    if eighth == 0 {
        return 1;
    }
    let exponent = 127 - eighth.leading_zeros();
    let power = 1u128 << exponent;
    u64::try_from(power.min(u128::from(cap)))
        .unwrap_or(cap)
        .max(1)
}

fn temporal_target(q: u64, qbusy: u64, profile: Profile) -> Result<u64> {
    if q == 0 || qbusy == 0 || !qbusy.is_power_of_two() {
        return Err("temporal deadline quantum is invalid".into());
    }
    let ratio = (qbusy / q).max(1);
    match profile {
        Profile::AdaptiveInverse => {
            let target = 100_000_000u128
                .checked_mul(u128::from(ratio))
                .ok_or_else(|| "inverse temporal deadline overflow".to_string())?;
            Ok(target.min(5_000_000_000) as u64)
        }
        Profile::AdaptiveLog => {
            let busy_exponent = u128::from(qbusy.trailing_zeros());
            if busy_exponent == 0 || q >= qbusy {
                return Ok(100_000_000);
            }
            if !q.is_power_of_two() {
                return Err("low-rate temporal quantum is not a power of two".into());
            }
            let quiet_exponent = u128::from(q.trailing_zeros());
            let log_ratio = busy_exponent
                .checked_sub(quiet_exponent)
                .ok_or_else(|| "log temporal exponent underflow".to_string())?;
            let numerator = 4_900_000_000u128
                .checked_mul(log_ratio)
                .ok_or_else(|| "log temporal deadline overflow".to_string())?;
            let offset = numerator.div_ceil(busy_exponent);
            let target = 100_000_000u128
                .checked_add(offset)
                .ok_or_else(|| "log temporal deadline overflow".to_string())?;
            Ok(target.min(5_000_000_000) as u64)
        }
        _ => Err("non-temporal profile used temporal deadline".into()),
    }
}

fn encode_csh2(
    rows: &[Observation],
    profile: Profile,
    timebase: Timebase,
    point_count: usize,
) -> Result<Vec<u8>> {
    let mut tracks: BTreeMap<(u32, u64, u32), Vec<(usize, u64)>> = BTreeMap::new();
    for (row_index, row) in rows.iter().enumerate() {
        for process in &row.processes {
            tracks
                .entry(process.identity())
                .or_default()
                .push((row_index, process.total()?));
        }
    }
    let mut out = Vec::new();
    out.extend_from_slice(CSH2);
    out.push(CSH2_VERSION);
    for value in [rows.len() as u64, tracks.len() as u64, point_count as u64] {
        put_uvarint(&mut out, value)?;
    }
    let cap = match profile {
        Profile::Adaptive => timebase.quantum(LEGACY_CPU_NS)?,
        Profile::Fixed100us => timebase.quantum(FIXED_100US_NS)?,
        Profile::AdaptiveInverse | Profile::AdaptiveLog => {
            return Err("temporal profile requires the temporal CSH2 body".into());
        }
        Profile::Legacy1ms => return Err("legacy profile cannot use CSH2".into()),
    };
    let adaptive = profile == Profile::Adaptive;
    let mut written_points = 0usize;
    for (identity, samples) in tracks {
        written_points = written_points
            .checked_add(samples.len())
            .ok_or_else(|| "CSH2 point count overflow".to_string())?;
        for value in [
            u64::from(identity.0),
            identity.1,
            u64::from(identity.2),
            samples.len() as u64,
        ] {
            put_uvarint(&mut out, value)?;
        }
        let mut previous_row = 0usize;
        for (index, (row, _)) in samples.iter().enumerate() {
            let delta = if index == 0 {
                *row
            } else {
                row.checked_sub(previous_row)
                    .ok_or_else(|| "CSH2 row order regression".to_string())?
            };
            if index > 0 && delta == 0 {
                return Err("duplicate CSH2 row index".into());
            }
            put_uvarint(&mut out, delta as u64)?;
            previous_row = *row;
        }
        put_uvarint(
            &mut out,
            samples
                .first()
                .ok_or_else(|| "empty CSH2 track".to_string())?
                .1,
        )?;
        let mut intervals = Vec::with_capacity(samples.len().saturating_sub(1));
        for pair in samples.windows(2) {
            let delta = pair[1]
                .1
                .checked_sub(pair[0].1)
                .ok_or_else(|| "CPU total regressed".to_string())?;
            let q = if adaptive {
                let eighth = delta / 8;
                let step = if eighth == 0 {
                    1
                } else {
                    1u64 << (63 - eighth.leading_zeros())
                };
                step.min(cap).max(1)
            } else if delta == 0 {
                1
            } else {
                cap
            };
            intervals.push(q);
        }
        let mut runs = Vec::<(usize, usize, u64)>::new();
        let mut start = 0usize;
        while start < intervals.len() {
            let q = intervals[start];
            let mut end = start + 1;
            while end < intervals.len() && intervals[end] == q {
                end += 1;
            }
            runs.push((start, end - start, q));
            start = end;
        }
        put_uvarint(&mut out, runs.len() as u64)?;
        for (start, length, q) in runs {
            put_uvarint(&mut out, length as u64)?;
            put_uvarint(&mut out, q)?;
            let anchor = samples[start].1;
            let end_point = start + length;
            for (_, cpu) in samples.iter().take(end_point).skip(start + 1) {
                let quotient = cpu
                    .checked_sub(anchor)
                    .ok_or_else(|| "CPU anchor regression".to_string())?
                    / q;
                put_uvarint(&mut out, quotient)?;
            }
            let endpoint_delta = samples[end_point]
                .1
                .checked_sub(anchor)
                .ok_or_else(|| "CPU anchor regression".to_string())?;
            put_uvarint(&mut out, endpoint_delta)?;
        }
        check_wire_size(&out)?;
    }
    if written_points != point_count {
        return Err("internal CSH2 point count mismatch".into());
    }
    check_wire_size(&out)?;
    Ok(out)
}

#[derive(Clone, Copy)]
struct TemporalSpan {
    first: usize,
    last: usize,
}

fn decoded_temporal_spans(
    rows: &[DecodedObservation],
) -> BTreeMap<(u32, u64, u32), Vec<TemporalSpan>> {
    let mut spans = BTreeMap::<(u32, u64, u32), Vec<TemporalSpan>>::new();
    for (row_index, row) in rows.iter().enumerate() {
        for process in &row.processes {
            let identity = process.identity();
            let identity_spans = spans.entry(identity).or_default();
            let contiguous = identity_spans.last().is_some_and(|span| {
                span.last.checked_add(1) == Some(row_index)
                    && row.seq == rows[span.last].seq.saturating_add(1)
                    && !decoded_temporal_quality_boundary(row, identity)
            });
            if contiguous {
                identity_spans.last_mut().unwrap().last = row_index;
            } else {
                identity_spans.push(TemporalSpan {
                    first: row_index,
                    last: row_index,
                });
            }
        }
    }
    spans
}

fn temporal_allowed_delta_range(quantum: u64, cap: u64, duration_ns: u64) -> Option<(u128, u128)> {
    let (normalized_min, normalized_max) = allowed_delta_range(Profile::Adaptive, quantum, cap)?;
    let duration = u128::from(duration_ns);
    let scale = 100_000_000u128;
    let delta_min = normalized_min.checked_mul(duration)?.div_ceil(scale);
    let delta_max = if normalized_max == u128::from(u64::MAX) {
        u128::from(u64::MAX)
    } else {
        normalized_max
            .checked_add(1)?
            .checked_mul(duration)?
            .div_ceil(scale)
            .checked_sub(1)?
    };
    Some((delta_min, delta_max.min(u128::from(u64::MAX))))
}

fn temporal_run_values_feasible(
    decoded: &[u64],
    residual_max: &[u64],
    durations: &[u64],
    start: usize,
    end: usize,
    quantum: u64,
    cap: u64,
) -> bool {
    let mut reachable_min = u128::from(decoded[start]);
    let Some(mut reachable_max) = reachable_min.checked_add(u128::from(residual_max[start])) else {
        return false;
    };
    for index in start + 1..=end {
        let Some((delta_min, delta_max)) =
            temporal_allowed_delta_range(quantum, cap, durations[index - 1])
        else {
            return false;
        };
        let Some(next_min) = reachable_min.checked_add(delta_min) else {
            return false;
        };
        let Some(next_max) = reachable_max.checked_add(delta_max) else {
            return false;
        };
        reachable_min = next_min;
        reachable_max = next_max;
        let point_min = u128::from(decoded[index]);
        let point_max = (point_min + u128::from(residual_max[index])).min(u128::from(u64::MAX));
        reachable_min = reachable_min.max(point_min);
        reachable_max = reachable_max.min(point_max);
        if reachable_min > reachable_max {
            return false;
        }
    }
    true
}

fn decode_csh2_temporal(
    bytes: &[u8],
    profile: Profile,
    timebase: Timebase,
    rows: &mut [DecodedObservation],
    expected_metadata_points: usize,
) -> Result<()> {
    if !matches!(profile, Profile::AdaptiveInverse | Profile::AdaptiveLog)
        || bytes.len() < 5
        || &bytes[..4] != CSH2
        || bytes[4] != CSH2_VERSION
    {
        return Err("unsupported temporal CSH2 magic/version".into());
    }
    let mut offset = 5usize;
    let row_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
        .map_err(|_| "temporal CSH2 row count overflow")?;
    let segment_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
        .map_err(|_| "temporal CSH2 segment count overflow")?;
    let checkpoint_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
        .map_err(|_| "temporal CSH2 checkpoint count overflow")?;
    if row_count != rows.len()
        || row_count > MAX_POINTS
        || checkpoint_count > expected_metadata_points
        || checkpoint_count > MAX_POINTS
        || segment_count > checkpoint_count
        || segment_count > bytes.len().saturating_sub(offset) / 5
    {
        return Err("inconsistent temporal CSH2 counts".into());
    }
    let spans = decoded_temporal_spans(rows);
    let expected_segment_count = spans
        .values()
        .try_fold(0usize, |count, identity_spans| {
            count.checked_add(identity_spans.len())
        })
        .ok_or_else(|| "temporal CSH2 span count overflow".to_string())?;
    if segment_count != expected_segment_count {
        return Err("temporal CSH2 segments do not cover every metadata span".into());
    }
    let cap = timebase.quantum(LEGACY_CPU_NS)?;
    let mut expected_segments = spans.iter().flat_map(|(identity, identity_spans)| {
        let identity = *identity;
        identity_spans.iter().map(move |span| (identity, *span))
    });
    let mut previous_segment: Option<((u32, u64, u32), usize)> = None;
    let mut observed_checkpoints = 0usize;
    for _ in 0..segment_count {
        let pid = to_u32(read_uvarint(bytes, &mut offset)?, "temporal CSH2 pid")?;
        let start_sec = read_uvarint(bytes, &mut offset)?;
        let start_usec = to_u32(
            read_uvarint(bytes, &mut offset)?,
            "temporal CSH2 start_usec",
        )?;
        let identity = (pid, start_sec, start_usec);
        validate_meta_process(pid, 0, start_sec, start_usec, "")?;
        let count = usize::try_from(read_uvarint(bytes, &mut offset)?)
            .map_err(|_| "temporal CSH2 sample count overflow")?;
        if count == 0
            || count > checkpoint_count.saturating_sub(observed_checkpoints)
            || count > row_count
        {
            return Err("invalid temporal CSH2 sample count".into());
        }
        let mut row_indices = Vec::with_capacity(count);
        let mut prior_index = 0usize;
        for index in 0..count {
            let delta = usize::try_from(read_uvarint(bytes, &mut offset)?)
                .map_err(|_| "temporal CSH2 row index overflow")?;
            let row_index = if index == 0 {
                delta
            } else {
                prior_index
                    .checked_add(delta)
                    .ok_or_else(|| "temporal CSH2 row index overflow".to_string())?
            };
            if row_index >= row_count || index > 0 && delta == 0 {
                return Err("temporal CSH2 row indices are not strictly increasing".into());
            }
            row_indices.push(row_index);
            prior_index = row_index;
        }
        let first_index = *row_indices
            .first()
            .ok_or_else(|| "empty temporal segment".to_string())?;
        let last_index = *row_indices.last().unwrap();
        let Some((expected_identity, expected_span)) = expected_segments.next() else {
            return Err("temporal CSH2 contains an unclaimed segment".into());
        };
        if identity != expected_identity
            || first_index != expected_span.first
            || last_index != expected_span.last
        {
            return Err("temporal CSH2 segment misses a metadata span endpoint".into());
        }
        if let Some((prior_identity, prior_end)) = previous_segment
            && (identity < prior_identity || identity == prior_identity && first_index <= prior_end)
        {
            return Err("temporal CSH2 segments are not in canonical order".into());
        }
        previous_segment = Some((identity, last_index));

        let first_total = read_uvarint(bytes, &mut offset)?;
        let interval_count = count - 1;
        let run_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
            .map_err(|_| "temporal CSH2 run count overflow")?;
        if (interval_count == 0 && run_count != 0)
            || (interval_count > 0 && (run_count == 0 || run_count > interval_count))
            || run_count > bytes.len().saturating_sub(offset) / 2
        {
            return Err("invalid temporal CSH2 run count".into());
        }
        let mut cpus = Vec::with_capacity(count);
        let mut bounds = Vec::with_capacity(count);
        let mut durations = Vec::with_capacity(interval_count);
        cpus.push(first_total);
        bounds.push(0u64);
        let mut completed_intervals = 0usize;
        let mut previous_quantum = None;
        for _ in 0..run_count {
            let run_intervals = usize::try_from(read_uvarint(bytes, &mut offset)?)
                .map_err(|_| "temporal CSH2 run length overflow")?;
            let quantum = read_uvarint(bytes, &mut offset)?;
            if run_intervals == 0
                || run_intervals > interval_count.saturating_sub(completed_intervals)
                || quantum == 0
                || quantum > cap
                || (quantum != cap && !quantum.is_power_of_two())
                || previous_quantum == Some(quantum)
            {
                return Err("invalid/noncanonical temporal CSH2 run".into());
            }
            previous_quantum = Some(quantum);
            let start_point = completed_intervals;
            let end_point = start_point
                .checked_add(run_intervals)
                .ok_or_else(|| "temporal CSH2 run end overflow".to_string())?;
            let anchor = *cpus
                .last()
                .ok_or_else(|| "empty temporal CPU track".to_string())?;
            for _ in start_point + 1..end_point {
                let quotient = read_uvarint(bytes, &mut offset)?;
                let value = quotient
                    .checked_mul(quantum)
                    .and_then(|value| anchor.checked_add(value))
                    .ok_or_else(|| "temporal CSH2 interior CPU value overflow".to_string())?;
                if value < *cpus.last().unwrap() {
                    return Err("temporal CSH2 interior CPU value regresses".into());
                }
                cpus.push(value);
                bounds.push(quantum - 1);
            }
            let endpoint_delta = read_uvarint(bytes, &mut offset)?;
            let endpoint = anchor
                .checked_add(endpoint_delta)
                .ok_or_else(|| "temporal CSH2 endpoint CPU overflow".to_string())?;
            if endpoint < *cpus.last().unwrap() {
                return Err("temporal CSH2 exact run endpoint regresses".into());
            }
            cpus.push(endpoint);
            bounds.push(0);
            for point in completed_intervals..end_point {
                let start_row = row_indices[point];
                let end_row = row_indices[point + 1];
                if !decoded_temporal_interval_covered(rows, identity, start_row, end_row) {
                    return Err("temporal CSH2 interval bridges unknown CPU coverage".into());
                }
                let duration = rows[end_row]
                    .scan_start_ns
                    .checked_sub(rows[start_row].scan_start_ns)
                    .filter(|duration| *duration > 0)
                    .ok_or_else(|| "temporal CSH2 interval has invalid duration".to_string())?;
                durations.push(duration);
            }
            if !temporal_run_values_feasible(
                &cpus,
                &bounds,
                &durations,
                start_point,
                end_point,
                quantum,
                cap,
            ) {
                return Err("temporal CSH2 run has no feasible source counter sequence".into());
            }
            completed_intervals = end_point;
        }
        if completed_intervals != interval_count
            || cpus.len() != count
            || bounds.len() != count
            || durations.len() != interval_count
        {
            return Err("temporal CSH2 runs do not cover all intervals".into());
        }
        for point_index in 0..count {
            let row_index = row_indices[point_index];
            let process_index = rows[row_index]
                .processes
                .binary_search_by_key(&identity, DecodedProcess::identity)
                .map_err(|_| "temporal CSH2 identity absent from metadata")?;
            let interval = if point_index == 0 {
                None
            } else {
                let start_index = row_indices[point_index - 1];
                let start = &rows[start_index];
                let end = &rows[row_index];
                let delta = cpus[point_index]
                    .checked_sub(cpus[point_index - 1])
                    .ok_or_else(|| "temporal CSH2 CPU total regressed".to_string())?;
                Some(CpuInterval {
                    start_seq: start.seq,
                    start_time_ns: start.scan_start_ns,
                    end_time_ns: end.scan_start_ns,
                    duration_ns: durations[point_index - 1],
                    delta,
                    error_bound: bounds[point_index].max(bounds[point_index - 1]),
                })
            };
            let process = &mut rows[row_index].processes[process_index];
            if process.cpu.is_some() {
                return Err("duplicate temporal CSH2 CPU checkpoint".into());
            }
            process.cpu = Some(CpuCheckpoint {
                total: cpus[point_index],
                error_bound: bounds[point_index],
                components: None,
                interval,
            });
            observed_checkpoints = observed_checkpoints
                .checked_add(1)
                .ok_or_else(|| "temporal CSH2 checkpoint count overflow".to_string())?;
        }
    }
    if expected_segments.next().is_some()
        || observed_checkpoints != checkpoint_count
        || offset != bytes.len()
    {
        return Err("temporal CSH2 coverage/count mismatch or trailing bytes".into());
    }
    Ok(())
}

fn decoded_temporal_interval_covered(
    rows: &[DecodedObservation],
    identity: (u32, u64, u32),
    start: usize,
    end: usize,
) -> bool {
    if end <= start || end >= rows.len() {
        return false;
    }
    for index in start + 1..=end {
        if rows[index].seq != rows[index - 1].seq.saturating_add(1)
            || rows[index]
                .processes
                .binary_search_by_key(&identity, DecodedProcess::identity)
                .is_err()
            || decoded_temporal_quality_boundary(&rows[index], identity)
        {
            return false;
        }
    }
    true
}

fn decoded_temporal_quality_boundary(row: &DecodedObservation, identity: (u32, u64, u32)) -> bool {
    decoded_temporal_quality_values_boundary(&row.quality, identity)
}

fn decoded_temporal_quality_values_boundary(
    qualities: &[Value],
    identity: (u32, u64, u32),
) -> bool {
    qualities.iter().any(|quality| {
        let kind = quality.get("kind").and_then(Value::as_str).unwrap_or("");
        let id = quality.get("identity");
        let targeted = id.is_some_and(|id| {
            id.get("pid").and_then(Value::as_u64) == Some(u64::from(identity.0))
                && id.get("start_sec").and_then(Value::as_u64) == Some(identity.1)
                && id.get("start_usec").and_then(Value::as_u64) == Some(u64::from(identity.2))
        });
        let continuity_unknown = kind.contains("continuity-unknown");
        targeted && (continuity_unknown || kind == "cpu-component-regression")
            || continuity_unknown && id.is_none()
            || kind.contains("acquisition-gap")
            || matches!(kind, "gap" | "source-gap" | "sequence-gap") && id.is_none()
    })
}

fn decode_csh2(
    bytes: &[u8],
    profile: Profile,
    timebase: Timebase,
    rows: &mut [DecodedObservation],
    expected_points: usize,
) -> Result<()> {
    if bytes.len() < 5 || &bytes[..4] != CSH2 {
        return Err("unsupported CSH2 magic/version".into());
    }
    let wire_version = bytes[4];
    if wire_version != CSH2_ABSOLUTE_ENDPOINT_VERSION && wire_version != CSH2_VERSION {
        return Err("unsupported CSH2 magic/version".into());
    }
    let mut offset = 5;
    let row_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
        .map_err(|_| "CSH2 row count overflow")?;
    let identity_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
        .map_err(|_| "CSH2 identity count overflow")?;
    let point_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
        .map_err(|_| "CSH2 point count overflow")?;
    if row_count != rows.len()
        || row_count > MAX_POINTS
        || point_count != expected_points
        || point_count > MAX_POINTS
        || identity_count > point_count
        || identity_count > bytes.len().saturating_sub(offset) / 4
    {
        return Err("inconsistent CSH2 counts".into());
    }
    let cap = match profile {
        Profile::Adaptive => timebase.quantum(LEGACY_CPU_NS)?,
        Profile::Fixed100us => timebase.quantum(FIXED_100US_NS)?,
        Profile::AdaptiveInverse | Profile::AdaptiveLog => {
            return Err("temporal profile requires the temporal CSH2 body".into());
        }
        Profile::Legacy1ms => return Err("legacy profile cannot use CSH2".into()),
    };
    let mut previous_identity = None;
    let mut observed_points = 0usize;
    for _ in 0..identity_count {
        let pid = to_u32(read_uvarint(bytes, &mut offset)?, "CSH2 pid")?;
        let start_sec = read_uvarint(bytes, &mut offset)?;
        let start_usec = to_u32(read_uvarint(bytes, &mut offset)?, "CSH2 start_usec")?;
        let identity = (pid, start_sec, start_usec);
        validate_meta_process(pid, 0, start_sec, start_usec, "")?;
        if previous_identity.is_some_and(|old| identity <= old) {
            return Err("CSH2 identities are not sorted".into());
        }
        previous_identity = Some(identity);
        let count = usize::try_from(read_uvarint(bytes, &mut offset)?)
            .map_err(|_| "CSH2 sample count overflow")?;
        if count == 0 || count > row_count || count > point_count.saturating_sub(observed_points) {
            return Err("invalid CSH2 sample count".into());
        }
        observed_points = observed_points
            .checked_add(count)
            .ok_or_else(|| "CSH2 point count overflow".to_string())?;
        let mut row_indices = Vec::with_capacity(count);
        let mut prior = 0usize;
        for index in 0..count {
            let delta = usize::try_from(read_uvarint(bytes, &mut offset)?)
                .map_err(|_| "CSH2 row index overflow")?;
            let row_index = if index == 0 {
                delta
            } else {
                prior
                    .checked_add(delta)
                    .ok_or_else(|| "CSH2 row index overflow".to_string())?
            };
            if (index > 0 && delta == 0) || row_index >= row_count {
                return Err("CSH2 row indices are not strictly increasing".into());
            }
            row_indices.push(row_index);
            prior = row_index;
        }
        let first_cpu = read_uvarint(bytes, &mut offset)?;
        let run_count = usize::try_from(read_uvarint(bytes, &mut offset)?)
            .map_err(|_| "CSH2 run count overflow")?;
        let interval_count = count.saturating_sub(1);
        if (interval_count == 0 && run_count != 0)
            || (interval_count > 0 && (run_count == 0 || run_count > interval_count))
            || run_count > bytes.len().saturating_sub(offset) / 2
        {
            return Err("invalid CSH2 run count".into());
        }
        let mut cpus = Vec::with_capacity(count);
        let mut bounds = Vec::with_capacity(count);
        cpus.push(first_cpu);
        bounds.push(0u64);
        let mut completed_intervals = 0usize;
        let mut previous_quantum = None;
        for _ in 0..run_count {
            let run_intervals = usize::try_from(read_uvarint(bytes, &mut offset)?)
                .map_err(|_| "CSH2 run length overflow")?;
            let q = read_uvarint(bytes, &mut offset)?;
            if run_intervals == 0
                || run_intervals > interval_count.saturating_sub(completed_intervals)
                || q == 0
                || q > cap
            {
                return Err("invalid CSH2 run length/quantum".into());
            }
            if previous_quantum == Some(q) {
                return Err("adjacent CSH2 runs are not maximal".into());
            }
            previous_quantum = Some(q);
            if profile == Profile::Adaptive && q != cap && !q.is_power_of_two() {
                return Err("adaptive CSH2 quantum is not a power of two or 1 ms cap".into());
            }
            if profile == Profile::Fixed100us && q != 1 && q != cap {
                return Err("fixed-100us CSH2 quantum is unsupported".into());
            }
            let anchor = *cpus
                .last()
                .ok_or_else(|| "empty CSH2 CPU track".to_string())?;
            let end_point = completed_intervals
                .checked_add(run_intervals)
                .ok_or_else(|| "CSH2 run end overflow".to_string())?;
            for _ in completed_intervals + 1..end_point {
                let quotient = read_uvarint(bytes, &mut offset)?;
                let value = quotient
                    .checked_mul(q)
                    .and_then(|v| anchor.checked_add(v))
                    .ok_or_else(|| "CSH2 interior CPU value overflow".to_string())?;
                if value
                    < *cpus
                        .last()
                        .ok_or_else(|| "empty CSH2 CPU track".to_string())?
                {
                    return Err("CSH2 interior CPU values regress".into());
                }
                cpus.push(value);
                bounds.push(q - 1);
            }
            let encoded_endpoint = read_uvarint(bytes, &mut offset)?;
            let endpoint = if wire_version == CSH2_ABSOLUTE_ENDPOINT_VERSION {
                encoded_endpoint
            } else {
                anchor
                    .checked_add(encoded_endpoint)
                    .ok_or_else(|| "CSH2 run endpoint overflow".to_string())?
            };
            if endpoint
                < *cpus
                    .last()
                    .ok_or_else(|| "empty CSH2 CPU track".to_string())?
            {
                return Err("CSH2 exact run endpoint regresses".into());
            }
            cpus.push(endpoint);
            bounds.push(0);
            for point in completed_intervals + 1..=end_point {
                let estimate = cpus[point] - cpus[point - 1];
                if profile == Profile::Adaptive && q > 1 && estimate == 0 {
                    return Err("adaptive positive interval vanished".into());
                }
            }
            if !run_values_feasible(
                &cpus,
                &bounds,
                completed_intervals,
                end_point,
                q,
                cap,
                profile,
            ) {
                return Err("CSH2 run has no feasible source counter sequence".into());
            }
            completed_intervals = end_point;
        }
        if completed_intervals != interval_count || cpus.len() != count || bounds.len() != count {
            return Err("CSH2 runs do not cover all intervals".into());
        }
        let mut previous_checkpoint: Option<(usize, u64, u64)> = None;
        for (point_index, ((row_index, cpu), error_bound)) in
            row_indices.into_iter().zip(cpus).zip(bounds).enumerate()
        {
            let exact_bound = if point_index == 0 || point_index + 1 == count {
                0
            } else {
                error_bound
            };
            let interval =
                previous_checkpoint.and_then(|(previous_row, previous_cpu, previous_bound)| {
                    let start = &rows[previous_row];
                    let end = &rows[row_index];
                    if row_index != previous_row + 1
                        || end.seq != start.seq.saturating_add(1)
                        || decoded_temporal_quality_boundary(end, identity)
                    {
                        return None;
                    }
                    let duration = end.scan_start_ns.checked_sub(start.scan_start_ns)?;
                    let delta = cpu.checked_sub(previous_cpu)?;
                    Some(CpuInterval {
                        start_seq: start.seq,
                        start_time_ns: start.scan_start_ns,
                        end_time_ns: end.scan_start_ns,
                        duration_ns: duration,
                        delta,
                        error_bound: error_bound.saturating_add(previous_bound),
                    })
                });
            let row = rows
                .get_mut(row_index)
                .ok_or_else(|| "CSH2 row index out of range".to_string())?;
            let pindex = row
                .processes
                .binary_search_by_key(&identity, DecodedProcess::identity)
                .map_err(|_| "CSH2 identity absent from metadata")?;
            let process = row
                .processes
                .get_mut(pindex)
                .ok_or_else(|| "CSH2 process index out of range".to_string())?;
            if process.cpu.is_some() {
                return Err("duplicate CSH2 CPU sample".into());
            }
            process.cpu = Some(CpuCheckpoint {
                total: cpu,
                error_bound: exact_bound,
                components: None,
                interval,
            });
            previous_checkpoint = Some((row_index, cpu, exact_bound));
        }
    }
    if observed_points != point_count {
        return Err("CSH2 point count mismatch".into());
    }
    if offset != bytes.len() {
        return Err("trailing CSH2 bytes".into());
    }
    let mut metadata_points = 0usize;
    for row in rows.iter() {
        metadata_points = metadata_points
            .checked_add(row.processes.len())
            .ok_or_else(|| "metadata point count overflow".to_string())?;
        if row.processes.iter().any(|process| process.cpu.is_none()) {
            return Err("PST2 process has no CSH2 CPU sample".into());
        }
    }
    if metadata_points != point_count {
        return Err("CPU and metadata point counts differ".into());
    }
    Ok(())
}

fn allowed_delta_range(profile: Profile, quantum: u64, cap: u64) -> Option<(u128, u128)> {
    match profile {
        Profile::Adaptive if cap == 1 && quantum == 1 => Some((0, u128::from(u64::MAX))),
        Profile::Adaptive if cap > 1 && quantum == 1 => Some((0, 15)),
        Profile::Adaptive if quantum == cap && cap > 1 => {
            let rounded_cap = if cap.is_power_of_two() {
                u128::from(cap)
            } else {
                1u128 << (64 - cap.leading_zeros())
            };
            Some((8 * rounded_cap, u128::from(u64::MAX)))
        }
        Profile::Adaptive if quantum > 1 && quantum < cap && quantum.is_power_of_two() => {
            Some((8 * u128::from(quantum), 16 * u128::from(quantum) - 1))
        }
        Profile::Fixed100us if cap == 1 && quantum == 1 => Some((0, u128::from(u64::MAX))),
        Profile::Fixed100us if cap > 1 && quantum == 1 => Some((0, 0)),
        Profile::Fixed100us if cap > 1 && quantum == cap => Some((1, u128::from(u64::MAX))),
        _ => None,
    }
}

fn run_values_feasible(
    decoded: &[u64],
    residual_max: &[u64],
    start: usize,
    end: usize,
    quantum: u64,
    cap: u64,
    profile: Profile,
) -> bool {
    let Some((delta_min, delta_max)) = allowed_delta_range(profile, quantum, cap) else {
        return false;
    };
    let mut reachable_min = u128::from(decoded[start]);
    let mut reachable_max = reachable_min;
    for index in start + 1..=end {
        reachable_min = reachable_min.saturating_add(delta_min);
        reachable_max = reachable_max.saturating_add(delta_max);
        let point_min = u128::from(decoded[index]);
        let point_max = (point_min + u128::from(residual_max[index])).min(u128::from(u64::MAX));
        reachable_min = reachable_min.max(point_min);
        reachable_max = reachable_max.min(point_max);
        if reachable_min > reachable_max {
            return false;
        }
    }
    true
}

fn finish_decoded_rows(
    rows: Vec<MetaRow>,
    context: Context,
    profile: Profile,
) -> Result<DecodedBlock> {
    let mut output = Vec::with_capacity(rows.len());
    let mut previous_cpu = HashMap::<(u32, u64, u32), (usize, u64, u64, u64, u64)>::new();
    let mut previous_seq = None;
    let mut previous_scan = None;
    for (row_index, row) in rows.into_iter().enumerate() {
        if previous_seq.is_some_and(|seq| row.seq <= seq)
            || previous_scan.is_some_and(|stamp| row.scan_start_ns <= stamp)
        {
            return Err("decoded row sequence/scan clocks are not strictly increasing".into());
        }
        previous_seq = Some(row.seq);
        previous_scan = Some(row.scan_start_ns);
        let MetaRow {
            seq,
            wall_start_ns,
            scan_start_ns,
            scan_end_ns,
            processes,
            quality,
        } = row;
        let processes = processes
            .into_iter()
            .map(MetaProcess::decoded)
            .collect::<Result<Vec<_>>>()?;
        let mut decoded_row = DecodedObservation {
            seq,
            wall_start_ns,
            scan_start_ns,
            scan_end_ns,
            processes,
            quality,
        };
        let quality = &decoded_row.quality;
        for process in &mut decoded_row.processes {
            let identity = process.identity();
            if let Some((prior_index, prior_seq, prior_time, prior_total, prior_bound)) =
                previous_cpu.get(&identity).copied()
                && prior_index + 1 == row_index
                && prior_seq.saturating_add(1) == seq
                && !decoded_temporal_quality_values_boundary(quality, identity)
                && let Some(cpu) = process.cpu.as_mut()
                && let Some(delta) = cpu.total.checked_sub(prior_total)
            {
                cpu.interval = Some(CpuInterval {
                    start_seq: prior_seq,
                    start_time_ns: prior_time,
                    end_time_ns: scan_start_ns,
                    duration_ns: scan_start_ns - prior_time,
                    delta,
                    error_bound: cpu.error_bound.saturating_add(prior_bound),
                });
            }
            if let Some(cpu) = &process.cpu {
                previous_cpu.insert(
                    identity,
                    (row_index, seq, scan_start_ns, cpu.total, cpu.error_bound),
                );
            }
        }
        output.push(decoded_row);
    }
    Ok(DecodedBlock {
        context,
        profile,
        rows: output,
        memory: None,
    })
}

fn validate_meta_clocks(rows: &[MetaRow]) -> Result<()> {
    let mut previous_seq = None;
    let mut previous_scan = None;
    for row in rows {
        if row.scan_end_ns < row.scan_start_ns
            || previous_seq.is_some_and(|seq| row.seq <= seq)
            || previous_scan.is_some_and(|stamp| row.scan_start_ns <= stamp)
        {
            return Err("PSD1 row clocks are invalid or unsorted".into());
        }
        previous_seq = Some(row.seq);
        previous_scan = Some(row.scan_start_ns);
    }
    Ok(())
}

fn validate_meta_process(
    pid: u32,
    ppid: u32,
    _start_sec: u64,
    start_usec: u32,
    name: &str,
) -> Result<()> {
    if pid == 0
        || pid > i32::MAX as u32
        || ppid > i32::MAX as u32
        || start_usec >= 1_000_000
        || name.len() > MAX_NAME_BYTES
    {
        return Err("invalid process identity or name in metadata".into());
    }
    Ok(())
}

fn to_u32(value: u64, label: &str) -> Result<u32> {
    u32::try_from(value).map_err(|_| format!("{label} exceeds u32"))
}

fn add_signed_u64(value: u64, delta: i128, label: &str) -> Result<u64> {
    let updated = i128::from(value)
        .checked_add(delta)
        .ok_or_else(|| format!("{label} overflow"))?;
    u64::try_from(updated).map_err(|_| format!("{label} outside u64 range"))
}
fn add_signed_i64(value: i64, delta: i128, label: &str) -> Result<i64> {
    let updated = i128::from(value)
        .checked_add(delta)
        .ok_or_else(|| format!("{label} overflow"))?;
    i64::try_from(updated).map_err(|_| format!("{label} outside i64 range"))
}

fn json_bytes<T: Serialize>(value: &T, limit: usize) -> Result<Vec<u8>> {
    let mut out = LimitedVec::new(limit);
    serde_json::to_writer(&mut out, value).map_err(|e| format!("JSON encoding failed: {e}"))?;
    Ok(out.into_inner())
}
fn parse_json<T: DeserializeOwned>(bytes: &[u8]) -> Result<T> {
    json_expansion_cost(bytes)?;
    serde_json::from_slice(bytes).map_err(|e| format!("invalid recording JSON section: {e}"))
}

// Bound serde_json's expanded representation before parsing. A tiny scalar can
// occupy a much larger Value/container slot, so input byte limits alone are not
// enough for attacker-controlled quality arrays and source headers.
fn json_expansion_cost(bytes: &[u8]) -> Result<usize> {
    let mut i = 0usize;
    let mut cost = 0usize;
    while i < bytes.len() {
        match bytes[i] {
            b' ' | 10 | 13 | 9 | b',' | b':' | b']' | b'}' => i += 1,
            b'{' | b'[' => {
                cost = cost
                    .checked_add(48)
                    .ok_or_else(|| "JSON expansion estimate overflow".to_string())?;
                i += 1;
            }
            b'"' => {
                let start = i + 1;
                i = start;
                let mut closed = false;
                while i < bytes.len() {
                    match bytes[i] {
                        92 => i = i.saturating_add(2),
                        b'"' => {
                            closed = true;
                            break;
                        }
                        _ => i += 1,
                    }
                }
                if !closed {
                    return Err("unterminated JSON string".into());
                }
                let raw_len = i - start;
                cost = cost
                    .checked_add(64)
                    .and_then(|n| n.checked_add(raw_len))
                    .ok_or_else(|| "JSON expansion estimate overflow".to_string())?;
                i += 1;
            }
            _ => {
                let start = i;
                while i < bytes.len()
                    && !matches!(
                        bytes[i],
                        b' ' | 10 | 13 | 9 | b',' | b':' | b']' | b'}' | b'{' | b'[' | b'"'
                    )
                {
                    i += 1;
                }
                if i == start {
                    i += 1;
                }
                // Account for the Value plus up to 2x Vec capacity growth.
                cost = cost
                    .checked_add(64)
                    .ok_or_else(|| "JSON expansion estimate overflow".to_string())?;
            }
        }
        if cost > MAX_DECODED_BYTES {
            return Err("JSON expansion exceeds the bounded output limit".into());
        }
    }
    Ok(cost)
}
struct LimitedVec {
    bytes: Vec<u8>,
    limit: usize,
}
impl LimitedVec {
    fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
        }
    }
    fn into_inner(self) -> Vec<u8> {
        self.bytes
    }
}
impl Write for LimitedVec {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let end = self
            .bytes
            .len()
            .checked_add(bytes.len())
            .ok_or_else(|| io::Error::other("encoded section size overflow"))?;
        if end > self.limit {
            return Err(io::Error::other("encoded section exceeds block limit"));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn put_bytes(out: &mut Vec<u8>, bytes: &[u8]) -> Result<()> {
    let end = out
        .len()
        .checked_add(bytes.len())
        .ok_or_else(|| "wire length overflow".to_string())?;
    if end > MAX_BLOCK_BYTES {
        return Err("recording section exceeds 64 MiB".into());
    }
    out.extend_from_slice(bytes);
    Ok(())
}
fn check_wire_size(out: &[u8]) -> Result<()> {
    if out.len() > MAX_BLOCK_BYTES {
        Err("recording section exceeds 64 MiB".into())
    } else {
        Ok(())
    }
}
fn put_uvarint(out: &mut Vec<u8>, mut value: u64) -> Result<()> {
    while value >= 0x80 {
        put_bytes(out, &[((value & 0x7f) as u8) | 0x80])?;
        value >>= 7;
    }
    put_bytes(out, &[value as u8])
}
fn put_svarint(out: &mut Vec<u8>, value: i128) -> Result<()> {
    let encoded = if value >= 0 {
        u128::try_from(value)
            .map_err(|_| "signed varint overflow")?
            .checked_mul(2)
    } else {
        value
            .checked_neg()
            .and_then(|v| u128::try_from(v).ok())
            .and_then(|v| v.checked_mul(2))
            .and_then(|v| v.checked_sub(1))
    }
    .ok_or_else(|| "signed varint overflow".to_string())?;
    put_uvarint128(out, encoded)
}
fn put_uvarint128(out: &mut Vec<u8>, mut value: u128) -> Result<()> {
    while value >= 0x80 {
        put_bytes(out, &[((value & 0x7f) as u8) | 0x80])?;
        value >>= 7;
    }
    put_bytes(out, &[value as u8])
}
fn put_string(out: &mut Vec<u8>, value: &str) -> Result<()> {
    let bytes = value.as_bytes();
    if bytes.len() > MAX_NAME_BYTES {
        return Err("process name exceeds supported limit".into());
    }
    put_uvarint(out, bytes.len() as u64)?;
    put_bytes(out, bytes)
}
fn read_uvarint(bytes: &[u8], offset: &mut usize) -> Result<u64> {
    u64::try_from(read_uvarint128(bytes, offset)?).map_err(|_| "unsigned varint exceeds u64".into())
}
fn read_svarint(bytes: &[u8], offset: &mut usize) -> Result<i128> {
    let encoded = read_uvarint128(bytes, offset)?;
    if encoded & 1 == 0 {
        i128::try_from(encoded / 2).map_err(|_| "signed varint exceeds supported range".into())
    } else {
        i128::try_from(encoded / 2)
            .map(|value| -value - 1)
            .map_err(|_| "signed varint exceeds supported range".into())
    }
}
fn read_uvarint128(bytes: &[u8], offset: &mut usize) -> Result<u128> {
    let start = *offset;
    let mut value = 0u128;
    for index in 0..19 {
        let byte = *bytes
            .get(*offset)
            .ok_or_else(|| "truncated varint".to_string())?;
        *offset = (*offset)
            .checked_add(1)
            .ok_or_else(|| "varint offset overflow".to_string())?;
        if index == 18 && byte > 3 {
            return Err("varint overflow".into());
        }
        value |= u128::from(byte & 0x7f) << (index * 7);
        if byte & 0x80 == 0 {
            let encoded_len = *offset - start;
            if encoded_len > 1 && byte == 0 {
                return Err("noncanonical varint".into());
            }
            return Ok(value);
        }
    }
    Err("varint overflow".into())
}
fn read_string(bytes: &[u8], offset: &mut usize) -> Result<String> {
    let length =
        usize::try_from(read_uvarint(bytes, offset)?).map_err(|_| "string length overflow")?;
    if length > MAX_NAME_BYTES {
        return Err("process name exceeds supported limit".into());
    }
    let end = offset
        .checked_add(length)
        .ok_or_else(|| "string length overflow".to_string())?;
    let value = bytes
        .get(*offset..end)
        .ok_or_else(|| "truncated process name".to_string())?;
    let result = std::str::from_utf8(value)
        .map_err(|_| "invalid UTF-8 process name")?
        .to_owned();
    *offset = end;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> Context {
        Context::new(Timebase {
            numer: 125,
            denom: 3,
        })
    }
    fn row(seq: u64, scan: u64, cpu: u64) -> Observation {
        Observation {
            seq,
            wall_start_ns: 1_700_000_000_000_000_000i64 + seq as i64 * 100_000_000,
            scan_start_ns: scan,
            scan_end_ns: scan + 1000,
            processes: vec![Process {
                pid: 42,
                ppid: 1,
                start_sec: 123,
                start_usec: 4,
                name: "tiny λ".into(),
                user: cpu,
                system: 0,
                rss: 1_048_575,
                owned: None,
                peak: None,
                evicted: None,
            }],
            quality: vec![],
        }
    }

    #[test]
    fn legacy_pst1_matches_python_control_golden() {
        let rows = [Observation {
            seq: 0,
            wall_start_ns: -2,
            scan_start_ns: 0,
            scan_end_ns: 3,
            processes: vec![Process {
                pid: 7,
                ppid: 1,
                start_sec: 2,
                start_usec: 3,
                name: "x".into(),
                user: 100,
                system: 20,
                rss: 1_048_575,
                owned: None,
                peak: None,
                evicted: None,
            }],
            quality: vec![],
        }];
        // Golden was generated independently with recording_storage._encode_block,
        // recording_codec.encode_sparse, and recording_cpu_shared.encode_shared.
        let expected = hex(concat!(
            "50535431d3017b22616c6c5f6f62736572766174696f6e735f6b657074223a747275652c",
            "226370755f7175616e74756d5f6e61746976655f7469636b73223a32343030302c",
            "226370755f74696d65626173655f6d616368223a5b3132352c335d2c",
            "226c61796f7574223a226d61736b222c227273735f736368656d65223a223235366b222c",
            "227273735f756e69745f6279746573223a3236323134342c",
            "22736368656d61223a227265636f7264696e672d73746f726167652d626c6f636b2d7631222c",
            "2274696d657374616d705f756e69745f6e73223a317d",
            "1b4353483100c0bb01017d0301010100000702030101000100007878",
            "15505344310100030003010001070203010178000003"
        ));
        let encoded = encode_block(&context(), &rows, Profile::Legacy1ms).unwrap();
        assert_eq!(encoded, expected);
        assert_eq!(&encoded[..4], PST1);
        let decoded = decode_block(&encoded).unwrap();
        assert_eq!(decoded.rows.len(), 1);
        let process = &decoded.rows[0].processes[0];
        assert_eq!(process.cpu.as_ref().unwrap().total, 120);
        assert_eq!(process.rss, 786_432);
        assert_eq!(process.cpu.as_ref().unwrap().components, None);
        assert_eq!(decoded.rows[0].wall_start_ns, -2);
    }

    #[test]
    fn adaptive_context_quality_and_missing_returning_empty_rows_roundtrip() {
        let mut ctx = context();
        ctx.hz = 17;
        ctx.capture_run_id = Some("run-λ".into());
        ctx.boot_id = Some("boot-1".into());
        ctx.clock = "mach_continuous_time".into();
        ctx.source_headers = vec![serde_json::json!({"probe_capture": 1, "custom": ["x", 4]})];
        let mut first = row(10, 1_000, 200);
        first.quality = vec![serde_json::json!({"kind":"gap", "count":2})];
        let empty = Observation {
            seq: 11,
            wall_start_ns: -9,
            scan_start_ns: 2_000,
            scan_end_ns: 2_500,
            processes: vec![],
            quality: vec![serde_json::json!("empty")],
        };
        let mut returned = row(12, 4_000, 250);
        returned.processes[0].name = "renamed".into();
        let bytes = encode_block(
            &ctx,
            &[first.clone(), empty.clone(), returned.clone()],
            Profile::Adaptive,
        )
        .unwrap();
        assert_eq!(&bytes[..4], PST2);
        let decoded = decode_block(&bytes).unwrap();
        assert_eq!(decoded.context, ctx);
        assert_eq!(decoded.profile, Profile::Adaptive);
        assert_eq!(decoded.rows[0].quality, first.quality);
        assert_eq!(decoded.rows[1].processes.len(), 0);
        assert_eq!(decoded.rows[1].quality, empty.quality);
        assert_eq!(decoded.rows[2].processes[0].name, "renamed");
        assert_eq!(
            decoded.rows[0].processes[0].cpu.as_ref().unwrap().total,
            200
        );
        assert_eq!(
            decoded.rows[2].processes[0].cpu.as_ref().unwrap().total,
            250
        );
        assert_eq!(decoded.rows[0].processes[0].rss, 786_432);
    }

    #[test]
    fn pst2_reuses_psd1_metadata_and_stays_compact_for_repeated_processes() {
        let mut first = row(0, 0, 0);
        first.processes[0].name = "x".repeat(1_024);
        let rows: Vec<_> = (0..80)
            .map(|index| {
                let mut current = first.clone();
                current.seq = index;
                current.scan_start_ns = index * 100_000_000;
                current.scan_end_ns = current.scan_start_ns + 1_000;
                current.processes[0].user = index * 100;
                current
            })
            .collect();
        let legacy = encode_block(&context(), &rows, Profile::Legacy1ms).unwrap();
        let adaptive = encode_block(&context(), &rows, Profile::Adaptive).unwrap();
        let [_, _, legacy_metadata] = unpack_sections(&legacy).unwrap();
        let [_, _, adaptive_metadata] = unpack_sections(&adaptive).unwrap();
        assert_eq!(adaptive_metadata, legacy_metadata);
        assert_eq!(&adaptive_metadata[..4], PSD1);
        assert!(adaptive_metadata.len() < rows.len() * 1_024 / 10);
    }

    #[test]
    fn pst2_quality_count_must_match_metadata_rows() {
        let mut first = row(0, 0, 10);
        first.quality = vec![serde_json::json!({"kind":"gap"})];
        let rows = [first, row(1, 100_000_000, 20)];
        let bytes = encode_block(&context(), &rows, Profile::Adaptive).unwrap();
        let [header, cpu, metadata] = unpack_sections(&bytes).unwrap();
        let mut header: Value = parse_json(header).unwrap();
        header["quality"].as_array_mut().unwrap().pop();
        let bad_header = json_bytes(&header, MAX_BLOCK_BYTES).unwrap();
        let malformed = pack_sections(PST2, &bad_header, cpu, metadata).unwrap();
        assert!(decode_block(&malformed).is_err());
    }

    #[test]
    fn pst2_preserves_first_and_last_native_zero_samples() {
        let first = row(0, 0, 0);
        let second = row(1, 100_000_000, 100);
        let mut final_process = row(2, 200_000_000, 0).processes.remove(0);
        final_process.pid = 43;
        let mut last = row(2, 200_000_000, 100);
        last.processes.push(final_process);
        let decoded = decode_block(
            &encode_block(&context(), &[first, second, last], Profile::Adaptive).unwrap(),
        )
        .unwrap();
        assert_eq!(decoded.rows[0].processes[0].cpu.as_ref().unwrap().total, 0);
        assert_eq!(decoded.rows[2].processes[1].pid, 43);
        assert_eq!(decoded.rows[2].processes[1].cpu.as_ref().unwrap().total, 0);
        assert_eq!(
            decoded.rows[0].processes[0]
                .cpu
                .as_ref()
                .unwrap()
                .components,
            None
        );
    }

    #[test]
    fn pst2_preserves_process_gaps_and_returns() {
        let first = row(0, 0, 50);
        let empty = Observation {
            seq: 1,
            wall_start_ns: 10,
            scan_start_ns: 100_000_000,
            scan_end_ns: 100_001_000,
            processes: vec![],
            quality: vec![],
        };
        let returned = row(2, 200_000_000, 150);
        let decoded = decode_block(
            &encode_block(&context(), &[first, empty, returned], Profile::Adaptive).unwrap(),
        )
        .unwrap();
        assert!(decoded.rows[1].processes.is_empty());
        assert_eq!(
            decoded.rows[2].processes[0].cpu.as_ref().unwrap().total,
            150
        );
    }

    #[test]
    fn pst2_preserves_rss_changes_after_flooring() {
        let mut first = row(0, 0, 10);
        first.processes[0].rss = 255_999;
        let mut second = row(1, 100_000_000, 20);
        second.processes[0].rss = 786_431;
        let decoded =
            decode_block(&encode_block(&context(), &[first, second], Profile::Adaptive).unwrap())
                .unwrap();
        assert_eq!(decoded.rows[0].processes[0].rss, 0);
        assert_eq!(decoded.rows[1].processes[0].rss, 524_288);
    }

    #[test]
    fn legacy_preserves_python_component_flags_and_all_other_quality() {
        let mut first = row(0, 0, 10);
        first.quality = (0..14)
            .map(|index| serde_json::json!({"kind":"cpu_component_decrease", "index":index}))
            .collect();
        let encoded = encode_block(&context(), &[first.clone()], Profile::Legacy1ms).unwrap();
        let [header_bytes, _, _] = unpack_sections(&encoded).unwrap();
        let header: Value = parse_json(header_bytes).unwrap();
        assert_eq!(
            header["cpu_component_discontinuities_before"]
                .as_array()
                .unwrap()
                .len(),
            14
        );
        assert!(header.get("quality").is_none());
        assert_eq!(
            decode_block(&encoded).unwrap().rows[0].quality,
            first.quality
        );

        let mut second = row(1, 100_000_000, 20);
        second.quality = vec![serde_json::json!({"kind":"other", "detail":[1,2]})];
        let rows = [row(0, 0, 10), second];
        let encoded = encode_block(&context(), &rows, Profile::Legacy1ms).unwrap();
        let [header_bytes, _, _] = unpack_sections(&encoded).unwrap();
        let header: Value = parse_json(header_bytes).unwrap();
        assert_eq!(header["quality"].as_array().unwrap().len(), 2);
        assert_eq!(
            decode_block(&encoded).unwrap().rows[1].quality,
            rows[1].quality
        );
    }

    #[test]
    fn adaptive_runs_keep_zero_positive_and_exact_track_ends() {
        for values in [
            vec![0, 101, 101],
            vec![0, 101, 101, 202, 303, 303],
            vec![
                9_000_000, 9_000_000, 9_000_016, 9_000_031, 9_000_031, 9_000_200,
            ],
        ] {
            let rows: Vec<_> = values
                .iter()
                .enumerate()
                .map(|(i, value)| row(i as u64, i as u64 * 100_000_000, *value))
                .collect();
            let decoded =
                decode_block(&encode_block(&context(), &rows, Profile::Adaptive).unwrap()).unwrap();
            let points: Vec<_> = decoded
                .rows
                .iter()
                .map(|r| r.processes[0].cpu.as_ref().unwrap().total)
                .collect();
            assert_eq!(points[0], values[0]);
            assert_eq!(*points.last().unwrap(), *values.last().unwrap());
            for i in 1..values.len() {
                let delta = values[i] - values[i - 1];
                let got = points[i] - points[i - 1];
                assert_eq!(delta == 0, got == 0);
                let q = adaptive_q(delta, context().cpu_timebase).unwrap();
                assert!(delta.abs_diff(got) < q);
                if delta > 0 {
                    assert!(8 * delta.abs_diff(got) < delta);
                }
            }
        }
    }

    #[test]
    fn csh2_multirun_golden_covers_quotients_shared_anchors_and_return_gaps() {
        let cpu_values = [
            (0, 1_000),
            (1, 1_160),
            (3, 1_400),
            (4, 1_800),
            (6, 2_280),
            (7, 2_280),
            (9, 2_440),
        ];
        let rows: Vec<_> = (0..10)
            .map(|seq| {
                let mut observation = row(seq, seq * 100, 0);
                if let Some((_, cpu)) = cpu_values.iter().find(|(index, _)| *index == seq) {
                    observation.processes[0].user = *cpu;
                } else {
                    observation.processes.clear();
                }
                observation
            })
            .collect();
        let encoded = encode_block(&context(), &rows, Profile::Adaptive).unwrap();
        let [header, encoded_cpu, metadata] = unpack_sections(&encoded).unwrap();
        let cpu = hex(concat!(
            "4353483202",     // CSH2, version 2
            "0a0107",         // ten rows, one identity, seven points
            "2a7b0407",       // identity (42, 123, 4), seven samples
            "00010201020102", // rows 0, 1, 3, 4, 6, 7, 9
            "e80704",         // first total 1000, four runs
            "02100a9003",     // 2 x q16, interior quotient 10, endpoint delta 400
            "02200cf006",     // 2 x q32, interior quotient 12, endpoint delta 880
            "010100",         // exact zero interval; endpoint delta 0
            "0110a001"        // q16 interval, endpoint delta 160
        ));
        assert_eq!(encoded_cpu, cpu);

        let legacy_cpu = hex(concat!(
            "4353483201",     // CSH2, version 1 absolute endpoints
            "0a0107",         // ten rows, one identity, seven points
            "2a7b0407",       // identity (42, 123, 4), seven samples
            "00010201020102", // rows 0, 1, 3, 4, 6, 7, 9
            "e80704",         // first total 1000, four runs
            "02100af80a",     // 2 x q16, interior quotient 10, absolute endpoint 1400
            "02200ce811",     // 2 x q32, interior quotient 12, absolute endpoint 2280
            "0101e811",       // exact zero interval; absolute endpoint 2280
            "01108813"        // q16 interval, absolute endpoint 2440
        ));
        let legacy_golden = pack_sections(PST2, header, &legacy_cpu, metadata).unwrap();
        let legacy_decoded = decode_block(&legacy_golden).unwrap();
        let golden = pack_sections(PST2, header, &cpu, metadata).unwrap();
        let decoded = decode_block(&golden).unwrap();
        let expected = [
            (0, Some(1_000)),
            (1, Some(1_160)),
            (2, None),
            (3, Some(1_400)),
            (4, Some(1_784)),
            (5, None),
            (6, Some(2_280)),
            (7, Some(2_280)),
            (8, None),
            (9, Some(2_440)),
        ];
        for block in [&decoded, &legacy_decoded] {
            for (row, (seq, cpu)) in block.rows.iter().zip(expected) {
                assert_eq!(row.seq, seq);
                assert_eq!(
                    row.processes
                        .first()
                        .map(|process| process.cpu.as_ref().unwrap().total),
                    cpu
                );
            }
        }
    }

    #[test]
    fn csh2_delta_endpoints_shrink_large_native_counters_without_losing_fidelity() {
        let mut values = vec![1_000_000_000_000_000u64];
        for increment in [8, 80, 160, 0].into_iter().cycle().take(32) {
            values.push(values.last().unwrap() + increment);
        }
        let rows: Vec<_> = values
            .iter()
            .enumerate()
            .map(|(index, value)| row(index as u64, index as u64 * 100_000_000, *value))
            .collect();
        let encoded = encode_block(&context(), &rows, Profile::Adaptive).unwrap();
        let [header, cpu, metadata] = unpack_sections(&encoded).unwrap();
        let quanta: Vec<_> = values
            .windows(2)
            .map(|pair| adaptive_q(pair[1] - pair[0], context().cpu_timebase).unwrap())
            .collect();
        assert!(quanta.windows(2).any(|pair| pair[0] != pair[1]));

        let legacy_cpu = manual_v1_single_track(&values);
        assert!(cpu.len() * 2 < legacy_cpu.len());
        let old_wire = pack_sections(PST2, header, &legacy_cpu, metadata).unwrap();
        let old_decoded = decode_block(&old_wire).unwrap();
        let decoded = decode_block(&encoded).unwrap();
        for (expected, current, old) in values
            .iter()
            .zip(&decoded.rows)
            .zip(&old_decoded.rows)
            .map(|((expected, current), old)| (expected, current, old))
        {
            assert_eq!(current.processes[0].cpu.as_ref().unwrap().total, *expected);
            assert_eq!(old.processes[0].cpu.as_ref().unwrap().total, *expected);
            assert_eq!(current.processes[0].cpu.as_ref().unwrap().error_bound, 0);
            assert_eq!(old.processes[0].cpu.as_ref().unwrap().error_bound, 0);
        }
    }

    #[test]
    fn csh2_singleton_matches_independent_handwritten_golden() {
        let rows = [Observation {
            seq: 0,
            wall_start_ns: 0,
            scan_start_ns: 0,
            scan_end_ns: 1,
            processes: vec![Process {
                pid: 7,
                ppid: 1,
                start_sec: 2,
                start_usec: 3,
                name: "x".into(),
                user: 123,
                system: 0,
                rss: 262_144,
                owned: None,
                peak: None,
                evicted: None,
            }],
            quality: vec![],
        }];
        let bytes = encode_block(&context(), &rows, Profile::Adaptive).unwrap();
        let [_, cpu, _] = unpack_sections(&bytes).unwrap();
        assert_eq!(cpu, hex("435348320201010107020301007b00"));
        let decoded = decode_block(&bytes).unwrap();
        assert_eq!(
            decoded.rows[0].processes[0].cpu.as_ref().unwrap().total,
            123
        );
    }

    #[test]
    fn fixed_100us_uses_distinct_version_and_native_ticks() {
        let rows: Vec<_> = [0, 1, 50_000, 50_000, 50_100]
            .into_iter()
            .enumerate()
            .map(|(i, cpu)| row(i as u64, i as u64 * 100_000_000, cpu))
            .collect();
        let bytes = encode_block(&context(), &rows, Profile::Fixed100us).unwrap();
        assert_eq!(&bytes[..4], PST2);
        assert!(bytes.windows(4).any(|w| w == CSH2));
        assert!(!bytes.windows(4).any(|w| w == CSH1));
        assert_eq!(decode_block(&bytes).unwrap().profile, Profile::Fixed100us);
    }

    #[test]
    fn legacy_tracks_preserve_returns_and_byte_control_metadata() {
        let mut a = row(0, 0, 100);
        a.processes[0].rss = 262_144;
        let empty = Observation {
            seq: 1,
            wall_start_ns: 1,
            scan_start_ns: 100,
            scan_end_ns: 101,
            processes: vec![],
            quality: vec![],
        };
        let mut c = row(2, 200, 300);
        c.processes[0].rss = 524_288;
        let decoded =
            decode_block(&encode_block(&context(), &[a, empty, c], Profile::Legacy1ms).unwrap())
                .unwrap();
        assert_eq!(
            decoded
                .rows
                .iter()
                .map(|r| r.processes.len())
                .collect::<Vec<_>>(),
            [1, 0, 1]
        );
        assert_eq!(
            decoded.rows[2].processes[0].cpu.as_ref().unwrap().total,
            300
        );
        assert_eq!(decoded.rows[2].processes[0].rss, 524_288);
    }

    #[test]
    fn component_regression_and_clock_order_are_rejected() {
        let mut first = row(0, 0, 100);
        first.processes[0].system = 75;
        let mut second = row(1, 100, 200);
        second.processes[0].system = 50;
        second.processes[0].user = 160;
        assert!(encode_block(&context(), &[first, second], Profile::Adaptive).is_err());
        let mut bad = row(1, 0, 1);
        bad.seq = 1;
        assert!(encode_block(&context(), &[row(0, 5, 0), bad], Profile::Adaptive).is_err());
    }

    #[test]
    fn decoder_rejects_inconsistent_exact_interval_quanta() {
        let rows = [row(0, 0, 0), row(1, 1, 1)];
        let adaptive = encode_block(&context(), &rows, Profile::Adaptive).unwrap();
        let [header, cpu, metadata] = unpack_sections(&adaptive).unwrap();
        let mut bad_cpu = cpu.to_vec();
        let q_offset = first_run_quantum_offset(&bad_cpu);
        bad_cpu[q_offset] = 2;
        let malformed = pack_sections(PST2, header, &bad_cpu, metadata).unwrap();
        assert!(decode_block(&malformed).is_err());

        let coarse = Context::new(Timebase {
            numer: 6_250,
            denom: 1,
        }); // 16 ticks per 100 us
        let fixed = encode_block(&coarse, &rows, Profile::Fixed100us).unwrap();
        let [header, cpu, metadata] = unpack_sections(&fixed).unwrap();
        let mut bad_cpu = cpu.to_vec();
        let q_offset = first_run_quantum_offset(&bad_cpu);
        bad_cpu[q_offset] = 1; // positive exact interval incorrectly tagged idle/exact
        let malformed = pack_sections(PST2, header, &bad_cpu, metadata).unwrap();
        assert!(decode_block(&malformed).is_err());
    }

    #[test]
    fn csh2_delta_endpoint_overflow_is_rejected_without_panicking() {
        let rows = [row(0, 0, u64::MAX - 1), row(1, 100_000_000, u64::MAX)];
        let encoded = encode_block(&context(), &rows, Profile::Adaptive).unwrap();
        let [header, _, metadata] = unpack_sections(&encoded).unwrap();
        let mut cpu = CSH2.to_vec();
        cpu.push(CSH2_VERSION);
        for value in [2, 1, 2, 42, 123, 4, 2, 0, 1, u64::MAX, 1, 1, 1, 1] {
            put_uvarint(&mut cpu, value).unwrap();
        }
        let malformed = pack_sections(PST2, header, &cpu, metadata).unwrap();
        let error = decode_block(&malformed).unwrap_err();
        assert!(error.contains("endpoint overflow"), "{error}");
    }

    #[test]
    fn impossible_joint_run_remainders_are_rejected() {
        assert!(!run_values_feasible(
            &[0, 16, 48, 80, 96],
            &[0, 1, 1, 1, 0],
            0,
            4,
            2,
            24_000,
            Profile::Adaptive
        ));
        assert!(!run_values_feasible(
            &[0, 0, 1],
            &[0, 15, 0],
            0,
            2,
            16,
            16,
            Profile::Fixed100us
        ));
    }

    #[test]
    fn ppid_delta_overflow_is_rejected_without_panicking() {
        let mut bytes = PSD1.to_vec();
        put_uvarint(&mut bytes, 2).unwrap();
        for (seq_delta, scan_delta) in [(0, 0), (1, 1)] {
            put_svarint(&mut bytes, seq_delta).unwrap();
            put_svarint(&mut bytes, 0).unwrap();
            put_svarint(&mut bytes, scan_delta).unwrap();
            put_uvarint(&mut bytes, 0).unwrap();
            put_uvarint(&mut bytes, 1).unwrap();
            put_uvarint(&mut bytes, 0).unwrap();
            if seq_delta == 0 {
                put_uvarint(&mut bytes, NEW).unwrap();
                for value in [1, 0, 0, 1] {
                    put_uvarint(&mut bytes, value).unwrap();
                }
                put_string(&mut bytes, "").unwrap();
                for value in [0, 0, 0] {
                    put_uvarint(&mut bytes, value).unwrap();
                }
            } else {
                put_uvarint(&mut bytes, PPID).unwrap();
                put_svarint(&mut bytes, i128::MAX).unwrap();
            }
        }
        assert!(decode_psd1(&bytes, 0).is_err());
    }

    #[test]
    fn json_expansion_budget_rejects_dense_nested_input_before_parsing() {
        let mut nested = vec![b'['; MAX_DECODED_BYTES / 48 + 1];
        nested.extend(std::iter::repeat_n(b']', MAX_DECODED_BYTES / 48 + 1));
        assert!(json_expansion_cost(&nested).is_err());
    }

    #[test]
    fn encode_and_decode_share_the_aggregate_pst2_expansion_boundary() {
        let name = "x".repeat(MAX_NAME_BYTES);
        let metadata_row_cost =
            std::mem::size_of::<MetaRow>() + std::mem::size_of::<MetaProcess>() + name.len();
        let mut low = 0usize;
        let mut high = MAX_DECODED_BYTES / metadata_row_cost;
        while low < high {
            let middle = low + (high - low).div_ceil(2);
            let name_bytes = middle * name.len();
            if check_v2_decoded_budget(middle, middle, name_bytes, 1, 0, 1024, false).is_ok() {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        let allowed_rows = low;
        assert!(allowed_rows < MAX_POINTS);
        let rows: Vec<_> = (0..=allowed_rows)
            .map(|seq| {
                let mut observation = row(seq as u64, seq as u64 * 2, 0);
                observation.processes[0].name = name.clone();
                observation
            })
            .collect();

        let error = encode_block(&context(), &rows, Profile::Adaptive).unwrap_err();
        assert!(error.contains("PST2 decoded expansion"), "{error}");
        let boundary = encode_block(&context(), &rows[..allowed_rows], Profile::Adaptive).unwrap();
        assert!(boundary.len() < 1_000_000);
        drop(rows);
        assert_eq!(decode_block(&boundary).unwrap().rows.len(), allowed_rows);
    }

    #[test]
    fn aggregate_budget_includes_temporal_spans_and_pmm1_scratch() {
        let mut low = 0usize;
        let mut high = MAX_POINTS;
        while low < high {
            let middle = low + (high - low).div_ceil(2);
            let names = middle * MAX_NAME_BYTES;
            if check_v2_decoded_budget(middle, middle, names, 1, 0, 0, false).is_ok() {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        let points = low;
        let names = points * MAX_NAME_BYTES;
        assert!(check_v2_decoded_budget(points, points, names, 1, 0, 0, false).is_ok());
        assert!(check_v2_decoded_budget(points, points, names, 1, 3, 0, true).is_err());
    }

    #[test]
    fn every_truncated_prefix_and_malformed_varint_is_rejected() {
        let bytes = encode_block(
            &context(),
            &[row(0, 0, 999), row(1, 10, 1_000)],
            Profile::Adaptive,
        )
        .unwrap();
        for end in 0..bytes.len() {
            assert!(decode_block(&bytes[..end]).is_err(), "accepted {end}");
        }
        let [header, cpu, metadata] = unpack_sections(&bytes).unwrap();
        for end in 0..cpu.len() {
            let truncated = pack_sections(PST2, header, &cpu[..end], metadata).unwrap();
            assert!(
                decode_block(&truncated).is_err(),
                "accepted CPU prefix {end}"
            );
        }
        for end in 0..metadata.len() {
            let truncated = pack_sections(PST2, header, cpu, &metadata[..end]).unwrap();
            assert!(
                decode_block(&truncated).is_err(),
                "accepted PSD1 prefix {end}"
            );
        }
        assert!(read_uvarint(&[0x80, 0], &mut 0usize).is_err());
        assert!(read_uvarint(&[0xff; 11], &mut 0usize).is_err());
        assert!(decode_block(&vec![0; MAX_BLOCK_BYTES + 1]).is_err());
    }

    #[test]
    fn generated_adaptive_histories_obey_per_interval_bounds() {
        for case in 0..64u64 {
            let mut value = 1_000_000_000u64 + case * 100_003;
            let mut values = vec![value];
            for step in 0..32u64 {
                let increment = if (step + case) % 7 == 0 {
                    0
                } else {
                    (step * 73 + case * 19) % 2_003 + 1
                };
                value += increment;
                values.push(value);
            }
            let rows: Vec<_> = values
                .iter()
                .enumerate()
                .map(|(i, cpu)| row(i as u64, i as u64 * 83_000_000 + case, *cpu))
                .collect();
            let decoded =
                decode_block(&encode_block(&context(), &rows, Profile::Adaptive).unwrap()).unwrap();
            let restored: Vec<_> = decoded
                .rows
                .iter()
                .map(|r| r.processes[0].cpu.as_ref().unwrap().total)
                .collect();
            assert_eq!(restored.first(), values.first());
            assert_eq!(restored.last(), values.last());
            for i in 1..values.len() {
                let actual = values[i] - values[i - 1];
                let estimate = restored[i] - restored[i - 1];
                assert_eq!(actual == 0, estimate == 0, "case={case}, interval={i}");
                let q = adaptive_q(actual, context().cpu_timebase).unwrap();
                let error = actual.abs_diff(estimate);
                assert!(error < q, "case={case}, interval={i}, error={error}, q={q}");
                if actual > 0 {
                    assert!(8 * error < actual);
                }
            }
        }
    }

    #[test]
    fn adaptive_singletons_and_empty_blocks_are_exact() {
        let singleton = row(7, 0, 12_345);
        let block =
            decode_block(&encode_block(&context(), &[singleton], Profile::Adaptive).unwrap())
                .unwrap();
        assert_eq!(
            block.rows[0].processes[0].cpu.as_ref().unwrap().total,
            12_345
        );
        assert_eq!(
            block.rows[0].processes[0].cpu.as_ref().unwrap().error_bound,
            0
        );
        let empty =
            decode_block(&encode_block(&context(), &[], Profile::Adaptive).unwrap()).unwrap();
        assert!(empty.rows.is_empty());
    }

    #[test]
    fn coarse_native_timebase_uses_exact_one_tick_quantum() {
        let ctx = Context::new(Timebase {
            numer: 2_000_000,
            denom: 1,
        });
        let rows = [row(0, 0, 0), row(1, 2, 8), row(2, 4, 8)];
        let decoded = decode_block(&encode_block(&ctx, &rows, Profile::Adaptive).unwrap()).unwrap();
        assert_eq!(decoded.rows[1].processes[0].cpu.as_ref().unwrap().total, 8);
        assert_eq!(decoded.rows[2].processes[0].cpu.as_ref().unwrap().total, 8);
        assert_eq!(adaptive_q(0, ctx.cpu_timebase).unwrap(), 1);
    }

    #[test]
    fn temporal_policy_uses_one_percent_reference_and_integer_deadlines() {
        let timebase = Timebase {
            numer: 125,
            denom: 3,
        };
        let cap = timebase.quantum(LEGACY_CPU_NS).unwrap();
        let qbusy = adaptive_quantum(u128::from(cap), cap);
        assert_eq!(cap, 24_000);
        assert_eq!(qbusy, 2_048);
        assert_eq!(temporal_quantum(24_000, 100_000_000, cap).unwrap(), qbusy);
        assert_eq!(temporal_quantum(120_000, 100_000_000, cap).unwrap(), 8_192);
        assert_eq!(temporal_quantum(120, 100_000_000, cap).unwrap(), 8);
        assert_eq!(
            temporal_target(8_192, qbusy, Profile::AdaptiveInverse).unwrap(),
            100_000_000
        );
        assert_eq!(
            temporal_target(8, qbusy, Profile::AdaptiveInverse).unwrap(),
            5_000_000_000
        );
        assert_eq!(
            temporal_target(8, qbusy, Profile::AdaptiveLog).unwrap(),
            3_663_636_364
        );

        let source = [row(0, 0, 0), row(1, 100_000_000, 1)];
        let encoded = encode_block(&Context::new(timebase), &source, Profile::AdaptiveLog).unwrap();
        let [header_bytes, cpu, metadata] = unpack_sections(&encoded).unwrap();
        assert_eq!(cpu[4], CSH2_VERSION);
        let header: Value = parse_json(header_bytes).unwrap();
        assert_eq!(header["profile"], "adaptive-log");
        assert!(Profile::parse("adaptive-log-v1").is_err());

        let mut impossible = cpu.to_vec();
        let q_offset = first_run_quantum_offset(&impossible);
        assert_eq!(impossible[q_offset], 1);
        impossible[q_offset] = 2;
        assert!(
            decode_block(&pack_sections(PST2, header_bytes, &impossible, metadata).unwrap())
                .is_err()
        );

        let huge_delta = [row(0, 0, 0), row(1, 1, 1_000_000_000_000)];
        let decoded =
            decode_block(&encode_block(&context(), &huge_delta, Profile::AdaptiveInverse).unwrap())
                .unwrap();
        assert_eq!(
            decoded.rows[1].processes[0].cpu.as_ref().unwrap().total,
            1_000_000_000_000
        );
    }

    #[test]
    fn temporal_decoder_requires_exact_raw_span_endpoints_and_every_segment() {
        let source = [row(0, 0, 0), row(1, 100_000_000, 1), row(2, 200_000_000, 2)];
        let encoded = encode_block(&context(), &source, Profile::AdaptiveInverse).unwrap();
        let [header, cpu, metadata] = unpack_sections(&encoded).unwrap();
        let (segment_count_offset, row_offsets) = temporal_track_offsets(cpu);
        assert_eq!(row_offsets.len(), 2);

        let mut no_segment = cpu.to_vec();
        no_segment[segment_count_offset] = 0;
        assert!(
            decode_block(&pack_sections(PST2, header, &no_segment, metadata).unwrap()).is_err()
        );

        let mut missing_first = cpu.to_vec();
        missing_first[row_offsets[0]] = 1;
        missing_first[row_offsets[1]] = 1;
        assert!(
            decode_block(&pack_sections(PST2, header, &missing_first, metadata).unwrap()).is_err()
        );

        let mut missing_last = cpu.to_vec();
        missing_last[row_offsets[1]] = 1;
        assert!(
            decode_block(&pack_sections(PST2, header, &missing_last, metadata).unwrap()).is_err()
        );
    }

    #[test]
    fn temporal_decoder_rejects_duplicate_unclaimed_and_inflated_cpu_indexes() {
        let rows = [
            row(0, 0, 10_000_000),
            row(1, 100_000_000, 20_000_000),
            row(2, 200_000_000, 30_000_000),
            row(3, 300_000_000, 40_000_000),
        ];
        let encoded = encode_block(&context(), &rows, Profile::AdaptiveInverse).unwrap();
        let [header, cpu_section, metadata] = unpack_sections(&encoded).unwrap();
        let cpu = cpu_section.to_vec();
        let mut offset = 5;
        for _ in 0..3 {
            read_uvarint(&cpu, &mut offset).unwrap();
        }
        let pid_offset = offset;
        for _ in 0..3 {
            read_uvarint(&cpu, &mut offset).unwrap();
        }
        let count = read_uvarint(&cpu, &mut offset).unwrap();
        assert_eq!(count, 4);
        read_uvarint(&cpu, &mut offset).unwrap();
        let duplicate_index = offset;
        assert_eq!(read_uvarint(&cpu, &mut offset).unwrap(), 1);

        let mut duplicate = cpu.clone();
        duplicate[duplicate_index] = 0;
        assert!(decode_block(&pack_sections(PST2, header, &duplicate, metadata).unwrap()).is_err());

        let mut unclaimed = cpu.clone();
        unclaimed[pid_offset] = 43;
        assert!(decode_block(&pack_sections(PST2, header, &unclaimed, metadata).unwrap()).is_err());

        let mut missing_index = cpu;
        missing_index[7] = 3;
        assert!(
            decode_block(&pack_sections(PST2, header, &missing_index, metadata).unwrap()).is_err()
        );
    }

    #[test]
    fn temporal_decoder_checks_resource_counts_before_allocating_indexes() {
        let mut cpu = CSH2.to_vec();
        cpu.push(CSH2_VERSION);
        put_uvarint(&mut cpu, 0).unwrap();
        put_uvarint(&mut cpu, 0).unwrap();
        put_uvarint(&mut cpu, (MAX_POINTS + 1) as u64).unwrap();
        assert!(
            decode_csh2_temporal(
                &cpu,
                Profile::AdaptiveLog,
                context().cpu_timebase,
                &mut [],
                0,
            )
            .is_err()
        );
    }

    fn temporal_track_offsets(cpu: &[u8]) -> (usize, Vec<usize>) {
        let mut offset = 5;
        read_uvarint(cpu, &mut offset).unwrap(); // row count
        let segment_count_offset = offset;
        read_uvarint(cpu, &mut offset).unwrap(); // segment count
        read_uvarint(cpu, &mut offset).unwrap(); // checkpoint count
        for _ in 0..3 {
            read_uvarint(cpu, &mut offset).unwrap();
        }
        let count = read_uvarint(cpu, &mut offset).unwrap() as usize;
        let mut row_offsets = Vec::with_capacity(count);
        for _ in 0..count {
            row_offsets.push(offset);
            read_uvarint(cpu, &mut offset).unwrap();
        }
        (segment_count_offset, row_offsets)
    }

    fn first_run_quantum_offset(cpu: &[u8]) -> usize {
        let mut offset = 5;
        for _ in 0..3 {
            read_uvarint(cpu, &mut offset).unwrap();
        }
        for _ in 0..3 {
            read_uvarint(cpu, &mut offset).unwrap();
        }
        let count = read_uvarint(cpu, &mut offset).unwrap();
        for _ in 0..count {
            read_uvarint(cpu, &mut offset).unwrap();
        }
        read_uvarint(cpu, &mut offset).unwrap(); // first exact CPU total
        read_uvarint(cpu, &mut offset).unwrap(); // run count
        read_uvarint(cpu, &mut offset).unwrap(); // run interval count
        offset
    }

    fn manual_v1_single_track(values: &[u64]) -> Vec<u8> {
        let mut out = CSH2.to_vec();
        out.push(CSH2_ABSOLUTE_ENDPOINT_VERSION);
        for value in [
            values.len() as u64,
            1,
            values.len() as u64,
            42,
            123,
            4,
            values.len() as u64,
        ] {
            put_uvarint(&mut out, value).unwrap();
        }
        for index in 0..values.len() {
            put_uvarint(&mut out, u64::from(index != 0)).unwrap();
        }
        put_uvarint(&mut out, values[0]).unwrap();

        let quanta: Vec<_> = values
            .windows(2)
            .map(|pair| adaptive_q(pair[1] - pair[0], context().cpu_timebase).unwrap())
            .collect();
        let mut runs = Vec::new();
        let mut start = 0;
        while start < quanta.len() {
            let mut end = start + 1;
            while end < quanta.len() && quanta[end] == quanta[start] {
                end += 1;
            }
            runs.push((start, end - start, quanta[start]));
            start = end;
        }
        put_uvarint(&mut out, runs.len() as u64).unwrap();
        for (start, length, quantum) in runs {
            put_uvarint(&mut out, length as u64).unwrap();
            put_uvarint(&mut out, quantum).unwrap();
            let end = start + length;
            let anchor = values[start];
            for value in values.iter().take(end).skip(start + 1) {
                put_uvarint(&mut out, (value - anchor) / quantum).unwrap();
            }
            put_uvarint(&mut out, values[end]).unwrap();
        }
        out
    }

    fn adaptive_q(delta: u64, timebase: Timebase) -> Result<u64> {
        let cap = timebase.quantum(LEGACY_CPU_NS)?;
        let eighth = delta / 8;
        let floor = if eighth == 0 {
            1
        } else {
            1u64 << (63 - eighth.leading_zeros())
        };
        Ok(floor.min(cap).max(1))
    }
    fn hex(s: &str) -> Vec<u8> {
        let compact: String = s.chars().filter(|c| !c.is_whitespace()).collect();
        compact
            .as_bytes()
            .chunks_exact(2)
            .filter_map(|pair| {
                let text = std::str::from_utf8(pair).ok()?;
                u8::from_str_radix(text, 16).ok()
            })
            .collect()
    }
}
