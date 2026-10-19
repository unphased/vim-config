use herdr_pane_load::recording::{
    Context, Observation, OutputFormat, Process, Profile, Timebase, pipeline, source::RawWriter,
    store,
};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);

impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "recording-bulk-{}-{}",
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

fn process(user: u64, system: u64) -> Process {
    Process {
        pid: 42,
        ppid: 1,
        start_sec: 10,
        start_usec: 20,
        name: "fixture λ".into(),
        user,
        system,
        rss: 999_936,
    }
}

fn row(seq: u64, processes: Vec<Process>) -> Observation {
    row_at(seq, seq * 100_000_000 + 10, processes)
}

fn row_at(seq: u64, scan_start_ns: u64, processes: Vec<Process>) -> Observation {
    Observation {
        seq,
        wall_start_ns: 1_700_000_000_000_000_000 + seq as i64 * 100_000_000,
        scan_start_ns,
        scan_end_ns: scan_start_ns + 10,
        processes,
        quality: vec![],
    }
}

fn context(segment: usize, same_context: bool) -> Context {
    let mut context = Context::new(Timebase {
        numer: 125,
        denom: 3,
    });
    context.capture_run_id = Some("bulk-fixture".into());
    if !same_context {
        context.source_headers.push(json!({"segment":segment}));
    }
    context
}

fn write_sources(
    temp: &Temp,
    directory: &str,
    sources: Vec<Vec<Observation>>,
    same_context: bool,
) -> Vec<PathBuf> {
    let source_dir = temp.path(directory);
    fs::create_dir(&source_dir).unwrap();
    sources
        .into_iter()
        .enumerate()
        .map(|(index, rows)| {
            let path = source_dir.join(format!("source-{index:06}.jsonl.zst"));
            let mut writer = RawWriter::create(&path, &context(index, same_context)).unwrap();
            for row in rows {
                writer.write(&row).unwrap();
            }
            writer.finish().unwrap();
            path
        })
        .collect()
}

fn record_options(
    output: PathBuf,
    profile: Profile,
    block_rows: usize,
) -> herdr_pane_load::recording::RecordOptions {
    let mut options = pipeline::default_record_options(output);
    options.min_free_bytes = 0;
    options.max_bytes = 64 * 1024 * 1024;
    options.profile = profile;
    options.format = OutputFormat::Binary;
    options.block_rows = block_rows;
    options.verify = true;
    options
}

fn assert_stats_and_archive_match(
    inputs: &[PathBuf],
    serial: &pipeline::RunStats,
    serial_output: &Path,
    parallel: &pipeline::RunStats,
    parallel_output: &Path,
) {
    assert_eq!(serial.complete, parallel.complete);
    assert_eq!(serial.scans, parallel.scans);
    assert_eq!(serial.readings, parallel.readings);
    assert_eq!(serial.blocks, parallel.blocks);
    assert_eq!(serial.flagged_events, parallel.flagged_events);
    assert_eq!(serial.raw_encoded_bytes, parallel.raw_encoded_bytes);
    assert_eq!(
        serde_json::to_value(&serial.source_hashes).unwrap(),
        serde_json::to_value(&parallel.source_hashes).unwrap(),
        "ordered source hash metadata differs for inputs {inputs:?}"
    );
    assert_eq!(
        fs::read(serial_output.join("archive/archive.json")).unwrap(),
        fs::read(parallel_output.join("archive/archive.json")).unwrap(),
        "archive metadata differs"
    );
    assert_eq!(
        store::read_archive(&serial_output.join("archive")).unwrap(),
        store::read_archive(&parallel_output.join("archive")).unwrap(),
        "ordered encoded block bytes differ"
    );
}

/// The three worker counts intentionally include more workers than inputs in several callers.
fn run_parity(temp: &Temp, inputs: &[PathBuf], block_rows: usize) -> pipeline::RunStats {
    run_parity_for_profiles(
        temp,
        inputs,
        block_rows,
        &[Profile::Legacy1ms, Profile::Adaptive],
    )
}

fn run_adaptive_parity(temp: &Temp, inputs: &[PathBuf], block_rows: usize) -> pipeline::RunStats {
    run_parity_for_profiles(temp, inputs, block_rows, &[Profile::Adaptive])
}

