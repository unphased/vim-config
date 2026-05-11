#!/bin/sh

pane_pid=$1
mode=${2:-border}

case $pane_pid in
    ''|*[!0-9]*)
        exit 0
        ;;
esac

ps -axo pid=,ppid=,comm=,args= 2>/dev/null | awk -v root="$pane_pid" -v mode="$mode" '
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

    if (mode == "compact") {
        printf "#[fg=#241b28]#[bg=#a980b6]#[bold]%s#[default] ", label
    } else {
        printf "#[fg=#241b28]#[bg=#a980b6]#[bold] %s #[default] ", label
    }
}
'
