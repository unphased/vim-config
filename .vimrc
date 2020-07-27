set nocompatible
set encoding=utf-8
set showcmd

set autoindent

filetype plugin indent on

call plug#begin('~/.vim/plugged')

Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }

Plug 'junegunn/fzf.vim'
Plug 'fidian/hexmode'
Plug 'rizzatti/dash.vim'
Plug 'chrisbra/csv.vim'

Plug 'godlygeek/tabular'
Plug 'plasticboy/vim-markdown'
Plug 'iamcco/markdown-preview.nvim', { 'do': { -> mkdp#util#install() }, 'for': [ 'markdown', 'vim-plug' ] }
Plug 'brgmnn/vim-opencl'

let g:vim_markdown_folding_disabled = 1

let g:csv_hiGroup = 'CursorColumn'
let g:csv_highlight_column = 'y'

Plug 'jreybert/vimagit'

Plug 'liuchengxu/vista.vim'

" if !has('nvim')
	Plug 'neoclide/coc.nvim', {'branch': 'release'}
	" for coc.nvim

	" au FileType c,cpp,objc,objcpp set cmdheight=2

	set updatetime=300
	set shortmess+=c

	set nobackup
	set nowritebackup
	inoremap <silent><expr> <TAB>
		  \ pumvisible() ? "\<C-n>" :
		  \ <SID>check_back_space() ? "\<TAB>" :
		  \ coc#refresh()
	inoremap <expr><S-TAB> pumvisible() ? "\<C-p>" : "\<C-h>"

	function! s:check_back_space() abort
	  let col = col('.') - 1
	  return !col || getline('.')[col - 1]  =~# '\s'
	endfunction

	" Use <cr> to confirm completion, `<C-g>u` means break undo chain at current 
	" position.
	" Coc only does snippet and additional edit on confirm.
	" inoremap <expr> <cr> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"
	" Or use `complete_info` if your vim support it, like:
	" inoremap <expr> <cr> complete_info()["selected"] != "-1" ? "\<C-y>" : "\<C-g>u\<CR>"
	"
	" new way to complete on enter
	inoremap <silent><expr> <cr> pumvisible() ? coc#_select_confirm()
				\: "\<C-g>u\<CR>\<c-r>=coc#on_enter()\<CR>"
	
	" Use `[g` and `]g` to navigate diagnostics
	nmap <silent> [g <Plug>(coc-diagnostic-prev)
	nmap <silent> ]g <Plug>(coc-diagnostic-next)

	" Remap keys for gotos
	nmap <silent> gd <Plug>(coc-definition)
	" satisfies my need for commanded go to def split, this replaces Select mode
	nnoremap gh :call CocAction('jumpDefinition', 'split')<CR>
	" vert split go to def, replaces gv which selects previous selection
	nnoremap gv :call CocAction('jumpDefinition', 'vsplit')<CR>
	" new tab go to def, replaces original vim bind for going to next tab, which is good to know, and 
	" which i will use on clean systems, but i already have F2 and tab and ctrl+pgdn for that.
	nnoremap gt :call CocAction('jumpDefinition', 'tabe')<CR>
	nmap <silent> gy <Plug>(coc-type-definition)
	nmap <silent> gi <Plug>(coc-implementation)
	nmap <silent> gr <Plug>(coc-references)

	if has('nvim')
		let g:coc_snippet_next = '<c-tab>'
		let g:coc_snippet_prev = '<c-s-tab>'
	else
		imap <F23> <Plug>(coc-snippets-expand-jump)
		let g:coc_snippet_next = '<F23>'
		let g:coc_snippet_prev = '<F22>'
	endif

	" Highlight symbol under cursor on CursorHold
	autocmd CursorHold * silent call CocActionAsync('highlight')

	" Remap for rename current word
	nmap <leader>rn <Plug>(coc-rename)

	" Remap for format selected region
	xmap <leader>f  <Plug>(coc-format-selected)

	augroup mygroup
	  autocmd!
	  " Setup formatexpr specified filetype(s).
	  autocmd FileType typescript,json setl formatexpr=CocAction('formatSelected')
	  " Update signature help on jump placeholder
	  autocmd User CocJumpPlaceholder call CocActionAsync('showSignatureHelp')
	augroup end

	" Remap for do codeAction of selected region, ex: `<leader>aap` for current paragraph
	xmap <leader>a  <Plug>(coc-codeaction-selected)
	nmap <leader>a  <Plug>(coc-codeaction-selected)

	" Remap for do codeAction of current line
	nmap <leader>ac  <Plug>(coc-codeaction)
	" Fix autofix problem of current line
	nmap <leader>qf  <Plug>(coc-fix-current)

	" Use `:Format` to format current buffer
	command! -nargs=0 Format :call CocAction('format')

	" Use `:Fold` to fold current buffer
	command! -nargs=? Fold :call   CocAction('fold', <f-args>)

	" use `:OR` for organize import of current buffer
	command! -nargs=0 OR   :call   CocAction('runCommand', 'editor.action.organizeImport')

	" Add status line support, for integration with other plugin, checkout `:h coc-status`
	" set statusline^=%{coc#status()}%{get(b:,'coc_current_function','')}

	nnoremap ? :call <SID>show_documentation()<CR>

	function! s:show_documentation()
	  if (index(['vim','help'], &filetype) >= 0)
		execute 'h '.expand('<cword>')
	  else
		call CocAction('doHover')
	  endif
	endfunction

" endif " if not nvim

if has('nvim')
" Plug 'neovim/nvim-lsp'
" Plug 'ervandew/supertab'
" Plug 'haorenW1025/completion-nvim'
endif

Plug 'jackguo380/vim-lsp-cxx-highlight'
let g:lsp_cxx_hl_log_file = '/tmp/vim-lsp-cxx-hl.log'
" let g:lsp_cxx_hl_verbose_log = 1
let g:lsp_cxx_hl_use_text_props = 1

" Load on nothing
" Plug 'SirVer/ultisnips', { 'on': [] }
" Plug 'Valloric/YouCompleteMe', { 'on': [] }
" Plug 'scrooloose/syntastic', { 'on': [] }
" Plug 'Shougo/neocomplete.vim'
" Plug 'w0rp/ale'
Plug 'chrisbra/Colorizer'
Plug 'majutsushi/tagbar', { 'on': ['Tagbar'] }
" Plug 'xavierd/clang_complete'

let s:LoadExpensivePluginsHasBeenRun = 0
function! LoadExpensive()
	if !(s:LoadExpensivePluginsHasBeenRun)
		echom 'loadexpensive'
		" call plug#load('ultisnips')
		call plug#load('tagbar')
		" call plug#load('clang_complete')
		autocmd! load_expensive
		let s:LoadExpensivePluginsHasBeenRun = 1
	endif
endfun

augroup load_expensive
	autocmd!
	autocmd InsertEnter * call LoadExpensive()
augroup END

Plug 'maxbrunsfeld/vim-yankstack' 

" Yankstack actually not expensive... this way to lazyload isnt good. (lose 
" first yanks)
", { 'on':  ['<Plug>yankstack_substitute_older_paste', 
"'<Plug>yankstack_substitute_newer_paste'] }
" autocmd! User vim-yankstack call InitYankStack()

Plug 'mbbill/undotree', { 'on': 'UndotreeToggle' }
Plug 'rhysd/clever-f.vim'

" Plug 'editorconfig/editorconfig-vim'

Plug 'rhysd/git-messenger.vim'
Plug 'leafgarland/typescript-vim'
Plug 'peitalin/vim-jsx-typescript'

" Plug 'neoclide/vim-jsx-improve'

" Plug 'chemzqm/vim-jsx-improve'
" let g:jsx_improve_motion_disable = 1

Plug 'scrooloose/nerdtree', { 'on': ['NERDTreeFind', 'NERDTreeToggle'] }
" Plug 'ctrlpvim/ctrlp.vim'
Plug 'vim-scripts/diffchanges.vim'
Plug 'tpope/vim-repeat'
Plug 'tpope/vim-surround'
Plug 'tpope/vim-speeddating'
Plug 'tpope/vim-commentary'
Plug 'tpope/vim-obsession'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-abolish' " this is the plug that does crc,crm,crs,cru (convert variable case e.g. camelCase MixedCase snake_case)
Plug 'tpope/vim-afterimage'
" Plug 'rust-lang/rust.vim'
" Plug 'tpope/vim-endwise'
" Plug 'vim-perl/vim-perl'
" Plug 'mattn/emmet-vim'
" Plug 'unphased/git-time-lapse'
Plug 'vim-scripts/yaifa.vim'
Plug 'nathanaelkane/vim-indent-guides'
" Plug 'wellle/context.vim'
Plug 'wellle/targets.vim'

" TODO: replace hicursorwords with a more straightforward impl such as 
" https://github.com/hotoo/highlight-cursor-word.vim/blob/master/plugin/highlight.vim
"
Plug 'unphased/HiCursorWords'

Plug 'dimasg/vim-mark', { 'on': '<Plug>MarkSet' }
" Bundle 'kien/rainbow_parentheses.vim'
Plug 'mhinz/vim-signify'
" Plug 'pangloss/vim-javascript'
" Plug 'jelera/vim-javascript-syntax'
Plug 'beyondmarc/glsl.vim'
"Bundle 'kana/vim-smartinput'
Plug 'honza/vim-snippets'
" Bundle 'oblitum/rainbow'
" Plug 'marijnh/tern_for_vim'
"
" Plug 'unphased/vim-airline'
" Plug 'vim-airline/vim-airline-themes'
Plug 'itchyny/lightline.vim'

" Plug 'prettier/vim-prettier', {
"   \ 'do': 'npm install',
"   \ 'branch': 'release/1.x',
"   \ 'for': [
"     \ 'javascript',
"     \ 'typescript',
"     \ 'css',
"     \ 'less',
"     \ 'scss',
"     \ 'json',
"     \ 'graphql',
"     \ 'markdown',
"     \ 'vue',
"     \ 'lua',
"     \ 'php',
"     \ 'python',
"     \ 'ruby',
"     \ 'html',
"     \ 'swift' ] }

" Plug 'lfilho/cosco.vim'
" let g:auto_comma_or_semicolon = 1
" let g:cosco_ignore_comment_lines = 1
" nnoremap <Leader>; :AutoCommaOrSemiColonToggle
" let g:cosco_filetype_blacklist = ['vim', 'bash']

" python integration seems to not work without this sometimes, i found this 
" when i was compiling vim myself on ubuntu 18.04
if has('python3')
	python3 import vim
endif

autocmd FileType c,cpp,cs,java setlocal commentstring=//\ %s

let g:lightline = { }
let g:lightline.colorscheme = 'powerline'
let g:lightline.enable = {
			\   'tabline': 1
			\ }

let g:lightline.tabline = {
		    \ 'left': [ [ 'tabs' ] ],
		    \ 'right': [ [ 'close' ] ] }

let g:lightline.tab = {
			\ 'active': [ 'tabwinct', 'filename', 'tabmod', 'readonly' ],
			\ 'inactive': [ 'tabwinct', 'filename', 'tabmod' ]
			\ }
let g:lightline.active = {
			\ 'left': [ [ 'mode', 'paste' ],
			\           [ 'cocstatus', 'gitbranch', 'readonly', 'relativepathtrunc', 'modified' ] ],
			\ 'right': [ [ 'percent' ],
			\            [ 'lineinfo', 'charvaluehex' ],
			\            [ 'fileformatenc', 'filetype' ] ] }
let g:lightline.inactive = {
			\ 'left': [ [ 'relativepathtrunc', 'modified' ] ] }

let g:lightline.tab_component_function = {
			\ 'tabwinct': 'TabWinCt',
			\ 'tabmod': 'TabAnyModified'
			\ }
let g:lightline.component_function = {
			\ 'gitbranch': 'fugitive#head',
			\ 'filesize': 'FileSize',
			\ 'filetype': 'FileTypeFun',
			\ 'cocstatus': 'coc#status',
			\ 'fileformatenc': 'FileFormatEncFun'
			\ }
let g:lightline.component = {
			\ 'mode': '%{lightline#mode()}',
			\ 'absolutepath': '%F',
			\ 'relativepathtrunc': '%<%f',
			\ 'filename': '%t',
			\ 'modified': '%M',
			\ 'bufnum': '%n',
			\ 'paste': '%{&paste?"PASTE":""}',
			\ 'readonly': '%R',
			\ 'charvalue': '%b',
			\ 'charvaluehex': '%02B',
			\ 'fileencoding': '%{&fenc!=#""?&fenc:&enc}',
			\ 'fileformat': '%{&ff}',
			\ 'percent': '%2p%%',
			\ 'percentwin': '%P',
			\ 'spell': '%{&spell?&spelllang:""}',
			\ 'lineinfo': '%l/%L:%c%V',
			\ 'line': '%l',
			\ 'column': '%c%V',
			\ 'close': '%999X X ',
			\ }

function! TabWinCt(n) abort
  let n = tabpagewinnr(a:n, '$')
  if (n == 1)
	  return ''
  else
	  return n
  endif
endfun

function! TabAnyModified(n) abort
	let winct = tabpagewinnr(a:n, '$')
	let modified = 0
	while winct > 0
		if gettabwinvar(a:n, winct, '&modified')
			return '+'
		endif
		let winct -= 1
	endwhile
	return ''
endfunction

function! FileSize()
	let bytes = getfsize(expand("%:p"))
	if bytes <= 0
		return ""
	endif
	if bytes < 65536
		return bytes
	elseif bytes < 67108864
		return (bytes / 1024) . "K"
	else
		return (bytes / 1048576) . "M"
	endif
endfunction

function! FileTypeFun()
	return winwidth(0) > 70 ? (&filetype !=# '' ? &filetype : 'no ft') : ''
endfunction
function! FileFormatEncFun()
	return winwidth(0) > 70 ? &fileformat : ''
endfunction

" Plug 'derekwyatt/vim-fswitch'
" Plug 'wakatime/vim-wakatime'
Plug 'kshenoy/vim-signature'
Plug 'jiangmiao/auto-pairs'
" Plug 'Raimondi/delimitMate'
"Plug 'mxw/vim-jsx'
"Plug 'rstacruz/vim-closer'
" Plug 'cohama/lexima.vim'

" Plug 'fatih/vim-go'

Plug 'tmux-plugins/vim-tmux'

Plug 'unphased/vim-unimpaired'

Plug 'vim-scripts/camelcasemotion'
Plug 'vim-scripts/ingo-library' " needed for EnhancedJumps
Plug 'vim-scripts/EnhancedJumps'

Plug 't9md/vim-textmanip', { 'on': [ '<Plug>(textmanip-move-down)', '<Plug>(textmanip-move-up)', '<Plug>(textmanip-move-left)', '<Plug>(textmanip-move-right)', '<Plug>(textmanip-toggle-mode)', '<Plug>(textmanip-toggle-mode)', ] }

Plug 'junegunn/vim-easy-align'

" Plug 'octol/vim-cpp-enhanced-highlight' " this broke way too often on modern c++ files. Really problematic angle bracket handling. Trying it again.

" Plug 'unphased/Cpp11-Syntax-Support'
" apparently a somewhat-working extension from base cpp stuff. At least it isnt
" a breaking one.

" Plug 'Mizuchi/STL-Syntax'

Plug 'unphased/vim-html-escape' " my master has gdefault detecting tweak

Plug 'rking/ag.vim'
" Plug 'kana/vim-textobj-user'

Plug 'Ron89/thesaurus_query.vim'
Plug 'AndrewRadev/switch.vim'

let g:switch_custom_definitions = 
			\ [
			\   ['show', 'hide']
			\ ]

Plug 'AndrewRadev/sideways.vim'
Plug 'AndrewRadev/linediff.vim'
Plug 'AndrewRadev/splitjoin.vim'
Plug 'AndrewRadev/inline_edit.vim'
" Plug 'AndrewRadev/whitespaste.vim'
Plug 'sickill/vim-pasta'

" superceded by Colorizer
" Plug 'ap/vim-css-color'
" Plug 'Xuyuanp/nerdtree-git-plugin'

" Plug 'chrisbra/NrrwRgn'
Plug 'https://github.com/wesQ3/vim-windowswap'
Plug 'sbdchd/neoformat'
" Plug 'anowlcalledjosh/conflict-marker.vim', { 'branch': 'diff3' }
" use unimpaired for conflict markers: ]n [n
Plug 'elzr/vim-json'
" Plug 'Shougo/echodoc.vim'
" Plug 'myhere/vim-nodejs-complete'

call plug#end()

" if has('nvim')
if 0
	set omnifunc=v:lua.vim.lsp.omnifunc
	nnoremap <silent> <c-]> <cmd>lua vim.lsp.buf.definition()<CR>
	nnoremap <silent> gd    <cmd>lua vim.lsp.buf.declaration()<CR>
	nnoremap <silent> ?     <cmd>lua vim.lsp.buf.hover()<CR>
	nnoremap <silent> 2gd   <cmd>lua vim.lsp.buf.implementation()<CR>
	nnoremap <silent> 3gd   <cmd>lua vim.lsp.buf.signature_help()<CR>
	nnoremap <silent> 1gd   <cmd>lua vim.lsp.buf.type_definition()<CR>
	nnoremap <silent> gr    <cmd>lua vim.lsp.buf.references()<CR>
	nnoremap <silent> g0    <cmd>lua vim.lsp.buf.document_symbol()<CR>

	echo 'nvim_lsp setting up ccls'
	lua vim.lsp.set_log_level("debug")
lua << EOF
	require'nvim_lsp'.ccls.setup{
	-- the following settings are not working. i ended up getting shit working using a .ccls file at the end of the day.
		init_options = { highlight = { lsRanges = true }}
	}
	require'nvim_lsp'.vimls.setup{}
	require'nvim_lsp'.pyls.setup{}
EOF

	" supertab

	" let g:SuperTabDefaultCompletionType = 'context'
	" autocmd FileType *
	" 			\ if &omnifunc != '' |
	" 			\   call SuperTabChain(&omnifunc, "<c-n>") |
	" 			\ endif

	" " Use completion-nvim in every buffer
	" autocmd BufEnter * lua require'completion'.on_attach()

	" " Use <Tab> and <S-Tab> to navigate through popup menu
	" inoremap <expr> <Tab>   pumvisible() ? "\<C-n>" : "\<Tab>"
	" inoremap <expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<S-Tab>"

	" " Set completeopt to have a better completion experience
	" set completeopt=menuone,noinsert,noselect

	" " Avoid showing message extra message when using completion
	" set shortmess+=c
	" let g:completion_enable_auto_popup = 0
	" function! s:check_back_space() abort
	" 	let col = col('.') - 1
	" 	return !col || getline('.')[col - 1]  =~ '\s'
	" endfunction

	" inoremap <silent><expr> <TAB>
	" 			\ pumvisible() ? "\<C-n>" :
	" 			\ <SID>check_back_space() ? "\<TAB>" :
	" 			\ completion#trigger_completion()

endif

call coc#add_extension('coc-json', 'coc-snippets', 'coc-python', 'coc-tabnine', 'coc-tsserver', 'coc-vimlsp', 'coc-emmet', 'coc-eslint', 'coc-diagnostic', 'coc-prettier')

let g:on_battery = 'zzzz'
function! CheckBatteryTabNine()
	call system('onbatt')
	echom 'what '.g:on_battery
	echom 'wtf '. (v:shell_error != g:on_battery)
	if v:shell_error != g:on_battery
		let g:on_battery = v:shell_error
		if g:on_battery == 0
			echom 'On battery: Disabling coc-tabnine when entering buffers.'
			call CocAction('deactivateExtension', 'coc-tabnine')
		else
			echom 'Not on battery: Enabling coc-tabnine when entering buffers.'
			" let l:z = CocAction('extensionStats')
			" echo 'extensionStats: '.l:z
			call CocAction('activeExtension', 'coc-tabnine')
		endif
	else
		echom 'no '.v:shell_error
	endif
endfun

" autocmd BufRead * call CheckBatteryTabNine()

" TODO make this detect and use zeal for linux and dash on mac
nnoremap <F5> :Dash!<CR>

" ensures (from vim) that tmux config works right for title
if &term == "tmux-256color-italic"
	set t_ts=]0;
	set t_fs=
endif

set title

" suppresses "Thanks for flying Vim", though I'd like to know why it fails at restoring original 
" title.
set titleold=

" To use echodoc, you must increase 'cmdheight' value.
" set cmdheight=2
" let g:echodoc_enable_at_startup = 1

if has('nvim')
	autocmd BufEnter * let &titlestring = "NVIM " . expand("%:t")

	autocmd BufEnter * highlight LspDiagnosticsError ctermbg=88 guibg=#870000
	autocmd BufEnter * highlight LspDiagnosticsWarning ctermbg=11 guibg=#878700
	autocmd BufEnter * highlight LspDiagnosticInformation ctermbg=242 guibg=#303030
	autocmd BufEnter * highlight LspDiagnosticHint ctermbg=88 guibg=#870000
	autocmd BufEnter * highlight LspReferenceText ctermbg=88 guibg=#870000

else
	autocmd BufEnter * let &titlestring = "VIM " . expand("%:t")
endif
" Bundle 'Decho'

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
au! BufNewFile,BufRead *.vsh,*.fsh,*.vp,*.fp,*.gp,*.vs,*.fs,*.gs,*.tcs,*.tes,*.cs,*.vert,*.frag,*.geom,*.tess,*.shd,*.gls,*.glsl set ft=glsl440
au! BufNewFile,BufReadPost *.md set filetype=markdown
au! BufRead,BufNewFile CUDA*.in,*.cuda,*.cu,*.cuh set ft=cuda

" customize it for my usual workflow
autocmd FileType gitcommit setlocal nosmartindent | setlocal formatoptions-=tcl

" this thing needs work
" nnoremap <Leader>g :call TimeLapse()<CR>

" nnoremap <Leader>e :silent !p4 edit %:p<CR>:redraw!<CR>
nnoremap <Leader>R :silent redraw!<CR>

set noequalalways

" let g:neocomplete#enable_at_startup = 1
" let g:neocomplete#min_keyword_length = 3
" let g:neocomplete#enable_fuzzy_completion = 1
" if !exists('g:neocomplete#keyword_patterns')
"     let g:neocomplete#keyword_patterns = {}
" endif
" let g:neocomplete#keyword_patterns['javascript'] = '[@#.]\?[[:alpha:]_:-][[:alnum:]_:-]*'

" autocmd FileType javascript set formatprg=prettier\ --stdin
" this is unsafe (syntax errors and bad line wrapping)

" neocomplete: bind tab for similar behavior to YCM
" inoremap <expr><TAB>  pumvisible() ? "\<C-n>" : "\<TAB>"
" inoremap <expr><S-TAB>  pumvisible() ? "\<C-p>" : "\<S-TAB>"

" These are apparently the defacto terminal codes for Ctrl+Tab and Ctrl+Shift+Tab
" but Vim has no knowledge of it. so here i am adding it to the fastkey 
" repertoire, but skipping F24 and F25 because the actual vitality plugin uses 
" this method specifically on F24 and F25
if !has('nvim')
	" c-tab
	set <F23>=[27;5;9~
	" s-c-tab
	set <F22>=[27;6;9~

	set <F20>=.
	set <F19>=,
	set <F16>=>
	set <F14>=<
endif

" " Ultisnips settings (to have it work together with YCM)
" if has('nvim')
" 	let g:UltiSnipsExpandTrigger="<C-TAB>"
" 	let g:UltiSnipsJumpForwardTrigger="<C-TAB>"
" 	let g:UltiSnipsJumpBackwardTrigger="<C-S-TAB>"

" 	" Just set to something so that c-tab wont be used (needed for nvim)
" 	let g:UltiSnipsListSnippets="<M-c>"
" else
" 	" I believe default <c-tab> binding fails to work on vim so this just ends 
" 	" up working the way i want
" 	let g:UltiSnipsExpandTrigger="<F23>"
" 	let g:UltiSnipsJumpForwardTrigger="<F23>"
" 	let g:UltiSnipsJumpBackwardTrigger="<F22>"
" endif
" " Using Ctrl Tab to fire the snippets. Shift tab is taken by YCM.
" " the weird custom mapping doesn't really seem to help anything and I cannot
" " figure out how to get it to respond to tab properly, so it should be an easy
" " enough thing to get used to to use Ctrl+(Shift+)Tab to control snips. Should
" " even allow seamless use of YCM while entering an ultisnip segment, so this is
" " pretty much near perfect for snippets since too much overloading is confusing
" " anyway.
" let g:UltiSnipsEditSplit="vertical"

" " let g:UltiSnipsSnippetDirectories = ["UltiSnips"]

" indent guides plugin
let g:indent_guides_enable_on_vim_startup = 1
let g:indent_guides_auto_colors = 0
let g:indent_guides_start_level = 1
let g:indent_guides_guide_size = 1

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

nnoremap <F4> :UndotreeToggle<CR>
inoremap <F4> <ESC>:UndotreeToggle<CR>

" These C-V and C-C mappings are for fakeclip, but fakeclip doesn't work on
" OSX and I never really seem to do much copying and pasting
" nmap <C-V> "*p
" vmap <C-C> "*y

" The new way to do copypaste is with + register -- I already have it set up to 
" have visual mode y yank to OS X pasteboard.

nnoremap <Leader>L :autocmd!<CR>:so $MYVIMRC<CR>:runtime! after/plugin/*.vim<CR>:runtime! after/ftplugin/*.vim<CR>

" for camelcasemotion, bringing back the original , by triggering it with ,,
" the comma repeats last t/f/T/F, which is *still* completely useless... Here's
" the thing. There's nothing useful to bind comma to, because comma is used 
" with camelcasemotion in normal mode because it's still marginally useful that 
" way.
" nnoremap ,, ;
" xnoremap ,, ;
" onoremap ,, ;
" now no longer really needed with cleverf

" for use with bkad's cmm. i went back because i found a bug
" call camelcasemotion#CreateMotionMappings(',')

" add some cases so that certain common keystrokes when used from visual mode 
" (which i often land in) will do what i would want it to do
xmap <C-P> <ESC><C-P>
omap <C-P> <ESC><C-P>

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
set ttimeoutlen=3

" set t_Co=256
" set term=screen-256color-italic
if !has('nvim')
	set ttymouse=xterm2
endif

syntax on
set number

set numberwidth=2
set laststatus=2
set undodir=~/.tmp

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
augroup checktime_augroup
    au!
    if !has("gui_running")
        "silent! necessary otherwise throws errors when using command
        "line window.
        autocmd BufEnter        * silent! checktime
        autocmd CursorHold      * silent! checktime
        autocmd CursorHoldI     * silent! checktime
        "these two _may_ slow things down. Remove if they do.
        "autocmd CursorMoved     * silent! checktime
        "autocmd CursorMovedI    * silent! checktime
    endif
augroup END

augroup yank_saving_group
" autocmd! CursorHold * noautocmd call YankSave()
" autocmd! CursorHoldI * call YankSave()
augroup END

let g:yank_save_buffer = ''
function! YankSave()
	" yank into pbcopy if @@ has changed.
	let yanked = substitute(@@, '\n', '\\n', 'g')
	if g:yank_save_buffer != yanked
		echom "running YankSave update!"
		let poscursor=getpos('.')
		let g:yank_save_buffer = yanked
		" this converts @@ into a bash single-quoted string by doing two 
		" transformations, turning single quotes inside @@ into '"'"', which is 
		" how you insert a single quote into a bash single quoted string, and 
		" the newlines which show as NULs in the variable into escaped newlines 
		" which are how to make the newlines work in the bash string. Then pipe 
		" into pbcopy.
		silent exec "!echo '" . substitute(escape(substitute(@@, "'", "'\"'\"'", 'g'), '!\#%'), '\n', '\\n', 'g') . "' | pbcopy"
		call setpos('.', poscursor)
	endif
endfun
" This stuff is cool, but is subject to vim's own ex substitutions, for 
" a subset of the ones it does, which is reasonably safe even when tested on 
" this vimrc itself (which is a minefield for this, if there ever was one). 
" With that being said it is not a perfectly correct operation, because e.g. 
" something like <afile> will get converted in the pbcopy. So, I am 
" contemplating switching this approach for writing to a temp file first in 
" order to make it correct.


if &term =~ '256color'
    " Disable Background Color Erase (BCE) so that color schemes
    " work properly when Vim is used inside tmux and GNU screen.
    " See also http://snk.tuxfamily.org/log/vim-256color-bce.html
    set t_ut=
endif

" prevent the damn commandlist from coming up. One day when i prevent the enter 
" bind from working in this window i can bring it back and actually use it. but 
" until then...
" nnoremap q: <Nop>
" this has a problem though: q now has a delay even when used to stop 
" a recording. argh.

colorscheme Tomorrow-Night-Eighties
hi LineNr ctermfg=242
" overrides the linenr set by above colorscheme.

"set listchars=tab:→\ ,extends:>,precedes:<,trail:·,nbsp:◆
set listchars=tab:→\ ,extends:»,precedes:«,trail:·,nbsp:◆
set list

hi NonText ctermbg=235 ctermfg=241
hi SpecialKey ctermfg=239

" Enhancements which override colorscheme
hi Statement cterm=bold
hi Exception ctermfg=211

hi FoldColumn guibg=black
hi Folded guibg=#151515

highlight DiffAdd term=reverse ctermbg=156 ctermfg=black guibg=#304930
highlight DiffChange term=reverse ctermbg=33 ctermfg=black guibg=#114048
highlight DiffText term=reverse ctermbg=blue ctermfg=16 guibg=#452250
highlight DiffDelete term=reverse ctermbg=red ctermfg=white guibg=#58252e

highlight SignifySignAdd    cterm=bold ctermbg=none ctermfg=119 guifg=#99ee99
highlight SignifySignDelete cterm=bold ctermbg=none ctermfg=167 guifg=#f255ba
highlight SignifySignChange cterm=bold ctermbg=none ctermfg=227 guifg=#99eeee
highlight SignifySignChangeDelete cterm=bold ctermbg=none ctermfg=203 guifg=#f99157

highlight SignifyLineAdd    ctermfg=none ctermbg=119 guibg=#203a20
highlight SignifyLineDelete ctermfg=none ctermbg=167 guibg=#3f1533
highlight SignifyLineChange ctermfg=none ctermbg=227 guibg=#0e3535
highlight SignifyLineChangeDelete ctermfg=none ctermbg=203 guibg=#433007

nnoremap <Leader>d :call sy#highlight#line_toggle()<CR>
let g:signify_line_highlight = 0

" syntastic / ALE

" " highlight SyntasticError ctermbg=91 guibg=#d05516
" highlight ALEError ctermbg=91 guibg=#d05516
" " highlight SyntasticErrorSign guibg=#DC571C guifg=#FFFFFF
" highlight ALEErrorSign guibg=#DC571C guifg=#FFFFFF
" " highlight SyntasticWarning ctermbg=24 guibg=#686832
" highlight ALEWarning ctermbg=24 guibg=#686832
" " highlight SyntasticWarningSign guibg=#f1af51 guifg=#303030
" highlight ALEWarningSign guibg=#f1af51 guifg=#303030
" " highlight SyntasticErrorLine guibg=#480000
" highlight ALEErrorLine guibg=#480000
" " highlight SyntasticWarningLine guibg=#383800
" highlight ALEWarningLine guibg=#383800

" " TODO detect if gcc is old, adjust to c++11 instead of 14
" " But, I'm not doing that because forking gcc sounds like a horrible idea on 
" " vim startup. So, I'm blanket-conf'ing gcc for c++11 for now

hi clear SignColumn

" let g:ale_sign_warning = '->'
" let g:ale_sign_error = '>>'

" HiCursorWords
let g:HiCursorWords_delay = 50

" map to move locationlist (syntastic errors)
" (now taken care of by unimpaired)
" noremap ]l :lnext<CR>
" noremap [l :lprev<CR>

" let g:syntastic_javascript_checkers = ['eslint']

" let g:syntastic_always_populate_loc_list = 1

" let g:syntastic_ignore_files = [
" 			\ '\vpublic/js/app/utils/global.js$'
" 			\ ]

" for debugging syntax
" (http://vim.wikia.com/wiki/Identify_the_syntax_highlighting_group_used_at_the_cursor)
command! SyntaxDetect :echom "hi<" . synIDattr(synID(line("."),col("."),1),"name") . '> trans<' . synIDattr(synID(line("."),col("."),0),"name") . "> lo<" . synIDattr(synIDtrans(synID(line("."),col("."),1)),"name") . ">"

" set updatetime=500
" Unsure if updatetime gets overwritten by plugins. There are many plugins
" I use which mess with updatetime (hicursorwords being one of them)

" noremap! <F5> <C-O>:YcmForceCompileAndDiagnostics<CR>
" noremap <F5> :YcmForceCompileAndDiagnostics<CR>

" " Binding F5 to the fswitch (switching between c/cpp and h/hxx/hpp) -- I like
" " to use this and ctrlp MRU rather than having to type in stuff
" nmap <silent> <F5> :FSSplitBelow<CR>

" " additional fswitch definitions are implemented not through any friendly 
" " variables but through defining variables via file autocommands -- i think it's
" " admissible as its fairly straightforward reasoning, at least
" au BufEnter *.cu let b:fswitchdst = 'h'
" au BufEnter *.vsh let b:fswitchdst = 'fsh'
" au BufEnter *.fsh let b:fswitchdst = 'vsh'
" au BufEnter *.mm  let b:fswitchdst = 'h' | let b:fswitchlocs = 'reg:/src/include/,reg:|src|include/**|,ifrel:|/src/|../include|'

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
	" we disable cursorline in normal mode because there used to be 
	" a performance problem in vim for general scrolling around. Leaving it 
	" because i don't need it so bad.
	set nocursorline
	" hi CursorLine ctermbg=NONE cterm=NONE
	hi CursorLineNr ctermfg=11 ctermbg=NONE
	" This next line is actually really cool, but I am taking it out for
	" consistency with other editors whose vim-modes do not allow me to do this
	" call cursor([getpos('.')[1], getpos('.')[2]+1]) " move cursor forward
	call SetPaste()
endfunction

hi CursorLine ctermbg=NONE

au! InsertEnter * call InsertEnterActions(v:insertmode)
au! InsertLeave * call InsertLeaveActions()

au! FileType tagbar setlocal cursorline

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
"
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
" vnoremap <Left> 2zhh
" vnoremap <Right> 2zll
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
" set clipboard=unnamed

" Using these is sort of questionable as it does pollute undo history :( TODO: 
" maybe not now with c-u g?
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
" noremap <S-J> 5gj
" noremap <S-K> 5gk
noremap <S-H> 7h
noremap <S-L> 7l

" override K bind from vim-go using an autocommand because that is the cleanest 
" way to do this without forking vim-go. BufWritePost is needed because that 
" will force it back since writing tends to have the plugin reapply the bind.

" similarly and conveniently this 'fixes' the behavior for NERDTree so that 
" navigation works as my brain expects it to, i.e. same as in a buffer. Except 
" that with BufEnter this doesnt work on the first open for NERDTree.

" this happens to also defer the bind for all buffer opens, but it shouldnt 
" matter, really.
au BufEnter,BufWritePost * noremap <buffer> <silent> K 5gk
au BufEnter * noremap <buffer> <silent> J 5gj

" and now to provide a new binding for GoDoc using au instead of after/ because 
" of maintainability
" au FileType go nnoremap <buffer> <silent> <C-d> :GoDoc<CR>

" this is kept here as an example for how to implement a (potentially buggy) 
" autocommand that works on an event which is also to be dependent on filetype.

" autocmd BufWritePost * if &filetype == "go"
"     \ | echom "binding"
"     \ | nnoremap <buffer> <silent> <C-d> :GoDoc<CR>
"     \ | endif

set wrap
set textwidth=99

set formatoptions=caq1njwbl
" " override $VIMRUNTIME/ftplugin/*.vim messing up my formatoptions by forcing the 
" " options that i really care about at this point
" au FileType * setlocal fo-=r
" au FileType * setlocal fo+=b

" au FileType txt setlocal fo-=c

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
	if newnr == nr && !has("gui_macvim")
		let cmd = 'tmux select-pane -' . tr(a:dir, 'hjkl', 'LDUR')
		call system(cmd)
		" echo 'Executed ' . cmd
	endif
endfun

noremap <silent> <C-H> :<c-u>call TmuxWindow('h')<CR>
noremap <silent> <C-J> :<c-u>call TmuxWindow('j')<CR>
noremap <silent> <C-K> :<c-u>call TmuxWindow('k')<CR>
noremap <silent> <C-L> :<c-u>call TmuxWindow('l')<CR>

noremap! <silent> <C-H> <ESC>:call TmuxWindow('h')<CR>
noremap! <silent> <C-J> <ESC>:call TmuxWindow('j')<CR>
noremap! <silent> <C-K> <ESC>:call TmuxWindow('k')<CR>
noremap! <silent> <C-L> <ESC>:call TmuxWindow('l')<CR>

" bind the F10 switcher key to also exit insert mode if sent to Vim, this
" should help its behavior become consistent outside of tmux as it won't then
" be doing any filtering on F10 (which should cycle panes)
"
" I actually think this binding is beautiful because it happens to be
" generally a good idea to exit insert mode anyway once switching away from
" Vim.
noremap <F10> <ESC>
snoremap <F10> <ESC>
noremap! <F10> <ESC>
cnoremap <F10> <c-c>

" this checks tmux to figure out if it should swap panes or trigger Tab
" instead
function! EfTen(direction)
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
" <c-u> erases any numeric prefix to prevent numbers from accidentally DoS'ing tmux with vim
nnoremap <silent> <F10> :<c-u>call EfTen('+')<CR>

" I am not really sure what happened here but, tmux 2 seems to just have its 
" own idea about how to send Shift F10 if TERM is screen-*. (before this used 
" to set <S-F10> to \x1b[34~ but that seems to have no effect when I commented 
" it out! Even under TERM=xterm-*!)
set <S-F10>=[21;2~
noremap <S-F10> <ESC>
noremap! <S-F10> <ESC>
nnoremap <silent> <S-F10> :call EfTen('-')<CR>

let g:colorizer_auto_filetype='css,html'
autocmd BufEnter,BufNew *.colorlog ColorHighlight

noremap <F12> :ColorSwapFgBg<CR>
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
" set <S-F1>=[1;2P
" noremap! <S-F1> <ESC>:tabclose<CR>
" noremap <S-F1> :tabclose<CR>
" noremap! <F1> <ESC>:tabnew<CR>
" noremap <F1> :tabnew<CR>
" inoremap <F1> <ESC>:tabnew<CR>
noremap! <silent> <F2> <ESC>:call SwitchTabPrev()<CR>
noremap <silent> <F2> :<c-u>call SwitchTabPrev()<CR>
" inoremap <F2> <ESC>:tabprev<CR>
noremap! <silent> <F3> <ESC>:call SwitchTabNext()<CR>
noremap <silent> <F3> :<c-u>call SwitchTabNext()<CR>
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
if !has('nvim') " regular vim doesn't understand c-a-s for whatever reason
	set <C-A-S>=
endif

cnoremap <silent> <C-A-S> <C-C>:w !sudo tee > /dev/null %<CR>:e!<CR>
noremap <silent> <C-A-S> <ESC>:w !sudo tee > /dev/null %<CR>:e!<CR>
inoremap <silent> <C-A-S> <ESC>:w !sudo tee > /dev/null %<CR>:e!<CR>

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
function! SearchForWord()
	let l:word = expand('<cword>')
	if g:highlighting == 1 && @/ =~ '^\\<'.l:word.'\\>$'
		let g:highlighting = 0
		return ":silent nohlsearch\<CR>"
	endif
	let @/ = '\<'.l:word.'\>'
	" add to history -- can clutter, but def helps
	" NOTE! the item is added without /v so backspace first, then hunt
	call histadd('search', '\v<' . l:word . '>')
	let g:highlighting = 1
	" save this to file system (!) for fast workflow -- disabled now because its 
	" visually distracting and i need an async way to deal with this...
	" silent exe "!echo " . l:word . " > $HOME/.vim/.search"
	" redraw!
	if has('python3')
		python3 << EOF
from os.path import expanduser
f = open(expanduser('~') + '/.vim/.search', 'w')
# print f
w = vim.eval("l:word")
f.write(w)
f.close()
EOF
	endif

	" this shit flickers and sucks
	" silent exec "!curl -s localhost:4000/ > /dev/null &"
	" redraw!
	return ":silent set hlsearch\<CR>"
endfunction
nnoremap <silent> <expr> <CR> &buftype == "" ? SearchForWord() : "<cr>"

function! ChompCtrlM(string)
    return substitute(a:string, '$', '', '')
endfunction

" proof of concept that i can chain something to occur after an eval-string 
" providing function. dont think i achieved this before
function! SearchWithHighlighting()
	let string = ChompCtrlM(SearchForWord())
	" echom 'A: '.string
	let string .= " | echom 'test'\<CR>"
	echom 'B: '.string
	return string
endfun

" Search for selected text.
" http://vim.wikia.com/wiki/VimTip171
let s:save_cpo = &cpo | set cpo&vim
if !exists('g:VeryLiteral')
  let g:VeryLiteral = 0
endif
function! s:VSetSearch(cmd)
  let old_reg = getreg('"')
  let old_regtype = getregtype('"')
  normal! gvy
  if has('python3')
    python3 << EOF
from os.path import expanduser
f = open(expanduser('~') + '/.vim/.search', 'w')
# print f
w = vim.eval("@@")
f.write(w)
f.close()
EOF
  endif
  if @@ =~? '^[0-9a-z,_]*$' || @@ =~? '^[0-9a-z ,_]*$' && g:VeryLiteral
    let @/ = @@
  else
    let pat = escape(@@, a:cmd.'\')
    if g:VeryLiteral
      let pat = substitute(pat, '\n', '\\n', 'g')
    else
      let pat = substitute(pat, '^\_s\+', '\\s\\+', '')
      let pat = substitute(pat, '\_s\+$', '\\s\\*', '')
      let pat = substitute(pat, '\_s\+', '\\_s\\+', 'g')
    endif
    let @/ = '\V'.pat
  endif
  normal! gV
  call setreg('"', old_reg, old_regtype)
endfunction
vnoremap <silent> <CR> :<C-U>call <SID>VSetSearch('/')<CR>/<C-R>/<CR>
vnoremap <silent> # :<C-U>call <SID>VSetSearch('?')<CR>?<C-R>/<CR>
vmap <kMultiply> *
nmap <silent> <Plug>VLToggle :let g:VeryLiteral = !g:VeryLiteral
  \\| echo "VeryLiteral " . (g:VeryLiteral ? "On" : "Off")<CR>
if !hasmapto("<Plug>VLToggle")
  nmap <unique> <Leader>vl <Plug>VLToggle
endif
let &cpo = s:save_cpo | unlet s:save_cpo

function! Del_word_delims()
	let reg = getreg('/')
	" After *                i^r/ will give me pattern instead of \<pattern\>
	let res = substitute(reg, '^\\<\(.*\)\\>$', '\1', '' )
	if res != reg
		return res
	endif
	" After * on a selection i^r/ will give me pattern instead of \Vpattern
	let res = substitute(reg, '^\\V'          , ''  , '' )
	let res = substitute(res, '\\\\'          , '\\', 'g')
	let res = substitute(res, '\\n'           , '\n', 'g')
	return res
endfunction

inoremap <silent> <C-R>/ <C-R>=Del_word_delims()<CR>
cnoremap          <C-R>/ <C-R>=Del_word_delims()<CR>

" map Q to :q
nnoremap Q :q<CR>

" nnoremap <F5> :TlistToggle<CR>
" inoremap <F5> <C-O>:TlistToggle<CR>

nnoremap <F6> :History<CR>
inoremap <F6> <ESC>:History<CR>
nnoremap <c-p> :Files<CR>

" opens the current buffer in nerdtree
nnoremap <Leader>f :call SmartNERDTree()<CR>

function! SmartNERDTree()
	if @% == ""
		NERDTreeToggle
	else
		NERDTreeFind
	endif
endfun


" I definitely do not use this -- F7 is now YCM sign toggle.
" nnoremap <F7> :NERDTreeToggle<CR>

" configuring CtrlP
" let g:ctrlp_max_files = 200000
" let g:ctrlp_clear_cache_on_exit = 0
" let g:ctrlp_root_markers = ['.ctrlp_root'] " insert this sentinel file anywhere that you'd like ctrlp to index from

" " If cwd is deep then it goes up to repo root. Else stays there!
" let g:ctrlp_working_path_mode = 'w'

noremap k gk
noremap j gj
noremap gk k
noremap gj j

" for wrapping based on words
set linebreak
let &showbreak="→ "
if exists('&breakindent')
	set breakindent
endif

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
" Attempting to focus window to the left in insert mode just wont work. I think 
" this is for placating putty's binding. But i am not certain.
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
" let g:ycm_add_preview_to_completeopt = 1
" let g:ycm_confirm_extra_conf = 0
" let g:ycm_complete_in_comments = 1
" let g:ycm_seed_identifiers_with_syntax = 1
" let g:ycm_collect_identifiers_from_comments_and_strings = 1
" let g:ycm_collect_identifiers_from_tags_files = 1
" let g:ycm_server_log_level = 'info'
" let g:ycm_max_diagnostics_to_display = 100
" let g:ycm_key_list_select_completion = ['<TAB>', '<Down>']
" let g:ycm_key_list_previous_completion = ['<S-TAB>', '<Up>']

" semantic on OSX works again! hooray -- now this has to be bound to a key 
" because of limitations. see issue 887 at YCM's github
" let g:ycm_enable_diagnostic_signs = 1
" let g:ycm_enable_diagnostic_highlighting = 1
" let g:ycm_server_keep_logfiles = 1

" sadly, this doesn't work on the fly for some reason. It's supposed to!
" nnoremap <F7> :call YCMSignToggle()<CR>
" function! YCMSignToggle()
" 	if g:ycm_enable_diagnostic_signs
" 		let g:ycm_enable_diagnostic_signs = 0
" 	else
" 		let g:ycm_enable_diagnostic_signs = 1
" 	endif
" endfunc

nnoremap <F7> :Buffers<CR>
" nnoremap <S-F7> :YcmCompleter GoToDefinition<CR>

" This insert mapping is for pasting; it appears that YCM only takes over the
" <C-P> when it has the complete box open (this may be a Vim
" limitation/builtin)
inoremap <C-P> <C-O>P

" set highlight for search to be less blinding
" highlight Search ctermbg=33 ctermfg=16
" highlight Search ctermbg=none ctermfg=none cterm=reverse
highlight Search ctermbg=124 ctermfg=NONE guibg=#a9291a guifg=NONE
highlight Error term=reverse ctermfg=8 ctermbg=9

" set t_ZH=[3m
" set t_ZR=[23m

" only on an italic term do we set comment to use italic cterm highlight
if &term == 'xterm-256color-italic' || &term == 'nvim' || &term == 'tmux-256color-italic'
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
let g:gundo_preview_bottom = 1

set undolevels=10000
set undofile

" set iskeyword=@,$,48-57,_,192-255

" Ctrl+F for find -- tip on \v from
" http://stevelosh.com/blog/2010/09/coming-home-to-vim/
" May take some getting used to, but is generally saving on use of backslashes
nnoremap <C-F> /\v
inoremap <C-F> <ESC>/\v
vnoremap <C-F> /\v
nnoremap / /\v
vnoremap / /\v

" pull up last search, usually for in case you typoed it or something
nnoremap <F1> /<c-u><up>

" Finding % to be highly powerful so I map to high traffic area single key
" This mostly alleviates the want for matching highlights for surrounding
" stuff because moving back and forth between the endpoints can be quite
" helpful anyway.
" see the after/plugin/matchit.vim for the bind since i have to bind it there

" flipping ' and ` for convenience
vnoremap ' `
nnoremap ' `
onoremap ' `

" this is intended for:
" swap and give myself the ability to still invoke the friggin jump 
" functionality of vim (map to ', make ' do `, because its more useful.)
" BUT, what happens is that matchit loads and overrides this. I need to not 
" really touch the matchit script since it'd be overkill, and.. well, the only 
" way then is to use a map

runtime macros/matchit.vim

" These maps are calling the stuff that matchit.vim sets.
" overloads %, so we try not to mess that up.
nmap ` %
vmap ` %
omap ` %

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
		" if only one tab but multiple windows still do cycle the windows at 
		" end
	elseif (tabpagenr('$') == 1)
		wincmd w
		" Rest of logic is just as sound (and simple) as it ever was
	elseif (winnr() == winnr('$'))
		tabnext
		" 1wincmd w "first window
		" not doing this anymore because it works more conveniently to retain 
		" tab's existing focus state.
	else
		wincmd w "next window
	endif

	" also provide a user friendly treatment: When this command lands us into 
	" a non-regular-file window, we will re-evaluate and push to next tab or 
	" window or buffer as appropriate. With the new behavior of leaving cursor 
	" where it lies, it slightly complicates this, but not by much.
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
		else
			" step forward while bufhidden, if end, scan back and then tabnext.
			while (winnr() != startWindowIndex && (&bufhidden == 'wipe' || &bufhidden == 'hide'))
				if (winnr() == winnr('$'))
					while (winnr() != startWindowIndex && (&bufhidden == 'wipe' || &bufhidden == 'hide'))
						wincmd W
					endwhile
					tabnext
				endif
				wincmd w
			endwhile
		endif
	endif
endfunc

function! PrevWindowOrTabOrBuffer()
	let startWindowIndex = winnr()
	if (winnr('$') == 1 && tabpagenr('$') == 1)
		" only situation where we cycle to next buffer
		bprev
	elseif (tabpagenr('$') == 1)
		wincmd W
	elseif (winnr() == 1)
		tabprev
		" exec winnr('$').'wincmd w'
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
		else 
			while (winnr() != startWindowIndex && (&bufhidden == 'wipe' || &bufhidden == 'hide'))
				if (winnr() == 1)
					while (winnr() != startWindowIndex && (&bufhidden == 'wipe' || &bufhidden == 'hide'))
						wincmd w
					endwhile
					tabprev
				endif
				wincmd W
			endwhile
		endif
	endif
endfunc

" I actually like the mash tab to cycle windows behavior so let's keep it simple
"nnoremap <Tab> :wincmd w<CR>
"nnoremap <S-Tab> :wincmd W<CR>

" Nevermind, I actually really need this on a small screen...
nnoremap <silent> <Tab> :call NextWindowOrTabOrBuffer()<CR>
nnoremap <silent> <S-Tab> :call PrevWindowOrTabOrBuffer()<CR>

" This makes it restore the last position
autocmd! BufReadPost * silent! normal! g`"zv

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


" This function makes it so that the setting of number, list, showbreak are
" cued on the current state of paste. Previously this was done with toggles
" all around so the desynchronization was real whenever the pastetoggle was
" used an odd number of times from insert mode. Now, this state is 
" self-repairing, and also I can run SetPaste from an exit-insert 
" autocommand, and there will be no healing necessary. Aside from signs.
function! SetPaste()
	" echo "Paste: ".&paste
	if (&paste)
		set nonumber
		set nolist
		let &showbreak=''
		sign unplace *
		" Not going to use elaborate way to track signs in order to toggle 
		" sign column. can just :e to bring them back...
	else
		set number
		set list
		let &showbreak="→ "
	endif
endf

if !has('nvim')
	set <F34>=comma]
	
	set <m-s>=s
	set <m-p>=p
	set <m-w>=w
endif

noremap <m-s> :update<CR>
vnoremap <m-s> <ESC>:update<CR>
cnoremap <m-s> <C-C>:update<CR>
inoremap <m-s> <ESC>:update<CR>
nnoremap <silent> <m-p> :set invpaste<CR>:call SetPaste()<CR>
set pastetoggle=<m-p>

set showmode

nnoremap <Leader>w :set wrap!<CR>

" A slightly perilous set of binds:
" the terminal in this case sends an escape, followed by a Ctrl char,
" the latter of which may be intercepted by tmux and passed through
" a shell script! (tmux is smart, though, and does the term timeout on
" the escape, it will be letting it pass through)
if !has('nvim')
	" set <F30>=h
	" set <F29>=j
	set <m-H>=H
	set <m-J>=J
	set <m-K>=K
	set <m-L>=L
	" set <F28>=k
	" set <F27>=l

	" These binds are for quick rearrangement of windows, useful function
	" that sadly I'll need to do hacking to get the same on tmux
endif

nnoremap <m-H> :wincmd H<CR>
nnoremap <m-J> :wincmd J<CR>
nnoremap <m-K> :wincmd K<CR>
nnoremap <m-L> :wincmd L<CR>

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
	nnoremap <M-R> :call MyForceVertSplit()<CR>
	nnoremap <M-F> :call MyForceHorizSplit()<CR>
else
	set <F18>=R
	set <F17>=F

	nnoremap <F18> :call MyForceVertSplit()<CR>
	nnoremap <F17> :call MyForceHorizSplit()<CR>
endif

" This is for yankstack
" have it not bind anything
let g:yankstack_map_keys = 0

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

if !empty(glob("~/.vim/plugged/vim-yankstack/autoload/yankstack.vim"))
	call yankstack#setup()
else
	echom "Yankstack not installed! Might want to plug install."
endif

nmap Y y$

" " this attempts to perform even more extra processing with the yank operation, 
" " to place it into a config global fetchable state just like my implicit search
" function! YankOverloadVisual(key)
" 	" So the problem with this here is that the @" only has the *last* 
" 	" selection's contents, the current selection is not available to us here. 
" 	" Unfortunately there is no way to get a function to run AFTER dispatching 
" 	" a potentially recursive map.
" 	call writefile(split(getreg("\""), "\n", 1), glob('~/.vim/.yank'), 'b')
" 	return a:key
" endfun

" vmap <expr> y YankOverloadVisual('y')

" " set the numpad key codes -- Mark helpfully already implements the stuff that
" " calls <k0>, etc
" if !has('nvim')
" 	set <k0>=Op
" 	set <k1>=Oq
" 	set <k2>=Or
" 	set <k3>=Os
" 	set <k4>=Ot
" 	set <k5>=Ou
" 	set <k6>=Ov
" 	set <k7>=Ow
" 	set <k8>=Ox
" 	set <k9>=Oy
" endif

set <k0>=0
set <k1>=1
set <k2>=2
set <k3>=3
set <k4>=4
set <k5>=5
set <k6>=6
set <k7>=7
set <k8>=8
set <k9>=9

" make recordings easier to fire off, binding alt+comma to @q (use qq to record 
" to q register)
" TBH since i wanted to bring comma back and stick with defaults, @ isnt too 
" hard to reach anyway, I abandoned this map for a while
" Hmmm, I've been actually typing [n]@@ a lot lately to run my macros, i dunno.
if has('nvim')
	nnoremap <m-<> :<C-u>call EnhancedComma('')<CR>
	nnoremap <m-,> :<C-u>call EnhancedComma(v:count1)<CR>
else
	nnoremap <F14> :<C-u>call EnhancedComma('')<CR>
	nnoremap <F19> :<C-u>call EnhancedComma(v:count1)<CR>
endif

function! EnhancedComma(count)
	" when no count, run it as many times as the match remains. That's done 
	" with fancy redir technique
	let poscursor=getpos('.')
	let hlsearchCurrent = v:hlsearch
	let c = a:count
	redir => searchcount
	silent! %s///n " this is not gn because i use g reversal (its called gdefault!)
	redir END
	let cc = split(searchcount, '\D\+')
	let ct = cc[0]
	if searchcount =~ 'Error'
		" this is the way to catch the zero matches case
		let ct = 0
	endif
	call setpos('.', poscursor)
	" echom 'searchcount =~ '.(searchcount =~ 'Error')
	if (c == '' && hlsearchCurrent)
		let c = ct
		echom 'running comma '.c.' times (all matches)...'
	elseif c == ''
		echom 'put search on to run comma on all matches'
		return
	endif
	" echom ct.' ## '.c
	if ct < c
		echom 'found fewer matches than requested ('.c.'), running only '.ct.' times'
		let c = ct
	endif
	while c > 0
		" echom 'count is '.c
		if (hlsearchCurrent)
			" echom 'seeking next mat'
			silent! normal n
			normal! @q
		else
			" echom 'advancing line because no hlsearch'
			normal! @qj
		endif
		let c -= 1
	endwhile
endfunction

" more ctrlp settings
" let g:ctrlp_switch_buffer = 'Et' " Jump to tab AND buffer if already open
" let g:ctrlp_open_new_file = 'r' " Open new files in a new tab
" let g:ctrlp_open_multiple_files = 'vj'
" let g:ctrlp_show_hidden = 1 " Index hidden files
" let g:ctrlp_follow_symlinks = 1

" " Edit this as necessary as work patterns change...
" " Do note that you have to manually rescan with F5 to see this applied!
" let g:ctrlp_custom_ignore = { 
" 			\ 'dir':  '\v[\/]node_modules|(public\/js\/app\/views)|(\.(git|hg|svn))',
" 			\ 'file': '\v\.(exe|so|dll|DS_Store|un\~|min\.js|es5\.js)$',
" 			\ }

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

" bind the ctrl arrow left and right in insert mode to WORD hop also
inoremap <C-Left> <ESC>bi
inoremap <C-Right> <ESC>lwi

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

" Set up c-style surround using * key. Useful in C/C++/JS
let g:surround_{char2nr("*")} = "/* \r */"
vmap * S*

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

" scrollbinding to view a file in columns -- taking it out because it has 
" quirks and isnt perfect

" noremap <silent> <Leader>c :<C-u>let @z=&so<CR>:set so=0 noscb<CR>:bo 
" vs<CR>Ljzt:setl scb<CR><C-w>p:setl scb<CR>:let &so=@z<CR>

" auto enable rainbow on c/cpp files
" Nope! too slow on preprocessor output
" au FileType c,cpp,objc,objcpp call rainbow#load()

" syntax sync minlines=256 " this was an attempt to speed up syntax on raspi.
" May not be necessary now that i took out line highlight

" let g:airline_skip_empty_sections = 1
" let g:airline#extensions#tabline#enabled = 1
" let g:airline#extensions#tagbar#enabled = 0 " disruptive and also wont work anyway, since i've lazied tagbar
" let g:airline#extensions#tabline#left_sep = ' '
" let g:airline#extensions#tabline#left_alt_sep = ' '
" if !exists('g:airline_symbols')
"   let g:airline_symbols = {}
" endif
" let g:airline_left_sep = ''
" let g:airline_left_alt_sep = ''
" let g:airline_right_sep = ''
" let g:airline_right_alt_sep = ''
" let g:airline_symbols.branch = ''
" let g:airline_symbols.readonly = ''
" let g:airline_symbols.linenr = ''
" let g:airline_theme='bubblegumslu'

" let g:airline#extensions#hunks#non_zero_only = 1
" let g:airline#extensions#whitespace#mixed_indent_algo = 1
" let g:airline#extensions#hunks#hunk_symbols = ['+', '~', '-']
" let g:airline#extensions#tagbar#enabled = 1 " not sure if does anything
" let g:airline#extensions#tagbar#flags = 'f' " not sure if does anything

" " Honestly I spend way too much time cleaning up trailing spaces which has as 
" " yet never had any solid reason. There are legitimate uses of trailing spaces 
" " in e.g. markdown.
" let g:airline#extensions#whitespace#checks = [ 'indent' ]

" let g:airline#extensions#tabline#formatter = 'unique_tail_improved'
" let g:airline#extensions#branch#displayed_head_limit = 15
" let g:airline#extensions#default#section_truncate_width = {
"   \ 'b': 120,
"   \ 'x': 45,
"   \ 'y': 115,
"   \ 'z': 120,
"   \ 'warning': 30,
"   \ }

" Highlight words to avoid in tech writing
" =======================================
"
"   obviously, basically, simply, of course, clearly,
"   just, everyone knows, However, so, easy

"   http://css-tricks.com/words-avoid-educational-writing/

highlight TechWordsToAvoid ctermbg=52 guibg=#602020
" 52 is the darkest red and it is a handy non-painful color

" also highlight swears for +3 professionalism
function! MatchTechWordsToAvoid()
	match TechWordsToAvoid /\c\<\(shit\|fuck\|crap\|ass\|obviously\|basically\|simply\|of\scourse\|clearly\|everyone\sknows\)\>/
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

" map back and forward (won't work without proper maps which term emulators 
" dont provide)
nnoremap <X1Mouse> u
nnoremap <X2Mouse> <C-R>

" Had this SO question answered a while ago but didnt get chance to insert it
" till now.
function! SmartInsertStartOfLine()
	if synIDattr(synID(line("."), col("."), 1), "name") =~ "Comment"
		normal! ^w
		startinsert
	else
		" why do i need to use feedkeys? who knows?
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
nnoremap <Leader>A :call SmartInsertEndOfLine()<CR>

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

set switchbuf=usetab,split

" This clears the bgcolor set by the colorscheme, and inherits term background 
" color provided helpfully by tmux. Quite nice and useful for bgcolor visual 
" focus and it's free and performant.
highlight Normal ctermbg=NONE

" now that focuslost works with iterm and tmux maybe this is just generally 
" improved behavior. Do have to be careful, but it speeds shit up when rapidly 
" working
" working
" Update not too many weeks later -- This actually causes phantom unintended 
" undoes being committed -- Also complicit in that particular brand of 
" treachery is Airline's tab bar. I am bringing back the old utilitarian tab 
" bar of mine again...

" au FocusLost * silent! wa

" just also exit insert mode when swapping out via click or whatever
" au FocusLost * stopinsert
" FocusLost seems to not work at all

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

" set spell
nmap <leader>s :set spell!<CR>

nmap <leader>S :saveas %%

highlight SpellBad ctermbg=NONE ctermfg=NONE cterm=underline guifg=NONE guibg=NONE gui=underline term=NONE
highlight SpellCap ctermbg=NONE ctermfg=NONE cterm=underline,bold guifg=NONE guibg=NONE gui=underline term=NONE
highlight SpellRare ctermbg=NONE ctermfg=NONE cterm=underline guifg=NONE guibg=NONE gui=underline term=NONE
highlight SpellLocal ctermbg=NONE ctermfg=NONE cterm=underline guifg=NONE guibg=NONE gui=underline term=NONE
" There exist some other spelling related highlight styles but i'll just deal 
" with them when i see them show up as I see fit. the capitalization one is 
" pretty acceptable for now also.

" Macro meta commands. For editing macros to refine them. This is just brimming 
" with power. Found here: 
" http://dailyvim.blogspot.com/2007/11/macro-registers.html
" Not too much but just a wrinkle, not really able (easily) to start recording 
" into the p or d registers.
" Now, turns out this shit has some issues, esp with YCM. I am disabling it now
" entirely because it's really easier to just recreate the fucking recording 
" manually after all... I think I just need to use a scratch buffer window to 
" do this (which is good because then i can still see the other code i was in) 
" and have YCM switched off in there, if possible. Anyhow it's quite some time 
" away from being feasible for me to invest time into, as i still use macros 
" fairly rarely. Also this binding is really aggravating because it makes 
" finishing a macro recording have a delay in it, you wouldnt think so but it 
" is aggravating.

" nnoremap qp Go<ESC>"qp
" nnoremap qd G0"qd$

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

" note that outline.pl was recently rewritten such that special chars are the 
" only ones that trigger empty boxes. So you may draw boxes like this and the 
" alphanum content will remain unchanged, hopefully this makes it easier to 
" write things quickly.

" ############&&&&&^^^
" ##########&&&&&&&
" ## text#&&&&&&
" ##     ###&&&&&&&
" ##########&&&&^&&
" ############&&&&&^^^

" If you test this you will find quite some breakage... there is a whole 
" edge-case situation going on here thats a bit unfortunate and I don't think 
" I can realistically make it fully featured. It's quite safer to use the below 
" lines and pluses at any rate.

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

autocmd BufEnter * highlight OverLength ctermbg=52 guibg=#602020

fu! LongLineHighlightToggle()
	highlight OverLength ctermbg=52 guibg=#602020
	if exists('w:long_line_match')
		match OverLength //
		unlet w:long_line_match
		" set colorcolumn=""
	else 
		match OverLength /\%>80v.\+/
		let w:long_line_match = 1
		" set colorcolumn=80
	endif
endfunction
map <Leader>l :call LongLineHighlightToggle()<CR>

set colorcolumn=100
highlight ColorColumn ctermbg=235 term=NONE guibg=#252525

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
" handles both situations elegantly. Now if i could make it so that j doesnt 
" often place the cursor in a not-so-great location, but usually whatever being
" used for the dot make this workable.
if has('nvim')
	" shit neovim has issues with binding keys...
	nnoremap <m->> :<C-u>call EnhancedDot('')<CR>
	nnoremap <m-.> :<C-u>call EnhancedDot(v:count1)<CR>
else
	nnoremap <F16> :<C-u>call EnhancedDot('')<CR>
	nnoremap <F20> :<C-u>call EnhancedDot(v:count1)<CR>
endif

" this will intelligently abort and undo at such time that it realizes 'n' did 
" not move the cursor.
function! EnhancedDot(count)
	" when no count, run it as many times as the match remains. That's done 
	" with fancy redir technique

	" need to store the position in order to restore it because the search 
	" count thing moves the cursor!
	let poscursor=getpos('.')
	let hlsearchCurrent = v:hlsearch
	let c = a:count
	redir => searchcount
	silent! %s///n " this is not gn because i use g reversal (its called gdefault!)
	redir END
	let cc = split(searchcount, '\D\+')
	let ct = cc[0]
	if searchcount =~ 'Error'
		" this is the way to catch the zero matches case
		let ct = 0
	endif
	call setpos('.', poscursor)
	" echom 'searchcount =~ '.(searchcount =~ 'Error')
	if (c == '' && hlsearchCurrent)
		let c = ct
		echom 'running dot '.c.' times (all matches)...'
	elseif c == ''
		echom 'put search on to run dot on all matches'
		return
	endif
	" echom ct.' ## '.c
	if ct < c
		echom 'found fewer matches than requested ('.c.'), running only '.ct.' times'
		let c = ct
	endif
	while c > 0
		" echom 'count is '.c
		if (hlsearchCurrent)
			" echom 'seeking next mat'
			silent! normal n
			normal .
		else
			" echom 'advancing line because no hlsearch'
			" need the normal! for j because j has been mapped to gj
			normal! .j
		endif
		let c -= 1
	endwhile
endfunction

" " keymap definitions for textmanip
" xmap <C-D> <Plug>(textmanip-duplicate-down)
" nmap <C-D> <Plug>(textmanip-duplicate-down)
" " Not sure if i need to consume ctrl+u for this. May not ever use it...
" xmap <C-U> <Plug>(textmanip-duplicate-up)
" nmap <C-U> <Plug>(textmanip-duplicate-up)

xmap <Down>  <Plug>(textmanip-move-down)
xmap <Up>    <Plug>(textmanip-move-up)
xmap <Left>  <Plug>(textmanip-move-left)
xmap <Right> <Plug>(textmanip-move-right)

" toggle insert/replace for textmanip with Ctrl+E
nmap <C-E>   <Plug>(textmanip-toggle-mode)
xmap <C-E>   <Plug>(textmanip-toggle-mode)

" save states for php. This affects too many variables for comfort, but I do 
" want it to work so I can maintain folding state. It's a sad compromise for 
" now. (so php is the only language having insane files i need folding to work 
" in -- whenever i find persistent buffer settings due to this mkview I can 
" manually erase these files (after exiting Vim, as exiting vim causes it to 
" write the view))

" au BufWinLeave *.php mkview
" au BufWinEnter *.php silent loadview

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

" add easy-align delims that curiously were not included out of the box.
let g:easy_align_delimiters = {
  \ ';': { 'pattern': ';', 'left_margin': 0, 'stick_to_left': 1 },
  \ '+': { 'pattern': '[+-]'},
  \ '*': { 'pattern': '[*/]'},
  \ '/': {
  \     'pattern':         '//\+\|/\*\|\*/',
  \     'delimiter_align': 'l',
  \     'ignore_groups':   ['!Comment'] }
  \ }

" for the octol/vim-cpp-enhanced-highlight plugin
" let g:cpp_experimental_template_highlight=1
" let g:cpp_class_scope_highlight=1

" " neat bracketed paste handling (not sure if i need special tmux shit but lets 
" " try this minimal version first)

" let &t_SI .= "\<Esc>[?2004h"
" let &t_EI .= "\<Esc>[?2004l"

" the above t_S/EI stuff was probably for vim only and neovim has its own 
" custom shit for paste. Basically i only use vim by accident these days 
" (neovim is much easier to build also!) and pretty much dont care all that 
" much if paste doesnt work too well in vanilla vim

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
	inoremap <c-b> <ESC>lve
else
	set <F15>=b
	inoremap <F15> <ESC>lve
	inoremap <c-b> <ESC>lve
endif

" bind Alt+V to do the same as alt+B but do less work whereby visual mode is 
" temporarily engaged (and we return to insert mode afterwards), and also the 
" movement to end of word is not auto performed
" if has('nvim')
" 	inoremap <m-v> <c-o>v
" else
" 	set <F16>=v
" 	inoremap <F16> <c-o>v
" endif
" Commented that thing out because I did not once use this capability so I am 
" allocating F16 for vim for something more useful for now

" Override the default which uses m-p which conflicts with my paste mode 
" binding
let g:AutoPairsShortcutToggle = '<M-z>'
let g:AutoPairsShortcutBackInsert = '<M-x>'
let g:AutoPairsShortcutJump = '<M-a>'
let g:AutoPairsCenterLine = 0
let g:AutoPairsOnlyWhitespace = 1

" make html files pair up brackets
au Filetype html let b:AutoPairs = {'`': '`', '"': '"', '{': '}', '''': '''', '(': ')', '[': ']', '<':'>'}

let g:AutoPairsMapCR=0
" imap <silent><CR> <CR><Plug>AutoPairsReturn

" bind Alt+P in insert mode to paste (for nvim)..
" this actually conflicts with internal vim binding, see i_CTRL_P, but 
" basically it does work somehow, only once per insertmode excursion. Better 
" than nothing.
if has('nvim')
	inoremap <c-p> <c-r>"
endif

" a special case for surrounding with newlines
vmap S<CR> S<C-J>V2j=

if has('python3')
	python3 << EOF
# print ('hi from python')
EOF
	function! MungeArgListPython()
		python3 << EOF
import string
# check we are inside parens
curcol = vim.current.window.cursor[1];
parensstart = string.rfind(vim.current.line, '(', 0, curcol);
parensend = string.find(vim.current.line, ')', curcol);
print ('curcol ' + str(curcol)+ ' idxs are ' + str(parensstart) + ', ' + str(parensend) + ' line inside parens is >>' + vim.current.line[parensstart:parensend+1] + '<<')
EOF
	endfun
	" X does something rather kind of useful but i never use it --- I am 
	" binding to a custom python line munger whose purpose is to clean the 
	" inside of the parens we are inside of -- e.g. useful with argtextobj 
	" operations, just litter with extra commas at the beginning or whatever 
	" and we mop them up.
	nnoremap X :call MungeArgListPython()<CR>
endif

let g:mwPalettes = {
	\	'original': [
	\   { 'ctermbg': '25',  'ctermfg': '7', 'guibg': "#c2474a"},
	\   { 'ctermbg': '22',  'ctermfg': '7', 'guibg': "#c96127"},
	\   { 'ctermbg': '125', 'ctermfg': '7', 'guibg': "#cf9c36"},
	\   { 'ctermbg': '57',  'ctermfg': '7', 'guibg': "#699c69"},
	\   { 'ctermbg': '21',  'ctermfg': '7', 'guibg': "#006969"},
	\   { 'ctermbg': '58',  'ctermfg': '7', 'guibg': "#699c9c"},
	\   { 'ctermbg': '30',  'ctermfg': '7', 'guibg': "#9c699c"},
	\   { 'ctermbg': '89',  'ctermfg': '7', 'guibg': '#123476'},
	\   { 'ctermbg': '28',  'ctermfg': '7', 'guibg': '#654321'},
	\   { 'ctermbg': '54',  'ctermfg': '7', 'guibg': '#456123'},
	\   { 'ctermbg': '27',  'ctermfg': '7', 'guibg': '#432165'},
	\   { 'ctermbg': '166', 'ctermfg': '7'},
	\   { 'ctermbg': '24',  'ctermfg': '7'},
	\   { 'ctermbg': '162', 'ctermfg': '7'},
	\   { 'ctermbg': '90',  'ctermfg': '7'},
	\   { 'ctermbg': '63',  'ctermfg': '7'},
	\   { 'ctermbg': '132', 'ctermfg': '7'},
	\   { 'ctermbg': '202', 'ctermfg': '7'},
	\],
	\	'extended': function('mark#palettes#Extended'),
	\	'maximum': function('mark#palettes#Maximum')
	\}

nnoremap <Leader>N :MarkClear<CR>
nmap <Leader>m <Plug>MarkSet
nmap <F11> <Plug>MarkSet
xmap <Leader>m <Plug>MarkSet
xmap <F11> <Plug>MarkSet
" this is hard to use on the Mac but I am leaving <Leader>m to be usable -- 
" this is just a shortcut

" make mark case sensitive, this is more useful because i only ever use mark 
" in 'careful' type situations to correlate variables or looking at logs
let g:mwIgnoreCase=0

nnoremap d<CR> <Nop>

command! -complete=shellcmd -nargs=+ Shell call s:RunShellCommand(<q-args>)
function! s:RunShellCommand(cmdline)
	echo a:cmdline
	let expanded_cmdline = a:cmdline
	for part in split(a:cmdline, ' ')
		if part[0] =~ '\v[%#<]'
			let expanded_part = fnameescape(expand(part))
			let expanded_cmdline = substitute(expanded_cmdline, part, expanded_part, '')
		endif
	endfor
	botright new
	setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile nowrap
	call setline(1, 'You entered:    ' . a:cmdline)
	call setline(2, 'Expanded Form:  ' .expanded_cmdline)
	call setline(3,substitute(getline(2),'.','=','g'))
	execute '$read !'. expanded_cmdline
	setlocal nomodifiable
	1
endfunction

" magical command line bind triggered by h space
cnoreabbrev h <C-r>=(&columns >= 160 && getcmdtype() ==# ':' && getcmdpos() == 1 ? 'vertical botright help' : 'h')<CR>

" Returns true if at least delay seconds have elapsed since the last time this 
" function was called, based on the time
" contained in the variable "timer". The first time it is called, the variable is defined and the function returns
" true.
"
" True means not zero.
"
" For example, to execute something no more than once every two seconds using a variable named "b:myTimer", do this:
"
" if LongEnough( "b:myTimer", 2 )
"   <do the thing>
" endif
"
" The optional 3rd parameter is the number of times to suppress the operation within the specified time and then let it
" happen even though the required delay hasn't happened. For example:
"
" if LongEnough( "b:myTimer", 2, 5 )
"   <do the thing>
" endif
"
" Means to execute either every 2 seconds or every 5 calls, whichever happens first.
function! LongEnough( timer, delay, ... )
  let result = 0
  let suppressionCount = 0
  if ( exists( 'a:1' ) )
    let suppressionCount = a:1
  endif
  " This is the first time we're being called.
  if ( !exists( a:timer ) )
    let result = 1
  else
    let timeElapsed = localtime() - {a:timer}
    " If it's been a while...
    if ( timeElapsed >= a:delay )
      let result = 1
    elseif ( suppressionCount > 0 )
      let {a:timer}_callCount += 1
      " It hasn't been a while, but the number of times we have been called has hit the suppression limit, so we activate
      " anyway.
      if ( {a:timer}_callCount >= suppressionCount )
        let result = 1
      endif
    endif
  endif
  " Reset both the timer and the number of times we've been called since the last update.
  if ( result )
    let {a:timer} = localtime()
    let {a:timer}_callCount = 0
  endif
  return result
endfunction

" thanks to ZyX
function! WinTextWidth()
	let winwidth = winwidth(0)
	let winwidth -= (max([len(line('$')), &numberwidth]) * (&number || &relativenumber))
	let winwidth -= &foldcolumn
	redir => signs
	execute 'silent sign place buffer=' . bufnr('%')
	redir END
	if signs !~# '^\n---[^\n]*\n$'
		let winwidth -= 2
	endif
	" echo "wtw ".winnr().": ".winwidth
	return winwidth
endfunction

let g:spreadratio = 0.4
" Terminate iteration at 'abort' lines for perf.
" for the purposes of HeightSpread, any file taller than the g:spreadratio 
" * (Vim height - 3) should be considered too large.
function! LineCount(abort)
	let startlnr = 1
	let endlnr = line('$')
	if endlnr > a:abort
		return endlnr
	endif
	let numlines = 0
	let winwidth = WinTextWidth()
	for lnr in range(startlnr, endlnr)
		let lwidth = strdisplaywidth(getline(lnr))
		" let height =
		" if height != 1
		" 	echo lnr.' # '.lwidth.' % '.height." ^ ".getline(lnr)
		" endif

		" need to take into account folded lines
		let foldnr = foldclosed(lnr)
		if foldnr != -1 && foldnr != lnr
			continue
		endif
		if foldnr == lnr
			" a folded fold is always adding one height
			let numlines += 1
			continue
		endif
		let numlines += max([(lwidth - 1) / winwidth + 1, 1])
		if numlines > a:abort
			return numlines
		endif
	endfor
	" echo "lc: ".numlines
	return numlines
endfunction

" a function to distribute vertical space based on file lengths (I intend to 
" maybe call this on new window/bufload)
function! HeightSpread()
	" short circuit me if do not have python
	if !has('python3')
		return
	endif

	" if !LongEnough('g:heightspread', 1.5)
	" 	return
	" 	" This is not ideal because it does not guarantee it will run after the
	" 	" last thing that triggers me. But rate limiting to ensure performance 
	" 	" is more paramount than correct async cleanup so this will have to do 
	" 	" for now until I can dig into vim/nvim code to try to integrate this 
	" 	" shit.
	"   " Since then though, we found noautocmd and things have gotten faster.
	" endif
	" echom 'running HeightSpread '.localtime()

	" This has to do some clever shit because the problem is that shrinking 
	" a window will generally expand the one underneath it. This means that 
	" multiple short files not at the top (i.e. top having a large file) will 
	" result in the large file failing to get expanded out.

	" So, what I will do is do a scan to query the height of each file, then 
	" sort them and figure out how many of the shortest files can all fit on 
	" screen at once. Then, I distribute the height of the rest of the files 
	" evenly and assign all of these values in a second pass.

	" Now the problem is that using wincmd j/k to obtain and set the heights 
	" does not work well because of awful performance. So I want to adjust the 
	" algorithm to just scan all the windows at this point. But, since there is
	" no way to get the missing data about the x/y positioning of each window 
	" without switching to it (here, so far, i implicitly pick out the ones 
	" I care about by scanning up and down from the starting window) that 
	" approach is doomed for now.

	" Update: found out about python ability to get window parameters including
	" widths and heights so now i can definitely eliminate this walking up and 
	" down stuff; it's still impossible to find the places that the cursors 
	" are, but that's totally a non-issue...

	" Note: since then I have realized that noautocmd makes the traditional 
	" vimL way performant enough again. Even though I spent yesterday writing 
	" the python height calculator routine and polishing it up, the 
	let startwin = winnr()
	" loop all the way to top (but we have to store the winnrs due to 
	" possibility of arbitrary window arrangement)
	let lastwin = startwin
	let yaxis = 0
	let start = [lastwin, LineCount((&lines - 3) * g:spreadratio), winheight(lastwin), @%, yaxis]
	let wins = []
	let totspace = winheight(lastwin)
	wincmd k
	while (winnr() != lastwin)
		let yaxis = yaxis - 1
		" echo 'a'.lastwin.'-'.winnr()
		let lastwin = winnr()
		let hei = winheight(lastwin)
		call insert(wins, [lastwin, LineCount((&lines - 3) * g:spreadratio), hei, @%, yaxis])
		let totspace += hei
		wincmd k
	endwhile
	exe startwin.'wincmd w'
	let lastwin = startwin
	let yaxis = 0
	wincmd j
	while (winnr() != lastwin)
		let yaxis = yaxis + 1
		" echo 'b'.lastwin.'-'.winnr()
		let lastwin = winnr()
		let hei = winheight(lastwin)
		call add(wins, [lastwin, LineCount((&lines - 3) * g:spreadratio), hei, @%, yaxis])
		let totspace += hei
		wincmd j
	endwhile
	" TODO eliminate the wincmd j/k shit for deriving it all via vim.windows 
	" from python as below. We already need to use the python datas to get true 
	" proper window height content requirements.

	let final = []
	" echom 'wins '.string(wins)
	" echom 'start '.string(start)

	" sort (vimscript algorithms are insane so i am pythoning)
	python3 << EOF
# import operator
# import time
# timestart = time.time()
## windowData = [None] * (len(vim.windows) + 1)
# print 'wins' + str(len(vim.windows))
## for wini, win in enumerate(vim.windows):
## 	# print ", ".join([str(x) for x in [win.col, win.row, win.width, win.height]]);
## 	# windir = dir(win)
## 	# print 'dir: ' + str(windir)
## 	# for method in windir:
## 	# 	attr = getattr(win, method)
## 	# 	if method == 'buffer':
## 	# 		print '    buffer: length ' + str(len(attr))
## 	# 		print '    buffer[0]: ' + str(attr[0])
## 	# 	elif method[0] != '_':
## 	# 		print '    ' + method + ': ' + str(attr)
## 	# Compute real height of each window using its buffer and window width
## 
## 	# print 'bufnum! ' + str(win.buffer.number)
## 	tabstop = win.buffer.options['tabstop']
## 	# print 'tabstop! ' + str(tabstop)
## 	vim.command('redir => signlist')
## 	vim.command('silent sign place buffer=' + str(win.buffer.number))
## 	vim.command('redir END')
## 	signlist = vim.eval('signlist')
## 	wrapping = win.options['wrap']
## 	signcols = 2 if (signlist.count('line=') > 0) else 0
## 	linenrcols = len(str(len(win.buffer))) + 1
## 	# not accounting for numberwidth or number options right now
## 	height = len(win.buffer)
## 	width = win.width
## 	# print 'vals! ' + str(linenrcols) + ' ' + str(signcols) + ' hei ' + str(height)
## 	i = 0
## 	if wrapping:
## 		height = 0
## 		for line in win.buffer:
## 			l8 = line.decode('utf-8')
## 			i = i + 1
## 			tabcount = l8.count('\t')
## 			actual = len(l8) + (tabstop - 1) * tabcount
## 			lineheight = (actual - 1) / (width - signcols - linenrcols) + 1
## 			if (lineheight == 0):
## 				lineheight = 1
## 			height += lineheight
## 			# if lineheight != 1:
## 				# print str(i) + ' # ' + str(lineheight) + ' $ ' + str(win.width) + ' ' + str(win.width - signcols - linenrcols) + ' % ' + str(actual)
## 	windowData[wini + 1] = {'height': height}
	# print str(win.number) + ' <> ' + str(wini + 1)

# print str(windowData)

lens = vim.eval('wins')
start = vim.eval('start')
totspc = vim.eval('totspace')
sortedk = sorted(lens, key=lambda x: int(x[1]))
if ((int(start[1]) + 10) < int(totspc)):
	# prioritize if current one "fits"
	sortedk.insert(0, start)
else:
	# dont care
	sortedk.append(start)
# print 'sortedk b: ' + str(sortedk)
## for e in sortedk:
	## e.insert(1, windowData[int(e[0])]['height'])
# print 'sortedk: ' + str(sortedk)
# print sortedk
tot = 0
fits_unsorted = []
split = []
spreadratio = float(vim.eval('g:spreadratio'))
for i, l, hei, name, yaxis in sortedk:
	if (float(l) < (spreadratio * float(int(totspc) - tot))):
		# space allocation logic goes as such: as we consider placing the next
		# increasingly large item, abort it if insertion would result in
		# more than 50% (or g:spreadratio (TODO impl this)) of total remaining
		# space consumed.

		# The reasoning behind this is that it will allow for a large amount of
		# small splits while guaranteeing a reasonable amount of remaining space
		# for the rest in a proportionate way.
		tot = tot + int(l)
		fits_unsorted.append([i, l, yaxis, True])
	else:
		split.append([i, hei, yaxis])
splitlen = int(totspc) - tot
# have to compute and apply all heights one after another otherwise Vim will
# yank the heights around and undo our work. This means sorting by y-axis

# we redistribute the heights of the remaining split items using their current
# height ratios, and use greedy assignment to be fuzzy with divisions while
# ensuring total height count adds up.

# print ('before: ' + str(splitlen) + ', ' + str(fits_unsorted))
import functools

abort=False
if len(split) > 0:
	split.insert(0, 0)
	suma = functools.reduce(lambda x,y: x + int(y[1]), split)
	print ('split: ' + str(split))
	print('suma' + str(suma))
	sum = 0
	for e in split:
		print('e' + str(e))
		sum += int(e[1])
	ratio = float(splitlen) / sum
	print ('ratio: ' + str(ratio))
	print ('split: ' + str(split))
	split = [[x[0], round(ratio*int(x[1])), x[2], False] for x in split[1:]]
else:
	# if everything fits we have to be careful and pad out the one which is
	# focused with the remainder of space which is splitlen, to still consume
	# the space (otherwise the command line becomes enormous)
	abort = True
	# for e in fits_unsorted:
	# 	if (e[2] == '0'):
	# 		e[1] = int(e[1]) + splitlen
	# 		break
# print ('after: ' + str(fits_unsorted))

# sort by position
if not abort: # if aborting just effectively skip the rest
	fits = sorted(fits_unsorted + split, key=lambda x: int(x[2]))
	for w, l, o, b in fits:
		# last value is flag whether fits or not. only if fits do we scroll them up
		vim.command('call add(final, [' + str(w) + ', ' + str(l) + ', "' + ('fit' if b else 'no') + '"])')
# print 'after sortin: ' + str(fits)
# print 'taken ' + str(time.time() - timestart)
EOF

	" echo 'totspc: '. totspace
	" echo 'fits'
	" echo fits
	" echo 'split'
	" echo split
	" echo splitlen

	for i in final
		exe i[0].'wincmd w'
		exe 'resize' string(i[1])
		" echo i[0].' set to '.i[1]
		if i[2] == 'fit'
			" echo 'going to top for window '.i[0]
			normal! 
		endif
	endfor

	" go back to starting window
	exe startwin.'wincmd w'
endfun

" for setting up ability to trigger something once on first creation of window
" autocmd that will set up the w:created variable
" autocmd VimEnter * autocmd WinEnter * let w:created=1

" Consider this one, since WinEnter doesn't fire on the first window created when Vim launches.
" You'll need to set any options for the first window in your vimrc,
" or in an earlier VimEnter autocmd if you include this
" autocmd VimEnter * let w:created=1

" Example of how to use w:created in an autocmd to initialize a window-local option
" autocmd WinEnter,BufEnter,BufWritePost,VimResized,InsertLeave * noautocmd call HeightSpread()

" function! AdjustStatusSections()
" 	echom "implement me"
" endfun

" autocmd VimResized * noautocmd call AdjustStatusSections()

" Not sure if this one here is overkill or not, but on terminal resizing it 
" will be useful to call the routine
" au BufWinEnter * silent call HeightSpread()
" I will use \H
nnoremap <Leader>H :noautocmd call HeightSpread()<CR>

" changing these to not switch window because its too damn slow
" TODO make this into a function which uses v:count1.
nnoremap = :vertical res +5<CR>
nnoremap - :vertical res -5<CR>
nnoremap + :res +4<CR>
nnoremap _ :res -4<CR>

" conceal rule for javascript
au! FileType javascript setl conceallevel=2 concealcursor=c

""pangloss conceal rules
"let g:javascript_conceal_function   = "ƒ"
"let g:javascript_conceal_null       = "ø"
"let g:javascript_conceal_this       = "@"
"let g:javascript_conceal_return     = "↲"
"let g:javascript_conceal_undefined  = "¿"
"let g:javascript_conceal_NaN        = "ℕ"
"let g:javascript_conceal_prototype  = "¶"

hi Conceal ctermbg=238 ctermfg=NONE cterm=NONE guibg=#404040

" TODO free up the [] maps from the pause (there is overloading done by vim 
" impaired which is causing the craziness) (But i mean there isnt actually an 
" action bound to [ or ] proper, so im not sure what i was getting at with this 
" comment originally.)

"""" I'm not using the following stuff and wanted to test omnicomplete """"
" " spell fix bind (my s, f, c binds are filled up, so I'm using x)
" nnoremap <Leader>x ms[s1z=:let g:correct_index = 1<CR>`s
" inoremap <C-x> <C-G>u<Esc>ms[s1z=:let g:correct_index = 1<CR>`sa

" " only works immediately after use of <Leader> x corrected to not the proper 
" " word
" nnoremap <Leader>X :let g:correct_index += 1<CR>u:exec "normal! " . correct_index . "z=`s"<CR>
" inoremap <C-X> <C-G>u<Esc>:let g:correct_index += 1<CR>u:exec "normal! " . correct_index . "z=`s"<CR>a

nnoremap <Leader>T :ThesaurusQueryReplaceCurrentWord<CR>
nnoremap <Leader>t :Tagbar<CR>

" because g: is easier to remember than :@* and also this is more full featured
" i believe.
function! SourceVimscript(type)
  let sel_save = &selection
  let &selection = "inclusive"
  let reg_save = @"
  if a:type == 'line'
    silent execute "normal! '[V']y"
  elseif a:type == 'char'
    silent execute "normal! `[v`]y"
  elseif a:type == "visual"
    silent execute "normal! gvy"
  elseif a:type == "currentline"
    silent execute "normal! yy"
  endif
  let @" = substitute(@", '\n\s*\\', '', 'g')
  " source the content
  @"
  let &selection = sel_save
  let @" = reg_save
endfunction
nnoremap <silent> g: :set opfunc=SourceVimscript<cr>g@
vnoremap <silent> g: :<c-U>call SourceVimscript("visual")<cr>
nnoremap <silent> g:: :call SourceVimscript("currentline")<cr>

" an interactive statusline that shows the number of search matches in the 
" buffer. Not really sure what I used this for, but it is quite clunky as it is
" now.
" this should maybe evenutally get integrated into airline. For the time being 
" we can manually enable this mode (and lose all of statusline) when we want 
" this capability...
let s:prevcountcache=[[], 0]
function! ShowCount()
    let key=[@/, b:changedtick]
    if s:prevcountcache[0]==#key
        return s:prevcountcache[1]
    endif
    let s:prevcountcache[0]=key
    let s:prevcountcache[1]=0
    let pos=getpos('.')
    try
        redir => subscount
        silent %s///gne
        redir END
        let result=matchstr(subscount, '\d\+')
        let s:prevcountcache[1]=result
        return result
    finally
        call setpos('.', pos)
    endtry
endfunction
set ruler
nnoremap <Leader>c :let &statusline='%{ShowCount()} %<%f %h%m%r%=%-14.(%l,%c%V%) %P' "THIS WILL BLOW AWAY STATUS LINE FOR SEARCH COUNTING. Ctrl+C to cancel

" windowswap disable binds, reducing latency on two of my existing binds now, 
" and allow me to bind just the one thing that i use with it.
let g:windowswap_map_keys = 0
nnoremap <m-w> :call WindowSwap#EasyWindowSwap()<CR>

" fuck, still doesnt work (i tried twice)
" function! HiCursorWordsDisable()
" 	augroup HiCursorWordsUpdate
" 		autocmd!
" 	augroup END
" 	augroup HiCursorWords 
" 		autocmd!
" 	augroup END
" endfun

" Zoom / Restore window.
function! s:ZoomToggle() abort
    if exists('t:zoomed') && t:zoomed
        execute t:zoom_winrestcmd
        let t:zoomed = 0
    else
        let t:zoom_winrestcmd = winrestcmd()
        resize
        vertical resize
        let t:zoomed = 1
    endif
endfunction
command! ZoomToggle call s:ZoomToggle()
nnoremap <Leader><Leader> :ZoomToggle<CR>

nnoremap [[ :SidewaysLeft<CR>
nnoremap ]] :SidewaysRight<CR>

" echom 'term is '.$TERM
if (exists('+termguicolors') && ($TERM == 'tmux-256color-italic' || $TERM == 'xterm-256color-italic'))
  let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
  let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
  set termguicolors
endif
" if has('termguicolors')
"   set termguicolors
" endif

if has("gui_macvim")
    " set macvim specific stuff
endif

if has("mouse_sgr")
	set ttymouse=sgr
"else
	"set ttymouse=xterm2
endif

hi Todo guibg=#484848

" command! -bang FLinesGrep call fzf#vim#grep(
"      \ 'GREP_COLORS="fn=34:mc=01;30:ms=33:sl=21:cx=31" grep -vnIr --exclude-dir=".git" --color=always "^$" .',
"      \ 0,
"      \ {'options': '--reverse --prompt "FLines> "'})

command! -bang -nargs=* FLineSearch call fzf#vim#grep("rg --color=never --line-number --column --no-heading --fixed-strings --hidden ".shellescape(<q-args>), 1, {'options': '--prompt "FLineSearch '.shellescape(<q-args>).'> "'})

command! -bang FLines call fzf#vim#grep(
     \ "rg --color=never --column --line-number --no-heading --ignore-case --hidden -v '^$'",
     \ 1,
     \ {'options': '--prompt "FLines> "'})

command! -bang Directories call fzf#run(fzf#wrap({'source': 'find * -type d'}))

" sets color style via fzf. kind of insane and seems to screw with the sign 
" styles :\
command! -bang Colors
  \ call fzf#vim#colors({'left': '15%', 'options': '--reverse --margin 30%,0'}, <bang>0)

let g:fzf_buffers_jump = 1

nnoremap <silent> <Leader>g :FLines<CR>

" This is intended to work by searching for the current search term without 
" modifying the search term.

" TODO need to figure out how to munge the search buffer upon use here.
" This is supposed to work like this: the active find buffer is used. Which is 
" all fine and good, the problem is that this often has garbage like word end 
" characters in it which must be cleaned for use in here.
nnoremap <Leader>G :exec "FLineSearch <c-r>/"<CR>

" An action can be a reference to a function that processes selected lines
function! s:build_quickfix_list(lines)
  call setqflist(map(copy(a:lines), '{ "filename": v:val }'))
  copen
  cc
endfunction

" add ctrlq to default maps
let g:fzf_action = {
  \ 'ctrl-q': function('s:build_quickfix_list'),
  \ 'ctrl-t': 'tab split',
  \ 'ctrl-s': 'split',
  \ 'ctrl-v': 'vsplit' }

" You can set up fzf window using a Vim command (Neovim or latest Vim 8 required)
" let g:fzf_layout = { 'window': 'enew' }
" let g:fzf_layout = { 'window': '-tabnew' }
" let g:fzf_layout = { 'window': 'new' }
let g:fzf_layout = { 'down': '~60%' }

" Customize fzf colors to match your color scheme
let g:fzf_colors =
\ { 'fg':      ['fg', 'Normal'],
  \ 'bg':      ['bg', 'Normal'],
  \ 'hl':      ['fg', 'Constant'],
  \ 'fg+':     ['fg', 'Normal'],
  \ 'bg+':     ['bg', 'CursorLine'],
  \ 'hl+':     ['fg', 'Constant'],
  \ 'info':    ['fg', 'PreProc'],
  \ 'border':  ['fg', 'Directory'],
  \ 'prompt':  ['fg', 'StatusLine'],
  \ 'pointer': ['fg', 'Exception'],
  \ 'marker':  ['fg', 'Keyword'],
  \ 'spinner': ['fg', 'Label'],
  \ 'header':  ['fg', 'Comment'] }

" Enable per-command history.
" CTRL-N and CTRL-P will be automatically bound to next-history and
" previous-history instead of down and up. If you don't like the change,
" explicitly bind the keys to down and up in your $FZF_DEFAULT_OPTS.
let g:fzf_history_dir = '~/.local/share/fzf-history'

" inoremap <expr> <c-x><c-k> fzf#vim#complete('cat /usr/share/dict/words')

let g:fzf_commits_log_options = '--graph --date-order --pretty=format:"%C(bold magenta)%h%Creset -%C(auto)%d%Creset %s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset"'

command! -bang -nargs=? -complete=dir Files
  \ call fzf#vim#files(<q-args>, {'options': ['--preview', 'bat -p --color always {}']}, <bang>0)

" https://stackoverflow.com/a/6271254
function! s:get_visual_selection()
	" Why is this not a built-in Vim script function?!
	let [line_start, column_start] = getpos("'<")[1:2]
	let [line_end, column_end] = getpos("'>")[1:2]
	let lines = getline(line_start, line_end)
	if len(lines) == 0
		return ''
	endif
	let lines[-1] = lines[-1][: column_end - (&selection == 'inclusive' ? 1 : 2)]
	let lines[0] = lines[0][column_start - 1:]
	return join(lines, "\n")
endfunction

" does not interfere with main search
function! SearchForToken()
	let l:word = expand('<cword>')
	echom 'search is '.l:word
	exec 'FLineSearch '.l:word
endfun
function! SearchForSelection()
	exec 'FLineSearch '.s:get_visual_selection()
endfun

nnoremap <Leader><CR> :call SearchForToken()<CR>
vnoremap <Leader><CR> :call SearchForSelection()<CR>

" override vim local search with global vim search (which is implicitly set in 
" filesystem by searching in any vim)
nnoremap <silent> <Leader>n :let @/ = join(readfile(glob("~/.vim/.search")), "\n")<CR>n
" TODO FINISH ME

set nostartofline

" prevent epic slowdowns in certain poorly formatted (often minified or 
" partially-minified) files
set synmaxcol=1000

" useful magic for making files executable if they look like they should be
au BufWritePost * if getline(1) =~ "^#!" | if getline(1) =~ "/bin/" | silent execute "!chmod a+x <afile>" | endif | endif

" augroup ALEProgress
"     autocmd!
" 	" TODO FIX/FINISH THIS THING
"     autocmd User ALELintPre hi Statusline guifg=#434343
"     autocmd User ALELintPost hi Statusline guifg=#262626
" augroup end

" let g:ale_list_window_size_max = 5
" let g:ale_list_window_size = 1

" autocmd User ALELintPost call s:ale_loclist_limit()
" function! s:ale_loclist_limit()
"     if exists("b:ale_list_window_size_max")
"         let b:ale_list_window_size = min([len(ale#engine#GetLoclist(bufnr('%'))), b:ale_list_window_size_max])
"     elseif exists("g:ale_list_window_size_max")
"         let b:ale_list_window_size = min([len(ale#engine#GetLoclist(bufnr('%'))), g:ale_list_window_size_max])
"     endif
" endfunction

" let g:ale_open_list = 1
" let g:ale_lint_on_text_changed = 'none'
" let g:ale_lint_on_save = 1
" let g:ale_lint_on_enter = 0
" let g:ale_max_signs = 64
" let g:_ale_cpp_options = ' --std=c++11 -O0'

" let g:ale_echo_msg_error_str = 'E'
" let g:ale_echo_msg_warning_str = 'W'
" let g:ale_echo_msg_format = '[%linter%] %s %code% [%severity%]'

" " TODO going to use python to walk the cwd up and slurp .clang_complete files 
" " to populate ale_pattern_options with all the necessary flags, mostly header 
" " paths. Bit annoying (and if i have the time i'd contribute it to ale...) but 
" " should work reliably. Then, no project specific header config will exist in 
" " vimrc (phew!!!)

" let g:_ale_cpp_options_onboard = g:_ale_cpp_options
" 			\ . ' -I /home/slu/onboard-sdk/osdk-core/api/inc'
" 			\ . ' -I /home/slu/onboard-sdk/osdk-core/protocol/inc'
" 			\ . ' -I /home/slu/onboard-sdk/osdk-core/hal/inc'
" 			\ . ' -I /home/slu/onboard-sdk/osdk-core/utility/inc'
" 			\ . ' -I /home/slu/onboard-sdk/osdk-core/platform/linux/inc'
" 			\ . ' -I /home/slu/onboard-sdk/sample/linux/common'
" 			\ . ' -I /home/slu/raspi-software/display'
" 			\ . ' -I /home/slu/WiringPi/wiringPi'
" 			\ . ' -I /home/slu/pigpio'
" 			\
" 			\ . ' -I /Users/slu/Documents/onboard-sdk/osdk-core/api/inc'
" 			\ . ' -I /Users/slu/Documents/onboard-sdk/osdk-core/protocol/inc'
" 			\ . ' -I /Users/slu/Documents/onboard-sdk/osdk-core/hal/inc'
" 			\ . ' -I /Users/slu/Documents/onboard-sdk/osdk-core/utility/inc'
" 			\ . ' -I /Users/slu/Documents/onboard-sdk/osdk-core/platform/linux/inc'
" 			\ . ' -I /Users/slu/Documents/onboard-sdk/sample/linux/common'
" 			\ . ' -I /Users/slu/Documents/pigpio'

" let g:ale_linters =	{ 'cpp': ['clang', 'clangtidy', 'g++'] }
" disable eslint for typescript. it interferes.
" let g:ale_linters =	{
" 			\ 'cpp': ['c++'],
" 			\ 'typescript': ['tslint', 'tsserver']
" 			\}

" let g:ale_cpp_gcc_options = g:_ale_cpp_options
" let g:ale_cpp_clang_options = g:_ale_cpp_options
" let g:ale_cpp_clangtidy_options = g:_ale_cpp_options

" let g:ale_cpp_clangtidy_checks = ['*', '-cppcoreguidelines-pro-bounds-pointer-arithmetic']

" let g:_ale_cpp_options_jibo = g:_ale_cpp_options

" let g:ale_pattern_options = {
" 			\}
" \	'.*/lps-service/web/js/lps\.js$': {'ale_enabled': 0},
" \   'jibo/': {
" \   	'ale_cpp_gcc_options': g:_ale_cpp_options_jibo,
" \   	'ale_cpp_clang_options': g:_ale_cpp_options_jibo,
" \   	'ale_cpp_clangtidy_options': g:_ale_cpp_options_jibo
" \   },
" \	'onboard-sdk/': {
" \   	'ale_cpp_gcc_options': g:_ale_cpp_options_onboard,
" \   	'ale_cpp_clang_options': g:_ale_cpp_options_onboard,
" \   	'ale_cpp_clangtidy_options': g:_ale_cpp_options_onboard
" \	}

" if !exists("g:os")
" 	if has("win64") || has("win32") || has("win16")
" 		let g:os="Windows"
" 	else
" 		" as a builtin (??), seems to require me to export OSTYPE in shell 
" 		" config.
" 		let g:os=$OSTYPE
" 	endif
" endif

" this is for centos
" let g:clang_library_path=glob('/usr/local/lib/libclang.so')
" if (!strlen(g:clang_library_path))
" 	" this is for ubuntu
" 	let g:clang_library_path=glob('/usr/lib/llvm-*/lib/libclang.so')
" 	if (!strlen(g:clang_library_path))
" 		" echom 'no clang found in /usr/lib/llvm-*, attempting /Library/Developer/...'
" 		" this is for macOS
" 		let g:clang_library_path=glob('/Library/Developer/CommandLineTools/usr/lib/libclang.dylib')
" 		if (!strlen(g:clang_library_path))
" 			let g:clang_library_path=glob('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libclang.dylib')
" 			if (!strlen(g:clang_library_path))
" 				let g:clang_library_path=glob('/Applications/Xcode.app/Contents/Frameworks/libclang.dylib')
" 				if (!strlen(g:clang_library_path) && g:os != 'linux-gnueabihf' && g:os != 'Windows' && g:os != 'msys')
" 					" do not surface this error on ARM linux systems such as raspi
" 					echom "clang still couldn't be found. hmm!"
" 				endif
" 			endif
" 		endif
" 	endif
" endif

" write some dates fast, from 
" http://blog.erw.dk/2016/04/19/entering-dates-and-times-in-vim/
inoremap <expr> <c-d>t strftime("%H:%M")
inoremap <expr> <c-d>T strftime("%H:%M:%S")
inoremap <expr> <c-d>d strftime("%Y-%m-%d")
inoremap <expr> <c-d>l strftime("%Y-%m-%d %H:%M")

" for cursor fanciness
" if exists('$TMUX')
"   let &t_SI = "\<Esc>Ptmux;\<Esc>\<Esc>[5 q\<Esc>\\"
"   let &t_EI = "\<Esc>Ptmux;\<Esc>\<Esc>[1 q\<Esc>\\"
" else
"   " let &t_SI = "\<Esc>]50;CursorShape=1\x7"
"   " let &t_EI = "\<Esc>]50;CursorShape=0\x7"
  let &t_SI = "\e[5 q"
  let &t_SR = "\e[2 q"
  let &t_EI = "\e[1 q"
" endif

hi CleverFMark guibg=#af008f guifg=#eeeeee
hi CleverFDirectMark guifg=#2fc00f cterm=bold,underline
let g:clever_f_mark_cursor_color = 'CleverFMark'
let g:clever_f_mark_char_color = 'CleverFMark'
let g:clever_f_mark_direct = 1
let g:clever_f_mark_direct_color = 'CleverFDirectMark'

" highlights for the bulitin tabline. When using lightline or airline or such, 
" should not affect anything.
" These colors are garish and bad for cterm, and since I'm using gui colors for 
" vim now, i'm not bothering to fix them.
hi TabLineFill ctermfg=LightGreen ctermbg=DarkGreen guibg=#111111 guifg=#222222
hi TabLine ctermfg=Blue ctermbg=Yellow guifg=#000000
hi TabLineSel ctermfg=Red ctermbg=Yellow guifg=#aaaaaa guibg=#222222
hi Title guifg=#f4f4f4 cterm=italic,bold gui=italic,bold

" paste the global search
nnoremap <Leader>P :.-1read $HOME/.vim/.search<CR>

" dont like this: this slurps entire line instead of what your visual selection 
" was
" vnoremap <silent> <Leader>y :w !pbcopy<CR><CR>
function! YankVisual()
	normal! gvy
	echom "running YankVisual pbcopy"
	let poscursor=getpos('.')
	" to debug -- make sure to keep it consistent with the below
	echom "exec !echo '" . substitute(escape(substitute(@@, "'", "'\"'\"'", 'g'), '!\#%'), '\n', '\\n', 'g') . "' | perl -pe 's/(?<\\!\\\\)\\\\n/\\n/g' | pbcopy"
	" Here's a quick summary. The exec body here has to be escaped for vim 
	" single quote strings, so single quotes are replaced with "'" and newlines 
	" are replaced with \n and converted back, except that \\n must be not be 
	" escaped (hence perl negative lookbehind).
	exec "!echo '" . substitute(escape(substitute(@@, "'", "'\"'\"'", 'g'), '!\#%'), '\n', '\\n', 'g') . "' | perl -pe 's/(?<\\!\\\\)\\\\n/\\n/g' | pbcopy"
endfun
vnoremap <Leader>y :<C-U> call YankVisual()<CR>:redraw!<CR>

" the leader y works like normal yy (but for my clipboard)
nnoremap <silent> <Leader>y :.w !pbcopy<CR><CR>
nnoremap <Leader>p :read !pbpaste<CR>

" do not use read here so that the selected stuff gets slurped.
vnoremap <Leader>p :!pbpaste<CR>

" let g:user_emmet_install_global = 0
" autocmd FileType html,css EmmetInstall | silent echom "enabling ctrl+comma emmet bind" | imap <F34> <C-y>, | nmap <F34> <C-y>,

" This is used to help resolve the temp file cannot be opened issue on long 
" running linux vim sessions.
command! Mktmpdir call mkdir(fnamemodify(tempname(),":p:h"),"",0700)

let g:git_messenger_include_diff = "current"

" for JSONC (JSON with comments) format
autocmd FileType json syntax match Comment +\/\/.\+$+

" just to view them
" nmap <PageUp> :echo 'pgup'<CR>
" nmap <PageDown> :echo 'pgdn'<CR>

if !has('nvim')
	set <F27>=[5;5~
	noremap! <silent> <F27> <ESC>:tabprev<CR>
	noremap <silent> <F27> :tabprev<CR>
	set <F28>=[6;5~
	noremap! <silent> <F28> <ESC>:tabnext<CR>
	noremap <silent> <F28> :tabnext<CR>
	set <F29>=[5;2~
	nmap <F29> :echo 's-pgup'<CR>
	set <F30>=[6;2~
	nmap <F30> :echo 's-pgdn'<CR>
	set <F31>=[5;3~
	nmap <F31> :echo 'm-pgup'<CR>
	set <F32>=[6;3~
	nmap <F32> :echo 'm-pgdn'<CR>
else
	nmap <C-PageUp> :echo 'c-pgup'<CR>
	nmap <C-PageDown> :echo 'c-pgdn'<CR>
	nmap <S-PageUp> :echo 's-pgup'<CR>
	nmap <S-PageDown> :echo 's-pgdn'<CR>
	nmap <M-PageUp> :echo 'm-pgup'<CR>
	nmap <M-PageDown> :echo 'm-pgdn'<CR>
endif
