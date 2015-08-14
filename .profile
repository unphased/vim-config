stty -ixon
stty -ixoff

export HISTSIZE=20000

# avoid duplicates.. 
export HISTCONTROL=ignoredups
# append history entries.. 
shopt -s histappend

export PATH=$HOME/shell-utils:$PATH

export TERM=xterm-256color
source $HOME/.aliases.sh

# for iphone
alias t=". $HOME/shell-utils/ios-textastic"

# Remember to link this to ~/.profile if it doesn't exist. (more robust than .bashrc)
