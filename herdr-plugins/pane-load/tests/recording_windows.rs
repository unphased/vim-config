use herdr_pane_load::recording::wire::encode_block_with_memory;
use herdr_pane_load::recording::{
    Context, CpuCheckpoint, MemoryEncoding, Observation, Process, Profile, Timebase, decode_block,
    encode_block,
};

const STEP_NS: u64 = 100_000_000;
const TICKS_PER_NS: u64 = 1;

fn row(seq: u64, total: u64) -> Observation {
    Observation {
        seq,
        wall_start_ns: 1_700_000_000_000_000_000 + (seq * STEP_NS) as i64,
        scan_start_ns: seq * STEP_NS,
        scan_end_ns: seq * STEP_NS + 1_000,
        processes: vec![Process {
            pid: 42,
            ppid: 1,
            start_sec: 123,
            start_usec: 4,
            name: "worker".into(),
            user: total,
            system: 0,
            rss: 1_048_575,
            owned: Some(4_000_000 + seq * 256 * 1024),
            peak: Some(8_000_000),
            evicted: None,
        }],
        quality: vec![],
    }
}

fn context() -> Context {
    Context::new(Timebase {
        numer: 1,
        denom: TICKS_PER_NS,
    })
}

fn samples(decoded: &herdr_pane_load::recording::DecodedBlock) -> Vec<(u64, CpuCheckpoint)> {
    decoded
        .rows
        .iter()
        .filter_map(|row| row.processes.first()?.cpu.clone().map(|cpu| (row.seq, cpu)))
        .collect()
}

fn encode(rate_ticks_per_100ms: u64, count: u64, profile: Profile) -> Vec<(u64, CpuCheckpoint)> {
    let source: Vec<_> = (0..count)
        .map(|seq| row(seq, seq * rate_ticks_per_100ms))
        .collect();
    let decoded = decode_block(&encode_block(&context(), &source, profile).unwrap()).unwrap();
    assert_eq!(
        decoded.rows.len(),
        source.len(),
        "metadata rows are never thinned"
    );
    samples(&decoded)
}

#[test]
fn one_percent_reference_uses_adaptive_one_millisecond_quantum() {
    let timebase = Timebase {
        numer: 125,
        denom: 3,
    }; // 24 MHz Mach ticks: 24,000 ticks per millisecond.
    let context = Context::new(timebase);

    let steady_five_percent: Vec<_> = (0..61).map(|seq| row(seq, seq * 120_000)).collect();
    let decoded = decode_block(
        &encode_block(&context, &steady_five_percent, Profile::AdaptiveInverse).unwrap(),
    )
    .unwrap();
    let steady_checkpoints = samples(&decoded);
    assert_eq!(steady_checkpoints.len(), steady_five_percent.len());
    for (index, (_, cpu)) in steady_checkpoints.iter().enumerate() {
        let actual = steady_five_percent[index].processes[0].total().unwrap();
        assert!(cpu.total <= actual);
        assert!(actual - cpu.total <= cpu.error_bound);
        assert_eq!(
            cpu.error_bound,
            if index == 0 || index + 1 == steady_checkpoints.len() {
                0
            } else {
                8_191
            }
        );
    }

    let low_rate: Vec<_> = (0..121).map(|seq| row(seq, seq * 120)).collect();
    let inverse =
        decode_block(&encode_block(&context, &low_rate, Profile::AdaptiveInverse).unwrap())
            .unwrap();
    let log =
        decode_block(&encode_block(&context, &low_rate, Profile::AdaptiveLog).unwrap()).unwrap();
    let inverse_intervals: Vec<_> = samples(&inverse)
        .iter()
        .filter_map(|(_, cpu)| cpu.interval.as_ref().map(|interval| interval.duration_ns))
        .collect();
    let log_intervals: Vec<_> = samples(&log)
        .iter()
        .filter_map(|(_, cpu)| cpu.interval.as_ref().map(|interval| interval.duration_ns))
        .collect();
    assert_eq!(
        inverse_intervals,
        [5_000_000_000, 5_000_000_000, 2_000_000_000]
    );
    assert_eq!(
        log_intervals,
        [3_700_000_000, 3_700_000_000, 3_700_000_000, 900_000_000]
    );
}

