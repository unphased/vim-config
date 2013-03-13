"set t_Co=256
set term=xterm-256color
syntax on
set ts=4
set number

set ignorecase
set smartcase

if &term =~ '256color'
    " Disable Background Color Erase (BCE) so that color schemes
    " work properly when Vim is used inside tmux and GNU screen.
    " See also http://snk.tuxfamily.org/log/vim-256color-bce.html
    set t_ut=
endif

colorscheme TMEighties

set mouse=a

" for hopping words
nnoremap [C <C-Right>
inoremap [C <C-Right>
nnoremap [D <C-Left>
inoremap [D <C-Left>

" default Terminal.app opt+left
nnoremap f <C-Right>
inoremap f <C-Right>

" default Terminal.app opt+right
nnoremap b <C-Left>
inoremap b <C-Left>

" hjkl faster navigation 
nnoremap <C-j> }
nnoremap <C-k> {
nnoremap <C-h> b
nnoremap <C-l> w

" This puts the cursor at the end of what is pasted so it can be chained
" and it also just makes sense
nnoremap p p`]
