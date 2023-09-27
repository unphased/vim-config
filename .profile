stty -ixon
stty -ixoff

export HISTSIZE=20000
export HISTFILESIZE=40000
export HISTTIMEFORMAT="%d/%m/%y %T "

# avoid duplicates.. 
export HISTCONTROL=ignoredups
# append history entries.. 
shopt -s histappend
shopt -s lithist
shopt -s histverify


export LESS='-g -i -M -R -z-4'

source $HOME/.aliases.sh
# Remember to link this to ~/.bash_profile if it doesn't exist. (more robust 
# than .bashrc)

which brew > /dev/null && if [ -f `brew --prefix`/etc/bash_completion ]; then
    # TODO: make this check better...
    . `brew --prefix`/etc/bash_completion
fi

[ -f /usr/share/bash-completion/completions/git ] && . /usr/share/bash-completion/completions/git

# a few helpers that have to match aliases
__git_complete gco _git_checkout
__git_complete g __git_main
__git_complete gd _git_diff
__git_complete d _git_diff

if [[ $MSYSTEM == MSYS ]]; then
	export PATH="$ORIGINAL_TEMP/../../Roaming/npm/:$PATH"
	export PATH=/c/Program\ Files/nodejs/:/c/Python27/:/mingw64/bin/:$PATH
	export PATH=/c/Program\ Files/neovim/bin/:$PATH
fi

echo 'Hi from ~/.profile'

# The following thanks to @Jonathan M Davis from SO
pushd()
{
  if [ $# -eq 0 ]; then
    DIR="${HOME}"
  else
    DIR="$1"
  fi

  builtin pushd "${DIR}" > /dev/null
  echo -n "DIRSTACK: "
  dirs
}

pushd_builtin()
{
  builtin pushd > /dev/null
  echo -n "DIRSTACK: "
  dirs
}

popd()
{
  builtin popd > /dev/null
  echo -n "DIRSTACK: "
  dirs
}

alias cd='pushd'
alias back='popd'
alias flip='pushd_builtin'
alias ..='cd ..'

# implement the helpers for changing dirs
alias 1='cd ~1'
alias 2='cd ~2'
alias 3='cd ~3'
alias 4='cd ~4'
alias 5='cd ~5'
alias 6='cd ~6'
alias 7='cd ~7'
alias 8='cd ~8'
alias 9='cd ~9'
alias 10='cd ~10'
alias 11='cd ~11'
alias 12='cd ~12'
alias 13='cd ~13'
alias 14='cd ~14'
alias 15='cd ~15'
alias 16='cd ~16'

# The following thanks to @Nicolas Thery from SO

function timer_now {
    date +%s%N
}

function timer_start {
    timer_start=${timer_start:-$(timer_now)}
}

function timer_stop {
    local delta_us=$((($(timer_now) - $timer_start) / 1000))
    local us=$((delta_us % 1000))
    local ms=$(((delta_us / 1000) % 1000))
    local s=$(((delta_us / 1000000) % 60))
    local m=$(((delta_us / 60000000) % 60))
    local h=$((delta_us / 3600000000))
    # Goal: always show around 3 digits of accuracy
    if ((h > 0)); then timer_show=${h}h${m}m
    elif ((m > 0)); then timer_show=${m}m${s}s
    elif ((s >= 10)); then timer_show=${s}.$((ms / 100))s
    elif ((s > 0)); then timer_show=${s}.$(printf %03d $ms)s
    elif ((ms >= 100)); then timer_show=${ms}ms
    elif ((ms > 0)); then timer_show=${ms}.$((us / 100))ms
    else timer_show=${us}us
    fi
    unset timer_start
}


set_prompt () {
    Last_Command=$? # Must come first!
    Blue='\[\e[01;34m\]'
    White='\[\e[01;37m\]'
    Red='\[\e[01;31m\]'
    Green='\[\e[01;32m\]'
    Reset='\[\e[00m\]'
    FancyX='\342\234\227'
    Checkmark='\342\234\223'

    history -a

    # Add a bright white exit status for the last command
    PS1="$White\$? "
    # If it was successful, print a green check mark. Otherwise, print
    # a red X.
    if [[ $Last_Command == 0 ]]; then
        PS1+="$Green$Checkmark "
    else
        PS1+="$Red$FancyX "
    fi

    # Add the ellapsed time and current date
    timer_stop
    PS1+="($timer_show) \t "

    # If root, just print the host in red. Otherwise, print the current user
    # and host in green.
    if [[ $EUID == 0 ]]; then
        PS1+="$Red\\u$Green@\\h "
    else
        PS1+="$Green\\u@\\h "
    fi
    # Print the working directory and prompt marker in blue, and reset
    # the text color to the default.
    PS1+="$Blue\\w\n\\\$$Reset "
}

# if [[ "$TERM_PROGRAM" == "iTerm.app" ]]; then
#     source ~/.vim/.iterm2_shell_integration.bash
# else
    trap 'timer_start' DEBUG
    PROMPT_COMMAND='set_prompt'
# fi

export PATH="$HOME/.cargo/bin:$PATH"

[ -f ~/.fzf.bash ] && source ~/.fzf.bash