#[test]
fn inverse_and_log_profiles_retain_less_as_steady_cpu_rate_falls() {
    for profile in [Profile::AdaptiveInverse, Profile::AdaptiveLog] {
        let counts: Vec<_> = [5_000_000, 500_000, 50_000, 5_000]
            .into_iter()
            .map(|rate| encode(rate, 121, profile).len())
            .collect();
        assert!(
            counts.windows(2).all(|pair| pair[0] >= pair[1]),
            "{counts:?}"
        );
        assert!(counts[0] > counts[3], "{profile:?}: {counts:?}");
    }
}

#[test]
fn quiet_prefix_is_closed_before_a_full_core_burst() {
    let mut source: Vec<_> = (0..30).map(|seq| row(seq, 0)).collect();
    source.push(row(30, 100_000_000));
    source.extend((31..62).map(|seq| row(seq, 100_000_000)));
    let decoded =
        decode_block(&encode_block(&context(), &source, Profile::AdaptiveInverse).unwrap())
            .unwrap();
    let checkpoints = samples(&decoded);
    let burst = checkpoints
        .iter()
        .find(|(seq, _)| *seq == 30)
        .expect("burst endpoint must be retained");
    assert_eq!(burst.1.total, 100_000_000);
    assert!(
        decoded.rows[31].processes[0].cpu.is_none(),
        "quiet rows must not hold CPU"
    );
    let interval = burst.1.interval.as_ref().expect("burst has a CPU interval");
    assert_eq!(interval.start_seq, 29);
    assert_eq!(interval.start_time_ns, 29 * STEP_NS);
    assert_eq!(interval.end_time_ns, 30 * STEP_NS);
    assert_eq!(interval.duration_ns, STEP_NS);
    assert_eq!(interval.delta, 100_000_000);
    assert!(checkpoints.iter().any(|(seq, _)| *seq == 29));
}

#[test]
fn selection_uses_latest_adjacent_raw_rate_without_cutting_a_short_prefix() {
    let times = [
        0,
        100_000_000,
        200_000_000,
        300_000_000,
        400_000_000,
        500_000_000,
    ];
    let totals = [0, 100_000, 300_000, 300_000, 300_000, 300_000];
    let source: Vec<_> = times
        .into_iter()
        .zip(totals)
        .enumerate()
        .map(|(seq, (time, total))| {
            let mut observation = row(seq as u64, total);
            observation.scan_start_ns = time;
            observation.scan_end_ns = time + 1_000;
            observation
        })
        .collect();
    let decoded =
        decode_block(&encode_block(&context(), &source, Profile::AdaptiveInverse).unwrap())
            .unwrap();
    let selected: Vec<_> = samples(&decoded).into_iter().map(|(seq, _)| seq).collect();
    assert_eq!(selected, [0, 4, 5]);
}

#[test]
fn noisy_thirty_hz_temporal_tracks_reduce_checkpoints_without_losing_aggregate_cpu() {
    let source: Vec<_> = (0..=600)
        .map(|seq| {
            let mut observation = row(seq, seq / 2);
            observation.scan_start_ns = seq * 33_333_333;
            observation.scan_end_ns = observation.scan_start_ns + 1_000;
            observation
        })
        .collect();
    for profile in [Profile::AdaptiveInverse, Profile::AdaptiveLog] {
        let decoded = decode_block(&encode_block(&context(), &source, profile).unwrap()).unwrap();
        let checkpoints = samples(&decoded);
        assert!(
            checkpoints.len() < source.len() / 20,
            "{profile:?}: {}",
            checkpoints.len()
        );
        assert_eq!(checkpoints.first().unwrap().1.total, 0);
        assert_eq!(checkpoints.last().unwrap().1.total, 300);
        assert!(
            checkpoints
                .windows(2)
                .all(|pair| pair[1].1.total >= pair[0].1.total)
        );
    }
}

