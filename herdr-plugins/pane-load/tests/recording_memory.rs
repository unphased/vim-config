use herdr_pane_load::recording::cli::parse_record_options;
use herdr_pane_load::recording::source::{self, RawWriter};
use herdr_pane_load::recording::wire::encode_block_with_memory;
use herdr_pane_load::recording::{
    Context, MemoryColumn, MemoryEncoding, Observation, Process, Profile, Timebase, decode_block,
    encode_block,
};
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

const UNIT: u64 = 100;
static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "pane-load-memory-tests-{}-{}",
            std::process::id(),
            NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
        ));
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
    context.capture_run_id = Some("memory-fixture".into());
    context.boot_id = Some("boot-fixture".into());
    context.clock = "mach_continuous_time".into();
    context
}

fn process(
    pid: u32,
    start_sec: u64,
    start_usec: u32,
    name: &str,
    owned: Option<u64>,
    peak: Option<u64>,
    evicted: Option<u64>,
) -> Process {
    Process {
        pid,
        ppid: 1,
        start_sec,
        start_usec,
        name: name.into(),
        user: 100 + u64::from(pid),
        system: 20,
        rss: 900_000 + u64::from(pid),
        owned,
        peak,
        evicted,
    }
}

fn row(seq: u64, processes: Vec<Process>) -> Observation {
    let scan_start_ns = (seq + 1) * 1_000;
    Observation {
        seq,
        wall_start_ns: 1_700_000_000_000_000_000 + seq as i64 * 1_000,
        scan_start_ns,
        scan_end_ns: scan_start_ns + 100,
        processes,
        quality: vec![],
    }
}

fn encoding(columns: Vec<MemoryColumn>, unit_bytes: u64) -> MemoryEncoding {
    MemoryEncoding {
        columns,
        unit_bytes,
    }
}

fn columns_all() -> Vec<MemoryColumn> {
    vec![
        MemoryColumn::Owned,
        MemoryColumn::Peak,
        MemoryColumn::Evicted,
    ]
}

fn rich_rows() -> Vec<Observation> {
    // Deliberately unsorted by pid. Identity A is renamed, disappears and returns;
    // identity B disappears and returns; identity C is new. Peak is below owned at
    // several points and is also present without owned at others.
    vec![
        row(
            0,
            vec![
                process(7, 8, 2, "beta", None, Some(950), Some(599)),
                process(42, 1, 3, "alpha", Some(1_234), Some(999), None),
            ],
        ),
        row(
            1,
            vec![
                process(42, 1, 3, "alpha-renamed", None, Some(777), Some(199)),
                process(99, 30, 4, "new", Some(1_099), None, None),
            ],
        ),
        row(
            2,
            vec![
                process(99, 30, 4, "new", Some(2_099), Some(1_901), Some(299)),
                process(7, 8, 2, "beta", Some(1_899), Some(2_599), None),
            ],
        ),
        row(
            3,
            vec![
                process(
                    42,
                    1,
                    3,
                    "alpha-returned",
                    Some(2_599),
                    Some(3_001),
                    Some(399),
                ),
                process(7, 8, 2, "beta", None, None, None),
            ],
        ),
    ]
}

fn decoded_process(
    row: &herdr_pane_load::recording::DecodedObservation,
    pid: u32,
) -> &herdr_pane_load::recording::DecodedProcess {
    row.processes
        .iter()
        .find(|process| process.pid == pid)
        .unwrap()
}

#[test]
fn pst2_none_and_selected_without_values_are_byte_identical() {
    let context = context();
    let rows = vec![
        row(0, vec![process(42, 1, 2, "none", None, None, None)]),
        row(1, vec![]),
    ];
    let compatibility = encode_block(&context, &rows, Profile::Adaptive).unwrap();
    let none =
        encode_block_with_memory(&context, &rows, Profile::Adaptive, MemoryEncoding::NONE).unwrap();
    let selected_but_empty = encode_block_with_memory(
        &context,
        &rows,
        Profile::Adaptive,
        MemoryEncoding::default(),
    )
    .unwrap();

    assert_eq!(none, compatibility);
    assert_eq!(selected_but_empty, compatibility);
    let decoded = decode_block(&compatibility).unwrap();
    assert_eq!(decoded.memory, None);
    assert!(decoded.rows[0].processes[0].owned.is_none());
    assert!(decoded.rows[0].processes[0].peak.is_none());
    assert!(decoded.rows[0].processes[0].evicted.is_none());
}

