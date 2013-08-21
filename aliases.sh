alias l="ls"
alias gs="git s" # short status 
alias glp="git log -p --no-ext-diff"
alias gdt="git difftool"
alias gd="git diff --no-ext-diff"
alias gdc="gd --cached"
alias gg="git lg"
alias gcm="git commit -am"
unalias gcp # I rarely cherry pick

# I often want to commit and push in one step
gcp() {
    [ -n "$2" ] && echo "args" && return
    gcm "$*" && gp
}

alias mk="make"

#Dupes of useful ones from omz
alias gl="git pull"
alias gp="git push"
alias gst="git status"

alias ds="dirs -v | head -10"
alias d="gd"

