"set t_Co=256
set term=xterm-256color
syntax on
set ts=4
set number

set ignorecase
set smartcase

colorscheme TMEighties
set t_ut=
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
nnoremap ^[[A { *** THIS IS ALL WRONG MUST USE PROPER MACHINE TO SET THE CHARACTERS *** 
nnoremap ^[[B }
inoremap ^[[A <ESC>{i
inoremap ^[[B <ESC>}i

