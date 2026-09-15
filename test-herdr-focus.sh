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
    cat <<'JSON'
{"result":{"workspaces":[
  {"workspace_id":"w-parent","number":2,"worktree":{"repo_key":"/repo/.git","is_linked_worktree":false}},
  {"workspace_id":"w-other","number":3},
  {"workspace_id":"w-child-a","number":7,"worktree":{"repo_key":"/repo/.git","is_linked_worktree":true}},
  {"workspace_id":"w-child-b","number":9,"worktree":{"repo_key":"/repo/.git","is_linked_worktree":true}},
  {"workspace_id":"w-final","number":10}
]}}
JSON
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

run_focus() {
  : >"$tmp/args"
  : >"$tmp/focus"
  HERDR_TEST_ARGS="$tmp/args" \
  HERDR_TEST_FOCUS="$tmp/focus" \
  HERDR_TEST_WORKSPACE="${2:-w-parent}" \
  PATH="$tmp:$PATH" \
    "$root/herdr-focus.sh" "$1"
  cat "$tmp/focus"
}

[ "$(run_focus down)" = 'workspace focus w-child-a' ] || fail 'down from parent should enter its first child'
[ -z "$(run_focus up)" ] || fail 'up from parent should remain at the boundary'
[ "$(run_focus up w-child-a)" = 'workspace focus w-parent' ] || fail 'up from a child should return to the parent'
[ "$(run_focus down w-child-a)" = 'workspace focus w-child-b' ] || fail 'down from a child should enter the next sibling'
[ "$(run_focus down w-child-b)" = 'workspace focus w-other' ] || fail 'down from the last child should leave the project group'

printf 'PASS: Herdr workspace navigation order\n'