#[test]
fn pst1_ignores_memory_values_and_remains_byte_identical() {
    let context = context();
    let without_memory = vec![row(0, vec![process(42, 1, 2, "compat", None, None, None)])];
    let with_memory = vec![row(
        0,
        vec![process(
            42,
            1,
            2,
            "compat",
            Some(12_345),
            Some(54_321),
            Some(6_789),
        )],
    )];
    let old_bytes = encode_block(&context, &without_memory, Profile::Legacy1ms).unwrap();
    let selected = encode_block_with_memory(
        &context,
        &with_memory,
        Profile::Legacy1ms,
        encoding(columns_all(), UNIT),
    )
    .unwrap();

    assert_eq!(selected, old_bytes);
    let decoded = decode_block(&selected).unwrap();
    assert_eq!(decoded.memory, None);
    let point = &decoded.rows[0].processes[0];
    assert_eq!((point.owned, point.peak, point.evicted), (None, None, None));
}

#[test]
fn pst2_roundtrips_identity_changes_optional_values_and_flooring_for_every_subset() {
    let context = context();
    let rows = rich_rows();
    let all = columns_all();

    for mask in 0_u8..8 {
        let selected: Vec<_> = all
            .iter()
            .enumerate()
            .filter_map(|(index, column)| ((mask & (1 << index)) != 0).then_some(*column))
            .collect();
        let encoded = encode_block_with_memory(
            &context,
            &rows,
            Profile::Adaptive,
            encoding(selected.clone(), UNIT),
        )
        .unwrap();
        let decoded = decode_block(&encoded).unwrap();
        let expected_memory = (!selected.is_empty()).then(|| encoding(selected.clone(), UNIT));
        assert_eq!(decoded.memory, expected_memory, "selection mask {mask:03b}");
        assert_eq!(decoded.rows.len(), 4);

        // PSD1's identity ordering is independent of the deliberately unsorted input.
        assert_eq!(decoded.rows[0].processes[0].pid, 7);
        assert_eq!(decoded.rows[0].processes[1].pid, 42);
        assert_eq!(decoded_process(&decoded.rows[1], 42).name, "alpha-renamed");
        assert!(!decoded.rows[1].processes.iter().any(|point| point.pid == 7));
        assert_eq!(decoded_process(&decoded.rows[2], 7).name, "beta");
        assert_eq!(decoded_process(&decoded.rows[3], 42).name, "alpha-returned");

        let a0 = decoded_process(&decoded.rows[0], 42);
        assert_eq!(
            a0.owned,
            selected.contains(&MemoryColumn::Owned).then_some(1_200)
        );
        // peak is encoded as signed excess over owned; a negative excess must roundtrip.
        assert_eq!(
            a0.peak,
            selected.contains(&MemoryColumn::Peak).then_some(900)
        );
        assert_eq!(a0.evicted, None);

        let b0 = decoded_process(&decoded.rows[0], 7);
        assert_eq!(b0.owned, None);
        assert_eq!(
            b0.peak,
            selected.contains(&MemoryColumn::Peak).then_some(900)
        );
        assert_eq!(
            b0.evicted,
            selected.contains(&MemoryColumn::Evicted).then_some(500)
        );

        let a1 = decoded_process(&decoded.rows[1], 42);
        assert_eq!(a1.owned, None);
        assert_eq!(
            a1.peak,
            selected.contains(&MemoryColumn::Peak).then_some(700)
        );
        assert_eq!(
            a1.evicted,
            selected.contains(&MemoryColumn::Evicted).then_some(100)
        );
        let c1 = decoded_process(&decoded.rows[1], 99);
        assert_eq!(
            c1.owned,
            selected.contains(&MemoryColumn::Owned).then_some(1_000)
        );
        assert_eq!(c1.peak, None);

        let b2 = decoded_process(&decoded.rows[2], 7);
        assert_eq!(
            b2.owned,
            selected.contains(&MemoryColumn::Owned).then_some(1_800)
        );
        assert_eq!(
            b2.peak,
            selected.contains(&MemoryColumn::Peak).then_some(2_500)
        );
        assert_eq!(b2.evicted, None);
        let c2 = decoded_process(&decoded.rows[2], 99);
        assert_eq!(
            c2.owned,
            selected.contains(&MemoryColumn::Owned).then_some(2_000)
        );
        assert_eq!(
            c2.peak,
            selected.contains(&MemoryColumn::Peak).then_some(1_900)
        );
        assert_eq!(
            c2.evicted,
            selected.contains(&MemoryColumn::Evicted).then_some(200)
        );

        let a3 = decoded_process(&decoded.rows[3], 42);
        assert_eq!(
            a3.owned,
            selected.contains(&MemoryColumn::Owned).then_some(2_500)
        );
        assert_eq!(
            a3.peak,
            selected.contains(&MemoryColumn::Peak).then_some(3_000)
        );
        assert_eq!(
            a3.evicted,
            selected.contains(&MemoryColumn::Evicted).then_some(300)
        );
    }
}

