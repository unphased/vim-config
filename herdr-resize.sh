#!/bin/sh

usage() {
  printf 'usage: %s {left|right|up|down}\n' "$0" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
direction=$1
case "$direction" in
  left) before=left; after=right; resize=shrink ;;
  right) before=left; after=right; resize=grow ;;
  up) before=up; after=down; resize=shrink ;;
  down) before=up; after=down; resize=grow ;;
  *) usage ;;
esac

herdr=${HERDR_BIN_PATH:-herdr}
pane=${HERDR_PANE_ID:-}
if [ -z "$pane" ]; then
  context=$("$herdr" pane current --current) || exit
  pane=$(printf '%s' "$context" | jq -er '.result.pane.pane_id') || exit
fi

neighbor() {
  response=$("$herdr" pane neighbor --pane "$pane" --direction "$1") || return
  printf '%s' "$response" | jq -r '.result.neighbor.neighbor_pane_id // empty'
}

after_pane=$(neighbor "$after") || exit
if [ -n "$after_pane" ]; then
  if [ "$resize" = grow ]; then
    target=$pane
    move=$after
  else
    target=$after_pane
    move=$before
  fi
else
  before_pane=$(neighbor "$before") || exit
  [ -n "$before_pane" ] || exit 0
  target=$pane
  move=$direction
fi

exec "$herdr" pane resize --pane "$target" --direction "$move" >/dev/null
