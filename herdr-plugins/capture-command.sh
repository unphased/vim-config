#!/bin/sh
# Record persistent direct-pane content just like the interactive zsh hook.
set -eu
capture_bin=${TERMPLEX_CAPTURE_BIN:-"$HOME/termplex/release/term-capture"}
capture_dir=${TERMPLEX_CAPTURE_DIR:-"$HOME/.termplex/captures"}
if [ "${TERMPLEX_CAPTURE:-1}" = 1 ]; then
  if [ ! -x "$capture_bin" ]; then
    capture_bin=$(command -v term-capture || :)
  fi
  if [ -n "$capture_bin" ] && [ -x "$capture_bin" ]; then
    exec "$capture_bin" --pid-prefix-dir "$capture_dir" -- "$@"
  fi
fi
# Keep content available when capture is disabled or not installed.
exec "$@"
