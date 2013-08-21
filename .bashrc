stty -ixon
stty -ixoff

export HISTSIZE=20000

# avoid duplicates.. 
export HISTCONTROL=ignoredups
# append history entries.. 
shopt -s histappend

source aliases.sh
# Remember to link this to ~/.profile if it doesn't exist. (more robust than .bashrc)
