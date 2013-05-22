set nocompatible
set showcmd

filetype off " Vundle needs this

set rtp+=~/.vim/bundle/vundle/
call vundle#rc()

Bundle 'gmarik/vundle'
Bundle 'Valloric/YouCompleteMe'
Bundle 'sjl/gundo.vim'

" iTerm2 support for focusing
Bundle 'sjl/vitality.vim'

Bundle 'unphased/vim-fakeclip' 
Bundle 'taglist.vim'
Bundle 'scrooloose/nerdtree'
Bundle 'scrooloose/syntastic'
Bundle 'kien/ctrlp.vim'
Bundle 'diffchanges.vim'
Bundle 'terryma/vim-multiple-cursors'
Bundle 'tpope/vim-repeat'
Bundle 'tpope/vim-surround'
Bundle 'unphased/vim-powerline'

" conditionally include the perforce bundle on machines that match this
if match($HOSTNAME,'athenahealth') != -1
	" echo 'enabling perforce'
	Bundle 'perforce.vim'
	" Note that this plugin does not work out of the box on Linux, but it can
	" be modified quickly to do so by fixing the if-block containing "p4.exe"
	" and also potentially requiring fixing of line-endings. All that could 
	" potentially be automated by this here vimrc but I don't care enough for
	" that because perforce is not a tool i use outside of work. 
endif

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

nmap <C-V> "*p

vmap <C-C> "*y

set hlsearch
set incsearch
set backspace=2
set sidescroll=3
set lcs=eol:$,extends:>,precedes:<
set sidescrolloff=25

" fast terminal (this is for escape code wait time for escape code based keys)
set ttimeout
set ttimeoutlen=10

" set t_Co=256
" set term=xterm-256color-italic

set ttyfast
set ttymouse=xterm2

syntax on
set number
set laststatus=2
set undofile

set ignorecase
set smartcase

set smartindent
set shiftwidth=4
set tabstop=4
" set expandtab
set smarttab

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
    hi StatusLine guibg=Cyan ctermfg=6 guifg=Black ctermbg=0
	set cursorline
  elseif a:mode == 'r'
    hi StatusLine ctermfg=5 guifg=Black ctermbg=3
  else
    hi StatusLine guibg=DarkRed ctermfg=1 guifg=Black ctermbg=0
  endif
endfunction

function! InsertLeaveActions()
	hi statusline ctermfg=237 ctermbg=250
	set nocursorline
endfunction

au InsertEnter * call InsertStatuslineColor(v:insertmode)
au InsertChange * call InsertStatuslineColor(v:insertmode)
au InsertLeave * call InsertLeaveActions()

" default the statusline to green when entering Vim
hi statusline guibg=DarkGrey ctermfg=237 guifg=Green ctermbg=250

" Formats the statusline
set statusline=[%{strlen(&fenc)?&fenc:'none'}, "file encoding
set statusline+=%{&ff}] "file format
set statusline+=%y      "filetype
set statusline+=%f                           " file name
set statusline+=%h      "help file flag
set statusline+=%m      "modified flag
set statusline+=%m      "modified flag
set statusline+=%m      "modified flag
set statusline+=%r      "read only flag

set statusline+=\ %=                        " align left
set statusline+=Line:\ %l/%L[%2p%%]            " line X of Y [percent of file]
set statusline+=\ Col:%-2c                    " current column
set statusline+=\ Buf:%n                    " Buffer number
set statusline+=\ %-3bx%02B\                 " ASCII and byte code under cursor

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
" nnoremap [C <C-Right>
" inoremap [C <C-Right>
" nnoremap [D <C-Left>
" inoremap [D <C-Left>

" default Terminal alt+left
" nnoremap f <C-Right>
" inoremap f <C-Right>

" default Terminal alt+right
" nnoremap b <C-Left>
" inoremap b <C-Left>

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
" these ones are ... you know what, just ignore all of this
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

inoremap <C-Up> <C-O>3<C-Y>
nnoremap <C-Up> 3<C-Y>
vnoremap <C-Up> 3<C-Y>
inoremap <C-Down> <C-O>3<C-E>
vnoremap <C-Down> 3<C-E>
nnoremap <C-Down> 3<C-E>

" more visual mode adjustment
vnoremap <C-L> <C-Right>
vnoremap <C-H> <C-Left>

" accelerated j/k navigation
nnoremap <S-J> 5j
nnoremap <S-K> 5k
nnoremap <S-H> 10h
nnoremap <S-L> 10l
" visual mode equivalents 
vnoremap <S-J> 5j
vnoremap <S-K> 5k
vnoremap <S-H> 10h
vnoremap <S-L> 10l

set wrap