#[test]
fn metadata_only_rows_have_no_cpu_and_memory_stays_on_every_row() {
    let decoded = decode_block(
        &encode_block_with_memory(
            &context(),
            &(0..121)
                .map(|seq| row(seq, seq * 5_000))
                .collect::<Vec<_>>(),
            Profile::AdaptiveLog,
            MemoryEncoding::default(),
        )
        .unwrap(),
    )
    .unwrap();
    assert!(
        decoded
            .rows
            .iter()
            .any(|row| row.processes[0].cpu.is_none())
    );
    for (seq, observation) in decoded.rows.iter().enumerate() {
        let process = &observation.processes[0];
        assert_eq!(observation.seq, seq as u64);
        assert_eq!(process.rss, 786_432);
        assert_eq!(
            process.owned,
            Some((4_000_000 + seq as u64 * 256 * 1024) / 262_144 * 262_144)
        );
        assert_eq!(process.peak, Some(8_000_000 / 262_144 * 262_144));
    }
}

#[test]
fn jitter_is_averaged_and_process_returns_start_a_new_baseline() {
    let mut source: Vec<_> = (0..61)
        .map(|seq| row(seq, if seq % 2 == 0 { seq } else { seq - 1 }))
        .collect();
    source[20].processes.clear();
    source[21].processes[0].user = source[19].processes[0].user;
    let decoded =
        decode_block(&encode_block(&context(), &source, Profile::AdaptiveInverse).unwrap())
            .unwrap();
    let checkpoints = samples(&decoded);
    assert!(
        checkpoints.len() < 30,
        "low-level jitter forced too many anchors"
    );
    let returned = checkpoints.iter().find(|(seq, _)| *seq == 21).unwrap();
    assert!(returned.1.interval.is_none(), "absence must not be bridged");
}

#[test]
fn source_elapsed_time_controls_normalized_cpu_rate_and_interval_duration() {
    let mut source: Vec<_> = (0..21)
        .map(|seq| {
            let mut observation = row(seq, seq * 60_000);
            observation.scan_start_ns = seq * 250_000_000;
            observation.scan_end_ns = observation.scan_start_ns + 500;
            observation
        })
        .collect();
    // A discontinuous sequence is a new baseline even when identity is unchanged.
    source[5].seq = 7;
    for (index, observation) in source.iter_mut().enumerate().skip(6) {
        observation.seq = index as u64 + 2;
    }
    let native_context = Context::new(Timebase {
        numer: 125,
        denom: 3,
    });
    let decoded =
        decode_block(&encode_block(&native_context, &source, Profile::AdaptiveInverse).unwrap())
            .unwrap();
    let checkpoints = samples(&decoded);
    assert!(
        checkpoints
            .iter()
            .any(|(seq, cpu)| *seq == 7 && cpu.interval.is_none())
    );
    for (_, cpu) in checkpoints {
        if let Some(interval) = cpu.interval {
            assert_eq!(
                interval.duration_ns,
                interval.end_time_ns - interval.start_time_ns
            );
            assert!(interval.duration_ns >= 250_000_000);
        }
    }
}

#[test]
fn quality_unknown_resets_cpu_and_only_name_or_parent_changes_force_checkpoints() {
    let mut source: Vec<_> = (0..31).map(|seq| row(seq, seq)).collect();
    source[8].processes[0].rss += 1_000_000;
    source[10].processes[0].name = "renamed".into();
    source[11].processes[0].ppid = 3;
    source[15].quality.push(serde_json::json!({
        "kind":"cpu-continuity-unknown",
        "identity":{"pid":42,"start_sec":123,"start_usec":4}
    }));
    source[15].processes[0].user = 1;
    for (seq, observation) in source.iter_mut().enumerate().skip(16) {
        observation.processes[0].user = 25_000_000 + seq as u64;
    }
    let native_context = Context::new(Timebase {
        numer: 125,
        denom: 3,
    });
    let decoded =
        decode_block(&encode_block(&native_context, &source, Profile::AdaptiveInverse).unwrap())
            .unwrap();
    let checkpoints = samples(&decoded);
    assert!(checkpoints.iter().any(|(seq, _)| *seq == 10));
    assert!(checkpoints.iter().any(|(seq, _)| *seq == 11));
    assert!(!checkpoints.iter().any(|(seq, _)| *seq == 8));
    let reset = checkpoints.iter().find(|(seq, _)| *seq == 15).unwrap();
    assert!(reset.1.interval.is_none());
    let after_reset = checkpoints.iter().find(|(seq, _)| *seq == 16).unwrap();
    assert_eq!(after_reset.1.interval.as_ref().unwrap().start_seq, 15);
}

