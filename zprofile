# echo Hi from ~/.zprofile

# Disabled while testing whether the inherited macOS environment already makes
# Homebrew and the pinned Node/Python installations available. Re-enable only
# the smallest missing piece if a fresh login shell proves otherwise.
# eval "$(/opt/homebrew/bin/brew shellenv)"
# export PATH="/opt/homebrew/opt/node@16/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/python@3/Frameworks/Python.framework/Versions/Current/bin:$PATH"

[[ -r ~/.sensitive_app_access_tokens.sh ]] && source ~/.sensitive_app_access_tokens.sh

export PATH="$HOME/go/bin:$PATH"

if [[ -n "${GHOSTTY_QUICK_TERMINAL:-}" && -z "${TMUX:-}" ]]; then
  exec "$HOME/.vim/ghostty-quickdash.sh"
fi