#[test]
fn memory_columns_are_declared_in_canonical_order_and_omit_unavailable_columns() {
    let context = context();
    let rows = vec![row(
        0,
        vec![process(42, 1, 2, "only peak", None, Some(400), None)],
    )];
    let encoded = encode_block_with_memory(
        &context,
        &rows,
        Profile::Adaptive,
        encoding(columns_all(), UNIT),
    )
    .unwrap();
    let sections = unpack_sections(&encoded);
    let header: Value = serde_json::from_slice(&sections.sections[0]).unwrap();
    assert_eq!(
        header["memory"],
        json!({"columns":["peak"],"unit_bytes":UNIT})
    );
    assert_eq!(sections.sections.len(), 4);
    assert_eq!(&sections.sections[3][..4], b"PMM1");

    let decoded = decode_block(&encoded).unwrap();
    assert_eq!(
        decoded.memory,
        Some(encoding(vec![MemoryColumn::Peak], UNIT))
    );
    assert_eq!(decoded.rows[0].processes[0].owned, None);
    assert_eq!(decoded.rows[0].processes[0].peak, Some(400));

    let all_columns = encode_block_with_memory(
        &context,
        &[row(
            0,
            vec![process(42, 1, 2, "all", Some(100), Some(200), Some(300))],
        )],
        Profile::Adaptive,
        encoding(columns_all(), UNIT),
    )
    .unwrap();
    let sections = unpack_sections(&all_columns);
    let header: Value = serde_json::from_slice(&sections.sections[0]).unwrap();
    assert_eq!(
        header["memory"]["columns"],
        json!(["owned", "peak", "evicted"])
    );
}