" hjkl faster navigation 
nnoremap <C-j> }
inoremap <C-j> <C-O>}
nnoremap <C-k> {
inoremap <C-k> <C-o>{
nnoremap <C-h> b
inoremap <C-h> <C-o>b
nnoremap <C-l> w
inoremap <C-l> <C-o>w

" This puts the cursor at the end of what is pasted so it can be chained
" and it also just makes sense
nnoremap P p
nnoremap p P`[

" I'm not sure what the semicolon is bound to but it
" will never be as useful as this binding
map ; :
" get original ; back by hitting ;;. : still does what it always did (disabled
" because I dont like the pause)
" noremap ;; :

set autoindent

" Prevent middle click paste (horrific with touchpad on mac)
noremap <MiddleMouse> <LeftMouse>

" vim-window management keys
noremap <C-H> <C-W>h
noremap <C-J> <C-W>j
noremap <C-K> <C-W>k
noremap <C-L> <C-W>l

nnoremap + <C-W>3-
nnoremap = <C-W>3+
nnoremap - <C-W>5>
nnoremap _ <C-W>5<

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
inoremap <C-S> <ESC>:update<CR>

" Use CTRL-Q for abort-quitting (no save)
noremap <C-Q> :qa!<CR>
vnoremap <C-Q> <C-C>:qa!<CR>
inoremap <C-Q> <C-O>:qa!<CR>

" this bit controls search and highlighting by using the Enter key in normal mode
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

" This came out of http://vim.wikia.com/wiki/Search_for_visually_selected_text
" Search for selected text, forwards or backwards.
vnoremap <silent> * :<C-U>
  \let old_reg=getreg('"')<Bar>let old_regtype=getregtype('"')<CR>
  \gvy/<C-R><C-R>=substitute(
  \escape(@", '/\.*$^~['), '\_s\+', '\\_s\\+', 'g')<CR><CR>
  \gV:call setreg('"', old_reg, old_regtype)<CR>
vnoremap <silent> # :<C-U>
  \let old_reg=getreg('"')<Bar>let old_regtype=getregtype('"')<CR>
  \gvy?<C-R><C-R>=substitute(
  \escape(@", '?\.*$^~['), '\_s\+', '\\_s\\+', 'g')<CR><CR>
  \gV:call setreg('"', old_reg, old_regtype)<CR>

" mapping Enter to also perform a search from visual mode (search what is
" selected)
vmap <silent> <CR> *N

" map Q to :q (I find Ex mode useless)
nnoremap Q :q<CR>

nnoremap <F5> :TlistToggle<CR>
inoremap <F5> <C-O>:TlistToggle<CR>

nnoremap <F6> :CtrlPMRUFiles<CR>
inoremap <F6> <ESC>:CtrlPMRUFiles<CR>

nnoremap <F7> :NERDTreeToggle<CR>

" configuring CtrlP 
let g:ctrlp_max_files = 200000
let g:ctrlp_clear_cache_on_exit = 0
let g:ctrlp_root_markers = ['.ctrlp_root'] " insert this sentinel file anywhere that you'd like ctrlp to index from

nnoremap k gk
nnoremap j gj

" These are old mappings for line based home/end, I needed to change these to
" prevent vim from hanging on escape 
" nnoremap <ESC>[1~ g^
" inoremap <ESC>[1~ <C-o>g^
" nnoremap <ESC>[4~ g$
" inoremap <ESC>[4~ <C-o>g$

" Remapping home and end because Vim gets these wrong (w.r.t. the terms I
" use and tmux doesn't translate them either) 
" set t_kh=[1~
" set t_@7=[4~
" nnoremap <Home> :echo('pressed Home')<CR>
" inoremap <Home> <C-O>g^
" nnoremap <End> :echo('pressed End')<CR>
" g<End>
" inoremap <End> <C-O>g<End>

" for not strange behavior on different kind of backspace (shift backspace on
" putty) when in insert mode (i have lazy pinky)
inoremap <C-H> <C-W>

" Move current tab into the specified direction.
" @param direction -1 for left, 1 for right.
function! TabMove(direction)
    " get number of tab pages.
    let ntp=tabpagenr("$")
    " move tab, if necessary.
    if ntp > 1
        " get number of current tab page.
        let ctpn=tabpagenr()
        " move left.
        if a:direction < 0
            let index=((ctpn-1+ntp-1)%ntp)
        else
            let index=(ctpn%ntp)
        endif

        " move tab page.
        execute "tabmove ".index
    endif
endfunction

" chain m + F2/F3 to move them rather than navigate through them
nnoremap m<F3> :call TabMove(1)<CR>
nnoremap m<F2> :call TabMove(-1)<CR>

" configuring YCM. 
let g:ycm_autoclose_preview_window_after_insertion = 1

" set highlight for search to be less blinding
hi Search ctermbg=236 ctermfg=NONE cterm=underline

" requires an italic term obviously
hi Comment cterm=italic 

" bind ctrl W to always work on windows from insert mode
inoremap <C-W> <ESC><C-W>

" Convenient command to see the difference between the current buffer and the
" file it was loaded from, thus the changes you made.
" Only define it when not defined already.
" if !exists(":DiffOrig")
  " command DiffOrig vert new | set bt=nofile | r ++edit # | 0d_ | diffthis
		  " \ | wincmd p | diffthis
" endif

" set ^Z in insert mode to run undo (overloading insert mode for
" functionality that is already ingrained)
inoremap <C-Z> <C-O>u

nnoremap <F8> :DiffChangesDiffToggle<CR>
nnoremap <F9> :DiffChangesPatchToggle<CR>

" this is a ctrl + backslash binding to vsplit
nmap <C-\> :vsplit<CR>
" this is a ctrl + hyphen binding to hsplit
nmap <C-_> :split<CR>

" these make the behavior more like tmux by opening to the right and below
" (why on earth not by default???)
set splitbelow
set splitright

" this makes gundo close the panel upon choosing a history location to warp to
let g:gundo_close_on_revert = 1

set iskeyword=@,$,48-57,_,-,192-255

" Powerline config 
let g:Powerline_colorscheme='default'
let g:Powerline_theme='default'
let g:Powerline_symbols='compatible'

" keybinding for toggling word-wrap 
nnoremap <S-W> :set wrap!<CR>

" Configure multiple cursors plugin
hi multiple_cursors_cursor term=reverse ctermbg=3 ctermfg=0
hi multiple_cursors_visual term=reverse ctermbg=6 ctermfg=0

" Ctrl+F for find
nnoremap <C-F> /
inoremap <C-F> <ESC>/

" mapping normal mode Tab to swap to next window
nnoremap <Tab> :wincmd w<CR>
nnoremap <S-Tab> :wincmd W<CR>
