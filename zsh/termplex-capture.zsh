# Capture every interactive zsh session once.
#
# The capture wrapper starts another interactive login zsh. Do not use an
# inherited environment latch here: long-lived multiplexers can inherit that
# variable and later launch independent shells that still need capture. The
# immediate-parent check distinguishes the wrapper's child from a new shell
# launched by tmux, Herdr, a terminal, or another shell.
__termplex_capture_parent_is_wrapper() {
  local parent_command
  parent_command=$(ps -ww -p "$PPID" -o command= 2>/dev/null) || return 1
  [[ "$parent_command" == *term-capture* ]]
}

__termplex_maybe_start_capture() {
  local capture_bin="${TERMPLEX_CAPTURE_BIN:-$HOME/termplex/release/term-capture}"
  local capture_dir="${TERMPLEX_CAPTURE_DIR:-$HOME/.termplex/captures}"

  if [[ ! -x "$capture_bin" ]]; then
    capture_bin="${commands[term-capture]:-}"
  fi
  [[ -x "$capture_bin" ]] || return 0
  exec "$capture_bin" --pid-prefix-dir "$capture_dir" -- /bin/zsh -il
}

if [[ -o interactive && ${TERMPLEX_CAPTURE:-1} == 1 ]] &&
   ! __termplex_capture_parent_is_wrapper &&
   test -t 0 && test -t 1 && test -t 2; then
  __termplex_maybe_start_capture
fi