#[test]
fn raw_source_roundtrips_eight_and_eleven_field_process_tuples() {
    let temp = TempDir::new();
    let context = context();
    let no_memory = row(0, vec![process(42, 1, 2, "plain", None, None, None)]);
    let with_memory = row(
        1,
        vec![
            process(7, 3, 4, "partial", None, Some(10_999), None),
            process(42, 1, 2, "full", Some(20_123), Some(30_456), Some(40_789)),
        ],
    );

    let plain_path = temp.path("plain.jsonl");
    let mut writer = RawWriter::create(&plain_path, &context).unwrap();
    writer.write(&no_memory).unwrap();
    writer.finish().unwrap();
    let plain_bytes = fs::read(&plain_path).unwrap();
    let plain_lines: Vec<_> = plain_bytes.split(|byte| *byte == b'\n').collect();
    assert_eq!(plain_lines.len(), 3);
    let plain_row: Value = serde_json::from_slice(plain_lines[1]).unwrap();
    assert_eq!(plain_row["processes"][0].as_array().unwrap().len(), 8);
    assert_eq!(
        plain_lines[1],
        br#"{"processes":[[42,1,1,2,"plain",142,20,900042]],"quality":[],"scan_end_ns":1100,"scan_start_ns":1000,"seq":0,"wall_start_ns":1700000000000000000}"#
    );

    let memory_path = temp.path("memory.jsonl");
    let mut writer = RawWriter::create(&memory_path, &context).unwrap();
    writer.write(&no_memory).unwrap();
    writer.write(&with_memory).unwrap();
    writer.finish().unwrap();
    let bytes = fs::read(&memory_path).unwrap();
    let lines: Vec<_> = bytes.split(|byte| *byte == b'\n').collect();
    let first: Value = serde_json::from_slice(lines[1]).unwrap();
    let second: Value = serde_json::from_slice(lines[2]).unwrap();
    assert_eq!(first["processes"][0].as_array().unwrap().len(), 8);
    assert_eq!(second["processes"][0].as_array().unwrap().len(), 11);
    assert_eq!(second["processes"][0][8], Value::Null);
    assert_eq!(second["processes"][0][9], json!(10_999));
    assert_eq!(second["processes"][0][10], Value::Null);
    assert_eq!(second["processes"][1][8], json!(20_123));

    let mut decoded_rows = Vec::new();
    let stats = source::visit_source(&memory_path, None, |_, observation| {
        decoded_rows.push(observation);
        Ok(())
    })
    .unwrap();
    assert_eq!(stats.scans, 2);
    assert_eq!(decoded_rows[0].processes, no_memory.processes);
    assert_eq!(
        decoded_rows[1].processes,
        vec![
            with_memory.processes[0].clone(),
            with_memory.processes[1].clone()
        ]
    );
}

#[test]
fn raw_source_without_memory_keeps_the_recording_source_v1_header() {
    let temp = TempDir::new();
    let path = temp.path("no-memory.jsonl");
    let context = context();
    let row = row(0, vec![process(42, 1, 2, "plain", None, None, None)]);
    let mut writer = RawWriter::create(&path, &context).unwrap();
    writer.write(&row).unwrap();
    writer.finish().unwrap();

    let bytes = fs::read(&path).unwrap();
    let first_line = bytes.split(|byte| *byte == b'\n').next().unwrap();
    let header: Value = serde_json::from_slice(first_line).unwrap();
    assert_eq!(header["recording_source"], 1);
    assert!(header.get("memory").is_none());
    let row_value = source::row_to_value(&row).unwrap();
    assert_eq!(row_value["processes"][0].as_array().unwrap().len(), 8);

    let output = Command::new(env!("CARGO_BIN_EXE_pane-load"))
        .args(["recording", "inspect", "--input"])
        .arg(&path)
        .arg("--jsonl")
        .output()
        .unwrap();
    assert!(output.status.success());
    let exported: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let export_header = exported
        .iter()
        .find(|value| value.get("recording_export").is_some())
        .unwrap();
    assert_eq!(export_header["cpu_unit"], "native_ticks");
    assert_eq!(export_header["cpu_total_only"], false);
    assert_eq!(
        export_header["cpu_components"],
        "raw-user-system-native-ticks"
    );
    let raw_observation = exported
        .iter()
        .find(|value| value["kind"] == "raw-source-observation")
        .unwrap();
    assert_eq!(raw_observation["processes"][0][5], 142);
    assert_eq!(raw_observation["processes"][0][6], 20);
}

