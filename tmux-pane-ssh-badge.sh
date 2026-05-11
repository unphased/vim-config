#!/bin/sh

pane_pid=$1
mode=${2:-border}
cache_ttl=${TMUX_PANE_SSH_BADGE_CACHE_TTL:-2}

case $pane_pid in
    ''|*[!0-9]*)
        exit 0
        ;;
esac

case $cache_ttl in
    ''|*[!0-9]*)
        cache_ttl=2
        ;;
esac

cache_owner=$(id -u 2>/dev/null || printf unknown)
cache_dir="${TMPDIR:-/tmp}/tmux-pane-ssh-badge-$cache_owner"
cache_file="$cache_dir/$pane_pid.label"

render_badge() {
    label=$1

    [ -n "$label" ] || exit 0

    if [ "$mode" = compact ]; then
        printf '#[fg=#241b28]#[bg=#a980b6]#[bold]%s#[default] ' "$label"
    else
        printf '#[fg=#241b28]#[bg=#a980b6]#[bold] %s #[default] ' "$label"
    fi
}

now=$(date +%s 2>/dev/null || printf 0)
if [ -r "$cache_file" ] && [ "$now" -gt 0 ]; then
    {
        IFS= read -r cached_at
        IFS= read -r cached_label
    } <"$cache_file"

    case $cached_at in
        ''|*[!0-9]*)
            ;;
        *)
            if [ $((now - cached_at)) -le "$cache_ttl" ]; then
                render_badge "$cached_label"
                exit 0
            fi
            ;;
    esac
fi

emit_process_table() {
    if ps -axo pid=,ppid=,comm=,args= 2>/dev/null; then
        return 0
    fi

    if command -v gps >/dev/null 2>&1 && gps -axo pid=,ppid=,comm=,args= 2>/dev/null; then
        return 0
    fi

    ps -eo pid=,ppid=,comm=,args= 2>/dev/null
}

label=$(emit_process_table | awk -v root="$pane_pid" '
function basename(path) {
    sub(/^.*\//, "", path)
    return path
}

function needs_option_arg(opt) {
    return opt ~ /^-[bcDEeFIiJLlmOoPpQRSWw]$/
}

function ssh_command_name(command, args, tokens, executable) {
    command = basename(command)
    executable = command
    if (executable != "ssh" && executable != "ssh.exe" && executable != "autossh" && executable != "mosh" && executable != "mosh-client") {
        split(args, tokens, /[[:space:]]+/)
        executable = basename(tokens[1])
    }

    if (executable == "ssh" || executable == "ssh.exe" || executable == "autossh") {
        return "SSH"
    }
    if (executable == "mosh" || executable == "mosh-client") {
        return "MOSH"
    }
    return ""
}

function clean_destination(destination) {
    sub(/^ssh:\/\//, "", destination)
    sub(/^.*@/, "", destination)
    if (destination ~ /^\[/) {
        sub(/^\[/, "", destination)
        sub(/\].*/, "", destination)
        return destination
    }
    sub(/:[0-9]+$/, "", destination)
    sub(/,$/, "", destination)
    return destination
}

function destination_from_args(command, args, tokens, count, i, token, skip_next) {
    command = basename(command)

    if (command == "mosh-client") {
        return "mosh"
    }

    count = split(args, tokens, /[[:space:]]+/)
    skip_next = 0
    for (i = 2; i <= count; i++) {
        token = tokens[i]
        if (token == "") {
            continue
        }
        if (skip_next) {
            skip_next = 0
            continue
        }
        if (token == "--") {
            continue
        }
        if (token ~ /^-/) {
            if (needs_option_arg(token)) {
                skip_next = 1
            }
            continue
        }
        return clean_destination(token)
    }

    return ""
}

function depth_from_root(pid, parent_pid, depth) {
    depth = 0
    while (pid in ppid_by_pid) {
        if (pid == root) {
            return depth
        }
        parent_pid = ppid_by_pid[pid]
        if (parent_pid == pid || parent_pid == "") {
            return -1
        }
        pid = parent_pid
        depth++
    }
    return -1
}

{
    pid = $1
    ppid = $2
    command = $3
    args = ""
    for (i = 4; i <= NF; i++) {
        args = args (args == "" ? "" : " ") $i
    }

    ppid_by_pid[pid] = ppid
    command_by_pid[pid] = command
    args_by_pid[pid] = args
}

END {
    best_pid = ""
    best_depth = -1

    for (pid in ppid_by_pid) {
        label = ssh_command_name(command_by_pid[pid], args_by_pid[pid])
        if (label == "") {
            continue
        }

        depth = depth_from_root(pid)
        if (depth < 0) {
            continue
        }

        if (best_depth < 0 || depth < best_depth) {
            best_depth = depth
            best_pid = pid
        }
    }

    if (best_pid == "") {
        exit
    }

    label = ssh_command_name(command_by_pid[best_pid], args_by_pid[best_pid])
    destination = destination_from_args(command_by_pid[best_pid], args_by_pid[best_pid])
    if (destination != "") {
        label = label " " destination
    }

    printf "%s", label
}
')

if mkdir -p "$cache_dir" 2>/dev/null; then
    chmod 700 "$cache_dir" 2>/dev/null
    cache_tmp="$cache_file.$$"
    {
        printf '%s\n' "$now"
        printf '%s\n' "$label"
    } >"$cache_tmp" 2>/dev/null && mv "$cache_tmp" "$cache_file" 2>/dev/null
fi

render_badge "$label"
