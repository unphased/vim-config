set nocompatible
set encoding=utf-8
set showcmd

filetype off " Vundle needs this

set rtp+=~/.vim/bundle/vundle/
call vundle#rc()

Plugin 'gmarik/vundle'
Plugin 'Valloric/YouCompleteMe'
Plugin 'simnalamburt/vim-mundo'

" iTerm2 support for focusing
" Plugin 'sjl/vitality.vim'

" Fakeclip doesn't seem to work well on OSX
" Tmux resize-window zoom has obsoleted this
" Bundle 'unphased/vim-fakeclip'

Plugin 'scrooloose/nerdtree'
Plugin 'scrooloose/syntastic'
Plugin 'kien/ctrlp.vim'
Plugin 'diffchanges.vim'
Plugin 'tpope/vim-repeat'
Plugin 'tpope/vim-surround'
Plugin 'tpope/vim-speeddating'
Plugin 'tpope/vim-commentary'
Plugin 'tpope/vim-obsession'
Plugin 'tpope/vim-fugitive'
Plugin 'tpope/vim-abolish'
Plugin 'vim-perl/vim-perl'
"Bundle 'Raimondi/delimitMate'
Plugin 'mattn/emmet-vim'
Plugin 'unphased/git-time-lapse'
Plugin 'maxbrunsfeld/vim-yankstack'
Plugin 'ldx/vim-indentfinder'
Plugin 'nathanaelkane/vim-indent-guides'
Plugin 'ihacklog/HiCursorWords'
Plugin 'dimasg/vim-mark'
" Bundle 'kien/rainbow_parentheses.vim'
"Bundle 'airblade/vim-gitgutter'
"Bundle 'akiomik/git-gutter-vim'
Plugin 'mhinz/vim-signify'
" Plugin 'pangloss/vim-javascript'
" Plugin 'jelera/vim-javascript-syntax'
Plugin 'beyondmarc/glsl.vim'
"Bundle 'kana/vim-smartinput'
Plugin 'SirVer/ultisnips'
" Bundle 'oblitum/rainbow'
Plugin 'marijnh/tern_for_vim'
Plugin 'unphased/vim-airline'
Plugin 'derekwyatt/vim-fswitch'
Plugin 'wakatime/vim-wakatime'
Plugin 'panozzaj/vim-autocorrect'
Plugin 'kshenoy/vim-signature'
" Plugin 'jeffkreeftmeijer/vim-numbertoggle'
"Plugin 'mxw/vim-jsx'

Plugin 'tmux-plugins/vim-tmux'

Plugin 'majutsushi/tagbar'

Plugin 'tpope/vim-unimpaired'

Plugin 'vim-scripts/camelcasemotion'
Plugin 'vim-scripts/EnhancedJumps'
Plugin 'vim-scripts/ingo-library' " needed for EnhancedJumps

Plugin 't9md/vim-textmanip'
Plugin 'vim-scripts/hexman.vim'
Plugin 'tpope/vim-afterimage'
Plugin 'junegunn/vim-easy-align'
Plugin 'jiangmiao/auto-pairs'
Plugin 'blueyed/argtextobj.vim'
Plugin 'octol/vim-cpp-enhanced-highlight'
Plugin 'unphased/Cpp11-Syntax-Support'

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

autocmd BufNewFile,BufReadPost *.md set filetype=markdown

" customize it for my usual workflow
autocmd FileType gitcommit set nosmartindent | set formatoptions-=t