#[test]
fn decoded_jsonl_export_includes_memory_bytes_and_the_selected_unit() {
    let temp = TempDir::new();
    let context = context();
    let rows = vec![row(
        0,
        vec![process(
            42,
            1,
            2,
            "export",
            Some(12_345),
            Some(23_456),
            Some(3_456),
        )],
    )];
    let block = encode_block_with_memory(
        &context,
        &rows,
        Profile::Adaptive,
        encoding(columns_all(), UNIT),
    )
    .unwrap();
    let path = temp.path("memory.pst");
    fs::write(&path, block).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_pane-load"))
        .args(["recording", "inspect", "--input"])
        .arg(&path)
        .arg("--jsonl")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "inspect failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let exported: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let header = exported
        .iter()
        .find(|value| value.get("recording_export").is_some())
        .unwrap();
    assert_eq!(header["cpu_unit"], "native_ticks");
    assert_eq!(header["time_unit"], "ns");
    assert_eq!(header["cpu_total_only"], true);
    assert_eq!(
        header["cpu_observation_model"],
        "dense-quantized-checkpoints"
    );
    assert_eq!(header["cpu_interpolation"], "none");
    let observation = exported
        .iter()
        .find(|value| value["kind"] == "decoded-observation")
        .unwrap();
    assert_eq!(observation["memory_unit_bytes"], UNIT);
    let process = &observation["processes"][0];
    assert_eq!(process["cpu"]["total_native_ticks"], 162);
    assert_eq!(process["cpu"]["error_bound_native_ticks"], 0);
    assert_eq!(process["cpu"]["components"], Value::Null);
    assert_eq!(process["cpu"]["interval"], Value::Null);
    assert!(process.get("cpu_total_native_ticks").is_none());
    assert_eq!(process["owned_bytes"], 12_300);
    assert_eq!(process["peak_bytes"], 23_400);
    assert_eq!(process["evicted_bytes"], 3_400);
}

#[test]
fn record_cli_memory_selection_defaults_allows_all_none_and_validates_units() {
    let defaults = parse_record_options(&["--output".into(), "out".into()]).unwrap();
    assert_eq!(defaults.memory, MemoryEncoding::default());
    assert_eq!(defaults.memory.columns, columns_all());
    assert_eq!(defaults.memory.unit_bytes, 262_144);

    let all = parse_record_options(&[
        "--output".into(),
        "out".into(),
        "--memory-columns".into(),
        "owned,peak,evicted".into(),
        "--memory-unit-bytes".into(),
        "4096".into(),
    ])
    .unwrap();
    assert_eq!(all.memory.columns, columns_all());
    assert_eq!(all.memory.unit_bytes, 4096);

    let none = parse_record_options(&[
        "--output".into(),
        "out".into(),
        "--memory-columns".into(),
        "none".into(),
    ])
    .unwrap();
    assert_eq!(none.memory, MemoryEncoding::NONE);

    for unit in ["0", "-1", "not-a-number"] {
        let result = parse_record_options(&[
            "--output".into(),
            "out".into(),
            "--memory-unit-bytes".into(),
            unit.into(),
        ]);
        assert!(result.is_err(), "accepted invalid memory unit {unit}");
    }
    for columns in ["", "none,owned", "owned,owned", "owned,unknown"] {
        let result = parse_record_options(&[
            "--output".into(),
            "out".into(),
            "--memory-columns".into(),
            columns.into(),
        ]);
        assert!(
            result.is_err(),
            "accepted invalid memory columns {columns:?}"
        );
    }
}

#[test]
fn decoder_requires_memory_header_and_fourth_section_as_a_pair() {
    let context = context();
    let rows = vec![row(
        0,
        vec![process(42, 1, 2, "has memory", Some(500), None, None)],
    )];
    let without_memory = encode_block(&context, &rows, Profile::Adaptive).unwrap();
    // A present memory field must be an object, not null masquerading as absence.
    assert!(decode_block(&rewrite_memory_header(&without_memory, Value::Null)).is_err());
    let mut sections = unpack_sections(&without_memory);
    sections.sections.push(b"PMM1".to_vec());
    assert!(decode_block(&pack_sections(&sections, &sections.sections)).is_err());

    let with_memory = encode_block_with_memory(
        &context,
        &rows,
        Profile::Adaptive,
        encoding(vec![MemoryColumn::Owned], UNIT),
    )
    .unwrap();
    let mut sections = unpack_sections(&with_memory);
    sections.sections.pop();
    assert!(decode_block(&pack_sections(&sections, &sections.sections)).is_err());

    let mut sections = unpack_sections(&with_memory);
    sections.sections[3][..4].copy_from_slice(b"BAD!");
    assert!(decode_block(&pack_sections(&sections, &sections.sections)).is_err());
}

