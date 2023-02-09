" echom "RTP is: ".&rtp

set rtp+=~/.vim
set rtp+=~/.vim/after
set packpath+=~/.vim
" set rtp+=~/usr/share/vim/vim74/

" echom "RTP is now: ".&rtp

" Source .vimrc
source ~/.vimrc

" Put neovim specific adjustments here (but usually cannot because of plug command order 
" requirements.)
