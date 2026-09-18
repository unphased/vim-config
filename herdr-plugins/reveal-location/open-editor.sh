#!/bin/sh
set -eu
: "${REVEAL_LOCATION_TARGET:?An editor pane requires a file target}"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
# Direct pane entrypoint: no commands are typed into the clicked pane's shell.
exec "${REVEAL_LOCATION:-$HOME/util/reveal-location}" --editor -- "$REVEAL_LOCATION_TARGET"