#[test]
fn decoder_rejects_unknown_duplicate_and_out_of_order_memory_columns() {
    let context = context();
    let rows = vec![row(
        0,
        vec![process(
            42,
            1,
            2,
            "has memory",
            Some(500),
            Some(600),
            Some(700),
        )],
    )];
    let base = encode_block_with_memory(
        &context,
        &rows,
        Profile::Adaptive,
        encoding(columns_all(), UNIT),
    )
    .unwrap();

    for columns in [
        json!(["owned", "unknown"]),
        json!(["owned", "owned"]),
        json!(["peak", "owned"]),
        json!(["evicted", "peak"]),
    ] {
        let malformed = rewrite_memory_header(&base, json!({"columns":columns,"unit_bytes":UNIT}));
        assert!(
            decode_block(&malformed).is_err(),
            "accepted columns {columns}"
        );
    }

    let malformed = rewrite_memory_header(&base, json!({"columns":["owned"],"unit_bytes":0}));
    assert!(decode_block(&malformed).is_err());
    let malformed = rewrite_memory_header(&base, json!({"columns":"owned","unit_bytes":UNIT}));
    assert!(decode_block(&malformed).is_err());
    let malformed = rewrite_memory_header(&base, json!({"columns":["owned"]}));
    assert!(decode_block(&malformed).is_err());
}

#[test]
fn decoder_rejects_bad_absent_indices_count_mismatch_trailing_data_and_overflow() {
    let context = context();
    let rows = vec![row(
        0,
        vec![process(42, 1, 2, "has memory", Some(500), None, None)],
    )];
    let base = encode_block(&context, &rows, Profile::Adaptive).unwrap();
    let header = json!({"columns":["owned"],"unit_bytes":2});

    // One process exists (index 0), so the first absent index 1 is out of range.
    let malformed = with_memory_section(&base, header.clone(), pmm_column(1, &[1], &[]));
    assert!(decode_block(&malformed).is_err());

    // The declared absent count cannot be satisfied by this one-process row.
    let malformed = with_memory_section(&base, header.clone(), pmm_column(2, &[], &[]));
    assert!(decode_block(&malformed).is_err());

    // Valid counts, but their promised indices / present deltas are truncated.
    for section in [pmm_column(1, &[], &[]), pmm_column(0, &[], &[])] {
        let malformed = with_memory_section(&base, header.clone(), section);
        assert!(decode_block(&malformed).is_err());
    }

    let mut trailing = pmm_column(0, &[], &[2]);
    trailing.push(0);
    let malformed = with_memory_section(&base, header.clone(), trailing);
    assert!(decode_block(&malformed).is_err());

    // The signed delta is a valid u64 unit count, but multiplying by unit_bytes=2 overflows.
    let malformed = with_memory_section(&base, header, pmm_column(0, &[], &[i128::from(u64::MAX)]));
    assert!(decode_block(&malformed).is_err());
}

#[test]
fn cached_binary_bench_rejects_memory_reencoding_options() {
    let temp = TempDir::new();
    let path = temp.path("memory.pst");
    let block = encode_block_with_memory(
        &context(),
        &rich_rows(),
        Profile::Adaptive,
        MemoryEncoding::default(),
    )
    .unwrap();
    fs::write(&path, block).unwrap();
    for flag in ["--memory-columns", "--memory-unit-bytes"] {
        let output = Command::new(env!("CARGO_BIN_EXE_pane-load"))
            .args(["recording", "bench", "--input"])
            .arg(&path)
            .args([
                "--profiles",
                "adaptive",
                flag,
                if flag == "--memory-columns" {
                    "none"
                } else {
                    "1"
                },
                "--output",
            ])
            .arg(temp.path("bench.jsonl"))
            .output()
            .unwrap();
        assert!(!output.status.success(), "silently ignored {flag}");
        assert!(String::from_utf8_lossy(&output.stderr).contains("raw source"));
    }
}

fn rewrite_memory_header(bytes: &[u8], memory: Value) -> Vec<u8> {
    let mut sections = unpack_sections(bytes);
    let mut header: Value = serde_json::from_slice(&sections.sections[0]).unwrap();
    header["memory"] = memory;
    sections.sections[0] = serde_json::to_vec(&header).unwrap();
    pack_sections(&sections, &sections.sections)
}

