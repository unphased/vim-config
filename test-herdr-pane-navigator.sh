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
    tab='w1:t1'
    [ "${HERDR_TEST_TRANSITION:-false}:$pane" != 'true:w1:p1' ] || tab='w1:t2'
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"w1"}}}\n' "$pane" "$tab"
    ;;
  'pane get w1:p1'|'pane get w1:p2')
    pane=${3}
    tab='w1:t1'
    [ "${HERDR_TEST_TRANSITION:-false}:$pane" != 'true:w1:p1' ] || tab='w1:t2'
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"w1"}}}\n' "$pane" "$tab"
    ;;
  'pane layout --pane w1:p1'|'pane layout --pane w1:p2')
    target=${4}
    pane=$(cat "$HERDR_TEST_STATE")
    tab='w1:t1'
    zoomed=${HERDR_TEST_ZOOMED:-true}
    if [ "${HERDR_TEST_TRANSITION:-false}" = true ]; then
      if [ "$target" = 'w1:p1' ]; then
        tab='w1:t2'
        zoomed=${HERDR_TEST_DEST_ZOOMED:-$zoomed}
      else
        pane='w1:p2'
        zoomed=${HERDR_TEST_SOURCE_ZOOMED:-$zoomed}
      fi
    fi
    if [ "${HERDR_TEST_SINGLE:-false}" = true ]; then
      panes='[{"pane_id":"w1:p1","rect":{"height":40,"width":100,"x":0,"y":0}}]'
      pane='w1:p1'
    else
      panes='[{"pane_id":"w1:p1","rect":{"height":40,"width":60,"x":0,"y":0}},{"pane_id":"w1:p2","rect":{"height":40,"width":40,"x":60,"y":0}}]'
    fi
    printf '{"result":{"layout":{"area":{"height":40,"width":100,"x":0,"y":0},"focused_pane_id":"%s","panes":%s,"tab_id":"%s","workspace_id":"w1","zoomed":%s}}}\n' \
      "$pane" "$panes" "$tab" "$zoomed"
    ;;
  'plugin pane open --plugin local.pane-navigator --entrypoint minimap --env HERDR_NAV_PANE_ID='*)
    printf '%s\n' "$*" >>"$HERDR_TEST_POPUPS"
    printf '{"result":{"ok":true}}\n'
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
: >"$tmp/directions"
: >"$tmp/popups"

run_navigator() {
  HERDR_BIN_PATH="$tmp/herdr" \
  HERDR_FOCUS_HELPER="$tmp/focus" \
  HERDR_TEST_DIRECTIONS="$tmp/directions" \
  HERDR_TEST_POPUPS="$tmp/popups" \
  HERDR_TEST_STATE="$tmp/state" \
    cargo run --quiet --manifest-path "$root/herdr-plugins/pane-navigator/Cargo.toml" -- "$@"
}

HERDR_PANE_ID='w1:p2' run_navigator left
[ "$(cat "$tmp/directions")" = 'left' ] || fail 'the action should move before showing the minimap'
grep -Fq 'HERDR_NAV_PANE_ID=w1:p1' "$tmp/popups" || fail 'zoomed multi-pane navigation should open the minimap'

: >"$tmp/directions"
printf 'w1:p1\n' >"$tmp/state"
printf '\014' | HERDR_NAV_PANE_ID='w1:p1' HERDR_MINIMAP_TIMEOUT=0.01 run_navigator popup >"$tmp/output"
[ "$(cat "$tmp/directions")" = 'right' ] || fail 'the popup should replay captured navigation before closing'
[ "$(cat "$tmp/state")" = 'w1:p2' ] || fail 'captured navigation should determine the focused pane'
for _ in {1..100}; do
  [ "$(wc -l <"$tmp/popups" | tr -d ' ')" -ge 2 ] && break
  sleep 0.01
