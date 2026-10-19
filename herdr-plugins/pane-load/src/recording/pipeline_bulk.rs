//! Two-pass offline bulk transform planning and bounded parallel group replay.
use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

pub(super) const MAX_GROUP_ENCODED_BYTES: usize = 256 * 1024 * 1024;
const MAX_BULK_SEED_ENTRIES: usize = 1_000_000;
const CANCELLED: &str = "bulk transform cancelled after a peer failure";

struct SourceSummary {
    stats: source::SourceStats,
    compressed_hash: String,
    resets: HashSet<Identity>,
    final_previous: HashMap<Identity, Previous>,
}

pub(super) struct GroupPlan {
    pub(super) start: usize,
    pub(super) end: usize,
    pub(super) context: Context,
    pub(super) seed_previous: HashMap<Identity, Previous>,
    pub(super) last_seq: Option<u64>,
    pub(super) last_stamp: Option<u64>,
}

pub(super) struct Plan {
    pub(super) sources: Vec<source::SourceStats>,
    pub(super) compressed_hashes: Vec<String>,
    pub(super) groups: Vec<GroupPlan>,
    pub(super) first_context: Context,
    pub(super) parser_workers: usize,
}

pub(super) struct GroupSourceStats {
    pub(super) index: usize,
    pub(super) stats: source::SourceStats,
    pub(super) compressed_hash: String,
}

pub(super) struct GroupStats {
    pub(super) sources: Vec<GroupSourceStats>,
    pub(super) scans: u64,
    pub(super) readings: u64,
    pub(super) flagged_events: u64,
}

pub(super) struct EncodedGroup {
    pub(super) blocks: Vec<EncodedBlock>,
    pub(super) stats: GroupStats,
}

struct BuildingGroup {
    start: usize,
    context: Context,
    seed_previous: HashMap<Identity, Previous>,
    touched: HashSet<Identity>,
    last_seq: Option<u64>,
    last_stamp: Option<u64>,
}

