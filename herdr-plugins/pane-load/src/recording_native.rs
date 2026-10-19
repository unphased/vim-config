//! Foreground native source adapter for `pane-load recording record`.
#[cfg(target_os = "macos")]
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(target_os = "macos")]
use herdr_pane_load::recording::{Context, Process as RecordedProcess, RecordOptions, Timebase};
#[cfg(any(target_os = "macos", test))]
use herdr_pane_load::recording::{LiveMessage, Observation};
#[cfg(any(target_os = "macos", test))]
use serde_json::{Value, json};
#[cfg(any(target_os = "macos", test))]
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
#[cfg(target_os = "macos")]
use std::thread;
#[cfg(any(target_os = "macos", test))]
use std::time::{Duration, Instant};
#[cfg(target_os = "macos")]
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(target_os = "macos")]
const PID_BUFFER_LIMIT: usize = 65_536;
#[cfg(target_os = "macos")]
const LIVE_QUEUE_SCANS: usize = 8;
#[cfg(target_os = "macos")]
const STOP_POLL: Duration = Duration::from_millis(25);
#[cfg(target_os = "macos")]
static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "macos")]
extern "C" fn record_signal_handler(_: libc::c_int) {
    STOP_REQUESTED.store(true, Ordering::Relaxed);
}

#[cfg(target_os = "macos")]
#[allow(clippy::fn_to_numeric_cast)]
fn install_record_signal_handlers() {
    // SAFETY: these handlers only set an atomic stop flag.
    unsafe {
        libc::signal(
            libc::SIGINT,
            record_signal_handler as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGTERM,
            record_signal_handler as *const () as libc::sighandler_t,
        );
    }
}

/// Entry point called only for the independent foreground `record` command.
pub fn run(args: &[String]) -> i32 {
    if args
        .chunks(2)
        .any(|option| option[0] == "--help" || option[0] == "-h")
    {
        println!(
            "pane-load recording record --output ROOT [--duration SEC] [--hz N] [--profile adaptive|legacy-1ms|fixed-100us] [--format binary|jsonl-zstd]"
        );
        return 0;
    }
    let options = match herdr_pane_load::recording::cli::parse_record_options(args) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("{error}");
            return 2;
        }
    };

    #[cfg(target_os = "macos")]
    let result = run_macos(options);
    #[cfg(not(target_os = "macos"))]
    let result: Result<(), String> = {
        let _ = options;
        Err("native recording currently supports macOS only".into())
    };

    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("recording: {error}");
            1
        }
    }
}

#[cfg(target_os = "macos")]
fn run_macos(options: RecordOptions) -> Result<(), String> {
    use super::MacProcessSampler;
    use herdr_pane_load::recording::pipeline::consume_live;

    let mut sampler = MacProcessSampler::new().map_err(|error| error.to_string())?;
    let timebase = sampler.timebase;
    let timebase = Timebase {
        numer: u64::from(timebase.numer),
        denom: u64::from(timebase.denom),
    };
    timebase.validate()?;
    let origin_ticks = continuous_ticks();
    let mut context = Context::new(timebase);
    context.hz = options.hz;
    context.capture_run_id = Some(format!("{}-{}", wall_time_ns()?, std::process::id()));
    context.boot_id = Some(boot_session_uuid()?);
    context.clock = "mach_continuous_time".into();
    context.source_headers.push(json!({
        "clock": "mach_continuous_time",
        "origin_ticks": origin_ticks,
        "timebase": { "numer": timebase.numer, "denom": timebase.denom },
        "unit": "ticks",
        "acquisition": {
            "method": "proc_listpids + BSD/task/BSD identity bracket",
            "atomicity": "non-atomic process scan",
            "scan_bounds": "continuous clock before enumeration through after process reads",
            "pid_limit": PID_BUFFER_LIMIT
        }
    }));

    let (tx, rx) = sync_channel::<LiveMessage>(LIVE_QUEUE_SCANS);
    let mut encoder_options = options.clone();
    // The producer owns the duration boundary; consume_live must drain through EOF.
    encoder_options.duration = None;
    let encoder_context = context.clone();
    let encoder = thread::Builder::new()
        .name("pane-load-record-encoder".into())
        .spawn(move || consume_live(&encoder_options, &encoder_context, rx))
        .map_err(|error| format!("start recording encoder: {error}"))?;

    STOP_REQUESTED.store(false, Ordering::Relaxed);
    install_record_signal_handlers();
    let mut terminal_quality_on_error = Vec::new();
    let sampling = observe(
        &mut sampler,
        &tx,
        &encoder,
        &options,
        timebase,
        origin_ticks,
        &mut terminal_quality_on_error,
    );
    let (quality, source_error) = match sampling {
        Ok(quality) => (quality, None),
        Err(error) => (terminal_quality_on_error, Some(error)),
    };
    let end_result = send_end(&tx, quality, source_error.clone());
    drop(tx);
    // A producer disconnect may be a consequence of an earlier storage failure.
    // Preserve the actionable writer/panic diagnostic before consequential errors.
    let encoded = encoder
        .join()
        .map_err(|_| "recording encoder thread panicked".to_string())?;
    encoded.map_err(|error| format!("recording writer: {error}"))?;
    if let Some(error) = source_error {
        return Err(error);
    }
    end_result?;
    Ok(())
}

