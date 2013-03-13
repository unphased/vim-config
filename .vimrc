"set t_Co=256
set term=xterm-256color
syntax on

set ignorecase
set smartcase

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

colorscheme TMEighties
set t_ut=
set mouse=a

