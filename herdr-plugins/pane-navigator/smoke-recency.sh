#!/bin/sh
# E2E: Ctrl-Tab recency against a throwaway headless Herdr session.
# Simulates the tab_focused hook by calling `observe` after each focus change.
set -eu

bin=$(cd "$(dirname "$0")" && pwd)/target/release/herdr-pane-navigator
session=recency-smoke-$$
unset HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH
herdr --session "$session" server >/dev/null 2>&1 &
cleanup() {
  herdr session stop "$session" >/dev/null 2>&1 || :
  herdr session delete "$session" >/dev/null 2>&1 || :
}
trap cleanup EXIT

HERDR_SOCKET_PATH=$HOME/.config/herdr/sessions/$session/herdr.sock
export HERDR_SOCKET_PATH
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  herdr workspace list >/dev/null 2>&1 && break
  sleep 0.1
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
here() { herdr pane current | jq -r '.result.pane.tab_id'; }
visit() { # TAB: focus it, then fire the hook the way Herdr would
  herdr tab focus "$1" >/dev/null
  HERDR_PLUGIN_EVENT_JSON=$(herdr pane current | jq -c '{data: (.result.pane | {workspace_id, tab_id})}') "$bin" observe
}
state() { jq -c . "$(dirname "$HERDR_SOCKET_PATH")/pane-navigator-recency.json"; }
marked() { herdr workspace list | jq -r '[.result.workspaces[] | select(.tokens.ctrl_tab_target? == "↩") | .workspace_id] | join(",")'; }

w2=$(herdr workspace create --no-focus | jq -r '.result.workspace.workspace_id')
w3=$(herdr workspace create --no-focus | jq -r '.result.workspace.workspace_id')

visit w1:t1
sleep 2.1                    # dwell on w1
visit "$w2:t1"
visit "$w3:t1"               # w2 was only passed through
[ "$(state | jq -r .prev.workspace)" = w1 ] || fail "transit: $(state)"
[ "$(marked)" = w1 ] || fail "sidebar mark: $(marked)"

"$bin" toggle
[ "$(here)" = w1:t1 ] || fail "toggle 1 landed on $(here)"
"$bin" toggle                # immediate second press flips back
[ "$(here)" = "$w3:t1" ] || fail "toggle 2 landed on $(here)"
[ "$(marked)" = w1 ] || fail "sidebar mark after toggles: $(marked)"

t2=$(herdr tab create --workspace w1 --no-focus | jq -r '.result.tab.tab_id')
"$bin" toggle; visit "$t2"; "$bin" toggle; "$bin" toggle
[ "$(here)" = "$t2" ] || fail "exact tab return landed on $(here)"

printf 'recency smoke: ok\n'
