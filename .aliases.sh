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

# I often want to commit and push in one step -- rather than cherry pick, gcp 
# shall be used for git commit push
gcp() {
    # [ -n "$2" ] && echo "args" && return
    gcm "$*" && gp
}

alias mk="make"

#Dupes of useful ones from omz
alias gl="git pull"
alias gp="git push"
alias gst="git status-with-ignored"
alias ga="git add"

alias ds="dirs -v | head -10"
alias d="gde"

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