fn run_parity_for_profiles(
    temp: &Temp,
    inputs: &[PathBuf],
    block_rows: usize,
    profiles: &[Profile],
) -> pipeline::RunStats {
    let mut adaptive_stats = None;
    for profile in profiles {
        let serial_output = temp.path(&format!("serial-{profile:?}"));
        let serial_options = record_options(serial_output.clone(), *profile, block_rows);
        let serial =
            pipeline::transform_sources(inputs, &serial_output, &serial_options, None).unwrap();

        for workers in [1, 2, 4] {
            let parallel_output = temp.path(&format!("parallel-{profile:?}-{workers}"));
            let parallel_options = record_options(parallel_output.clone(), *profile, block_rows);
            let parallel = pipeline::transform_sources_with_workers(
                inputs,
                &parallel_output,
                &parallel_options,
                None,
                workers,
            )
            .unwrap();
            assert_stats_and_archive_match(
                inputs,
                &serial,
                &serial_output,
                &parallel,
                &parallel_output,
            );
        }

        if *profile == Profile::Adaptive {
            adaptive_stats = Some(serial);
        }
    }
    adaptive_stats.unwrap()
}

fn run_all_empty_parity(temp: &Temp, inputs: &[PathBuf]) -> Option<pipeline::RunStats> {
    let serial_output = temp.path("serial-Adaptive");
    let serial_options = record_options(serial_output.clone(), Profile::Adaptive, 3);
    let serial = pipeline::transform_sources(inputs, &serial_output, &serial_options, None);
    match serial {
        Ok(serial) => {
            for workers in [1, 2, 4] {
                let output = temp.path(&format!("parallel-Adaptive-{workers}"));
                let options = record_options(output.clone(), Profile::Adaptive, 3);
                let parallel = pipeline::transform_sources_with_workers(
                    inputs, &output, &options, None, workers,
                )
                .unwrap();
                assert_stats_and_archive_match(inputs, &serial, &serial_output, &parallel, &output);
            }
            Some(serial)
        }
        Err(serial_error) => {
            for workers in [1, 2, 4] {
                let output = temp.path(&format!("parallel-Adaptive-{workers}"));
                let options = record_options(output, Profile::Adaptive, 3);
                let error = pipeline::transform_sources_with_workers(
                    inputs,
                    &options.output,
                    &options,
                    None,
                    workers,
                )
                .unwrap_err();
                assert_eq!(error, serial_error, "workers={workers}");
            }
            None
        }
    }
}

fn decoded_rows(output: &Path) -> Vec<herdr_pane_load::recording::DecodedObservation> {
    store::read_archive(&output.join("archive"))
        .unwrap()
        .into_iter()
        .flat_map(|bytes| {
            herdr_pane_load::recording::decode_block(&bytes)
                .unwrap()
                .rows
        })
        .collect()
}

#[test]
fn parallel_matches_serial_for_late_cross_shard_system_regression_and_gap() {
    let temp = Temp::new();
    // The system counter falls at seq 3 while the combined total still grows.
    let inputs = write_sources(
        &temp,
        "late-regression-sources",
        vec![
            vec![
                row(0, vec![process(100, 200)]),
                row(1, vec![process(110, 220)]),
            ],
            vec![row(2, vec![])],
            vec![row(3, vec![])],
            vec![row(4, vec![process(130, 210)])],
            vec![row(5, vec![process(150, 250)])],
        ],
        false,
    );
    run_parity(&temp, &inputs, 3);
}

#[test]
fn identical_context_keeps_partial_blocks_across_five_physical_files() {
    let temp = Temp::new();
    let inputs = write_sources(
        &temp,
        "five-context-sources",
        (0..5)
            .map(|seq| vec![row(seq, vec![process(100 + seq, 200 + seq)])])
            .collect(),
        true,
    );
    let stats = run_parity(&temp, &inputs, 3);
    assert_eq!(
        stats.blocks, 2,
        "same-context file boundaries must not cut blocks"
    );
}

#[test]
fn reset_for_absent_identity_clears_cross_shard_state() {
    let temp = Temp::new();
    let mut reset = row(1, vec![]);
    reset.quality.push(json!({
        "kind":"cpu-continuity-unknown",
        "identity":{"pid":42,"start_sec":10,"start_usec":20},
        "seq":1,"unavailable_rate":true
    }));
    let inputs = write_sources(
        &temp,
        "absent-reset-sources",
        vec![
            vec![row(0, vec![process(100, 200)])],
            vec![reset],
            vec![row(2, vec![process(10, 20)])],
        ],
        false,
    );
    run_parity(&temp, &inputs, 3);
}

