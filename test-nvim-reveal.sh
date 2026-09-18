#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
REVEAL_TEST_ROOT="$root" XDG_STATE_HOME="$tmp" \
HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/reveal-test-herdr.sock HERDR_PANE_ID=w-test:p-test \
TMUX=/tmp/reveal-test-tmux.sock,123,0 TMUX_PANE=%777 \
  nvim --headless -u NONE -i NONE -l "$root/nvim/tests/reveal_spec.lua"
