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
case "$*" in
  'pane current --current')
    pane=$(cat "$HERDR_TEST_STATE")
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t1","workspace_id":"w1"}}}\n' "$pane"
    ;;
  'pane layout --pane w1:p1'|'pane layout --pane w1:p2')
    pane=$(cat "$HERDR_TEST_STATE")
    cat <<JSON
{"result":{"layout":{"area":{"height":40,"width":100,"x":0,"y":0},"focused_pane_id":"$pane","panes":[{"pane_id":"w1:p1","rect":{"height":40,"width":60,"x":0,"y":0}},{"pane_id":"w1:p2","rect":{"height":40,"width":40,"x":60,"y":0}}],"tab_id":"w1:t1","workspace_id":"w1","zoomed":${HERDR_TEST_ZOOMED:-true}}}}
JSON
    ;;
  *)
    printf 'unexpected herdr command: %s\n' "$*" >&2
    exit 1
    ;;
esac
MOCK

cat >"$tmp/focus" <<'MOCK'
#!/bin/sh
printf '%s\n' "$1" >>"$HERDR_TEST_DIRECTIONS"
case "$1" in
  left) printf 'w1:p1\n' >"$HERDR_TEST_STATE" ;;
  right) printf 'w1:p2\n' >"$HERDR_TEST_STATE" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/herdr" "$tmp/focus"
printf 'w1:p2\n' >"$tmp/state"

printf '\014' | \
  HERDR_BIN_PATH="$tmp/herdr" \
  HERDR_ACTIVE_PANE_ID='w1:p2' \
  HERDR_FOCUS_HELPER="$tmp/focus" \
  HERDR_MINIMAP_TIMEOUT=0.01 \
  HERDR_TEST_DIRECTIONS="$tmp/directions" \
  HERDR_TEST_STATE="$tmp/state" \
  python3 "$root/herdr-pane-navigator.py" left >"$tmp/output"

[ "$(cat "$tmp/directions")" = $'left\nright' ] || fail 'popup should handle repeated navigation before closing'
[ "$(cat "$tmp/state")" = 'w1:p2' ] || fail 'the latest movement should determine the focused pane'
grep -Fq 'Workspace w1  Tab w1:t1' "$tmp/output" || fail 'minimap context is missing'
grep -Fq '● current' "$tmp/output" || fail 'focused-pane legend is missing'
grep -Fq '┌' "$tmp/output" || fail 'minimap border is missing'
[ "$(grep -o '●' "$tmp/output" | wc -l | tr -d ' ')" -eq 4 ] || fail 'each redraw should mark the focused box and include its legend'
[ "$(grep -o $'\033\[2J' "$tmp/output" | wc -l | tr -d ' ')" -eq 2 ] || fail 'minimap should redraw after every movement'

: >"$tmp/directions"
printf 'w1:p2\n' >"$tmp/state"
HERDR_BIN_PATH="$tmp/herdr" \
HERDR_ACTIVE_PANE_ID='w1:p2' \
HERDR_FOCUS_HELPER="$tmp/focus" \
HERDR_TEST_DIRECTIONS="$tmp/directions" \
HERDR_TEST_STATE="$tmp/state" \
HERDR_TEST_ZOOMED=false \
  python3 "$root/herdr-pane-navigator.py" left >"$tmp/not-zoomed"
[ "$(cat "$tmp/directions")" = 'left' ] || fail 'normal tiled navigation should still move once'
[ ! -s "$tmp/not-zoomed" ] || fail 'normal tiled navigation should not draw or wait on the minimap'

printf 'PASS: Herdr popup pane navigator\n'