// Literal source evidence keeps the expected event independent of production helpers.
#[allow(clippy::too_many_arguments)]
fn regression_event(
    component: &str,
    before_seq: u64,
    before_stamp: u64,
    before_user: u64,
    before_system: u64,
    after_seq: u64,
    after_stamp: u64,
    after_user: u64,
    after_system: u64,
) -> Value {
    let identity = json!({"pid":42,"start_sec":10,"start_usec":20});
    json!({
        "kind":"cpu-component-regression",
        "component":component,
        "identity":identity,
        "before":{
            "identity":identity,"seq":before_seq,"scan_start_ns":before_stamp,
            "cpu_unit":"native_ticks","user":before_user,"system":before_system
        },
        "after":{
            "identity":identity,"seq":after_seq,"scan_start_ns":after_stamp,
            "cpu_unit":"native_ticks","user":after_user,"system":after_system
        },
        "unavailable_rate":true,
        "restart_inference":"unknown; counter decrease is not proof of process restart"
    })
}

#[test]
fn same_point_component_regressions_preserve_payload_and_deduplicate_existing_quality() {
    let temp = Temp::new();
    let first = row(0, vec![process(100, 200)]);
    let mut changed = process(90, 190);
    changed.ppid = 88;
    changed.name = "renommé 雨 ☃".into();
    changed.rss = 2 * 262_144;
    let mut second = row(1, vec![changed]);
    second.quality.push(regression_event(
        "user",
        0,
        first.scan_start_ns,
        100,
        200,
        1,
        second.scan_start_ns,
        90,
        190,
    ));
    let inputs = write_sources(
        &temp,
        "component-sources",
        vec![vec![first], vec![second]],
        true,
    );
    let stats = run_adaptive_parity(&temp, &inputs, 3);
    assert_eq!(stats.flagged_events, 2);

    let rows = decoded_rows(&temp.path("serial-Adaptive"));
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[1].quality.len(), 2);
    assert_eq!(rows[1].quality[0]["component"], "user");
    assert_eq!(rows[1].quality[1]["component"], "system");
    assert_eq!(rows[1].quality[0]["before"]["seq"], 0);
    assert_eq!(rows[1].quality[1]["before"]["seq"], 0);
    assert_eq!(rows[1].processes[0].name, "renommé 雨 ☃");
    assert_eq!(rows[1].processes[0].ppid, 88);
    assert_eq!(rows[1].processes[0].rss, 2 * 262_144);
}

#[test]
fn absent_reset_before_late_first_touch_does_not_seed_a_future_counter() {
    let temp = Temp::new();
    let mut reset = row(0, vec![]);
    reset.quality.push(json!({
        "kind":"cpu-continuity-unknown",
        "identity":{"pid":42,"start_sec":10,"start_usec":20},
        "seq":0,"unavailable_rate":true
    }));
    let inputs = write_sources(
        &temp,
        "late-first-touch-sources",
        vec![
            vec![reset],
            vec![],
            vec![row(1, vec![process(100, 200)])],
            vec![row(2, vec![process(10, 220)])],
        ],
        true,
    );
    let stats = run_adaptive_parity(&temp, &inputs, 3);
    assert_eq!(stats.flagged_events, 2);

    let rows = decoded_rows(&temp.path("serial-Adaptive"));
    assert_eq!(
        rows[1].quality.len(),
        0,
        "first appearance is a baseline, not a regression"
    );
    assert_eq!(rows[2].quality.len(), 1);
    assert_eq!(rows[2].quality[0]["component"], "user");
    assert_eq!(rows[2].quality[0]["before"]["seq"], 1);
    assert_eq!(rows[2].quality[0]["before"]["user"], 100);
    assert_eq!(rows[2].quality[0]["after"]["user"], 10);
    assert_eq!(rows[2].quality[0]["after"]["system"], 220);
}

#[test]
fn empty_first_middle_last_and_all_sources_match_serial() {
    let temp = Temp::new();
    let inputs = write_sources(
        &temp,
        "sparse-sources",
        vec![
            vec![],
            vec![row(0, vec![process(10, 20)])],
            vec![],
            vec![row(1, vec![process(20, 30)])],
            vec![],
        ],
        true,
    );
    assert_eq!(run_adaptive_parity(&temp, &inputs, 3).scans, 2);

    let all_empty_temp = Temp::new();
    let all_empty = write_sources(
        &all_empty_temp,
        "all-empty-sources",
        vec![vec![], vec![], vec![]],
        true,
    );
    if let Some(stats) = run_all_empty_parity(&all_empty_temp, &all_empty) {
        assert_eq!(stats.scans, 0);
        assert_eq!(stats.readings, 0);
        assert_eq!(stats.blocks, 0);
    }
}

