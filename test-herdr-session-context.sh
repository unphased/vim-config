#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"$tmp/herdr" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >>"$HERDR_TEST_ARGS"
case "$HERDR_TEST_MODE:$*" in
  'success:pane get w1:p2')
    cat <<'JSON'
{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t3","workspace_id":"w1","cwd":"/repo","foreground_cwd":"/repo/src","terminal_title_stripped":"pi - repo","agent":"pi","agent_status":"working","agent_session":{"source":"herdr:pi","kind":"path","value":"/sessions/current.jsonl"}}}}
JSON
    ;;
  'success:pane process-info --pane w1:p2')
    cat <<'JSON'
{"result":{"process_info":{"pane_id":"w1:p2","shell_pid":100,"foreground_processes":[{"name":"node","argv0":"pi","pid":200,"cwd":"/repo/src"}]}}}
JSON
    ;;
  'success:pane read w1:p2 --source recent-unwrapped --lines 120')
    printf 'recent terminal line 1\nrecent terminal line 2\n'
    ;;
  'malformed:pane get w1:p2')
    printf 'not JSON\n'
    ;;
  'failure:pane get w1:p2')
    printf 'pane unavailable\n' >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$tmp/herdr"

run_context() {
  HERDR_TEST_ARGS="$tmp/args" \
  HERDR_TEST_MODE=$1 \
  HERDR_ACTIVE_PANE_ID='w1:p2' \
  HERDR_BIN_PATH="$tmp/herdr" \
    "$root/herdr-session-context.sh"
}

run_context success >"$tmp/success"
grep -Fq 'Working dir     /repo/src' "$tmp/success" || fail 'foreground cwd is missing'
grep -Fq 'Agent           pi' "$tmp/success" || fail 'agent is missing'
grep -Fq 'Session value   /sessions/current.jsonl' "$tmp/success" || fail 'session reference is missing'
grep -Fq 'Raw pane metadata' "$tmp/success" || fail 'raw pane metadata section is missing'
grep -Fq 'Foreground processes' "$tmp/success" || fail 'process section is missing'
grep -Fq 'Recent terminal output (up to 120 lines)' "$tmp/success" || fail 'recent output section is missing'
grep -Fq 'recent terminal line 2' "$tmp/success" || fail 'recent terminal output is missing'
grep -Fxq 'pane get w1:p2' "$tmp/args" || fail 'pane metadata command is missing'
grep -Fxq 'pane process-info --pane w1:p2' "$tmp/args" || fail 'process-info command is missing'
grep -Fxq 'pane read w1:p2 --source recent-unwrapped --lines 120' "$tmp/args" || fail 'pane read command is missing'

: >"$tmp/args"
run_context malformed >"$tmp/malformed"
grep -Fq 'Could not parse metadata for pane w1:p2' "$tmp/malformed" || fail 'malformed JSON fallback is missing'
grep -Fq 'not JSON' "$tmp/malformed" || fail 'malformed response is missing'

: >"$tmp/args"
run_context failure >"$tmp/failure"
grep -Fq 'Could not inspect pane w1:p2' "$tmp/failure" || fail 'inspection failure is missing'
grep -Fq 'pane unavailable' "$tmp/failure" || fail 'inspection error is missing'

env -u HERDR_ACTIVE_PANE_ID HERDR_BIN_PATH="$tmp/herdr" \
  "$root/herdr-session-context.sh" >"$tmp/no-pane"
grep -Fq 'No active pane context was provided.' "$tmp/no-pane" || fail 'missing-pane message is missing'

printf 'PASS: Herdr session context popup\n'
