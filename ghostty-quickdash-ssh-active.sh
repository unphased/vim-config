#!/bin/sh

set -eu

home_dir=${HOME:-/home/slu}
ssh_log=${1:-${XDG_STATE_HOME:-$home_dir/.local/state}/quickdash/ssh-connections.tsv}
once=0
if [ "${1:-}" = "--once" ]; then
  once=1
  ssh_log=${2:-${XDG_STATE_HOME:-$home_dir/.local/state}/quickdash/ssh-connections.tsv}
elif [ "${SSH_ACTIVE_ONCE:-}" = 1 ]; then
  once=1
fi

# The launcher normally creates this.  Keeping the viewer usable on its own is
# helpful when the quickdash session is being bootstrapped.
if [ ! -e "$ssh_log" ]; then
  mkdir -p "${ssh_log%/*}" 2>/dev/null || true
  : >"$ssh_log"
fi

if date -j -f '%Y-%m-%dT%H:%M:%S%z' '2000-01-01T00:00:00+0000' +%s >/dev/null 2>&1; then
  date_mode=bsd
else
  date_mode=gnu
fi

timestamp_epoch() {
  timestamp=$1
  case "$timestamp" in
    *Z) timestamp="${timestamp%Z}+0000" ;;
    *)
      timezone=${timestamp#${timestamp%??????}}
      case "$timezone" in
        [+-]??:??) timestamp="${timestamp%??????}${timezone%:*}${timezone#*:}" ;;
      esac
      ;;
  esac
  if [ "$date_mode" = bsd ]; then
    date -j -f '%Y-%m-%dT%H:%M:%S%z' "$timestamp" +%s 2>/dev/null
  else
    date -d "$timestamp" +%s 2>/dev/null
  fi
}

bright=$(printf '\033[1;36m')
normal=$(printf '\033[36m')
dim=$(printf '\033[2;36m')
reset=$(printf '\033[0m')
if [ "${SSH_ACTIVE_NO_COLOR:-}" = 1 ] || [ ! -t 1 ]; then
  bright=
  normal=
  dim=
  reset=
fi

render() {
  now=$(date +%s)
  state_file=$(mktemp "${TMPDIR:-/tmp}/quickdash-ssh-active.XXXXXX")
  trap 'rm -f "$state_file"; exit 0' HUP INT TERM
  trap 'rm -f "$state_file"' EXIT

  columns=$(tput cols 2>/dev/null || printf '80')
  case "$columns" in
    ''|*[!0-9]*) columns=80 ;;
  esac
  origin_width=$((columns - 40))
  [ "$origin_width" -lt 1 ] && origin_width=1

  # Rebuild state from the log each frame.  The log is small enough for this
  # polling loop, and this also handles long-lived sessions and log rotation.
  awk -v origin_width="$origin_width" '
  BEGIN {
    FS = "\t"
    OFS = "\t"
    tab = sprintf("%c", 9)
  }
  function value(key, i) {
    for (i = 1; i <= NF; i++)
      if ($i ~ ("^" key "="))
        return substr($i, length(key) + 2)
    return ""
  }
  function pid_from_chain(chain, start, rest, pid_end) {
    start = index(chain, "ssh[")
    if (!start)
      return ""
    rest = substr(chain, start + 4)
    pid_end = index(rest, "]")
    if (!pid_end)
      return ""
    return substr(rest, 1, pid_end - 1)
  }
  function clip(text, width) {
    if (length(text) > width)
      return substr(text, 1, width - 2) ".."
    return text
  }
  {
    # A short-lived producer used literal \\t escapes instead of tabs.
    line = $0
    gsub(/\\t/, tab, line)
    $0 = line

    type = value("type")
    if (type == "ssh_disconnect") {
      id = value("ssh_pid")
      if (id == "")
        id = pid_from_chain(value("process_chain"))
      if (id != "")
        live[id] = 0
      next
    }
    if (type != "ssh_connect" && type != "ssh_request")
      next

    chain = value("process_chain")
    id = value("ssh_pid")
    if (id == "")
      id = pid_from_chain(chain)

    # Request records enrich a known connection.  Request-only historical
    # records have no lifecycle end event, so treating them as live forever
    # would turn the dashboard into a history list rather than an active view.
    if (type == "ssh_request" && (id == "" || !seen[id]))
      next
    if (id == "")
      id = "line-" NR

    if (!seen[id]) {
      order[++count] = id
      seen[id] = 1
    }
    live[id] = 1
    if (type == "ssh_connect")
      started[id] = $1
    if (value("user") != "")
      user[id] = value("user")
    if (value("host") != "")
      destination[id] = value("host")
    if (value("alias") != "")
      alias[id] = value("alias")
    if (value("ssh_pid") != "")
      pid[id] = value("ssh_pid")
    else
      pid[id] = id
    if (chain != "") {
      sub(/^ssh\[[0-9]+\][[:space:]]*<-[[:space:]]*/, "", chain)
      origin[id] = chain
    }
    if (destination[id] == "" && alias[id] != "")
      destination[id] = alias[id]
    if (destination[id] == "" && value("targets") != "") {
      destination[id] = value("targets")
      sub(/,.*/, "", destination[id])
      sub(/:[0-9]+$/, "", destination[id])
    }
  }
  END {
    for (i = count; i >= 1; i--) {
      id = order[i]
      if (!live[id])
        continue
      peer = destination[id]
      if (peer == "")
        peer = "-"
      if (user[id] != "")
        peer = user[id] "@" peer
      print started[id], clip(peer, 18),
        clip((alias[id] == "" ? "-" : alias[id]), 8),
        clip((pid[id] == "" ? "-" : pid[id]), 5),
        (origin[id] == "" ? "-" : clip(origin[id], origin_width))
    }
  }
  ' "$ssh_log" >"$state_file"

  count=$(awk 'END { print NR + 0 }' "$state_file")
  if [ "$count" -eq 0 ]; then
    printf '%sSSH attempts  -  clear%s\n' "$dim" "$reset"
  else
    printf '%sSSH attempts  -  %s active%s\n' "$bright" "$count" "$reset"
    printf '%sAGE  %-18s %-8s %-5s %s%s\n' "$dim" "DESTINATION" "ALIAS" "PID" "ORIGIN" "$reset"
  fi

  rows=$count
  overflow=0
  if [ "$rows" -gt 3 ]; then
    rows=2
    overflow=1
  fi
  shown=0
  while IFS="$(printf '\t')" read -r started destination alias pid origin; do
    [ -n "$started" ] || continue
    [ "$shown" -ge "$rows" ] && break
    if epoch=$(timestamp_epoch "$started"); then
      age=$((now - epoch))
    else
      age=20
    fi
    [ "$age" -lt 0 ] && age=0

    if [ "$age" -lt 10 ]; then
      colour=$bright
    elif [ "$age" -lt 20 ]; then
      colour=$normal
    else
      colour=$dim
    fi
    printf '%s%3ss  %-18s %-8s %-5s %s%s\n' "$colour" "$age" \
      "$destination" "$alias" "$pid" "$origin" "$reset"
    shown=$((shown + 1))
  done <"$state_file"
  if [ "$overflow" -eq 1 ]; then
    printf '%s... %s more active%s\n' "$dim" "$((count - rows))" "$reset"
  fi

  rm -f "$state_file"
  trap - EXIT HUP INT TERM
}

while :; do
  if [ -t 1 ] && [ "$once" -eq 0 ]; then
    printf '\033[H\033[2J'
  fi
  render
  [ "$once" -eq 1 ] && exit 0
  sleep 1
done
