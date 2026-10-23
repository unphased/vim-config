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
    printf '{"result":{"pane":{"pane_id":"w-parent:p1","tab_id":"%s","workspace_id":"%s"}}}\n' \
      "${HERDR_TEST_TAB:-w-parent:t2}" "$HERDR_TEST_WORKSPACE"
    ;;
  'pane edges --pane w-parent:p1')
    printf '%s\n' '{"result":{"edges":{"up":true,"down":true,"left":false,"right":false}}}'
    ;;
  'tab list --workspace w-parent')
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w-parent:t1","number":1},{"tab_id":"w-parent:t2","number":2},{"tab_id":"w-parent:t3","number":3}]}}'
    ;;
  'tab list --workspace w-child-a')
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w-child-a:t1","number":1},{"tab_id":"w-child-a:t2","number":2}]}}'
    ;;
  'tab list --workspace w-child-b')
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w-child-b:t1","number":1}]}}'
    ;;
  'tab list --workspace w-other')
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w-other:t1","number":1}]}}'
    ;;
  'tab list --workspace w-final')
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w-final:t1","number":1}]}}'
    ;;
  'tab focus '*)
    [ "${HERDR_TEST_FAIL_FOCUS:-0}" != 1 ] || exit 1
    printf '%s\n' "$*" >>"$HERDR_TEST_FOCUS"
    ;;
  'workspace list')
    markers=
    [ ! -r "$HERDR_TEST_MARKER" ] || markers=$(cat "$HERDR_TEST_MARKER")
    jq -nc --arg markers "$markers" '
      ($markers | split("\n")) as $marked |
      {result: {workspaces: [
        {workspace_id:"w-parent", number:2, worktree:{repo_key:"/repo/.git", is_linked_worktree:false}},
        {workspace_id:"w-other", number:3},
        {workspace_id:"w-child-a", number:7, worktree:{repo_key:"/repo/.git", is_linked_worktree:true}},
        {workspace_id:"w-child-b", number:9, worktree:{repo_key:"/repo/.git", is_linked_worktree:true}},
        {workspace_id:"w-final", number:10}
      ] | map(.active_tab_id = (if .workspace_id == "w-parent" then "w-parent:t2" else .workspace_id + ":t1" end)
        | . as $workspace | if ($marked | index($workspace.workspace_id)) then . + {tokens:{ctrl_tab_target:"↩"}} else . end)}}' |
      jq --slurpfile metadata "$HERDR_TEST_METADATA" '
        .result.workspaces |= map(.tokens = ((.tokens // {}) + ($metadata[0][.workspace_id] // {})))'
    ;;
  'workspace report-metadata '*)
    metadata_workspace=$3
    shift 5
    while [ "$#" -gt 0 ]; do
      option=$1 value=$2
      shift 2
      case "$option:$value" in
        '--token:ctrl_tab_target=↩')
          grep -Fxq "$metadata_workspace" "$HERDR_TEST_MARKER" 2>/dev/null \
            || printf '%s\n' "$metadata_workspace" >>"$HERDR_TEST_MARKER"
          ;;
        '--clear-token:ctrl_tab_target')
          grep -Fxv "$metadata_workspace" "$HERDR_TEST_MARKER" >"$HERDR_TEST_MARKER.tmp" || :
          mv "$HERDR_TEST_MARKER.tmp" "$HERDR_TEST_MARKER"
          ;;
        '--token:ctrl_tab_history='*|'--token:ctrl_tab_fallback='*)
          jq --arg workspace "$metadata_workspace" --arg key "${value%%=*}" --arg value "${value#*=}" \
            '.[$workspace][$key] = $value' "$HERDR_TEST_METADATA" >"$HERDR_TEST_METADATA.tmp"
          mv "$HERDR_TEST_METADATA.tmp" "$HERDR_TEST_METADATA"
          ;;
        '--clear-token:ctrl_tab_history'|'--clear-token:ctrl_tab_fallback')
          jq --arg workspace "$metadata_workspace" --arg key "$value" 'del(.[$workspace][$key])' \
            "$HERDR_TEST_METADATA" >"$HERDR_TEST_METADATA.tmp"
          mv "$HERDR_TEST_METADATA.tmp" "$HERDR_TEST_METADATA"
          ;;
        *) printf 'unexpected metadata option: %s %s\n' "$option" "$value" >&2; exit 1 ;;
      esac
    done
    ;;
  'workspace focus w-child-a'|'workspace focus w-child-b'|'workspace focus w-parent'|'workspace focus w-other'|'workspace focus w-final')
    [ "${HERDR_TEST_FAIL_FOCUS:-0}" != 1 ] || exit 1
    printf '%s\n' "$*" >>"$HERDR_TEST_FOCUS"
    ;;
  *)
    printf 'unexpected herdr command: %s\n' "$*" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$tmp/herdr"