#[cfg(any(target_os = "macos", test))]
fn send_end(
    tx: &SyncSender<LiveMessage>,
    quality: Vec<Value>,
    error: Option<String>,
) -> Result<(), String> {
    tx.send(LiveMessage::End { quality, error })
        .map_err(|_| "recording consumer disconnected before end marker".to_string())
}

#[cfg(target_os = "macos")]
fn observe(
    sampler: &mut super::MacProcessSampler,
    tx: &SyncSender<LiveMessage>,
    encoder: &thread::JoinHandle<impl Send>,
    options: &RecordOptions,
    timebase: Timebase,
    origin_ticks: u64,
    terminal_quality_on_error: &mut Vec<Value>,
) -> Result<Vec<Value>, String> {
    if !(1..=1000).contains(&options.hz) {
        return Err("--hz must be in 1..=1000".into());
    }
    let started = Instant::now();
    let interval = Duration::from_secs_f64(1.0 / options.hz as f64);
    let finish_at = match options.duration {
        Some(seconds) => Some(
            started
                .checked_add(
                    Duration::try_from_secs_f64(seconds)
                        .map_err(|_| "--duration is too large".to_string())?,
                )
                .ok_or_else(|| "--duration is too large".to_string())?,
        ),
        None => None,
    };
    let mut next_deadline = started;
    let mut next_seq = 0_u64;
    let mut pending = PendingGap::default();
    let mut previous_scan_start_ns = None;
    let sampling = (|| -> Result<(), String> {
        while !STOP_REQUESTED.load(Ordering::Relaxed) {
            if encoder.is_finished() {
                return Err("recording consumer stopped; refusing further samples".into());
            }
            if next_seq > 0 {
                let now = Instant::now();
                let (missed, deadline) = missed_deadlines(now, next_deadline, interval, finish_at)?;
                if missed > 0 {
                    let stamp = relative_ns(continuous_ticks(), origin_ticks, timebase)?;
                    pending.record_scheduled_range(next_seq, missed, stamp)?;
                    next_seq = next_seq
                        .checked_add(missed)
                        .ok_or_else(|| "observation sequence overflow".to_string())?;
                    next_deadline = deadline;
                }
            }
            if finish_at.is_some_and(|deadline| Instant::now() >= deadline) {
                break;
            }
            while Instant::now() < next_deadline {
                if STOP_REQUESTED.load(Ordering::Relaxed) {
                    break;
                }
                if encoder.is_finished() {
                    return Err("recording consumer stopped; refusing further samples".into());
                }
                let remaining = next_deadline.saturating_duration_since(Instant::now());
                thread::sleep(remaining.min(STOP_POLL));
            }
            if STOP_REQUESTED.load(Ordering::Relaxed)
                || finish_at.is_some_and(|deadline| Instant::now() >= deadline)
            {
                break;
            }

            let mut row = sample_scan(sampler, next_seq, timebase, origin_ticks)?;
            if let Some(previous) = previous_scan_start_ns
                && let Some(gap) = clock_gap_quality(previous, row.scan_start_ns, interval)
            {
                row.quality.push(gap);
            }
            previous_scan_start_ns = Some(row.scan_start_ns);
            next_seq = next_seq
                .checked_add(1)
                .ok_or_else(|| "observation sequence overflow".to_string())?;
            let original_quality_len = row.quality.len();
            pending.attach(&mut row);
            match tx.try_send(row.into()) {
                Ok(()) => pending.clear(),
                Err(TrySendError::Full(LiveMessage::Observation(mut row))) => {
                    row.quality.truncate(original_quality_len);
                    pending.record_scan(row)?;
                }
                Err(TrySendError::Full(LiveMessage::End { .. })) => unreachable!(),
                Err(TrySendError::Disconnected(_)) => {
                    return Err("recording consumer disconnected; stopping native sampling".into());
                }
            }

            next_deadline = next_deadline
                .checked_add(interval)
                .ok_or_else(|| "sampling deadline overflow".to_string())?;
        }
        Ok(())
    })();

    let mut sampling_error = sampling.err();
    if sampling_error.is_none() && next_seq > 0 {
        let trailing = (|| -> Result<(), String> {
            let (missed, _) = missed_deadlines(Instant::now(), next_deadline, interval, finish_at)?;
            if missed > 0 {
                let stamp = relative_ns(continuous_ticks(), origin_ticks, timebase)?;
                pending.record_scheduled_range(next_seq, missed, stamp)?;
            }
            Ok(())
        })();
        if let Err(error) = trailing {
            sampling_error = Some(error);
        }
    }
    // If the queue remained full through shutdown, preserve its latest actual scan.
    if let Some(last) = pending.take_final_scan()
        && let Err(error) = tx.send(last.into())
    {
        sampling_error.get_or_insert_with(|| {
            format!("recording consumer disconnected before final scan: {error}")
        });
    }
    let mut terminal_quality = pending.take_quality();
    if let Some(previous) = previous_scan_start_ns {
        match relative_ns(continuous_ticks(), origin_ticks, timebase) {
            Ok(now) => {
                if let Some(gap) = clock_gap_quality(previous, now, interval) {
                    terminal_quality.push(gap);
                }
            }
            Err(error) => {
                sampling_error.get_or_insert(error);
            }
        }
    }
    if let Some(error) = sampling_error {
        *terminal_quality_on_error = terminal_quality;
        Err(error)
    } else {
        Ok(terminal_quality)
    }
}

