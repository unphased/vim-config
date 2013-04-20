set t_Co=256
set term=xterm-256color
syntax on
set ts=4
set shiftwidth=4
set number
set laststatus=2
set paste

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
set statusline+=Line:%l/%L[%p%%]            " line X of Y [percent of file]
set statusline+=\ Col:%c                    " current column
set statusline+=\ Buf:%n                    " Buffer number
set statusline+=\ [%b][0x%B]\               " ASCII and byte code under cursor

" end pulled from SO

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
inoremap <C-Up> <C-O>{
inoremap <C-Down> <C-O>}
nnoremap <C-Up> {
nnoremap <C-Down> }

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
nnoremap - <C-W>>

noremap <F12> <Help>
nnoremap <F1> :tabnew<CR>
inoremap <F1> <C-O>:tabnew<CR><ESC>
nnoremap <F2> :tabprev<CR>
inoremap <F2> <C-O>:tabprev<CR><ESC>
nnoremap <F3> :tabnext<CR>
inoremap <F3> <C-O>:tabnext<CR><ESC>
