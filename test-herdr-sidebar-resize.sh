#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cat >"$tmp/herdr" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >>"$CALL_LOG"
exit "${RELOAD_EXIT:-0}"
MOCK
chmod +x "$tmp/herdr"
export HERDR_CONFIG_PATH="$tmp/config.toml" HERDR_BIN_PATH="$tmp/herdr" CALL_LOG="$tmp/calls"

resize() {
  # Use the actual background-command shell, not the interactive environment.
  /bin/sh -lc '"$1/herdr-sidebar-resize.sh" "$2"' sidebar-test "$root" "$1"
}
widths() {
  for pair in "width $1" "min_width $2" "max_width $3"; do
    grep -Eq "^sidebar_${pair% *} = ${pair##* }( #.*)?$" "$HERDR_CONFIG_PATH" || fail "expected sidebar_$pair"
  done
}
reloads() { wc -l <"$CALL_LOG" | tr -d ' '; }

printf '[ui]\nsidebar_max_width = 48 # cap\nsidebar_width = 36\n[ui.sidebar.agents]\nrow_gap = 0\n' >"$HERDR_CONFIG_PATH"
resize shrink
widths 32 32 32
resize grow
widths 36 36 36
[ "$(reloads)" = 2 ] || fail 'reload count'
grep -qx 'server reload-config' "$CALL_LOG" || fail 'reload command'
grep -qx 'sidebar_max_width = 36 # cap' "$HERDR_CONFIG_PATH" || fail 'comment lost'
grep -qx '\[ui.sidebar.agents\]' "$HERDR_CONFIG_PATH" || fail 'unrelated section lost'
grep -qx 'row_gap = 0' "$HERDR_CONFIG_PATH" || fail 'unrelated setting lost'

output=$(resize toggle)
widths 36 18 48
grep -Fq 'Mouse resizing enabled' <<<"$output" || fail 'mouse popup status'
output=$(resize toggle)
widths 36 36 36
grep -Fq 'Pinned: 36 columns' <<<"$output" || fail 'pinned popup status'
# Adjustments automatically pin even from mouse mode; remembered width survives toggles.
resize toggle >/dev/null
resize grow
widths 40 40 40
resize toggle >/dev/null
widths 40 18 48
resize shrink
widths 36 36 36

printf '[ui]\nsidebar_width = 18\nsidebar_min_width = 18\nsidebar_max_width = 18\n' >"$HERDR_CONFIG_PATH"
cp "$CALL_LOG" "$tmp/calls-before"
resize shrink
widths 18 18 18
cmp "$CALL_LOG" "$tmp/calls-before" || fail 'floor caused unnecessary reload'
printf '[ui]\nsidebar_width = 65534\n' >"$HERDR_CONFIG_PATH"
resize grow
widths 65535 65535 65535
cp "$CALL_LOG" "$tmp/calls-before"
resize grow
cmp "$CALL_LOG" "$tmp/calls-before" || fail 'ceiling caused unnecessary reload'

# Missing keys/sections use the default width (26); insertion stays in [ui].
printf '[ui]\n[ui.sidebar.agents]\nrow_gap = 0\n' >"$HERDR_CONFIG_PATH"
resize shrink
widths 22 22 22
awk '/^sidebar_max_width/ { found=1 } /^\[ui.sidebar.agents\]/ { exit !found }' "$HERDR_CONFIG_PATH" || fail 'wrong section'
printf '[theme]\nname = "catppuccin"\n' >"$HERDR_CONFIG_PATH"
resize grow
widths 30 30 30
grep -qx '\[ui\]' "$HERDR_CONFIG_PATH" || fail 'missing ui section'

mv "$HERDR_CONFIG_PATH" "$tmp/target.toml"
ln -s "$tmp/target.toml" "$HERDR_CONFIG_PATH"
resize shrink
[ -L "$HERDR_CONFIG_PATH" ] || fail 'symlink replaced'
widths 26 26 26

cp "$HERDR_CONFIG_PATH" "$tmp/original"
if resize bogus 2>/dev/null; then fail 'invalid direction accepted'; fi
cmp "$HERDR_CONFIG_PATH" "$tmp/original" || fail 'invalid direction wrote config'
for key in width min_width max_width; do
  printf '[ui]\nsidebar_%s = "invalid"\n' "$key" >"$HERDR_CONFIG_PATH"
  cp "$HERDR_CONFIG_PATH" "$tmp/original"
  if resize grow 2>/dev/null; then fail "invalid $key accepted"; fi
  cmp "$HERDR_CONFIG_PATH" "$tmp/original" || fail 'invalid width wrote config'
done

printf '[ui]\nsidebar_width = 36\n' >"$HERDR_CONFIG_PATH"
export RELOAD_EXIT=7
if output=$(resize toggle); then fail 'reload failure ignored'; else [ "$?" = 7 ] || fail 'wrong failure status'; fi
[ -z "$output" ] || fail 'success popup shown on reload failure'
unset RELOAD_EXIT

# Rapid detached commands must not lose decrements.
printf '[ui]\nsidebar_width = 60\n' >"$HERDR_CONFIG_PATH"
pids=()
for ((i=0; i<8; i++)); do resize shrink & pids+=("$!"); done
for pid in "${pids[@]}"; do wait "$pid"; done
widths 28 28 28

python3 - "$root/herdr.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    commands = {entry['key']: entry for entry in tomllib.load(f)['keys']['command']}
for key, action in [('prefix+comma', 'shrink'), ('prefix+period', 'grow'), ('prefix+semicolon', 'toggle')]:
    entry = commands[key]
    assert entry['command'] == f'~/.vim/herdr-sidebar-resize.sh {action}', entry
    assert entry['type'] == ('popup' if action == 'toggle' else 'shell'), entry
assert 'ctrl+comma' not in commands
PY
printf 'PASS: Herdr sidebar pinned/mouse sizing (popup status, bounds, preservation, concurrency)\n'
