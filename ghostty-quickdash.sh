#!/bin/sh

set -eu

tmux_bin=$(command -v tmux)
session=quickdash
home_dir=${HOME:-/home/slu}
htop_bin=$(command -v htop)
watch_bin=$(command -v watch)
quota_script="$home_dir/hyperion/tools/quota/quota-latest.sh"
ssh_log="${XDG_STATE_HOME:-$home_dir/.local/state}/quickdash/ssh-connections.tsv"
ssh_log_viewer="$home_dir/.vim/ghostty-quickdash-ssh-log.sh"
ssh_active_viewer="$home_dir/.vim/ghostty-quickdash-ssh-active.sh"

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

ssh_log_command="$(shell_quote "$ssh_log_viewer") $(shell_quote "$ssh_log")"
ssh_active_command="$(shell_quote "$ssh_active_viewer") $(shell_quote "$ssh_log")"

umask 077
mkdir -p "${ssh_log%/*}" 2>/dev/null || true
: >>"$ssh_log" 2>/dev/null || true

if ! "$tmux_bin" has-session -t "$session" 2>/dev/null; then
  "$tmux_bin" new-session -d -s "$session" -c "$home_dir"
  left_pane=$("$tmux_bin" display-message -p -t "$session" '#{pane_id}')
  "$tmux_bin" send-keys -t "$left_pane" "$htop_bin" C-m
  right_pane=$("$tmux_bin" split-window -h -P -F '#{pane_id}' -t "$left_pane" -c "$home_dir")
  "$tmux_bin" send-keys -t "$right_pane" "NO_COLOR= FORCE_COLOR=1 $watch_bin -c -n 300 $quota_script" C-m
  ssh_pane=$("$tmux_bin" split-window -v -P -F '#{pane_id}' -t "$right_pane" -c "$home_dir")
  "$tmux_bin" select-pane -t "$ssh_pane" -T "SSH connections"
  "$tmux_bin" send-keys -t "$ssh_pane" "$ssh_log_command" C-m
  active_pane=$("$tmux_bin" split-window -v -b -l 5 -P -F '#{pane_id}' -t "$ssh_pane" -c "$home_dir")
  "$tmux_bin" select-pane -t "$active_pane" -T "SSH attempts"
  "$tmux_bin" send-keys -t "$active_pane" "$ssh_active_command" C-m
  "$tmux_bin" select-pane -t "$left_pane"
else
  # Add the compact pane to a session created by an older quickdash.
  active_pane=$("$tmux_bin" list-panes -t "$session" -F '#{pane_title}|#{pane_id}' |
    awk -F '|' '$1 == "SSH attempts" { print $2; exit }')
  if [ -z "$active_pane" ]; then
    ssh_pane=$("$tmux_bin" list-panes -t "$session" -F '#{pane_title}|#{pane_id}' |
      awk -F '|' '$1 == "SSH connections" { print $2; exit }')
    if [ -n "$ssh_pane" ]; then
      active_pane=$("$tmux_bin" split-window -v -b -l 5 -P -F '#{pane_id}' -t "$ssh_pane" -c "$home_dir")
      "$tmux_bin" select-pane -t "$active_pane" -T "SSH attempts"
      "$tmux_bin" send-keys -t "$active_pane" "$ssh_active_command" C-m
    fi
  fi
fi

exec "$tmux_bin" attach-session -t "$session"
