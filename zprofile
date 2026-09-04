# echo Hi from ~/.zprofile

# This login-shell file is the bootstrap anchor: warn if an installer or dotfiles
# update has redirected zshrc before the tracked configuration gets a chance to run.
if [[ -o interactive && ! "$HOME/.zshrc" -ef "$HOME/.vim/zshrc" ]]; then
  print -u2 -- "warning: ~/.zshrc is not linked to ~/.vim/zshrc; this shell may be using stale configuration"
fi

# Dogfood term-capture around the complete login shell, before zshrc performs
# expensive interactive initialization. The child inherits the latch and
# proceeds through zprofile/zshrc without wrapping itself again.
__termplex_maybe_start_capture() {
  local capture_bin="${TERMPLEX_CAPTURE_BIN:-$HOME/termplex/release/term-capture}"
  local capture_dir="${TERMPLEX_CAPTURE_DIR:-$HOME/.termplex/captures}"

  if [[ ! -x "$capture_bin" ]]; then
    capture_bin="${commands[term-capture]:-}"
  fi
  [[ -x "$capture_bin" ]] || return 0
  export TERMPLEX_CAPTURE_ACTIVE=1
  exec "$capture_bin" --pid-prefix-dir "$capture_dir" -- /bin/zsh -il
}

if [[ -o interactive && ${TERMPLEX_CAPTURE:-1} == 1 &&
      -z ${TERMPLEX_CAPTURE_ACTIVE:-} ]] && test -t 0 && test -t 1 && test -t 2; then
  __termplex_maybe_start_capture
fi

# Homebrew supplies login-shell tools used before zshrc is fully initialized,
# including quickdash dependencies such as htop and watch.
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Keep the old pinned Node/Python overrides disabled; Homebrew itself is enough
# for the shell integrations tested so far.
# export PATH="/opt/homebrew/opt/node@16/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/python@3/Frameworks/Python.framework/Versions/Current/bin:$PATH"

[[ -r ~/.sensitive_app_access_tokens.sh ]] && source ~/.sensitive_app_access_tokens.sh

export PATH="$HOME/go/bin:$PATH"

if [[ -n "${GHOSTTY_QUICK_TERMINAL:-}" && -z "${TMUX:-}" ]]; then
  exec "$HOME/.vim/ghostty-quickdash.sh"
fi
