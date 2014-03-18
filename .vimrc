set nocompatible
set encoding=utf-8
set showcmd

filetype off " Vundle needs this

set rtp+=~/.vim/bundle/vundle/
call vundle#rc()

Bundle 'gmarik/vundle'
Bundle 'Valloric/YouCompleteMe'
Bundle 'unphased/gundo.vim'

" iTerm2 support for focusing
" Bundle 'sjl/vitality.vim'

" Fakeclip doesn't seem to work well on OSX
" Tmux resize-window zoom has obsoleted this
" Bundle 'unphased/vim-fakeclip' 

Bundle 'scrooloose/nerdtree'
Bundle 'scrooloose/syntastic'
Bundle 'kien/ctrlp.vim'
Bundle 'diffchanges.vim'
Bundle 'tpope/vim-repeat'
Bundle 'tpope/vim-surround'
Bundle 'tpope/vim-speeddating'
Bundle 'unphased/vim-powerline'
Bundle 'vim-perl/vim-perl'
"Bundle 'Raimondi/delimitMate'
Bundle 'mattn/emmet-vim'
Bundle 'unphased/git-time-lapse'
Bundle 'maxbrunsfeld/vim-yankstack'
Bundle 'unphased/Vim-IndentFinder'
Bundle 'nathanaelkane/vim-indent-guides'
Bundle 'OrelSokolov/HiCursorWords'
Bundle 'unphased/vim-mark'
Bundle 'kien/rainbow_parentheses.vim'
"Bundle 'airblade/vim-gitgutter'
"Bundle 'akiomik/git-gutter-vim'
Bundle 'mhinz/vim-signify'
Bundle 'pangloss/vim-javascript'
Bundle 'beyondmarc/glsl.vim'
"Bundle 'kana/vim-smartinput'
Bundle 'SirVer/ultisnips'
Bundle 'oblitum/rainbow'

" Bundle 'Decho'

filetype plugin indent on "more Vundle setup

 "
 " Brief help
 " :BundleList          - list configured bundles
 " :BundleInstall(!)    - install(update) bundles
 " :BundleSearch(!) foo - search(or refresh cache first) for foo
 " :BundleClean(!)      - confirm(or auto-approve) removal of unused bundles
 "
 " see :h vundle for more details or wiki for FAQ


" These are file extension filetype settings
au! BufRead,BufNewFile *.esp set ft=perl
au! BufRead,BufNewFile *.mm set ft=objcpp
au! BufRead,BufNewFile *.mlp set ft=xml


autocmd BufNewFile,BufRead *.vsh,*.fsh,*.vp,*.fp,*.gp,*.vs,*.fs,*.gs,*.tcs,*.tes,*.cs,*.vert,*.frag,*.geom,*.tess,*.shd,*.gls,*.glsl set ft=glsl440

