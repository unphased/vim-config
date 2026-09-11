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
printf '%s\n' "$*" >"$HERDR_TEST_ARGS"
case "$HERDR_TEST_MODE" in
  success)
    cat <<'JSON'
{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t3","workspace_id":"w1","cwd":"/repo","foreground_cwd":"/repo/src","terminal_title_stripped":"pi - repo","agent":"pi","agent_status":"working","agent_session":{"source":"herdr:pi","kind":"path","value":"/sessions/current.jsonl"}}}}
JSON
    ;;
  malformed)
    printf 'not JSON\n'
    ;;
  failure)
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
grep -Fxq 'pane get w1:p2' "$tmp/args" || fail 'wrong Herdr command arguments'

run_context malformed >"$tmp/malformed"
grep -Fq 'Could not parse metadata for pane w1:p2' "$tmp/malformed" || fail 'malformed JSON fallback is missing'
grep -Fq 'not JSON' "$tmp/malformed" || fail 'malformed response is missing'

run_context failure >"$tmp/failure"
grep -Fq 'Could not inspect pane w1:p2' "$tmp/failure" || fail 'inspection failure is missing'
grep -Fq 'pane unavailable' "$tmp/failure" || fail 'inspection error is missing'

env -u HERDR_ACTIVE_PANE_ID HERDR_BIN_PATH="$tmp/herdr" \
  "$root/herdr-session-context.sh" >"$tmp/no-pane"
grep -Fq 'No active pane context was provided.' "$tmp/no-pane" || fail 'missing-pane message is missing'

printf 'PASS: Herdr session context popup\n'
