#!/bin/sh
set -eu

: "${HERDR_BIN_PATH:?HERDR_BIN_PATH is required}"
: "${HERDR_PANE_ID:?HERDR_PANE_ID is required}"

exec "$HERDR_BIN_PATH" pane move "$HERDR_PANE_ID" \
  --new-workspace \
  --focus
