//! Small offline command handlers for transform, inspect, export, and profile checks.
use super::model::{
    Context, DecodedBlock, Observation, OutputFormat, Profile, RecordOptions, Result, Timebase,
};
use super::{
    decode_block, pipeline, source,
    store::{self, ArchiveWriter, StoreOptions},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{BufWriter, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const CODEC_FRAME_INPUT_LIMIT: usize = 16 * 1024 * 1024;
const USAGE: &str = "pane-load recording <record|transform|inspect|bench> ...\n\
record: --output ROOT [--duration SEC] [--hz N] [--profile adaptive|legacy-1ms|fixed-100us] [--format binary|jsonl-zstd]\n\
transform: --input FILE|CAPTUREROOT --output NEWARCHIVE [--timebase NUM/DEN] [--profile PROFILE] [--block-rows N] [--frame-bytes N] [--max-bytes N] [--min-free-bytes N]\n\
inspect: --input ARCHIVE|RECORDROOT|CACHE [--verify] [--jsonl] [--recover]\n\
bench: --input RAWSOURCE|ARCHIVE/CACHE --profiles adaptive,legacy-1ms,fixed-100us [--timebase NUM/DEN] --output DIR|FILE.jsonl";

/// Parse the flags following `record`. Unknown, duplicate, missing, and malformed flags fail.
pub fn parse_record_options(args: &[String]) -> Result<RecordOptions> {
    let mut output = None;
    let mut duration = None;
    let mut hz = None;
    let mut profile = None;
    let mut format = None;
    let mut frame_bytes = None;
    let mut max_bytes = None;
    let mut min_free_bytes = None;
    let mut block_rows = None;
    let mut seen = std::collections::HashSet::new();
    let mut index = 0;
    while index < args.len() {
        let flag = &args[index];
        if !seen.insert(flag.clone()) {
            return Err(format!("duplicate option: {flag}"));
        }
        index += 1;
        if flag == "--help" || flag == "-h" {
            return Err(USAGE.into());
        }
        if !matches!(
            flag.as_str(),
            "--output"
                | "--duration"
                | "--hz"
                | "--profile"
                | "--format"
                | "--frame-bytes"
                | "--max-bytes"
                | "--min-free-bytes"
                | "--block-rows"
        ) {
            return Err(format!("unknown record option: {flag}"));
        }
        let value = args
            .get(index)
            .ok_or_else(|| format!("{flag} requires a value"))?;
        index += 1;
        match flag.as_str() {
            "--output" => output = Some(PathBuf::from(value)),
            "--duration" => duration = Some(parse_f64(value, "--duration")?),
            "--hz" => hz = Some(parse_u64(value, "--hz")?),
            "--profile" => profile = Some(parse_named_profile(value)?),
            "--format" => format = Some(parse_format(value)?),
            "--frame-bytes" => frame_bytes = Some(parse_usize(value, "--frame-bytes")?),
            "--max-bytes" => max_bytes = Some(parse_u64(value, "--max-bytes")?),
            "--min-free-bytes" => min_free_bytes = Some(parse_u64(value, "--min-free-bytes")?),
            "--block-rows" => block_rows = Some(parse_usize(value, "--block-rows")?),
            _ => return Err(format!("unknown record option: {flag}")),
        }
    }
    let output = output.ok_or_else(|| "record requires --output ROOT".to_string())?;
    let mut options = pipeline::default_record_options(output);
    if let Some(value) = duration {
        options.duration = Some(value);
    }
    if let Some(value) = hz {
        options.hz = value;
    }
    if let Some(value) = profile {
        options.profile = value;
    }
    if let Some(value) = format {
        options.format = value;
    }
    if let Some(value) = frame_bytes {
        options.frame_bytes = value;
    }
    if let Some(value) = max_bytes {
        options.max_bytes = value;
    }
    if let Some(value) = min_free_bytes {
        options.min_free_bytes = value;
    }
    if let Some(value) = block_rows {
        options.block_rows = value;
    }
    if options.hz == 0 || options.hz > 1000 {
        return Err("--hz must be in 1..=1000".into());
    }
    if options.duration.is_some_and(|v| {
        !v.is_finite() || v <= 0.0 || std::time::Duration::try_from_secs_f64(v).is_err()
    }) {
        return Err("--duration must be finite, positive, and representable".into());
    }
    if options.block_rows == 0 || options.block_rows > super::model::MAX_POINTS {
        return Err("--block-rows must be in 1..=1000000".into());
    }
    if options.frame_bytes == 0 || options.frame_bytes > super::model::MAX_BLOCK_BYTES {
        return Err(format!(
            "--frame-bytes must be in 1..={}",
            super::model::MAX_BLOCK_BYTES
        ));
    }
    if options.max_bytes == 0 {
        return Err("--max-bytes must be positive".into());
    }
    Ok(options)
}

/// Handles non-native recording subcommands. Arguments begin with `transform`, `inspect`,
/// `bench`, or a help token; native `record` is deliberately handled by main's adapter.
pub fn run(args: &[String]) -> Result<()> {
    let Some(command) = args.first().map(String::as_str) else {
        print_usage();
        return Ok(());
    };
    match command {
        "help" | "--help" | "-h" => {
            print_usage();
            Ok(())
        }
        "record" => Err("record is handled by the native recording adapter".into()),
        "transform" => run_transform(&args[1..]),
        "inspect" => run_inspect(&args[1..]),
        "bench" => run_bench(&args[1..]),
        _ => Err(format!("unknown recording command: {command}\n{USAGE}")),
    }
}

fn print_usage() {
    println!("{USAGE}");
}

#[derive(Default)]
struct Parsed {
    input: Option<PathBuf>,
    output: Option<PathBuf>,
    timebase: Option<Timebase>,
    profile: Option<Profile>,
    block_rows: Option<usize>,
    frame_bytes: Option<usize>,
    max_bytes: Option<u64>,
    min_free_bytes: Option<u64>,
    profiles: Option<Vec<Profile>>,
    verify: bool,
    jsonl: bool,
    recover: bool,
}

fn parse_flags(args: &[String], allowed: &[&str], booleans: &[&str]) -> Result<Parsed> {
    let mut parsed = Parsed::default();
    let mut seen = std::collections::HashSet::new();
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        if !seen.insert(flag.to_owned()) {
            return Err(format!("duplicate option: {flag}"));
        }
        index += 1;
        if booleans.contains(&flag) {
            match flag {
                "--verify" => parsed.verify = true,
                "--jsonl" => parsed.jsonl = true,
                "--recover" => parsed.recover = true,
                _ => unreachable!(),
            }
            continue;
        }
        if !allowed.contains(&flag) {
            return Err(format!("unknown option: {flag}"));
        }
        let value = args
            .get(index)
            .ok_or_else(|| format!("{flag} requires a value"))?;
        index += 1;
        match flag {
            "--input" => parsed.input = Some(PathBuf::from(value)),
            "--output" => parsed.output = Some(PathBuf::from(value)),
            "--timebase" => parsed.timebase = Some(parse_timebase(value)?),
            "--profile" => parsed.profile = Some(parse_named_profile(value)?),
            "--block-rows" => parsed.block_rows = Some(parse_usize(value, flag)?),
            "--frame-bytes" => parsed.frame_bytes = Some(parse_usize(value, flag)?),
            "--max-bytes" => parsed.max_bytes = Some(parse_u64(value, flag)?),
            "--min-free-bytes" => parsed.min_free_bytes = Some(parse_u64(value, flag)?),
            "--profiles" => {
                let mut profiles = Vec::new();
                for name in value.split(',') {
                    if name.is_empty() {
                        return Err(
                            "--profiles must be a comma-separated list of named profiles".into(),
                        );
                    }
                    let profile = parse_named_profile(name)?;
                    if profiles.contains(&profile) {
                        return Err(format!("duplicate benchmark profile: {name}"));
                    }
                    profiles.push(profile);
                }
                if profiles.is_empty() {
                    return Err("--profiles must not be empty".into());
                }
                parsed.profiles = Some(profiles);
            }
            _ => return Err(format!("unsupported option: {flag}")),
        }
    }
    Ok(parsed)
}

fn run_transform(args: &[String]) -> Result<()> {
    let parsed = parse_flags(
        args,
        &[
            "--input",
            "--output",
            "--timebase",
            "--profile",
            "--block-rows",
            "--frame-bytes",
            "--max-bytes",
            "--min-free-bytes",
        ],
        &[],
    )?;
    let input = parsed
        .input
        .ok_or_else(|| "transform requires --input".to_string())?;
    let output = parsed
        .output
        .ok_or_else(|| "transform requires --output".to_string())?;
    let files = pipeline::source_files(&input)?;
    ensure_no_overlap(&input, &output)?;
    let mut options = pipeline::default_record_options(output.clone());
    if let Some(profile) = parsed.profile {
        options.profile = profile;
    }
    if let Some(value) = parsed.block_rows {
        options.block_rows = value;
    }
    if let Some(value) = parsed.frame_bytes {
        options.frame_bytes = value;
    }
    if let Some(value) = parsed.max_bytes {
        options.max_bytes = value;
    }
    if let Some(value) = parsed.min_free_bytes {
        options.min_free_bytes = value;
    }
    let stats = pipeline::transform_sources(&files, &output, &options, parsed.timebase)?;
    println!(
        "{}",
        serde_json::to_string(&stats).map_err(|e| format!("encode transform metrics: {e}"))?
    );
    Ok(())
}

fn ensure_no_overlap(input: &Path, output: &Path) -> Result<()> {
    if fs::symlink_metadata(output).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err("output must not be a symlink".into());
    }
    let input_meta = fs::symlink_metadata(input).map_err(|e| format!("inspect input: {e}"))?;
    if input_meta.file_type().is_symlink() {
        return Err("input must not be a symlink".into());
    }
    let input = fs::canonicalize(input).map_err(|e| format!("resolve input: {e}"))?;
    let output_abs = if output.exists() {
        fs::canonicalize(output).map_err(|e| format!("resolve output: {e}"))?
    } else {
        let parent = output
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        fs::canonicalize(parent)
            .map_err(|e| format!("resolve output parent: {e}"))?
            .join(
                output
                    .file_name()
                    .ok_or_else(|| "output has no final component".to_string())?,
            )
    };
    let overlap = if input_meta.is_dir() {
        output_abs.starts_with(&input) || input.starts_with(&output_abs)
    } else {
        output_abs == input
    };
    if overlap {
        return Err("input and output trees must not overlap".into());
    }
    Ok(())
}