/// Scan each source independently with an empty offline validator. Ordered folding of
/// reset identities and final states then reconstructs the exact incoming validator state.
pub(super) fn build_plan(
    inputs: &[PathBuf],
    legacy_timebase: Option<Timebase>,
    ledger: Option<&CaptureLedger>,
    requested_workers: usize,
) -> Result<Plan> {
    let parser_workers = requested_workers.min(inputs.len()).max(1);
    let mut global_previous: HashMap<Identity, Previous> = HashMap::new();
    let mut last_seq = None;
    let mut last_stamp = None;
    let mut first_context: Option<Context> = None;
    let mut current_group: Option<BuildingGroup> = None;
    let mut next_group_start = 0;
    let mut groups = Vec::new();
    let mut sources = Vec::with_capacity(inputs.len());
    let mut compressed_hashes = Vec::with_capacity(inputs.len());
    let mut retained_seed_entries = 0usize;

    for batch_start in (0..inputs.len()).step_by(parser_workers) {
        let batch_end = (batch_start + parser_workers).min(inputs.len());
        let cancel = AtomicBool::new(false);
        let summaries = std::thread::scope(|scope| {
            let mut handles = Vec::with_capacity(batch_end - batch_start);
            let mut spawn_error = None;
            for (index, path) in inputs.iter().enumerate().take(batch_end).skip(batch_start) {
                let cancel = &cancel;
                match std::thread::Builder::new()
                    .name(format!("bulk-summary-{index}"))
                    .spawn_scoped(scope, move || {
                        let result = summarize_source(path, legacy_timebase, ledger, index, cancel);
                        if result.is_err() {
                            cancel.store(true, Ordering::Release);
                        }
                        result
                    }) {
                    Ok(handle) => handles.push((index, handle)),
                    Err(error) => {
                        cancel.store(true, Ordering::Release);
                        spawn_error = Some(format!("spawn source summary worker {index}: {error}"));
                        break;
                    }
                }
            }
            let mut results = Vec::with_capacity(handles.len());
            let mut error = spawn_error;
            for (index, handle) in handles {
                match handle.join() {
                    Ok(Ok(summary)) => results.push((index, Some(summary))),
                    Ok(Err(message)) => {
                        if message != CANCELLED && error.is_none() {
                            error = Some(format!("{}: {message}", inputs[index].display()));
                        }
                        results.push((index, None));
                    }
                    Err(_) => {
                        cancel.store(true, Ordering::Release);
                        error.get_or_insert_with(|| {
                            format!(
                                "{}: source summary worker panicked",
                                inputs[index].display()
                            )
                        });
                        results.push((index, None));
                    }
                }
            }
            (results, error)
        });
        if let Some(error) = summaries.1 {
            return Err(error);
        }

        for (index, summary) in summaries.0 {
            let summary =
                summary.ok_or_else(|| format!("{}: {CANCELLED}", inputs[index].display()))?;
            let stats = &summary.stats;
            if let Some(first) = &first_context {
                if !first.same_stream(&stats.context) {
                    return Err(format!(
                        "{}: source hz/timebase/run/boot context is not stable across files",
                        inputs[index].display()
                    ));
                }
            } else {
                first_context = Some(stats.context.clone());
            }

            if stats.scans > 0 {
                if let (Some(previous), Some(first)) = (last_seq, stats.first_seq)
                    && first <= previous
                {
                    return Err(format!(
                        "global observation sequence is not strictly increasing at {first}"
                    ));
                }
                if let (Some(previous), Some(first)) = (last_stamp, stats.first_scan_start_ns)
                    && first <= previous
                {
                    return Err(format!(
                        "global scan clock is not strictly increasing at {first}"
                    ));
                }

                if current_group
                    .as_ref()
                    .is_some_and(|group| group.context != stats.context)
                {
                    let group = current_group.take().expect("group exists");
                    retained_seed_entries =
                        retained_seed_entries.saturating_add(group.seed_previous.len());
                    groups.push(finish_group(group, index));
                    next_group_start = index;
                }
                if current_group.is_none() {
                    current_group = Some(BuildingGroup {
                        start: next_group_start,
                        context: stats.context.clone(),
                        seed_previous: HashMap::new(),
                        touched: HashSet::new(),
                        last_seq,
                        last_stamp,
                    });
                }
                let group = current_group.as_mut().expect("group initialized");
                for id in summary
                    .resets
                    .iter()
                    .chain(summary.final_previous.keys())
                    .copied()
                {
                    if group.touched.insert(id) {
                        if group.touched.len() > MAX_BULK_SEED_ENTRIES
                            || retained_seed_budget_exceeded(
                                retained_seed_entries,
                                group.seed_previous.len(),
                                MAX_BULK_SEED_ENTRIES,
                            )
                        {
                            return Err(format!(
                                "bulk continuity seeds exceed the {}-identity memory bound; retry with --workers 1",
                                MAX_BULK_SEED_ENTRIES
                            ));
                        }
                        if let Some(previous) = global_previous.get(&id) {
                            group.seed_previous.insert(id, *previous);
                        }
                    }
                }
                last_seq = stats.last_seq;
                last_stamp = stats.last_scan_start_ns;
            }

            for id in &summary.resets {
                global_previous.remove(id);
            }
            global_previous.extend(summary.final_previous);
            compressed_hashes.push(summary.compressed_hash);
            sources.push(summary.stats);
        }
    }

    let first_context =
        first_context.ok_or_else(|| "all source summaries are missing".to_string())?;
    if let Some(group) = current_group.take() {
        retained_seed_entries = retained_seed_entries.saturating_add(group.seed_previous.len());
        if retained_seed_budget_exceeded(retained_seed_entries, 0, MAX_BULK_SEED_ENTRIES) {
            return Err(format!(
                "bulk continuity seeds exceed the {}-identity memory bound; retry with --workers 1",
                MAX_BULK_SEED_ENTRIES
            ));
        }
        groups.push(finish_group(group, inputs.len()));
    } else if groups.is_empty() {
        // Header-only sources still establish the archive context and require pass-two
        // integrity verification, although there are no rows to encode.
        groups.push(GroupPlan {
            start: 0,
            end: inputs.len(),
            context: first_context.clone(),
            seed_previous: HashMap::new(),
            last_seq: None,
            last_stamp: None,
        });
    }
    drop(global_previous);
    Ok(Plan {
        sources,
        compressed_hashes,
        groups,
        first_context,
        parser_workers,
    })
}

