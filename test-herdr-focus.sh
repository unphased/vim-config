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
    printf '{"result":{"pane":{"pane_id":"w-parent:p1","tab_id":"w-parent:t1","workspace_id":"%s"}}}\n' "$HERDR_TEST_WORKSPACE"
    ;;
  'pane edges --pane w-parent:p1')
    printf '%s\n' '{"result":{"edges":{"up":true,"down":true,"left":false,"right":false}}}'
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
      ] | map(. as $workspace | if ($marked | index($workspace.workspace_id)) then . + {tokens:{ctrl_tab_target:"↩"}} else . end)}}'
    ;;
  'workspace report-metadata '*)
    metadata_workspace=$3
    case "${6:-}:${7:-}" in
      '--token:ctrl_tab_target=↩')
        grep -Fxq "$metadata_workspace" "$HERDR_TEST_MARKER" 2>/dev/null \
          || printf '%s\n' "$metadata_workspace" >>"$HERDR_TEST_MARKER"
        ;;
      '--clear-token:ctrl_tab_target')
        grep -Fxv "$metadata_workspace" "$HERDR_TEST_MARKER" >"$HERDR_TEST_MARKER.tmp" || :
        mv "$HERDR_TEST_MARKER.tmp" "$HERDR_TEST_MARKER"
        ;;
      *) printf 'unexpected metadata command: %s\n' "$*" >&2; exit 1 ;;
    esac
    ;;
  'workspace focus w-child-a'|'workspace focus w-child-b'|'workspace focus w-parent'|'workspace focus w-other'|'workspace focus w-final')
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
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >"$tmp/marker"
}

run_focus() {
  : >"$tmp/args"
  : >"$tmp/focus"
  HERDR_TEST_ARGS="$tmp/args" \
  HERDR_TEST_FOCUS="$tmp/focus" \
  HERDR_TEST_MARKER="$tmp/marker" \
  HERDR_TEST_WORKSPACE="${2:-w-parent}" \
  HERDR_WORKSPACE_TOGGLE_LOCK="$tmp/toggle-lock" \
  PATH="$tmp:$PATH" \
    "$root/herdr-focus.sh" "$1"
  cat "$tmp/focus"
}

set_marker w-final
[ "$(run_focus down)" = 'workspace focus w-child-a' ] || fail 'down from parent should enter its first child'
[ "$(cat "$tmp/marker")" = w-final ] || fail 'directional navigation must not change the toggle target'
! grep -q 'workspace report-metadata' "$tmp/args" || fail 'directional navigation must not touch toggle metadata'
[ -z "$(run_focus up)" ] || fail 'up from parent should remain at the boundary'
[ "$(run_focus up w-child-a)" = 'workspace focus w-parent' ] || fail 'up from a child should return to the parent'
[ "$(run_focus down w-child-b)" = 'workspace focus w-other' ] || fail 'down from the last child should leave the project group'

set_marker w-final
[ "$(run_focus toggle)" = 'workspace focus w-final' ] || fail 'toggle should focus the yellow-arrow workspace'
[ "$(cat "$tmp/marker")" = w-parent ] || fail 'toggle should move the yellow arrow to its source workspace'
grep -q 'workspace report-metadata w-parent --source workspace-toggle --token ctrl_tab_target=↩' "$tmp/args" \
  || fail 'toggle should mark its source workspace'
grep -q 'workspace report-metadata w-final --source workspace-toggle --clear-token ctrl_tab_target' "$tmp/args" \
  || fail 'toggle should clear its former target marker'

[ "$(run_focus toggle w-final)" = 'workspace focus w-parent' ] || fail 'second toggle should swap back'
[ "$(cat "$tmp/marker")" = w-final ] || fail 'second toggle should return the arrow to the prior workspace'

set_marker w-final
[ "$(run_focus toggle w-other)" = 'workspace focus w-final' ] || fail 'ordinary navigation must not change the sticky target'
[ "$(cat "$tmp/marker")" = w-other ] || fail 'toggle after ordinary navigation should remember only its source'

set_marker w-other
[ -z "$(run_focus toggle w-other)" ] || fail 'toggle should do nothing when the arrow is already current'
[ "$(cat "$tmp/marker")" = w-other ] || fail 'self-targeting toggle must preserve the sticky target'
! grep -q 'workspace focus' "$tmp/args" || fail 'self-targeting toggle must not focus another workspace'

set_marker w-parent w-final
[ "$(run_focus toggle)" = 'workspace focus w-final' ] || fail 'toggle should recover a duplicate marker by choosing the noncurrent target'
[ "$(cat "$tmp/marker")" = w-parent ] || fail 'toggle should reconcile duplicate markers to its source'

set_marker
[ "$(run_focus toggle)" = 'workspace focus w-child-a' ] || fail 'toggle without an arrow should bootstrap to an adjacent workspace'
[ "$(cat "$tmp/marker")" = w-parent ] || fail 'bootstrap toggle should mark its source workspace'

printf 'PASS: Herdr workspace navigation and sticky toggle\n'
