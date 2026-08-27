#!/bin/sh

set -eu

home_dir=${HOME:-/home/slu}
ssh_log=${1:-${XDG_STATE_HOME:-$home_dir/.local/state}/quickdash/ssh-connections.tsv}

if [ ! -e "$ssh_log" ]; then
  mkdir -p "${ssh_log%/*}" 2>/dev/null || true
  : >"$ssh_log"
fi

# Keep this as a stream: the terminal scrollback is the history view.
terminal_columns() {
  columns=
  if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    columns=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_width}' 2>/dev/null || true)
  fi
  case "$columns" in
    ''|*[!0-9]*) columns=$(tput cols 2>/dev/null || printf '100') ;;
  esac
  case "$columns" in
    ''|*[!0-9]*) columns=100 ;;
  esac
  printf '%s\n' "$columns"
}
columns=$(terminal_columns)
# The fixed fields use 101 columns; the process chain gets the remainder.
origin_width=$((columns - 101))
[ "$origin_width" -lt 0 ] && origin_width=0
tail -n 20 -F "$ssh_log" | awk -v origin_width="$origin_width" -v screen_width="$columns" '
BEGIN {
  FS = "\t"
  OFS = " "
  tab = sprintf("%c", 9)
  esc = sprintf("%c", 27)
  dim = esc "[2m"
  normal = esc "[22m"
  printf "%s\n", clip_terminal(sprintf("%-14s %-9s %-25s %-7s %-12s %-28s %s", "WHEN", "EVENT", "PEER", "PID", "ALIAS", "CWD", "ORIGIN"), screen_width)
  printf "%s\n", clip_terminal(sprintf("%-14s %-9s %-25s %-7s %-12s %-28s %s", "--------------", "---------", "-------------------------", "-------", "------------", "----------------------------", "------"), screen_width)
}
function value(key, i) {
  for (i = 1; i <= NF; i++)
    if ($i ~ ("^" key "="))
      return substr($i, length(key) + 2)
  return ""
}
function clip(text, width) {
  if (width <= 0)
    return ""
  if (length(text) > width)
    return substr(text, 1, width < 3 ? width : width - 2) (width < 3 ? "" : "..")
  return text
}
function clip_terminal(text, width, i, char, result, visible, in_escape, saw_escape) {
  result = ""
  visible = 0
  for (i = 1; i <= length(text); i++) {
    char = substr(text, i, 1)
    if (in_escape) {
      result = result char
      if (char ~ /[[:alpha:]]/)
        in_escape = 0
    } else if (char == esc) {
      result = result char
      in_escape = 1
      saw_escape = 1
    } else {
      if (visible >= width)
        break
      result = result char
      visible++
    }
  }
  return result (saw_escape ? esc "[0m" : "")
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
  event = clip(event, 9)

  timestamp = substr($1, 6, 5) " " substr($1, 12, 8)
  pid = value("ssh_pid")
  if (pid == "")
    pid = pid_from_chain(value("process_chain"))

  endpoint = value("endpoint")
  host = value("host")
  port = value("port")
  alias = value("alias")
  cwd = value("cwd")
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

  pid = clip((pid == "" ? "-" : pid), 7)
  row = sprintf("%-14s %-9s %-25s %-7s %-12s %-28s %s", timestamp, event, clip(peer, 25), pid, clip((alias == "" ? "-" : alias), 12), clip((cwd == "" ? "-" : cwd), 28), render_chain(value("process_chain")))
  printf "%s\n", clip_terminal(row, screen_width)
  fflush()
}
'
