#!/bin/bash

echo Hello from aliases.sh
# todo: make me a function
# idempotent alias check (or prints existing alias -- might wanna suppress that 
# too)
alias ls 2>/dev/null >/dev/null || alias ls="ls --color=always"

# some versions of htop kill high sierra without being run as root.
# TODO replace me with a version check on htop
# Nah, it's ok. just make sure your system has 2.2.0 or newer and just dont 
# worry about it.
# if [[ "$(uname -a)" =~ "Darwin Kernel Version 17" ]]; then
# 	alias htop="sudo htop"
# fi

if [ "$(uname)" = Linux ] && lsb_release -i | grep Ubuntu; then
	alias open="xdg-open"
fi

# black ass magic
export TERMINFO_DIRS=$TERMINFO_DIRS:$HOME/.local/share/terminfo

alias vv="v ~/.vim/nvim/init.lua"
alias vp="~/.vim/nvim/monitored_autoload_nvim.sh -O ~/.vim/nvim/lua/plugins.lua ~/.vim/nvim/init.lua"
alias l="ls -rt"
alias sl="ls"
alias ll="l -lha"
# alias la="ll -a"
alias ssht="TERM=xterm-256color ssh"
alias v="nvim"
alias vd='v $(git diff --name-only | while read file; do printf "$(git rev-parse --show-toplevel)/$file "; done) -O'
alias g="git"
alias gs="git s" # short status 
alias gco="git checkout"
alias gta="git ta"
alias gtap="git tap"
alias gte="git te"
if [[ -n "${ZSH_VERSION:-}" ]]; then
  # In zsh with extendedglob enabled, `^slu` expands to "everything except slu".
  # The notes helpers intentionally use `^<ref>` shorthands, so disable globbing
  # for these commands to prevent accidental expansion into filenames.
  alias gn="noglob git gn"
  alias gne="noglob git gn --edit"
  alias gnr="noglob git nr"
else
  alias gn="git gn"
  alias gne="git gn --edit"
  alias gnr="git nr"
