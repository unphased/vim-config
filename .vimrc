set nocompatible
filetype off " Vundle needs this

set rtp+=~/.vim/bundle/vundle/
call vundle#rc()

Bundle 'gmarik/vundle'
Bundle 'Valloric/YouCompleteMe'
Bundle 'sjl/gundo.vim'
Bundle 'jeffkreeftmeijer/vim-numbertoggle'
Bundle 'sjl/vitality.vim'
Bundle 'atsepkov/vim-fakeclip'

filetype plugin indent on "more Vundle

 "
 " Brief help
 " :BundleList          - list configured bundles
 " :BundleInstall(!)    - install(update) bundles
 " :BundleSearch(!) foo - search(or refresh cache first) for foo
 " :BundleClean(!)      - confirm(or auto-approve) removal of unused bundles
 "
 " see :h vundle for more details or wiki for FAQ

au BufRead,BufNewFile *.esp setfiletype perl

nnoremap <F4> :GundoToggle<CR>
inoremap <F4> <ESC>:GundoToggle<CR>

set hlsearch
set backspace=2

set t_Co=256
set term=xterm-256color

set ttyfast
set ttymouse=xterm2

syntax on
set ts=4
set shiftwidth=4
set number
set laststatus=2
set undofile

set ignorecase
set smartcase

if &term =~ '256color'
    " Disable Background Color Erase (BCE) so that color schemes
    " work properly when Vim is used inside tmux and GNU screen.
    " See also http://snk.tuxfamily.org/log/vim-256color-bce.html
    set t_ut=
endif

colorscheme TMEighties

highlight DiffAdd term=reverse ctermbg=green ctermfg=black
highlight DiffChange term=reverse ctermbg=blue ctermfg=black
highlight DiffText term=reverse ctermbg=cyan ctermfg=black
highlight DiffDelete term=reverse ctermbg=red ctermfg=black

" start pulled from SO: http://stackoverflow.com/a/9121083/340947 

function! InsertStatuslineColor(mode)
  if a:mode == 'i'
    hi statusline guibg=Cyan ctermfg=6 guifg=Black ctermbg=0
  elseif a:mode == 'r'
    hi statusline guibg=Purple ctermfg=5 guifg=Black ctermbg=0
  else
    hi statusline guibg=DarkRed ctermfg=1 guifg=Black ctermbg=0
  endif
endfunction

au InsertEnter * call InsertStatuslineColor(v:insertmode)
au InsertLeave * hi statusline ctermfg=237 ctermbg=250

" default the statusline to green when entering Vim
hi statusline guibg=DarkGrey ctermfg=237 guifg=Green ctermbg=250

" Formats the statusline
set statusline=%f                           " file name
set statusline+=[%{strlen(&fenc)?&fenc:'none'}, "file encoding
set statusline+=%{&ff}] "file format
set statusline+=%y      "filetype
set statusline+=%h      "help file flag
set statusline+=%m      "modified flag
set statusline+=%r      "read only flag

set statusline+=\ %=                        " align left
set statusline+=Line:\ %l/%L[%2p%%]            " line X of Y [percent of file]
set statusline+=\ Col:%-2c                    " current column
set statusline+=\ Buf:%n                    " Buffer number
set statusline+=\ %-3b%%%-2B\               " ASCII and byte code under cursor

" end pulled from SO

" omnifunc, pulled from http://amix.dk/blog/post/19021

autocmd FileType python set omnifunc=pythoncomplete#Complete
autocmd FileType javascript set omnifunc=javascriptcomplete#CompleteJS
autocmd FileType html set omnifunc=htmlcomplete#CompleteTags
autocmd FileType css set omnifunc=csscomplete#CompleteCSS
autocmd FileType xml set omnifunc=xmlcomplete#CompleteTags
autocmd FileType php set omnifunc=phpcomplete#CompletePHP
autocmd FileType c set omnifunc=ccomplete#Complete

set mouse=a

" for hopping words (from default shitty putty) 
nnoremap [C <C-Right>
inoremap [C <C-Right>
nnoremap [D <C-Left>
inoremap [D <C-Left>

" default Terminal alt+left
nnoremap f <C-Right>
inoremap f <C-Right>

" default Terminal alt+right
nnoremap b <C-Left>
inoremap b <C-Left>

" consistency with pagers in normal mode
nnoremap <Space> <C-D>
nnoremap b <C-U>

" No longer using alt+arrows to do anything
" nnoremap [1;3A {
" nnoremap [1;3B }
" nnoremap [1;3C <C-Right>
" nnoremap [1;3D <C-Left>
" inoremap [1;3A <ESC>{i
" inoremap [1;3B <ESC>}i
" inoremap [1;3C <C-Right>
" inoremap [1;3D <C-Left>


" note THESE NEXT FEW LINES ARE NOT PROPER ESC CHARACTERS (and are here for refernece only)
" these ones are ... you know what just ignore all of this
" nnoremap ^[[A {
" nnoremap ^[[1;5A {
" nnoremap ^[[B }
" nnoremap ^[[1;5B }
" inoremap ^[[A <ESC>{i
" inoremap ^[[1;5A <ESC>{i
" inoremap ^[[B <ESC>}i
" inoremap ^[[1;5B <ESC>}i

" With a proper terminal (proper ctrl key reporting can be done with putty and iterm2 so no crazy escapes are needed)
inoremap <S-Up> <C-O>{
inoremap <S-Down> <C-O>}
nnoremap <S-Up> {
nnoremap <S-Down> }

inoremap <C-Up> <C-O><C-Y>
nnoremap <C-Up> <C-Y>
inoremap <C-Down> <C-O><C-E>
nnoremap <C-Down> <C-E>

set wrap

" hjkl faster navigation 
nnoremap <C-j> }
nnoremap <C-k> {
nnoremap <C-h> b
nnoremap <C-l> w

" This puts the cursor at the end of what is pasted so it can be chained
" and it also just makes sense
nnoremap P p
nnoremap p P`[

nnoremap ; :

set autoindent

" Prevent middle click paste (horrific with touchpad on mac)
noremap <MiddleMouse> <LeftMouse>

" vim-window management keys
noremap <C-H> <C-W>h
noremap <C-J> <C-W>j
noremap <C-K> <C-W>k
noremap <C-L> <C-W>l

nnoremap + <C-W>3+
nnoremap = <C-W>=
nnoremap - <C-W>5>

noremap <F12> <Help>
nnoremap <F1> :tabnew<CR>
inoremap <F1> <C-O>:tabnew<CR><ESC>
nnoremap <F2> :tabprev<CR>
inoremap <F2> <C-O>:tabprev<CR><ESC>
nnoremap <F3> :tabnext<CR>
inoremap <F3> <C-O>:tabnext<CR><ESC>

" Use CTRL-S for saving, also in Insert mode
noremap <C-S> :update<CR>
vnoremap <C-S> <C-C>:update<CR>
inoremap <C-S> <C-O>:update<CR>

" Use CTRL-Q for hard-quitting 
noremap <C-Q> :qa!<CR>
vnoremap <C-Q> <C-C>:qa!<CR>
inoremap <C-Q> <C-O>:qa!<CR>

let g:highlighting = 0
function! Highlighting()
  if g:highlighting == 1 && @/ =~ '^\\<'.expand('<cword>').'\\>$'
    let g:highlighting = 0
    return ":silent nohlsearch\<CR>"
  endif
  let @/ = '\<'.expand('<cword>').'\>'
  let g:highlighting = 1
  return ":silent set hlsearch\<CR>"
endfunction
nnoremap <silent> <expr> <CR> Highlighting()
