vim-config
==========

My personal vim configuration.

Note that in favor of not having my home folder be itself a git repository 
(which is probably fine but kind of too much git for comfort), I placed the 
.vimrc in here (i.e. so when cloned it will become `~/.vim/.vimrc`) and a good 
way to set it up is 

2. (if you do not already have a `~/.vim` dir) `git clone 
   git@github.com:unphased/vim-config ~/.vim`  
3. back `~/.vimrc` up if it exists. Then delete it.
4. `cd ~ && ln -s .vim/.vimrc .vimrc`  

Linux virtual terminal setup is tracked here too:

```
~/.vim/linux-vt-install.sh
```

That script links the VT palette/setup files into `~/.config` and adds guarded
Bash/Zsh hooks so the root-level setup script only runs when `TERM=linux`.

Use `--force` if an existing local copy should be replaced by the tracked
symlink.