#[test]
fn larger_first_shard_does_not_reorder_global_output() {
    let temp = Temp::new();
    let mut first = Vec::new();
    for seq in 0..300 {
        let mut observation = row(seq, vec![process(seq + 1, seq + 2)]);
        observation.scan_start_ns = seq * 10_000_000 + 10;
        observation.scan_end_ns = observation.scan_start_ns + 10;
        first.push(observation);
    }
    let mut sources = vec![first];
    for seq in 300..304 {
        let mut observation = row(seq, vec![process(seq + 1, seq + 2)]);
        observation.scan_start_ns = seq * 10_000_000 + 10;
        observation.scan_end_ns = observation.scan_start_ns + 10;
        sources.push(vec![observation]);
    }
    let inputs = write_sources(&temp, "uneven-sources", sources, false);
    let stats = run_adaptive_parity(&temp, &inputs, 400);
    assert_eq!(stats.scans, 304);
    assert_eq!(
        stats.blocks, 5,
        "distinct source contexts retain their cuts"
    );
    let output = temp.path("uneven-active-workers");
    let options = record_options(output.clone(), Profile::Adaptive, 400);
    let parallel =
        pipeline::transform_sources_with_workers(&inputs, &output, &options, None, 4).unwrap();
    assert_eq!(parallel.encoding_workers, Some(4));
    assert_eq!(parallel.bulk_workers, Some(4));
}

fn write_private_json(path: &Path, value: &Value) {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .unwrap();
    serde_json::to_writer(&mut file, value).unwrap();
}

#[test]
fn late_source_crc_failure_never_publishes_complete_for_any_upstream_status() {
    for upstream in ["absent", "complete", "partial"] {
        let temp = Temp::new();
        let input_dir = temp.path(&format!("crc-input-{upstream}"));
        fs::create_dir(&input_dir).unwrap();
        if upstream == "complete" {
            write_private_json(
                &input_dir.join("complete.json"),
                &json!({"kind":"live-native","complete":true,"end_quality":[]}),
            );
        } else if upstream == "partial" {
            write_private_json(
                &input_dir.join("partial.json"),
                &json!({"kind":"live-native","complete":false,"end_quality":[],"end_reason":"fixture ended early"}),
            );
        }
        let first_path = input_dir.join("input-000.jsonl.zst");
        let mut writer = RawWriter::create(&first_path, &context(0, true)).unwrap();
        writer.write(&row(0, vec![process(10, 20)])).unwrap();
        writer.write(&row(1, vec![process(20, 30)])).unwrap();
        writer.finish().unwrap();
        let corrupt_path = input_dir.join("input-001.jsonl.zst");
        let mut writer = RawWriter::create(&corrupt_path, &context(0, true)).unwrap();
        writer.write(&row(2, vec![process(30, 40)])).unwrap();
        writer.finish().unwrap();
        let mut bytes = fs::read(&corrupt_path).unwrap();
        let last = bytes.last_mut().unwrap();
        *last ^= 1;
        fs::write(&corrupt_path, bytes).unwrap();
        let inputs = vec![first_path, corrupt_path];

        for (label, workers) in [("serial", None), ("parallel", Some(4))] {
            let output = temp.path(&format!("crc-output-{upstream}-{label}"));
            let options = record_options(output.clone(), Profile::Adaptive, 3);
            let error = match workers {
                None => pipeline::transform_sources(&inputs, &output, &options, None).unwrap_err(),
                Some(workers) => pipeline::transform_sources_with_workers(
                    &inputs, &output, &options, None, workers,
                )
                .unwrap_err(),
            };
            assert!(
                error.to_lowercase().contains("zstd") || error.to_lowercase().contains("checksum"),
                "unexpected CRC failure for {upstream}: {error}"
            );
            assert!(!output.join("complete.json").exists());
            let partial: Value =
                serde_json::from_slice(&fs::read(output.join("partial.json")).unwrap()).unwrap();
            assert_eq!(partial["complete"], false);
        }
    }
}

