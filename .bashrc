stty -ixon
stty -ixoff

export HISTSIZE=20000

# avoid duplicates.. 
export HISTCONTROL=ignoredups
# append history entries.. 
shopt -s histappend

. aliases.sh