#[derive(Deserialize)]
struct ArchiveMetadata {
    format: String,
    version: u32,
    context: Context,
    profile: Profile,
}

fn archive_paths(input: &Path) -> Result<Vec<PathBuf>> {
    let meta = fs::symlink_metadata(input).map_err(|e| format!("inspect input: {e}"))?;
    if meta.file_type().is_symlink() {
        return Err("inspect input must not be a symlink".into());
    }
    if meta.is_file() {
        return Ok(Vec::new());
    }
    if !meta.is_dir() {
        return Err("inspect input must be a file or directory".into());
    }
    if input.join("archive.json").is_file() {
        return Ok(vec![input.to_path_buf()]);
    }
    let mut out = Vec::new();
    let direct = input.join("archive");
    if direct.join("archive.json").is_file() {
        out.push(direct);
    }
    for entry in fs::read_dir(input).map_err(|e| format!("list recording root: {e}"))? {
        let entry = entry.map_err(|e| format!("read recording root entry: {e}"))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with("run-") {
            continue;
        }
        let run_meta = fs::symlink_metadata(entry.path())
            .map_err(|e| format!("inspect recording run: {e}"))?;
        if run_meta.file_type().is_symlink() || !run_meta.is_dir() {
            return Err("recording root contains an unsafe run entry".into());
        }
        let archive = entry.path().join("archive");
        if archive.join("archive.json").is_file() {
            out.push(archive);
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}

fn maybe_recover(archive: &Path) -> Result<Vec<String>> {
    let bytes = fs::read(archive.join("archive.json"))
        .map_err(|e| format!("read archive metadata: {e}"))?;
    let metadata: ArchiveMetadata =
        serde_json::from_slice(&bytes).map_err(|e| format!("decode archive metadata: {e}"))?;
    if metadata.format != "pane-load-recording-archive" || metadata.version != 1 {
        return Err("unsupported archive metadata".into());
    }
    let writer = ArchiveWriter::open(
        archive,
        &metadata.context,
        metadata.profile,
        StoreOptions {
            frame_bytes: 16 * 1024 * 1024,
            max_bytes: u64::MAX,
            min_free_bytes: 0,
        },
    )?;
    let report = writer.recovery_report().to_vec();
    writer.finish()?;
    Ok(report)
}

#[derive(Default)]
struct Summary {
    incomplete: bool,
    partial_error: Option<String>,
    archives: u64,
    blocks: u64,
    scans: u64,
    readings: u64,
    flagged_events: u64,
    encoded_bytes: u64,
    recovery: Vec<String>,
    profiles: Vec<String>,
    contexts: Vec<Value>,
    source_hashes: Vec<pipeline::SourceHashStats>,
}

fn run_inspect(args: &[String]) -> Result<()> {
    let started = std::time::Instant::now();
    let cpu_before = get_cpu();
    let parsed = parse_flags(
        args,
        &["--input", "--timebase"],
        &["--verify", "--jsonl", "--recover"],
    )?;
    let input = parsed
        .input
        .ok_or_else(|| "inspect requires --input".to_string())?;
    let mut summary = Summary::default();
    let archives = archive_paths(&input)?;
    if let Some(error) = partial_recording_error(&input, &archives)? {
        if parsed.jsonl {
            return Err(format!(
                "cannot export an explicitly partial recording: {error}"
            ));
        }
        summary.incomplete = true;
        summary.partial_error = Some(error);
    }
    if !archives.is_empty() {
        for archive in archives {
            if parsed.recover {
                summary.recovery.extend(
                    maybe_recover(&archive)?
                        .into_iter()
                        .map(|m| format!("{}: {m}", archive.display())),
                );
            }
            inspect_archive(&archive, &mut summary, parsed.jsonl, parsed.verify)?;
        }
    } else if input.extension().and_then(|x| x.to_str()) == Some("pst") {
        inspect_pst_files(std::slice::from_ref(&input), &mut summary, parsed.jsonl)?;
    } else {
        let cached = if input.is_dir() {
            let mut paths = Vec::new();
            collect_pst(&input, &mut paths)?;
            paths.sort();
            paths
        } else {
            Vec::new()
        };
        if !cached.is_empty() {
            inspect_pst_files(&cached, &mut summary, parsed.jsonl)?;
        } else {
            let files = if input.is_file() {
                vec![input.clone()]
            } else {
                pipeline::source_files(&input)?
            };
            for path in files {
                inspect_source_file(&path, &mut summary, parsed.jsonl, parsed.timebase)?;
            }
        }
    }
    if !parsed.jsonl {
        let value = json!({"format":"pane-load-inspection","incomplete":summary.incomplete,"partial_error":summary.partial_error,
            "archives":summary.archives,"blocks":summary.blocks,"scans":summary.scans,
            "readings":summary.readings,"flagged_events":summary.flagged_events,"encoded_bytes":summary.encoded_bytes,
            "profiles":summary.profiles,"contexts":summary.contexts,"source_hashes":summary.source_hashes,"recovery":summary.recovery,
            "wall_seconds":started.elapsed().as_secs_f64(),"own_cpu_seconds":get_cpu_delta(cpu_before).0,"child_cpu_seconds":0.0,"peak_rss_bytes":get_cpu().1});
        println!(
            "{}",
            serde_json::to_string(&value).map_err(|e| format!("encode inspection summary: {e}"))?
        );
    }
    Ok(())
}

fn partial_recording_error(input: &Path, archives: &[PathBuf]) -> Result<Option<String>> {
    let mut candidates = if fs::symlink_metadata(input).is_ok_and(|metadata| metadata.is_dir()) {
        vec![input.join("partial.json")]
    } else {
        Vec::new()
    };
    for archive in archives {
        if let Some(run) = archive.parent() {
            candidates.push(run.join("partial.json"));
        }
    }
    for path in candidates {
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(format!(
                    "inspect partial status {}: {error}",
                    path.display()
                ));
            }
        };
        if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() > 64 * 1024 {
            return Err(format!("unsafe partial status: {}", path.display()));
        }
        let bytes = fs::read(&path).map_err(|error| format!("read partial status: {error}"))?;
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|error| format!("decode partial status: {error}"))?;
        let reason = value
            .get("end_reason")
            .or_else(|| value.get("error"))
            .and_then(Value::as_str)
            .unwrap_or("recording did not complete")
            .to_owned();
        return Ok(Some(reason));
    }
    Ok(None)
}