#[test]
fn cross_file_duplicate_sequences_and_out_of_order_clocks_are_rejected() {
    let temp = Temp::new();
    let duplicate_seq = write_sources(
        &temp,
        "duplicate-seq-sources",
        vec![
            vec![row_at(4, 10, vec![])],
            vec![row_at(4, 20, vec![])],
            vec![row_at(5, 30, vec![])],
        ],
        true,
    );
    let out_of_order_seq = write_sources(
        &temp,
        "out-of-order-seq-sources",
        vec![
            vec![row_at(4, 10, vec![])],
            vec![row_at(3, 20, vec![])],
            vec![row_at(5, 30, vec![])],
        ],
        true,
    );
    let backwards_clock = write_sources(
        &temp,
        "backwards-clock-sources",
        vec![
            vec![row_at(0, 10, vec![])],
            vec![row_at(1, 20, vec![])],
            vec![row_at(2, 15, vec![])],
        ],
        true,
    );
    for (name, inputs, expected) in [
        (
            "duplicate-seq",
            duplicate_seq,
            "global observation sequence is not strictly increasing",
        ),
        (
            "out-of-order-seq",
            out_of_order_seq,
            "global observation sequence is not strictly increasing",
        ),
        (
            "backwards-clock",
            backwards_clock,
            "global scan clock is not strictly increasing",
        ),
    ] {
        let serial_output = temp.path(&format!("{name}-serial"));
        let serial_options = record_options(serial_output.clone(), Profile::Adaptive, 3);
        let serial_error =
            pipeline::transform_sources(&inputs, &serial_output, &serial_options, None)
                .unwrap_err();
        assert!(serial_error.contains(expected), "{serial_error}");
        for workers in [1, 2, 4] {
            let output = temp.path(&format!("{name}-workers-{workers}"));
            let options = record_options(output.clone(), Profile::Adaptive, 3);
            let error =
                pipeline::transform_sources_with_workers(&inputs, &output, &options, None, workers)
                    .unwrap_err();
            assert!(error.contains(expected), "workers={workers}: {error}");
        }
    }
}

#[test]
fn workers_zero_is_rejected_and_cli_accepts_auto_but_record_does_not_accept_workers() {
    use herdr_pane_load::recording::cli::{parse_record_options, run};

    let temp = Temp::new();
    let inputs = write_sources(
        &temp,
        "cli-sources",
        vec![
            vec![row(0, vec![process(10, 20)])],
            vec![row(1, vec![process(20, 30)])],
        ],
        true,
    );
    let zero_output = temp.path("api-zero-workers");
    let zero_options = record_options(zero_output.clone(), Profile::Adaptive, 3);
    let error =
        pipeline::transform_sources_with_workers(&inputs, &zero_output, &zero_options, None, 0)
            .unwrap_err();
    assert!(error.to_lowercase().contains("worker"));

    let input_directory = inputs[0].parent().unwrap();
    let serial = temp.path("cli-serial");
    let serial_options = record_options(serial.clone(), Profile::Adaptive, 3);
    pipeline::transform_sources(&inputs, &serial, &serial_options, None).unwrap();
    for (name, worker_arg) in [
        ("default", None),
        ("auto", Some("auto")),
        ("two", Some("2")),
    ] {
        let output = temp.path(&format!("cli-{name}"));
        let mut args = vec![
            "transform".into(),
            "--input".into(),
            input_directory.to_string_lossy().into_owned(),
            "--output".into(),
            output.to_string_lossy().into_owned(),
            "--min-free-bytes".into(),
            "0".into(),
            "--max-bytes".into(),
            "67108864".into(),
        ];
        if let Some(worker_arg) = worker_arg {
            args.extend(["--workers".into(), worker_arg.into()]);
        }
        run(&args).unwrap();
        assert_eq!(
            fs::read(serial.join("archive/archive.json")).unwrap(),
            fs::read(output.join("archive/archive.json")).unwrap()
        );
        assert_eq!(
            store::read_archive(&serial.join("archive")).unwrap(),
            store::read_archive(&output.join("archive")).unwrap()
        );
    }

    for (label, worker_arg) in [("zero", "0"), ("malformed", "many")] {
        let output = temp.path(&format!("cli-invalid-{label}"));
        let error = run(&[
            "transform".into(),
            "--input".into(),
            input_directory.to_string_lossy().into_owned(),
            "--output".into(),
            output.to_string_lossy().into_owned(),
            "--min-free-bytes".into(),
            "0".into(),
            "--max-bytes".into(),
            "67108864".into(),
            "--workers".into(),
            worker_arg.into(),
        ])
        .unwrap_err();
        assert!(error.to_lowercase().contains("worker"), "{error}");
        assert!(!output.exists());
    }

    let record_error = parse_record_options(&[
        "--output".into(),
        temp.path("record-output").to_string_lossy().into_owned(),
        "--workers".into(),
        "2".into(),
    ])
    .unwrap_err();
    assert!(record_error.contains("unknown"));
}
