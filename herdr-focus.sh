#!/bin/sh

usage() {
  printf 'usage: %s {left|right|up|down|toggle}\n' "$0" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in
  left|right|up|down|toggle) direction=$1 ;;
  *) usage ;;
esac

run_locked_toggle() {
  if [ -n "${HERDR_WORKSPACE_TOGGLE_LOCK:-}" ]; then
    toggle_lock=$HERDR_WORKSPACE_TOGGLE_LOCK
  else
    lock_key=$(printf '%s' "${HERDR_SOCKET_PATH:-default}" | cksum)
    lock_key=${lock_key%% *}
    toggle_lock="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/workspace-toggle-$lock_key.lock"
  fi
  mkdir -p "$(dirname "$toggle_lock")" || exit
  HERDR_WORKSPACE_TOGGLE_LOCKED=1
  export HERDR_WORKSPACE_TOGGLE_LOCKED

  if command -v lockf >/dev/null 2>&1; then
    exec lockf -t 2 "$toggle_lock" "$0" toggle
  elif command -v flock >/dev/null 2>&1; then
    exec flock -w 2 "$toggle_lock" "$0" toggle
  fi
  printf 'Ctrl-Tab requires lockf or flock\n' >&2
  exit 1
}

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

# Keep each repository's parent followed immediately by its linked workspaces.
workspace_adjacent_target() {
  jq -r \
    --arg current "$1" \
    --arg direction "$2" '
      .result.workspaces as $workspaces |
      $workspaces
      | map(
          . as $workspace
          | . + {
              sort_key: (
                if ($workspace.worktree != null and $workspace.worktree.is_linked_worktree == true) then
                  ([$workspaces[]
                    | select(
                        .worktree != null
                        and .worktree.repo_key == $workspace.worktree.repo_key
                        and (.worktree.is_linked_worktree // false) == false
                      )
                    | .number
                  ] | .[0]) // $workspace.number
                else
                  $workspace.number
                end
              )
            }
        )
      | sort_by([
          .sort_key,
          (if (.worktree != null and .worktree.is_linked_worktree == true) then 1 else 0 end),
          .number
        ])
      | map(.workspace_id) as $ordered
      | ($ordered | index($current)) as $index
      | if $index == null then empty
        elif ($direction == "up" and $index == 0) then empty
        elif ($direction == "down" and ($index + 1) >= ($ordered | length)) then empty
        elif ($direction == "up") then $ordered[$index - 1]
        else $ordered[$index + 1]
        end // empty'
}

if [ "$direction" = toggle ] && [ "${HERDR_WORKSPACE_TOGGLE_LOCKED:-}" != 1 ]; then
  run_locked_toggle
fi

context=$(herdr pane current --current) || exit
pane=$(printf '%s' "$context" | jq -r '.result.pane.pane_id')
tab=$(printf '%s' "$context" | jq -r '.result.pane.tab_id')
workspace=$(printf '%s' "$context" | jq -r '.result.pane.workspace_id')

if [ "$direction" = toggle ]; then
  workspaces=$(herdr workspace list) || exit
  target=$(printf '%s' "$workspaces" | jq -r --arg current "$workspace" \
    '.result.workspaces[]
      | select(.workspace_id != $current and .tokens.ctrl_tab_target? == "↩")
      | .workspace_id' \
    | head -n 1)

  if [ -z "$target" ] && printf '%s' "$workspaces" | jq -e --arg current "$workspace" \
      'any(.result.workspaces[]; .workspace_id == $current and .tokens.ctrl_tab_target? == "↩")' \
      >/dev/null; then
    # The target is a sticky bookmark. Reaching it by some other means does not
    # silently assign a different workspace.
    exit
  fi

  if [ -z "$target" ]; then
    target=$(printf '%s' "$workspaces" | workspace_adjacent_target "$workspace" up)
    [ -n "$target" ] \
      || target=$(printf '%s' "$workspaces" | workspace_adjacent_target "$workspace" down)
  fi
  [ -n "$target" ] || exit

  # Move the visible bookmark before focus. If the command is interrupted,
  # either the old or new current workspace still carries a usable marker.
  herdr workspace report-metadata "$workspace" --source workspace-toggle \
    --token 'ctrl_tab_target=↩' >/dev/null || exit
  if ! herdr workspace focus "$target"; then
    herdr workspace report-metadata "$workspace" --source workspace-toggle \
      --clear-token ctrl_tab_target >/dev/null 2>&1 || :
    exit 1
  fi

  printf '%s' "$workspaces" | jq -r \
    '.result.workspaces[] | select(.tokens.ctrl_tab_target? == "↩") | .workspace_id' \
    | while IFS= read -r marked_workspace; do
        [ "$marked_workspace" = "$workspace" ] && continue
        herdr workspace report-metadata "$marked_workspace" --source workspace-toggle \
          --clear-token ctrl_tab_target >/dev/null 2>&1 || :
      done
  exit
fi

edges=$(herdr pane edges --pane "$pane") || exit
case "$direction" in
  left|right)
    if [ "$(printf '%s' "$edges" | jq -r --arg key "$direction" '.result.edges | .[$key]')" = true ]; then
      tabs=$(herdr tab list --workspace "$workspace") || exit
      current=$(printf '%s' "$tabs" | jq -r --arg id "$tab" '.result.tabs[] | select(.tab_id == $id) | .number')
      target=$(printf '%s' "$tabs" | adjacent_target tabs "$current" "$direction" tab_id)
      [ -z "$target" ] || herdr tab focus "$target"
    else
      herdr pane focus --pane "$pane" --direction "$direction"
    fi
    ;;
  up|down)
    if [ "$(printf '%s' "$edges" | jq -r --arg key "$direction" '.result.edges | .[$key]')" = true ]; then
      workspaces=$(herdr workspace list) || exit
      target=$(printf '%s' "$workspaces" | workspace_adjacent_target "$workspace" "$direction")
      [ -z "$target" ] || herdr workspace focus "$target"
    else
      herdr pane focus --pane "$pane" --direction "$direction"
    fi
    ;;
esac