#[test]
fn temporal_profiles_retain_positive_millisecond_metadata_changes_for_multiple_processes() {
    let context = Context::new(Timebase { numer: 1, denom: 1 });
    let rows: Vec<_> = (0..3)
        .map(|seq| {
            let mut observation = row(seq, seq);
            observation.scan_start_ns = seq * 1_000_000;
            observation.scan_end_ns = observation.scan_start_ns + 100;
            for process in &mut observation.processes {
                process.name = format!("worker-{seq}");
            }
            let mut second = observation.processes[0].clone();
            second.pid = 43;
            second.user = seq;
            observation.processes.push(second);
            observation
        })
        .collect();

    for profile in [Profile::AdaptiveInverse, Profile::AdaptiveLog] {
        let encoded = encode_block(&context, &rows, profile).unwrap();
        let decoded = decode_block(&encoded).unwrap();
        for (row_index, decoded_row) in decoded.rows.iter().enumerate() {
            assert_eq!(decoded_row.processes.len(), 2);
            for process in &decoded_row.processes {
                let cpu = process
                    .cpu
                    .as_ref()
                    .expect("name changes retain each point");
                assert_eq!(cpu.total, row_index as u64);
                assert_eq!(cpu.error_bound, 0);
                if row_index > 0 {
                    let interval = cpu.interval.as_ref().unwrap();
                    assert_eq!(interval.delta, 1);
                    assert_eq!(interval.error_bound, 0);
                    assert_eq!(interval.duration_ns, 1_000_000);
                }
            }
        }
    }
}

#[test]
fn clock_gap_resets_temporal_cpu_baseline_without_crossing_the_rate_jump() {
    let mut source = vec![row(0, 0), row(1, 100), row(2, 10_000), row(3, 10_100)];
    for (observation, stamp) in
        source
            .iter_mut()
            .zip([0, 100_000_000, 10_000_000_000, 10_100_000_000])
    {
        observation.scan_start_ns = stamp;
        observation.scan_end_ns = stamp + 1_000;
    }
    source[2]
        .quality
        .push(serde_json::json!({"kind":"clock-gap"}));

    for profile in [Profile::AdaptiveInverse, Profile::AdaptiveLog] {
        let decoded = decode_block(&encode_block(&context(), &source, profile).unwrap()).unwrap();
        let process_cpu = |seq: usize| {
            decoded.rows[seq].processes[0]
                .cpu
                .as_ref()
                .expect("gap boundaries are retained")
        };
        assert_eq!(process_cpu(1).total, 100);
        assert_eq!(process_cpu(1).interval.as_ref().unwrap().start_seq, 0);
        assert_eq!(process_cpu(2).total, 10_000);
        assert!(process_cpu(2).interval.is_none());
        let after_gap = process_cpu(3).interval.as_ref().unwrap();
        assert_eq!(after_gap.start_seq, 2);
        assert_eq!(after_gap.delta, 100);
    }
}

#[test]
fn singleton_and_empty_blocks_are_valid() {
    for source in [vec![], vec![row(0, 7)]] {
        let decoded =
            decode_block(&encode_block(&context(), &source, Profile::AdaptiveInverse).unwrap())
                .unwrap();
        assert_eq!(decoded.rows.len(), source.len());
        if let Some(cpu) = decoded
            .rows
            .first()
            .and_then(|row| row.processes.first())
            .and_then(|p| p.cpu.as_ref())
        {
            assert!(cpu.interval.is_none());
        }
    }
}
