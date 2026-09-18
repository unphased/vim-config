#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/herdr-claude-statusline.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_arg() {
  grep -Fx -- "$1" "$tmp/herdr.args" >/dev/null || fail "missing Herdr argument: $1"
}

assert_no_arg() {
  if grep -Fx -- "$1" "$tmp/herdr.args" >/dev/null; then
    fail "unexpected Herdr argument: $1"
  fi
}

cat >"$tmp/transcript.jsonl" <<'JSONL'
{"type":"assistant","isSidechain":false,"message":{"id":"m1","usage":{"input_tokens":1000,"output_tokens":1000,"cache_creation_input_tokens":1000,"cache_read_input_tokens":1000}}}
{"type":"assistant","isSidechain":false,"message":{"id":"m1","usage":{"input_tokens":1000,"output_tokens":1000,"cache_creation_input_tokens":1000,"cache_read_input_tokens":1000}}}
{"type":"assistant","isSidechain":false,"message":{"id":"m2","usage":{"input_tokens":4996000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"assistant","isSidechain":true,"message":{"id":"sidechain","usage":{"input_tokens":9000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JSONL

cat >"$tmp/status.json" <<JSON
{
  "model": {"display_name": "Opus 4.1"},
  "effort": {"level": "high"},
  "context_window": {"used_percentage": 75, "context_window_size": 200000},
  "transcript_path": "$tmp/transcript.jsonl"
}
JSON

mkdir "$tmp/bin"
cat >"$tmp/bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$HERDR_TEST_ARGS"
SH
chmod +x "$tmp/bin/herdr"

HERDR_ENV=1 \
HERDR_PANE_ID=w:test \
HERDR_SOCKET_PATH="$tmp/herdr.sock" \
HERDR_TEST_ARGS="$tmp/herdr.args" \
HERDR_CLAUDE_CACHE_DIR="$tmp/cache" \
PATH="$tmp/bin:$PATH" \
  "$repo/herdr-claude-statusline.sh" --report-only <"$tmp/status.json"

assert_arg 'pane'
assert_arg 'report-metadata'
assert_arg 'w:test'
assert_arg 'user:claude-statusline'
assert_arg 'herdr:claude'
assert_arg 'claude=✳'
assert_arg 'model=Opus 4.1:high'
assert_arg 'context_warn=75%/200k'
assert_arg 'session_tokens_active=5Mt'
assert_arg 'context_ok'
assert_arg 'context_error'
assert_arg 'session_tokens_healthy'
assert_arg 'session_tokens_warn'
assert_arg 'session_tokens_long'
assert_arg 'session_tokens_extreme'
assert_no_arg 'session_tokens_healthy=?'

cat >"$tmp/status-empty.json" <<'JSON'
{
  "model": {"display_name": "Opus 5 (1M context)"},
  "effort": {"level": "high"},
  "context_window": {"context_window_size": 1000000}
}
JSON
HERDR_ENV=1 \
HERDR_PANE_ID=w:test \
HERDR_SOCKET_PATH="$tmp/herdr.sock" \
HERDR_TEST_ARGS="$tmp/herdr.args" \
HERDR_CLAUDE_CACHE_DIR="$tmp/cache" \
PATH="$tmp/bin:$PATH" \
  "$repo/herdr-claude-statusline.sh" --report-only <"$tmp/status-empty.json"
assert_arg 'context_ok=?/1M'
assert_no_arg 'context_error=1000000%/?'
assert_arg 'session_tokens_healthy'
assert_arg 'session_tokens_active'
assert_arg 'session_tokens_warn'
assert_arg 'session_tokens_long'
assert_arg 'session_tokens_extreme'
if grep -E '^session_tokens_[^=]+=' "$tmp/herdr.args" >/dev/null; then
  fail 'missing transcript retained a session-token value'
fi

cat >"$tmp/delegate.sh" <<'SH'
#!/bin/sh
cat >"$CLAUDE_TEST_INPUT"
printf 'delegated status\n'
SH
chmod +x "$tmp/delegate.sh"

output=$(
  CLAUDE_TEST_INPUT="$tmp/delegated.json" \
  CLAUDE_STATUSLINE_DELEGATE="$tmp/delegate.sh" \
    "$repo/herdr-claude-statusline.sh" <"$tmp/status.json"
)
[[ "$output" == 'delegated status' ]] || fail 'statusline output was not delegated'
cmp -s "$tmp/status.json" "$tmp/delegated.json" || fail 'delegate did not receive the original JSON'

printf 'ok: Claude statusline reports Herdr token metadata and preserves its delegate\n'