" Friendly for editing temp files (the case that prompted this was 
" submit_files.pl
autocmd BufNew,BufRead /tmp/* setlocal formatoptions=tcq

nnoremap <Leader>g :call TimeLapse()<CR>

nnoremap <Leader>e :silent !p4 edit %:p<CR>:redraw!<CR>
nnoremap <Leader>R :silent redraw!<CR>

" Ultisnips settings (to have it work together with YCM)
let g:UltiSnipsExpandTrigger="<F25>"
let g:UltiSnipsJumpForwardTrigger="<F25>"
let g:UltiSnipsJumpBackwardTrigger="<F24>"
" Using Ctrl Tab to fire the snippets. Shift tab is taken by YCM
" the weird custom mapping doesn't really seem to help anything and I cannot 
" figure out how to get it to respond to tab properly, so it should be an easy 
" enough thing to get used to to use Ctrl+(Shift+)Tab to control snips. Should even allow seamless use of YCM while 
" entering an ultisnip segment, so this is pretty much near perfect for snippets since too much overloading is confusing
" anyway.
let g:UltiSnipsEditSplit="vertical"

" indent guides plugin
let g:indent_guides_enable_on_vim_startup = 1
let g:indent_guides_auto_colors = 0
let g:indent_guides_start_level = 1
let g:indent_guides_guide_size = 1
au! VimEnter,Colorscheme * :hi IndentGuidesOdd ctermbg=235 ctermfg=233 | hi IndentGuidesEven ctermbg=236 ctermfg=233

" signify
let g:signify_sign_overwrite = 0
let g:signify_update_on_focusgained = 1

nnoremap <F4> :GundoToggle<CR>
inoremap <F4> <ESC>:GundoToggle<CR>

" These C-V and C-C mappings are for fakeclip, but fakeclip doesn't work on
" OSX and I never really seem to do much copying and pasting
" nmap <C-V> "*p
" vmap <C-C> "*y

nnoremap <Leader>L :so $MYVIMRC<CR>:runtime! after/plugin/*.vim<CR>

set hlsearch
set incsearch
set showmatch " May be overly conspicuous and unnecessary
set backspace=2
set sidescroll=2

set sidescrolloff=3

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

set gdefault " Reverses meaning of /g in regex

set smartindent
au! FileType python setl nosmartindent

set shiftwidth=4
set tabstop=4
" set expandtab
set smarttab

" This was just pulled from the help because it seems so awesome
augroup gzip
     autocmd!
     autocmd BufReadPre,FileReadPre	*.gz set bin
     autocmd BufReadPost,FileReadPost	*.gz '[,']!gunzip
     autocmd BufReadPost,FileReadPost	*.gz set nobin
     autocmd BufReadPost,FileReadPost	*.gz execute ":doautocmd BufReadPost " . expand("%:r")
     autocmd BufWritePost,FileWritePost	*.gz !mv <afile> <afile>:r
     autocmd BufWritePost,FileWritePost	*.gz !gzip <afile>:r
     autocmd FileAppendPre		*.gz !gunzip <afile>
     autocmd FileAppendPre		*.gz !mv <afile>:r <afile>
     autocmd FileAppendPost		*.gz !mv <afile> <afile>:r
     autocmd FileAppendPost		*.gz !gzip <afile>:r
augroup END

set autoread
augroup checktime
    au!
    if !has("gui_running")
        "silent! necessary otherwise throws errors when using command
        "line window.
        autocmd BufEnter        * checktime
        autocmd CursorHold      * checktime
        autocmd CursorHoldI     * checktime
        "these two _may_ slow things down. Remove if they do.
        "autocmd CursorMoved     * silent! checktime
        "autocmd CursorMovedI    * silent! checktime
    endif
augroup END

if &term =~ '256color'
    " Disable Background Color Erase (BCE) so that color schemes
    " work properly when Vim is used inside tmux and GNU screen.
    " See also http://snk.tuxfamily.org/log/vim-256color-bce.html
    set t_ut=
endif

colorscheme Tomorrow-Night-Eighties

"set listchars=tab:→\ ,extends:>,precedes:<,trail:·,nbsp:◆
set listchars=tab:→\ ,extends:»,precedes:«,trail:·,nbsp:◆
set list

hi NonText ctermbg=234 ctermfg=254
hi SpecialKey ctermfg=239

" Enhancements to regular old syntax highlighting
hi Statement cterm=bold
hi Exception ctermfg=211

highlight DiffAdd term=reverse ctermbg=156 ctermfg=black
highlight DiffChange term=reverse ctermbg=33 ctermfg=black
highlight DiffText term=reverse ctermbg=blue ctermfg=16
highlight DiffDelete term=reverse ctermbg=red ctermfg=white

" mostly for syntastic
highlight SpellCap ctermfg=16
highlight Error ctermfg=7
highlight SpellBad ctermfg=7 ctermbg=196

hi clear SignColumn

" HiCursorWords
let g:HiCursorWords_delay = 15

" map to move locationlist (syntastic errors)
noremap ]l :lnext<CR>
noremap [l :lprev<CR>

" for debugging syntax
" (http://vim.wikia.com/wiki/Identify_the_syntax_highlighting_group_used_at_the_cursor)
command! SyntaxDetect :echom "hi<" . synIDattr(synID(line("."),col("."),1),"name") . '> trans<' . synIDattr(synID(line("."),col("."),0),"name") . "> lo<" . synIDattr(synIDtrans(synID(line("."),col("."),1)),"name") . ">"

set updatetime=500
" Unsure if updatetime gets overwritten by plugins. There are many plugins
" I use which mess with updatetime (hicursorwords being one of them)

noremap! <F5> <C-O>:YcmForceCompileAndDiagnostics<CR> 
noremap <F5> :YcmForceCompileAndDiagnostics<CR>

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
	" This next line is actually really cool, but I am taking it out for
	" consistency with other editors whose vim-modes do not allow me to do this
	" call cursor([getpos('.')[1], getpos('.')[2]+1]) " move cursor forward
endfunction

hi CursorLine ctermbg=16
set cursorline

au! InsertEnter * call InsertEnterActions(v:insertmode)
" au InsertChange * call InsertStatuslineColor(v:insertmode)
au! InsertLeave * call InsertLeaveActions()

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
vnoremap <Space> <C-D>
nnoremap b <C-U>

" Do something more useful than what the h key already does with normal mode backspace
nnoremap <BS> b
vnoremap <BS> b

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

inoremap <C-Up> <C-O>4<C-Y>
nnoremap <C-Up> 4<C-Y>
vnoremap <C-Up> 4<C-Y>
inoremap <C-Down> <C-O>4<C-E>
vnoremap <C-Down> 4<C-E>
nnoremap <C-Down> 4<C-E>

vnoremap <Up> <C-Y>g<Up>
vnoremap <Down> <C-E>g<Down>
nnoremap <Up> <C-Y>g<Up>
nnoremap <Down> <C-E>g<Down>
" Not sure why but I couldn't i(nore)map Up and Down

" I like joining lines (I do this operation with the delete key a lot -- that
" key is a reach) -- this map is used because it is *close* to J
nnoremap <C-N> J

" accelerated j/k navigation
noremap <S-J> 5gj
noremap <S-K> 5gk
noremap <S-H> 7h
noremap <S-L> 7l

set wrap
set textwidth=80 " after much messing around, 80 is still a good wrap point
set formatoptions=caq1njw

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

nnoremap P P`[

" Snippets
nnoremap <Leader>dump ause DumperHarness;<CR>DumperHarness::Examine(, 'green');<ESC>7h

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
function! TmuxWindow(dir)
	let nr=winnr()
	silent! exe 'wincmd ' . a:dir
	let newnr=winnr()
	if newnr == nr
		let cmd = 'tmux select-pane -' . tr(a:dir, 'hjkl', 'LDUR')
		call system(cmd)
		echo 'Executed ' . cmd
	endif
endfun

noremap <C-H> :call TmuxWindow('h')<CR>
noremap <C-J> :call TmuxWindow('j')<CR>
noremap <C-K> :call TmuxWindow('k')<CR>
noremap <C-L> :call TmuxWindow('l')<CR>

noremap! <C-H> <ESC>:call TmuxWindow('h')<CR>
noremap! <C-J> <ESC>:call TmuxWindow('j')<CR>
noremap! <C-K> <ESC>:call TmuxWindow('k')<CR>
noremap! <C-L> <ESC>:call TmuxWindow('l')<CR>

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
function! F10OverloadedFunctionalityCheckTmux(direction)
	let tmux_panes_count = system('tmux display -p "#{window_panes}"')
	if tmux_panes_count == 1 || tmux_panes_count == "failed to connect to server\n"
		if (a:direction == '+')
			wincmd w "next window
		else
			wincmd W "prev window
		endif
	else
		call system('tmux select-pane -t :.'.a:direction)
	endif
endfunc
nnoremap <F10> :call F10OverloadedFunctionalityCheckTmux('+')<CR>
set <S-F10>=[34~
noremap <S-F10> <ESC>
noremap! <S-F10> <ESC>
nnoremap <S-F10> :call F10OverloadedFunctionalityCheckTmux('-')<CR>

noremap <F12> <Help>
function! SwitchTabNext()
	if tabpagenr('$') == 1
		call system('tmux next-window')
	else
		tabnext
	endif
endfunc
function! SwitchTabPrev()
	if tabpagenr('$') == 1
		call system('tmux previous-window')
	else
		tabprev
	endif
endfunc

" Need a proper bind for this. gah
set <S-F1>=[1;2P
noremap! <S-F1> <ESC>:tabclose<CR>
noremap <S-F1> :tabclose<CR>
noremap! <F1> <ESC>:tabnew<CR>
noremap <F1> :tabnew<CR>
" inoremap <F1> <ESC>:tabnew<CR>
noremap! <F2> <ESC>:call SwitchTabPrev()<CR>
noremap <F2> :call SwitchTabPrev()<CR>
" inoremap <F2> <ESC>:tabprev<CR>
noremap! <F3> <ESC>:call SwitchTabNext()<CR>
noremap <F3> :call SwitchTabNext()<CR>
" inoremap <F3> <ESC>:tabnext<CR>
" I am hoping to come up with mappings for the F-keys in insert mode that
" can serve productive purposes.

" This is for accomodating PuTTY's behavior of turning shift+F1 into F11
nnoremap <F11> :tabclose<CR>

set showtabline=1  " 0, 1 or 2; when to use a tab pages line
" set tabline=%!MyTabLine()  " custom tab pages line
function! MyTabLine()
	let s = '' " complete tabline goes here
	" loop through each tab page
	for t in range(tabpagenr('$'))
		" set highlight
		if t + 1 == tabpagenr()
			let s .= '%#TabLineSel#'
		else
			let s .= '%#TabLine#'
		endif
		" set the tab page number (for mouse clicks)
		let s .= '%' . (t + 1) . 'T'
		let s .= ' '
		" set page number string
		let s .= t + 1 . ' '
		" get buffer names and statuses
		let n = ''	"temp string for buffer names while we loop and check buftype
		let m = 0	" &modified counter
		let bc = len(tabpagebuflist(t + 1))	"counter to avoid last ' '
		" loop through each buffer in a tab
		for b in tabpagebuflist(t + 1)
			" buffer types: quickfix gets a [Q], help gets [H]{base fname}
			" others get 1dir/2dir/3dir/fname shortened to 1/2/3/fname
			if getbufvar( b, "&buftype" ) == 'help'
				let n .= '[H]' . fnamemodify( bufname(b), ':t:s/.txt$//' )
			elseif getbufvar( b, "&buftype" ) == 'quickfix'
				let n .= '[Q]'
			else
				let n .= pathshorten(bufname(b))
			endif
			" check and ++ tab's &modified count
			if getbufvar( b, "&modified" )
				let m += 1
			endif
			" no final ' ' added...formatting looks better done later
			if bc > 1
				let n .= ' '
			endif
			let bc -= 1
		endfor
		" add modified label [n+] where n pages in tab are modified
		if m > 0
			if m == 1
				let m = ''
			endif
			let s .= '[' . m . '+] '
		endif
		" select the highlighting for the buffer names
		" my default highlighting only underlines the active tab
		" buffer names.
		if t + 1 == tabpagenr()
			let s .= '%#TabLineSel#'
		else
			let s .= '%#TabLine#'
		endif
		" add buffer names
		if n == ''
			let s.= '[New]'
		else
			let s .= n
		endif
		" switch to no underlining and add final space to buffer list
		let s .= ' '
	endfor
	" after the last tab fill with TabLineFill and reset tab page nr
	let s .= '%#TabLineFill#%T'
	" right-align the label to close the current tab page
	if tabpagenr('$') > 1
		let s .= '%=%#TabLineFill#%999Xclose'
	endif
	return s
endfunction

" Use CTRL-S for saving, also in Insert mode TODO: Make this more robust
" mode-wise
noremap <C-S> :update<CR>
vnoremap <C-S> <ESC>:update<CR>
cnoremap <C-S> <C-C>:update<CR>
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

" map Q to :q
nnoremap Q :q<CR>

" nnoremap <F5> :TlistToggle<CR>
" inoremap <F5> <C-O>:TlistToggle<CR>

nnoremap <F6> :CtrlPMRUFiles<CR>
inoremap <F6> <ESC>:CtrlPMRUFiles<CR>

nnoremap <F7> :NERDTreeToggle<CR>

" configuring CtrlP 
let g:ctrlp_max_files = 200000
let g:ctrlp_clear_cache_on_exit = 0
let g:ctrlp_root_markers = ['.ctrlp_root'] " insert this sentinel file anywhere that you'd like ctrlp to index from

noremap k gk
noremap j gj

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
" Attempting to focus window to the left in insert mode just wont work.
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
let g:ycm_confirm_extra_conf = 0
let g:ycm_complete_in_comments = 1
let g:ycm_seed_identifiers_with_syntax = 1
let g:ycm_collect_identifiers_from_comments_and_strings = 1
"let g:ycm_server_use_vim_stdout = 1
let g:ycm_server_log_level = 'debug'

" This insert mapping is for pasting; it appears that YCM only takes over the
" <C-P> when it has the complete box open (this may be a Vim
" limitation/builtin)
inoremap <C-P> <C-O>p<CR>

" set highlight for search to be less blinding
highlight Search ctermbg=25 ctermfg=NONE

" only on an italic term do we set comment to use italic cterm highlight
if &term == 'xterm-256color-italic'
	hi Comment cterm=italic
endif

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
nnoremap <C-\> :vsplit<CR>
vnoremap <C-\> <Esc>:vsplit<CR>
" this is a ctrl + hyphen binding to hsplit
nnoremap <C-_> :split<CR>
vnoremap <C-_> <Esc>:split<CR>

" these make the behavior more like tmux by opening to the right and below
set splitbelow
set splitright

" this makes gundo close the panel upon choosing a history location to warp to
let g:gundo_close_on_revert = 1
let g:gundo_preview_bottom = 1

set undolevels=10000

set iskeyword=@,$,48-57,_,192-255

" Powerline config
let g:Powerline_colorscheme='default'
let g:Powerline_theme='default'
let g:Powerline_symbols='compatible'

" Ctrl+F for find -- tip on \v from
" http://stevelosh.com/blog/2010/09/coming-home-to-vim/
" May take some getting used to, but is generally saving on use of backslashes
nnoremap <C-F> /\v
inoremap <C-F> <ESC>/\v
vnoremap <C-F> /\v
nnoremap / /\v
vnoremap / /\v

" Finding % to be highly powerful so I map to high traffic area single key
" This mostly alleviates the want for matching highlights for surrounding
" stuff because moving back and forth between the endpoints can be quite
" helpful anyway.
" These maps are non-recursive to accomodate the fact that matchit.vim
" overloads %, so we try not to mess that up.
nmap ` %
vmap ` %



" mapping normal mode Tab to swap to next window; saving the functionality of
" tab (next jumplist position) to C-B (since PgUp serves that function well)
nnoremap <C-B> <Tab>
" context-sensitively overload Tab to switch either tabs or windows that are in current tab
function! NextWindowOrTab()
	if (winnr() == winnr('$'))
		tabnext
		1wincmd w "first window
	else
		wincmd w "next window
	endif
endfunc

function! PrevWindowOrTab()
	if (winnr() == 1)
		tabprev
		let winnr = winnr('$')
		exec winnr . 'wincmd w'
	else
		wincmd W
	endif
endfunc

" I actually like the mash tab to cycle windows behavior so let's keep it simple
"nnoremap <Tab> :wincmd w<CR>
"nnoremap <S-Tab> :wincmd W<CR>

" Nevermind, I actually really need this on a small screen...
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
  au! BufReadPost * if line("'\"") > 0 && line("'\"") <= line("$")
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
" This is gonna suspend vim and is not really a working bind
nnoremap <F36> u
vnoremap <F36> <ESC>u 
" todo: figure out how to make this save and restore the selection area

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
" being a rather common key sequence and macs...
noremap <F31> :update<CR>
vnoremap <F31> <ESC>:update<CR>
cnoremap <F31> <C-C>:update<CR>
inoremap <F31> <ESC>:update<CR>

nnoremap <silent> <F33> :set invpaste paste?<CR>:set number!<CR>:set list!<CR>
set pastetoggle=<F33>
set showmode

" A slightly perilous set of binds:
" the terminal in this case sends an escape, followed by a Ctrl char,
" the latter of which may be intercepted by tmux and passed through
" a shell script! (tmux is smart, though, and does the term timeout on
" the escape, it will be letting it pass through)
set <F30>=h
set <F29>=j
set <F28>=k
set <F27>=l

" These binds are for quick rearrangement of windows, very awesome function
" that sadly I'll need to do hacking to get the same on tmux
nnoremap <F30> :wincmd H<CR>
nnoremap <F29> :wincmd J<CR>
nnoremap <F28> :wincmd K<CR>
nnoremap <F27> :wincmd L<CR>

" This is for yankstack
" have it not bind anything
let g:yankstack_map_keys = 0

" the yankstack plugin requires loading prior to my binds (wonder what other
" plugins have this sort of behavior)
call yankstack#setup()
set <F26>=d " the reason for this one here is <A-D> appears to be the same as <A-S-D> as far as vim is concerned
set <A-S-D>=D
nmap <F26> <Plug>yankstack_substitute_older_paste
" nmap <C-D> <Plug>yankstack_substitute_older_paste
" The old bind (Ctrl+D) is confusing, so i am commenting it out.
" the real shame is that there is no way to pass in Ctrl+Shift+letter.
nmap <A-S-D> <Plug>yankstack_substitute_newer_paste

" These are apparently the defacto terminal codes for Ctrl+Tab and Ctrl+Shift+Tab
" but Vim has no knowledge of it. so here i am adding it to the fastkey repertoire
set <F25>=[27;5;9~
set <F24>=[27;6;9~

" make recordings easier to fire off, binding comma to @q (use qq to record
" what you wanna repeat using comma)
nnoremap , @q

" more ctrlp settings
let g:ctrlp_switch_buffer = 'Et' " Jump to tab AND buffer if already open
let g:ctrlp_open_new_file = 'r' " Open new files in a new tab
let g:ctrlp_open_multiple_files = 'trj'
let g:ctrlp_show_hidden = 1 " Index hidden files
let g:ctrlp_follow_symlinks = 1

" pulled from http://vim.wikia.com/wiki/Move_current_window_between_tabs
function! MoveToPrevTab()
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

function! MoveToNextTab()
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

nnoremap y<F2> :call MoveToPrevTab()<CR>
nnoremap y<F3> :call MoveToNextTab()<CR>

set scrolloff=2
runtime macros/matchit.vim

" bind the ctrl arrow left and right in insert mode to WORD hop also
inoremap <C-Left> <ESC>bi
inoremap <C-Right> <ESC>lwi

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
" let delimitMate_expand_space = 1
" let delimitMate_expand_cr = 1

" This is for replicating what ST does when typing a delimiter character
" when something is selected, to wrap selection with it: to undo just use
" surround.vim e.g. ds'
vmap ' S'
vmap " S"
vmap { S{
vmap } S}
vmap ( S(
vmap ) S)
vmap [ S[
vmap ] S]
" This is way too cool (auto lets you enter tags)
vmap < S<
vmap > S>
" restore the functions for shifting selections
vnoremap << <
vnoremap >> >

" if ;w<CR> is typed in insert mode, exit insert mode and run a prompt asking
" if you really want to save the file (rather than inserting ;w<CR> into file)
function! MyConfirmSave()
	if confirm('Save file? (you are getting lazy...)', "OK\nNo") == 1
		w
		silent redraw!
	endif
endfunc
inoremap ;w<CR> <ESC>:call MyConfirmSave()<CR>

function! MyConfirmSaveQuit()
	if confirm('Save file and then quit? (you are getting lazy...)', "OK\nNo") == 1
		wq
		silent redraw!
	endif
endfunc
inoremap ;wq<CR> <ESC>:call MyConfirmSaveQuit()<CR>

function! MyConfirmSaveQuitAll()
	if confirm('Save file and then quit all? (you are getting lazy...)', "OK\nNo") == 1
		wqa
		silent redraw!
	endif
endfunc
inoremap ;wqa<CR> <ESC>:call MyConfirmSaveQuitAll()<CR>

"""" Commenting out cmaps because cmap applies when e.g. typing in (/)-search mode
" " prevent common typos from actually writing files to disk
" cmap wq1 wq!
" cmap w1 w!
" cmap q1 q!
" cmap qa1 qa!
" cmap e1 e!
" 
" cmap w; w
" 
" cmap qw wq
" cmap qw! wq!
" cmap qw1 wq!
" 
" " and more combinatorially exploding goodness for dealing with flubbing the
" " enter key
" cmap wq\ wq
" cmap wq1\ wq!
" cmap wq!\ wq!
" cmap w\ w
" cmap w1\ w!
" cmap w!\ w!
" cmap q\ q
" cmap q1\ q!
" cmap q!\ q!
" cmap qa\ qa
" cmap qa1\ qa!
" cmap qa!\ qa!
" cmap e\ e
" cmap e1\ e!
" cmap e!\ e!
" " I am tempted to do more cases to address overzealous shift key, but screw it
" " because I will not have a hard time becoming more lazy with the shift key
" " which is what the above bindings allow for.
" 
" " This actually happens a lot and makes scary errors and opens some shit.
" cmap lw w
" cmap lwq wq
" cmap lw! w!
" cmap lw1 w!
" cmap lwq! wq!
" cmap lwq1 wq!
" cmap le! e!
" cmap le1 e!
" cmap lq q
" cmap lq! q!
" cmap lq1 q!

" taken from http://stackoverflow.com/a/6052704/340947 and with some stylistic 
" changes and functional enhancements of mine (the backing up of session files)
fu! SaveSess()
	" if the session file exists, rename it to a dotfile with a timestamp
	if filereadable(getcwd().'/.session.vim')
		call system('mv '.getcwd().'/.session.vim '.getcwd().'/.session-'.substitute(strftime("%Y %b %d %X"), ' ', '_', 'g').'.vim')
	endif
	set sessionoptions=tabpages,winsize
    execute 'mksession '.getcwd().'/.session.vim'
endfunction

fu! RestoreSess()
	if filereadable(getcwd().'/.session.vim')
		execute 'so '.getcwd().'/.session.vim'
	endif
endfunction

" autocmd VimLeave * call SaveSess()
" Disabling this --- it's too goddamn cluttery to leave session files EVERY time
" autocmd VimEnter * call RestoreSess()


" This is for not putting two spaces after a period when Vim formats things
set nojoinspaces

" This is for less frustration in vblock mode (virtual-edit)
set ve=block

" something somebody cameup with in response to my SO topic
onoremap <silent> X :<C-u>execute 'normal! vlF' . nr2char(getchar()) . 'of' . nr2char(getchar())<CR>
vnoremap <silent> X :<C-u>execute 'normal! vlF' . nr2char(getchar()) . 'of' . nr2char(getchar())<CR>

" scrollbinding to view a file in columns
:noremap <silent> <Leader>c :<C-u>let @z=&so<CR>:set so=0 noscb<CR>:bo vs<CR>Ljzt:setl scb<CR><C-w>p:setl scb<CR>:let &so=@z<CR>

" auto enable rainbow on c/cpp files
" Nope! too slow on preprocessor output
" au FileType c,cpp,objc,objcpp call rainbow#load()