" Friendly for editing temp files (the case that prompted this was
" submit_files.pl
autocmd BufNew,BufRead /tmp/* setlocal formatoptions=tcq

nnoremap <Leader>g :call TimeLapse()<CR>

" nnoremap <Leader>e :silent !p4 edit %:p<CR>:redraw!<CR>
nnoremap <Leader>R :silent redraw!<CR>

" Ultisnips settings (to have it work together with YCM)
if has('nvim')
	let g:UltiSnipsExpandTrigger="<C-TAB>"
	let g:UltiSnipsJumpForwardTrigger="<C-TAB>"
	let g:UltiSnipsJumpBackwardTrigger="<C-S-TAB>"

	" Just set to something so that c-tab wont be used (needed for nvim)
	let g:UltiSnipsListSnippets="<M-c>"
else
	" I believe default <c-tab> binding fails to work on vim so this just ends 
	" up working the way i want
	let g:UltiSnipsExpandTrigger="<F23>"
	let g:UltiSnipsJumpForwardTrigger="<F23>"
	let g:UltiSnipsJumpBackwardTrigger="<F22>"
endif
" Using Ctrl Tab to fire the snippets. Shift tab is taken by YCM.
" the weird custom mapping doesn't really seem to help anything and I cannot
" figure out how to get it to respond to tab properly, so it should be an easy
" enough thing to get used to to use Ctrl+(Shift+)Tab to control snips. Should
" even allow seamless use of YCM while entering an ultisnip segment, so this is
" pretty much near perfect for snippets since too much overloading is confusing
" anyway.
let g:UltiSnipsEditSplit="vertical"

" indent guides plugin
let g:indent_guides_enable_on_vim_startup = 1
let g:indent_guides_auto_colors = 0
let g:indent_guides_start_level = 1
let g:indent_guides_guide_size = 1
au! VimEnter,Colorscheme * :hi IndentGuidesOdd ctermbg=235 ctermfg=16 | hi IndentGuidesEven ctermbg=236 ctermfg=234

" signify
let g:signify_sign_overwrite = 0
let g:signify_update_on_focusgained = 1

" customizing the vim-signature bindings (to un-delay the backtick)

let g:SignatureMap = {
	\ 'Leader'             :  "m",
	\ 'PlaceNextMark'      :  "m,",
	\ 'ToggleMarkAtLine'   :  "m.",
	\ 'PurgeMarksAtLine'   :  "m-",
	\ 'DeleteMark'         :  "dm",
	\ 'PurgeMarks'         :  "m<Space>",
	\ 'PurgeMarkers'       :  "m<BS>",
	\ 'GotoNextSpotAlpha'  :  "']",
	\ 'GotoPrevSpotAlpha'  :  "'[",
	\ 'GotoNextLineByPos'  :  "]'",
	\ 'GotoPrevLineByPos'  :  "['",
	\ 'GotoNextSpotByPos'  :  "]`",
	\ 'GotoPrevSpotByPos'  :  "[`",
	\ 'GotoNextMarker'     :  "[+",
	\ 'GotoPrevMarker'     :  "[-",
	\ 'GotoNextMarkerAny'  :  "]=",
	\ 'GotoPrevMarkerAny'  :  "[=",
	\ 'ListLocalMarks'     :  "m/",
	\ 'ListLocalMarkers'   :  "m?"
	\ }

nnoremap <F4> :GundoToggle<CR>
inoremap <F4> <ESC>:GundoToggle<CR>

" These C-V and C-C mappings are for fakeclip, but fakeclip doesn't work on
" OSX and I never really seem to do much copying and pasting
" nmap <C-V> "*p
" vmap <C-C> "*y

" The new way to do copypaste is with + register -- I already have it set up to 
" have visual mode y yank to OS X pasteboard.

nnoremap <Leader>L :so $MYVIMRC<CR>:runtime! after/plugin/*.vim<CR>

" for camelcasemotion, bringing back the original , by triggering it with ,,
" the comma repeats last t/f/T/F, which is *still* completely useless... Here's
" the thing. There's nothing useful to bind comma to, because comma is used 
" with camelcasemotion in normal mode because it's still marginally useful that 
" way.
nnoremap , <Nop>
xnoremap , <Nop>
onoremap , <Nop>

" remapping keys for EnhancedJumps: I cant let tab get mapped. Since curly 
" braces are conveniently available as hopping by paragraphs is not useful for 
" me, this example given by the doc will work out well.
nmap {          <Plug>EnhancedJumpsOlder
nmap }          <Plug>EnhancedJumpsNewer
nmap g{         <Plug>EnhancedJumpsLocalOlder
nmap g}         <Plug>EnhancedJumpsLocalNewer
nmap <Leader>{  <Plug>EnhancedJumpsRemoteOlder
nmap <Leader>}  <Plug>EnhancedJumpsRemoteNewer

" some possible conflict with :redir
let g:EnhancedJumps_CaptureJumpMessages = 0

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
" set term=screen-256color-italic

set ttymouse=xterm2

syntax on
set number
set laststatus=2
set undofile

set ignorecase
set smartcase

set gdefault " Reverses meaning of /g in regex

" I took out smartindent
" au! FileType python setl nosmartindent

set shiftwidth=4
set tabstop=4
" set expandtab
set smarttab

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
set listchars=tab:╶─,extends:»,precedes:«,trail:·,nbsp:◆
set list

hi NonText ctermbg=234 ctermfg=254
hi SpecialKey ctermfg=239

" Enhancements which override colorscheme
hi Statement cterm=bold
hi Exception ctermfg=211

highlight DiffAdd term=reverse ctermbg=156 ctermfg=black
highlight DiffChange term=reverse ctermbg=33 ctermfg=black
highlight DiffText term=reverse ctermbg=blue ctermfg=16
highlight DiffDelete term=reverse ctermbg=red ctermfg=white

" mostly for syntastic
highlight SyntasticError ctermbg=91
highlight SyntasticWarning ctermbg=24

hi clear SignColumn

" HiCursorWords
let g:HiCursorWords_delay = 50

" map to move locationlist (syntastic errors)
" (now taken care of by unimpaired)
" noremap ]l :lnext<CR>
" noremap [l :lprev<CR>

" syntastic set up for jsx
" MAKE SURE YOU HAVE npm install -g jsxhint
let g:syntastic_javascript_checkers = ['jsxhint']

let g:syntastic_always_populate_loc_list = 1

" for debugging syntax
" (http://vim.wikia.com/wiki/Identify_the_syntax_highlighting_group_used_at_the_cursor)
command! SyntaxDetect :echom "hi<" . synIDattr(synID(line("."),col("."),1),"name") . '> trans<' . synIDattr(synID(line("."),col("."),0),"name") . "> lo<" . synIDattr(synIDtrans(synID(line("."),col("."),1)),"name") . ">"

" set updatetime=500
" Unsure if updatetime gets overwritten by plugins. There are many plugins
" I use which mess with updatetime (hicursorwords being one of them)

" noremap! <F5> <C-O>:YcmForceCompileAndDiagnostics<CR>
" noremap <F5> :YcmForceCompileAndDiagnostics<CR>

" Binding F5 to the fswitch (switching between c/cpp and h/hxx/hpp) -- I like
" to use this and ctrlp MRU rather than having to type in stuff
nmap <silent> <F5> :FSSplitBelow<CR>

" additional fswitch definitions are implemented not through any friendly 
" variables but through defining variables via file autocommands -- i think it's
" admissible as its fairly straightforward reasoning, at least
au BufEnter *.vsh let b:fswitchdst = 'fsh'
au BufEnter *.fsh let b:fswitchdst = 'vsh'
au BufEnter *.mm  let b:fswitchdst = 'h' | let b:fswitchlocs = 'reg:/src/include/,reg:|src|include/**|,ifrel:|/src/|../include|'

function! InsertEnterActions(mode)
	"echo 'islc'
	set cursorline
	if a:mode == 'i'
		hi CursorLine ctermbg=235 cterm=NONE
		hi CursorLineNr cterm=bold ctermfg=199 ctermbg=237
	elseif a:mode == 'r'
		hi CursorLine cterm=reverse
	else
	endif
endfunction

function! InsertLeaveActions()
	set nocursorline
	" hi CursorLine ctermbg=NONE cterm=NONE
	hi CursorLineNr ctermfg=11 ctermbg=NONE
	" This next line is actually really cool, but I am taking it out for
	" consistency with other editors whose vim-modes do not allow me to do this
	" call cursor([getpos('.')[1], getpos('.')[2]+1]) " move cursor forward
endfunction

hi CursorLine ctermbg=NONE

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

" set statusline+=\ %=                        " align left
" set statusline+=Line:\ %l/%L[%2p%%]            " line X of Y [percent of file]
" set statusline+=\ Col:%-2c                    " current column
" set statusline+=\ Buf:%n                    " Buffer number
" set statusline+=\ %-3bx%02B\                 " ASCII and byte code under cursor

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
" Not sure why but I couldn't i(nore)map Up and Down -- i am not really sure how 
" well it would work to allow scroll overriding in insert mode

" Mapping left and right arrows to help scroll the view as well. I think I want 
" to overdo the effect as well.
vnoremap <Left> 2zhh
vnoremap <Right> 2zll
nnoremap <Left> 3zhh
nnoremap <Right> 3zll

" Have to override the shift and ctrl + arrow keys in insert and normal mode, 
" these do aggravating things by default
nnoremap <S-Left> b
vnoremap <S-Left> b
nnoremap <S-Right> e
vnoremap <S-Right> e

nnoremap <C-Left> B
vnoremap <C-Left> B
nnoremap <C-Right> E
vnoremap <C-Right> E

" I just want to make visual mode yank also spit into system clipboard. Will 
" only really work on OSX. I use a clipboard stack so clobbering is alright


" Using these is sort of questionable as it does pollute undo history :(
inoremap <S-Left> <C-O>b
inoremap <S-Right> <C-O>e
inoremap <C-Left> <C-O>B
inoremap <C-Right> <C-O>e
" This last one isnt E because of some stupid bind problem with E (which is my 
" smart semicolon aware end of line edit key, which i never use... grr)

" I like joining lines (I do this operation with the delete key a lot -- that
" key is a reach) -- this map is used because it is *close* to J
nnoremap <silent> <C-N> :let poscursorjoinlines=getpos('.')<Bar>join<Bar>call setpos('.', poscursorjoinlines)<CR>
" I have this: imap <C-N> <C-O><C-N>
" in the after/plugin/YouCompleteMe dir becuase the ctrl n in insert mode is 
" overridden by YCM to move around the completion picker (which is useless)

" accelerated j/k navigation
noremap <S-J> 5gj
noremap <S-K> 5gk
noremap <S-H> 7h
noremap <S-L> 7l

set wrap
set textwidth=79 
" after much messing around, 80 is still a good wrap point to keep at least the 
" comments neat

set formatoptions=caq1njw
" override $VIMRUNTIME/ftplugin/*.vim messing up my formatoptions by forcing the 
" options that i really care about at this point
au FileType * setlocal fo-=r

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

" I'm not sure what the semicolon is bound to but it
" will never be as useful as this binding
map ; :
" get original ; back by hitting ;;. : still does what it always did (disabled
" because I dont like the pause)
" noremap ;; :

set autoindent

" Prevent middle click paste (horrific with touchpad on mac)
noremap <MiddleMouse> <LeftMouse>
inoremap <MiddleMouse> <Nop>

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

" I am not really sure what happened here but, tmux 2 seems to just have its 
" own idea about how to send Shift F10 if TERM is screen-*. (before this used 
" to set <S-F10> to \x1b[34~ but that seems to have no effect when I commented 
" it out! Even under TERM=xterm-*!)
set <S-F10>=[21;2~
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
noremap! <silent> <F2> <ESC>:call SwitchTabPrev()<CR>
noremap <silent> <F2> :call SwitchTabPrev()<CR>
" inoremap <F2> <ESC>:tabprev<CR>
noremap! <silent> <F3> <ESC>:call SwitchTabNext()<CR>
noremap <silent> <F3> :call SwitchTabNext()<CR>
" inoremap <F3> <ESC>:tabnext<CR>
" I am hoping to come up with mappings for the F-keys in insert mode that
" can serve productive purposes.

" This is for accomodating PuTTY's behavior of turning shift+F1 into F11
" But I don't want it because sometimes i turn off the volume keys bind on osx 
" (for being able to use those keys in parallels)
" nnoremap <F11> :tabclose<CR>

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

" helper bind http://stackoverflow.com/a/7078429/340947
cmap w!! w !sudo tee > /dev/null %

" bind CTRL-ALT-S for saving as root (run sudo tee)
" SHIFT-CTRL is not possible on terminals (same as CTRL-S)
set <C-A-S>=
cnoremap <C-A-S> <C-C>:w !sudo tee > /dev/null %<CR>
noremap <C-A-S> <ESC>:w !sudo tee > /dev/null %<CR>
inoremap <C-A-S> <ESC>:w !sudo tee > /dev/null %<CR>

function! MyConfirmQuitAllNoSave()
	qall
	if confirm('DISCARD CHANGES and then QUIT ALL? (you hit Ctrl+Q)', "OK\nNo") == 1
		qall!
	endif
endfunc
" Use CTRL-Q for abort-quitting (no save)
noremap <C-Q> :call MyConfirmQuitAllNoSave()<CR>
cnoremap <C-Q> <C-C>:call MyConfirmQuitAllNoSave()<CR>
inoremap <C-Q> <C-O>:call MyConfirmQuitAllNoSave()<CR>

" this bit controls search and highlighting by using the Enter key in normal mode
let g:highlighting = 1
function! Highlighting()
  if g:highlighting == 1 && @/ =~ '^\\<'.expand('<cword>').'\\>$'
    let g:highlighting = 0
    return ":silent nohlsearch\<CR>"
  endif
  let @/ = '\<'.expand('<cword>').'\>'
  " add to history -- can clutter, but def helps
  " NOTE! the item is added without /v so backspace first, then hunt
  call histadd('search', '\v<' . expand('<cword>') . '>')
  let g:highlighting = 1
  return ":silent set hlsearch\<CR>"
endfunction
nnoremap <silent> <expr> <CR> Highlighting()

" This came out of http://vim.wikia.com/wiki/Search_for_visually_selected_text
" Search for selected text, forwards or backwards.
vnoremap <silent> <CR> :<C-U>
  \let old_reg=getreg('"')<Bar>let old_regtype=getregtype('"')<CR>
  \gvy/<C-R><C-R>=substitute(
  \escape(@", '/\.*$^~['), '\_s\+', '\\_s\\+', 'g')<CR><CR>
  \gV:call setreg('"', old_reg, old_regtype)<CR>
vnoremap <silent> # :<C-U>
  \let old_reg=getreg('"')<Bar>let old_regtype=getregtype('"')<CR>
  \gvy?<C-R><C-R>=substitute(
  \escape(@", '?\.*$^~['), '\_s\+', '\\_s\\+', 'g')<CR><CR>
  \gV:call setreg('"', old_reg, old_regtype)<CR>

" map Q to :q
nnoremap Q :q<CR>

" nnoremap <F5> :TlistToggle<CR>
" inoremap <F5> <C-O>:TlistToggle<CR>

nnoremap <F6> :CtrlPMRUFiles<CR>
inoremap <F6> <ESC>:CtrlPMRUFiles<CR>
nnoremap <S-F6> :NERDTreeToggle<CR>

" opens the current buffer in nerdtree
nnoremap <Leader>f :NERDTreeFind<CR>

" I definitely do not use this -- F7 is now YCM sign toggle.
" nnoremap <F7> :NERDTreeToggle<CR>

" configuring CtrlP
let g:ctrlp_max_files = 200000
let g:ctrlp_clear_cache_on_exit = 0
let g:ctrlp_root_markers = ['.ctrlp_root'] " insert this sentinel file anywhere that you'd like ctrlp to index from

noremap k gk
noremap j gj
noremap gk k
noremap gj j

" for wrapping based on words
set linebreak

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
" let g:ycm_autoclose_preview_window_after_insertion = 1
let g:ycm_add_preview_to_completeopt = 1
let g:ycm_confirm_extra_conf = 0
let g:ycm_complete_in_comments = 1
let g:ycm_seed_identifiers_with_syntax = 1
let g:ycm_collect_identifiers_from_comments_and_strings = 1
"let g:ycm_server_use_vim_stdout = 1
let g:ycm_server_log_level = 'info'
let g:ycm_max_diagnostics_to_display = 300

" semantic on OSX works again! hooray -- now this has to be bound to a key 
" because of limitations. see issue 887 at YCM's github
let g:ycm_enable_diagnostic_signs = 1
let g:ycm_enable_diagnostic_highlighting = 1
let g:ycm_server_keep_logfiles = 1
highlight YcmErrorLine guibg=#3f0000
highlight YcmWarningLine guibg=#282800

let g:ycm_filetype_specific_completion_to_disable = { 'php': 1 }

" sadly, this doesn't work on the fly for some reason. It's supposed to!
" nnoremap <F7> :call YCMSignToggle()<CR>
" function! YCMSignToggle()
" 	if g:ycm_enable_diagnostic_signs
" 		let g:ycm_enable_diagnostic_signs = 0
" 	else
" 		let g:ycm_enable_diagnostic_signs = 1
" 	endif
" endfunc

" setting F7 to ycmdiags
nnoremap <F7> :YcmDiags<CR>
nnoremap <S-F7> :YcmCompleter GoToDefinition<CR>

" This insert mapping is for pasting; it appears that YCM only takes over the
" <C-P> when it has the complete box open (this may be a Vim
" limitation/builtin)
inoremap <C-P> <C-O>p<CR>

" set highlight for search to be less blinding
" highlight Search ctermbg=33 ctermfg=16
" highlight Search ctermbg=none ctermfg=none cterm=reverse
highlight Search ctermbg=124 ctermfg=none
highlight Error term=reverse ctermfg=8 ctermbg=9

" set t_ZH=[3m
" set t_ZR=[23m

" only on an italic term do we set comment to use italic cterm highlight
if &term == 'xterm-256color-italic' || &term == 'nvim'
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

nnoremap <F9> :DiffChangesPatchToggle<CR>
nnoremap <S-F9> :DiffChangesDiffToggle<CR>

nnoremap <F8> :TagbarToggle<CR>

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

" set iskeyword=@,$,48-57,_,192-255

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
nnoremap ` %
vnoremap ` %

" mapping normal mode Tab to swap to next window; saving the functionality of
" tab (next jumplist position) to C-B (since PgUp serves that function well)
nnoremap <C-B> <Tab>

" context-sensitively overload Tab to switch either tabs or windows that are in
" current tab since using airline I am digging the buffer tabline support, so
" when only one tab is open, then tab cycles through the buffers that are in
" that list (which i do believe means that the buffers are in memory. vim is
" weird).
function! NextWindowOrTabOrBuffer()
	" prefer to cycle thru only the set of windows if more than one window 
	" (rather than to start going through buffer list) -- however if there are 
	" tabs, will continue through tabs once at end of windows for current tab

	" store the original window index for use in checking done later
	let startWindowIndex = winnr()
	if (winnr('$') == 1 && tabpagenr('$') == 1)
		" only situation where we cycle to next buffer
		bnext
		return
	endif
	" Rest of logic is just as sound (and simple) as it ever was
	if (winnr() == winnr('$'))
		tabnext
		1wincmd w "first window
	else
		wincmd w "next window
	endif

	" also provide a user friendly treatment: When this command lands us into 
	" a non-regular-file window, we will re-evaluate and push to next tab or 
	" window or buffer as appropriate.
	if (&bufhidden == 'wipe' || &bufhidden == 'hide')
		if (tabpagenr('$') == 1)
			" determine for sure whether we're looking at a single-openfile-tab
			while winnr() != startWindowIndex
				if (&bufhidden == 'wipe' || &bufhidden == 'hide')
					" ensure to not list any buffer like this (this may be 
					" a bad hack -- but i see no consequences yet)
					set nobuflisted
					wincmd w
				else
					return
					" actually our job is done
				endif
			endwhile
			bnext
		elseif (winnr() == winnr('$'))
			tabnext
			1wincmd w "first window
		else
			wincmd w "next window
		endif
	endif
endfunc

function! PrevWindowOrTabOrBuffer()
	let startWindowIndex = winnr()
	if (winnr('$') == 1 && tabpagenr('$') == 1)
		" only situation where we cycle to next buffer
		bprev
		return
	endif
	if (winnr() == 1)
		tabprev
		exec winnr('$').'wincmd w'
	else
		wincmd W
	endif

	" for skipping special buffers
	if (&bufhidden == 'wipe' || &bufhidden == 'hide')
		if (tabpagenr('$') == 1)
			" determine for sure whether we're looking at a single-openfile-tab
			while winnr() != startWindowIndex
				if (&bufhidden == 'wipe' || &bufhidden == 'hide')
					" ensure to not list any buffer like this (this may be 
					" a bad hack -- but i see no consequences yet)
					set nobuflisted
					wincmd W
				else
					return
					" actually our job is done
				endif
			endwhile

			" now winnr == startWindowIndex... So we've already switched back 
			" to the main buffer so it means that it is necessary to go do the 
			" buffer swap
			bprev
		elseif (winnr() == 1)
			tabprev
			exec winnr('$').'wincmd w'
		else
			wincmd W
		endif
	endif
endfunc

" I actually like the mash tab to cycle windows behavior so let's keep it simple
"nnoremap <Tab> :wincmd w<CR>
"nnoremap <S-Tab> :wincmd W<CR>

" Nevermind, I actually really need this on a small screen...
nnoremap <Tab> :call NextWindowOrTabOrBuffer()<CR>
nnoremap <S-Tab> :call PrevWindowOrTabOrBuffer()<CR>

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
if !has('nvim')
	set <F37>=
	inoremap <F37> <C-W>
else
	inoremap <M-BS> <C-W>
endif

" force bash mode for sh syntax
let g:is_bash=1

if !has('nvim')
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
else
	nnoremap <m-w> :set wrap!<CR>
	inoremap <m-w> :set wrap!<CR>
	noremap <m-s> :update<CR>
	vnoremap <m-s> <ESC>:update<CR>
	cnoremap <m-s> <C-C>:update<CR>
	inoremap <m-s> <ESC>:update<CR>

	nnoremap <silent> <m-p> :set invpaste paste?<CR>:set number!<CR>:set list!<CR>
	set pastetoggle=<m-p>
endif
set showmode

" A slightly perilous set of binds:
" the terminal in this case sends an escape, followed by a Ctrl char,
" the latter of which may be intercepted by tmux and passed through
" a shell script! (tmux is smart, though, and does the term timeout on
" the escape, it will be letting it pass through)
if has('nvim')
	" nvim's binds are simpler
	nnoremap <m-h> :wincmd H<CR>
	nnoremap <m-j> :wincmd J<CR>
	nnoremap <m-k> :wincmd K<CR>
	nnoremap <m-l> :wincmd L<CR>
else
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
endif

" This is a new thing that I realized I could implement with vimscript -- it 
" mirrors my simplistic rearrangement shortcuts for Tmux (which are annoyingly 
" basic yet surprisingly powerful for the types of organization that do not 
" happen at short intervals)

" these binds query and store the current buffer #, close the window, splits 
" whatever window we fall into either horiz. or vertically, and then restores 
" the buffer. Really simple. It will potentially resize the rest of the window 
" heights/widths because of annoying vim legacy behavior, and I can't do much 
" about it.
function! MyForceHorizSplit()
	let curbuffer = bufnr('%')
	hide
	" hide buffer, do not need to unload or whatever
	split
	exec 'b '.curbuffer
endfunc
function! MyForceVertSplit()
	let curbuffer = bufnr('%')
	hide
	vsplit
	exec 'b '.curbuffer
endfunc
if has('nvim')
	nnoremap <M-F> :call MyForceVertSplit()<CR>
	nnoremap <M-R> :call MyForceHorizSplit()<CR>
else
	set <F18>=F
	set <F17>=R

	nnoremap <F18> :call MyForceVertSplit()<CR>
	nnoremap <F17> :call MyForceHorizSplit()<CR>
endif

" This is for yankstack
" have it not bind anything
let g:yankstack_map_keys = 0

" the yankstack plugin requires loading prior to my binds (wonder what other
" plugins have this sort of behavior)
call yankstack#setup()
if has('nvim')
	nmap <m-d> <Plug>yankstack_substitute_older_paste
	nmap <M-S-D> <Plug>yankstack_substitute_newer_paste
else
	set <F26>=d " the reason for this one here is <A-D> appears to be the same as <A-S-D> as far as vim is concerned
	set <A-S-D>=D
	nmap <F26> <Plug>yankstack_substitute_older_paste
	" nmap <C-D> <Plug>yankstack_substitute_older_paste
	" The old bind (Ctrl+D) is confusing, so i am commenting it out.
	" the real shame is that there is no way to pass in Ctrl+Shift+letter.
	nmap <A-S-D> <Plug>yankstack_substitute_newer_paste
endif

" These are apparently the defacto terminal codes for Ctrl+Tab and Ctrl+Shift+Tab
" but Vim has no knowledge of it. so here i am adding it to the fastkey 
" repertoire, but skipping F24 and F25 because the actual vitality plugin uses 
" this method specifically on F24 and F25
if !has('nvim')
	set <F23>=[27;5;9~
	set <F22>=[27;6;9~
	set <F21>=n

	set <F20>=.
	set <F19>=,
endif

" set the numpad key codes -- Mark helpfully already implements the stuff that
" calls <k0>, etc
if !has('nvim')
	set <k0>=Op
	set <k1>=Oq
	set <k2>=Or
	set <k3>=Os
	set <k4>=Ot
	set <k5>=Ou
	set <k6>=Ov
	set <k7>=Ow
	set <k8>=Ox
	set <k9>=Oy
endif

" make recordings easier to fire off, binding alt+comma to @q (use qq to record 
" to q register)
" TBH since i wanted to bring comma back and stick with defaults, @ isnt too 
" hard to reach anyway, I abandoned this map for a while
if has('nvim')
	nnoremap <m-,> @q
else
	nnoremap <F19> @q
endif

" more ctrlp settings
let g:ctrlp_switch_buffer = 'Et' " Jump to tab AND buffer if already open
let g:ctrlp_open_new_file = 'r' " Open new files in a new tab
let g:ctrlp_open_multiple_files = 'vj'
let g:ctrlp_show_hidden = 1 " Index hidden files
let g:ctrlp_follow_symlinks = 1

" Edit this as necessary as work patterns change...
" Do note that you have to manually rescan with F5 to see this applied!
let g:ctrlp_custom_ignore = { 
			\ 'dir':  '\v[\/]node_modules|(public\/js\/app\/views)|(\.(git|hg|svn))',
			\ 'file': '\v\.(exe|so|dll|DS_Store|un\~)$',
			\ }

" pulled from http://vim.wikia.com/wiki/Move_current_window_between_tabs
function! MoveToPrevTab()
	"there is only one window
	if tabpagenr('$') == 1 && winnr('$') == 1
		return
	endif
	"preparing new window
	let l:tab_nr = tabpagenr()
	let l:tab_nr_end = tabpagenr('$')
	let l:cur_buf = bufnr('%')
	if tabpagenr() != 1
		close!
		if l:tab_nr == tabpagenr()
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
	if tabpagenr() < l:tab_nr
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
	res +8
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
	res -8
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
	vertical res +15
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
	vertical res -15
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

" shortcut for visual mode space wrapping makes it more reasonable than using 
" default vim surround space maps which require hitting space twice or 
" modifying wrap actions by prepending space to their triggers -- i am guiding 
" the default workflow toward being more visualmode centric which involves less 
" cognitive frontloading.
vmap <Space> S<Space><Space>

" restore the functions for shifting selections
vnoremap << <
vnoremap >> >

" if ;w<CR> is typed in insert mode, exit insert mode and run a prompt asking
" if you really want to save the file (rather than inserting ;w<CR> into file)
function! MyConfirmSave()
	if confirm('Save file? (you probably hit ;w<CR> in insert mode...)', "OK\nNo") == 1
		w
		silent redraw!
	endif
endfunc
inoremap ;w<CR> <ESC>:call MyConfirmSave()<CR>

function! MyConfirmSaveQuit()
	if confirm('Save file and then QUIT? (you probably hit ;wq<CR> in insert mode...)', "OK\nNo") == 1
		wq
		silent redraw!
	endif
endfunc
inoremap ;wq<CR> <ESC>:call MyConfirmSaveQuit()<CR>

function! MyConfirmSaveQuitAll()
	if confirm('Save file and then QUIT ALL? (you probably hit ;wqa<CR> in insert mode...)', "OK\nNo") == 1
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
" Sadly gotta disable this --- it's too goddamn cluttery to leave session files 
" EVERY time. I need to come up with something to more easily save though. 
" I reckon I should re-enable this, but make it auto-clean all but the 3 most 
" recent session files. These session shits work REALLY good.
" autocmd VimEnter * call RestoreSess()

" This is for not putting two spaces after a period when Vim formats things. 
" It's a dumb style that wastes perfectly good bytes and space for no good 
" reason and looks annoying.
set nojoinspaces

" This is for less frustration in vblock mode (virtual-edit)
set ve=block

" something somebody cameup with in response to my SO topic
onoremap <silent> x :<C-u>execute 'normal! vlF' . nr2char(getchar()) . 'of' . nr2char(getchar())<CR>
vnoremap <silent> x :<C-u>execute 'normal! vlF' . nr2char(getchar()) . 'of' . nr2char(getchar())<CR>

" scrollbinding to view a file in columns
:noremap <silent> <Leader>c :<C-u>let @z=&so<CR>:set so=0 noscb<CR>:bo vs<CR>Ljzt:setl scb<CR><C-w>p:setl scb<CR>:let &so=@z<CR>

" auto enable rainbow on c/cpp files
" Nope! too slow on preprocessor output
" au FileType c,cpp,objc,objcpp call rainbow#load()

" syntax sync minlines=256 " this was an attempt to speed up syntax on raspi.
" May not be necessary now that i took out line highlight

let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#left_sep = ''
let g:airline#extensions#tabline#left_alt_sep = ''
if !exists('g:airline_symbols')
  let g:airline_symbols = {}
endif
let g:airline_left_sep = ''
let g:airline_left_alt_sep = ''
let g:airline_right_sep = ''
let g:airline_right_alt_sep = ''
let g:airline_symbols.branch = ''
let g:airline_symbols.readonly = ''
let g:airline_symbols.linenr = ''
let g:airline_theme='bubblegum'

let g:airline#extensions#hunks#non_zero_only = 1
let g:airline#extensions#whitespace#mixed_indent_algo = 1
let g:airline#extensions#hunks#hunk_symbols = ['+', '~', '-']
let g:airline#extensions#tagbar#enabled = 1 " not sure if does anything
let g:airline#extensions#tagbar#flags = 'f' " not sure if does anything

" Honestly I spend way too much time cleaning up trailing spaces which has as 
" yet never had any solid reason. There are legitimate uses of trailing spaces 
" in e.g. markdown.
let g:airline#extensions#whitespace#checks = [ 'indent' ]

let g:airline#extensions#tabline#formatter = 'unique_tail_improved'
let g:airline#extensions#branch#displayed_head_limit = 15
let g:airline#extensions#default#section_truncate_width = {
  \ 'b': 60,
  \ 'x': 125,
  \ 'y': 113,
  \ 'z': 100,
  \ 'warning': 50,
  \ }

" Highlight words to avoid in tech writing
" =======================================
"
"   obviously, basically, simply, of course, clearly,
"   just, everyone knows, However, So, easy

"   http://css-tricks.com/words-avoid-educational-writing/

highlight TechWordsToAvoid ctermbg=52
" 52 is the darkest red and it is a handy non-painful color

function! MatchTechWordsToAvoid()
	match TechWordsToAvoid /\c\<\(obviously\|basically\|simply\|of\scourse\|clearly\|everyone\sknows\|so,\)\>/
endfunction
autocmd FileType vim,markdown,javascript,cpp,bash,zsh,sh call MatchTechWordsToAvoid()
" autocmd BufWinEnter *.md call MatchTechWordsToAvoid()
" autocmd InsertEnter *.md call MatchTechWordsToAvoid()
" autocmd InsertLeave *.md call MatchTechWordsToAvoid()
" autocmd BufWinLeave *.md call clearmatches()

" woot, disable phantom clicktyping into random spots
inoremap <LeftMouse> <Nop>
inoremap <2-LeftMouse> <Nop>
inoremap <3-LeftMouse> <Nop>
inoremap <4-LeftMouse> <Nop>

" Had this SO question answered a while ago but didnt get chance to insert it
" till now.
function! SmartInsertStartOfLine()
	if synIDattr(synID(line("."), col("."), 1), "name") =~ "Comment"
		normal! ^w
		startinsert
	else
		call feedkeys('I', 'n')
	endif
endfun
" http://stackoverflow.com/a/22282505/340947
nnoremap I :call SmartInsertStartOfLine()<CR>

" corresponding bind for A which smartly places the cursor before any semicolon
" that may be present at the end of the line
function! SmartInsertEndOfLine()
	let l:linenrsearch = search(';\s*$', 'n')
	if (l:linenrsearch == line('.')) " If the current line ends in semicolon 
										 " using 'n' to not move the cursor to 
										 " a different line
		call search(';\s*$')
		startinsert
	else
		call feedkeys('A', 'n')
	endif
endfun

" Overriding the key that normally moves to the end of a big-word. I never use 
" that... However, it may be smart to eventually remap some other combo to that 
" functionality
nnoremap E :call SmartInsertEndOfLine()<CR>

" I decided i wanted the b for page up again. i already got used to backspace to 
" go back a word; i don't have a problem with it. The reach for the Z key is not 
" nice. And its not like i was going to make the backspace key do page up 
" either, thats too reachy to navigate around. It does seem to work well enough 
" when moving back short distances on a line so i like it the way i had it 
" before.
nnoremap b <C-U>
vnoremap b <C-U>

" fixes aggravating default indentation for switch case statements, which also 
" affects e.g. JavaScript -- except it stopped working, lets try l
set cinoptions=J1

" this just makes more sense (there is potential quirkiness with yankstack, but 
" with minimal testing, this appears to now work well)
nmap Y y$

set switchbuf=usetab,split

" " bind to not the default
" if has('nvim')
" 	let g:NumberToggleTrigger="<m-n>" " this seems to not be working
" 	nnoremap <M-n> :call NumberToggle()<CR>
" else
" 	let g:NumberToggleTrigger="<F21>" " alt+n
" endif

" now that focuslost works with iterm and tmux maybe this is just generally 
" improved behavior. Do have to be careful, but it speeds shit up when rapidly 
" working
" Update not too many weeks later -- This actually causes phantom unintended 
" undoes being committed -- Also complicit in that particular brand of 
" treachery is Airline's tab bar. I am bringing back the old utilitarian tab 
" bar of mine again...

" au FocusLost * silent! wa

" just also exit insert mode when swapping out via click or whatever
au FocusLost * stopinsert 

" for tagbar
" add a definition for Objective-C to tagbar
let g:tagbar_type_objcpp = {
	\ 'ctagstype' : 'objcpp',
	\ 'kinds': [
	\     'i:class interface'
	\,    'x:class extension'
	\,    'I:class implementation'
	\,    'P:protocol'
	\,    'M:method'
	\,    't:typedef'
	\,    'v:variable'
	\,    'p:property'
	\,    'e:enumeration'
	\,    'f:function'
	\,    'd:macro'
	\,    'g:pragma'
	\,    'c:constant'
	\, ],
	\ 'sro'        : ' '
	\ }
let g:tagbar_type_objc = {
	\ 'ctagstype' : 'objcpp',
	\ 'kinds': [
	\     'i:class interface'
	\,    'x:class extension'
	\,    'I:class implementation'
	\,    'P:protocol'
	\,    'M:method'
	\,    't:typedef'
	\,    'v:variable'
	\,    'p:property'
	\,    'e:enumeration'
	\,    'f:function'
	\,    'd:macro'
	\,    'g:pragma'
	\,    'c:constant'
	\, ],
	\ 'sro'        : ' '
	\ }

" set tagbar highlight color
hi TagBarHighlight ctermbg=27 ctermfg=254

" set tagbar to open on the left side
let g:tagbar_left=1

" Store temporary files in a central spot
let vimtmp = $HOME . '/.tmp/' . getpid()
silent! call mkdir(vimtmp, "p", 0700)
let &backupdir=vimtmp
let &directory=vimtmp

" I've been watching Drew Neil's vimcasts.
" Here are some binds that are just brilliant for the :e command which remains 
" greatly useful even in the presence of CtrlP
cnoremap %% <C-R>=fnameescape(expand('%:h')).'/'<cr>
map <leader>ew :e %%
map <leader>es :sp %%
map <leader>ev :vsp %%
map <leader>et :tabe %%

" Spell check on by default. Why not? It just needs to be a style that is 
" sufficiently subtle so that it does not become annoying. The default of red 
" background is problematic. I am a little undecided on if underline is 
" sufficient.
set spell
nmap <leader>s :set spell!<CR>

highlight SpellBad ctermbg=NONE ctermfg=NONE cterm=underline
highlight SpellCap ctermbg=NONE ctermfg=NONE cterm=underline,bold
highlight SpellRare ctermbg=NONE ctermfg=NONE cterm=underline
" There exist some other spelling related highlight styles but i'll just deal 
" with them when i see them show up as I see fit. the capitalization one is 
" pretty acceptable for now also.

" Macro meta commands. For editing macros to refine them. This is just brimming 
" with power. Found here: 
" http://dailyvim.blogspot.com/2007/11/macro-registers.html
" Not too much but just a wrinkle, not really able (easily) to start recording 
" into the p or d registers. well then  i think

nnoremap qp Go<ESC>"qp
nnoremap qd G0"qd$

" Just taking some space here to document the method for generating nice 
" unicode fixed-width-text tables.

" aaaabbbbbcdefffg
" a  abbdbbcdffffggg
" a  abbbbcddfffgh
" aaaabbbbbcdefffg
" 
" aaa aaaa aaa
" a a a  a a a
" aaa aaaa a a
"          aaa

" ############&&&&&^^^
" ##########&&&&&&&
" ###text#&&&&&&
" ##########&&&&&&&
" ############&&&&&^^^


" Converts using outline.pl to:
 
" ┌───┬────┬┬┬┬──┬┐
" │┌─┐│ ┌┐ ││├┘  │└─┐
" ││ ││ └┘┌┼┘│  ┌┼┬─┘
" │└─┘│   └┼┐├┐ └┼┤
" └───┴────┴┴┴┴──┴┘
" ┌──┐┌───┐┌──┐
" │┌┐││┌─┐││┌┐│
" │└┘││└─┘│││││
" └──┘└───┘│└┘│
"          └──┘

" Note how this is really easy to invoke (visual select, then :!out<Tab><CR>)
" Outline has been edited by me to only accept numeric and special char values
" to convert to lines while leaving the rest as-is -- this way a table can be 
" edited and re-rendered much more readily.

" there is also bdua2b.pl

" +------+
" | text |
" +--+---+--+
" +--+   |  |
" +--+---+  |
" +---------+

" ┌──────┐
" │ text │
" ├──┬───┼──┐
" ├──┤   │  │
" ├──┴───┘  │
" └─────────┘

" The combination of smart non-text-destructive box rendering combined with 
" textmanip makes for extremely powerful visual text-based drawing.


" globally highlight, remember the match only can be set to one thing

" Right now I initialize it to show bad tech writing words, but with the toggle 
" here we can explicitly highlight the overlong lines. There is a potential 
" tweak which is to toggle between the regex for the bad words and the regex 
" for long lines AND bad words... But it's a lot less editable/maintainable -- 
" so I am going to leave it like this for now since the match is per buffer not 
" per vim session.

autocmd BufEnter * highlight OverLength ctermbg=52

fu! LongLineHighlightToggle()
	highlight OverLength ctermbg=52
	if exists('w:long_line_match') 
		match OverLength //
		unlet w:long_line_match
		" set colorcolumn=""
	else 
		match OverLength /\%>79v.\+/
		let w:long_line_match = 1
		" set colorcolumn=80
	endif
endfunction
map <Leader>l :call LongLineHighlightToggle()<CR>

set colorcolumn=80
highlight ColorColumn ctermbg=235 term=NONE

" This one is insane. In the membraaaane...
" So I originally wanted to bind this behavior to period since itd be sick 
" (except for times when it would cause me to skip some search&repeat 
" applications), I can't actually do this because of repeat.vim dynamically 
" overriding the period binding. That's quite alright, though, now I just have 
" to remember to use alt period to trigger this neatness (because ctrl period 
" is not supported by the terminal *shakefist*).

" I further enhance my special alt period bind with a contextual superpower 
" based on the searching state -- if searching highlight is enabled, we will 
" hop to the next match before calling dot! Otherwise, hop down a line. This 
" handles both situations so elegantly that it almost hurts.
if has('nvim')
	" shit neovim has issues with binding keys...
	nnoremap <m-.> :<C-u>call MyAmazingEnhancedDot(v:count1)<CR>
else
	nnoremap <F20> :<C-u>call MyAmazingEnhancedDot(v:count1)<CR>
endif

function! MyAmazingEnhancedDot(count)
	let c = a:count
	while c > 0
		if v:hlsearch == 1
			:normal! .n
		else
			:normal! .j
		endif
		let c -= 1
	endwhile
endfunction

" keymap definitions for textmanip
xmap <C-D> <Plug>(textmanip-duplicate-down)
nmap <C-D> <Plug>(textmanip-duplicate-down)
" Not sure if i need to consume ctrl+u for this. May not ever use it...
xmap <C-U> <Plug>(textmanip-duplicate-up)
nmap <C-U> <Plug>(textmanip-duplicate-up)

xmap <Down> <Plug>(textmanip-move-down)
xmap <Up> <Plug>(textmanip-move-up)
xmap <Left> <Plug>(textmanip-move-left)
xmap <Right> <Plug>(textmanip-move-right)

" toggle insert/replace for textmanip with Ctrl+E
nmap <C-E> <Plug>(textmanip-toggle-mode)
xmap <C-E> <Plug>(textmanip-toggle-mode)

" save states for php. This affects too many variables for comfort, but I do 
" want it to work so I can maintain folding state. It's a sad compromise for 
" now. (so php is the only language having insane files i need folding to work 
" in -- whenever i find persistent buffer settings due to this mkview I can 
" manually erase these files (after exiting Vim, as exiting vim causes it to 
" write the view))
au BufWinLeave *.php mkview
au BufWinEnter *.php silent loadview

" easy-align bindings
" hit uppercase a in visual to align it. I thought it was unmapped but it is 
" hella mapped and I use it a lot it turns out (say you want to wrap a string 
" literal in parens... now the uppercase A is really only useful for adding 
" characters along the right side of a block visual selection but that's easily
" done with uppercase I. And I reckon virtual-edit for block helps though the 
" any commented wrapping text will mess with it pretty hard. Oh well.
vmap A <Plug>(LiveEasyAlign)
" use ga such as gaip to align paragraph
nmap ga <Plug>(LiveEasyAlign)

" for the octol/vim-cpp-enhanced-highlight plugin
let g:cpp_experimental_template_highlight=1
let g:cpp_class_scope_highlight=1

" " neat bracketed paste handling (not sure if i need special tmux shit but lets 
" " try this minimal version first)

" let &t_SI .= "\<Esc>[?2004h"
" let &t_EI .= "\<Esc>[?2004l"

" inoremap <special> <expr> <Esc>[200~ XTermPasteBegin()

" function! XTermPasteBegin()
"   set pastetoggle=<Esc>[201~
"   set paste
"   return ""
" endfunction

" bind Alt+B to insert mode temporary entry into visual mode and automatically 
" travel to the end of the current word, mainly useful for facilitating fast 
" vim-surround operations with brackets and such things via visual mode
if has('nvim')
	inoremap <m-b> <ESC>lve
else
	set <F15>=b
	inoremap <F15> <ESC>lve
endif

" bind Alt+V to do the same as alt+B but do less work whereby visual mode is 
" temporarily engaged (and we return to insert mode afterwards), and also the 
" movement to end of word is not auto performed
if has('nvim')
	inoremap <m-v> <c-o>v
else
	set <F16>=v
	inoremap <F16> <c-o>v
endif

" Override the default which uses m-p which conflicts with my paste mode 
" binding
let g:AutoPairsShortcutToggle = '<m-z>'
let g:AutoPairsShortcutBackInsert = '<m-x>'
let g:AutoPairsCenterLine = 0

" bind Alt+P in insert mode to paste (for nvim)..
" this actually conflicts with internal vim binding, see i_CTRL_P, but 
" basically it does work somehow, only once per insertmode excursion. Better 
" than nothing.
if has('nvim')
	inoremap <c-p> <c-r>"
endif

" a special case for surrounding with newlines
vmap S<CR> S<C-J>V2j=
