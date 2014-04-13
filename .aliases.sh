alias l="ls"
alias sl="ls"
alias ll="l -l"
alias la="ll -a"
alias g="git"
alias gs="git s" # short status 
alias glp="git log -p --no-ext-diff"
alias glpe="git log -p --ext-diff"
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
unalias gm # I also rarely merge
alias k='l' # this is a bit tongue in cheek

# I often want to commit and push in one step
gcp() {
    # [ -n "$2" ] && echo "args" && return
    gcm "$*" && gp
}

alias mk="make"

#Dupes of useful ones from omz
alias gl="git pull"
alias gp="git push"
alias gst="git status"

alias ds="dirs -v | head -10"
alias d="gde"

