#!/bin/sh

if [ "$#" -ne 1 ]; then
  printf 'usage: %s {left|right|up|down}\n' "$0" >&2
  exit 2
fi

case "$1" in
  left|right|up|down) ;;
  *)
    printf 'usage: %s {left|right|up|down}\n' "$0" >&2
    exit 2
    ;;
esac

direction=$1
context=$(herdr pane current --current) || exit
pane=$(printf '%s' "$context" | jq -r '.result.pane.pane_id')
tab=$(printf '%s' "$context" | jq -r '.result.pane.tab_id')
workspace=$(printf '%s' "$context" | jq -r '.result.pane.workspace_id')
edges=$(herdr pane edges --pane "$pane") || exit

case "$direction" in
  left|right)
    if [ "$(printf '%s' "$edges" | jq -r --arg key "$direction" '.result.edges | .[$key]')" = true ]; then
      tabs=$(herdr tab list --workspace "$workspace") || exit
      current=$(printf '%s' "$tabs" | jq -r --arg id "$tab" '.result.tabs[] | select(.tab_id == $id) | .number')
      if [ "$direction" = left ]; then
        target_number=$((current - 1))
      else
        target_number=$((current + 1))
      fi
      target=$(printf '%s' "$tabs" | jq -r --argjson n "$target_number" '.result.tabs[] | select(.number == $n) | .tab_id')
      if [ -n "$target" ]; then
        herdr tab focus "$target"
      fi
    else
      herdr pane focus --pane "$pane" --direction "$direction"
    fi
    ;;
  up|down)
    if [ "$(printf '%s' "$edges" | jq -r --arg key "$direction" '.result.edges | .[$key]')" = true ]; then
      workspaces=$(herdr workspace list) || exit
      current=$(printf '%s' "$workspaces" | jq -r --arg id "$workspace" '.result.workspaces[] | select(.workspace_id == $id) | .number')
      if [ "$direction" = up ]; then
        target_number=$((current - 1))
      else
        target_number=$((current + 1))
      fi
      target=$(printf '%s' "$workspaces" | jq -r --argjson n "$target_number" '.result.workspaces[] | select(.number == $n) | .workspace_id')
      if [ -n "$target" ]; then
        herdr workspace focus "$target"
      fi
    else
      herdr pane focus --pane "$pane" --direction "$direction"
    fi
    ;;
esac