fn inspect_archive(path: &Path, summary: &mut Summary, export: bool, _verify: bool) -> Result<()> {
    let metadata_bytes =
        fs::read(path.join("archive.json")).map_err(|e| format!("read archive metadata: {e}"))?;
    let metadata: ArchiveMetadata = serde_json::from_slice(&metadata_bytes)
        .map_err(|e| format!("decode archive metadata: {e}"))?;
    if metadata.format != "pane-load-recording-archive" || metadata.version != 1 {
        return Err("unsupported archive metadata".into());
    }
    summary.archives += 1;
    summary.profiles.push(format!("{:?}", metadata.profile));
    summary.contexts.push(
        serde_json::to_value(&metadata.context)
            .map_err(|e| format!("encode archive context: {e}"))?,
    );
    if export {
        print_export_header("decoded-binary", metadata.profile, &metadata.context)?;
    }
    store::visit_blocks(path, |bytes| {
        let block = decode_block(bytes)?;
        if block.profile != metadata.profile {
            return Err("archive block profile disagrees with archive metadata".into());
        }
        if export {
            write_decoded_rows(&block)?;
        }
        accumulate_block(summary, &block, bytes.len() as u64);
        Ok(())
    })
}

fn inspect_pst_files(paths: &[PathBuf], summary: &mut Summary, export: bool) -> Result<()> {
    for path in paths {
        let bytes =
            fs::read(path).map_err(|e| format!("read cached block {}: {e}", path.display()))?;
        let block = decode_block(&bytes)?;
        if export
            && (summary.blocks == 0 || !summary.profiles.contains(&format!("{:?}", block.profile)))
        {
            print_export_header("decoded-binary-cache", block.profile, &block.context)?;
        }
        summary.profiles.push(format!("{:?}", block.profile));
        summary.contexts.push(
            serde_json::to_value(&block.context)
                .map_err(|e| format!("encode cached context: {e}"))?,
        );
        accumulate_block(summary, &block, bytes.len() as u64);
        if export {
            write_decoded_rows(&block)?;
        }
    }
    Ok(())
}

