vim-config
==========

My personal vim configuration.

Note that in favor of not having my personal folder be itself a git repository (which is probably fine but kind of too much git for comfort), I placed the .vimrc in here (i.e. so when cloned it will become `~/.vim/.vimrc`) and a good way to set it up is 

1) `cd ~/.vim`  
2) `git clone git@github.com:unphased/vim-config`  
3) delete ~/.vimrc if it exists, back it up  
4) `cd ~ && ln -s .vim/.vimrc .vimrc`

