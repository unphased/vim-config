set nocompatible

" load match-up
let &rtp  = '~/.local/share/nvim/lazy/vim-matchup/,' . &rtp
let &rtp .= ',~/.local/share/nvim/lazy/vim-matchup/after'

" load other plugins, if necessary
let &rtp = '~/.local/share/nvim/lazy/vim-surround/,' . &rtp

filetype plugin indent on
syntax enable

let g:matchup_surround_enabled = 1

