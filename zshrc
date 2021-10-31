echo Hi from ~/.zshrc

. "$HOME/.cargo/env"
eval "$(/opt/homebrew/bin/brew shellenv)"

. $HOME/.aliases.sh
echo path after aliases:

echo "$(echo ${PATH} | tr : '\n')"

export PATH="/opt/homebrew/opt/node@16/bin:$PATH"

autoload -Uz compinit && compinit

eval "$(starship init zsh)"

setopt NO_CASE_GLOB
setopt AUTO_CD
setopt CORRECT
setopt CORRECT_ALL
setopt APPEND_HISTORY
setopt EXTENDED_HISTORY
setopt INC_APPEND_HISTORY_TIME
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_FIND_NO_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY

# set emacs key mode so it doesnt eat ctrl+R
bindkey -e

# allow ctrl+s to work
stty -ixon
stty -ixoff

bindkey "\e" backward-delete-word

bindkey "\eOc" forward-word
bindkey "\eOd" backward-word

# ctrl
bindkey "\e[1;5C" forward-word
bindkey "\e[1;5D" backward-word

# alt
bindkey "\e[1;3C" forward-word
bindkey "\e[1;3D" backward-word

# shift
bindkey "\e[1;2C" forward-word
bindkey "\e[1;2D" backward-word

bindkey "\e[5C" forward-word
bindkey "\e[5D" backward-word
bindkey "\e\e[C" forward-word
bindkey "\e\e[D" backward-word

# home/end
bindkey "\e[1~" beginning-of-line
bindkey "\e[4~" end-of-line

# ignore filepaths used for corrections.
# See https://unix.stackexchange.com/a/422451/12497
export CORRECT_IGNORE_FILE='.*'

bindkey "^[[A" history-beginning-search-backward
bindkey "^[[B" history-beginning-search-forward
