#!/bin/sh

set -eu

tmux_bin=/usr/local/bin/tmux
session=quickdash
home_dir=${HOME:-/Users/slu}
btop_bin=/opt/homebrew/bin/btop
watch_bin=/opt/homebrew/bin/watch
quota_script="$home_dir/hyperion/tools/quota/quota-latest.sh"

if ! "$tmux_bin" has-session -t "$session" 2>/dev/null; then
  "$tmux_bin" new-session -d -s "$session" -c "$home_dir" "$btop_bin"
  "$tmux_bin" split-window -h -t "$session":0 -c "$home_dir" "$watch_bin -n 300 $quota_script"
  "$tmux_bin" select-pane -t "$session":0.0
fi

exec "$tmux_bin" attach-session -t "$session"