fn retained_seed_budget_exceeded(retained: usize, candidate: usize, limit: usize) -> bool {
    retained.saturating_add(candidate) > limit
}

fn summary_budget_exceeded(
    accumulated_resets: usize,
    current_row_resets: usize,
    projected_previous: usize,
    limit: usize,
) -> bool {
    accumulated_resets > limit || current_row_resets.saturating_add(projected_previous) > limit
}

fn projected_previous_len(
    previous: &HashMap<Identity, Previous>,
    row_resets: &HashSet<Identity>,
    row: &Observation,
) -> usize {
    let removed = row_resets
        .iter()
        .filter(|identity| previous.contains_key(*identity))
        .count();
    let mut projected = previous.len().saturating_sub(removed);
    for process in &row.processes {
        let identity = process.identity();
        if row_resets.contains(&identity) || !previous.contains_key(&identity) {
            projected = projected.saturating_add(1);
        }
    }
    projected
}

fn finish_group(group: BuildingGroup, end: usize) -> GroupPlan {
    GroupPlan {
        start: group.start,
        end,
        context: group.context,
        seed_previous: group.seed_previous,
        last_seq: group.last_seq,
        last_stamp: group.last_stamp,
    }
}

fn summarize_source(
    path: &Path,
    legacy_timebase: Option<Timebase>,
    ledger: Option<&CaptureLedger>,
    index: usize,
    cancel: &AtomicBool,
) -> Result<SourceSummary> {
    if cancel.load(Ordering::Acquire) {
        return Err(CANCELLED.into());
    }
    if let Some(ledger) = ledger {
        verify_capture_source_hash(ledger, index, path)?;
    }
    let mut validator = Validator::new(false);
    let mut resets = HashSet::new();
    let stats = source::visit_source(path, legacy_timebase, |_, mut row| {
        if cancel.load(Ordering::Acquire) {
            return Err(CANCELLED.into());
        }
        let row_resets: HashSet<_> = row
            .quality
            .iter()
            .filter_map(continuity_unknown_identity)
            .collect();
        resets.extend(row_resets.iter().copied());
        let projected_previous = projected_previous_len(&validator.previous, &row_resets, &row);
        if summary_budget_exceeded(
            resets.len(),
            row_resets.len(),
            projected_previous,
            MAX_BULK_SEED_ENTRIES,
        ) {
            return Err(format!(
                "bulk source summary exceeds the {}-identity memory bound; retry with --workers 1",
                MAX_BULK_SEED_ENTRIES
            ));
        }
        validator.validate(&mut row)?;
        Ok(())
    })?;
    let compressed_hash = if let Some(ledger) = ledger {
        verify_capture_segment(ledger, index, path, &stats)?
    } else {
        hash_source_file(path)?.1
    };
    Ok(SourceSummary {
        stats,
        compressed_hash,
        resets,
        final_previous: validator.previous,
    })
}

#[derive(Clone, Copy)]
pub(super) struct ReplayInput<'a> {
    pub(super) inputs: &'a [PathBuf],
    pub(super) expected_sources: &'a [source::SourceStats],
    pub(super) expected_compressed_hashes: &'a [String],
    pub(super) legacy_timebase: Option<Timebase>,
    pub(super) ledger: Option<&'a CaptureLedger>,
    pub(super) options: &'a RecordOptions,
    pub(super) cancel: &'a AtomicBool,
}

pub(super) fn encode_group(group: &GroupPlan, replay: &ReplayInput<'_>) -> Result<EncodedGroup> {
    encode_group_with_limit(group, replay, MAX_GROUP_ENCODED_BYTES)
}

