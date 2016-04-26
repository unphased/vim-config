stty -ixon
stty -ixoff

export HISTSIZE=20000

# avoid duplicates.. 
export HISTCONTROL=ignoredups
# append history entries.. 
shopt -s histappend

export PATH=$HOME/util:$PATH

source $HOME/.aliases.sh
# Remember to link this to ~/.bash_profile if it doesn't exist. (more robust 
# than .bashrc)

echo 'Hi from ~/.profile'
