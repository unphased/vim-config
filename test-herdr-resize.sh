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
case "$*" in
  'pane current --current')
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}'
    exit 0
    ;;
  'pane neighbor --pane w1:p2 --direction left') neighbor=${HERDR_TEST_LEFT:-} ;;
  'pane neighbor --pane w1:p2 --direction right') neighbor=${HERDR_TEST_RIGHT:-} ;;
  'pane neighbor --pane w1:p2 --direction up') neighbor=${HERDR_TEST_UP:-} ;;
  'pane neighbor --pane w1:p2 --direction down') neighbor=${HERDR_TEST_DOWN:-} ;;
  'pane resize --pane '*' --direction '*) exit 0 ;;
  *) printf 'unexpected herdr command: %s\n' "$*" >&2; exit 1 ;;
esac

if [ -n "${neighbor:-}" ]; then
  printf '{"result":{"neighbor":{"neighbor_pane_id":"%s"}}}\n' "$neighbor"
else
  printf '%s\n' '{"result":{"neighbor":{}}}'
fi
MOCK
chmod +x "$tmp/herdr"

run_resize() {
  direction=$1
  : >"$tmp/args"
  HERDR_TEST_ARGS="$tmp/args" \
  HERDR_TEST_LEFT="${2:-}" \
  HERDR_TEST_RIGHT="${3:-}" \
  HERDR_TEST_UP="${4:-}" \
  HERDR_TEST_DOWN="${5:-}" \
  HERDR_PANE_ID="${HERDR_TEST_PANE_ID-w1:p2}" \
  HERDR_BIN_PATH="$tmp/herdr" \
  PATH="$tmp:$PATH" \
    "$root/herdr-resize.sh" "$direction"
}

assert_commands() {
  expected=$1
  actual=$(cat "$tmp/args")
  [ "$actual" = "$expected" ] || fail "expected commands:\n$expected\nactual commands:\n$actual"
}

# Prefer the bottom/right boundary so top/left stays anchored. Shrinking a
# middle pane therefore grows the neighbor on that boundary instead.
run_resize left w1:p-left w1:p-right
assert_commands $'pane neighbor --pane w1:p2 --direction right\npane resize --pane w1:p-right --direction left'
run_resize up '' '' w1:p-top w1:p-bottom
assert_commands $'pane neighbor --pane w1:p2 --direction down\npane resize --pane w1:p-bottom --direction up'

# Growing moves that same preferred boundary directly.
run_resize right w1:p-left w1:p-right
assert_commands $'pane neighbor --pane w1:p2 --direction right\npane resize --pane w1:p2 --direction right'
run_resize down '' '' w1:p-top w1:p-bottom
assert_commands $'pane neighbor --pane w1:p2 --direction down\npane resize --pane w1:p2 --direction down'

# At the bottom/right edge, preserve spatial direction: move the only boundary
# left/up or right/down exactly as requested.
run_resize left w1:p-left
assert_commands $'pane neighbor --pane w1:p2 --direction right\npane neighbor --pane w1:p2 --direction left\npane resize --pane w1:p2 --direction left'
run_resize right w1:p-left
assert_commands $'pane neighbor --pane w1:p2 --direction right\npane neighbor --pane w1:p2 --direction left\npane resize --pane w1:p2 --direction right'
run_resize up '' '' w1:p-top
assert_commands $'pane neighbor --pane w1:p2 --direction down\npane neighbor --pane w1:p2 --direction up\npane resize --pane w1:p2 --direction up'
run_resize down '' '' w1:p-top
assert_commands $'pane neighbor --pane w1:p2 --direction down\npane neighbor --pane w1:p2 --direction up\npane resize --pane w1:p2 --direction down'

# A pane without a split on this axis cannot be resized.
run_resize left
assert_commands $'pane neighbor --pane w1:p2 --direction right\npane neighbor --pane w1:p2 --direction left'

# Outside a keybinding subprocess, resolve Herdr's current pane explicitly.
HERDR_TEST_PANE_ID= run_resize down '' '' w1:p-top w1:p-bottom
assert_commands $'pane current --current\npane neighbor --pane w1:p2 --direction down\npane resize --pane w1:p2 --direction down'

for direction in left right up down; do
  grep -Fq "command = \"~/.vim/herdr-resize.sh $direction\"" "$root/herdr.toml" \
    || fail "$direction resize helper is not bound"
done
for direction in left right up down; do
  grep -Fqx "resize_pane_$direction = \"\"" "$root/herdr.toml" \
    || fail "native $direction resize binding still shadows the helper"
done

printf 'PASS: Herdr pane resize anchoring\n'