#[cfg(any(target_os = "macos", test))]
#[derive(Default)]
struct PendingGap {
    count: u64,
    first_seq: Option<u64>,
    last_seq: Option<u64>,
    first_ns: Option<u64>,
    last_ns: Option<u64>,
    final_prior_ns: Option<u64>,
    final_after_first_ns: Option<u64>,
    final_scan: Option<Observation>,
}

#[cfg(any(target_os = "macos", test))]
impl PendingGap {
    fn record_scheduled_range(
        &mut self,
        first_seq: u64,
        count: u64,
        stamp_ns: u64,
    ) -> Result<(), String> {
        if count == 0 {
            return Ok(());
        }
        let last_seq = first_seq
            .checked_add(count - 1)
            .ok_or_else(|| "observation sequence overflow".to_string())?;
        if self
            .final_scan
            .as_ref()
            .is_some_and(|row| row.seq < first_seq)
        {
            self.final_after_first_ns.get_or_insert(stamp_ns);
        }
        self.record_range(first_seq, last_seq, count, stamp_ns)
    }

    fn record_scan(&mut self, row: Observation) -> Result<(), String> {
        self.final_prior_ns = self.last_ns;
        self.final_after_first_ns = None;
        self.record_range(row.seq, row.seq, 1, row.scan_start_ns)?;
        self.final_scan = Some(row);
        Ok(())
    }

    fn record_range(
        &mut self,
        first_seq: u64,
        last_seq: u64,
        count: u64,
        stamp_ns: u64,
    ) -> Result<(), String> {
        self.count = self
            .count
            .checked_add(count)
            .ok_or_else(|| "acquisition gap count overflow".to_string())?;
        self.first_seq.get_or_insert(first_seq);
        self.last_seq = Some(last_seq);
        self.first_ns.get_or_insert(stamp_ns);
        self.last_ns = Some(stamp_ns);
        Ok(())
    }

    fn quality(&self) -> Option<Value> {
        (self.count > 0).then(|| {
            json!({
                "kind": "acquisition-gap",
                "scans": self.count,
                "seq_start": self.first_seq,
                "seq_end": self.last_seq,
                "start_ns": self.first_ns,
                "end_ns": self.last_ns
            })
        })
    }

