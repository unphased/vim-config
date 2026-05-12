#!/bin/sh

registry=${MACHINE_COLORS_REGISTRY:-$HOME/util/machine-colors.tsv}

find_tmux() {
    if [ -n "${TMUX_BIN:-}" ]; then
        printf '%s\n' "$TMUX_BIN"
        return 0
    fi

    if command -v tmux >/dev/null 2>&1; then
        command -v tmux
        return 0
    fi

    for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

tmux_bin=$(find_tmux) || exit 0

default_status_bg=#303030
default_status_fg=#cfcfcf
default_window_bg=#242424
default_window_fg=#9a9a9a
default_current_bg=#484848
default_current_fg=#e0e0e0
default_active_border_bg=#3f3f3f
default_active_border_fg=#808080
default_border_bg=#1e1e1e
default_border_fg=#6f6f6f

remote_status_bg=#4b3157
remote_status_fg=#f0dcf7
remote_window_bg=#35243d
remote_window_fg=#c9a8d2
remote_current_bg=#6a4778
remote_current_fg=#ffffff
remote_active_border_bg=#4b3157
remote_active_border_fg=#d8a2e8
remote_border_bg=#2b1d32
remote_border_fg=#a878b5

scale_color() {
    accent=$1
    percent=$2

    awk -v accent="$accent" -v percent="$percent" '
    function hex_value(char) {
        char = tolower(char)
        return index("0123456789abcdef", char) - 1
    }

    function component(hex, start) {
        return (hex_value(substr(hex, start, 1)) * 16) + hex_value(substr(hex, start + 1, 1))
    }

    function scale_component(value, scaled) {
        scaled = int(value * percent / 100 + 0.5)
        if (scaled < 0) {
            return 0
        }
        if (scaled > 255) {
            return 255
        }
        return scaled
    }

    BEGIN {
        sub(/^#/, "", accent)
        if (accent !~ /^[0-9a-fA-F]{6}$/) {
            print "#808080"
            exit
        }

        printf "#%02x%02x%02x\n",
            scale_component(component(accent, 1)),
            scale_component(component(accent, 3)),
            scale_component(component(accent, 5))
    }
    '
}

machine_palette() {
    accent=$1

    printf '%s\t' "$(scale_color "$accent" 30)"
    printf '%s\t' "$(scale_color "$accent" 45)"
    printf '%s\t' "$(scale_color "$accent" 60)"
    printf '%s\t' "$(scale_color "$accent" 82)"
    printf '%s\n' "$(scale_color "$accent" 125)"
}

normalize_candidates() {
    {
        printf '%s\n' "${MACHINE_ID:-}"
        if [ -r /opt/machine-id ]; then
            sed -n '1p' /opt/machine-id 2>/dev/null
        fi
        hostname -s 2>/dev/null
        hostname 2>/dev/null
        uname -n 2>/dev/null
    } | awk '
    function normalize(value) {
        value = tolower(value)
        sub(/^ssh:\/\//, "", value)
        sub(/^.*@/, "", value)
        sub(/^\[/, "", value)
        sub(/\].*/, "", value)
        sub(/:[0-9]+$/, "", value)
        sub(/\.$/, "", value)
        return value
    }

    {
        value = normalize($0)
        if (value != "" && !seen[value]++) {
            print value
        }
    }
    '
}

lookup_machine_style() {
    [ -r "$registry" ] || return 1

    candidates=$(normalize_candidates | paste -sd, -)
    [ -n "$candidates" ] || return 1

    awk -F '\t' -v candidates="$candidates" '
    BEGIN {
        count = split(candidates, candidate_lines, /,/)
        for (i = 1; i <= count; i++) {
            if (candidate_lines[i] != "") {
                wanted[candidate_lines[i]] = 1
            }
        }
    }

    function normalize(value) {
        value = tolower(value)
        sub(/^ssh:\/\//, "", value)
        sub(/^.*@/, "", value)
        sub(/^\[/, "", value)
        sub(/\].*/, "", value)
        sub(/:[0-9]+$/, "", value)
        sub(/\.$/, "", value)
        return value
    }

    function alias_matches(aliases, parts, count, i) {
        count = split(aliases, parts, /,/)
        for (i = 1; i <= count; i++) {
            if (wanted[normalize(parts[i])]) {
                return 1
            }
        }
        return 0
    }

    function aliases_from_record() {
        if ($4 ~ /^#[0-9a-fA-F]{6}$/ || ($4 == "" && $5 != "")) {
            return $5
        }
        return $4
    }

    NR == 1 || $1 ~ /^#/ {
        next
    }

    wanted[normalize($1)] || alias_matches(aliases_from_record()) {
        label = $2
        accent = $3
        if (label == "") {
            label = $1
        }
        if (accent == "") {
            accent = "#a980b6"
        }
        printf "%s\t%s", label, accent
        exit
    }
    ' "$registry"
}

apply_style() {
    status_bg=$1
    status_fg=$2
    window_bg=$3
    window_fg=$4
    current_bg=$5
    current_fg=$6
    active_border_bg=$7
    active_border_fg=$8
    border_bg=$9
    shift 9
    border_fg=$1

    "$tmux_bin" set -g status-bg "$status_bg"
    "$tmux_bin" set -g status-fg "$status_fg"
    "$tmux_bin" setw -g window-status-style "bg=$window_bg,fg=$window_fg"
    "$tmux_bin" setw -g window-status-current-style "bg=$current_bg,fg=$current_fg,bold"
    "$tmux_bin" setw -g pane-active-border-style "bg=$active_border_bg,fg=$active_border_fg"
    "$tmux_bin" setw -g pane-border-style "bg=$border_bg,fg=$border_fg"
}

apply_status_left() {
    session_bg=$1
    session_fg=$2
    socket_fg=$3

    "$tmux_bin" set -g status-left "#[reverse]#{?client_prefix,#[fg=red] TMUX #[noreverse]#[bg=$session_bg]#[reverse]#[bg=default],}#[fg=$socket_fg] #{s|.*/||:,#{socket_path}} #[fg=$session_fg]#[bg=$session_bg] #{session_name} "
}

machine_style=$(lookup_machine_style)
if [ -n "$machine_style" ]; then
    label=${machine_style%%	*}
    accent=${machine_style#*	}

    "$tmux_bin" set -g @machine_color_label "$label"
    "$tmux_bin" set -g @machine_color_accent "$accent"
    palette=$(machine_palette "$accent")
    old_ifs=$IFS
    IFS='	'
    set -- $palette
    IFS=$old_ifs
    level1=$1
    level2=$2
    level3=$3
    level4=$4
    level5=$5
    "$tmux_bin" set -g @machine_color_foreground "$level1"
    apply_style "$level2" "$level5" "$level1" "$level4" "$level3" "$level5" "$level3" "$level5" "$level2" "$level4"
    apply_status_left "$level3" "$level1" "$level4"
elif [ "${TMUX_SSH_BOUNDARY:-}" = 1 ]; then
    "$tmux_bin" set -g @machine_color_label ""
    "$tmux_bin" set -g @machine_color_accent ""
    "$tmux_bin" set -g @machine_color_foreground ""
    apply_style "$remote_status_bg" "$remote_status_fg" "$remote_window_bg" "$remote_window_fg" "$remote_current_bg" "$remote_current_fg" "$remote_active_border_bg" "$remote_active_border_fg" "$remote_border_bg" "$remote_border_fg"
    apply_status_left "$remote_current_bg" "#241b28" "$remote_active_border_fg"
else
    "$tmux_bin" set -g @machine_color_label ""
    "$tmux_bin" set -g @machine_color_accent ""
    "$tmux_bin" set -g @machine_color_foreground ""
    apply_style "$default_status_bg" "$default_status_fg" "$default_window_bg" "$default_window_fg" "$default_current_bg" "$default_current_fg" "$default_active_border_bg" "$default_active_border_fg" "$default_border_bg" "$default_border_fg"
    apply_status_left "#606060" "#303030" "#606060"
fi
