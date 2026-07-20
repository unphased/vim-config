# echo Hi from ~/.zprofile

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
