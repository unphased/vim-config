# Capture every interactive zsh session once.
#
# term-capture marks its direct child with that child's PID. Convert the
# exported marker into shell-local state immediately so it cannot leak through
# long-lived multiplexers, while both zprofile and zshrc can recognize the
# wrapped shell.
if [[ ${TERMPLEX_CAPTURE_CHILD_PID:-} == $$ ]]; then
  typeset -g __termplex_capture_child_pid=$$
  typeset -g +x __termplex_capture_child_pid
fi
unset TERMPLEX_CAPTURE_CHILD_PID

__termplex_maybe_start_capture() {
  local capture_bin="${TERMPLEX_CAPTURE_BIN:-$HOME/termplex/release/term-capture}"
  local capture_dir="${TERMPLEX_CAPTURE_DIR:-$HOME/.termplex/captures}"

  if [[ ! -x "$capture_bin" ]]; then
    capture_bin="${commands[term-capture]:-}"
  fi
  [[ -x "$capture_bin" ]] || return 0
  exec "$capture_bin" --pid-prefix-dir "$capture_dir" -- /bin/zsh -il
}

if [[ -o interactive && ${TERMPLEX_CAPTURE:-1} == 1 &&
      ${__termplex_capture_child_pid:-} != $$ ]] &&
   test -t 0 && test -t 1 && test -t 2; then
  __termplex_maybe_start_capture
fi