fn inspect_source_file(
    path: &Path,
    summary: &mut Summary,
    export: bool,
    legacy_timebase: Option<Timebase>,
) -> Result<()> {
    let mut header = false;
    let stats = source::visit_source(path, legacy_timebase, |context, row| {
        if !header && export {
            print_export_header("raw-source", Profile::Adaptive, context)?;
            header = true;
        }
        summary.scans = summary.scans.saturating_add(1);
        summary.readings = summary.readings.saturating_add(row.processes.len() as u64);
        summary.flagged_events = summary
            .flagged_events
            .saturating_add(row.quality.len() as u64);
        if export {
            write_raw_row(&row)?;
        }
        Ok(())
    })?;
    summary.encoded_bytes = summary.encoded_bytes.saturating_add(stats.input_bytes);
    summary.source_hashes.push(pipeline::SourceHashStats {
        path: path.to_string_lossy().into_owned(),
        scans: stats.scans,
        readings: stats.readings,
        input_bytes: stats.input_bytes,
        expanded_bytes: stats.expanded_bytes,
        expanded_sha256: stats.expanded_sha256.clone(),
        first_seq: stats.first_seq,
        last_seq: stats.last_seq,
        first_scan_start_ns: stats.first_scan_start_ns,
        last_scan_start_ns: stats.last_scan_start_ns,
    });
    summary.contexts.push(
        serde_json::to_value(stats.context).map_err(|e| format!("encode source context: {e}"))?,
    );
    Ok(())
}

