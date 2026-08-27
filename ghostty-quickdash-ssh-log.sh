#!/bin/sh

set -eu

home_dir=${HOME:-/home/slu}
ssh_log=${1:-${XDG_STATE_HOME:-$home_dir/.local/state}/quickdash/ssh-connections.tsv}

if [ ! -e "$ssh_log" ]; then
  mkdir -p "${ssh_log%/*}" 2>/dev/null || true
  : >"$ssh_log"
fi

# Keep this as a stream: the terminal scrollback is the history view.
columns=$(tput cols 2>/dev/null || printf '100')
case "$columns" in
  ''|*[!0-9]*) columns=100 ;;
esac
origin_width=$((columns - 72))
[ "$origin_width" -lt 3 ] && origin_width=3
tail -n 20 -F "$ssh_log" | awk -v origin_width="$origin_width" '
BEGIN {
  FS = "\t"
  OFS = " "
  tab = sprintf("%c", 9)
  esc = sprintf("%c", 27)
  dim = esc "[2m"
  normal = esc "[22m"
  printf "%-14s %-9s %-25s %-7s %-12s %s\n", "WHEN", "EVENT", "PEER", "PID", "ALIAS", "ORIGIN"
  printf "%-14s %-9s %-25s %-7s %-12s %s\n", "--------------", "---------", "-------------------------", "-------", "------------", "------"
}
function value(key, i) {
  for (i = 1; i <= NF; i++)
    if ($i ~ ("^" key "="))
      return substr($i, length(key) + 2)
  return ""
}
function clip(text, width) {
  if (length(text) > width)
    return substr(text, 1, width - 2) ".."
  return text
}
function pid_from_chain(chain, start, rest, end) {
  start = index(chain, "ssh[")
  if (!start)
    return "-"
  rest = substr(chain, start + 4)
  end = index(rest, "]")
  return end ? substr(rest, 1, end - 1) : "-"
}
function render_chain(chain, count, i, node, rendered) {
  if (chain == "")
    return "-"
  gsub(/[[:space:]]*<-[[:space:]]*/, " <- ", chain)
  sub(/^ssh\[[0-9]+\][[:space:]]*<-[[:space:]]*/, "", chain)
  chain = clip(chain, origin_width)
  count = split(chain, nodes, / <- /)
  rendered = ""
  for (i = 1; i <= count; i++) {
    node = nodes[i]
    if (node ~ /^(bash|zsh|sh|tmux)\[[0-9]+\]$/)
      node = dim node normal
    rendered = rendered (i == 1 ? "" : " <- ") node
  }
  return rendered
}
{
  # Normalize the one historical producer that wrote literal \\t escapes.
  line = $0
  gsub(/\\t/, tab, line)
  $0 = line

  type = value("type")
  event = type
  sub(/^ssh_/, "", event)
  if (event == "disconnect")
    event = "done"
  if (event == "")
    event = "activity"

  timestamp = substr($1, 6, 5) " " substr($1, 12, 8)
  pid = value("ssh_pid")
  if (pid == "")
    pid = pid_from_chain(value("process_chain"))

  endpoint = value("endpoint")
  host = value("host")
  port = value("port")
  alias = value("alias")
  if (endpoint != "")
    peer = endpoint
  else if (host != "")
    peer = host (port == "" ? "" : ":" port)
  else if (alias != "")
    peer = alias
  else
    peer = "-"
  user = value("user")
  if (user != "")
    peer = user "@" peer

  printf "%-14s %-9s %-25s %-7s %-12s %s\n", timestamp, event, clip(peer, 25), (pid == "" ? "-" : pid), clip((alias == "" ? "-" : alias), 12), render_chain(value("process_chain"))
  fflush()
}
'