set_marker() {
  : >"$tmp/marker"
  printf '{}\n' >"$tmp/metadata"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >"$tmp/marker"
}

set_history() {
  set_marker "$1"
  jq -nc --arg workspace "$1" --arg history "$2" \
    '{($workspace): {ctrl_tab_history: $history}}' >"$tmp/metadata"
}

run_focus() {
  : >"$tmp/args"
  : >"$tmp/focus"
  HERDR_TEST_ARGS="$tmp/args" \
  HERDR_TEST_FOCUS="$tmp/focus" \
  HERDR_TEST_MARKER="$tmp/marker" \
  HERDR_TEST_METADATA="$tmp/metadata" \
  HERDR_TEST_WORKSPACE="${2:-w-parent}" \
  HERDR_TEST_TAB="${3:-w-parent:t2}" \
  HERDR_WORKSPACE_TOGGLE_LOCK="$tmp/toggle-lock" \
  PATH="$tmp:$PATH" \
    "$root/herdr-focus.sh" "$1" || return
  cat "$tmp/focus"
}

set_marker w-final
[ "$(run_focus previous-tab w-parent w-parent:t2)" = 'tab focus w-parent:t1' ] || fail 'previous-tab should focus the adjacent lower-numbered tab'
[ "$(run_focus next-tab w-parent w-parent:t2)" = 'tab focus w-parent:t3' ] || fail 'next-tab should focus the adjacent higher-numbered tab'
[ "$(run_focus previous-tab w-child-a w-child-a:t1)" = 'tab focus w-parent:t3' ] || fail 'previous-tab should cross up to the previous workspace last tab'
[ "$(run_focus next-tab w-parent w-parent:t3)" = 'tab focus w-child-a:t1' ] || fail 'next-tab should cross down to the next workspace first tab'
[ "$(run_focus next-tab w-child-a w-child-a:t2)" = 'tab focus w-child-b:t1' ] || fail 'tab navigation should respect grouped workspace ordering'
result=$(run_focus previous-tab w-parent w-parent:t1) || fail 'the global beginning must be a successful no-op'
[ -z "$result" ] || fail 'previous-tab should not wrap at the global beginning'
result=$(run_focus next-tab w-final w-final:t1) || fail 'the global end must be a successful no-op'
[ -z "$result" ] || fail 'next-tab should not wrap at the global end'
! grep -q 'pane edges' "$tmp/args" || fail 'linear tab navigation must not inspect pane edges'

[ "$(run_focus down)" = 'workspace focus w-child-a' ] || fail 'down from parent should enter its first child'
[ "$(cat "$tmp/marker")" = w-final ] || fail 'directional navigation must not change the toggle target'
! grep -q 'workspace report-metadata' "$tmp/args" || fail 'directional navigation must not touch toggle metadata'
[ -z "$(run_focus up)" ] || fail 'up from parent should remain at the boundary'
[ "$(run_focus up w-child-a)" = 'workspace focus w-parent' ] || fail 'up from a child should return to the parent'
[ "$(run_focus down w-child-b)" = 'workspace focus w-other' ] || fail 'down from the last child should leave the project group'

set_marker w-final
[ "$(run_focus toggle)" = 'workspace focus w-final' ] || fail 'toggle should focus the yellow-arrow workspace'
[ "$(cat "$tmp/marker")" = w-parent ] || fail 'toggle should move the yellow arrow to its source workspace'
jq -e '."w-final".ctrl_tab_fallback == "↩"' "$tmp/metadata" >/dev/null \
  || fail 'toggle should mark the historical fallback workspace'
grep -q 'workspace report-metadata w-parent --source workspace-toggle --token ctrl_tab_target=↩' "$tmp/args" \
  || fail 'toggle should mark its source workspace'
grep -q 'workspace report-metadata w-final --source workspace-toggle --clear-token ctrl_tab_target' "$tmp/args" \
  || fail 'toggle should clear its former target marker'

[ "$(run_focus toggle w-final w-final:t1)" = 'tab focus w-parent:t2' ] || fail 'second toggle should restore the exact source tab'
[ "$(cat "$tmp/marker")" = w-final ] || fail 'second toggle should return the arrow to the prior workspace'
jq -e '."w-parent".ctrl_tab_fallback == "↩" and ."w-final".ctrl_tab_fallback == null' "$tmp/metadata" >/dev/null \
  || fail 'second toggle should move the fallback marker and clear its old slot'