fn print_export_header(kind: &str, profile: Profile, context: &Context) -> Result<()> {
    let value = json!({"recording_export":1,"kind":kind,"profile":profile,"context":context,
        "cpu_components":"unavailable-for-binary-total-only","rss_precision_bytes":262144,
        "cpu_precision":"per-reading native tick error bound"});
    println!(
        "{}",
        serde_json::to_string(&value).map_err(|e| format!("encode export header: {e}"))?
    );
    Ok(())
}
fn write_decoded_rows(block: &DecodedBlock) -> Result<()> {
    for row in &block.rows {
        let value = json!({"kind":"decoded-observation","seq":row.seq,"wall_start_ns":row.wall_start_ns,
            "scan_start_ns":row.scan_start_ns,"scan_end_ns":row.scan_end_ns,"quality":row.quality,
            "processes":row.processes.iter().map(|p| json!({"pid":p.pid,"ppid":p.ppid,"start_sec":p.start_sec,"start_usec":p.start_usec,
                "name":p.name,"cpu_total_native_ticks":p.cpu_total,"cpu_error_bound_native_ticks":p.cpu_error_bound,
                "cpu_components":null,"components_available":false,"rss_bytes":p.rss,"rss_precision_bytes":262144})).collect::<Vec<_>>()});
        println!(
            "{}",
            serde_json::to_string(&value).map_err(|e| format!("encode decoded export: {e}"))?
        );
    }
    Ok(())
}
fn write_raw_row(row: &Observation) -> Result<()> {
    let mut value = source::row_to_value(row)?;
    value["kind"] = Value::String("raw-source-observation".into());
    println!(
        "{}",
        serde_json::to_string(&value).map_err(|e| format!("encode raw export: {e}"))?
    );
    Ok(())
}
fn accumulate_block(summary: &mut Summary, block: &DecodedBlock, bytes: u64) {
    summary.blocks = summary.blocks.saturating_add(1);
    summary.scans = summary.scans.saturating_add(block.rows.len() as u64);
    summary.readings = summary.readings.saturating_add(
        block
            .rows
            .iter()
            .map(|row| row.processes.len() as u64)
            .sum::<u64>(),
    );
    summary.flagged_events = summary.flagged_events.saturating_add(
        block
            .rows
            .iter()
            .map(|row| row.quality.len() as u64)
            .sum::<u64>(),
    );
    summary.encoded_bytes = summary.encoded_bytes.saturating_add(bytes);
}

