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

printf '[ui]\nsidebar_max_width = 60 # cap\nsidebar_width = 36\n[ui.sidebar.agents]\nrow_gap = 0\n' >"$HERDR_CONFIG_PATH"
cp "$HERDR_CONFIG_PATH" "$tmp/original"
resize shrink
grep -qx 'sidebar_max_width = 56 # cap' "$HERDR_CONFIG_PATH" || fail shrink
resize reset
sed 's/60 # cap/48 # cap/' "$tmp/original" >"$tmp/expected"
cmp "$HERDR_CONFIG_PATH" "$tmp/expected" || fail 'unrelated config changed'
[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" = 2 ] || fail 'reload count'
grep -qx 'server reload-config' "$CALL_LOG" || fail 'reload command'

printf '[ui]\nsidebar_min_width = 24\nsidebar_max_width = 25\n' >"$HERDR_CONFIG_PATH"
resize shrink
grep -qx 'sidebar_max_width = 24' "$HERDR_CONFIG_PATH" || fail floor
# Repeated floor/reset presses should not reload an unchanged config.
cp "$CALL_LOG" "$tmp/calls-before"
resize shrink
cmp "$CALL_LOG" "$tmp/calls-before" || fail 'floor caused unnecessary reload'
printf '[ui]\nsidebar_max_width = 65534\n' >"$HERDR_CONFIG_PATH"
resize reset
grep -qx 'sidebar_max_width = 48' "$HERDR_CONFIG_PATH" || fail reset
cp "$CALL_LOG" "$tmp/calls-before"
resize reset
cmp "$CALL_LOG" "$tmp/calls-before" || fail 'reset caused unnecessary reload'
printf '[ui]\nsidebar_min_width = 50\nsidebar_max_width = 60\n' >"$HERDR_CONFIG_PATH"
resize reset
grep -qx 'sidebar_max_width = 50' "$HERDR_CONFIG_PATH" || fail 'reset violated minimum'

# Missing keys and sections use Herdr defaults; insertion stays in [ui].
printf '[ui]\nsidebar_width = 26\n[ui.sidebar.agents]\nrow_gap = 0\n' >"$HERDR_CONFIG_PATH"
resize shrink
grep -qx 'sidebar_max_width = 32' "$HERDR_CONFIG_PATH" || fail default
awk '/^sidebar_max_width/ { found=1 } /^\[ui.sidebar.agents\]/ { exit !found }' "$HERDR_CONFIG_PATH" || fail 'wrong section'
printf '[theme]\nname = "catppuccin"\n' >"$HERDR_CONFIG_PATH"
resize shrink
grep -qx '\[ui\]' "$HERDR_CONFIG_PATH" || fail 'missing ui section'
grep -qx 'sidebar_max_width = 32' "$HERDR_CONFIG_PATH" || fail 'missing max setting'

mv "$HERDR_CONFIG_PATH" "$tmp/target.toml"
ln -s "$tmp/target.toml" "$HERDR_CONFIG_PATH"
resize reset
[ -L "$HERDR_CONFIG_PATH" ] || fail 'symlink replaced'
grep -qx 'sidebar_max_width = 48' "$tmp/target.toml" || fail 'symlink target not updated'

cp "$HERDR_CONFIG_PATH" "$tmp/original"
if resize bogus 2>/dev/null; then fail 'invalid direction accepted'; fi
cmp "$HERDR_CONFIG_PATH" "$tmp/original" || fail 'invalid direction wrote config'
printf '[ui]\nsidebar_max_width = "invalid"\n' >"$HERDR_CONFIG_PATH"
cp "$HERDR_CONFIG_PATH" "$tmp/original"
if resize reset 2>/dev/null; then fail 'invalid width accepted'; fi
cmp "$HERDR_CONFIG_PATH" "$tmp/original" || fail 'invalid width wrote config'

printf '[ui]\nsidebar_max_width = 36\n' >"$HERDR_CONFIG_PATH"
export RELOAD_EXIT=7
if resize reset; then fail 'reload failure ignored'; else [ "$?" = 7 ] || fail 'wrong failure status'; fi
unset RELOAD_EXIT

# Rapid detached commands must not lose decrements.
printf '[ui]\nsidebar_max_width = 60\n' >"$HERDR_CONFIG_PATH"
pids=()
for ((i=0; i<8; i++)); do resize shrink & pids+=("$!"); done
for pid in "${pids[@]}"; do wait "$pid"; done
grep -qx 'sidebar_max_width = 28' "$HERDR_CONFIG_PATH" || fail 'concurrent updates lost'

for direction in shrink reset; do
  grep -Fq "command = \"~/.vim/herdr-sidebar-resize.sh $direction\"" "$root/herdr.toml" || fail 'missing binding'
done
for key in ctrl+comma prefix+comma; do
  grep -F -A2 "key = \"$key\"" "$root/herdr.toml" | grep -Fq 'herdr-sidebar-resize.sh shrink' || fail "$key binding"
done
grep -F -A2 'key = "prefix+period"' "$root/herdr.toml" | grep -Fq 'herdr-sidebar-resize.sh reset' || fail 'reset binding'
printf 'PASS: Herdr sidebar resize (background shell, preservation, bounds, concurrency)\n'
