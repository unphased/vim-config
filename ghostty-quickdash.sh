#!/bin/sh

set -eu

tmux_bin=/usr/local/bin/tmux
session=quickdash
home_dir=${HOME:-/Users/slu}
htop_bin=/opt/homebrew/bin/htop
watch_bin=/opt/homebrew/bin/watch
quota_script="$home_dir/hyperion/tools/quota/quota-latest.sh"

if ! "$tmux_bin" has-session -t "$session" 2>/dev/null; then
  "$tmux_bin" new-session -d -s "$session" -c "$home_dir"
  left_pane=$("$tmux_bin" display-message -p -t "$session" '#{pane_id}')
  "$tmux_bin" send-keys -t "$left_pane" "$htop_bin" C-m
  right_pane=$("$tmux_bin" split-window -h -P -F '#{pane_id}' -t "$left_pane" -c "$home_dir")
  "$tmux_bin" send-keys -t "$right_pane" "$watch_bin -n 300 $quota_script" C-m
  "$tmux_bin" select-pane -t "$left_pane"
fi

exec "$tmux_bin" attach-session -t "$session"
