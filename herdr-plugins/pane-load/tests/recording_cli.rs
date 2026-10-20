use herdr_pane_load::recording::pipeline;
use herdr_pane_load::recording::source::RawWriter;
use herdr_pane_load::recording::store;
use herdr_pane_load::recording::{
    Context, LiveMessage, Observation, OutputFormat, Process, Profile, RecordOptions, Timebase,
};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "pane-load-cli-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn context(run: &str) -> Context {
    let mut context = Context::new(Timebase {
        numer: 125,
        denom: 3,
    });
    context.capture_run_id = Some(run.to_owned());
    context.boot_id = Some("boot-fixture".into());
    context.clock = "mach_continuous_time".into();
    context
}
fn row(seq: u64, stamp: u64, processes: Vec<Process>) -> Observation {
    Observation {
        seq,
        wall_start_ns: 1_700_000_000_000_000_000 + seq as i64,
        scan_start_ns: stamp,
        scan_end_ns: stamp + 10,
        processes,
        quality: vec![],
    }
}
fn proc(user: u64, system: u64) -> Process {
    Process {
        pid: 42,
        ppid: 1,
        start_sec: 10,
        start_usec: 20,
        name: "fixture".into(),
        user,
        system,
        rss: 900_000,
        owned: None,
        peak: None,
        evicted: None,
    }
}
fn options(output: PathBuf, format: OutputFormat) -> RecordOptions {
    RecordOptions {
        output,
        duration: None,
        hz: 10,
        profile: Profile::Adaptive,
        format,
        frame_bytes: 1024 * 1024,
        max_bytes: 64 * 1024 * 1024,
        min_free_bytes: 0,
        block_rows: 300,
        verify: false,
        memory: Default::default(),
    }
}
fn write_source(path: &Path, context: &Context, rows: &[Observation]) {
    let mut writer = RawWriter::create(path, context).unwrap();
    for row in rows {
        writer.write(row).unwrap();
    }
    writer.finish().unwrap();
}
fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[test]
fn record_options_reject_unknown_and_duplicate_flags_and_apply_defaults() {
    use herdr_pane_load::recording::cli::parse_record_options;
    let bad = vec!["--output".into(), "x".into(), "--wat".into(), "yes".into()];
    assert!(parse_record_options(&bad).unwrap_err().contains("unknown"));
    let duplicate = vec!["--output".into(), "a".into(), "--output".into(), "b".into()];
    assert!(
        parse_record_options(&duplicate)
            .unwrap_err()
            .contains("duplicate")
    );
    let options = parse_record_options(&["--output".into(), "store".into()]).unwrap();
    assert_eq!(options.profile, Profile::Adaptive);
    for (name, expected) in [
        ("adaptive", Profile::Adaptive),
        ("adaptive-inverse", Profile::AdaptiveInverse),
        ("adaptive-log", Profile::AdaptiveLog),
        ("legacy-1ms", Profile::Legacy1ms),
        ("fixed-100us", Profile::Fixed100us),
    ] {
        let options = parse_record_options(&[
            "--output".into(),
            "store".into(),
            "--profile".into(),
            name.into(),
        ])
        .unwrap();
        assert_eq!(options.profile, expected);
    }
    for alias in ["adaptive-inverse-v1", "adaptive-log-v1"] {
        let result = parse_record_options(&[
            "--output".into(),
            "store".into(),
            "--profile".into(),
            alias.into(),
        ]);
        assert!(result.is_err(), "accepted new profile alias {alias}");
    }
    assert_eq!(options.hz, 10);
    assert_eq!(options.block_rows, 300);
    assert_eq!(options.frame_bytes, 16 * 1024 * 1024);
    assert_eq!(options.max_bytes, 8 * 1024 * 1024 * 1024);
    assert_eq!(options.min_free_bytes, 20 * 1024 * 1024 * 1024);
    assert_eq!(options.format, OutputFormat::Binary);
    assert!(!options.verify);
}

