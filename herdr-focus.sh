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

adjacent_target() {
  case "$2" in
    ''|*[!0-9]*) return 0 ;;
  esac

  jq -r \
    --arg collection "$1" \
    --argjson current "$2" \
    --arg direction "$3" \
    --arg id_key "$4" '
      [.result[$collection][] | select(
        if ($direction == "left" or $direction == "up") then
          .number < $current
        else
          .number > $current
        end
      )] |
      sort_by(.number) |
      if length == 0 then empty
      elif ($direction == "left" or $direction == "up") then .[-1][$id_key]
      else .[0][$id_key]
      end'
}

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
      target=$(printf '%s' "$tabs" | adjacent_target tabs "$current" "$direction" tab_id)
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
      target=$(printf '%s' "$workspaces" | adjacent_target workspaces "$current" "$direction" workspace_id)
      if [ -n "$target" ]; then
        herdr workspace focus "$target"
      fi
    else
      herdr pane focus --pane "$pane" --direction "$direction"
    fi
    ;;
esac