    fn attach(&self, row: &mut Observation) {
        if let Some(gap) = self.quality() {
            row.quality.push(gap);
        }
    }

    fn take_final_scan(&mut self) -> Option<Observation> {
        let mut row = self.final_scan.take()?;
        // Preserve preceding gaps on the real scan while leaving later misses terminal.
        let first_seq = self.first_seq?;
        let last_seq = self.last_seq?;
        if first_seq < row.seq {
            row.quality.push(json!({
                "kind": "acquisition-gap",
                "scans": row.seq - first_seq,
                "seq_start": first_seq,
                "seq_end": row.seq - 1,
                "start_ns": self.first_ns,
                "end_ns": self.final_prior_ns
            }));
        }
        let trailing_count = last_seq.saturating_sub(row.seq);
        if trailing_count > 0 {
            self.count = trailing_count;
            self.first_seq = row.seq.checked_add(1);
            self.last_seq = Some(last_seq);
            self.first_ns = self.final_after_first_ns.or(self.last_ns);
            self.final_prior_ns = None;
            self.final_after_first_ns = None;
        } else {
            self.clear();
        }
        Some(row)
    }

    fn take_quality(&mut self) -> Vec<Value> {
        let quality = self.quality().into_iter().collect();
        self.clear();
        quality
    }

    fn clear(&mut self) {
        *self = Self::default();
    }
}

#[cfg(any(target_os = "macos", test))]
fn missed_deadlines(
    now: Instant,
    next_deadline: Instant,
    interval: Duration,
    finish_at: Option<Instant>,
) -> Result<(u64, Instant), String> {
    let step_ns = interval.as_nanos();
    if step_ns == 0 {
        return Err("sampling interval is below clock resolution".into());
    }
    let due = if now < next_deadline {
        0
    } else {
        (now.duration_since(next_deadline).as_nanos() / step_ns)
            .checked_add(1)
            .ok_or_else(|| "missed observation count overflow".to_string())?
    };
    let before_finish = match finish_at {
        None => u128::MAX,
        Some(finish) if next_deadline >= finish => 0,
        Some(finish) => {
            let distance = finish.duration_since(next_deadline).as_nanos();
            ((distance - 1) / step_ns)
                .checked_add(1)
                .ok_or_else(|| "missed observation count overflow".to_string())?
        }
    };
    let count = u64::try_from(due.min(before_finish))
        .map_err(|_| "missed observation count overflow".to_string())?;
    let advance_ns = step_ns
        .checked_mul(u128::from(count))
        .ok_or_else(|| "sampling deadline overflow".to_string())?;
    let seconds = u64::try_from(advance_ns / 1_000_000_000)
        .map_err(|_| "sampling deadline overflow".to_string())?;
    let nanos = (advance_ns % 1_000_000_000) as u32;
    let advance = Duration::new(seconds, nanos);
    let deadline = next_deadline
        .checked_add(advance)
        .ok_or_else(|| "sampling deadline overflow".to_string())?;
    Ok((count, deadline))
}

#[cfg(any(target_os = "macos", test))]
fn clock_gap_quality(previous_ns: u64, current_ns: u64, interval: Duration) -> Option<Value> {
    let elapsed_ns = current_ns.checked_sub(previous_ns)?;
    let threshold_ns = u64::try_from(interval.as_nanos().saturating_mul(2)).unwrap_or(u64::MAX);
    (elapsed_ns > threshold_ns).then(|| {
        json!({
            "kind": "clock-gap",
            "elapsed_ns": elapsed_ns,
            "threshold_ns": threshold_ns
        })
    })
}