#[derive(Default)]
struct CodecTotals {
    pending: Vec<Vec<u8>>,
    pending_bytes: usize,
    input_bytes: u64,
    compressed_bytes: u64,
    encoder_cpu_seconds: f64,
    encoder_wall_seconds: f64,
    frames: u64,
    repeats: u64,
}
impl CodecTotals {
    fn push(&mut self, block: &[u8]) -> Result<()> {
        let cost = block.len().saturating_add(11);
        if !self.pending.is_empty()
            && (self.pending_bytes.saturating_add(cost) > CODEC_FRAME_INPUT_LIMIT
                || self.pending.len() >= 16_000)
        {
            self.flush()?;
        }
        self.pending.push(block.to_vec());
        self.pending_bytes = self.pending_bytes.saturating_add(cost);
        if self.pending_bytes >= CODEC_FRAME_INPUT_LIMIT || self.pending.len() >= 16_000 {
            self.flush()?;
        }
        Ok(())
    }
    fn flush(&mut self) -> Result<()> {
        if self.pending.is_empty() {
            return Ok(());
        }
        let result = store::benchmark_frame(&self.pending)?;
        self.input_bytes = self.input_bytes.saturating_add(result.input_bytes);
        self.compressed_bytes = self
            .compressed_bytes
            .saturating_add(result.compressed_bytes);
        self.encoder_cpu_seconds += result.encoder_cpu_seconds;
        self.encoder_wall_seconds += result.encoder_wall_seconds;
        self.frames = self.frames.saturating_add(1);
        self.repeats = self.repeats.saturating_add(result.repeats as u64);
        self.pending.clear();
        self.pending_bytes = 0;
        Ok(())
    }
}

#[derive(Serialize)]
struct BenchResult {
    format: &'static str,
    profile: String,
    mode: String,
    scans: u64,
    readings: u64,
    blocks: u64,
    encoded_bytes: u64,
    wall_seconds: f64,
    own_cpu_seconds: f64,
    child_cpu_seconds: f64,
    peak_rss_bytes: u64,
    timing_scope: String,
    codec: &'static str,
    codec_quality: u8,
    codec_window_log: u8,
    codec_framing: &'static str,
    codec_input_bytes: u64,
    codec_input_gib: f64,
    codec_compressed_bytes: u64,
    codec_encoder_cpu_seconds: f64,
    codec_encoder_wall_seconds: f64,
    codec_frames: u64,
    codec_repeats: u64,
    flagged_events: u64,
    endpoint_mismatches: u64,
    positive_intervals_lost: u64,
    precision_violations: u64,
    rss_floor_violations: u64,
    source_hashes: Vec<pipeline::SourceHashStats>,
}