fi
gnl() {
  local -a refs
  refs=($(git for-each-ref refs/notes --format='%(refname)' 2>/dev/null))
  if [[ ${#refs[@]} -eq 0 ]]; then
    echo "gnl: no refs/notes/* found" >&2
    return 1
  fi
  git log --graph --oneline "${refs[@]}"
}

gnlp() {
  local -a refs
  refs=($(git for-each-ref refs/notes --format='%(refname)' 2>/dev/null))
  if [[ ${#refs[@]} -eq 0 ]]; then
    echo "gnlp: no refs/notes/* found" >&2
    return 1
  fi
  git log --graph --oneline -p "${refs[@]}"
}

gnls() {
  local -a refs
  refs=($(git for-each-ref refs/notes --format='%(refname)' 2>/dev/null))
  if [[ ${#refs[@]} -eq 0 ]]; then
    echo "gnls: no refs/notes/* found" >&2
    return 1
  fi
  git log --graph --oneline --stat "${refs[@]}"
}

# Notes DAG, patch view (mnemonic: git log notes -p)
alias glnp="gnlp"
alias glpo="git --no-pager log -p --color=always | less"
alias glpa="git log -p --all"
alias glpf="git log -p --follow"
alias glp="git log -p"
alias glpe="GIT_EXTERNAL_DIFF=sift GIT_PAGER=less git log -p --ext-diff --pretty=format:'%C(bold yellow)%H%Creset%C(auto)%d%Creset %s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset'"
alias glpen="git --no-pager log -p --color=always | less"
# alias glpes="git log -p --ext-diff --stat"
alias gd="git --no-pager diff --color=always | less"
alias gf='git fetch'
alias gds="git diff --stat"
alias di="git diff-with-ignored"
alias gc!="git commit --amend"

alias gsp="git stash pop"

# unfortunately the mnemonic of ext is sticking, so even though difftool is used to run sift 
# i will keep using the "e"
alias gde="GIT_EXTERNAL_DIFF=sift GIT_PAGER=less git diff --ext-diff"
alias de="gde"
alias gdc="gd --cached"
#unalias gg # some git gui thing from ohmyzsh
alias gg="git lgt --all"
alias ggn="git lgt --all --include-notes-dag"
alias gfp="git push --force-with-lease" # for force push when e.g. amending
alias ggs="git lgt --all --stat"
alias ggsn="git lgt --all --stat --include-notes-dag"
alias gca="git commit -av"
alias gcm="git commit-message"
#unalias gcp # I rarely cherry pick (if not using ohmyzsh, this will cause bash to emit a warning)

alias gc="git commit -v"

alias gp="git push"
alias k="l" # this is a bit tongue in cheek

alias gl="git pull"

alias gr="git remote"

# actually zsh with prezto won't need this since it has its own fallback 
# mechanism for make. But, this is useful in e.g. bash.
which colormake > /dev/null 2>&1 && alias make="colormake"

alias mk="make"
alias gcp="git commit-push"

alias gcb='git checkout -b'

#Dupes of useful ones from omz
alias gp="git push"
alias gst="git status-with-ignored"
alias ga="git add"
alias gb="git branch"

alias ds="dirs -v | head -10"
alias d="g diff --no-ext-diff"

alias nri="rm -rf ./node_modules/ && npm i"

# alias ts="tmux split-window"
# # V is the easier mnemonic. But in tmux parlance this is a horizontal split.
# alias tv="tmux split-window -h"

# alias iack="ack -i"

# if [ "$(uname)" != "MSYS_NT-10.0" ]; then
# 	alias vim="TERM=xterm-256color-italic vim"
# fi

alias c="cd"

# TODO: deal with this abomination (i.e. make it worse by generalizing it)
if [[ $(uname) == Linux ]]; then
	# need to use a non custom term to not confuse nano. Also enabling the 
	# experimental undo functionality for nano
	alias nano="TERM=xterm-256color nano -u"
	# # this is a trick seen here http://superuser.com/a/479816/98199
	# # it is slightly horrifying and basically turns sudo into a function now. It 
	# # will quickly be seen whether this is a sane approach
	# function sudo() {
	# 	case $* in
	# 		nano* ) shift 1; TERM=xterm-256color command sudo nano -u "$@" ;;
	# 		* ) command sudo "$@" ;;
	# 	esac
	# }

	# We can compile and install a newer nano on OSX but there is DEFINITELY no 
	# reason to use it over vim on a machine running OSX. None at all.
fi

alias dc="cd"

# Very useful command debugger
BLACK="\x1b[30m"
RESET="\x1b[0m"
execute () {
  CTR=1
  echo "Executing the following:"
  for arg in "$@"; do
    printf "$BLACK"'$'"%s=$RESET%s " $CTR "$arg"
    (( CTR ++ ))
  done
  echo "" # new line
  "$@"
}

# unfortunately this is turning into a place where i collect environment 
# settings for both zsh/bash. Not that theres anything wrong with that per se, 
# but it means this file shouldn't be called aliases.sh any longer...

# fix TERM=screen-* causing LESS to use italics.
export LESS_TERMCAP_mb=$'\E[1;31m'       # begin blinking
export LESS_TERMCAP_md=$'\E[1;38;5;74m'  # begin bold
export LESS_TERMCAP_me=$'\E[0m'           # end mode
export LESS_TERMCAP_se=$'\E[0m'          # end standout-mode (clear bg)
export LESS_TERMCAP_so=$'\E[30;48;5;74m'    # begin standout-mode / info box (use bgcolor)
export LESS_TERMCAP_ue=$'\E[0m'           # end underline
export LESS_TERMCAP_us=$'\E[4;38;5;146m' # begin underline

export OSTYPE

# # because omz people are slightly incompetent and regressed these aliases i did 
# # start to use (these may come back later when #4585 completes)
alias gdc='git diff --cached'
alias gap='git add --patch'
alias gsl="git stash list -p --ext-diff | sed -e 's/^stash@\\(.*\\)/[33m[7m\\1[m/'"

alias grepc='grep --color=always --exclude=\*{.,-}min.\*'
# alias cack='ack --color'
# alias ackc='ack --color'
# alias agc='ag --color'
alias mkae='make'

# only for macos
if [[ "$(uname -a)" =~ "Darwin Kernel" ]]; then
  alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi

# to make fzf's file finding usage (mainly when using vim but should work for 
# non-vim) work like i want, which is let me comb through all the files ever. 
# Except for git repoes.
export FZF_DEFAULT_COMMAND="fd --type file"

# i'm trying to not export PATH in the aliases script here. But, so far it is 
# my only way to dedupe a sane config across OS's, bash & omz & prezto.

# set PATH so it includes user's private bin directories
export PATH="$HOME/.cargo/bin:$HOME/bin:$HOME/.local/bin:$PATH"

export PATH=$HOME/util:$PATH

# source $HOME/.vim/work/aliases/rtr.sh

# Not sure how i feel about this but it's how they want it done
export PATH=$PATH:/usr/local/go/bin

export EDITOR=nvim

# for pip3 on macos (ehhhh)
# [[ -d $HOME/Library/Python/3.8/bin && ! "$PATH" =~ $HOME/Library/Python/3.8/bin ]] && export 
# PATH=$HOME/Library/Python/3.8/bin:$PATH

# for when tmux panes lose the ssh agent env vars
fixssh() {
  eval $(tmux show-env -s |grep '^SSH_')
}

# for adam costello's par
export PARINIT="rTbgqR B=.,?'_A_a_@ Q=_s>|"

export MACHINE_ID=$(cat /opt/machine-id)
export GIT_DELTA_HYPERLINK_FORMAT="file://$MACHINE_ID{path}:{line}"

## this alias broke all of git tab completions but curiously only for macos.
# alias git="git --config-env=delta.hyperlinks-file-link-format=GIT_DELTA_HYPERLINK_FORMAT"

# Temporarily pointing aider at local install. This may be temporary as pipx does a decent job of maintaining it
# normally but This is the cleanest way i came up with so far to quickly target a local install IF ONE EXISTS.
AIDER_PROGRAM=~/aider/venv/bin/aider
AIDER_PROGRAM2=~/.local/bin/aider
AIDER_CMD=aider

if [[ -x "$AIDER_PROGRAM2" ]]; then
  echo "Note: aider has been found at (secondary location) $AIDER_PROGRAM2."
  AIDER_CMD="$AIDER_PROGRAM2"
fi

if [[ -x "$AIDER_PROGRAM" ]]; then
  echo "Note: aider has been found at $AIDER_PROGRAM."
  AIDER_CMD="$AIDER_PROGRAM"
fi

aider_function() {
  # Push title to stack
  echo -ne "\033[22;0t"
  # Set title
  echo -ne "\033]0;AIDER\007"
  # Set trap to restore title when exiting aider
  trap 'echo -ne "\033[23;0t"; trap - INT TERM EXIT' INT TERM EXIT
  "$AIDER_CMD" "$@"
  # Restore the title after aider finishes
  echo -ne "\033[23;0t"
  # Remove the trap after finishing
  trap - INT TERM EXIT
}

alias aider='aider_function'

nv() {
  local launcher
  launcher="$(command -v neovide-launch.sh 2>/dev/null || true)"
  [[ -n "$launcher" ]] || launcher="neovide"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ( NEOVIDE_FRAME=transparent "$launcher" "$@" & )
  else
    ( NEOVIDE_FRAME=full "$launcher" "$@" & )
  fi
}

# just sets the N prefix to a sane and safe location in home dir. Although the default is reasonable and works almost
# out of the box on macos (it isn't though, on account of /usr/local/n needing chowning) the default path does not work
# on linux without perm shenanigans. So this is a good way to establish a better N prefix to use.
export N_PREFIX=$HOME/.n
export PATH=$N_PREFIX/bin:$PATH
# note on some systems specifically ones where i dont set up THIS script, it's fine and low effort to just run n with
# sudo, it's not like that will affect the user running node.

# Machine specific/contextual visual stuff!
# - tmux status bar will have a salient color specific to machines/environments. To make this work an env var is
#   provided for tmux config to leverage.
# - non tmux shell environment will have entire shell bgcolor set to a subtler version of that color.
# - root shells will have a salient bgcolor? (not sure about this one as root shell wont be running my zsh and easy to
# recognize)

# Still planning -- I might try to define these colors in the hardware mac address file. we'll see...

alias civ="civit_dl"

# Sucks it took me 10 years longer than it should have to derive these helpers
alias last2='!-2 && !!'
alias last3='!-3 && !-2 && !!'
alias last4='!-4 && !-3 && !-2 && !!'
alias last5='!-5 && !-4 && !-3 && !-2 && !!'
alias last6='!-6 && !-5 && !-4 && !-3 && !-2 && !!'
