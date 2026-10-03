#!/bin/sh

reset=0
case "${1:-}" in
  shrink) delta=-4 ;;
  reset) delta=0; reset=48 ;;
  *) printf 'usage: %s {shrink|reset}\n' "$0" >&2; exit 2 ;;
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

awk -v delta="$delta" -v reset="$reset" '
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
BEGIN { minimum = 18; maximum = 36 }
{
  lines[NR] = $0
  if ($0 ~ /^[ \t]*\[ui\][ \t]*(#.*)?$/) { ui = 1; found = 1 }
  else if (ui && $0 ~ /^[ \t]*\[/) { ui = 0; end = NR }
  if (ui && $0 ~ /^[ \t]*sidebar_min_width[ \t]*=/) minimum = width($0)
  if (ui && $0 ~ /^[ \t]*sidebar_max_width[ \t]*=/) {
    maximum = width($0)
    maxline = NR
  }
}
END {
  if (failed) exit 2
  if (reset) maximum = reset
  else maximum += delta
  if (maximum < minimum) maximum = minimum
  if (maximum > 65535) maximum = 65535
  if (!end) end = NR + 1
  for (i = 1; i <= NR; i++) {
    if (found && !maxline && i == end) print "sidebar_max_width = " maximum
    if (i == maxline) {
      match(lines[i], /=[ \t]*[0-9_]+/)
      value = substr(lines[i], RSTART, RLENGTH)
      sub(/[0-9_]+$/, maximum, value)
      print substr(lines[i], 1, RSTART - 1) value substr(lines[i], RSTART + RLENGTH)
    } else print lines[i]
  }
  if (!found) print "\n[ui]"
  if (!maxline && (!found || end == NR + 1)) print "sidebar_max_width = " maximum
}
' "$config" >"$tmp" || exit

# Avoid expensive reloads when already at the floor or reset cap.
cmp -s "$tmp" "$config" && exit 0

# Writing through the existing path preserves its symlink and permissions.
cat "$tmp" >"$config" || exit
"$herdr" server reload-config >/dev/null
