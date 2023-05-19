-- -- -- TODO LIST
--[[

- short term for STS: work out how to delete/paste items automating handling and placement of delimiters, handling inclusion of boundary bracket chars, etc. I guess the latter can be handled by having a way to expand to all siblings though. This may have impact on the next work.
- improve STS to contantly set highlights to preview what the parent and sibling nodes are? track the last child node? abandon visual mode? Not sure.
- for STS: evaluate if it is more intuitive for both parent/child and sibling movements to use up/down directionals rather than have siblings be left/right. I guess the main issue here is evicting other key binds...
- find for most common languages a workflow to autoformat them, which is going to solve the indent related niggles that remain
- explore the alternative to composer (live-command.nvim previews macros and other stuff) (there is also nvim-neoclip)
- make the i_I custom behavior i have dot-repeatable (i tried with gpt4 and failed)
- get a better profiler tool and figure out why this file is sluggish (got perfanno and it is kind of pretty cool, but see if there are any other better profilers)
- look into resolving wezterm performance issues (https://github.com/wez/wezterm/discussions/3664) and move away from alacritty/windows term/possibly eliminate tmux
- reorganize the config into separate source files grouped by functionality
- LOW still want that one key to cycle windows and then tabs, even while trying to make the ctrl-w w, gt defaults -- for now this is done with tab and shift tab and i might just keep this honestly, because the behavior of going to the next tab when at the last window didnt really work that intuitively.
- (IMPL'd but broken) yank window to new tab in next/prev direction or into new tab (also like how this is consistent with how the analogous one works in tmux)
- my prized alt-, and friends automations (to be fair i've been getting good at manually leveraging dot-repeat which is decently good retraining) (for this one i think i should look into the newer knowledge i now have for being able to customize dot repeat? or nah...)
- DONE via alt+p. Also, paste mode is deprecated now. \p for toggle paste and removing indent markers and stuff like that in paste mode to make it work like a copy-mode
- f10 handling for tmux (amazing though, i got this far without it, maybe i dont want to integrate from vim to tmux...)

- implement insert mode ctrl arrows to do big word hops (backspace does a small word hop)
- (super low prio) implement semantic highlight removal (i want this in possibly lua right now but also definitely dockerfile) by literally selecting them out at the highlight group level (ah dang, no worky for dockerls)
- see if i can get trouble to show a list of just a type of severity of diag. hook to click on section. This might not be easily doable but if i can programmatically fetch the list i can just try to focus on the first of that type.
- I THINK I DID THIS add update field back to heirline for diags' flexible entries.
- NOT SURE IF THING figure out why dockerls capabilities doesn't include semantic tokens
- highlight with a salient background the active window in nvim 

--]]

-- traditional settings

vim.o.title = true
vim.o.number = true
vim.o.undofile = true
vim.o.undodir = vim.env.HOME .. "/.tmp"
vim.o.termguicolors = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.tabstop = 4
vim.o.numberwidth = 3
-- vim.o.cmdheight = 0
vim.o.updatetime = 300 -- useful for non-plugin word highlight
vim.o.mousescroll = 'ver:3,hor:3'
vim.o.showbreak = "→ "

-- settings that may require inclusion prior to Lazy loader

-- init lazy.nvim plugin loader
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end

vim.opt.rtp:prepend(lazypath)

local function safeRequire(module)
  local success, res = pcall(require, module)
  if success then return res end
  vim.api.nvim_err_writeln("safeRequire caught an error while loading " .. module .. ", error: " .. res)
  return nil
end

-- plugins
require("lazy").setup("plugins", {
  checker = { enabled = true, notify = false, },
  git = {
    url_format = "git@github.com:%s.git",
  }
})

-- mappings

--- from the vimL 
-- " woot, disable phantom clicktyping into random spots
-- inoremap <LeftMouse> <Nop>
-- inoremap <2-LeftMouse> <Nop>
-- inoremap <3-LeftMouse> <Nop>
-- inoremap <4-LeftMouse> <Nop>
vim.keymap.set("i", "<LeftMouse>", "<Nop>")
vim.keymap.set("i", "<2-LeftMouse>", "<Nop>")
vim.keymap.set("i", "<3-LeftMouse>", "<Nop>")
vim.keymap.set("i", "<4-LeftMouse>", "<Nop>")

-- Remember: I map at the terminal level ctrl+BS, alt/opt+BS both to ^[^?, so binds should use <m-bs>. I'm not sure how this works on windows terminal as well, but it does.
-- stronger normal mode move back via backspace
vim.keymap.set("n", "<M-BS>", "B")
-- word delete. Note that <Cmd>normal db does NOT work because exiting normal mode puts the cursor at the wrong spot
vim.keymap.set("i", "<M-BS>", "<C-W>")
-- command mode word delete
vim.keymap.set('c', "<M-BS>", '<C-W>', {noremap = true})

vim.keymap.set("n", "<leader>w", ":set wrap!<cr>")

--- disabling for now since regular works with cmp cmdline completion
-- vim.keymap.set({ "n", "v" }, "/", "/\\V")
vim.keymap.set({ "n", "x" }, "k", "gk")
vim.keymap.set({ "n", "x" }, "j", "gj")
vim.keymap.set({ "n", "x" }, "gk", "k")
vim.keymap.set({ "n", "x" }, "gj", "j")

vim.keymap.set({ "x", "n" }, "K", "5gk")
vim.keymap.set({ "x", "n" }, "J", "5gj")
vim.keymap.set({ "x", "n" }, "H", "7h")
vim.keymap.set({ "x", "n" }, "L", "7l")

-- just a thing i got used to; makes it easy to put what you just typed into brackets
vim.keymap.set("i", "<c-b>", "<esc>lve")

-- Joining lines with Ctrl+N. Keep cursor stationary.
vim.keymap.set("n", "<c-n>", function()
  local line, col = unpack(vim.api.nvim_win_get_cursor(0))
  -- print("win_get_cursor: "..vim.inspect(vim.api.nvim_win_get_cursor(0)).. " Unpacks to "..line..","..col)
  vim.cmd("normal! J")
  vim.api.nvim_win_set_cursor(0, { line, col })
end)

-- make alt+p (historical reason: used to toggle paste mode) toggle in unison the indent markers and the listchars. Key the state off of the indent-blankline toggle state.
vim.keymap.set("n", "<m-p>", function()
  local indent_blankline_enabled = vim.g.indent_blankline_enabled
  if indent_blankline_enabled then
    vim.g.indent_blankline_enabled = false
    vim.o.list = false
    vim.o.number = false
    -- a bit tricky: toggle signs off
    vim.o.signcolumn = "no"
  else
    vim.g.indent_blankline_enabled = true
    vim.o.list = true
    vim.o.number = true
    vim.o.signcolumn = "auto"
  end
end)

-- make it easier to type a colon
vim.keymap.set("n", ";", ":")

-- make paste not move the cursor
vim.keymap.set("n", "P", "P`[")

-- turn F10 into escape
vim.keymap.set({ "", "!" }, "<F10>", "<esc>")
vim.keymap.set({ "c" }, "<F10>", "<c-c>")

-- normal and visual mode backspace does what b does
-- disabled for nvim-spider
-- vim.keymap.set({ "n", "v" }, "<bs>", "b")
-- consistency with pagers in normal mode
vim.keymap.set({ "n", "v" }, " ", "<c-d>")
vim.keymap.set({ "n", "v" }, "b", "<c-u>")

-- ctrl+b to go back forward in jumplist
vim.keymap.set("n", "<c-b>", "<tab>")

-- hoping to automate entering visual mode
-- vim.keymap.set('n', '<cr>', 'v<cr>', {remap = true})

-- allow backtick to do the same thing as percent
vim.keymap.set({ "n", "v", "o" }, "`", "%")
vim.keymap.set("n", "<c-\\>", ":vsplit<cr>")
vim.keymap.set("v", "<c-\\>", "<esc>:vsplit<cr>")
vim.keymap.set("n", "<c-_>", ":split<cr>")
vim.keymap.set("v", "<c-_>", "<esc>:split<cr>")

-- Example basic version of my quick-search. Not using this though. too simplistic.
-- vim.keymap.set('n', '<CR>', '*``')

-- make typing d<CR> not cause two lines to be deleted. Make it do nothing instead. This is because d is a terminal alias I use and it's too easy to let it be entered in a Vim.
vim.keymap.set("n", "d<CR>", "<nop>")

-- quit with shift+q
vim.keymap.set("n", "<s-q>", ":q<cr>")

-- add more window key sugar for the yank direction HJKL default binds.
vim.keymap.set("n", "<c-w><c-l>", "<c-w>L")
vim.keymap.set("n", "<c-w><c-h>", "<c-w>H")
vim.keymap.set("n", "<c-w><c-j>", "<c-w>J")
vim.keymap.set("n", "<c-w><c-k>", "<c-w>K")

-- filters out windows:
-- - made by nvim-treesitter-context
-- - made by Neotree
-- - made by Trouble
-- Does so by filtering out not focusable, then filtering out nofile/nowrite/help/quickfix, then checking filetypes where still applicable (hopefully never need to do that)
local function filter_to_real_wins(window_list)
  local real_wins = {}
  for _, win in ipairs(window_list) do
    -- log("win config", win, vim.api.nvim_win_get_config(win))
    local buf =  vim.api.nvim_win_get_buf(win)
    -- log("win buftype filetype", win, vim.api.nvim_buf_get_option(buf, "buftype"), vim.api.nvim_buf_get_option(buf, "filetype"))
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    if vim.api.nvim_win_get_config(win).focusable and buftype ~= "nofile" and buftype ~= "nowrite" and buftype ~= "help" and buftype ~= "quickfix" then
      table.insert(real_wins, win)
    end
  end
  return real_wins
end

-- cycle thruogh the windows with tab. If the current tab has only one window, actually cycle through all the buffers which are not already open in other tabs (if applicable).
_G.CycleWindowsOrBuffers = function (forward)
  local curwin = vim.api.nvim_get_current_win()
  local wins = filter_to_real_wins(vim.api.nvim_list_wins())
  local tabs = vim.api.nvim_list_tabpages()
  local curtab = vim.api.nvim_get_current_tabpage()
  local wins_in_curtab = filter_to_real_wins(vim.api.nvim_tabpage_list_wins(curtab))
  -- log("wins, tabs, curtab, wins_in_curtab", wins, tabs, curtab, wins_in_curtab)
  if #wins == 1 then
    log("CycleWindowsOrBuffers only one window, cycling buffer " .. (forward and "forward" or "backward"))
    if forward then vim.cmd("bnext") else vim.cmd("bprevious") end
  elseif #tabs == 1 then
    log("CycleWindowsOrBuffers only one tab, going forward to next window")
    vim.cmd("wincmd " .. (forward and "w" or "W"))
  -- boundary
  elseif forward and wins_in_curtab[#wins_in_curtab] == curwin then
    log("CycleWindowsOrBuffers in last window in tab so going forward to next tab")
    vim.cmd("tabnext")
  elseif not forward and curwin == wins_in_curtab[1] then
    log("CycleWindowsOrBuffers in first window in tab so going back to prev tab")
    vim.cmd("tabprevious")
  else
    log("CycleWindowsOrBuffers in the last case (multiple tabs, not at end), cycling window " .. (forward and "forward" or "backward"))
    vim.cmd("wincmd " .. (forward and "w" or "W"))
  end
end

vim.keymap.set("n", "<tab>", "<cmd>lua CycleWindowsOrBuffers(true)<cr>")
vim.keymap.set("n", "<s-tab>", "<cmd>lua CycleWindowsOrBuffers(false)<cr>")

-- dumping vimL code that I didnt bother porting yet here for expedient bringup
vim.cmd([[

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

  " my quit method: ctrl+q first attempts to quit nvim. if there are unsaved changes, ask if you want to save them first.
  function! MyConfirmQuitAllNoSave()
    qall
    if confirm('DISCARD CHANGES and then QUIT ALL? (you hit Ctrl+Q)', "No\nConfirm Discarding Changes!") == 2
      qall!
    endif
  endfunc
  " Use CTRL-Q for abort-quitting (no save)
  noremap <C-Q> :call MyConfirmQuitAllNoSave()<CR>
  cnoremap <C-Q> <C-C>:call MyConfirmQuitAllNoSave()<CR>
  inoremap <C-Q> <C-O>:call MyConfirmQuitAllNoSave()<CR>

  noremap <C-S> :update<CR>
  vnoremap <C-S> <ESC>:update<CR>
  cnoremap <C-S> <C-C>:update<CR>
  inoremap <C-S> <ESC>:update<CR>
  noremap <m-s> :update<CR>
  vnoremap <m-s> <ESC>:update<CR>
  cnoremap <m-s> <C-C>:update<CR>
  inoremap <m-s> <ESC>:update<CR>

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

  "   function Blah()
  "   python3 << EOF
  " from os.path import expanduser
  " f = open(expanduser('~') + '/.vim/.search', 'w')
  " # print f
  " w = vim.eval("l:word")
  " f.write(w)
  " f.close()
  " EOF
  " endfunction

  "" Following live in heirline for now
  " highlight DiffAdd guibg=#203520 guifg=NONE
  " highlight DiffChange guibg=#13292e guifg=NONE
  " " highlight DiffText guibg=#452250 guifg=NONE
  " highlight DiffDelete guibg=#30181a guifg=NONE
  highlight GitSignsChangeInline guibg=#302ee8 guifg=NONE gui=bold
  " FYI this style is only gonna get used in inline previews
  highlight GitSignsDeleteInline guibg=#68221a guifg=NONE gui=bold
  highlight GitSignsAddInline guibg=#30582e guifg=NONE gui=bold

  " highlight GitSignsAddLnInline guibg=#30ff2e guifg=NONE
  " highlight GitSignsChangeLnInline guibg=#0000ff guifg=NONE
  highlight GitSignsDeleteLnInline gui=underdouble guisp=#800000 guibg=NONE guifg=NONE
  " highlight GitSignsDeleteVirtLn guibg=NONE guifg=NONE
  " I wanted to make the fg of the deleted virt lines similar or darker than the comment style since it has to be made more subtle than that at least not to lead to some confusion. Do no specify a fg for all the other kind of styles like this so as to preserve syntax highlighting, but in virtual lines highlighting is not a possibility anyway.
  highlight GitSignsDeleteVirtLn guibg=#500000 guifg=#707070
  highlight GitSignsDeleteVirtLnInLine guibg=#700000 gui=strikethrough

  highlight WordUnderTheCursor gui=bold
  highlight IlluminatedWordText gui=bold
  highlight IlluminatedWordWrite gui=bold,underline
  highlight IlluminatedWordRead gui=bold

  highlight MatchParen guibg=#306868

  highlight StatusLineLineNo gui=bold

  noremap <silent> <C-H> :<c-u>call TmuxWindow('h')<CR>
  noremap <silent> <C-J> :<c-u>call TmuxWindow('j')<CR>
  noremap <silent> <C-K> :<c-u>call TmuxWindow('k')<CR>
  noremap <silent> <C-L> :<c-u>call TmuxWindow('l')<CR>

  noremap! <silent> <C-H> <ESC>:call TmuxWindow('h')<CR>
  noremap! <silent> <C-J> <ESC>:call TmuxWindow('j')<CR>
  noremap! <silent> <C-K> <ESC>:call TmuxWindow('k')<CR>
  noremap! <silent> <C-L> <ESC>:call TmuxWindow('l')<CR>

  nmap ` %
  vmap ` %
  omap ` %

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

  vmap S<CR> S<C-J>V2j=

  " Note gui=italic is what modern nvim seems to take, NOT cterm. likely related to 24bit color
  hi Comment cterm=italic gui=italic
  hi CopilotSuggestion gui=bold guibg=#202020

  nnoremap = :vertical res +5<CR>
  nnoremap - :vertical res -5<CR>
  nnoremap + :res +4<CR>
  nnoremap _ :res -4<CR>

  nnoremap <leader>f :NeoTreeRevealToggle<CR>
  nnoremap fg :Neotree float reveal_file=<cfile> reveal_force_cwd<cr>

  nnoremap <c-m-s> :SudaWrite<CR>

  " https://stackoverflow.com/a/75553217/340947
  let vimtmp = $HOME . '/.tmp/' . getpid()
  silent! call mkdir(vimtmp, "p", 0700)
  let &backupdir=vimtmp
  let &directory=vimtmp
  set backup

  " This is super neat text based refactor command which nvim shows you the preview replacement as you type
  " TODO i still need to find a better bind for this because it is hard to remember
  nnoremap <m-/> :%s/\<<c-r><c-w>\>//g<left><left>
  " The obvious but bad visual mode version of this
  " vnoremap <m-/> y:%s/<c-r>0//g<left><left>

  "" From https://stackoverflow.com/a/6171215/340947
  " Escape special characters in a string for exact matching.
  " This is useful to copying strings from the file to the search tool
  " Based on this - http://peterodding.com/code/vim/profile/autoload/xolox/escape.vim
  function! EscapeString (string)
    let string=a:string
    " Escape regex characters
    let string = escape(string, '^$.*\/~[]')
    " Escape the line endings
    let string = substitute(string, '\n', '\\n', 'g')
    return string
  endfunction

  " Get the current visual block for search and replaces
  " This function passed the visual block through a string escape function
  " Based on this - https://stackoverflow.com/questions/676600/vim-replace-selected-text/677918#677918
  function! GetVisual() range
    " Save the current register and clipboard
    let reg_save = getreg('"')
    let regtype_save = getregtype('"')
    let cb_save = &clipboard
    set clipboard&

    " Put the current visual selection in the " register
    normal! ""gvy
    let selection = getreg('"')

    " Put the saved registers and clipboards back
    call setreg('"', reg_save, regtype_save)
    let &clipboard = cb_save

    "Escape any special characters in the selection
    let escaped_selection = EscapeString(selection)

    return escaped_selection
  endfunction

  " Ctrl+R works well to mean "replace"
  vnoremap <c-r> <Esc>:%s/<c-r>=GetVisual()<cr>//g<left><left>

  " What's a bit funny is that we probably do not need a plugin to automate this across files because it's quite easy to hit colon up to fetch the replacement command back out
  " TODO Actually I think we can do it easily by finding those files and then specifying them in the command line just like we do with % but the real true solution is some kinda preview window

  " Fix home and end (Don't work; but I think I just need to convince tmux to emit other codes)
  " set t_kh=[1~
  " set t_@7=[4~

  "" This does not do anything here because our lua nvim config disables traditional vim syntax systems
  " command! SyntaxDetect :echom "hi<" . synIDattr(synID(line("."),col("."),1),"name") . '> trans<' . synIDattr(synID(line("."),col("."),0),"name") . "> lo<" . synIDattr(synIDtrans(synID(line("."),col("."),1)),"name") . ">"
  " These are for disabling the default middlemouse mouse paste action which is sometimes easily accidentally triggered (3-finger tap gesture)
  noremap <MiddleMouse> <LeftMouse>
  inoremap <MiddleMouse> <Nop>

  source $VIMRUNTIME/menu.vim
  set wildmenu
  set cpo-=<
  set wcm=<C-Z>
  map <F5> :emenu <C-Z>

  " windowswap config
  let g:windowswap_map_keys = 0
  nnoremap <m-w> :call WindowSwap#EasyWindowSwap()<CR>

  "" This enables the count and index indicator for search. Not enabled because we are using google/vim-searchindex and it does not limit to a count of 99
  " set shortmess-=S

  " an intuitive way to surround a selection with newlines
  vmap S<CR> S<C-J>V2j=

  " The visual search implementation. I haven't seen this in a plugin so I maintain it here slightly modified with my binds

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
  " if !hasmapto("<Plug>VLToggle")
  "   nmap <unique> <Leader>vl <Plug>VLToggle
  " endif
  let &cpo = s:save_cpo | unlet s:save_cpo
  " End impl of Search for selected text.


  " Ctrl+F for find -- tip on \v from
  " http://stevelosh.com/blog/2010/09/coming-home-to-vim/
  " May take some getting used to, but is generally saving on use of backslashes
  nnoremap <C-F> /\v
  inoremap <C-F> <ESC>/\v
  vnoremap <C-F> /\v
  nnoremap / /\v
  vnoremap / /\v


]])

-- CURRENTLY NOT WORKING AT ALL YET
_G.MoveToPrevTab = function()
  -- There is only one window
  if (#vim.api.nvim_list_tabpages()) == 1 and vim.api.nvim_win_get_number(0) == 1 then
    print "moveToPrevTab: Only one window. Doing nothing"
    return
  end

  -- Preparing new window
  local current_tabpage_number = vim.api.nvim_tabpage_get_number(0)
  local current_buf = vim.api.nvim_get_current_buf()

  if current_tabpage_number == 1 then
    -- Close current window
    vim.api.nvim_win_close(0, true)

    if current_tabpage_number == vim.api.nvim_tabpage_get_number(0) then
      -- Move to previous tabpage
      vim.api.nvim_set_current_tabpage(vim.api.nvim_tabpage_get_previous(0))
    end

    -- Open new window in current tabpage
    vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {relative='editor', row=0, col=0})
  else
    -- Close current window and create new tabpage
    vim.api.nvim_win_close(0, true)
    vim.api.nvim_command('tabnew')
  end

  -- Open current buffer in new window
  vim.api.nvim_set_current_buf(current_buf)
end

-- CURRENTLY THIS IS STILL NOT WORKING PROPERLY
_G.MoveToNextTab = function()
  -- there is only one window
  local tabpages = vim.api.nvim_list_tabpages()
  if (#tabpages) == 1 and vim.api.nvim_win_get_number(0) == 1 then
    print "MoveToNextTab: There is only one window, doing nothing"
    return
  end

  -- preparing new window
  local tab_nr = vim.api.nvim_tabpage_get_number(0) -- vim.fn.tabpagenr()
  local tab_nr_end = tabpages[#tabpages] -- vim.fn.tabpagenr("$")
  local cur_buf = vim.api.nvim_get_current_buf()
  
  log("tab_nr: ", tab_nr)
  log("tab_nr_end: ", tab_nr_end)

  if tab_nr ~= tab_nr_end then
    vim.api.nvim_command('close')
    if tab_nr == vim.fn.tabpagenr() then
      vim.api.nvim_command('tabnext')
    end
    vim.api.nvim_command('sp')
  else
    vim.api.nvim_command('close')
    vim.api.nvim_command('tabnew')
  end

  -- opening current buffer in new window
  vim.api.nvim_set_current_buf(cur_buf)
end

vim.api.nvim_set_keymap('n', '<Leader>t', '<Cmd>lua MoveToNextTab()<CR>', {noremap = true, silent = true})

-- yanking window to the next tab
vim.keymap.set("n", "ygT", "<cmd>lua MoveToPrevTab()<CR>")
vim.keymap.set("n", "ygt", "<cmd>lua MoveToNextTab()<CR>")

-- implements a smart I to insert at the front of the line but after the comment symbol if applicable
-- http://stackoverflow.com/a/22282505/340947
local is_comment_ts_hl = function()
  local hl = require'nvim-treesitter-playground.hl-info'.get_treesitter_hl()
  -- loop
  for _, v in ipairs(hl) do
    -- if any contain 'comment': typical values seen are: { "* **@error**", "* **@comment**", "* **@spell**", "* **@spell**" }
    if string.find(v, 'comment') then
      return true
    end
  end
  return false
end

_G.smart_insert_start_of_line = function()
  if is_comment_ts_hl() then
    vim.cmd[[normal! ^w]]
    vim.cmd[[startinsert]]
  else
    vim.api.nvim_feedkeys('I', 'n', true)
  end
end

vim.api.nvim_set_keymap('n', 'I', ':lua smart_insert_start_of_line()<CR>', {noremap = true, silent = true})

-- helpers
function string:split(delimiter)
  local result = {}
  local from = 1
  local delim_from, delim_to = string.find(self, delimiter, from)
  while delim_from do
    table.insert(result, string.sub(self, from, delim_from - 1))
    from = delim_to + 1
    delim_from, delim_to = string.find(self, delimiter, from)
  end
  table.insert(result, string.sub(self, from))
  return result
end

function table:print()
  for key, value in pairs(self) do
    print(key, value)
  end
end

function is_lazy_plugin_installed(plugin_name)
  local plugin_path = vim.fn.stdpath("data") .. "/lazy/" .. plugin_name
  return vim.fn.isdirectory(plugin_path) == 1
end

_G.write_to_file = function (content, file)
  local f = io.open(file, "w")
  f:write(content)
  f:close()
end

_G.log = function(...)
  local args = {...}
  local log_file_path = "/tmp/lua-nvim.log"
  local log_file = io.open(log_file_path, "a")
  if log_file == nil then
    print("Could not open log file: " .. log_file_path)
    return
  end
  io.output(log_file)
  io.write(string.format("%s:%03d", os.date("%H:%M:%S"), vim.loop.now() % 1000) .. " >>> ")
  for i, payload in ipairs(args) do
    local ty = type(payload)
    if ty == "table" then
      io.write(string.format("%d -> %s\n", i, vim.inspect(payload)))
    elseif ty == "function" then
      io.write(string.format("%d -> [function]\n", i))
    else
      io.write(string.format("%d -> %s\n", i, payload))
    end
  end
  io.close(log_file)
end

function _G.overwrite_file(payload, filename)
  local log_file_path = vim.env.HOME .. "/" .. filename
  local log_file = io.open(log_file_path, "w")
  log_file:write(payload)
  log_file:close()
end

-- gvar settings for plugins
vim.g.matchup_matchparen_offscreen = { method = "popup" }
vim.g.matchup_surround_enabled = 1
vim.g.matchup_matchparen_deferred = 1
vim.g.matchup_matchparen_hi_surround_always = 1
vim.g.matchup_transmute_enabled = 1

vim.opt.titlestring = "NVIM %f%h%m%r%w (%{tabpagenr()} of %{tabpagenr('$')})"

-- plugin settings
safeRequire("gitsigns").setup({
  on_attach = function (bufnr)
    local gs = package.loaded.gitsigns
    local function map(mode, l, r, opts)
      opts = opts or {}
      opts.buffer = bufnr
      vim.keymap.set(mode, l, r, opts)
    end
    map('n', ']c', function()
      if vim.wo.diff then return ']c' end
      vim.schedule(function() gs.next_hunk() end)
      return '<Ignore>'
    end, {expr=true, desc="Next Hunk"})

    map('n', '[c', function()
      if vim.wo.diff then return '[c' end
      vim.schedule(function() gs.prev_hunk() end)
      return '<Ignore>'
    end, {expr=true, desc="Prev Hunk"})

    -- toggle show deleted
    map('n', '<leader>d', function ()
      vim.schedule(function() gs.toggle_deleted() end)
      return '<Ignore>'
    end, {expr=true, desc="Toggle Show Deleted (GitSigns)"})
  end,
  diff_opts = {
    internal = true,
    -- linematch = 1
  },
  count_chars = {
    [1] = "₁",
    [2] = "₂",
    [3] = "₃",
    [4] = "₄",
    [5] = "₅",
    [6] = "₆",
    [7] = "₇",
    [8] = "₈",
    [9] = "₉",
    ["+"] = "₊",
  },
  signs = {
    add = { text = "+", show_count = true },
    change = { text = "│", show_count = true },
    delete = { text = "_", show_count = true },
    topdelete = { text = "‾", show_count = true },
    changedelete = { text = "~", show_count = true },
    untracked = { text = "┆" },
  },
  show_deleted = true,
  numhl = true, -- Toggle with `:Gitsigns toggle_numhl`
  linehl = false, -- Toggle with `:Gitsigns toggle_linehl`
  word_diff = true, -- Toggle with `:Gitsigns toggle_word_diff`
  current_line_blame = true, -- Toggle with `:Gitsigns toggle_current_line_blame`
  current_line_blame_opts = {
    virt_text = true,
    virt_text_pos = "eol", -- 'eol' | 'overlay' | 'right_align'
    delay = 400,
    ignore_whitespace = true,
  },
})

local tele_actions = safeRequire('telescope.actions')
safeRequire('telescope').setup{
  defaults = {
    mappings = {
      i = {
        -- remove me to get normal mode in telescope
        ["<esc>"] = tele_actions.close,
        ["<RightMouse>"] = tele_actions.close,
        -- clicking will not interpret the location of the click but mouse can be used with scroll to pick or cancel, which is a lot better than always dismissing and clicking through underneath
        ["<LeftMouse>"] = tele_actions.select_default,
        ["<ScrollWheelDown>"] = tele_actions.preview_scrolling_down,
        ["<ScrollWheelUp>"] = tele_actions.preview_scrolling_up,
      }
    },
    scroll_strategy = "limit",
    layout_config = {
      scroll_speed = 3
    },
  }
}
local telescope_builtin = safeRequire("telescope.builtin")
vim.keymap.set("n", "<c-p>", function ()
  telescope_builtin.find_files({ find_command = { 'fd', '--type', 'f' } })
end)
-- hard to believe ctrl+G was not already bound by vim
vim.keymap.set('n', '<c-g>', '<cmd>AdvancedGitSearch<CR>')
vim.keymap.set("n", "<leader>g", telescope_builtin.live_grep, { desc = "Telescope Live Grep" })
vim.keymap.set("n", "<leader><CR>", telescope_builtin.grep_string, { desc = "Telescope Grep String" })
vim.keymap.set("n", "<leader>m", telescope_builtin.man_pages, { desc = "Telescope Man Pages" })
vim.keymap.set("n", "<f6>", telescope_builtin.oldfiles, { desc = "Telescope Recent Files" })
vim.keymap.set("n", "<leader>b", telescope_builtin.buffers, { desc = "Telescope Buffers" })
-- "vim help"
vim.keymap.set('n', '<leader>h', telescope_builtin.help_tags, { desc = "Telescope Help Tags" })

safeRequire("nvim-lastplace").setup({})
safeRequire("nvim-autopairs").setup({ map_cr = false })
safeRequire("Comment").setup()

safeRequire("nvim-treesitter.configs").setup({
  -- A list of parser names, or "all" (the four listed parsers should always be installed)
  ensure_installed = { "c", "lua", "vim", "bash", "comment" },

  -- Install parsers synchronously (only applied to `ensure_installed`)
  sync_install = false,

  -- Automatically install missing parsers when entering buffer
  -- Recommendation: set to false if you don't have `tree-sitter` CLI installed locally
  auto_install = true,

  -- List of parsers to ignore installing (for "all")
  --- ignore_install = { "javascript" },

  ---- If you need to change the installation directory of the parsers (see -> Advanced Setup)
  -- parser_install_dir = "/some/path/to/store/parsers", -- Remember to run vim.opt.runtimepath:append("/some/path/to/store/parsers")!

  highlight = {
    -- `false` will disable the whole extension
    enable = true,

    -- NOTE: these are the names of the parsers and not the filetype. (for example if you want to
    -- disable highlighting for the `tex` filetype, you need to include `latex` in this list as this is
    -- the name of the parser)
    -- list of language that will be disabled
    --- disable = { "c", "rust" },

    -- Or use a function for more flexibility, e.g. to disable slow treesitter highlight for large files
    disable = function(lang, buf)
      local max_filesize = 100 * 1024 -- 100 KB
      local ok, stats = pcall(vim.loop.fs_stat, vim.api.nvim_buf_get_name(buf))
      if ok and stats and stats.size > max_filesize then
        return true
      end
    end,

    -- Setting this to true will run `:h syntax` and tree-sitter at the same time.
    -- Set this to `true` if you depend on 'syntax' being enabled (like for indentation).
    -- Using this option may slow down your editor, and you may see some duplicate highlights.
    -- Instead of true it can also be a list of languages
    additional_vim_regex_highlighting = false,
  },
  indent = {
    enable = true,
    disable = { "python", "lua" },
  },
  -- incremental_selection = {
  --   enable = true,
  --   keymaps = {
  --     init_selection = "<leader>v", -- set to `false` to disable one of the mappings
  --     node_incremental = "<right>",
  --     scope_incremental = "<up>",
  --     node_decremental = "<left>",
  --   },
  -- },
  matchup = {
    enable = true, -- mandatory, false will disable the whole extension
    disable = {}, -- optional, list of language that will be disabled
  },

  textobjects = {
    swap = {
      -- disabled because using STS for swaps
      enable = false,
      swap_next = {
        ["]]"] = "@parameter.inner",
      },
      swap_previous = {
        ["[["] = "@parameter.inner",
      },
    },
    select = {
      enable = true,

      -- Automatically jump forward to textobj, similar to targets.vim
      lookahead = true,

      keymaps = {
        -- You can use the capture groups defined in textobjects.scm
        ["af"] = "@function.outer",
        ["if"] = "@function.inner",
        ["ac"] = "@class.outer",
        ["ia"] = "@parameter.inner",
        ["aa"] = "@parameter.outer",
        ["/"] = "@comment.outer",
        -- You can optionally set descriptions to the mappings (used in the desc parameter of
        -- nvim_buf_set_keymap) which plugins like which-key display
        ["ic"] = { query = "@class.inner", desc = "Select inner part of a class region" },
        -- You can also use captures from other query groups like `locals.scm`
        ["as"] = { query = "@scope", query_group = "locals", desc = "Select language scope" },
      },
      -- You can choose the select mode (default is charwise 'v')
      --
      -- Can also be a function which gets passed a table with the keys
      -- * query_string: eg '@function.inner'
      -- * method: eg 'v' or 'o'
      -- and should return the mode ('v', 'V', or '<c-v>') or a table
      -- mapping query_strings to modes.
      selection_modes = {
        ["@parameter.outer"] = "v", -- charwise
        ["@function.outer"] = "V", -- linewise
        ["@class.outer"] = "<c-v>", -- blockwise
      },
      -- If you set this to `true` (default is `false`) then any textobject is
      -- extended to include preceding or succeeding whitespace. Succeeding
      -- whitespace has priority in order to act similarly to eg the built-in
      -- `ap`.
      --
      -- Can also be a function which gets passed a table with the keys
      -- * query_string: eg '@function.inner'
      -- * selection_mode: eg 'v'
      -- and should return true of false
      include_surrounding_whitespace = true,
    },
  },

  -- let's see if textsubjects works well enough for my needs. so far seems like whitespace heuristics may be nice to have.
  -- textsubjects = {
  --   enable = true,
  --   prev_selection = ',', -- (Optional) keymap to select the previous selection
  --   keymaps = {
  --     ['<cr>'] = 'textsubjects-smart',
  --     ["'"] = 'textsubjects-container-outer',
  --     [';'] = 'textsubjects-container-inner',
  --   },
  -- },
})

safeRequire("trouble").setup({
  -- your configuration comes here
  -- or leave it empty to use the default settings
  -- refer to the configuration section below
})

safeRequire("neo-tree").setup({
  auto_clean_after_session_restore = true, -- Automatically clean up broken neo-tree buffers saved in sessions
  close_if_last_window = true,
  sort_case_insensitive = true,
  filesystem = {
    follow_current_file = true,
    use_libuv_file_watcher = true,
    filtered_items = {
      visible = true, -- This is what you want: If you set this to `true`, all "hide" just mean "dimmed out"
      hide_dotfiles = false,
      hide_gitignored = true,
    },
  },
  source_selector = {
    winbar = true,
    statusline = false
  },
  -- log_level = "trace",
  -- log_to_file = true,
  --- below is not working unknown reason https://github.com/nvim-neo-tree/neo-tree.nvim/issues/486
  event_handlers = {
    {
      event = "neo_tree_buffer_enter",
      custom = "my custom handler",
      handler = function ()
        vim.cmd([[
          " echom "neotree enter buf"
          setlocal wrap
        ]])
      end
    }
  }
})

vim.cmd([[ 
  set cursorline
]])

safeRequire("colorizer").setup()

-- general plugin specific binds (TODO: put together when refactoring the plugin configs into files)
vim.keymap.set("n", "<leader>y", safeRequire("osc52").copy_operator, { expr = true, desc = "Copy to host term system clipboard via OSC 52" })
vim.keymap.set("n", "<leader>yy", "<leader>c_", { remap = true, desc = "Copy entire line to host term system clipboard via OSC 52" })
vim.keymap.set("x", "<leader>y", safeRequire("osc52").copy_visual, { desc = "Copy visual selection to host term system clipboard via OSC 52" })

-- We can explicitly use the server's own clipboard or fallback clipboard file if we somehow know
-- that we want the buffer that's in there.
-- nnoremap <Leader>p :read !pbpaste<CR>
vim.keymap.set("n", "<leader>p", ":read !pbpaste<CR>", { desc = "Paste from pbpaste" })
vim.keymap.set("v", "<leader>p", ":!pbpaste<CR>", { desc = "Paste from pbpaste" })

-- do not use read here so that the selected stuff gets slurped.
-- vnoremap <Leader>p :!pbpaste<CR>

-- lspconfig
-- set border
-- local _border = "rounded"

-- vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(
--   vim.lsp.handlers.hover, {
--     border = _border
--   }
-- )

-- vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(
--   vim.lsp.handlers.signature_help, {
--     border = _border
--   }
-- )
--
-- vim.diagnostic.config{
--   float={border=_border}
-- }

-- vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, { desc = "Open diagnostic in float" })
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Go to previous diagnostic" })
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Go to next diagnostic" })
-- vim.keymap.set("n", "<leader>q", vim.diagnostic.setloclist, { desc = "Set diagnostics to location list" })

-- indent-blankline

vim.opt.list = true
-- opting to not use eol since it's too noisy looking imo
-- "eol:↴"
vim.opt.listchars = "tab:→ ,extends:»,precedes:«,trail:·,nbsp:◆"

vim.cmd("highlight IndentBlanklineContextChar guifg=#66666f gui=nocombine")
vim.cmd("highlight IndentBlanklineContextStart gui=underdouble guisp=#66666f")
vim.cmd("highlight IndentBlanklineIndent1 gui=nocombine guifg=#383838")
vim.cmd("highlight IndentBlanklineIndent2 gui=nocombine guifg=#484848")
safeRequire("indent_blankline").setup({
  char = "▏",
  char_highlight_list = {
    "IndentBlanklineIndent1",
    "IndentBlanklineIndent2",
  },
  context_char = "▏",
  space_char_blankline = " ",
  show_end_of_line = true, -- no effect while eof not put in listchars.
  show_current_context = true,
  show_current_context_start = true,
})


vim.opt.completeopt="menu,menuone,noselect"

local cmp = safeRequire'cmp'
local lspkind = safeRequire('lspkind')


local has_words_before = function()
  local line, col = unpack(vim.api.nvim_win_get_cursor(0))
  return col ~= 0 and vim.api.nvim_buf_get_lines(0, line - 1, line, true)[1]:sub(col, col):match("%s") == nil
end

cmp.setup({
  formatting = {
    format = lspkind.cmp_format({
      mode = 'symbol_text',
      maxwidth = 50, -- prevent the popup from showing more than provided characters (e.g 50 will not show more than 50 characters)
      ellipsis_char = '…', -- when popup menu exceed maxwidth, the truncated part would show ellipsis_char instead (must define maxwidth first)

      -- The function below will be called before any actual modifications from lspkind
      -- so that you can provide more controls on popup customization. (See [#30](https://github.com/onsails/lspkind-nvim/pull/30))
      -- before = function (entry, vim_item)
      --   ...
      --   return vim_item
      -- end
    })
  },

  window = {
    -- completion = cmp.config.window.bordered(),
    -- documentation = cmp.config.window.bordered(),
  },
  mapping = cmp.mapping.preset.insert({
    ['<C-b>'] = cmp.mapping.scroll_docs(-4),
    ['<C-f>'] = cmp.mapping.scroll_docs(4),
    --- removing c-space from cmp behavior to make room for it for copilot
    -- ['<C-Space>'] = cmp.mapping.complete(),
    ['<C-e>'] = cmp.mapping.abort(),
    ["<CR>"] = cmp.mapping.confirm({
      behavior = cmp.ConfirmBehavior.Replace,
      select = false,
    }),
    ["<Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_next_item()
      -- You could replace the expand_or_jumpable() calls with expand_or_locally_jumpable() 
      -- they way you will only jump inside the snippet region
      -- elseif luasnip.expand_or_jumpable() then
      --   luasnip.expand_or_jump()
      elseif has_words_before() then
        cmp.complete()
      else
        fallback()
      end
    end, { "i", "s" }),

    ["<S-Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_prev_item()
      -- elseif luasnip.jumpable(-1) then
      --   luasnip.jump(-1)
      else
        fallback()
      end
    end, { "i", "s" }),
  }),
  sources = cmp.config.sources({
    { name = 'nvim_lsp' },
    -- { name = 'vsnip' }, -- For vsnip users.
    -- { name = 'luasnip' }, -- For luasnip users.
    -- { name = 'ultisnips' }, -- For ultisnips users.
    -- { name = 'snippy' }, -- For snippy users.
    { name = 'buffer' },
    { name = 'path',
      option = {
        -- Options go into this table
      },
    },
    { name = 'nvim_lsp_signature_help' },
  })
})

-- Set configuration for specific filetype.
cmp.setup.filetype('gitcommit', {
  sources = cmp.config.sources({
    { name = 'cmp_git' }, -- You can specify the `cmp_git` source if you were installed it.
  }, {
    { name = 'buffer' },
  })
})

-- Use buffer source for `/` and `?` (if you enabled `native_menu`, this won't work anymore).
-- -- disabling the search cmp completion to see if the search history problem is related to this; completions from buffer in here are not valuable honestly
-- cmp.setup.cmdline({ '/', '?' }, {
--   mapping = cmp.mapping.preset.cmdline(),
--   completion = {
--     -- only start completion after typing 3 chars
--     keyword_length = 3,
--   },
--   sources = cmp.config.sources({
--     { name = 'buffer' }
--   })
-- })

-- Use cmdline & path source for ':' (if you enabled `native_menu`, this won't work anymore).
cmp.setup.cmdline(':', {
  mapping = cmp.mapping.preset.cmdline(),
  completion = {
    -- only start completion after typing 3 chars
    keyword_length = 2,
  },
  sources = cmp.config.sources({
    { name = 'path' }
  }, {
    { name = 'cmdline' }
  })
})

-- insert `(` after select function or method item
local cmp_autopairs = safeRequire('nvim-autopairs.completion.cmp')
cmp.event:on(
  'confirm_done',
  cmp_autopairs.on_confirm_done()
)

safeRequire("neodev").setup({
  -- add any options here, or leave empty to use the default settings
})

safeRequire("mason").setup({})
safeRequire("mason-lspconfig").setup({
  -- A list of servers to automatically install if they're not already installed. Example: { "rust_analyzer@nightly", "lua_ls" }
  -- This setting has no relation with the `automatic_installation` setting.
  ensure_installed = {
    "clangd", "lua_ls"
  },

  -- Whether servers that are set up (via lspconfig) should be automatically installed if they're not already installed.
  -- This setting has no relation with the `ensure_installed` setting.
  -- Can either be:
  --   - false: Servers are not automatically installed.
  --   - true: All servers set up via lspconfig are automatically installed.
  --   - { exclude: string[] }: All servers set up via lspconfig, except the ones provided in the list, are automatically installed.
  --       Example: automatic_installation = { exclude = { "rust_analyzer", "solargraph" } }
  automatic_installation = true,
})

local null_ls = safeRequire("null-ls")

safeRequire("mason-null-ls").setup({
  ensure_installed = { "shellcheck" },
  automatic_setup = true,
  handlers = {
    function(source_name, methods)
      -- print("mason-null-ls-handler: source_name:" .. source_name)
      -- print("mason-null-ls-handler: methods:" .. vim.inspect(methods))
      -- all sources with no handler get passed here

      -- To keep the original functionality of `automatic_setup = true`,
      -- please add the below.
      safeRequire("mason-null-ls.automatic_setup")(source_name, methods)
    end,
    pylint = function (source_name, methods)
      -- need to set PYTHONPATH via --source-roots
      null_ls.register(null_ls.builtins.diagnostics.pylint.with({
        env = function(params)
          local computed_pythonpath = vim.fn.system('python3 -c "import site; print(site.getsitepackages()[0])"')
          local resolved_symlink = vim.fn.system('readlink -f ' .. computed_pythonpath):gsub("\n$", "")
          print ('null-ls pylint pythonpath', resolved_symlink)
          return { PYTHONPATH = resolved_symlink }
        end,
      }))
    end,
    cspell = function(source_name, methods)
      null_ls.register(null_ls.builtins.diagnostics.cspell.with({
        timeout = 20000,
        method = null_ls.methods.DIAGNOSTICS_ON_SAVE,
      }))
    end,

    -- stylua = function(source_name, methods)
    --   null_ls.register(null_ls.builtins.formatting.stylua)
    -- end,
  }
})

null_ls.setup({
  debug = true,
  -- this is for cspell to default to hints and not errors (yeesh)
  fallback_severity = vim.diagnostic.severity.HINT,
  sources = {
    null_ls.builtins.code_actions.gitsigns,
  }
})

local capabilities = safeRequire('cmp_nvim_lsp').default_capabilities()

-- oh man written by GPT4
local function deep_copy(tbl)
    local copy = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            copy[k] = deep_copy(v)
        else
            copy[k] = v
        end
    end
    return copy
end

local ext = function(table, key, value)
  local tbl = deep_copy(table)
  tbl[key] = value
  return tbl
end

vim.keymap.set('n', '?', vim.lsp.buf.hover)

-- local goto_preview = safeRequire('goto-preview')

local trouble = require('trouble')
-- keymaps!!
local lsp_attach = function (x, bufnr)
  local engine = x.name;
  log("lsp_attach:" .. engine .. "bufnr=" .. bufnr)
  local bufopts = { noremap=true, silent=true, buffer=bufnr }
  vim.keymap.set('n', 'gD', '<cmd>TroubleToggle lsp_type_definitions<cr>', ext(bufopts, "desc", "Go to Type Definition (Trouble UI)"))
  vim.keymap.set('n', 'gd', '<cmd>TroubleToggle lsp_definitions<cr>', ext(bufopts, "desc", "Go to Definition (preview window)"))
  -- vim.keymap.set('n', 'gi', goto_preview.goto_preview_implementation, ext(bufopts, "desc", "Go to Implementation (preview window)"))
  -- mnemonic is "args"
  vim.keymap.set('n', '<leader>a', vim.lsp.buf.signature_help, ext(bufopts, "desc", "Signature help"))
  -- vim.keymap.set('n', '<space>wa', vim.lsp.buf.add_workspace_folder, bufopts)
  -- vim.keymap.set('n', '<space>wr', vim.lsp.buf.remove_workspace_folder, bufopts)
  -- vim.keymap.set('n', '<space>wl', function()
  --   print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
  -- end, bufopts)
  -- vim.keymap.set('n', '<space>D', vim.lsp.buf.type_definition, bufopts)
  vim.keymap.set('n', '<leader>r', vim.lsp.buf.rename, ext(bufopts, "desc", "Rename"))
  vim.keymap.set('n', '<leader>ca', function() vim.cmd('CodeActionMenu') end, ext(bufopts, "desc", "Code Action Menu"))
  vim.keymap.set('n', 'gr', '<cmd>TroubleToggle lsp_references<cr>', ext(bufopts, "desc", "Go to References"))
  vim.keymap.set('n', '<leader>=', function() vim.lsp.buf.format { async = true } end, ext(bufopts, "desc", "Format Buffer"))
end

safeRequire("mason-lspconfig").setup_handlers {
  -- The first entry (without a key) will be the default handler
  -- and will be called for each installed server that doesn't have
  -- a dedicated handler.
  function (server_name) -- default handler (optional)
    safeRequire("lspconfig")[server_name].setup {
      capabilities = capabilities,
      on_attach = lsp_attach,
    }
  end,
  -- Next, you can provide a dedicated handler for specific servers. Don't forget to bring capabilities and on_attach in.
  ["dockerls"] = function ()
    -- print("dockerls caps =" .. vim.inspect(capabilities))
    safeRequire("lspconfig")["dockerls"].setup {
      capabilities = capabilities,
      on_attach = lsp_attach,
    }
  end,
  ["lua_ls"] = function ()
    safeRequire("lspconfig")["lua_ls"].setup {
      capabilities = capabilities,
      on_attach = lsp_attach,
      settings = {
        Lua = {
          completion = {
            callSnippet = "Replace"
          },
          workspace = {
            -- library = vim.api.nvim_get_runtime_file('', true),
            checkThirdParty = false, -- THIS IS THE IMPORTANT LINE TO ADD
          },
        }
      }
    }
  end
}

safeRequire("yanky").setup({
  highlight = {
    on_put = true,
    on_yank = true,
    timer = 1000,
  },
})
vim.keymap.set({"n","x"}, "p", "<Plug>(YankyPutAfter)")
vim.keymap.set({"n","x"}, "P", "<Plug>(YankyPutBefore)")
--- commenting these out because i'm never ever going to remember to use them
-- vim.keymap.set({"n","x"}, "gp", "<Plug>(YankyGPutAfter)")
-- vim.keymap.set({"n","x"}, "gP", "<Plug>(YankyGPutBefore)")
-- yankring
vim.keymap.set("n", "<c-u>", "<Plug>(YankyCycleForward)")
vim.keymap.set("n", "<c-y>", "<Plug>(YankyCycleBackward)")
-- Search highlight
vim.cmd([[
  hi YankyPut guibg=#2f9366 gui=bold cterm=bold
  hi YankyYanked guibg=#2e5099 gui=bold cterm=bold

  hi Search cterm=bold ctermfg=black ctermbg=yellow guibg=#a9291a guifg=NONE
  hi IncSearch cterm=bold ctermfg=black ctermbg=cyan guibg=#f04050 guifg=NONE gui=NONE
  hi Visual term=reverse ctermbg=238 guibg=#504050
  hi NormalFloat guibg=#404060

  " pane/window split style: only vertical split style matters in vim since horizontal splits are made of statuslines.
  hi VertSplit guifg=#505760

  hi TSPlaygroundFocus guibg=#2f628e
]])

-- for conflict-marker
vim.cmd([[ 
  " disable the default highlight group
  let g:conflict_marker_highlight_group = ''

  " Include text after begin and end markers
  let g:conflict_marker_begin = '^<<<<<<< .*$'
  let g:conflict_marker_end   = '^>>>>>>> .*$'

  highlight ConflictMarkerBegin guibg=#2f7366
  highlight ConflictMarkerOurs guibg=#2e5049
  highlight ConflictMarkerTheirs guibg=#344f69
  highlight ConflictMarkerEnd guibg=#2f628e
  highlight ConflictMarkerCommonAncestorsHunk guibg=#754a81
]])

vim.keymap.set("n", "<F4>", ":UndotreeToggle<CR>")
vim.keymap.set("i", "<F4>", "<Esc>:UndotreeToggle<CR>")

vim.keymap.set("n", "<leader>t", ":Trouble document_diagnostics<CR>")
vim.keymap.set("n", "<leader>T", ":Trouble workspace_diagnostics<CR>")

-- set the icons for diagnostic
vim.cmd [[
  sign define DiagnosticSignError text=✘  linehl= texthl=DiagnosticSignError numhl=
  sign define DiagnosticSignWarn text= linehl= texthl=DiagnosticSignWarn numhl= 
  sign define DiagnosticSignInfo text=  linehl= texthl=DiagnosticSignInfo numhl= 
  sign define DiagnosticSignHint text=⚑  linehl= texthl=DiagnosticSignHint numhl=
]]

-- helper for stevearc/profile.nvim
-- local should_profile = os.getenv("NVIM_PROFILE")
-- if should_profile then
--   require("profile").instrument_autocmds()
--   if should_profile:lower():match("^start") then
--     require("profile").start("*")
--   else
--     require("profile").instrument("*")
--   end
-- end
--
-- local function toggle_profile()
--   local prof = require("profile")
--   if prof.is_recording() then
--     prof.stop()
--     vim.ui.input({ prompt = "Save profile to:", completion = "file", default = "profile.json" }, function(filename)
--       if filename then
--         prof.export(filename)
--         vim.notify(string.format("Wrote %s", filename))
--       end
--     end)
--   else
--     prof.start("*")
--   end
-- end
-- vim.keymap.set("", "<f1>", toggle_profile)


safeRequire('treesitter-context').setup{
  enable = true, -- Enable this plugin (Can be enabled/disabled later via commands)
  max_lines = 0, -- How many lines the window should span. Values <= 0 mean no limit.
  min_window_height = 0, -- Minimum editor window height to enable context. Values <= 0 mean no limit.
  line_numbers = true,
  multiline_threshold = 20, -- Maximum number of lines to collapse for a single context line
  trim_scope = 'inner', -- Which context lines to discard if `max_lines` is exceeded. Choices: 'inner', 'outer'
  mode = 'topline',  -- Line used to calculate context. Choices: 'cursor', 'topline'
  -- Separator between context and content. Should be a single character string, like '-'.
  -- When separator is set, the context will only show up when there are at least 2 lines above cursorline.
  separator = nil,
  zindex = 20, -- The Z-index of the context window
}

-- nvim-spider
vim.keymap.set({"n", "o", "x"}, "w", "<cmd>lua require('spider').motion('w')<CR>", { desc = "Spider-w (hit sub words, skip to word chars)" })
vim.keymap.set({"n", "o", "x"}, "e", "<cmd>lua require('spider').motion('e')<CR>", { desc = "Spider-e (hit sub words, skip to word chars)" })
vim.keymap.set({"n", "o", "x"}, "<BS>", "<cmd>lua require('spider').motion('b')<CR>", { desc = "Spider-b (hit sub words, skip to word chars)" })
-- normally there is a ge map but i never use ge and don't see it in the future either.

-- Syntax Tree Surfer
local sts = safeRequire('syntax-tree-surfer')
if sts then sts.setup({
  -- icon_dictionary = {
  --   ["if_statement"] = "",
  --   ["else_clause"] = "",
  --   ["else_statement"] = "",
  --   ["elseif_statement"] = "",
  --   ["for_statement"] = "ﭜ",
  --   ["while_statement"] = "ﯩ",
  --   ["switch_statement"] = "ﳟ",
  --   ["function"] = "",
  --   ["function_definition"] = "",
  --   ["variable_declaration"] = "",
  -- },
}) end

-- local opts = {noremap = true, silent = true}
local opts = {noremap = true} -- delete me later

-- Normal Mode Swapping:
-- Swap The Master Node relative to the cursor with it's siblings, Dot Repeatable
vim.keymap.set("n", "{", function()
	vim.opt.opfunc = "v:lua.STSSwapUpNormal_Dot"
	return "g@l"
end, { silent = true, expr = true })
vim.keymap.set("n", "}", function()
	vim.opt.opfunc = "v:lua.STSSwapDownNormal_Dot"
	return "g@l"
end, { silent = true, expr = true })
-- Swap Current Node at the Cursor with it's siblings, Dot Repeatable
vim.keymap.set("n", "]]", function()
	vim.opt.opfunc = "v:lua.STSSwapCurrentNodeNextNormal_Dot"
	return "g@l"
end, { silent = true, expr = true })
vim.keymap.set("n", "[[", function()
	vim.opt.opfunc = "v:lua.STSSwapCurrentNodePrevNormal_Dot"
	return "g@l"
end, { silent = true, expr = true })
--
-- --> If the mappings above don't work, use these instead (no dot repeatable)
-- -- vim.keymap.set("n", "vd", '<cmd>STSSwapCurrentNodeNextNormal<cr>', opts)
-- -- vim.keymap.set("n", "vu", '<cmd>STSSwapCurrentNodePrevNormal<cr>', opts)
-- -- vim.keymap.set("n", "vD", '<cmd>STSSwapDownNormal<cr>', opts)
-- -- vim.keymap.set("n", "vU", '<cmd>STSSwapUpNormal<cr>', opts)
--
-- -- Visual Selection from Normal Mode
vim.keymap.set("n", "vx", '<cmd>STSSelectMasterNode<cr>', opts)
vim.keymap.set("n", "vn", '<cmd>STSSelectCurrentNode<cr>', opts)
--
-- Select Nodes in Visual Mode
vim.keymap.set("x", "<Down>", '<cmd>STSSelectNextSiblingNode<cr>', opts)
vim.keymap.set("x", "<Up>", '<cmd>STSSelectPrevSiblingNode<cr>', opts)
vim.keymap.set("x", "<Left>", '<cmd>STSSelectParentNode<cr>', opts)
vim.keymap.set("x", "<Right>", '<cmd>STSSelectChildNode<cr>', opts)

-- Swapping Nodes in Visual Mode
vim.keymap.set("x", "<C-Down>", '<cmd>STSSwapNextVisual<cr>', opts)
vim.keymap.set("x", "<C-Up>", '<cmd>STSSwapPrevVisual<cr>', opts)

-- end of Syntax Tree Surfer

-- putting here late so log global is present for it
safeRequire("heirline_conf.heirline")