fn run_bench(args: &[String]) -> Result<()> {
    let parsed = parse_flags(
        args,
        &["--input", "--profiles", "--timebase", "--output"],
        &[],
    )?;
    let input = parsed
        .input
        .ok_or_else(|| "bench requires --input".to_string())?;
    let output = parsed
        .output
        .ok_or_else(|| "bench requires --output".to_string())?;
    let profiles = parsed
        .profiles
        .ok_or_else(|| "bench requires --profiles".to_string())?;
    let archives = archive_paths(&input)?;
    let mut results = Vec::new();
    let mut cached_files = Vec::new();
    if archives.is_empty() && input.is_dir() {
        collect_pst(&input, &mut cached_files)?;
        cached_files.sort();
    }
    let is_cached = !archives.is_empty()
        || input.extension().and_then(|x| x.to_str()) == Some("pst")
        || !cached_files.is_empty();
    if is_cached {
        let paths = if archives.is_empty() {
            if input.extension().and_then(|x| x.to_str()) == Some("pst") {
                vec![input.clone()]
            } else {
                cached_files
            }
        } else {
            Vec::new()
        };
        let start = std::time::Instant::now();
        let before = get_cpu();
        let mut source_profile = None;
        let mut total = 0u64;
        let mut scans = 0u64;
        let mut readings = 0u64;
        let mut flags = 0u64;
        let mut blocks = 0u64;
        let mut codec = CodecTotals::default();
        {
            let mut consume = |bytes: &[u8]| -> Result<()> {
                let block = decode_block(bytes)?;
                if source_profile.is_some_and(|p| p != block.profile) {
                    return Err("cached input contains mixed CPU profiles".into());
                }
                source_profile = Some(block.profile);
                codec.push(bytes)?;
                total = total.saturating_add(bytes.len() as u64);
                blocks += 1;
                scans = scans.saturating_add(block.rows.len() as u64);
                readings = readings.saturating_add(
                    block
                        .rows
                        .iter()
                        .map(|r| r.processes.len() as u64)
                        .sum::<u64>(),
                );
                flags = flags.saturating_add(
                    block
                        .rows
                        .iter()
                        .map(|r| r.quality.len() as u64)
                        .sum::<u64>(),
                );
                Ok(())
            };
            if !archives.is_empty() {
                for archive in &archives {
                    store::visit_blocks(archive, |bytes| consume(bytes))?;
                }
            } else {
                for path in &paths {
                    let bytes = fs::read(path)
                        .map_err(|e| format!("read cached block {}: {e}", path.display()))?;
                    consume(&bytes)?;
                }
            }
        }
        codec.flush()?;
        let source_profile =
            source_profile.ok_or_else(|| "cached input contains no binary blocks".to_string())?;
        if profiles.len() != 1 || profiles[0] != source_profile {
            return Err("cached binary supports codec-only benchmarking of its stored profile; use raw source to compare profiles".into());
        }
        let (cpu, peak) = get_cpu_delta(before);
        results.push(BenchResult {
            format: "pane-load-recording-bench",
            profile: format!("{:?}", source_profile),
            mode: "cached-binary-codec".into(),
            scans,
            readings,
            blocks,
            encoded_bytes: total,
            wall_seconds: start.elapsed().as_secs_f64(),
            own_cpu_seconds: cpu,
            child_cpu_seconds: 0.0,
            peak_rss_bytes: peak,
            timing_scope: "cached decode/validation plus separate codec encoder repeats".into(),
            codec: "brotli",
            codec_quality: 5,
            codec_window_log: 20,
            codec_framing: "PCR1",
            codec_input_bytes: codec.input_bytes,
            codec_input_gib: codec.input_bytes as f64 / 1_073_741_824.0,
            codec_compressed_bytes: codec.compressed_bytes,
            codec_encoder_cpu_seconds: codec.encoder_cpu_seconds,
            codec_encoder_wall_seconds: codec.encoder_wall_seconds,
            codec_frames: codec.frames,
            codec_repeats: codec.repeats,
            flagged_events: flags,
            endpoint_mismatches: 0,
            positive_intervals_lost: 0,
            precision_violations: 0,
            rss_floor_violations: 0,
            source_hashes: Vec::new(),
        });
    } else {
        let files = pipeline::source_files(&input)?;
        let output_abs = if output.exists() {
            fs::canonicalize(&output).map_err(|e| format!("resolve bench output: {e}"))?
        } else {
            let parent = output
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or(Path::new("."));
            fs::canonicalize(parent)
                .map_err(|e| format!("resolve bench output parent: {e}"))?
                .join(
                    output
                        .file_name()
                        .ok_or_else(|| "output has no final component".to_string())?,
                )
        };
        for file in &files {
            let source_abs =
                fs::canonicalize(file).map_err(|e| format!("resolve bench source: {e}"))?;
            let input_is_dir = fs::metadata(&input)
                .map_err(|e| format!("inspect bench input: {e}"))?
                .is_dir();
            if (input_is_dir
                && output_abs.starts_with(
                    &fs::canonicalize(&input).map_err(|e| format!("resolve bench input: {e}"))?,
                ))
                || (!input_is_dir && output_abs == source_abs)
            {
                return Err("bench output must not overlap its source tree".into());
            }
        }
        for profile in profiles {
            let stats = pipeline::benchmark_sources(&files, profile, parsed.timebase)?;
            results.push(BenchResult {
                format: "pane-load-recording-bench",
                profile: format!("{profile:?}"),
                mode: "source-transform-decode-verify-and-codec-encode".into(),
                scans: stats.scans,
                readings: stats.readings,
                blocks: stats.blocks,
                encoded_bytes: stats.raw_encoded_bytes,
                wall_seconds: stats.wall_seconds,
                own_cpu_seconds: stats.own_cpu_seconds,
                child_cpu_seconds: stats.child_cpu_seconds,
                peak_rss_bytes: stats.peak_rss_bytes,
                timing_scope: "includes source decode, profile transform, and decode verification; codec encoder timing is separate".into(),
                codec: "brotli",
                codec_quality: 5,
                codec_window_log: 20,
                codec_framing: "PCR1",
                codec_input_bytes: stats.codec_input_bytes,
                codec_input_gib: stats.codec_input_bytes as f64 / 1_073_741_824.0,
                codec_compressed_bytes: stats.codec_compressed_bytes,
                codec_encoder_cpu_seconds: stats.codec_encoder_cpu_seconds,
                codec_encoder_wall_seconds: stats.codec_encoder_wall_seconds,
                codec_frames: stats.codec_frames,
                codec_repeats: stats.codec_repeats,
                flagged_events: stats.flagged_events,
                endpoint_mismatches: stats.endpoint_mismatches,
                positive_intervals_lost: stats.positive_intervals_lost,
                precision_violations: stats.precision_violations,
                rss_floor_violations: stats.rss_floor_violations,
                source_hashes: stats.source_hashes,
            });
        }
    }
    write_results(&output, &results)
}

