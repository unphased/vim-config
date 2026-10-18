use herdr_pane_load::recording::{
    Context, Observation, Process, Profile, Timebase, decode_block, encode_block,
};

fn row(seq: u64, total: u64) -> Observation {
    Observation {
        seq,
        wall_start_ns: 1_700_000_000_000_000_000 + seq as i64 * 100_000_000,
        scan_start_ns: seq * 100_000_000,
        scan_end_ns: seq * 100_000_000 + 1000,
        processes: vec![Process {
            pid: 42,
            ppid: 1,
            start_sec: 123,
            start_usec: 4,
            name: "tiny λ".into(),
            user: total,
            system: 0,
            rss: 1_048_575,
        }],
        quality: vec![],
    }
}

#[test]
fn adaptive_keeps_source_zero_and_positive_intervals() {
    let context = Context::new(Timebase {
        numer: 125,
        denom: 3,
    });
    // Endpoint correction must NOT repay the first interval's remainder in idle.
    let source: Vec<_> = [0, 101, 101, 202, 303, 303]
        .into_iter()
        .enumerate()
        .map(|(i, c)| row(i as u64, c))
        .collect();
    let bytes = encode_block(&context, &source, Profile::Adaptive).unwrap();
    let decoded = decode_block(&bytes).unwrap();
    assert_eq!(decoded.rows.len(), source.len());
    let values: Vec<_> = decoded
        .rows
        .iter()
        .map(|r| r.processes[0].cpu_total)
        .collect();
    assert_eq!(values.first(), Some(&0));
    assert_eq!(values.last(), Some(&303));
    for i in 1..values.len() {
        let actual = source[i].processes[0].user - source[i - 1].processes[0].user;
        let restored = values[i] - values[i - 1];
        assert_eq!(actual == 0, restored == 0);
        assert!(actual == 0 || 8 * actual.abs_diff(restored) < actual);
    }
    assert!(decoded.rows.iter().all(|r| r.processes[0].rss == 786_432));
    assert!(
        decoded
            .rows
            .iter()
            .all(|r| r.processes[0].components.is_none())
    );
}

#[test]
fn component_regression_hidden_by_growing_sum_is_not_accepted_inside_a_block() {
    let context = Context::new(Timebase {
        numer: 125,
        denom: 3,
    });
    let a = row(0, 100);
    let mut b = row(1, 200);
    b.processes[0].system = 50;
    let mut a = a;
    a.processes[0].system = 75;
    assert!(encode_block(&context, &[a, b], Profile::Adaptive).is_err());
}

#[test]
fn decoder_rejects_all_truncated_prefixes_without_panicking() {
    let context = Context::new(Timebase {
        numer: 125,
        denom: 3,
    });
    let bytes = encode_block(&context, &[row(0, 999), row(1, 1000)], Profile::Adaptive).unwrap();
    for end in 0..bytes.len() {
        assert!(
            decode_block(&bytes[..end]).is_err(),
            "accepted prefix {end}"
        );
    }
}
