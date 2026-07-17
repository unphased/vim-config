# echo Hi from ~/.zprofile

# Leave zsh vi mode enabled, but make delayed Esc+p/P inert. A stray Esc can
# enter vi command mode, then a later p/P can paste clipboard text at the prompt.
__disable_zsh_vi_put_keys() {
  [[ -o interactive ]] || return

  bindkey -M vicmd 'p' undefined-key 2>/dev/null
  bindkey -M vicmd 'P' undefined-key 2>/dev/null
  precmd_functions=(${precmd_functions:#__disable_zsh_vi_put_keys})
}

if [[ -z "${precmd_functions[(r)__disable_zsh_vi_put_keys]:-}" ]]; then
  precmd_functions+=(__disable_zsh_vi_put_keys)
fi

# Note, the following is insufficient to set homebrew env vars in the proper spots.
eval "$(/opt/homebrew/bin/brew shellenv)"

export PATH="/opt/homebrew/opt/node@16/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/python@3/Frameworks/Python.framework/Versions/Current/bin:$PATH"

source ~/.sensitive_app_access_tokens.sh

export PATH="$HOME/go/bin:$PATH"

if [[ -n "${GHOSTTY_QUICK_TERMINAL:-}" && -z "${TMUX:-}" ]]; then
  exec "$HOME/.vim/ghostty-quickdash.sh"
fi


# Added by Antigravity CLI installer
export PATH="/Users/slu/.local/bin:$PATH"
