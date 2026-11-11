# Pane navigator diagnostics

Enable a capture on the machine running the Herdr server (no restart needed):

```sh
log="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/focus-trace.log"
mkdir -p "$(dirname "$log")"
(umask 077; touch "$log")
tail -f "$log"
```

Reproduce the rapid navigation, then remove the log to disable capture (copy it
elsewhere first if needed). Logs are not rotated; enable only while diagnosing.
`HERDR_FOCUS_TRACE_FILE` overrides the path for manually launched commands.

```text
hotkey action → helper waits → lock → live source → focus → unlock
             → observed destination → popup open → captured keys / popup exit
```

The helper and navigator append metadata to the same file. `trace_id` connects an
action to its helper, popup, and detached worker; PID identifies each process.
`time_us` is an epoch timestamp. Records include directions, inherited/live pane
IDs, focus commands/results, and popup lifecycle—not pane text or typed input.
No extra Herdr queries are made. Helper tracing uses the existing Perl runtime;
logging errors are ignored and never prevent navigation.

These diagnostics do **not** fix the remaining rapid-repeat race. In particular,
Herdr itself can change focus outside the helper lock; the trace establishes what
the helper actually saw, not the reason for every server-side focus change.
