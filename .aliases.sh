# todo: make me a function
# idempotent alias check (or prints existing alias -- might wanna suppress that 
# too)
alias ls 2>/dev/null >/dev/null || alias ls="ls --color=always"

alias l="ls"
alias sl="ls"
alias ll="l -l"
alias la="ll -a"
alias g="git"
alias gs="git s" # short status 
alias gco="git checkout"
alias glp="git log -p --no-ext-diff"
alias glpf="git log -p --no-ext-diff --follow"
alias glpe="git log -p --ext-diff"
alias glpef="git log -p --ext-diff --follow"
alias gdt="git difftool"
alias gd="git diff --no-ext-diff"
alias gds="git diff --stat"
alias gde="git diff --ext-diff"
alias gdc="gd --cached"
alias gg="git lg --all"
alias gca="git commit -av"
alias gcm="git commit -am"
unalias gcp # I rarely cherry pick
alias gp="git push"
alias k='l' # this is a bit tongue in cheek

alias mk="make"
alias gcp="git commit-push"

#Dupes of useful ones from omz
alias gl="git pull"
alias gp="git push"
alias gst="git status-with-ignored"
alias ga="git add"

alias ds="dirs -v | head -10"
alias d="gde"

alias iack="ack -i"
alias vim="TERM=xterm-256color-italic vim"

# TODO: deal with this abomination (viz. make it worse by generalizing it)
if [[ $(uname) == Linux ]]; then
	# need to use a non custom term to not confuse nano. Also enabling the 
	# experimental undo functionality for nano
	alias nano="TERM=xterm-256color nano -u"
	# this is a trick seen here http://superuser.com/a/479816/98199
	# it is slightly horrifying and basically turns sudo into a function now. It 
	# will quickly be seen whether this is a sane approach
	function sudo() {
		case $* in
			nano* ) shift 1; TERM=xterm-256color command sudo nano -u "$@" ;;
			* ) command sudo "$@" ;;
		esac
	}

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