#[cfg(target_os = "macos")]
fn sample_scan(
    sampler: &mut super::MacProcessSampler,
    seq: u64,
    timebase: Timebase,
    origin_ticks: u64,
) -> Result<Observation, String> {
    let start_ticks = continuous_ticks();
    let scan_start_ns = relative_ns(start_ticks, origin_ticks, timebase)?;
    let wall_start_ns = wall_time_ns()?;
    let mut quality = Vec::new();
    let enumeration = checked_pids();
    let mut processes = Vec::new();
    match enumeration {
        Ok((pids, truncated)) => {
            if truncated {
                quality.push(json!({
                    "kind": "enumeration-truncated",
                    "listed_pids": pids.len(),
                    "pid_limit": PID_BUFFER_LIMIT
                }));
            }
            let mut bsd_failures = 0_u64;
            let mut task_failures = 0_u64;
            let mut raced = 0_u64;
            for pid in pids {
                let Some(before) = sampler.bsd_info(pid) else {
                    bsd_failures += 1;
                    continue;
                };
                let Some(task) = sampler.task_info(pid) else {
                    task_failures += 1;
                    continue;
                };
                let Some(after) = sampler.bsd_info(pid) else {
                    bsd_failures += 1;
                    continue;
                };
                if before.pid != pid as u32
                    || after.pid != pid as u32
                    || (before.start_sec, before.start_usec) != (after.start_sec, after.start_usec)
                {
                    raced += 1;
                    continue;
                }
                let raw_name = super::c_string(&after.name)
                    .or_else(|| super::c_string(&after.comm))
                    .unwrap_or_default();
                let name = if raw_name.is_empty() {
                    "?".to_owned()
                } else {
                    String::from_utf8_lossy(&raw_name).into_owned()
                };
                processes.push(RecordedProcess {
                    pid: pid as u32,
                    ppid: after.ppid,
                    start_sec: after.start_sec,
                    start_usec: after.start_usec as u32,
                    name,
                    user: task.total_user,
                    system: task.total_system,
                    rss: task.resident_size,
                });
            }
            push_count(&mut quality, "bsd-read-failures", bsd_failures);
            push_count(&mut quality, "task-read-failures", task_failures);
            push_count(&mut quality, "identity-races", raced);
        }
        Err(error) => quality.push(json!({
            "kind": "enumeration-error",
            "error": error
        })),
    }
    let scan_end_ns = relative_ns(continuous_ticks(), origin_ticks, timebase)?;
    Ok(Observation {
        seq,
        wall_start_ns,
        scan_start_ns,
        scan_end_ns,
        processes,
        quality,
    })
}

#[cfg(target_os = "macos")]
fn push_count(quality: &mut Vec<Value>, kind: &str, count: u64) {
    if count > 0 {
        quality.push(json!({ "kind": kind, "count": count }));
    }
}

#[cfg(target_os = "macos")]
fn checked_pids() -> Result<(Vec<i32>, bool), String> {
    use std::mem::size_of;
    let mut size = 4096_usize.min(PID_BUFFER_LIMIT * size_of::<u32>());
    loop {
        let mut pids = vec![0_u32; size / size_of::<u32>()];
        // PROC_ALL_PIDS returns bytes written, or zero on failure. This
        // process itself exists, so zero cannot mean a genuinely empty host.
        let bytes =
            unsafe { super::proc_listpids(1, 0, pids.as_mut_ptr().cast(), size as libc::c_int) };
        if bytes <= 0 {
            return Err(format!(
                "proc_listpids returned {bytes}: {}",
                std::io::Error::last_os_error()
            ));
        }
        let bytes = bytes as usize;
        if bytes > size || !bytes.is_multiple_of(size_of::<u32>()) {
            return Err(format!(
                "invalid proc_listpids byte count: {bytes} for {size}-byte buffer"
            ));
        }
        pids.truncate(bytes / size_of::<u32>());
        let values = pids
            .into_iter()
            .filter(|pid| *pid != 0 && *pid <= i32::MAX as u32)
            .map(|pid| pid as i32)
            .collect::<Vec<_>>();
        if bytes < size {
            return Ok((values, false));
        }
        let limit = PID_BUFFER_LIMIT * size_of::<u32>();
        if size >= limit {
            return Ok((values, true));
        }
        size = size.saturating_mul(2).min(limit);
    }
}

#[cfg(target_os = "macos")]
fn continuous_ticks() -> u64 {
    unsafe extern "C" {
        fn mach_continuous_time() -> u64;
    }
    // SAFETY: mach_continuous_time has no arguments and returns the hardware tick count.
    unsafe { mach_continuous_time() }
}

#[cfg(target_os = "macos")]
fn relative_ns(ticks: u64, origin: u64, timebase: Timebase) -> Result<u64, String> {
    let elapsed = ticks
        .checked_sub(origin)
        .ok_or_else(|| "continuous clock moved before its run origin".to_string())?;
    u64::try_from(u128::from(elapsed) * u128::from(timebase.numer) / u128::from(timebase.denom))
        .map_err(|_| "continuous clock nanosecond conversion overflow".to_string())
}

