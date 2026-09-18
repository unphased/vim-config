#!/bin/sh
set -eu
: "${HERDR_PLUGIN_CLICKED_URL:?This action requires a file-link click}"
# GUI-launched Herdr/Alacritty may not inherit the interactive shell's PATH.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
handler=${REVEAL_LOCATION:-"$HOME/util/reveal-location"}
errors=$(mktemp)
trap 'rm -f "$errors"' EXIT HUP INT TERM
if "$handler" -- "$HERDR_PLUGIN_CLICKED_URL" 2>"$errors"; then
  exit 0
else
  status=$?
  message=$(head -c 1000 "$errors")
  printf '%s\n' "$message" >&2
  if [ -n "${HERDR_BIN_PATH:-}" ]; then
    "$HERDR_BIN_PATH" notification show 'Could not reveal file' --body "$message" --sound none >/dev/null 2>&1 || :
  fi
  exit "$status"
fi
