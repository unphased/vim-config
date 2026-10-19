use herdr_pane_load::recording::{Context, Observation, OutputFormat, Process, Profile, Timebase, pipeline, source::RawWriter, store};
use std::{fs, path::PathBuf, sync::atomic::{AtomicU64, Ordering}};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp { fn new() -> Self { let p=std::env::temp_dir().join(format!("recording-bulk-{}-{}",std::process::id(),NEXT.fetch_add(1,Ordering::Relaxed))); fs::create_dir(&p).unwrap(); Self(p) } }
impl Drop for Temp { fn drop(&mut self) { let _=fs::remove_dir_all(&self.0); } }
fn process(user:u64, system:u64)->Process { Process {pid:42,ppid:1,start_sec:10,start_usec:20,name:"fixture λ".into(),user,system,rss:999_999} }
fn row(seq:u64, processes:Vec<Process>)->Observation { Observation {seq,wall_start_ns:1_700_000_000_000_000_000+seq as i64*100_000_000,scan_start_ns:seq*100_000_000+10,scan_end_ns:seq*100_000_000+20,processes,quality:vec![]} }
fn run_parity(sources:Vec<Vec<Observation>>, same_context:bool) {
    let temp=Temp::new(); let mut inputs=vec![];
    for (i,rows) in sources.into_iter().enumerate() {
        let mut context=Context::new(Timebase {numer:125,denom:3});context.capture_run_id=Some("bulk-fixture".into());
        if !same_context {context.source_headers.push(serde_json::json!({"segment":i}));}
        let path=temp.0.join(format!("input-{i}.jsonl.zst"));let mut writer=RawWriter::create(&path,&context).unwrap();for r in rows {writer.write(&r).unwrap();}writer.finish().unwrap();inputs.push(path);
    }
    for profile in [Profile::Legacy1ms,Profile::Adaptive] {
        let serial=temp.0.join(format!("serial-{profile:?}"));let parallel=temp.0.join(format!("parallel-{profile:?}"));
        let mut options=pipeline::default_record_options(serial.clone());options.min_free_bytes=0;options.max_bytes=64*1024*1024;options.profile=profile;options.format=OutputFormat::Binary;options.block_rows=3;options.verify=true;
        let a=pipeline::transform_sources(&inputs,&serial,&options,None).unwrap();
        options.output=parallel.clone();let b=pipeline::transform_sources_with_workers(&inputs,&parallel,&options,None,3).unwrap();
        assert_eq!(a.scans,b.scans);assert_eq!(a.readings,b.readings);assert_eq!(a.flagged_events,b.flagged_events);assert_eq!(a.blocks,b.blocks);
        assert_eq!(serde_json::to_value(&a.source_hashes).unwrap(),serde_json::to_value(&b.source_hashes).unwrap());
        assert_eq!(store::read_archive(&serial.join("archive")).unwrap(),store::read_archive(&parallel.join("archive")).unwrap());
    }
}
#[test]
fn parallel_matches_serial_for_late_cross_shard_component_regression_and_gap() {
    run_parity(vec![vec![row(0,vec![process(100,200)]),row(1,vec![process(110,220)])],vec![row(2,vec![]),row(3,vec![process(130,210)])],vec![row(4,vec![process(150,250)])]],false);
}
#[test]
fn identical_context_does_not_invent_cuts_at_physical_file_boundaries() {
    run_parity((0..5).map(|i|vec![row(i,vec![process(100+i,200+i)])]).collect(),true);
}
#[test]
fn reset_for_absent_identity_clears_cross_shard_state() {
    let mut reset=row(1,vec![]);reset.quality.push(serde_json::json!({"kind":"cpu-continuity-unknown","identity":{"pid":42,"start_sec":10,"start_usec":20},"seq":1,"unavailable_rate":true}));
    run_parity(vec![vec![row(0,vec![process(100,200)])],vec![reset],vec![row(2,vec![process(10,20)])]],false);
}
