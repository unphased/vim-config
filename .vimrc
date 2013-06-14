set nocompatible
set showcmd

filetype off " Vundle needs this

set rtp+=~/.vim/bundle/vundle/
call vundle#rc()

Bundle 'gmarik/vundle'
Bundle 'Valloric/YouCompleteMe'
Bundle 'sjl/gundo.vim'

" iTerm2 support for focusing
" Bundle 'sjl/vitality.vim'

" Fakeclip doesn't seem to work well on OSX
" Tmux resize-window zoom has obsoleted this
" Bundle 'unphased/vim-fakeclip' 

Bundle 'taglist.vim'
Bundle 'scrooloose/nerdtree'
Bundle 'scrooloose/syntastic'
Bundle 'kien/ctrlp.vim'
Bundle 'diffchanges.vim'
Bundle 'terryma/vim-multiple-cursors'
Bundle 'tpope/vim-repeat'
Bundle 'tpope/vim-surround'
Bundle 'unphased/vim-powerline'
Bundle 'vim-perl/vim-perl'
Bundle 'Raimondi/delimitMate'
Bundle 'mattn/zencoding-vim'
Bundle 'unphased/git-time-lapse'
Bundle 'maxbrunsfeld/vim-yankstack'
Bundle 'DetectIndent'

" conditionally include the perforce bundle on machines that match this
" if match($HOSTNAME,'athenahealth') != -1
	" echo 'enabling perforce'
	" Bundle 'perforce.vim'
	" Note that this plugin does not work out of the box on Linux, but it can
	" be modified quickly to do so by fixing the if-block containing "p4.exe"
	" and also potentially requiring fixing of line-endings. All that could 
	" potentially be automated by this here vimrc but I don't care enough for
	" that because perforce is not a tool i use outside of work.
" endif
" turns out that p4 plugin really doesn't work. at all.

filetype plugin indent on "more Vundle setup

 "
 " Brief help
 " :BundleList          - list configured bundles
 " :BundleInstall(!)    - install(update) bundles
 " :BundleSearch(!) foo - search(or refresh cache first) for foo
 " :BundleClean(!)      - confirm(or auto-approve) removal of unused bundles
 "
 " see :h vundle for more details or wiki for FAQ

" This is athena-specific
au BufRead,BufNewFile *.esp setfiletype perl

" this is for auto running DetectIndent
function! DetectIndent()
	DetectIndent "only really using this for determining expandtab...
	set tabstop=4
	set shiftwidth=4
endfunc
au BufReadPost * call DetectIndent()

" this thing doesnt appear to work...
let g:detectindent_preferred_indent=4

nnoremap <F4> :GundoToggle<CR>
inoremap <F4> <ESC>:GundoToggle<CR>

" These C-V and C-C mappings are for fakeclip, but fakeclip doesn't work on
" OSX and I never really seem to do much copying and pasting
" nmap <C-V> "*p
" vmap <C-C> "*y

set hlsearch
set incsearch
set backspace=2
set sidescroll=3

set sidescrolloff=25

" fast terminal (this is for escape code wait time for escape code based keys)
set ttimeout
set ttimeoutlen=10

" set t_Co=256
" set term=xterm-256color-italic

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

set listchars=tab:╶─,extends:>,precedes:<,trail:◼,nbsp:⬧
set list

hi NonText ctermbg=234 ctermfg=254
hi SpecialKey ctermfg=239

highlight DiffAdd term=reverse ctermbg=156 ctermfg=black
highlight DiffChange term=reverse ctermbg=blue ctermfg=black
highlight DiffText term=reverse ctermbg=171 ctermfg=black
highlight DiffDelete term=reverse ctermbg=red ctermfg=black

" mostly for syntastic
highlight SpellCap ctermfg=16

function! InsertEnterActions(mode)
	echo 'islc'
  if a:mode == 'i'
	hi CursorLine ctermbg=237
	hi CursorLineNr cterm=bold ctermfg=255
  elseif a:mode == 'r'
	hi CursorLine cterm=reverse
  else
  endif
endfunction

function! InsertLeaveActions()
	hi CursorLine ctermbg=16 cterm=NONE
	hi CursorLineNr ctermfg=11
	call cursor([getpos('.')[1], getpos('.')[2]+1]) " move cursor forward
endfunction

hi CursorLine ctermbg=16
set cursorline

