#!/usr/bin/env bash
set -euo pipefail

max_title_chars=${TMUX_PROJECT_WINDOW_NAME_MAX:-20}

shorten_title() {
    local value=$1
    local max=$2
    local marker="…"
    local keep front back

    if (( ${#value} <= max )); then
        printf '%s\n' "$value"
        return
    fi

    if (( max <= ${#marker} )); then
        printf '%.*s\n' "$max" "$value"
        return
    fi

    keep=$((max - ${#marker}))
    front=$(((keep + 1) / 2))
    back=$((keep - front))
    printf '%s%s%s\n' "${value:0:front}" "$marker" "${value: -back}"
}

window_title_for_cwd() {
    local cwd=$1
    local repo_root project prefix title

    if [[ ! -d $cwd ]]; then
        title=${cwd##*/}
        printf '%s\n' "${title:-$cwd}"
        return
    fi

    if repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
        project=${repo_root##*/}
        prefix=$(git -C "$cwd" rev-parse --show-prefix 2>/dev/null || true)
        prefix=${prefix%/}

        if [[ -n $prefix ]]; then
            title="$project/$prefix"
        else
            title=$project
        fi
    else
        title=${cwd##*/}
    fi

    printf '%s\n' "${title:-/}"
}

refresh_window() {
    local target=$1
    local cwd=${2:-}
    local auto current short title title_short fields

    fields=$(tmux display-message -p -t "$target" '#{automatic-rename}	#{pane_current_path}	#{window_name}	#{@project_window_name_short}' 2>/dev/null) || return 0
    IFS=$'\t' read -r auto cwd current short <<<"$fields"
    [[ $auto == 1 ]] || return 0

    title=$(window_title_for_cwd "$cwd")
    [[ -n $title ]] || return 0

    title_short=$(shorten_title "$title" "$max_title_chars")

    if [[ $current != "$title" ]]; then
        tmux rename-window -t "$target" "$title"
        tmux set-option -wq -t "$target" automatic-rename on
    fi

    if [[ $short != "$title_short" ]]; then
        tmux set-option -wq -t "$target" @project_window_name_short "$title_short"
    fi
}

refresh_all_windows() {
    local throttle=0
    local now last window_id auto cwd current short title title_short

    if [[ ${1:-} == "--throttle" ]]; then
        throttle=${2:-0}
    fi

    if (( throttle > 0 )); then
        now=$(date +%s)
        last=$(tmux show-options -gqv @project_window_names_refreshed_at 2>/dev/null || true)
        if [[ $last =~ ^[0-9]+$ ]] && (( now - last < throttle )); then
            return 0
        fi
        tmux set-option -gq @project_window_names_refreshed_at "$now"
    fi

    while IFS=$'\t' read -r window_id auto cwd current short; do
        [[ $auto == 1 ]] || continue

        title=$(window_title_for_cwd "$cwd")
        [[ -n $title ]] || continue

        title_short=$(shorten_title "$title" "$max_title_chars")

        if [[ $current != "$title" ]]; then
            tmux rename-window -t "$window_id" "$title"
            tmux set-option -wq -t "$window_id" automatic-rename on
        fi

        if [[ $short != "$title_short" ]]; then
            tmux set-option -wq -t "$window_id" @project_window_name_short "$title_short"
        fi
    done < <(tmux list-windows -a -F '#{window_id}	#{automatic-rename}	#{pane_current_path}	#{window_name}	#{@project_window_name_short}' 2>/dev/null)
}

if [[ ${1:-} == "--truncate" ]]; then
    shift
    if [[ ${1:-} =~ ^[0-9]+$ ]]; then
        max_title_chars=$1
        shift
    fi

    shorten_title "${1:-}" "$max_title_chars"
    exit 0
fi

if [[ ${1:-} == "--refresh-window" ]]; then
    shift
    refresh_window "${1:-}"
    exit 0
fi

if [[ ${1:-} == "--refresh-all" ]]; then
    shift
    refresh_all_windows "$@"
    exit 0
fi

cwd=${1:-$PWD}
window_title_for_cwd "$cwd"