fn with_memory_section(bytes: &[u8], memory: Value, section: Vec<u8>) -> Vec<u8> {
    let mut sections = unpack_sections(bytes);
    let mut header: Value = serde_json::from_slice(&sections.sections[0]).unwrap();
    header["memory"] = memory;
    sections.sections[0] = serde_json::to_vec(&header).unwrap();
    sections.sections.push(section);
    pack_sections(&sections, &sections.sections)
}

fn pmm_column(absent_count: u64, absent_indices: &[u64], values: &[i128]) -> Vec<u8> {
    let mut section = b"PMM1".to_vec();
    put_uvarint(&mut section, absent_count);
    for index in absent_indices {
        put_uvarint(&mut section, *index);
    }
    for value in values {
        put_svarint(&mut section, *value);
    }
    section
}

struct Sections {
    magic: [u8; 4],
    sections: Vec<Vec<u8>>,
}

fn unpack_sections(bytes: &[u8]) -> Sections {
    let magic = bytes[..4].try_into().unwrap();
    let mut offset = 4;
    let mut sections = Vec::new();
    while offset < bytes.len() {
        let length = usize::try_from(read_uvarint(bytes, &mut offset)).unwrap();
        let end = offset.checked_add(length).unwrap();
        assert!(end <= bytes.len(), "test fixture has truncated section");
        sections.push(bytes[offset..end].to_vec());
        offset = end;
    }
    assert_eq!(offset, bytes.len());
    Sections { magic, sections }
}

fn pack_sections(original: &Sections, sections: &[Vec<u8>]) -> Vec<u8> {
    let mut bytes = original.magic.to_vec();
    for section in sections {
        put_uvarint(&mut bytes, section.len() as u64);
        bytes.extend_from_slice(section);
    }
    bytes
}

fn put_uvarint(output: &mut Vec<u8>, mut value: u64) {
    while value >= 0x80 {
        output.push((value as u8 & 0x7f) | 0x80);
        value >>= 7;
    }
    output.push(value as u8);
}

fn put_svarint(output: &mut Vec<u8>, value: i128) {
    let encoded = if value >= 0 {
        (value as u128) * 2
    } else {
        ((-value) as u128) * 2 - 1
    };
    let mut encoded = encoded;
    while encoded >= 0x80 {
        output.push((encoded as u8 & 0x7f) | 0x80);
        encoded >>= 7;
    }
    output.push(encoded as u8);
}

fn read_uvarint(bytes: &[u8], offset: &mut usize) -> u64 {
    let mut value = 0_u64;
    let mut shift = 0;
    loop {
        let byte = bytes[*offset];
        *offset += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return value;
        }
        shift += 7;
        assert!(shift < 64);
    }
}

#[cfg(target_os = "macos")]
#[test]
fn native_record_defaults_capture_own_memory_and_none_omits_it() {
    for selected in [None, Some("none")] {
        let temp = TempDir::new();
        let root = temp.path("recording");
        let mut command = Command::new(env!("CARGO_BIN_EXE_pane-load"));
        command
            .args(["recording", "record", "--output"])
            .arg(&root)
            .args(["--duration", "0.3", "--min-free-bytes", "0"]);
        if let Some(columns) = selected {
            command.args(["--memory-columns", columns]);
        }
        let mut child = command.spawn().unwrap();
        let pid = child.id();
        assert!(child.wait().unwrap().success());
        let output = Command::new(env!("CARGO_BIN_EXE_pane-load"))
            .args(["recording", "inspect", "--input"])
            .arg(&root)
            .arg("--jsonl")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let rows: Vec<Value> = String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .filter(|value: &Value| value["kind"] == "decoded-observation")
            .collect();
        assert!(!rows.is_empty());
        if selected.is_none() {
            let own = rows
                .iter()
                .flat_map(|row| row["processes"].as_array().unwrap())
                .find(|p| p["pid"] == pid)
                .unwrap();
            assert!(own["owned_bytes"].as_u64().unwrap() > 0);
        } else {
            assert!(
                rows.iter()
                    .all(|row| row.get("memory_unit_bytes").is_none())
            );
            assert!(
                rows.iter()
                    .flat_map(|row| row["processes"].as_array().unwrap())
                    .all(|p| p.get("owned_bytes").is_none())
            );
        }
    }
}
