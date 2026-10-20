use herdr_pane_load::recording::{
    Context, CpuCheckpoint, Observation, Process, Profile, Timebase, decode_block, encode_block,
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
        .filter_map(|row| {
            row.processes
                .first()?
                .cpu
                .clone()
                .map(|cpu| (row.seq, cpu))
        })
        .collect()
}

fn encode(rate_ticks_per_100ms: u64, count: u64, profile: Profile) -> Vec<(u64, CpuCheckpoint)> {
    let source: Vec<_> = (0..count)
        .map(|seq| row(seq, seq * rate_ticks_per_100ms))
        .collect();
    let decoded = decode_block(&encode_block(&context(), &source, profile).unwrap()).unwrap();
    assert_eq!(decoded.rows.len(), source.len(), "metadata rows are never thinned");
    samples(&decoded)
}

#[test]
fn inverse_and_log_profiles_retain_less_as_steady_cpu_rate_falls() {
    for profile in [Profile::AdaptiveInverse, Profile::AdaptiveLog] {
        let counts: Vec<_> = [5_000_000, 500_000, 50_000, 5_000]
            .into_iter()
            .map(|rate| encode(rate, 121, profile).len())
            .collect();
        assert!(counts.windows(2).all(|pair| pair[0] >= pair[1]), "{counts:?}");
        assert!(counts[0] > counts[3], "{profile:?}: {counts:?}");
    }
}

#[test]
fn quiet_prefix_is_closed_before_a_full_core_burst() {
    let mut source: Vec<_> = (0..30).map(|seq| row(seq, 0)).collect();
    source.push(row(30, 100_000_000));
    let decoded = decode_block(
        &encode_block(&context(), &source, Profile::AdaptiveInverse).unwrap(),
    )
    .unwrap();
    let checkpoints = samples(&decoded);
    let burst = checkpoints
        .iter()
        .find(|(seq, _)| *seq == 30)
        .expect("burst endpoint must be retained");
    let interval = burst.1.interval.as_ref().expect("burst has a CPU interval");
    assert_eq!(interval.start_seq, 29);
    assert_eq!(interval.start_time_ns, 29 * STEP_NS);
    assert_eq!(interval.end_time_ns, 30 * STEP_NS);
    assert_eq!(interval.duration_ns, STEP_NS);
    assert_eq!(interval.delta, 100_000_000);
    assert!(checkpoints.iter().any(|(seq, _)| *seq == 29));
}

#[test]
fn metadata_only_rows_have_no_cpu_and_memory_stays_on_every_row() {
    let decoded = decode_block(
        &encode_block(
            &context(),
            &(0..121).map(|seq| row(seq, seq * 5_000)).collect::<Vec<_>>(),
            Profile::AdaptiveLog,
        )
        .unwrap(),
    )
    .unwrap();
    assert!(decoded.rows.iter().any(|row| row.processes[0].cpu.is_none()));
    for (seq, observation) in decoded.rows.iter().enumerate() {
        let process = &observation.processes[0];
        assert_eq!(observation.seq, seq as u64);
        assert_eq!(process.rss, 786_432);
        assert_eq!(process.owned, Some((4_000_000 + seq as u64 * 256 * 1024) / 262_144 * 262_144));
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
    let decoded = decode_block(
        &encode_block(&context(), &source, Profile::AdaptiveInverse).unwrap(),
    )
    .unwrap();
    let checkpoints = samples(&decoded);
    assert!(checkpoints.len() < 30, "low-level jitter forced too many anchors");
    let returned = checkpoints.iter().find(|(seq, _)| *seq == 21).unwrap();
    assert!(returned.1.interval.is_none(), "absence must not be bridged");
}

#[test]
fn singleton_and_empty_blocks_are_valid() {
    for source in [vec![], vec![row(0, 7)]] {
        let decoded = decode_block(
            &encode_block(&context(), &source, Profile::AdaptiveInverse).unwrap(),
        )
        .unwrap();
        assert_eq!(decoded.rows.len(), source.len());
        if let Some(cpu) = decoded.rows.first().and_then(|row| row.processes.first()).and_then(|p| p.cpu.as_ref()) {
            assert!(cpu.interval.is_none());
        }
    }
}
