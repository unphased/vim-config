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
# The fixed fields use 92 columns; the process chain gets the remainder.
origin_width=$((columns - 92))
[ "$origin_width" -lt 0 ] && origin_width=0
tail -n 20 -F "$ssh_log" | awk -v origin_width="$origin_width" -v screen_width="$columns" -v home_dir="${HOME:-/home/slu}" '
BEGIN {
  FS = "\t"
  OFS = " "
  tab = sprintf("%c", 9)
  esc = sprintf("%c", 27)
  dim = esc "[2m"
  normal = esc "[22m"
  printf "%s\n", clip_terminal(sprintf("%-14s %-9s %-25s %-7s %-32s %s", "WHEN", "EVENT", "PEER", "PID", "CWD", "ORIGIN"), screen_width)
  printf "%s\n", clip_terminal(sprintf("%-14s %-9s %-25s %-7s %-32s %s", "--------------", "---------", "-------------------------", "-------", "--------------------------------", "------"), screen_width)
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
function shorten_home(path, suffix) {
  if (home_dir == "" || index(path, home_dir) != 1)
    return path
  suffix = substr(path, length(home_dir) + 1)
  if (suffix == "" || substr(suffix, 1, 1) == "/")
    return "~" suffix
  return path
}
function describe_node(node, kind, pid, query, command, args, arg_count, i, candidate, base) {
  if (node !~ /^(bash|sh|zsh)\[[0-9]+\]$/)
    return node
  kind = node
  sub(/\[.*/, "", kind)
  pid = node
  sub(/^[^[]+\[/, "", pid)
  sub(/\].*$/, "", pid)
  query = "ps -ww -o command= -p " pid " 2>/dev/null"
  command = ""
  if ((query | getline command) <= 0) {
    close(query)
    return node
  }
  close(query)
  gsub(/[[:space:]]+/, " ", command)
  arg_count = split(command, args, / /)
  for (i = 2; i <= arg_count; i++) {
    candidate = args[i]
    gsub(/\"/, "", candidate)
    if (candidate ~ /\.(sh|bash|zsh)$/ || candidate ~ /^\//) {
      base = candidate
      sub(/^.*\//, "", base)
      return kind "[" pid ":" base "]"
    }
  }
  return node
}
function render_chain(chain, count, i, node, rendered) {
  if (chain == "")
    return "-"
  gsub(/[[:space:]]*<-[[:space:]]*/, " <- ", chain)
  sub(/^ssh\[[0-9]+\][[:space:]]*<-[[:space:]]*/, "", chain)
  count = split(chain, nodes, / <- /)
  rendered = ""
  for (i = 1; i <= count; i++) {
    node = describe_node(nodes[i])
    rendered = rendered (i == 1 ? "" : " <- ") node
  }
  rendered = clip(rendered, origin_width)
  count = split(rendered, nodes, / <- /)
  rendered = ""
  for (i = 1; i <= count; i++) {
    node = nodes[i]
    if (node ~ /^(bash|zsh|sh|tmux)\[[0-9]+([:]|\])/)
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
  cwd = shorten_home(value("cwd"))
  if (alias != "")
    peer = alias
  else if (endpoint != "")
    peer = endpoint
  else if (host != "")
    peer = host (port == "" ? "" : ":" port)
  else
    peer = "-"
  user = value("user")
  if (user != "")
    peer = user "@" peer

  pid = clip((pid == "" ? "-" : pid), 7)
  row = sprintf("%-14s %-9s %-25s %-7s %-32s %s", timestamp, event, clip(peer, 25), pid, clip((cwd == "" ? "-" : cwd), 32), render_chain(value("process_chain")))
  printf "%s\n", clip_terminal(row, screen_width)
  fflush()
}
'
