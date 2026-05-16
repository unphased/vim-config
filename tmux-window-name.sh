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

if [[ ${1:-} == "--truncate" ]]; then
    shift
    if [[ ${1:-} =~ ^[0-9]+$ ]]; then
        max_title_chars=$1
        shift
    fi

    shorten_title "${1:-}" "$max_title_chars"
    exit 0
fi

cwd=${1:-$PWD}

if [[ ! -d $cwd ]]; then
    title=${cwd##*/}
    printf '%s\n' "${title:-$cwd}"
    exit 0
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