pub(super) fn encode_group_with_limit(
    group: &GroupPlan,
    replay: &ReplayInput<'_>,
    max_encoded_bytes: usize,
) -> Result<EncodedGroup> {
    let mut blocks = Vec::new();
    let mut encoded_bytes = 0usize;
    let stats = replay_group(group, replay, |block| {
        encoded_bytes = encoded_bytes
            .checked_add(block.bytes.len())
            .ok_or_else(|| "bulk encoded group size overflow".to_string())?;
        if encoded_bytes > max_encoded_bytes {
            return Err(format!(
                "bulk encoded group exceeds {} bytes; retry with --workers 1",
                max_encoded_bytes
            ));
        }
        blocks.push(block);
        Ok(())
    })?;
    Ok(EncodedGroup { blocks, stats })
}

pub(super) fn replay_group(
    group: &GroupPlan,
    replay: &ReplayInput<'_>,
    mut emit: impl FnMut(EncodedBlock) -> Result<()>,
) -> Result<GroupStats> {
    let ReplayInput {
        inputs,
        expected_sources,
        expected_compressed_hashes,
        legacy_timebase,
        ledger,
        options,
        cancel,
    } = replay;
    let mut validator = Validator::new(false);
    validator.previous.clone_from(&group.seed_previous);
    validator.last_seq = group.last_seq;
    validator.last_stamp = group.last_stamp;
    let mut builder = BlockBuilder::new(&group.context);
    let mut output = GroupStats {
        sources: Vec::with_capacity(group.end.saturating_sub(group.start)),
        scans: 0,
        readings: 0,
        flagged_events: 0,
    };

    for (source_index, path) in inputs.iter().enumerate().take(group.end).skip(group.start) {
        if cancel.load(Ordering::Acquire) {
            return Err(CANCELLED.into());
        }
        if let Some(ledger) = ledger {
            verify_capture_source_hash(ledger, source_index, path)?;
        }
        let source_stats = source::visit_source(path, *legacy_timebase, |context, mut row| {
            if cancel.load(Ordering::Acquire) {
                return Err(CANCELLED.into());
            }
            if context != &group.context {
                return Err("source context differs from planned bulk group".into());
            }
            let flagged = validator.validate(&mut row)?;
            output.scans = output.scans.saturating_add(1);
            output.readings = output.readings.saturating_add(row.processes.len() as u64);
            output.flagged_events = output
                .flagged_events
                .saturating_add(row.quality.len() as u64);
            if (builder.should_cut(context, &row, options) || flagged) && !builder.is_empty() {
                let block = encode_finished_block(&builder, options)?;
                emit(block)?;
                builder.rows.clear();
                builder.points = 0;
            }
            builder.push(row);
            Ok(())
        })
        .map_err(|error| format!("{}: {error}", path.display()))?;
        if expected_sources.get(source_index) != Some(&source_stats) {
            return Err(format!(
                "{}: source changed between bulk transform passes",
                path.display()
            ));
        }
        let compressed_hash = if let Some(ledger) = ledger {
            verify_capture_segment(ledger, source_index, path, &source_stats)?
        } else {
            hash_source_file(path)?.1
        };
        if expected_compressed_hashes.get(source_index) != Some(&compressed_hash) {
            return Err(format!(
                "{}: compressed source changed between bulk transform passes",
                path.display()
            ));
        }
        output.sources.push(GroupSourceStats {
            index: source_index,
            stats: source_stats,
            compressed_hash,
        });
    }
    if !builder.is_empty() {
        emit(encode_finished_block(&builder, options)?)?;
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recording::store;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_ID: AtomicU64 = AtomicU64::new(0);

    struct TestDir(PathBuf);

    impl TestDir {
        fn new() -> Self {
            let id = TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("pane-load-bulk-{}-{id}", std::process::id()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn path(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn context(segment: u64) -> Context {
        let mut context = Context::new(Timebase { numer: 1, denom: 1 });
        context.source_headers = vec![json!({"segment_index": segment})];
        context
    }

    fn process(pid: u32, user: u64, system: u64) -> Process {
        Process {
            pid,
            ppid: 1,
            start_sec: u64::from(pid),
            start_usec: 0,
            name: format!("p{pid}"),
            user,
            system,
            rss: 1024 * 1024,
            owned: None,
            peak: None,
            evicted: None,
        }
    }

    fn row(seq: u64, stamp: u64, processes: Vec<Process>, quality: Vec<Value>) -> Observation {
        Observation {
            seq,
            wall_start_ns: stamp as i64,
            scan_start_ns: stamp,
            scan_end_ns: stamp + 1,
            processes,
            quality,
        }
    }

    fn write_source(path: &Path, context: &Context, rows: &[Observation]) {
        let mut writer = RawWriter::create(path, context).unwrap();
        for row in rows {
            writer.write(row).unwrap();
        }
        writer.finish().unwrap();
    }

    #[test]
    fn seed_budget_counts_retained_seed_maps_not_touched_identities() {
        // The separate per-group touched cap is enforced at the call site. Across
        // groups, only identities actually copied into seed maps consume this budget.
        assert!(!retained_seed_budget_exceeded(1, 1, 2));
        assert!(retained_seed_budget_exceeded(1, 2, 2));
    }

    #[test]
    fn summary_budget_does_not_recount_past_resets_as_current_state() {
        assert!(!summary_budget_exceeded(2, 0, 2, 2));
        assert!(!summary_budget_exceeded(2, 1, 1, 2));
        assert!(summary_budget_exceeded(2, 1, 2, 2));
        assert!(summary_budget_exceeded(3, 0, 0, 2));
    }

    #[test]
    fn parallel_group_replay_matches_serial_bytes_across_reset_and_late_touch() {
        let temp = TestDir::new();
        let first = context(0);
        let second = context(1);
        let absent_reset = json!({
            "kind": "cpu-continuity-unknown",
            "identity": {"pid": 10, "start_sec": 10, "start_usec": 0}
        });
        let inputs = vec![
            temp.path("source-0.jsonl"),
            temp.path("source-1.jsonl"),
            temp.path("source-2.jsonl"),
        ];
        write_source(
            &inputs[0],
            &first,
            &[
                row(1, 100, vec![process(10, 100, 50)], vec![]),
                row(2, 200, vec![process(10, 200, 100)], vec![]),
            ],
        );
        // The unknown-baseline reset targets an identity absent from this row. The
        // next shard touches it late in the same exact-context group with lower counters.
        write_source(
            &inputs[1],
            &second,
            &[row(3, 300, vec![process(20, 10, 5)], vec![absent_reset])],
        );
        write_source(
            &inputs[2],
            &second,
            &[row(
                4,
                400,
                vec![process(10, 1, 1), process(20, 20, 10)],
                vec![],
            )],
        );

        let mut serial_options = default_record_options(temp.path("serial"));
        serial_options.min_free_bytes = 0;
        serial_options.verify = true;
        let serial =
            transform_sources(&inputs, &serial_options.output, &serial_options, None).unwrap();

        let mut bulk_options = default_record_options(temp.path("bulk"));
        bulk_options.min_free_bytes = 0;
        bulk_options.verify = true;
        let bulk =
            transform_sources_with_workers(&inputs, &bulk_options.output, &bulk_options, None, 3)
                .unwrap();

        assert_eq!(
            store::read_archive(&serial_options.output.join("archive")).unwrap(),
            store::read_archive(&bulk_options.output.join("archive")).unwrap()
        );
        assert_eq!(serial.scans, bulk.scans);
        assert_eq!(serial.readings, bulk.readings);
        assert_eq!(serial.flagged_events, bulk.flagged_events);
        assert_eq!(serial.blocks, bulk.blocks);
        assert_eq!(serial.source_hashes.len(), bulk.source_hashes.len());
        assert_eq!(bulk.bulk_workers, Some(3));
        assert_eq!(bulk.encoding_workers, Some(2));
        assert_eq!(bulk.source_passes, Some(2));
    }

    #[test]
    fn pass_two_detects_compressed_change_with_identical_expanded_stream() {
        let temp = TestDir::new();
        let plain_path = temp.path("plain.jsonl");
        let compressed_path = temp.path("source.jsonl.zst");
        write_source(
            &plain_path,
            &context(0),
            &[row(1, 100, vec![process(10, 100, 50)], vec![])],
        );
        let plain = fs::read(&plain_path).unwrap();
        let mut compressed = zstd::stream::encode_all(&plain[..], 0).unwrap();
        // A skippable frame changes the compressed bytes without changing JSONL output.
        compressed.extend_from_slice(&[0x50, 0x2a, 0x4d, 0x18, 4, 0, 0, 0, b'A', b'A', b'A', b'A']);
        fs::write(&compressed_path, &compressed).unwrap();

        let inputs = vec![compressed_path.clone()];
        let plan = build_plan(&inputs, None, None, 1).unwrap();
        let mut mutated = fs::read(&compressed_path).unwrap();
        let payload_start = mutated.len() - 4;
        mutated[payload_start..].copy_from_slice(b"BBBB");
        fs::write(&compressed_path, mutated).unwrap();
        let replay_stats = source::visit_source(&compressed_path, None, |_, _| Ok(())).unwrap();
        assert_eq!(plan.sources[0], replay_stats);

        let options = default_record_options(temp.path("unused-output"));
        let cancel = AtomicBool::new(false);
        let replay = ReplayInput {
            inputs: &inputs,
            expected_sources: &plan.sources,
            expected_compressed_hashes: &plan.compressed_hashes,
            legacy_timebase: None,
            ledger: None,
            options: &options,
            cancel: &cancel,
        };
        let error = match replay_group(&plan.groups[0], &replay, |_| Ok(())) {
            Ok(_) => panic!("compressed source mutation should be rejected"),
            Err(error) => error,
        };
        assert!(error.contains("compressed source changed between bulk transform passes"));
    }

    #[test]
    fn late_encode_failure_finishes_committed_frame_prefix() {
        let temp = TestDir::new();
        let inputs = vec![
            temp.path("source-0.jsonl"),
            temp.path("source-1.jsonl"),
            temp.path("source-2.jsonl"),
        ];
        write_source(
            &inputs[0],
            &context(0),
            &[row(1, 100, vec![process(10, 100, 50)], vec![])],
        );
        write_source(
            &inputs[1],
            &context(1),
            &[row(2, 200, vec![process(20, 200, 100)], vec![])],
        );
        let large_processes = (0..64)
            .map(|offset| {
                process(
                    100 + offset,
                    300 + u64::from(offset),
                    150 + u64::from(offset),
                )
            })
            .collect();
        write_source(
            &inputs[2],
            &context(2),
            &[row(3, 300, large_processes, vec![])],
        );

        let options = default_record_options(temp.path("unused-options-output"));
        let plan = build_plan(&inputs, None, None, 2).unwrap();
        let cancel = AtomicBool::new(false);
        let encoded_sizes = plan
            .groups
            .iter()
            .map(|group| {
                let replay = ReplayInput {
                    inputs: &inputs,
                    expected_sources: &plan.sources,
                    expected_compressed_hashes: &plan.compressed_hashes,
                    legacy_timebase: None,
                    ledger: None,
                    options: &options,
                    cancel: &cancel,
                };
                encode_group(group, &replay)
                    .unwrap()
                    .blocks
                    .iter()
                    .map(|block| block.bytes.len())
                    .sum::<usize>()
            })
            .collect::<Vec<_>>();
        let limit = encoded_sizes[..2].iter().copied().max().unwrap();
        assert!(encoded_sizes[2] > limit);

        let output = temp.path("partial-output");
        fs::create_dir(&output).unwrap();
        let archive_path = output.join("archive");
        let setup = BulkTransformSetup {
            inputs: &inputs,
            legacy_timebase: None,
            options: &options,
            requested_workers: 2,
            archive_path: &archive_path,
            store_options: StoreOptions {
                min_free_bytes: 0,
                ..StoreOptions::default()
            },
            capture_ledger: None,
            checked_segments: None,
            stats: RunStats::default(),
        };
        let error = run_bulk_transform_with_group_limit(setup, limit).unwrap_err();
        assert!(error.contains("bulk encoded group exceeds"));
        let prefix = store::read_archive(&archive_path).unwrap();
        assert_eq!(
            prefix.len(),
            2,
            "the earlier committed group blocks remain inspectable"
        );
    }
}