au InsertEnter * call InsertEnterActions(v:insertmode)
" au InsertChange * call InsertStatuslineColor(v:insertmode)
au InsertLeave * call InsertLeaveActions()

" default the statusline to green when entering Vim
" hi statusline guibg=DarkGrey ctermfg=237 guifg=Green ctermbg=250

" Formats the statusline
" set statusline=[%{strlen(&fenc)?&fenc:'none'}, "file encoding
" set statusline+=%{&ff}] "file format
" set statusline+=%y      "filetype
" set statusline+=%f                           " file name
" set statusline+=%h      "help file flag
" set statusline+=%m      "modified flag
" set statusline+=%m      "modified flag
" set statusline+=%m      "modified flag
" set statusline+=%r      "read only flag
"
" set statusline+=\ %=                        " align left
" set statusline+=Line:\ %l/%L[%2p%%]            " line X of Y [percent of file]
" set statusline+=\ Col:%-2c                    " current column
" set statusline+=\ Buf:%n                    " Buffer number
" set statusline+=\ %-3bx%02B\                 " ASCII and byte code under cursor
"
" end pulled from SO

" omnifunc, pulled from http://amix.dk/blog/post/19021
"
" Do I need these omnifuncs? 
" autocmd FileType python set omnifunc=pythoncomplete#Complete
" autocmd FileType javascript set omnifunc=javascriptcomplete#CompleteJS
" autocmd FileType html set omnifunc=htmlcomplete#CompleteTags
" autocmd FileType css set omnifunc=csscomplete#CompleteCSS
" autocmd FileType xml set omnifunc=xmlcomplete#CompleteTags
" autocmd FileType php set omnifunc=phpcomplete#CompletePHP
" autocmd FileType c set omnifunc=ccomplete#Complete

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

" accelerated j/k navigation
nnoremap <S-J> 7j
nnoremap <S-K> 7k
nnoremap <S-H> 10h
nnoremap <S-L> 10l
" visual mode equivalents
vnoremap <S-J> 7j
vnoremap <S-K> 7k
vnoremap <S-H> 10h
vnoremap <S-L> 10l

set wrap

" Helpful warning message
au FileChangedShell * echo "Warning: File changed on disk!!"

" hjkl faster navigation
" nnoremap <C-j> }
" inoremap <C-j> <C-O>}
" nnoremap <C-k> {
" inoremap <C-k> <C-o>{
" nnoremap <C-h> b
" inoremap <C-h> <C-o>b
" nnoremap <C-l> w
" inoremap <C-l> <C-o>w

" This is for yankstack
" have it not bind anything
let g:yankstack_map_keys = 0

