" echom "RTP is: ".&rtp

set rtp+=~/.vim/
set rtp+=~/.vim/after/
set rtp+=~/usr/share/vim/vim74/

" echom "RTP is now: ".&rtp

" Source .vimrc
source ~/.vimrc

" Put neovim specific adjustments here
noremap <F22> <ESC>
noremap! <F22> <ESC>
nnoremap <F22> :call F10OverloadedFunctionalityCheckTmux('-')<CR>