fn write_results(path: &Path, results: &[BenchResult]) -> Result<()> {
    let file_output = path.extension().and_then(|s| s.to_str()) == Some("jsonl");
    let target = if file_output {
        path.to_path_buf()
    } else {
        if path.exists() {
            let meta =
                fs::symlink_metadata(path).map_err(|e| format!("inspect benchmark output: {e}"))?;
            if meta.file_type().is_symlink() || !meta.is_dir() {
                return Err("benchmark output must be a new directory".into());
            }
            if fs::read_dir(path)
                .map_err(|e| format!("list benchmark output: {e}"))?
                .next()
                .is_some()
            {
                return Err("benchmark output directory is not empty".into());
            }
            #[cfg(unix)]
            if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
                return Err("existing benchmark output must be owned and private".into());
            }
        } else {
            let mut builder = DirBuilder::new();
            #[cfg(unix)]
            builder.mode(0o700);
            builder
                .create(path)
                .map_err(|e| format!("create benchmark output: {e}"))?;
        }
        path.join("bench.jsonl")
    };
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    opts.mode(0o600);
    let file = opts
        .open(&target)
        .map_err(|e| format!("create benchmark results: {e}"))?;
    let mut writer = BufWriter::new(file);
    for result in results {
        serde_json::to_writer(&mut writer, result)
            .map_err(|e| format!("encode benchmark result: {e}"))?;
        writer
            .write_all(b"\n")
            .map_err(|e| format!("write benchmark result: {e}"))?;
    }
    writer
        .flush()
        .map_err(|e| format!("flush benchmark results: {e}"))?;
    writer
        .get_ref()
        .sync_all()
        .map_err(|e| format!("sync benchmark results: {e}"))?;
    Ok(())
}

fn collect_pst(root: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(root).map_err(|e| format!("list cache: {e}"))? {
        let entry = entry.map_err(|e| format!("read cache entry: {e}"))?;
        let path = entry.path();
        let m = fs::symlink_metadata(&path).map_err(|e| format!("inspect cache entry: {e}"))?;
        if m.file_type().is_symlink() {
            return Err("cache contains symlink".into());
        }
        if m.is_dir() {
            collect_pst(&path, out)?;
        } else if m.is_file() && path.extension().and_then(|x| x.to_str()) == Some("pst") {
            out.push(path);
        }
    }
    Ok(())
}

fn get_cpu() -> (f64, u64) {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
        return (0.0, 0);
    }
    let u = unsafe { usage.assume_init() };
    let secs = u.ru_utime.tv_sec as f64
        + u.ru_utime.tv_usec as f64 / 1e6
        + u.ru_stime.tv_sec as f64
        + u.ru_stime.tv_usec as f64 / 1e6;
    #[cfg(target_os = "macos")]
    let peak = u.ru_maxrss.max(0) as u64;
    #[cfg(not(target_os = "macos"))]
    let peak = (u.ru_maxrss.max(0) as u64).saturating_mul(1024);
    (secs, peak)
}
fn get_cpu_delta(before: (f64, u64)) -> (f64, u64) {
    let after = get_cpu();
    ((after.0 - before.0).max(0.0), after.1)
}

fn parse_named_profile(value: &str) -> Result<Profile> {
    match value {
        "adaptive" => Ok(Profile::Adaptive),
        "legacy-1ms" => Ok(Profile::Legacy1ms),
        "fixed-100us" => Ok(Profile::Fixed100us),
        _ => Err(format!("unknown recording profile: {value}")),
    }
}

fn parse_format(value: &str) -> Result<OutputFormat> {
    match value {
        "binary" => Ok(OutputFormat::Binary),
        "jsonl-zstd" => Ok(OutputFormat::JsonlZstd),
        _ => Err(format!("unknown recording output format: {value}")),
    }
}
fn parse_u64(value: &str, label: &str) -> Result<u64> {
    value
        .parse()
        .map_err(|_| format!("{label} must be an unsigned integer"))
}
fn parse_usize(value: &str, label: &str) -> Result<usize> {
    value
        .parse()
        .map_err(|_| format!("{label} must be a positive integer"))
}
fn parse_f64(value: &str, label: &str) -> Result<f64> {
    value
        .parse()
        .map_err(|_| format!("{label} must be a number"))
}
fn parse_timebase(value: &str) -> Result<Timebase> {
    let (n, d) = value
        .split_once('/')
        .ok_or_else(|| "--timebase must be NUM/DEN".to_string())?;
    if d.contains('/') || n.is_empty() || d.is_empty() {
        return Err("--timebase must be NUM/DEN".into());
    }
    let t = Timebase {
        numer: parse_u64(n, "timebase numerator")?,
        denom: parse_u64(d, "timebase denominator")?,
    };
    t.validate()?;
    Ok(t)
}