run_focus toggle w-other w-other:t1 >/dev/null
jq -e '[to_entries[] | select(.value.ctrl_tab_fallback == "↩") | .key] == ["w-final"]' \
  "$tmp/metadata" >/dev/null || fail 'a third workspace must not leave stale fallback glyphs'

set_marker w-final
[ "$(run_focus toggle w-other)" = 'workspace focus w-final' ] || fail 'ordinary navigation must not change the sticky target'
[ "$(cat "$tmp/marker")" = w-other ] || fail 'toggle after ordinary navigation should remember only its source'

# Establish two exact return points, then reach the primary one without toggling.
set_marker
run_focus toggle w-parent w-parent:t2 >/dev/null
jq -e '."w-parent".ctrl_tab_history | fromjson ==
  [{workspace:"w-parent",tab:"w-parent:t2"},{workspace:"w-child-a",tab:"w-child-a:t1"}]' \
  "$tmp/metadata" >/dev/null || fail 'bootstrap should save both exact endpoints'
[ "$(run_focus toggle w-parent w-parent:t2)" = 'tab focus w-child-a:t1' ] \
  || fail 'bootstrap destination should retain its original tab as the older return point'
run_focus toggle w-child-a w-child-a:t2 >/dev/null
[ "$(run_focus toggle w-child-a w-child-a:t2)" = 'tab focus w-parent:t2' ] \
  || fail 'already on the primary return point should use the older workspace and tab'
[ "$(run_focus toggle w-parent w-parent:t2)" = 'tab focus w-child-a:t2' ] \
  || fail 'fallback should still allow repeated back-and-forth toggling'

# Two return points may be different tabs of the same workspace.
[ "$(run_focus toggle w-parent w-parent:t3)" = 'tab focus w-parent:t2' ] \
  || fail 'same-workspace history should restore its saved tab'
[ "$(run_focus toggle w-parent w-parent:t3)" = 'tab focus w-parent:t2' ] \
  || fail 'already on the primary tab should select the older tab in that workspace'
jq -e '."w-parent".ctrl_tab_fallback == "↩"' "$tmp/metadata" >/dev/null \
  || fail 'same-workspace history should retain the fallback glyph too'

set_marker w-other
[ "$(run_focus toggle w-other w-other:t1)" = 'workspace focus w-child-b' ] \
  || fail 'a legacy self-target without history should bootstrap rather than no-op'

set_history w-parent '[{"workspace":"w-parent","tab":"w-parent:closed"},{"workspace":"w-final","tab":"w-final:t1"}]'
[ "$(run_focus toggle)" = 'tab focus w-final:t1' ] \
  || fail 'closed tab in the current workspace should not block the older return point'

set_history w-parent '[{"workspace":"w-parent","tab":"w-parent:closed"},{"workspace":"w-final","tab":"w-final:t1"}]'
[ "$(run_focus toggle w-other w-other:t1)" = 'workspace focus w-parent' ] \
  || fail 'closed tab in another workspace should fall back to workspace focus'

set_history w-parent '[{"workspace":"closed-workspace","tab":"closed-tab"},{"workspace":"w-final","tab":"w-final:t1"}]'
[ "$(run_focus toggle)" = 'tab focus w-final:t1' ] \
  || fail 'closed workspace should not block the older return point'

set_history w-final 'not json'
[ "$(run_focus toggle)" = 'workspace focus w-final' ] \
  || fail 'malformed history should fall back to the visible workspace bookmark'

set_history w-final '[{"workspace":"w-final","tab":"w-final:t1"},{"workspace":"w-parent","tab":"w-parent:t2"}]'
before=$(cat "$tmp/metadata")
if HERDR_TEST_FAIL_FOCUS=1 run_focus toggle; then
  fail 'focus failure should propagate'
fi
[ "$(cat "$tmp/metadata")" = "$before" ] || fail 'failed focus must preserve history'
[ "$(cat "$tmp/marker")" = w-final ] || fail 'failed focus must preserve the visible bookmark'
! grep -q 'report-metadata' "$tmp/args" || fail 'failed focus must not mutate metadata'


set_marker w-parent w-final
[ "$(run_focus toggle)" = 'workspace focus w-final' ] || fail 'toggle should recover a duplicate marker by choosing the noncurrent target'
[ "$(cat "$tmp/marker")" = w-parent ] || fail 'toggle should reconcile duplicate markers to its source'

set_marker
[ "$(run_focus toggle)" = 'workspace focus w-child-a' ] || fail 'toggle without an arrow should bootstrap to an adjacent workspace'
[ "$(cat "$tmp/marker")" = w-parent ] || fail 'bootstrap toggle should mark its source workspace'

printf 'PASS: Herdr workspace/tab navigation and two-point toggle history\n'
