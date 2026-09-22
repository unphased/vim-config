#!/bin/sh

if [ "$#" -ne 1 ]; then
  printf 'usage: %s {left|right|up|down|toggle}\n' "$0" >&2
  exit 2
fi

case "$1" in
  left|right|up|down|toggle) ;;
  *)
    printf 'usage: %s {left|right|up|down|toggle}\n' "$0" >&2
    exit 2
    ;;
esac

direction=$1

if [ -n "${HERDR_WORKSPACE_TOGGLE_STATE:-}" ]; then
  state_file=$HERDR_WORKSPACE_TOGGLE_STATE
else
  state_key=$(printf '%s' "${HERDR_SOCKET_PATH:-default}" | cksum)
  state_key=${state_key%% *}
  state_file="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/workspace-toggle-$state_key"
fi

save_toggle_state() {
  mkdir -p "$(dirname "$state_file")" || return
  printf '%s\t%s\n' "$1" "$2" >"$state_file.tmp.$$" || return
  mv "$state_file.tmp.$$" "$state_file"
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

# Herdr's workspace numbers reflect creation/sidebar positions, so linked
# worktrees can be separated from their parent by unrelated workspaces. Keep
# each repository's parent followed immediately by its linked workspaces.
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

context=$(herdr pane current --current) || exit
pane=$(printf '%s' "$context" | jq -r '.result.pane.pane_id')
tab=$(printf '%s' "$context" | jq -r '.result.pane.tab_id')
workspace=$(printf '%s' "$context" | jq -r '.result.pane.workspace_id')

remembered=
last_controlled=
if [ -r "$state_file" ]; then
  IFS="$(printf '\t')" read -r remembered last_controlled <"$state_file"
fi

if [ "$direction" = toggle ]; then
  if [ -n "$remembered" ] && [ "$remembered" != "$workspace" ]; then
    target=$remembered
    if herdr workspace focus "$target"; then
      save_toggle_state "$workspace" "$target"
    else
      rm -f "$state_file"
      exit 1
    fi
  else
    save_toggle_state "$workspace" "$workspace"
  fi
  exit
fi

# A workspace change outside this helper starts a new navigation chain. Once
# custom navigation starts, preserve its origin while it crosses workspaces.
if [ -z "$remembered" ] || [ "$last_controlled" != "$workspace" ]; then
  remembered=$workspace
fi

edges=$(herdr pane edges --pane "$pane") || exit
focused_workspace=$workspace

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
      target=$(printf '%s' "$workspaces" | workspace_adjacent_target "$workspace" "$direction")
      if [ -n "$target" ]; then
        herdr workspace focus "$target" || exit
        focused_workspace=$target
      fi
    else
      herdr pane focus --pane "$pane" --direction "$direction"
    fi
    ;;
esac

save_toggle_state "$remembered" "$focused_workspace"
