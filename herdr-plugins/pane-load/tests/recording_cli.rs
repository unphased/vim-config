use herdr_pane_load::recording::pipeline;
use herdr_pane_load::recording::source::RawWriter;
use herdr_pane_load::recording::store;
use herdr_pane_load::recording::{
    Context, LiveMessage, Observation, OutputFormat, Process, Profile, RecordOptions, Timebase,
};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
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
    assert_eq!(options.hz, 10);
    assert_eq!(options.block_rows, 300);
    assert_eq!(options.frame_bytes, 16 * 1024 * 1024);
    assert_eq!(options.max_bytes, 8 * 1024 * 1024 * 1024);
    assert_eq!(options.min_free_bytes, 20 * 1024 * 1024 * 1024);
    assert_eq!(options.format, OutputFormat::Binary);
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
    let replay_blocks = store::read_archive(&replay_root.join("archive")).unwrap();
    assert_eq!(live_blocks, replay_blocks);
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
    assert_eq!(checked["source_sha256"], sha256(&source_bytes));
    assert_eq!(checked["scans"], 2);
    assert_eq!(checked["seq_range"][0], 10);
    assert_eq!(checked["seq_range"][1], 11);
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
    assert!(
        events
            .iter()
            .all(|v| v["unavailable_rate"] == true && v["restart"] == "not_restart")
    );
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
    fs::write(oversized.join("prior-run-data"), vec![0u8; 4096]).unwrap();
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
    assert!(run.join("partial.json").is_file());
    assert_eq!(store::read_archive(&run.join("archive")).unwrap().len(), 1);

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
    assert!(result.is_err());
    assert!(!output.join("complete.json").exists());
    assert!(output.join("partial.json").is_file());
    let inspect = herdr_pane_load::recording::cli::run(&[
        "inspect".into(),
        "--input".into(),
        output.to_string_lossy().into_owned(),
        "--jsonl".into(),
    ]);
    assert!(inspect.unwrap_err().contains("partial recording"));
}
