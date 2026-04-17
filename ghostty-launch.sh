#!/bin/sh

if [ "${GHOSTTY_QUICK_TERMINAL:-}" = "1" ]; then
  exec /usr/local/bin/tmux new-session -A -s quickdash
fi

exec "${SHELL:-/bin/zsh}" -l
