#!/bin/sh

set -eu

app_id=com.mitchellh.ghostty.quickdash
launcher="$HOME/.vim/ghostty-quickdash.sh"
pattern="ghostty .*--class=$app_id"

pids=$(pgrep -u "$(id -u)" -f "$pattern" || true)
if [ -n "$pids" ]; then
  kill $pids
  exit 0
fi

exec ghostty \
  --class="$app_id" \
  --title=quickdash \
  --gtk-single-instance=false \
  -e "$launcher"
