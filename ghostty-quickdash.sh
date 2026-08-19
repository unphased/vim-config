#!/bin/sh

set -eu

tmux_bin=$(command -v tmux)
session=quickdash
home_dir=${HOME:-/home/slu}
htop_bin=$(command -v htop)
watch_bin=$(command -v watch)
tail_bin=$(command -v tail)
quota_script="$home_dir/hyperion/tools/quota/quota-latest.sh"
ssh_log="${XDG_STATE_HOME:-$home_dir/.local/state}/quickdash/ssh-connections.tsv"

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
  "$tmux_bin" send-keys -t "$ssh_pane" "$tail_bin -n 20 -F $ssh_log" C-m
  "$tmux_bin" select-pane -t "$left_pane"
fi

exec "$tmux_bin" attach-session -t "$session"