#[cfg(target_os = "macos")]
fn wall_time_ns() -> Result<i64, String> {
    let nanos = match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => i128::try_from(duration.as_nanos())
            .map_err(|_| "wall clock nanoseconds overflow".to_string())?,
        Err(error) => -i128::try_from(error.duration().as_nanos())
            .map_err(|_| "wall clock nanoseconds overflow".to_string())?,
    };
    i64::try_from(nanos).map_err(|_| "wall clock is outside signed nanosecond range".into())
}

#[cfg(target_os = "macos")]
fn boot_session_uuid() -> Result<String, String> {
    use std::ffi::CString;
    use std::os::raw::c_char;

    unsafe extern "C" {
        fn sysctlbyname(
            name: *const c_char,
            oldp: *mut libc::c_void,
            oldlenp: *mut libc::size_t,
            newp: *mut libc::c_void,
            newlen: libc::size_t,
        ) -> libc::c_int;
    }

    let key = CString::new("kern.bootsessionuuid").expect("static sysctl name");
    let mut length = 0_usize;
    // SAFETY: the null oldp query asks the kernel for this sysctl's value length.
    if unsafe {
        sysctlbyname(
            key.as_ptr(),
            std::ptr::null_mut(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        return Err(format!(
            "read kern.bootsessionuuid: {}",
            std::io::Error::last_os_error()
        ));
    }
    if length == 0 || length > 256 {
        return Err(format!("invalid kern.bootsessionuuid length: {length}"));
    }
    let mut bytes = vec![0_u8; length];
    // SAFETY: bytes is length-sized and the kernel writes the requested sysctl value.
    if unsafe {
        sysctlbyname(
            key.as_ptr(),
            bytes.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        return Err(format!(
            "read kern.bootsessionuuid: {}",
            std::io::Error::last_os_error()
        ));
    }
    bytes.truncate(length);
    if bytes.last() == Some(&0) {
        bytes.pop();
    }
    let uuid =
        String::from_utf8(bytes).map_err(|_| "boot session UUID is not UTF-8".to_string())?;
    if uuid.is_empty() {
        return Err("kern.bootsessionuuid is empty".into());
    }
    Ok(uuid)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(seq: u64) -> Observation {
        Observation {
            seq,
            wall_start_ns: 0,
            scan_start_ns: seq * 10,
            scan_end_ns: seq * 10 + 1,
            processes: vec![],
            quality: vec![],
        }
    }

    #[test]
    fn pending_queue_gaps_attach_exact_range_to_next_accepted_scan() {
        let mut gap = PendingGap::default();
        gap.record_scan(row(3)).unwrap();
        gap.record_scan(row(4)).unwrap();
        let mut next = row(5);
        gap.attach(&mut next);
        assert_eq!(next.quality[0]["scans"], 2);
        assert_eq!(next.quality[0]["seq_start"], 3);
        assert_eq!(next.quality[0]["seq_end"], 4);
        gap.clear();
        assert_eq!(gap.count, 0);
    }

    #[test]
    fn final_real_scan_is_not_reported_as_lost() {
        let mut gap = PendingGap::default();
        gap.record_scan(row(3)).unwrap();
        gap.record_scan(row(4)).unwrap();
        let final_scan = gap.take_final_scan().unwrap();
        assert_eq!(final_scan.seq, 4);
        assert_eq!(final_scan.quality[0]["scans"], 1);
        assert_eq!(final_scan.quality[0]["seq_start"], 3);
        assert_eq!(final_scan.quality[0]["seq_end"], 3);
    }

    #[test]
    fn final_scan_keeps_trailing_scheduled_misses_as_terminal_quality() {
        let mut gap = PendingGap::default();
        gap.record_scan(row(3)).unwrap();
        gap.record_scan(row(4)).unwrap();
        gap.record_scheduled_range(5, 1, 51).unwrap();
        let final_scan = gap.take_final_scan().unwrap();
        assert_eq!(final_scan.quality[0]["seq_start"], 3);
        assert_eq!(final_scan.quality[0]["seq_end"], 3);
        let terminal = gap.take_quality();
        assert_eq!(terminal[0]["scans"], 1);
        assert_eq!(terminal[0]["seq_start"], 5);
        assert_eq!(terminal[0]["seq_end"], 5);
        assert_eq!(terminal[0]["start_ns"], 51);
    }

    #[test]
    fn missed_deadlines_advance_in_constant_time_and_respect_duration_cutoff() {
        let start = Instant::now();
        let interval = Duration::from_millis(100);
        let (missed, deadline) = missed_deadlines(
            start + Duration::from_secs(10),
            start,
            interval,
            Some(start + Duration::from_secs(5)),
        )
        .unwrap();
        assert_eq!(missed, 50);
        assert_eq!(deadline, start + Duration::from_secs(5));
    }

    #[test]
    fn clock_gap_quality_requires_continuous_span_over_threshold() {
        let interval = Duration::from_millis(100);
        assert!(clock_gap_quality(10, 200_000_010, interval).is_none());
        let gap = clock_gap_quality(10, 250_000_010, interval).unwrap();
        assert_eq!(gap["kind"], "clock-gap");
        assert_eq!(gap["elapsed_ns"], 250_000_000_u64);
        assert_eq!(gap["threshold_ns"], 200_000_000_u64);
    }

    fn fake_producer(tx: SyncSender<LiveMessage>, quality: Vec<Value>, error: Option<String>) {
        send_end(&tx, quality, error).unwrap();
    }

    #[test]
    fn fake_producer_emits_terminal_gap_and_error_before_channel_close() {
        let mut gap = PendingGap::default();
        gap.record_scheduled_range(8, 3, 80).unwrap();
        let quality = gap.take_quality();
        let (tx, rx) = sync_channel(1);
        fake_producer(tx, quality, Some("sampling failed".into()));
        match rx.recv().unwrap() {
            LiveMessage::End { quality, error } => {
                assert_eq!(error.as_deref(), Some("sampling failed"));
                assert_eq!(quality[0]["kind"], "acquisition-gap");
                assert_eq!(quality[0]["scans"], 3);
                assert_eq!(quality[0]["seq_start"], 8);
                assert_eq!(quality[0]["seq_end"], 10);
            }
            LiveMessage::Observation(_) => panic!("expected explicit end message"),
        }
        assert!(rx.recv().is_err());
    }
}

#[cfg(all(test, target_os = "macos"))]
mod memory_tests {
    use super::*;
    use herdr_pane_load::recording::MemoryEncoding;

    #[test]
    fn two_scans_capture_an_unmapped_64_mib_spike() {
        let mut sampler = super::super::MacProcessSampler::new().unwrap();
        let timebase = Timebase {
            numer: u64::from(sampler.timebase.numer),
            denom: u64::from(sampler.timebase.denom),
        };
        let origin = continuous_ticks();
        let first = sample_scan(
            &mut sampler,
            0,
            timebase,
            origin,
            &MemoryEncoding::default(),
        )
        .unwrap();
        let own = |row: &Observation| {
            row.processes
                .iter()
                .find(|p| p.pid == std::process::id())
                .unwrap()
                .clone()
        };
        let baseline = own(&first);
        assert!(baseline.owned.unwrap() > 0);
        const SIZE: usize = 64 * 1024 * 1024;
        // SAFETY: the anonymous mapping is checked, touched in-bounds, then unmapped exactly once.
        unsafe {
            let memory = libc::mmap(
                std::ptr::null_mut(),
                SIZE,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANON,
                -1,
                0,
            );
            assert_ne!(memory, libc::MAP_FAILED);
            for offset in (0..SIZE).step_by(4096) {
                std::ptr::write_volatile(memory.cast::<u8>().add(offset), 1);
            }
            assert_eq!(libc::munmap(memory, SIZE), 0);
        }
        let second = sample_scan(
            &mut sampler,
            1,
            timebase,
            origin,
            &MemoryEncoding::default(),
        )
        .unwrap();
        let point = own(&second);
        assert!(
            point.peak.unwrap() - point.owned.unwrap() >= SIZE as u64,
            "peak={:?}, owned={:?}",
            point.peak,
            point.owned
        );
        assert!(point.owned.unwrap().saturating_sub(baseline.owned.unwrap()) < SIZE as u64);
    }
}
