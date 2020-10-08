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

# stub pbcopy and pbpaste for linux, for getting a little closer to copypaste 
# holy grail for my usual envs. Still not gonna have direct vim clipboard 
# compatibility (that's vim-specific, and can interact with this), but it def 
# makes life easier in the shell.
if [ "$(uname)" = Linux ] && ! [[ "$PATH" = *"/linux_pb"* ]] && ! xset q &>/dev/null; then
	# This ensures that these fallback filesystem clipboard programs become 
	# available for vim to use if X is not running, regardless of whether 
	# X exists on the system. In particular we insert linux_pb earlier in the 
	# path than /usr/local/bin should be, and the environment will control 
	# which program is pulled on a system.
	PATH="$HOME/util/linux_pb:$PATH"
fi

if [ "$(uname)" = Linux ] && lsb_release -i | grep Ubuntu; then
	alias open="xdg-open"
fi

alias l="ls"
alias sl="ls"
alias ll="l -l"
alias la="ll -a"
alias ssht="TERM=xterm ssh"
alias g="git"
alias gs="git s" # short status 
alias gco="git checkout"
alias glp="git log -p --no-ext-diff"
alias glpa="git log -p --no-ext-diff --all"
alias glpf="git log -p --no-ext-diff --follow"
alias glpe="git log -p --ext-diff"
alias glpea="git log -p --ext-diff --all"
alias glpef="git log -p --ext-diff --follow"
# alias glpes="git log -p --ext-diff --stat"
alias gd="git diff --no-ext-diff"
alias gf='git fetch'
alias gds="git diff --stat"
alias gdi="git diff-with-ignored"
alias di="git diff-with-ignored-ext"
alias gc!="git commit --amend"
alias gde="git diff --ext-diff"
alias gdc="gd --cached"
#unalias gg # some git gui thing from ohmyzsh
alias gg="git lg --all"
alias gfp="git push --force-with-lease" # for force push when e.g. amending
alias ggs="git lg --all --stat"
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

alias ds="dirs -v | head -10"
alias d="gde"

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

# unfortunately this is turning into a place where i collect environment 
# settings for both zsh/bash. Not that theres anything wrong with that per se, 
# but it means this file shouldn't be called aliases.sh any longer...

# fix TERM=screen-* causing LESS to use italics.
export LESS_TERMCAP_mb=$'\E[01;31m'       # begin blinking
export LESS_TERMCAP_md=$'\E[01;38;5;74m'  # begin bold
export LESS_TERMCAP_me=$'\E[0m'           # end mode
export LESS_TERMCAP_se=$'\E[49m'          # end standout-mode (clear bg)
export LESS_TERMCAP_so=$'\E[48;5;124m'    # begin standout-mode / info box (use bgcolor)
export LESS_TERMCAP_ue=$'\E[0m'           # end underline
export LESS_TERMCAP_us=$'\E[04;38;5;146m' # begin underline

export OSTYPE

# # because omz people are slightly incompetent and regressed these aliases i did 
# # start to use (these may come back later when #4585 completes)
alias gdc='git diff --cached'
alias gap='git add --patch'
alias gsl='git stash list -p --ext-diff'

alias grepc='grep --color=always --exclude=\*{.,-}min.\*'
# alias cack='ack --color'
# alias ackc='ack --color'
# alias agc='ag --color'
alias mkae='make'

# to make fzf's file finding usage (mainly when using vim but should work for 
# non-vim) work like i want, which is let me comb through all the files ever. 
# Except for git repoes.
export FZF_DEFAULT_COMMAND="fd --type file"

# i'm trying to not export PATH in the aliases script here. But, so far it is 
# my only way to dedupe a sane config across OS's, bash & omz & prezto.

# set PATH so it includes user's private bin directories
export PATH=$HOME/util:$PATH
export PATH="$HOME/.yarn/bin:$HOME/.cargo/bin:$HOME/bin:$HOME/.local/bin:$PATH"

sourcertrsetup () {
	CURRENTSHELL="$(ps -o cmd= -p $$ | sed -e 's/^-//' -e 's:.*/::' )"
	WORKSPACE_LINE="$(catkin config | grep $1)"
	echo "$WORKSPACE_LINE"
	WORKSPACE="${WORKSPACE_LINE##* }"
	echo shell is "$CURRENTSHELL", sourcing from "$WORKSPACE"
	source "$WORKSPACE/setup.$CURRENTSHELL"
}

alias rtr='sourcertrsetup devel'
alias rtrins='sourcertrsetup install'