done
[ "$(wc -l <"$tmp/popups" | tr -d ' ')" -eq 2 ] || fail 'captured navigation should reopen the resulting minimap'
tail -1 "$tmp/popups" | grep -Fq 'HERDR_NAV_PANE_ID=w1:p2' || fail 'reopened minimap should follow captured navigation'
grep -Fq 'Workspace w1  Tab w1:t1' "$tmp/output" || fail 'minimap context is missing'
grep -Fq '┌' "$tmp/output" || fail 'minimap border is missing'
[ "$(grep -o '●' "$tmp/output" | wc -l | tr -d ' ')" -eq 2 ] || fail 'the initial minimap should mark the focused box and include its legend'
[ "$(grep -o $'\033\[2J' "$tmp/output" | wc -l | tr -d ' ')" -eq 1 ] || fail 'captured navigation should close instead of redrawing the popup'

: >"$tmp/directions"
: >"$tmp/popups"
printf 'w1:p2\n' >"$tmp/state"
HERDR_PANE_ID='w1:p2' HERDR_TEST_ZOOMED=false run_navigator left
[ "$(cat "$tmp/directions")" = 'left' ] || fail 'normal tiled navigation should still move once'
[ ! -s "$tmp/popups" ] || fail 'normal tiled navigation should not open a popup'

: >"$tmp/directions"
: >"$tmp/popups"
printf 'w1:p1\n' >"$tmp/state"
HERDR_PANE_ID='w1:p1' HERDR_TEST_SINGLE=true run_navigator left
[ "$(cat "$tmp/directions")" = 'left' ] || fail 'single-pane navigation should still move once'
[ ! -s "$tmp/popups" ] || fail 'single-pane tabs should not open a popup'

: >"$tmp/directions"
: >"$tmp/popups"
printf 'w1:p2\n' >"$tmp/state"
HERDR_PANE_ID='w1:p2' HERDR_TEST_TRANSITION=true run_navigator left
grep -Fq 'HERDR_NAV_PREVIOUS_PANE_ID=w1:p2' "$tmp/popups" || fail 'tab transitions should retain the previous layout'
grep -Fq 'HERDR_NAV_TRANSITION_DIRECTION=left' "$tmp/popups" || fail 'tab transitions should retain their direction'
printf '' | \
  HERDR_NAV_PANE_ID='w1:p1' \
  HERDR_NAV_PREVIOUS_PANE_ID='w1:p2' \
  HERDR_NAV_TRANSITION_DIRECTION=left \
  HERDR_TEST_TRANSITION=true \
  run_navigator popup >"$tmp/transition-output"
grep -Fq '← previous' "$tmp/transition-output" || fail 'transition minimap should label the previous layout with an arrow'
[ "$(grep -o '←' "$tmp/transition-output" | wc -l | tr -d ' ')" -eq 2 ] || fail 'transition arrow should replace the current-pane dot'

: >"$tmp/directions"
: >"$tmp/popups"
printf 'w1:p2\n' >"$tmp/state"
HERDR_PANE_ID='w1:p2' \
HERDR_TEST_TRANSITION=true \
HERDR_TEST_SOURCE_ZOOMED=false \
HERDR_TEST_DEST_ZOOMED=true \
  run_navigator left
grep -Fq 'HERDR_NAV_PANE_ID=w1:p1' "$tmp/popups" || fail 'entering a zoomed tab should open its minimap'
if grep -Fq 'HERDR_NAV_PREVIOUS_PANE_ID' "$tmp/popups"; then
  fail 'entering a zoomed tab should show current state rather than previous state'
fi
printf '' | \
  HERDR_NAV_PANE_ID='w1:p1' \
  HERDR_TEST_TRANSITION=true \
  HERDR_TEST_DEST_ZOOMED=true \
  run_navigator popup >"$tmp/enter-output"
grep -Fq '● current' "$tmp/enter-output" || fail 'entered zoomed tab should mark its current pane'

printf 'PASS: Herdr Rust popup pane navigator\n'
