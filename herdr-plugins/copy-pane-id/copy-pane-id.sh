#!/bin/sh
set -eu

if [ "${HERDR_PLUGIN_ENTRYPOINT_ID:-}" = osc52 ]; then
  : "${COPY_TEXT:?COPY_TEXT is required}"
  payload=$(printf '%s' "$COPY_TEXT" | base64 | tr -d '\r\n')
  printf '\033]52;c;%s\007' "$payload"
  exit 0
fi

: "${HERDR_BIN_PATH:?HERDR_BIN_PATH is required}"
: "${HERDR_PLUGIN_ID:?HERDR_PLUGIN_ID is required}"
: "${HERDR_PANE_ID:?HERDR_PANE_ID is required}"
: "${HERDR_WORKSPACE_ID:?HERDR_WORKSPACE_ID is required}"

# Action stdout is captured in plugin logs. A short-lived background pane lets
# Herdr forward OSC 52 to the attached client without typing into the target.
exec "$HERDR_BIN_PATH" plugin pane open \
  --plugin "$HERDR_PLUGIN_ID" \
  --entrypoint osc52 \
  --placement tab \
  --workspace "$HERDR_WORKSPACE_ID" \
  --env "COPY_TEXT=$HERDR_PANE_ID" \
  --no-focus