" the yankstack plugin requires loading prior to my binds (wonder what other
" plugins have this sort of behavior)
call yankstack#setup()
" This puts the cursor at the end of what is pasted so it can be chained
" and it also just makes sense
nmap <C-d> <Plug>yankstack_substitute_older_paste
nmap <C-e> <Plug>yankstack_substitute_newer_paste
nnoremap P p
nnoremap p P`[

" this just makes sense
nmap Y y$

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
" <C-L> is refresh screen, use :refresh if needed. (and since I am abolishing
" it in the shell use the clear builtin on there also)

" If cannot move in a direction, attempt to forward the directive to tmux
function TmuxWindow(dir)
	let nr=winnr()
	silent! exe 'wincmd ' . a:dir
	let newnr=winnr()
	if newnr == nr
		let cmd = 'tmux select-pane -' . tr(a:dir, 'hjkl', 'LDUR')
		call system(cmd)
		echo 'Executed ' . cmd
	endif
endfun

nnoremap <C-H> :call TmuxWindow('h')<CR>
nnoremap <C-J> :call TmuxWindow('j')<CR>
nnoremap <C-K> :call TmuxWindow('k')<CR>
nnoremap <C-L> :call TmuxWindow('l')<CR>

" bind the F10 switcher key to also exit insert mode if sent to Vim, this
" should help its behavior become consistent outside of tmux as it won't then
" be doing any filtering on F10 (which should cycle panes)
"
" I actually think this binding is beautiful because it happens to be
" generally a good idea to exit insert mode anyway once switching away from
" Vim.
noremap <F10> <ESC>
noremap! <F10> <ESC>

" this checks tmux to figure out if it should swap panes or trigger Tab
" instead
function F10OverloadedFunctionalityCheckTmux()
	if system('tmux display -p "#{window_panes}"') == 1
		call NextWindowOrTab()
	else
		call system('tmux select-pane -t :.+')
	endif
endfunc
nnoremap <F10> :call F10OverloadedFunctionalityCheckTmux()<CR>

noremap <F12> <Help>
nnoremap <F1> :tabnew<CR>
" inoremap <F1> <ESC>:tabnew<CR>
nnoremap <F2> :tabprev<CR>
" inoremap <F2> <ESC>:tabprev<CR>
nnoremap <F3> :tabnext<CR>
" inoremap <F3> <ESC>:tabnext<CR>
" I am hoping to come up with mappings for the F-keys in insert mode that
" can serve productive purposes.

" This is for accomodating PuTTY's behavior of turning shift+F1 into F11
nnoremap <F11> :tabclose<CR>

" Use CTRL-S for saving, also in Insert mode TODO: Make this more robust
" mode-wise
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
" selected) (and staying in the same spot by searching backward once)
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

" This is for making the alternate backspace delete an entire word.
" Attempting to focus window to the left in insert mode just wont work, this should be fine.
inoremap <C-H> <C-W>

" Move current tab into the specified direction.
" @param direction -1 for left, 1 for right.
" Only necessary if you want "wrapping" functionality
"function! TabMove(direction)
"    " get number of tab pages.
"    let ntp=tabpagenr("$")
"    " move tab, if necessary.
"    if ntp > 1
"        " get number of current tab page.
"        let ctpn=tabpagenr()
"        " move left.
"        if a:direction < 0
"            let index=((ctpn-1+ntp-1)%ntp)
"        else
"            let index=(ctpn%ntp)
"        endif
"
"        " move tab page.
"        execute "tabmove ".index
"    endif
"endfunction

" chain m + F2/F3 to move them rather than navigate through them
nnoremap m<F3> :tabmove +1<CR>
nnoremap m<F2> :tabmove -1<CR>

" configuring YCM. 
let g:ycm_autoclose_preview_window_after_insertion = 1
let g:ycm_add_preview_to_completeopt = 1

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
set splitbelow
set splitright

" this makes gundo close the panel upon choosing a history location to warp to
let g:gundo_close_on_revert = 1

set iskeyword=@,$,48-57,_,-,192-255

" Powerline config
let g:Powerline_colorscheme='default'
let g:Powerline_theme='default'
let g:Powerline_symbols='compatible'


" Configure multiple cursors plugin
hi multiple_cursors_cursor term=reverse ctermbg=3 ctermfg=0
hi multiple_cursors_visual term=reverse ctermbg=6 ctermfg=0

" Ctrl+F for find
nnoremap <C-F> /
inoremap <C-F> <ESC>/

" mapping normal mode Tab to swap to next window: Ctrl-Y has already been
" mapped out above, so we can safely overload it to fire whatevers bound on Ctrl-I
nnoremap <C-Y> <Tab>
" context-sensitively overload Tab to switch either tabs or windows that are in current tab
function NextWindowOrTab()
	if (winnr() == winnr('$'))
		tabnext
		1wincmd w
	else
		wincmd w
	endif
endfunc

function PrevWindowOrTab()
	if (winnr() == 1)
		tabprev
		let winnr = winnr('$')
		exec winnr . 'wincmd w'
	else
		wincmd W
	endif
endfunc
nnoremap <Tab> :call NextWindowOrTab()<CR>
nnoremap <S-Tab> :call PrevWindowOrTab()<CR>

" Uncomment the following to have Vim jump to the last position when
" reopening a file
" Put into e.g.
" ~/.vim/after/ftplugin/gitcommit.vim
" this:
" :autocmd BufWinEnter <buffer> normal! gg0
" to get this not to affect whatever filetypes 
" if has("autocmd")
  au BufReadPost * if line("'\"") > 0 && line("'\"") <= line("$")
    \| exe "normal! g'\"" | endif
" endif


"THIS SECTION CONTAINS THE FAST KEY BINDINGS
" Make alt+BS do the same as in bash/zsh (I am doing experimental override of xF keys)
set <F37>=
inoremap <F37> <C-W>

" Make alt+z perform the undo function (mapping ctrl z to alt z may need to be
" done at shell level, but this helps on OSX at least)
set <F36>=z
inoremap <F36> <C-O>u
nnoremap <F36> u
vnoremap <F36> <ESC>u " todo: figure out how to make this save and restore the selection area 
" note that pressing u in visual mode lowercases the selection 
set <F35>=Z
inoremap <F35> <C-O><C-R>
nnoremap <F35> <C-R>
vnoremap <F35> <ESC><C-R>

" Make Alt+Tab switch vim tabs  (todo: figure out a less wrong escape code to
" use) -- this one is clearly only possible on a Mac
set <F34>=[99Z
inoremap <F34> <C-O>:tabnext<CR>
nnoremap <F34> :tabnext<CR>
vnoremap <F34> <ESC>:tabnext<CR>

set <F33>=p

set <F32>=w
" keybinding for toggling word-wrap 
nnoremap <F32> :set wrap!<CR>
inoremap <F32> :set wrap!<CR>

set <F31>=s
" just a convenience thing for being lazy what with switching OS's and this
" being a rather important bind
inoremap <F31> <ESC>:update<CR>
noremap <F31> :update<CR>

nnoremap <silent> <F33> :set invpaste paste?<CR>:set number!<CR>
set pastetoggle=<F33>
set showmode

" make recordings easier to fire off, binding comma to @q (use qq to record
" what you wanna repeat)
nnoremap , @q

" more ctrlp settings
let g:ctrlp_switch_buffer = 'Et' " Jump to tab AND buffer if already open
let g:ctrlp_open_new_file = 'r' " Open new files in a new tab
let g:ctrlp_open_multiple_files = 'trj'
let g:ctrlp_show_hidden = 1 " Index hidden files

" pulled from http://vim.wikia.com/wiki/Move_current_window_between_tabs
function MoveToPrevTab()
  "there is only one window
  if tabpagenr('$') == 1 && winnr('$') == 1
    return
  endif
  "preparing new window
  let l:tab_nr = tabpagenr('$')
  let l:cur_buf = bufnr('%')
  if tabpagenr() != 1
    close!
    if l:tab_nr == tabpagenr('$')
      tabprev
    endif
    sp
  else
    close!
    exe "0tabnew"
  endif
  "opening current buffer in new window
  exe "b".l:cur_buf
endfunc

function MoveToNextTab()
  "there is only one window
  if tabpagenr('$') == 1 && winnr('$') == 1
    return
  endif
  "preparing new window
  let l:tab_nr = tabpagenr('$')
  let l:cur_buf = bufnr('%')
  if tabpagenr() < tab_nr
    close!
    if l:tab_nr == tabpagenr('$')
      tabnext
    endif
    sp
  else
    close!
    tabnew
  endif
  "opening current buffer in new window
  exe "b".l:cur_buf
endfunc

nnoremap w<F2> :call MoveToPrevTab()<CR>
nnoremap w<F3> :call MoveToNextTab()<CR>

set scrolloff=2
runtime macros/matchit.vim

" bind the ctrl arrow left and right in insert mode to WORD hop also
inoremap <C-Left> <ESC>Bi
inoremap <C-Right> <ESC>Wa

func! MyResizeDown()
	let curwindow = winnr()
	wincmd j
	if winnr() == curwindow
		wincmd k
	else
		wincmd p
	endif
	3wincmd +
	exec curwindow.'wincmd w'
endfunc

func! MyResizeUp()
	let curwindow = winnr()
	wincmd j
	if winnr() == curwindow
		wincmd k
	else
		wincmd p
	endif
	3wincmd -
	exec curwindow.'wincmd w'
endfunc

func! MyResizeRight()
	let curwindow = winnr()
	wincmd l
	if winnr() == curwindow
		wincmd h
	else
		wincmd p
	endif
	5wincmd >
	exec curwindow.'wincmd w'
endfunc

func! MyResizeLeft()
	let curwindow = winnr()
	wincmd l
	if winnr() == curwindow
		wincmd h
	else
		wincmd p
	endif
	5wincmd <
	exec curwindow.'wincmd w'
endfunc

nnoremap - :call MyResizeLeft()<CR>
nnoremap = :call MyResizeRight()<CR>
nnoremap _ :call MyResizeDown()<CR>
nnoremap + :call MyResizeUp()<CR>

" delimitMate configuration
let delimitMate_expand_space = 1
let delimitMate_expand_cr = 1
