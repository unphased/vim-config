# echo Hi from ~/.zprofile

# This login-shell file is the bootstrap anchor: warn if an installer or dotfiles
# update has redirected zshrc before the tracked configuration gets a chance to run.
if [[ -o interactive && ! "$HOME/.zshrc" -ef "$HOME/.vim/zshrc" ]]; then
  print -u2 -- "warning: ~/.zshrc is not linked to ~/.vim/zshrc; this shell may be using stale configuration"
fi

# Start capture before zshrc performs expensive interactive initialization.
# The shared helper is also sourced by zshrc so non-login interactive shells
# (such as fresh tmux panes) are captured too.
# TEMP: disabled while testing Herdr cwd and agent detection through a direct PTY.
# source "$HOME/.vim/zsh/termplex-capture.zsh"

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