#[test]
fn channel_eof_commits_tail_and_raw_replay_has_binary_block_parity() {
    let temp = Temp::new();
    let context = context("parity");
    let mut rows = vec![
        row(0, 1_000, vec![proc(100, 10)]),
        row(1, 2_000, vec![proc(110, 20)]),
    ];
    // Raw source fixtures must carry acquisition-time quality for same-source parity.
    rows[0].quality.push(serde_json::json!({
        "kind":"cpu-continuity-unknown",
        "reason":"new-or-expired-live-baseline",
        "identity":{"pid":42,"start_sec":10,"start_usec":20},
        "seq":0,"scan_start_ns":1000,"unavailable_rate":true
    }));
    let (tx, rx) = mpsc::channel();
    for row in rows.clone() {
        tx.send(row.into()).unwrap();
    }
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    let binary_root = temp.path("binary");
    let stats = pipeline::consume_live(
        &options(binary_root.clone(), OutputFormat::Binary),
        &context,
        rx,
    )
    .unwrap();
    assert_eq!(stats.scans, 2);
    assert_eq!(stats.blocks, 1); // acquisition quality does not split ordinary blocks
    let live_blocks = store::read_archive(&binary_root.join("run-parity/archive")).unwrap();
    assert_eq!(live_blocks.len(), 1);

    let (tx, rx) = mpsc::channel();
    for row in rows {
        tx.send(row.into()).unwrap();
    }
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    let raw_root = temp.path("raw");
    pipeline::consume_live(
        &options(raw_root.clone(), OutputFormat::JsonlZstd),
        &context,
        rx,
    )
    .unwrap();
    let raw_run = raw_root.join("run-parity");
    let files = pipeline::source_files(&raw_run).unwrap();
    assert_eq!(files.len(), 1);
    let replay_root = temp.path("replayed");
    let replay_stats = pipeline::transform_sources(
        &files,
        &replay_root,
        &options(replay_root.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    assert_eq!(replay_stats.scans, 2);
    assert!(replay_root.join("complete.json").is_file());
    assert!(!replay_root.join("partial.json").exists());
    let replay_blocks = store::read_archive(&replay_root.join("archive")).unwrap();
    assert_eq!(live_blocks, replay_blocks);
}

#[test]
fn fresh_live_identity_quality_does_not_split_blocks_and_replay_is_identical() {
    let temp = Temp::new();
    let context = context("new-identity-parity");
    let mut new_process = proc(30, 40);
    new_process.pid = 43;
    let rows = vec![
        row(0, 100, vec![proc(10, 20)]),
        row(1, 200, vec![proc(20, 30)]),
        row(2, 300, vec![new_process]),
    ];

    let live_root = temp.path("live-binary");
    let (tx, rx) = mpsc::channel();
    for row in rows.clone() {
        tx.send(row.into()).unwrap();
    }
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    let live = pipeline::consume_live(
        &options(live_root.clone(), OutputFormat::Binary),
        &context,
        rx,
    )
    .unwrap();
    assert_eq!(live.blocks, 1);

    let raw_root = temp.path("live-raw");
    let (tx, rx) = mpsc::channel();
    for row in rows {
        tx.send(row.into()).unwrap();
    }
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    pipeline::consume_live(
        &options(raw_root.clone(), OutputFormat::JsonlZstd),
        &context,
        rx,
    )
    .unwrap();
    let files = pipeline::source_files(&raw_root.join("run-new-identity-parity")).unwrap();
    let replay_root = temp.path("replayed");
    let replay = pipeline::transform_sources(
        &files,
        &replay_root,
        &options(replay_root.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    assert_eq!(replay.blocks, 1);
    assert_eq!(
        store::read_archive(&live_root.join("run-new-identity-parity/archive")).unwrap(),
        store::read_archive(&replay_root.join("archive")).unwrap()
    );
}

#[test]
fn frozen_capture_ledger_is_verified_and_checked_ledger_is_source_ordered() {
    let temp = Temp::new();
    let capture = temp.path("capture");
    let source_root = capture.join("source");
    fs::create_dir_all(&source_root).unwrap();
    let context = context("frozen-capture");
    let rows = vec![
        row(10, 100, vec![proc(100, 20)]),
        row(11, 200, vec![proc(110, 30)]),
    ];
    let source_path = source_root.join("source-000000.jsonl.zst");
    write_source(&source_path, &context, &rows);
    let source_bytes = fs::read(&source_path).unwrap();
    let ledger = serde_json::json!({
        "path":"source-000000.jsonl.zst", "segment_index":0, "count":2,
        "requested_samples":2, "seq_range":[10,11], "time_range_ns":[100,200],
        "complete":true, "capture_run_id":"frozen-capture"
    });
    let mut ledger_bytes = serde_json::to_vec(&ledger).unwrap();
    ledger_bytes.push(b'\n');
    fs::write(source_root.join("segments.jsonl"), &ledger_bytes).unwrap();
    // Older preserved run metadata omits capture_run_id; the ledger remains authoritative.
    let run_bytes = b"{\"hz\":10,\"started_utc\":\"fixture\"}\n";
    fs::write(capture.join("run.json"), run_bytes).unwrap();
    let preserved = serde_json::json!({"files":[
        {"path":"source/source-000000.jsonl.zst","bytes":source_bytes.len(),"sha256":sha256(&source_bytes)},
        {"path":"source/segments.jsonl","bytes":ledger_bytes.len(),"sha256":sha256(&ledger_bytes)},
        {"path":"run.json","bytes":run_bytes.len(),"sha256":sha256(run_bytes)}
    ]});
    fs::write(
        capture.join("PRESERVATION.json"),
        serde_json::to_vec(&serde_json::json!({
            "capture_run_id":"frozen-capture","segments":1,"actual_samples":2,
            "files":preserved["files"]
        }))
        .unwrap(),
    )
    .unwrap();

    let files = pipeline::source_files(&capture).unwrap();
    assert_eq!(files.as_slice(), std::slice::from_ref(&source_path));
    let output = temp.path("converted-capture");
    let stats = pipeline::transform_sources(
        &files,
        &output,
        &options(output.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    assert_eq!(stats.scans, 2);
    let checked: serde_json::Value = serde_json::from_slice(
        fs::read(output.join("checkedsegments.jsonl"))
            .unwrap()
            .split(|b| *b == b'\n')
            .next()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(checked["capture_run_id"], "frozen-capture");
    assert_eq!(checked["segment_index"], 0);
    assert_eq!(checked["source_sha256"], sha256(&source_bytes));
    assert_eq!(checked["scans"], 2);
    assert_eq!(checked["seq_range"][0], 10);
    assert_eq!(checked["seq_range"][1], 11);
}

#[test]
fn capture_ledger_accepts_ordered_subsets_and_rejects_reordering_or_missing_sources() {
    let temp = Temp::new();
    let capture = temp.path("subset-capture");
    let source_root = capture.join("source");
    fs::create_dir_all(&source_root).unwrap();
    let ctx = context("subset-capture");
    for index in 0..3_u64 {
        let path = source_root.join(format!("source-{index:06}.jsonl.zst"));
        write_source(
            &path,
            &ctx,
            &[row(index, (index + 1) * 100, vec![proc(10 + index, 20)])],
        );
        let segment = serde_json::json!({
            "path":format!("source-{index:06}.jsonl.zst"), "segment_index":index,
            "count":1, "requested_samples":1, "seq_range":[index,index],
            "time_range_ns":[(index + 1) * 100,(index + 1) * 100],
            "complete":true, "capture_run_id":"subset-capture"
        });
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(source_root.join("segments.jsonl"))
            .unwrap();
        serde_json::to_writer(&mut file, &segment).unwrap();
        use std::io::Write;
        file.write_all(b"\n").unwrap();
    }
    let files = pipeline::source_files(&capture).unwrap();
    let output = temp.path("middle-only");
    let stats = pipeline::transform_sources(
        &[files[1].clone()],
        &output,
        &options(output.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    assert_eq!(stats.scans, 1);
    assert_eq!(stats.source_hashes.len(), 1);
    let checked: serde_json::Value = serde_json::from_slice(
        fs::read(output.join("checkedsegments.jsonl"))
            .unwrap()
            .split(|byte| *byte == b'\n')
            .next()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(checked["segment_index"], 1);
    assert_eq!(checked["capture_run_id"], "subset-capture");
    assert_eq!(checked["scans"], 1);

    let reordered_output = temp.path("reordered-subset");
    let error = pipeline::transform_sources(
        &[files[1].clone(), files[0].clone()],
        &reordered_output,
        &options(reordered_output.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap_err();
    assert!(error.contains("contiguous ordered capture-ledger subset"));
    assert!(!reordered_output.exists());

    fs::remove_file(&files[2]).unwrap();
    assert!(
        pipeline::source_files(&capture)
            .unwrap_err()
            .contains("missing or unclaimed source segments")
    );
}

#[test]
fn transform_verify_flag_audits_and_labels_cpu_scope() {
    let temp = Temp::new();
    let source = temp.path("verify-source.jsonl.zst");
    write_source(
        &source,
        &context("verify"),
        &[row(0, 100, vec![proc(50, 25)])],
    );
    let output = temp.path("verified-transform");
    herdr_pane_load::recording::cli::run(&[
        "transform".into(),
        "--input".into(),
        source.to_string_lossy().into_owned(),
        "--output".into(),
        output.to_string_lossy().into_owned(),
        "--verify".into(),
    ])
    .unwrap();
    let status: serde_json::Value =
        serde_json::from_slice(&fs::read(output.join("complete.json")).unwrap()).unwrap();
    assert_eq!(status["verification_enabled"], true);
    assert_eq!(status["precision_violations"], 0);
    assert_eq!(status["rss_floor_violations"], 0);
    assert_eq!(status["endpoint_mismatches"], 0);

    let unverified_output = temp.path("unverified-transform");
    let stdout = Command::new(env!("CARGO_BIN_EXE_pane-load"))
        .args(["recording", "transform", "--input"])
        .arg(&source)
        .arg("--output")
        .arg(&unverified_output)
        .output()
        .unwrap();
    assert!(stdout.status.success());
    let transformed: serde_json::Value = serde_json::from_slice(&stdout.stdout).unwrap();
    assert_eq!(transformed["verification_enabled"], false);
    assert_eq!(transformed["cpu_checkpoints"], 1);
    assert_eq!(transformed["cpu_intervals"], 0);
    let inspected = Command::new(env!("CARGO_BIN_EXE_pane-load"))
        .args(["recording", "inspect", "--input"])
        .arg(unverified_output.join("archive"))
        .output()
        .unwrap();
    assert!(inspected.status.success());
    let summary: serde_json::Value = serde_json::from_slice(&inspected.stdout).unwrap();
    assert_eq!(summary["cpu_checkpoints"], transformed["cpu_checkpoints"]);
    assert_eq!(summary["cpu_intervals"], transformed["cpu_intervals"]);
    assert_eq!(
        summary["cpu_omitted_readings"],
        transformed["cpu_omitted_readings"]
    );
}

#[test]
fn source_audit_handles_empty_rows_metadata_changes_and_gaps() {
    let temp = Temp::new();
    let source = temp.path("audit-source.jsonl.zst");
    let mut changed = proc(1, 0);
    changed.name = "renamed".into();
    changed.ppid = 9;
    let mut last = proc(100_000, 0);
    last.name = changed.name.clone();
    last.ppid = changed.ppid;
    write_source(
        &source,
        &context("audit"),
        &[
            row(0, 100, vec![proc(0, 0)]),
            row(1, 200, vec![proc(1, 0)]),
            row(2, 300, vec![]),
            row(3, 400, vec![changed.clone()]),
            row(4, 500, vec![last]),
        ],
    );
    let adaptive = pipeline::benchmark_sources(
        std::slice::from_ref(&source),
        Profile::Adaptive,
        None,
        16 * 1024 * 1024,
    )
    .unwrap();
    assert_eq!(adaptive.precision_violations, 0);
    assert_eq!(adaptive.endpoint_mismatches, 0);
    assert_eq!(adaptive.rss_floor_violations, 0);

    let fixed = pipeline::benchmark_sources(
        std::slice::from_ref(&source),
        Profile::Fixed100us,
        None,
        16 * 1024 * 1024,
    )
    .unwrap();
    assert_eq!(fixed.precision_violations, 0);
    assert_eq!(fixed.endpoint_mismatches, 0);

    let legacy =
        pipeline::benchmark_sources(&[source], Profile::Legacy1ms, None, 16 * 1024 * 1024).unwrap();
    assert_eq!(legacy.precision_violations, 0);
    assert!(legacy.cpu_checkpoints > 0);
    assert_eq!(legacy.endpoint_mismatches, 0);
    assert!(legacy.positive_intervals_lost > 0);
}

#[test]
fn bench_reports_encoder_metrics_separately_from_decode_verification() {
    let temp = Temp::new();
    let raw = temp.path("bench-source.jsonl.zst");
    let context = context("bench");
    write_source(
        &raw,
        &context,
        &[
            row(0, 100, vec![proc(10, 10)]),
            row(1, 200, vec![proc(20, 20)]),
        ],
    );
    let raw_output = temp.path("raw-bench.jsonl");
    herdr_pane_load::recording::cli::run(&[
        "bench".into(),
        "--input".into(),
        raw.to_string_lossy().into_owned(),
        "--profiles".into(),
        "adaptive".into(),
        "--output".into(),
        raw_output.to_string_lossy().into_owned(),
    ])
    .unwrap();
    let raw_result: serde_json::Value = serde_json::from_slice(
        fs::read(&raw_output)
            .unwrap()
            .split(|b| *b == b'\n')
            .next()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(raw_result["codec"], "brotli");
    assert_eq!(raw_result["codec_framing"], "PCR1");
    assert!(
        raw_result["timing_scope"]
            .as_str()
            .unwrap()
            .contains("decode verification")
    );
    assert!(raw_result["codec_input_bytes"].as_u64().unwrap() > 0);
    assert!(raw_result["codec_compressed_bytes"].as_u64().unwrap() > 0);
    assert_eq!(
        raw_result["codec_repeats"],
        raw_result["codec_frames"].as_u64().unwrap() * 3
    );

    let output = temp.path("bench-transform");
    pipeline::transform_sources(
        &[raw],
        &output,
        &options(output.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    let cached_output = temp.path("cached-bench.jsonl");
    herdr_pane_load::recording::cli::run(&[
        "bench".into(),
        "--input".into(),
        output.join("archive").to_string_lossy().into_owned(),
        "--profiles".into(),
        "adaptive".into(),
        "--output".into(),
        cached_output.to_string_lossy().into_owned(),
    ])
    .unwrap();
    let cached: serde_json::Value = serde_json::from_slice(
        fs::read(cached_output)
            .unwrap()
            .split(|b| *b == b'\n')
            .next()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(cached["mode"], "cached-binary-codec");
    assert!(cached["codec_encoder_cpu_seconds"].as_f64().unwrap() >= 0.0);
}

#[test]
fn source_and_cached_benchmarks_share_frame_geometry_across_eight_blocks() {
    let temp = Temp::new();
    let raw = temp.path("eight-block-source.jsonl.zst");
    let ctx = context("eight-blocks");
    let rows: Vec<_> = (0..8)
        .map(|index| row(index, (index + 1) * 100, vec![proc(100 - index, 20)]))
        .collect();
    write_source(&raw, &ctx, &rows);
    let archive = temp.path("eight-block-archive");
    let transformed = pipeline::transform_sources(
        std::slice::from_ref(&raw),
        &archive,
        &options(archive.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    assert_eq!(transformed.blocks, 8);

    let run_bench = |input: &Path, target: usize, name: &str| {
        let output = temp.path(name);
        herdr_pane_load::recording::cli::run(&[
            "bench".into(),
            "--input".into(),
            input.to_string_lossy().into_owned(),
            "--profiles".into(),
            "adaptive".into(),
            "--frame-bytes".into(),
            target.to_string(),
            "--output".into(),
            output.to_string_lossy().into_owned(),
        ])
        .unwrap();
        serde_json::from_slice::<serde_json::Value>(
            fs::read(output)
                .unwrap()
                .split(|byte| *byte == b'\n')
                .next()
                .unwrap(),
        )
        .unwrap()
    };
    let raw_full = run_bench(&raw, 16 * 1024 * 1024, "raw-full.jsonl");
    let cache_full = run_bench(
        &archive.join("archive"),
        16 * 1024 * 1024,
        "cache-full.jsonl",
    );
    for key in [
        "codec_input_bytes",
        "codec_compressed_bytes",
        "codec_frames",
        "actual_max_input_bytes",
        "codec_repeats",
    ] {
        assert_eq!(raw_full[key], cache_full[key], "{key}");
    }
    assert_eq!(raw_full["codec_frames"], 1);
    assert_eq!(raw_full["codec_repeats"], 3);
    assert_eq!(raw_full["repeats_per_frame"], 3);
    assert_eq!(
        raw_full["actual_max_input_bytes"],
        raw_full["codec_input_bytes"]
    );

    let tail_target = raw_full["codec_input_bytes"].as_u64().unwrap() as usize / 2;
    let raw_tail = run_bench(&raw, tail_target, "raw-tail.jsonl");
    let cache_tail = run_bench(&archive.join("archive"), tail_target, "cache-tail.jsonl");
    for key in [
        "codec_input_bytes",
        "codec_compressed_bytes",
        "codec_frames",
        "actual_max_input_bytes",
        "codec_repeats",
    ] {
        assert_eq!(raw_tail[key], cache_tail[key], "{key}");
    }
    assert!(raw_tail["codec_frames"].as_u64().unwrap() > 1);
    assert!(raw_tail["codec_frames"].as_u64().unwrap() < 8);
    assert!(raw_tail["actual_max_input_bytes"].as_u64().unwrap() <= tail_target as u64);
    assert_eq!(raw_tail["frame_target_bytes"], tail_target);

    let raw_oversized = run_bench(&raw, 1, "raw-oversized.jsonl");
    let cache_oversized = run_bench(&archive.join("archive"), 1, "cache-oversized.jsonl");
    assert_eq!(raw_oversized["codec_frames"], 8);
    assert_eq!(
        raw_oversized["codec_frames"],
        cache_oversized["codec_frames"]
    );
    assert_eq!(
        raw_oversized["codec_input_bytes"],
        cache_oversized["codec_input_bytes"]
    );
    assert_eq!(
        raw_oversized["codec_compressed_bytes"],
        cache_oversized["codec_compressed_bytes"]
    );
    assert!(raw_oversized["actual_max_input_bytes"].as_u64().unwrap() > 1);
}

#[test]
fn inspect_exports_validated_private_pst_blocks_and_rejects_partial_data() {
    let temp = Temp::new();
    let raw = temp.path("export-source.jsonl.zst");
    write_source(&raw, &context("export"), &[row(0, 100, vec![proc(10, 20)])]);
    let output = temp.path("export-transform");
    pipeline::transform_sources(
        std::slice::from_ref(&raw),
        &output,
        &options(output.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    let original = store::read_archive(&output.join("archive"))
        .unwrap()
        .remove(0);
    let export = temp.path("pst-export");
    herdr_pane_load::recording::cli::run(&[
        "inspect".into(),
        "--input".into(),
        output.join("archive").to_string_lossy().into_owned(),
        "--blocks-out".into(),
        export.to_string_lossy().into_owned(),
    ])
    .unwrap();
    assert_eq!(fs::read(export.join("block-000000.pst")).unwrap(), original);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&export).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(export.join("block-000000.pst"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(export.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["quantized"], true);
    assert_eq!(manifest["raw_source_lossless"], false);
    assert_eq!(manifest["blocks"][0]["bytes"], original.len());
    assert_eq!(manifest["blocks"][0]["sha256"], sha256(&original));

    let cache = temp.path("pst-cache");
    fs::create_dir(&cache).unwrap();
    fs::write(cache.join("one.pst"), &original).unwrap();
    let cache_export = temp.path("cache-export");
    herdr_pane_load::recording::cli::run(&[
        "inspect".into(),
        "--input".into(),
        cache.to_string_lossy().into_owned(),
        "--blocks-out".into(),
        cache_export.to_string_lossy().into_owned(),
    ])
    .unwrap();
    assert_eq!(
        fs::read(cache_export.join("block-000000.pst")).unwrap(),
        original
    );
    assert!(
        herdr_pane_load::recording::cli::run(&[
            "inspect".into(),
            "--input".into(),
            output.join("archive").to_string_lossy().into_owned(),
            "--jsonl".into(),
            "--blocks-out".into(),
            temp.path("conflicting-export")
                .to_string_lossy()
                .into_owned(),
        ])
        .unwrap_err()
        .contains("mutually exclusive")
    );
    assert!(
        herdr_pane_load::recording::cli::run(&[
            "inspect".into(),
            "--input".into(),
            output.join("archive").to_string_lossy().into_owned(),
            "--blocks-out".into(),
            export.to_string_lossy().into_owned(),
        ])
        .is_err()
    );
    assert_eq!(fs::read(export.join("block-000000.pst")).unwrap(), original);

    let partial = output.join("partial.json");
    fs::write(&partial, br#"{"end_reason":"fixture partial"}"#).unwrap();
    let completion_wins = temp.path("completion-wins");
    herdr_pane_load::recording::cli::run(&[
        "inspect".into(),
        "--input".into(),
        output.join("archive").to_string_lossy().into_owned(),
        "--blocks-out".into(),
        completion_wins.to_string_lossy().into_owned(),
    ])
    .unwrap();
    assert!(completion_wins.join("manifest.json").is_file());
    fs::remove_file(output.join("complete.json")).unwrap();
    let rejected = temp.path("partial-export");
    assert!(
        herdr_pane_load::recording::cli::run(&[
            "inspect".into(),
            "--input".into(),
            output.join("archive").to_string_lossy().into_owned(),
            "--blocks-out".into(),
            rejected.to_string_lossy().into_owned(),
        ])
        .unwrap_err()
        .contains("partial")
    );
    assert!(!rejected.exists());
}

#[test]
fn capture_ledger_rejects_missing_segments_and_unclaimed_artifacts() {
    let temp = Temp::new();
    let capture = temp.path("capture-ledger");
    let source_root = capture.join("source");
    fs::create_dir_all(&source_root).unwrap();
    fs::write(capture.join("run.json"), b"{}\n").unwrap();
    assert!(
        pipeline::source_files(&capture)
            .unwrap_err()
            .contains("missing")
    );

    let context = context("unclaimed");
    let source_path = source_root.join("source-000000.jsonl.zst");
    let rows = [row(0, 100, vec![proc(10, 10)])];
    write_source(&source_path, &context, &rows);
    let entry = serde_json::json!({"path":"source-000000.jsonl.zst","segment_index":0,
        "count":1,"requested_samples":1,"seq_range":[0,0],"time_range_ns":[100,100],
        "complete":true,"capture_run_id":"unclaimed"});
    fs::write(source_root.join("segments.jsonl"), format!("{}\n", entry)).unwrap();
    fs::write(
        source_root.join("source-000001.jsonl.zst.partial"),
        b"partial",
    )
    .unwrap();
    assert!(
        pipeline::source_files(&capture)
            .unwrap_err()
            .contains("unclaimed")
    );
}

#[test]
fn raw_first_segment_numbering_rotates_and_replays_in_source_order() {
    let temp = Temp::new();
    let context = context("ordered-raw-rotation");
    let mut live_options = options(temp.path("live-binary"), OutputFormat::Binary);
    live_options.block_rows = 1;
    live_options.frame_bytes = 1024;
    let rows = vec![
        row(0, 100, vec![proc(10, 20)]),
        row(1, 200, vec![proc(20, 30)]),
        row(2, 300, vec![proc(30, 40)]),
    ];
    let (tx, rx) = mpsc::channel();
    for row in rows.clone() {
        tx.send(row.into()).unwrap();
    }
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    pipeline::consume_live(&live_options, &context, rx).unwrap();

    let raw_root = temp.path("raw");
    let mut raw_options = options(raw_root.clone(), OutputFormat::JsonlZstd);
    raw_options.block_rows = 1;
    raw_options.frame_bytes = 1;
    let (tx, rx) = mpsc::channel();
    for row in rows {
        tx.send(row.into()).unwrap();
    }
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    pipeline::consume_live(&raw_options, &context, rx).unwrap();

    let raw_run = raw_root.join("run-ordered-raw-rotation");
    let files = pipeline::source_files(&raw_run).unwrap();
    assert_eq!(files.len(), 3);
    assert!(files[0].ends_with("source-000000.jsonl.zst"));
    assert!(files[1].ends_with("source-000001.jsonl.zst"));
    assert!(files[2].ends_with("source-000002.jsonl.zst"));
    let replay_root = temp.path("replayed");
    let mut replay_options = options(replay_root.clone(), OutputFormat::Binary);
    replay_options.block_rows = 1;
    pipeline::transform_sources(&files, &replay_root, &replay_options, None).unwrap();
    assert_eq!(
        store::read_archive(&live_options.output.join("run-ordered-raw-rotation/archive")).unwrap(),
        store::read_archive(&replay_root.join("archive")).unwrap()
    );

    let old_layout = temp.path("old-layout");
    fs::create_dir(&old_layout).unwrap();
    let mut legacy = RawWriter::create(&old_layout.join("source.jsonl"), &context).unwrap();
    legacy.write(&row(0, 100, vec![proc(10, 20)])).unwrap();
    legacy.finish().unwrap();
    write_source(
        &old_layout.join("source-000001.jsonl.zst"),
        &context,
        &[row(1, 200, vec![proc(20, 30)])],
    );
    let old_files = pipeline::source_files(&old_layout).unwrap();
    assert!(old_files[0].ends_with("source.jsonl"));
    assert!(old_files[1].ends_with("source-000001.jsonl.zst"));
}

#[test]
fn size_flush_resets_frame_age_for_the_next_frame() {
    let temp = Temp::new();
    let mut options = options(temp.path("age-frames"), OutputFormat::Binary);
    options.block_rows = 1;
    options.frame_bytes = 2048;
    let context = context("frame-age-reset");
    let mut large = proc(10, 20);
    large.name = "x".repeat(4000);
    let rows = [
        row(0, 100, vec![large]),
        row(1, 3_599_999_999_900, vec![proc(20, 30)]),
        row(2, 3_600_000_000_100, vec![proc(30, 40)]),
    ];
    let (tx, rx) = mpsc::channel();
    for row in rows {
        tx.send(row.into()).unwrap();
    }
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    pipeline::consume_live(&options, &context, rx).unwrap();
    let archive = options.output.join("run-frame-age-reset/archive");
    let frames = fs::read_dir(archive)
        .unwrap()
        .filter_map(|entry| {
            let path = entry.unwrap().path();
            path.extension()
                .is_some_and(|extension| extension == "pcr")
                .then_some(path)
        })
        .count();
    assert_eq!(frames, 2, "the two recent rows should share their frame");
}

#[test]
fn regression_across_missing_scan_and_source_shard_is_cut_and_annotated() {
    let temp = Temp::new();
    let root = temp.path("capture/capture/source");
    fs::create_dir_all(&root).unwrap();
    let context = context("sharded");
    let first = vec![row(0, 100, vec![proc(100, 200)]), row(1, 200, vec![])];
    let second = vec![row(2, 300, vec![proc(90, 150)])];
    write_source(&root.join("source-000000.jsonl.zst"), &context, &first);
    write_source(&root.join("source-000001.jsonl.zst"), &context, &second);
    let inputs = pipeline::source_files(&temp.path("capture")).unwrap();
    assert!(inputs[0].ends_with("source-000000.jsonl.zst"));
    let output = temp.path("converted");
    let stats = pipeline::transform_sources(
        &inputs,
        &output,
        &options(output.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    assert_eq!(stats.scans, 3);
    assert_eq!(stats.source_hashes.len(), 2);
    let blocks = store::read_archive(&output.join("archive")).unwrap();
    let decoded: Vec<_> = blocks
        .iter()
        .map(|bytes| herdr_pane_load::recording::decode_block(bytes).unwrap())
        .collect();
    let flagged: Vec<_> = decoded
        .iter()
        .flat_map(|block| block.rows.iter())
        .filter(|row| row.seq == 2)
        .collect();
    assert_eq!(flagged.len(), 1);
    let events = &flagged[0].quality;
    assert_eq!(
        events
            .iter()
            .filter(|v| v["kind"] == "cpu-component-regression")
            .count(),
        2
    );
    assert!(events.iter().all(|event| {
        event["unavailable_rate"] == true
            && event["restart_inference"]
                == "unknown; counter decrease is not proof of process restart"
            && event["before"]["cpu_unit"] == "native_ticks"
            && event["after"]["cpu_unit"] == "native_ticks"
            && event["before"]["user"] == 100
            && event["before"]["system"] == 200
            && event["after"]["user"] == 90
            && event["after"]["system"] == 150
    }));
    assert_eq!(decoded.iter().flat_map(|b| &b.rows).count(), 3);
}

#[test]
fn regression_cuts_before_row_without_forcing_singleton_block() {
    let temp = Temp::new();
    let context = context("regression-cut");
    let (tx, rx) = mpsc::channel();
    for observation in [
        row(0, 100, vec![proc(100, 100)]),
        row(1, 200, vec![proc(110, 110)]),
        row(2, 300, vec![proc(90, 90)]),
        row(3, 400, vec![proc(95, 95)]),
    ] {
        tx.send(observation.into()).unwrap();
    }
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);

    let root = temp.path("regression-cut");
    let stats =
        pipeline::consume_live(&options(root.clone(), OutputFormat::Binary), &context, rx).unwrap();
    assert_eq!(stats.blocks, 2);
    let blocks = store::read_archive(&root.join("run-regression-cut/archive")).unwrap();
    let decoded: Vec<_> = blocks
        .iter()
        .map(|bytes| herdr_pane_load::recording::decode_block(bytes).unwrap())
        .collect();
    assert_eq!(
        decoded[0]
            .rows
            .iter()
            .map(|row| row.seq)
            .collect::<Vec<_>>(),
        [0, 1]
    );
    assert_eq!(
        decoded[1]
            .rows
            .iter()
            .map(|row| row.seq)
            .collect::<Vec<_>>(),
        [2, 3]
    );
}

#[test]
fn source_run_partial_and_end_quality_survive_transform_even_for_file_input() {
    use std::os::unix::fs::PermissionsExt;
    let temp = Temp::new();
    let context = context("upstream-status");
    let partial_run = temp.path("partial-raw-run");
    fs::create_dir(&partial_run).unwrap();
    fs::set_permissions(&partial_run, fs::Permissions::from_mode(0o700)).unwrap();
    let partial_source = partial_run.join("source-000000.jsonl.zst");
    write_source(
        &partial_source,
        &context,
        &[row(0, 100, vec![proc(10, 20)])],
    );
    fs::write(
        partial_run.join("partial.json"),
        serde_json::to_vec(&serde_json::json!({
            "kind":"live-native", "complete":false, "status":"failed",
            "end_reason":"native producer failed after closed frame",
            "end_quality":[{"kind":"producer-drop","count":2}]
        }))
        .unwrap(),
    )
    .unwrap();
    fs::set_permissions(
        partial_run.join("partial.json"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let partial_output = temp.path("partial-import");
    let stats = pipeline::transform_sources(
        std::slice::from_ref(&partial_source),
        &partial_output,
        &options(partial_output.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    assert_eq!(
        stats.end_reason.as_deref(),
        Some("native producer failed after closed frame")
    );
    assert_eq!(stats.end_quality[0]["kind"], "producer-drop");
    assert_eq!(stats.flagged_events, 1);
    assert!(!partial_output.join("complete.json").exists());
    let partial: serde_json::Value =
        serde_json::from_slice(&fs::read(partial_output.join("partial.json")).unwrap()).unwrap();
    assert_eq!(
        partial["end_reason"],
        "native producer failed after closed frame"
    );
    assert_eq!(partial["end_quality"][0]["kind"], "producer-drop");

    let complete_run = temp.path("complete-raw-run");
    fs::create_dir(&complete_run).unwrap();
    fs::set_permissions(&complete_run, fs::Permissions::from_mode(0o700)).unwrap();
    let complete_source = complete_run.join("source-000000.jsonl.zst");
    write_source(
        &complete_source,
        &context,
        &[row(0, 100, vec![proc(10, 20)])],
    );
    fs::write(
        complete_run.join("complete.json"),
        serde_json::to_vec(&serde_json::json!({
            "kind":"live-native", "complete":true, "status":"complete",
            "end_quality":[{"kind":"orderly-stop"}]
        }))
        .unwrap(),
    )
    .unwrap();
    fs::set_permissions(
        complete_run.join("complete.json"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let complete_output = temp.path("complete-import");
    let stats = pipeline::transform_sources(
        &[complete_source],
        &complete_output,
        &options(complete_output.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    assert_eq!(stats.end_quality[0]["kind"], "orderly-stop");
    assert_eq!(stats.flagged_events, 1);
    assert!(complete_output.join("complete.json").is_file());

    let legacy_root = temp.path("preserved-legacy/source");
    fs::create_dir_all(&legacy_root).unwrap();
    write_source(
        &legacy_root.join("source-000000.jsonl.zst"),
        &context,
        &[row(0, 100, vec![proc(10, 20)])],
    );
    fs::write(
        legacy_root.join("status.json"),
        br#"{"status":"interrupted"}"#,
    )
    .unwrap();
    let legacy_files = pipeline::source_files(&temp.path("preserved-legacy")).unwrap();
    let legacy_output = temp.path("legacy-import");
    pipeline::transform_sources(
        &legacy_files,
        &legacy_output,
        &options(legacy_output.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    assert!(legacy_output.join("complete.json").is_file());
}

#[test]
fn record_root_rejects_foreign_permissions_hardlinked_lock_and_prior_bytes_without_chmod() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let temp = Temp::new();
    let context = context("private-root");

    let loose_root = temp.path("loose-root");
    fs::create_dir(&loose_root).unwrap();
    fs::set_permissions(&loose_root, fs::Permissions::from_mode(0o755)).unwrap();
    let (tx, rx) = mpsc::channel();
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    assert!(
        pipeline::consume_live(
            &options(loose_root.clone(), OutputFormat::Binary),
            &context,
            rx
        )
        .is_err()
    );
    assert_eq!(fs::metadata(&loose_root).unwrap().mode() & 0o777, 0o755);

    let linked_root = temp.path("linked-root");
    fs::create_dir(&linked_root).unwrap();
    fs::set_permissions(&linked_root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(linked_root.join("record.lock"), b"").unwrap();
    fs::set_permissions(
        linked_root.join("record.lock"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    fs::hard_link(linked_root.join("record.lock"), temp.path("lock-alias")).unwrap();
    let (tx, rx) = mpsc::channel();
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    assert!(
        pipeline::consume_live(&options(linked_root, OutputFormat::Binary), &context, rx).is_err()
    );

    let oversized = temp.path("oversized-root");
    fs::create_dir(&oversized).unwrap();
    fs::set_permissions(&oversized, fs::Permissions::from_mode(0o700)).unwrap();
    for index in 0..32 {
        let prior_run = oversized.join(format!("run-prior-{index:03}"));
        fs::create_dir(&prior_run).unwrap();
        fs::set_permissions(&prior_run, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(prior_run.join("data"), vec![index as u8; 128]).unwrap();
        fs::set_permissions(prior_run.join("data"), fs::Permissions::from_mode(0o600)).unwrap();
    }
    let mut limited = options(oversized.clone(), OutputFormat::Binary);
    limited.max_bytes = 1024;
    let (tx, rx) = mpsc::channel();
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    assert!(
        pipeline::consume_live(&limited, &context, rx)
            .unwrap_err()
            .contains("byte limit")
    );
    assert!(!oversized.join("run-private-root").exists());
}

#[test]
fn raw_recording_uses_remaining_budget_without_counting_old_history_twice() {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let temp = Temp::new();
    let root = temp.path("raw-budget");
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let prior = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(root.join("prior-history"))
        .unwrap();
    prior.set_len(40 * 1024 * 1024).unwrap();
    let config = options(root.clone(), OutputFormat::JsonlZstd);
    let (tx, rx) = mpsc::channel();
    tx.send(row(0, 100, vec![proc(10, 20)]).into()).unwrap();
    tx.send(row(1, 100_000_100, vec![proc(11, 21)]).into())
        .unwrap();
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    let stats = pipeline::consume_live(&config, &context("remaining-budget"), rx).unwrap();
    assert_eq!(stats.scans, 2);
    assert!(root.join("run-remaining-budget/complete.json").is_file());
}

#[test]
fn startup_recovers_only_incomplete_archives_and_reports_old_corruption() {
    use std::os::unix::fs::PermissionsExt;
    let temp = Temp::new();
    let root = temp.path("recovery-root");
    let old_context = context("completed-corrupt");
    let (tx, rx) = mpsc::channel();
    tx.send(row(0, 100, vec![proc(10, 20)]).into()).unwrap();
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    pipeline::consume_live(
        &options(root.clone(), OutputFormat::Binary),
        &old_context,
        rx,
    )
    .unwrap();
    let completed_archive = root.join("run-completed-corrupt/archive");
    let frame = fs::read_dir(&completed_archive)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.extension().is_some_and(|extension| extension == "pcr"))
        .unwrap();
    let mut bytes = fs::read(&frame).unwrap();
    let middle = bytes.len() / 2;
    bytes[middle] ^= 0x40;
    fs::write(&frame, bytes).unwrap();

    let (tx, rx) = mpsc::channel();
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    let fresh = pipeline::consume_live(
        &options(root.clone(), OutputFormat::Binary),
        &context("fresh-after-complete-corruption"),
        rx,
    )
    .unwrap();
    assert!(fresh.recovery.is_empty());

    let incomplete = root.join("run-incomplete-corrupt");
    fs::create_dir(&incomplete).unwrap();
    fs::set_permissions(&incomplete, fs::Permissions::from_mode(0o700)).unwrap();
    let mut writer = store::ArchiveWriter::open(
        &incomplete.join("archive"),
        &context("incomplete-corrupt"),
        Profile::Adaptive,
        store::StoreOptions::default(),
    )
    .unwrap();
    writer.append(b"frame to corrupt").unwrap();
    writer.finish().unwrap();
    fs::write(
        incomplete.join("partial.json"),
        br#"{"kind":"live-native","complete":false,"end_reason":"killed"}"#,
    )
    .unwrap();
    fs::set_permissions(
        incomplete.join("partial.json"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let frame = fs::read_dir(incomplete.join("archive"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.extension().is_some_and(|extension| extension == "pcr"))
        .unwrap();
    let mut bytes = fs::read(&frame).unwrap();
    let middle = bytes.len() / 2;
    bytes[middle] ^= 0x40;
    fs::write(&frame, bytes).unwrap();

    let (tx, rx) = mpsc::channel();
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    let after_bad_partial = pipeline::consume_live(
        &options(root.clone(), OutputFormat::Binary),
        &context("fresh-after-partial-corruption"),
        rx,
    )
    .unwrap();
    assert!(
        after_bad_partial
            .recovery
            .iter()
            .any(|report| report.contains("recovery warning"))
    );

    let journal_run = root.join("run-journal-recovery");
    fs::create_dir(&journal_run).unwrap();
    fs::set_permissions(&journal_run, fs::Permissions::from_mode(0o700)).unwrap();
    let mut writer = store::ArchiveWriter::open(
        &journal_run.join("archive"),
        &context("journal-recovery"),
        Profile::Adaptive,
        store::StoreOptions::default(),
    )
    .unwrap();
    writer.append(b"durable journal tail").unwrap();
    drop(writer);
    fs::write(
        journal_run.join("partial.json"),
        br#"{"kind":"live-native","complete":false,"end_reason":"killed"}"#,
    )
    .unwrap();
    fs::set_permissions(
        journal_run.join("partial.json"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let (tx, rx) = mpsc::channel();
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    pipeline::consume_live(
        &options(root.clone(), OutputFormat::Binary),
        &context("fresh-after-journal-recovery"),
        rx,
    )
    .unwrap();
    assert_eq!(
        store::read_archive(&journal_run.join("archive")).unwrap(),
        [b"durable journal tail".to_vec()]
    );
    assert!(!journal_run.join("archive/active.journal").exists());
}

#[test]
fn missing_or_failed_end_never_publishes_complete_and_end_quality_is_counted() {
    let temp = Temp::new();
    let context = context("end-state");
    let root = temp.path("missing-end");
    let (tx, rx) = mpsc::channel();
    tx.send(row(0, 100, vec![proc(100, 100)]).into()).unwrap();
    drop(tx);
    assert!(
        pipeline::consume_live(&options(root.clone(), OutputFormat::Binary), &context, rx,)
            .is_err()
    );
    let run = root.join("run-end-state");
    assert!(!run.join("complete.json").exists());
    let partial: serde_json::Value =
        serde_json::from_slice(&fs::read(run.join("partial.json")).unwrap()).unwrap();
    assert_eq!(partial["kind"], "live-native");
    assert_eq!(partial["complete"], false);
    assert_eq!(store::read_archive(&run.join("archive")).unwrap().len(), 1);
    herdr_pane_load::recording::cli::run(&[
        "inspect".into(),
        "--input".into(),
        run.to_string_lossy().into_owned(),
        "--recover".into(),
    ])
    .unwrap();
    assert!(run.join("partial.json").is_file());
    assert!(
        herdr_pane_load::recording::cli::run(&[
            "inspect".into(),
            "--input".into(),
            run.to_string_lossy().into_owned(),
            "--jsonl".into(),
        ])
        .unwrap_err()
        .contains("partial recording")
    );

    let root = temp.path("failed-end");
    let (tx, rx) = mpsc::channel();
    tx.send(row(0, 100, vec![proc(100, 100)]).into()).unwrap();
    tx.send(LiveMessage::End {
        quality: vec![serde_json::json!({"kind":"producer-drop","count":3})],
        error: Some("sampler failed".into()),
    })
    .unwrap();
    drop(tx);
    assert!(
        pipeline::consume_live(&options(root.clone(), OutputFormat::Binary), &context, rx,)
            .is_err()
    );
    let partial: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("run-end-state/partial.json")).unwrap())
            .unwrap();
    assert_eq!(partial["flagged_events"], 2); // scan baseline plus producer-end quality
    assert_eq!(partial["end_quality"][0]["kind"], "producer-drop");
    assert_eq!(partial["end_reason"], "sampler failed");
    assert!(!root.join("run-end-state/complete.json").exists());
}

#[test]
fn native_run_publishes_in_progress_status_before_receiving_data() {
    let temp = Temp::new();
    let root = temp.path("in-progress");
    let run = root.join("run-before-data");
    let (tx, rx) = mpsc::channel();
    let worker = std::thread::spawn({
        let root = root.clone();
        move || {
            pipeline::consume_live(
                &options(root, OutputFormat::Binary),
                &context("before-data"),
                rx,
            )
        }
    });
    for _ in 0..200 {
        if run.join("partial.json").is_file() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let status: serde_json::Value =
        serde_json::from_slice(&fs::read(run.join("partial.json")).unwrap()).unwrap();
    assert_eq!(status["kind"], "live-native");
    assert_eq!(status["status"], "in-progress");
    assert_eq!(status["complete"], false);
    assert!(
        status["end_reason"]
            .as_str()
            .unwrap()
            .contains("trailing observations")
    );

    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    worker.join().unwrap().unwrap();
    assert!(run.join("complete.json").is_file());
    assert!(!run.join("partial.json").exists());
}

#[test]
fn live_expiry_marks_returning_identity_unknown_instead_of_false_regression() {
    let temp = Temp::new();
    let ctx = context("expiry");
    let (tx, rx) = mpsc::channel();
    tx.send(row(0, 100, vec![proc(100, 100)]).into()).unwrap();
    tx.send(row(1, 31_000_000_101, vec![proc(1, 1)]).into())
        .unwrap();
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    let root = temp.path("expired");
    pipeline::consume_live(&options(root.clone(), OutputFormat::Binary), &ctx, rx).unwrap();
    let blocks = store::read_archive(&root.join("run-expiry/archive")).unwrap();
    let decoded: Vec<_> = blocks
        .iter()
        .map(|bytes| herdr_pane_load::recording::decode_block(bytes).unwrap())
        .collect();
    let returned = decoded
        .iter()
        .flat_map(|block| &block.rows)
        .find(|row| row.seq == 1)
        .unwrap();
    assert!(
        returned
            .quality
            .iter()
            .any(|event| event["kind"] == "cpu-continuity-unknown")
    );
    assert!(
        !returned
            .quality
            .iter()
            .any(|event| event["kind"] == "cpu-component-regression")
    );

    // Replay is unbounded, but the explicit unknown-baseline flag resets this identity
    // before historical counters are compared.
    let source_path = temp.path("expiry-source.jsonl.zst");
    let mut replay_returned = row(1, 31_000_000_101, vec![proc(1, 1)]);
    replay_returned.quality = returned.quality.clone();
    write_source(
        &source_path,
        &context("expiry"),
        &[row(0, 100, vec![proc(100, 100)]), replay_returned],
    );
    let replay = temp.path("expiry-replay");
    pipeline::transform_sources(
        &[source_path],
        &replay,
        &options(replay.clone(), OutputFormat::Binary),
        None,
    )
    .unwrap();
    let replay_blocks = store::read_archive(&replay.join("archive")).unwrap();
    let replay_rows: Vec<_> = replay_blocks
        .iter()
        .flat_map(|bytes| {
            herdr_pane_load::recording::decode_block(bytes)
                .unwrap()
                .rows
        })
        .collect();
    assert!(
        replay_rows[1]
            .quality
            .iter()
            .all(|event| event["kind"] != "cpu-component-regression")
    );
}

#[test]
fn corrupt_source_never_publishes_success_manifest_and_marks_partial_output() {
    let temp = Temp::new();
    let source_path = temp.path("source.jsonl.zst");
    write_source(
        &source_path,
        &context("bad-crc"),
        &[row(0, 10, vec![proc(1, 2)])],
    );
    let mut bytes = fs::read(&source_path).unwrap();
    bytes.truncate(bytes.len() - 3);
    fs::write(&source_path, bytes).unwrap();
    let output = temp.path("partial");
    let result = pipeline::transform_sources(
        &[source_path],
        &output,
        &options(output.clone(), OutputFormat::Binary),
        None,
    );
    let error = result.unwrap_err();
    assert!(!output.join("complete.json").exists());
    let partial: serde_json::Value =
        serde_json::from_slice(&fs::read(output.join("partial.json")).unwrap()).unwrap();
    assert_eq!(partial["kind"], "source-import");
    assert_eq!(partial["complete"], false);
    assert_eq!(partial["error"], error);
    let inspect = herdr_pane_load::recording::cli::run(&[
        "inspect".into(),
        "--input".into(),
        output.to_string_lossy().into_owned(),
        "--jsonl".into(),
    ]);
    assert!(inspect.unwrap_err().contains("partial recording"));
}

#[test]
#[ignore = "requires an explicitly captured native reference in PROCSTATS_NATIVE_REFERENCE"]
fn native_reference_live_and_replay_byte_parity() {
    let source = PathBuf::from(
        std::env::var_os("PROCSTATS_NATIVE_REFERENCE").expect("set native reference path"),
    );
    let mut rows = Vec::new();
    let parsed = herdr_pane_load::recording::source::visit_source(&source, None, |_, row| {
        rows.push(row);
        Ok(())
    })
    .unwrap();
    assert!(!rows.is_empty());
    let temp = Temp::new();
    let live = temp.path("live");
    let config = options(live.clone(), OutputFormat::Binary);
    let (tx, rx) = mpsc::channel();
    for row in rows {
        tx.send(LiveMessage::Observation(row)).unwrap();
    }
    tx.send(LiveMessage::End {
        quality: vec![],
        error: None,
    })
    .unwrap();
    drop(tx);
    let stats = pipeline::consume_live(&config, &parsed.context, rx).unwrap();
    let replay = temp.path("replay");
    let mut replay_config = options(replay.clone(), OutputFormat::Binary);
    replay_config.verify = true;
    let replayed = pipeline::transform_sources(&[source], &replay, &replay_config, None).unwrap();
    assert_eq!(stats.scans, replayed.scans);
    let live_archive = live
        .join(format!("run-{}", parsed.context.capture_run_id.unwrap()))
        .join("archive");
    assert_eq!(
        store::read_archive(&live_archive).unwrap(),
        store::read_archive(&replay.join("archive")).unwrap()
    );
}

#[test]
fn real_capture_context_survives_legacy_control_and_per_shard_provenance() {
    let temp = Temp::new();
    for profile in [Profile::Legacy1ms, Profile::Adaptive] {
        let mut first = context("context-parity");
        first
            .source_headers
            .push(serde_json::json!({"segment_index":0}));
        let mut second = first.clone();
        second.source_headers = vec![serde_json::json!({"segment_index":1})];
        let label = format!("{profile:?}");
        let a = temp.path(&format!("{label}-0.jsonl.zst"));
        let b = temp.path(&format!("{label}-1.jsonl.zst"));
        write_source(
            &a,
            &first,
            &[
                row(0, 10, vec![proc(0, 0)]),
                row(1, 100_000_010, vec![proc(101, 0)]),
            ],
        );
        write_source(
            &b,
            &second,
            &[
                row(2, 200_000_010, vec![proc(202, 0)]),
                row(3, 300_000_010, vec![proc(303, 0)]),
            ],
        );
        let output = temp.path(&format!("{label}-archive"));
        let mut config = options(output.clone(), OutputFormat::Binary);
        config.profile = profile;
        config.verify = true;
        let stats = pipeline::transform_sources(&[a, b], &output, &config, None).unwrap();
        assert_eq!(stats.precision_violations, 0);
        let exported = temp.path(&format!("{label}-blocks"));
        herdr_pane_load::recording::cli::run(&[
            "inspect".into(),
            "--input".into(),
            output.to_string_lossy().into(),
            "--blocks-out".into(),
            exported.to_string_lossy().into(),
        ])
        .unwrap();
        assert!(exported.join("manifest.json").exists());
    }
}

#[test]
fn temporal_profile_cli_export_preserves_sparse_cpu_intervals_and_dense_metadata() {
    const STEP_NS: u64 = 100_000_000;
    const BURST_TICKS: u64 = 2_400_000; // 100 ms at 24 MHz native CPU ticks.
    let temp = Temp::new();
    let source = temp.path("temporal-source.jsonl.zst");
    let context = context("temporal-cli");
    let rows: Vec<_> = (0..201)
        .map(|seq| {
            let mut process = proc(if seq == 0 { 0 } else { BURST_TICKS }, 0);
            process.rss = 2 * 262_144;
            process.owned = Some(12_300);
            process.peak = Some(45_600);
            process.evicted = Some(78_900);
            row(seq, seq * STEP_NS, vec![process])
        })
        .collect();
    write_source(&source, &context, &rows);

    for (profile, expected_model) in [
        ("adaptive-inverse", "sparse-interval-averaged"),
        ("adaptive-log", "sparse-interval-averaged"),
    ] {
        let output = temp.path(&format!("transform-{profile}"));
        let transformed = Command::new(env!("CARGO_BIN_EXE_pane-load"))
            .args(["recording", "transform", "--input"])
            .arg(&source)
            .args(["--output"])
            .arg(&output)
            .args([
                "--profile",
                profile,
                "--verify",
                "--memory-columns",
                "owned,peak,evicted",
                "--memory-unit-bytes",
                "100",
                "--block-rows",
                "300",
                "--max-bytes",
                "67108864",
                "--min-free-bytes",
                "0",
            ])
            .output()
            .unwrap();
        assert!(
            transformed.status.success(),
            "{profile} transform failed: {}",
            String::from_utf8_lossy(&transformed.stderr)
        );
        let transform_stats: serde_json::Value =
            serde_json::from_slice(&transformed.stdout).unwrap();
        assert_eq!(transform_stats["verification_enabled"], true);
        assert_eq!(transform_stats["precision_violations"], 0);
        assert_eq!(transform_stats["scans"], 201);
        assert!(transform_stats["cpu_checkpoints"].as_u64().unwrap() < 201);
        assert!(transform_stats["cpu_omitted_readings"].as_u64().unwrap() > 0);

        let archive = output.join("archive");
        let inspected = Command::new(env!("CARGO_BIN_EXE_pane-load"))
            .args(["recording", "inspect", "--input"])
            .arg(&archive)
            .arg("--jsonl")
            .output()
            .unwrap();
        assert!(
            inspected.status.success(),
            "{profile} inspect failed: {}",
            String::from_utf8_lossy(&inspected.stderr)
        );
        let exported: Vec<serde_json::Value> = String::from_utf8(inspected.stdout)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let header = exported
            .iter()
            .find(|value| value.get("recording_export").is_some())
            .unwrap();
        assert_eq!(header["profile"], profile);
        assert_eq!(header["cpu_unit"], "native_ticks");
        assert_eq!(header["time_unit"], "ns");
        assert_eq!(header["cpu_total_only"], true);
        assert_eq!(header["cpu_observation_model"], expected_model);
        assert_eq!(header["cpu_interpolation"], "none");

        let observations: Vec<_> = exported
            .iter()
            .filter(|value| value["kind"] == "decoded-observation")
            .collect();
        assert_eq!(observations.len(), 201);
        let cpu_readings = observations
            .iter()
            .filter_map(|observation| observation["processes"][0]["cpu"].as_object())
            .count();
        assert!(cpu_readings < observations.len());
        assert_eq!(
            observations
                .iter()
                .filter(|observation| observation["processes"][0]["cpu"].is_null())
                .count(),
            observations.len() - cpu_readings
        );

        let baseline = observations[0];
        assert_eq!(baseline["seq"], 0);
        assert_eq!(
            baseline["processes"][0]["cpu"]["interval"],
            serde_json::Value::Null
        );
        let burst = observations[1];
        assert_eq!(burst["seq"], 1);
        let interval = &burst["processes"][0]["cpu"]["interval"];
        assert_eq!(interval["start_seq"], 0);
        assert_eq!(interval["start_time_ns"], 0);
        assert_eq!(interval["end_time_ns"], STEP_NS);
        assert_eq!(interval["duration_ns"], STEP_NS);
        let decoded_delta = interval["delta_native_ticks"].as_u64().unwrap();
        let error_bound = interval["error_bound_native_ticks"].as_u64().unwrap();
        assert!(
            decoded_delta.abs_diff(BURST_TICKS) <= error_bound,
            "interval delta {decoded_delta} differs from source {BURST_TICKS} by more than {error_bound}"
        );

        for (seq, observation) in observations.iter().enumerate() {
            assert_eq!(observation["seq"], seq as u64);
            assert_eq!(observation["scan_start_ns"], seq as u64 * STEP_NS);
            assert_eq!(observation["scan_end_ns"], seq as u64 * STEP_NS + 10);
            assert_eq!(observation["processes"][0]["rss_bytes"], 2 * 262_144);
            assert_eq!(observation["processes"][0]["owned_bytes"], 12_300);
            assert_eq!(observation["processes"][0]["peak_bytes"], 45_600);
            assert_eq!(observation["processes"][0]["evicted_bytes"], 78_900);
        }

        let summary_output = Command::new(env!("CARGO_BIN_EXE_pane-load"))
            .args(["recording", "inspect", "--input"])
            .arg(&archive)
            .output()
            .unwrap();
        assert!(summary_output.status.success());
        let summary: serde_json::Value = serde_json::from_slice(&summary_output.stdout).unwrap();
        assert_eq!(
            summary["cpu_checkpoints"],
            transform_stats["cpu_checkpoints"]
        );
        assert_eq!(summary["cpu_intervals"], transform_stats["cpu_intervals"]);
        assert_eq!(
            summary["cpu_omitted_readings"],
            transform_stats["cpu_omitted_readings"]
        );
        assert_eq!(
            summary["max_cpu_interval_ns"],
            transform_stats["max_cpu_interval_ns"]
        );
        assert!(summary["max_cpu_interval_ns"].as_u64().unwrap() >= STEP_NS);
    }

    let bench_output = temp.path("temporal-bench.jsonl");
    let benchmark = Command::new(env!("CARGO_BIN_EXE_pane-load"))
        .args(["recording", "bench", "--input"])
        .arg(&source)
        .args(["--profiles", "adaptive-inverse,adaptive-log", "--output"])
        .arg(&bench_output)
        .output()
        .unwrap();
    assert!(
        benchmark.status.success(),
        "new bench profile names rejected: {}",
        String::from_utf8_lossy(&benchmark.stderr)
    );
    let results: Vec<serde_json::Value> = fs::read_to_string(bench_output)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(results.len(), 2);
    assert_eq!(results[0]["profile"], "AdaptiveInverse");
    assert_eq!(results[1]["profile"], "AdaptiveLog");
}
