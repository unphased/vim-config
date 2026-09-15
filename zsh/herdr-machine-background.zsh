# Wrap Herdr's TUI attach commands with the machine background.

__herdr_report_shell_process_title() {
  [[ ${HERDR_ENV:-} == 1 && -n ${HERDR_PANE_ID:-} ]] || return 0

  command herdr pane report-metadata "$HERDR_PANE_ID" \
    --source zsh:process-title --title "zsh pid=$$ ppid=$PPID" \
    >/dev/null 2>&1
}

__herdr_clear_shell_process_title_for_pi() {
  [[ ${HERDR_ENV:-} == 1 && -n ${HERDR_PANE_ID:-} ]] || return 0
  [[ ${1:-} == pi || ${1:-} == pi[[:space:]]* ]] || return 0

  command herdr pane report-metadata "$HERDR_PANE_ID" \
    --source zsh:process-title --clear-title \
    >/dev/null 2>&1
}

_herdr_tui_attach() {
  (( $# == 0 )) && return 0
  if [[ "$1" == session ]]; then
    [[ $# == 3 && "$2" == attach && -n "$3" && "$3" != -* ]]
    return $?
  fi

  local saw_attach_option=false
  while (( $# )); do
    case "$1" in
      --session|--remote)
        (( $# >= 2 )) && [[ -n "$2" && "$2" != -* ]] || return 1
        saw_attach_option=true
        shift 2
        ;;
      --session=*|--remote=*)
        [[ -n "${1#*=}" ]] || return 1
        saw_attach_option=true
        shift
        ;;
      --remote-keybindings)
        (( $# >= 2 )) || return 1
        shift 2
        ;;
      --remote-keybindings=*|--handoff)
        shift
        ;;
      *)
        return 1
        ;;
    esac
  done

  [[ "$saw_attach_option" == true ]]
}

herdr() {
  if ! _herdr_tui_attach "$@"; then
    command herdr "$@"
    return $?
  fi

  local machine_style_script="${HOME}/.vim/tmux-apply-machine-style.sh"
  local project_bgcolor_script="${HOME}/util/bgcolor.sh"
  local project_dir="$PWD"
  local machine_bg herdr_status

  if [[ ! -x "$machine_style_script" ]]; then
    command herdr "$@"
    return $?
  fi

  machine_bg="$($machine_style_script --print-background 2>/dev/null)" || {
    command herdr "$@"
    return $?
  }
  if [[ ! "$machine_bg" =~ '^#[0-9A-Fa-f]{6}$' ]]; then
    command herdr "$@"
    return $?
  fi

  printf '\033]11;%s\033\\' "$machine_bg"
  {
    command herdr "$@"
  } always {
    herdr_status=$?
    if [[ -x "$project_bgcolor_script" ]]; then
      "$project_bgcolor_script" "$project_dir" 2>/dev/null || true
    fi
  }

  return $herdr_status
}
