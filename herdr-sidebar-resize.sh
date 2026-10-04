#!/bin/sh

case "${1:-}" in
  shrink) delta=-4 ;;
  grow) delta=4 ;;
  toggle) delta=0 ;;
  *) printf 'usage: %s {shrink|grow|toggle}\n' "$0" >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || exit 2

config=${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}
herdr=${HERDR_BIN_PATH:-herdr}
lock=$config.sidebar-resize.lock
# Detached keybind commands can overlap. Serialize the edit and reload.
tries=0
until mkdir "$lock" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 100 ] || { printf 'sidebar resize: cannot lock %s\n' "$config" >&2; exit 1; }
  sleep 0.05
done
tmp=''
trap 'rm -f "$tmp"; rmdir "$lock"' EXIT
trap 'exit 1' HUP INT TERM
tmp=$(mktemp "$config.sidebar-resize.XXXXXX") || exit

awk -v delta="$delta" -v action="$1" '
function width(line, value) {
  value = line
  sub(/^[^=]*=[ \t]*/, "", value)
  sub(/[ \t]*(#.*)?$/, "", value)
  gsub(/_/, "", value)
  if (value !~ /^[0-9]+$/ || value + 0 > 65535) {
    print "sidebar resize: invalid width: " line > "/dev/stderr"
    failed = 1
    exit 2
  }
  return value + 0
}
function insert_missing() {
  for (k = 1; k <= 3; k++)
    if (!keyline[keys[k]]) print keys[k] " = " values[keys[k]]
}
BEGIN {
  preferred = 26; minimum = 18; maximum = 36
  keys[1] = "sidebar_width"
  keys[2] = "sidebar_min_width"
  keys[3] = "sidebar_max_width"
}
{
  lines[NR] = $0
  if ($0 ~ /^[ \t]*\[ui\][ \t]*(#.*)?$/) { ui = 1; found = 1 }
  else if (ui && $0 ~ /^[ \t]*\[/) { ui = 0; end = NR }
  if (ui && $0 ~ /^[ \t]*sidebar_(width|min_width|max_width)[ \t]*=/) {
    key = $0
    sub(/^[ \t]*/, "", key)
    sub(/[ \t]*=.*/, "", key)
    values[key] = width($0)
    keyline[key] = NR
    linekey[NR] = key
    if (key == "sidebar_width") preferred = values[key]
    if (key == "sidebar_min_width") minimum = values[key]
    if (key == "sidebar_max_width") maximum = values[key]
  }
}
END {
  if (failed) exit 2
  pinned = !(action == "toggle" && minimum == maximum)
  if (pinned) {
    preferred += delta
    if (preferred < 18) preferred = 18
    if (preferred > 65535) preferred = 65535
    minimum = maximum = preferred
  } else {
    # Mouse mode restores the normal loose bounds; keep the last pinned width.
    minimum = 18; maximum = 48
  }
  values["sidebar_width"] = preferred
  values["sidebar_min_width"] = minimum
  values["sidebar_max_width"] = maximum
  if (!end) end = NR + 1
  for (i = 1; i <= NR; i++) {
    if (found && i == end) insert_missing()
    if (i in linekey) {
      match(lines[i], /=[ \t]*[0-9_]+/)
      value = substr(lines[i], RSTART, RLENGTH)
      sub(/[0-9_]+$/, values[linekey[i]], value)
      print substr(lines[i], 1, RSTART - 1) value substr(lines[i], RSTART + RLENGTH)
    } else print lines[i]
  }
  if (!found) print "\n[ui]"
  if (!found || end == NR + 1) insert_missing()
}
' "$config" >"$tmp" || exit

# Avoid expensive reloads when already at the floor or ceiling.
if ! cmp -s "$tmp" "$config"; then
  # Writing through the existing path preserves its symlink and permissions.
  cat "$tmp" >"$config" || exit
  "$herdr" server reload-config >/dev/null || exit "$?"
fi

if [ "$1" = toggle ]; then
  message=$(awk -F= '
    /^[ \t]*\[ui\][ \t]*(#.*)?$/ { ui = 1; next }
    /^[ \t]*\[/ { ui = 0 }
    ui && /^[ \t]*sidebar_(min_width|max_width)[ \t]*=/ {
      value = $2 + 0
      if ($1 ~ /sidebar_min_width/) minimum = value
      else maximum = value
    }
    END {
      if (minimum == maximum) print "Pinned: " minimum " columns\nPrefix+, / Prefix+. to resize"
      else print "Mouse resizing enabled"
    }
  ' "$tmp")
  # Release the edit lock before the short-lived popup waits to close.
  rm -f "$tmp"
  rmdir "$lock"
  trap - EXIT
  printf '\n%s\n' "$message"
  sleep 1
fi
