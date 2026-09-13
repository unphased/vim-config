#!/bin/sh
set -eu

: "${HERDR_BIN_PATH:?HERDR_BIN_PATH is required}"
: "${HERDR_PANE_ID:?HERDR_PANE_ID is required}"
: "${HERDR_TAB_ID:?HERDR_TAB_ID is required}"
: "${HERDR_WORKSPACE_ID:?HERDR_WORKSPACE_ID is required}"

tabs=$(
  "$HERDR_BIN_PATH" tab list --workspace "$HERDR_WORKSPACE_ID"
)
pane_count=$(printf '%s' "$tabs" | jq -er --arg tab_id "$HERDR_TAB_ID" \
  '.result.tabs[] | select(.tab_id == $tab_id) | .pane_count')

if [ "$pane_count" -gt 1 ]; then
  exec "$HERDR_BIN_PATH" pane move "$HERDR_PANE_ID" \
    --new-tab \
    --workspace "$HERDR_WORKSPACE_ID" \
    --focus
fi

exec "$HERDR_BIN_PATH" pane move "$HERDR_PANE_ID" \
  --new-workspace \
  --focus
