-- -- -- TODO LIST

-- - short term for STS: work out how to delete/paste items automating handling
-- and placement of delimiters, handling inclusion of boundary bracket chars, etc.
-- I guess the latter can be handled by having a way to expand to all siblings
-- though. This may have impact on the next work.
-- - improve STS to contantly set highlights to preview what the parent and
-- sibling nodes are? track the last child node? abandon visual mode? Not sure.
-- - for STS: evaluate if it is more intuitive for both parent/child and sibling
-- movements to use up/down directionals rather than have siblings be left/right.
-- I guess the main issue here is evicting other key binds...
-- - find for most common languages a workflow to autoformat them, which is going
-- to solve the indent related niggles that remain
-- - explore the alternative to composer (live-command.nvim previews macros and
-- other stuff) (there is also nvim-neoclip)
-- - make the i_I custom behavior i have dot-repeatable (i tried with gpt4 and failed)
-- - get a better profiler tool and figure out why this file is sluggish (got perfanno and it is kind of pretty cool, but
-- see if there are any other better profilers)
-- - look into resolving wezterm performance issues (https://github.com/wez/wezterm/discussions/3664) and move away from
-- alacritty/windows term/possibly eliminate tmux
-- - reorganize the config into separate source files grouped by functionality
-- - LOW still want that one key to cycle windows and then tabs, even while trying to make the ctrl-w w, gt defaults --
-- for now this is done with tab and shift tab and i might just keep this honestly, because the behavior of going to the
--   next tab when at the last window didnt really work that intuitively. - (IMPL'd but broken) yank window to new tab in
--   next/prev direction or into new tab (also like how this is consistent with how the analogous one works in tmux)
-- - my prized alt-, and friends automations (to be fair i've been getting good at manually leveraging dot-repeat which is
-- decently good retraining) (for this one i think i should look into the newer knowledge i now have for being able to
-- customize dot repeat? or nah...)
-- - DONE via alt+p. Also, paste mode is deprecated now. \p for toggle paste and removing indent markers and stuff like
-- that in paste mode to make it work like a copy-mode
-- - f10 handling for tmux (amazing though, i got this far without it, maybe i dont want to integrate from vim to tmux...)
-- 
-- - implement insert mode ctrl arrows to do big word hops (backspace does a small word hop)
-- - (super low prio) implement semantic highlight removal (i want this in possibly lua right now but also definitely
-- dockerfile) by literally selecting them out at the highlight group level (ah dang, no worky for dockerls)
-- - see if i can get trouble to show a list of just a type of severity of diag. hook to click on section. This might not
-- be easily doable but if i can programmatically fetch the list i can just try to focus on the first of that type.
-- - I THINK I DID THIS add update field back to heirline for diags' flexible entries.
-- - NOT SURE IF THING figure out why dockerls capabilities doesn't include semantic tokens
-- - highlight with a salient background the active window in nvim
-- - also toggle the showbreak on alt p

-- traditional settings

vim.o.title         = true
vim.o.number        = true
vim.o.undofile      = true
vim.o.undodir       = vim.env.HOME .. "/.tmp"
vim.o.termguicolors = true
vim.o.ignorecase    = true
vim.o.smartcase     = true
vim.o.tabstop       = 4
vim.o.numberwidth   = 3
-- vim.o.cmdheight  = 0
vim.o.updatetime    = 300 -- useful for non-plugin word highlight
vim.o.mousescroll   = 'ver:3,hor:3'
vim.o.showbreak     = "→ "
vim.o.linebreak     = true
vim.o.breakindent   = false
vim.o.textwidth     = 120
vim.o.colorcolumn   = "+1"

vim.cmd('autocmd BufEnter * set formatoptions-=ro | set formatoptions+=n')
vim.cmd('autocmd BufEnter * setlocal formatoptions-=ro | setlocal formatoptions+=n')

-- settings that may require inclusion prior to Lazy loader

-- init lazy.nvim plugin loader
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "git@github.com:folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end

vim.opt.rtp:prepend(lazypath)

local function safeRequire(module)
  local success, res = pcall(require, module)
  if success then return res end
  vim.api.nvim_err_writeln("safeRequire caught an error while loading " .. module .. ", error: " .. res)
  return { setup = function() end, load_extension = function() end }
end

-- plugins
require("lazy").setup("plugins", {
  checker = { enabled = true, notify = false, },
  git = {
    url_format = "git@github.com:%s.git",
  }
})

-- vim.cmd.colorscheme 'midnight'

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

-- Remember: I map at the terminal level ctrl+BS, alt/opt+BS both to ^[^?, so binds should use
-- <m-bs>. I'm not sure how this works on windows terminal as well, but it does. It implements a
-- stronger normal mode move back via backspace
vim.keymap.set("n", "<M-BS>", "B")
-- word delete. Note that <Cmd>normal db does NOT work because exiting normal mode puts the cursor at the wrong spot
vim.keymap.set("i", "<M-BS>", "<C-W>")
-- command mode word delete
vim.keymap.set('c', "<M-BS>", '<C-W>', {noremap = true})

-- navigation keys (meta and ctrl will just do the same since i'm used to that)
-- note, cmd+left and right i have mapped to home and end at the terminal level usually
vim.keymap.set({'i', 'n'}, '<M-Left>', '<C-Left>')
vim.keymap.set({'i', 'n'}, '<M-Right>', '<C-Right>')

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
-- vim.keymap.set("i", "<c-b>", "<esc>lve")
vim.keymap.set("i", "<m-b>", "<esc>lve") -- also for some reason my muscle memory is for the alt version of this. sucks. let's actually free the ctrl b for something else then...
vim.keymap.set("i", "<c-b>", "<esc>lve") -- well i can't really free it since in my mind this is all ctrlb does in insert mode

-- Joining lines with Ctrl+N. Keep cursor stationary.
vim.keymap.set("n", "<c-n>", function()
  local line, col = unpack(vim.api.nvim_win_get_cursor(0))
  -- print("win_get_cursor: "..vim.inspect(vim.api.nvim_win_get_cursor(0)).. " Unpacks to "..line..","..col)
  vim.cmd("normal! J")
  vim.api.nvim_win_set_cursor(0, { line, col })
end)

-- Join lines selected in visual mode with Ctrl+N.
vim.keymap.set("v", "<c-n>", ":join<cr>`<")

-- run par to format selected region. useful probably only for comments.
vim.keymap.set("v", "<c-p>", ':!par rTbgqR "B=.,?\'_A_a_@" "Q=_s>|" w100 <cr>')

-- make alt+p (historical reason: used to toggle paste mode) toggle in unison the indent markers and the listchars. Key the state off of the indent-blankline toggle state.
vim.keymap.set("n", "<m-p>", function()
  local indent_blankline_enabled = vim.g.indent_blankline_enabled
  if vim.wo.number then
    vim.g.indent_blankline_enabled = false
    vim.cmd[[IBLDisable]]
    vim.wo.list = false
    vim.wo.number = false
    -- a bit tricky: toggle signs off
    vim.wo.signcolumn = "no"
    vim.wo.showbreak = ""
  else
    vim.cmd[[IBLEnable]]
    vim.wo.list = true
    vim.wo.number = true
    vim.wo.signcolumn = "auto"
    vim.wo.showbreak = "→ "
  end
end)

vim.api.nvim_create_user_command("DiffChanged", ":w! /tmp/cur-vim-buf | :split term://sift % /tmp/cur-vim-buf", {})

-- need to come up with a way to let q quit terminal when it has exited. oh well iq is not too bad right now

-- a bind to let me clear the file and leave in insert mode
vim.keymap.set("n", "<leader>C", ":%d<cr>i")

-- make it easier to type a colon
vim.keymap.set("n", ";", ":")

-- make paste not move the cursor
vim.keymap.set("n", "P", "P`[")

-- turn F10 into escape
vim.keymap.set({ "v", "i", "s" }, "<F10>", "<esc>") -- Applies to modes nvois, v should inlude s, but seems to not
vim.keymap.set({ "c" }, "<F10>", "<c-c>")

-- normal and visual mode backspace does what b does
-- disabled for nvim-spider
-- vim.keymap.set({ "n", "v" }, "<bs>", "b")
-- consistency with pagers in normal mode
vim.keymap.set({ "n", "v" }, " ", "<c-d>")
vim.keymap.set({ "n", "v" }, "b", "<c-u>")

----- the below is better to just leave as-is for original B behavior. the <BS> is what does b...
-- vim.keymap.set({ "n", "v" }, "B", "b")

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

-- combination next and repeat
function enhanced_dot(count)
  local poscursor = vim.fn.getpos('.')
  local hlsearchCurrent = vim.v.hlsearch
  local c = count
  local searchInfo = vim.fn.searchcount({maxcount = 9999})
  local ct = searchInfo.total

  vim.fn.setpos('.', poscursor)
  if (c == '' and hlsearchCurrent == 1) then
    c = ct
    vim.cmd('echom "running dot '..c..' times (all matches)..."')
  elseif c == '' then
    vim.cmd('echom "put search on to run dot on all matches. aborting"')
    return
  end
  if ct < c then
    vim.cmd('echom "found fewer matches than requested ('..c..'), running only '..ct..' times"')
    c = ct
  end
  while c > 0 do
    if hlsearchCurrent == 1 then
      vim.cmd("silent! normal n")
      vim.cmd("normal .$zz")
    else
      vim.cmd("normal .j")
    end
    c = c - 1
  end
end

vim.api.nvim_set_keymap('n', '<M-.>', ":lua enhanced_dot(vim.v.count1)<CR>", { noremap = true })
vim.api.nvim_set_keymap('n', '<M->>', ":lua enhanced_dot('')<CR>", { noremap = true })

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
    log("CycleWindowsOrBuffers only one tab, going forward to next window", forward)
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

  hi @diff.plus.diff guibg=#203520 guifg=NONE
  hi @diff.minus.diff guibg=#30181a guifg=NONE

  highlight GitSignsChangeInline guibg=#302ee8 guifg=NONE gui=underline
  " FYI this style is only gonna get used in inline previews
  highlight GitSignsDeleteInline guibg=#68221a guifg=NONE gui=underline
  highlight GitSignsAddInline guibg=#30582e guifg=NONE gui=underline

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

  highlight MatchParen guibg=#683068

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

  " Note gui=italic is what modern nvim seems to take, NOT cterm. likely related to 24bit color
  hi Comment cterm=italic gui=italic
  hi CopilotSuggestion gui=bold guibg=#202020

  nnoremap = :vertical res +5<CR>
  nnoremap - :vertical res -5<CR>
  nnoremap + :res +4<CR>
  nnoremap _ :res -4<CR>

  nnoremap <leader>f :NvimTreeFindFile<CR>

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

  """ an intuitive way to surround a selection with newlines -- disabled for now to try to adjust to Leap -- also, this logic is wrong! I think!
  " vmap S<CR> S<C-J>V2j=

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

  " set foldmethod=indent

]])

-- If cannot move in a direction, attempt to forward the directive to tmux
local function tmux_window(dir)
  -- exit insert mode if applicable
  if vim.fn.mode() == 'i' then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  end

  local move_functions = {
    h = vim.fn.winnr('h'),
    j = vim.fn.winnr('j'),
    k = vim.fn.winnr('k'),
    l = vim.fn.winnr('l')
  }
  local target_win = move_functions[dir]
  if target_win ~= vim.fn.winnr() then -- has somewhere to go
    -- vim.api.nvim_set_current_win(vim.fn.win_getid(target_win))
    -- so the above would work but is actually too low level and screws visual cursor positions up by failing to reset visual mode state!

    -- so, back to the typical way to switch buffers.
    vim.cmd('silent! wincmd ' .. dir)

  else -- at some edge, fallback to tmux
    vim.system({ 'tmux', 'select-pane', '-' .. string.gsub(dir, '[hjkl]', {h='L', j='D', k='U', l='R'}) }):wait()
    -- this has a race condition. TODO TODO TODO DO THIS: https://github.com/neovim/neovim/discussions/29905#discussioncomment-10182547
  end
end

-- -- Global table to store visual selections for each buffer
-- _G.visual_selections = {}
--
-- local function store_visual_selection()
--   local mode = vim.fn.mode()
--   local bufnr = vim.api.nvim_get_current_buf()
--   if mode:find('^[vV\22]') then -- visual, visual-line, or visual-block mode
--     local vstate = vim.fn.getpos('v')
--     _G.visual_selections[bufnr] = { mode = mode, v = vstate, cur = vim.fn.getpos('.') }
--   else
--     _G.visual_selections[bufnr] = nil
--   end
--   log('store for ' .. bufnr .. ' mode ' .. (mode:find('^\22') and 'vblock' or mode), _G.visual_selections)
-- end
--
-- local function restore_visual_selection()
--   local bufnr = vim.api.nvim_get_current_buf()
--   local selection = _G.visual_selections[bufnr]
--   local mode = vim.fn.mode()
--   log('restore for ' .. bufnr .. ' mode ' .. mode, selection)
--
--   if selection then
--     -- Set the cursor position
--     vim.fn.setpos("'>", selection.v)
--     vim.fn.setpos("'<", selection.cur)
--     vim.fn.setpos(".", selection.cur)
--
--     -- Enter visual mode if necessary
--     if not mode:find('^[vV\22]') then -- visual, visual-line, or visual-block mode
--       log('not in visual mode, issuing normal! gv after setting marks')
--       vim.cmd('normal! gv')
--     else
--       log('already in visual mode, let us see if assignment via marks works')
--     end
--     _G.visual_selections[bufnr] = nil -- Clear the stored selection after restoring
--   else
--     -- exit visual mode if necessary
--     if mode:find('^[vV\22]') then -- visual, visual-line, or visual-block mode
--       log('we forced exit from visual mode due to no storage')
--       vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
--     end
--   end
-- end
--
-- local visual_selection_group = vim.api.nvim_create_augroup("VisualSelectionMemory", { clear = true })
--
-- vim.api.nvim_create_autocmd("BufLeave", {
--   group = visual_selection_group,
--   callback = store_visual_selection
-- })
--
-- vim.api.nvim_create_autocmd("BufEnter", {
--   group = visual_selection_group,
--   callback = restore_visual_selection
-- })

vim.keymap.set({ "n", "v", "i" }, "<C-h>", function() tmux_window('h') end, { noremap = true, desc = "Move to window on left, overflow to tmux" })
vim.keymap.set({ "n", "v", "i" }, "<C-j>", function() tmux_window('j') end, { noremap = true, desc = "Move to window below, overflow to tmux" })
vim.keymap.set({ "n", "v", "i" }, "<C-k>", function() tmux_window('k') end, { noremap = true, desc = "Move to window above, overflow to tmux" })
vim.keymap.set({ "n", "v", "i" }, "<C-l>", function() tmux_window('l') end, { noremap = true, desc = "Move to window on right, overflow to tmux" })

-- vim.api.nvim_set_keymap('n', '<Leader>t', '<Cmd>lua MoveToNextTab()<CR>', {noremap = true, silent = true})

-- yanking window to the next tab
vim.keymap.set("n", "ygT", ":call MoveToPrevTab()<CR>")
vim.keymap.set("n", "ygt", ":call MoveToNextTab()<CR>")

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

function _G.put(...)
  local objects = {}
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    table.insert(objects, vim.inspect(v))
  end

  print(table.concat(objects, '\n'))
  return ...
end

_G.map = function(tbl, f)
  if tbl == nil then
    return nil
  end
  local t = {}
  for k,v in pairs(tbl) do
    t[k] = f(v, k)
  end
  return t
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
require("gitsigns").setup({
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
  show_deleted = false,
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

local Layout = require("nui.layout")
local Popup = require("nui.popup")

local telescope = require("telescope")
local TSLayout = require("telescope.pickers.layout")

local tele_actions = safeRequire('telescope.actions')
telescope.setup{
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
        ["<C-Down>"] = tele_actions.cycle_history_next,
        ["<C-Up>"] = tele_actions.cycle_history_prev,
      }
    },
    scroll_strategy = "limit",
    layout_config = {
      scroll_speed = 3
    },
    border = false,
    create_layout = function(picker)
      local border = {
        results = {
          top_left = "┌",
          top = "─",
          top_right = "┬",
          right = "│",
          bottom_right = "",
          bottom = "",
          bottom_left = "",
          left = "│",
        },
        results_patch = {
          minimal = {
            top_left = "┌",
            top_right = "┐",
          },
          horizontal = {
            top_left = "┌",
            top_right = "┬",
          },
          vertical = {
            top_left = "├",
            top_right = "┤",
          },
        },
        prompt = {
          top_left = "├",
          top = "─",
          top_right = "┤",
          right = "│",
          bottom_right = "┘",
          bottom = "─",
          bottom_left = "└",
          left = "│",
        },
        prompt_patch = {
          minimal = {
            bottom_right = "┘",
          },
          horizontal = {
            bottom_right = "┴",
          },
          vertical = {
            bottom_right = "┘",
          },
        },
        preview = {
          top_left = "┌",
          top = "─",
          top_right = "┐",
          right = "│",
          bottom_right = "┘",
          bottom = "─",
          bottom_left = "└",
          left = "│",
        },
        preview_patch = {
          minimal = {},
          horizontal = {
            bottom = "─",
            bottom_left = "",
            bottom_right = "┘",
            left = "",
            top_left = "",
          },
          vertical = {
            bottom = "",
            bottom_left = "",
            bottom_right = "",
            left = "│",
            top_left = "┌",
          },
        },
      }

      local results = Popup({
        focusable = false,
        border = {
          style = border.results,
          text = {
            top = picker.results_title,
            top_align = "center",
          },
        },
        win_options = {
          winhighlight = "Normal:Normal",
        },
      })

      local prompt = Popup({
        enter = true,
        border = {
          style = border.prompt,
          text = {
            top = picker.prompt_title,
            top_align = "center",
          },
        },
        win_options = {
          winhighlight = "Normal:Normal",
        },
      })

      local preview = Popup({
        focusable = false,
        border = {
          style = border.preview,
          text = {
            top = picker.preview_title,
            top_align = "center",
          },
        },
      })

      local box_by_kind = {
        vertical = Layout.Box({
          Layout.Box(preview, { grow = 1 }),
          Layout.Box(results, { grow = 1 }),
          Layout.Box(prompt, { size = 3 }),
        }, { dir = "col" }),
        horizontal = Layout.Box({
          Layout.Box({
            Layout.Box(results, { grow = 1 }),
            Layout.Box(prompt, { size = 3 }),
          }, { dir = "col", size = "30%" }),
          Layout.Box(preview, { size = "70%" }),
        }, { dir = "row" }),
        minimal = Layout.Box({
          Layout.Box(results, { grow = 1 }),
          Layout.Box(prompt, { size = 3 }),
        }, { dir = "col" }),
      }

      local function get_box()
        local height, width = vim.o.lines, vim.o.columns
        local box_kind = "horizontal"
        if width < 100 then
          box_kind = "vertical"
          if height < 40 then
            box_kind = "minimal"
          end
        elseif width < 120 then
          box_kind = "minimal"
        end
        return box_by_kind[box_kind], box_kind
      end

      local function prepare_layout_parts(layout, box_type)
        layout.results = TSLayout.Window(results)
        results.border:set_style(border.results_patch[box_type])

        layout.prompt = TSLayout.Window(prompt)
        prompt.border:set_style(border.prompt_patch[box_type])

        if box_type == "minimal" then
          layout.preview = nil
        else
          layout.preview = TSLayout.Window(preview)
          preview.border:set_style(border.preview_patch[box_type])
        end
      end

      local box, box_kind = get_box()
      local layout = Layout({
        relative = "editor",
        position = "50%",
        size = {
          height = "80%",
          width = "90%",
        },
      }, box)

      layout.picker = picker
      prepare_layout_parts(layout, box_kind)

      local layout_update = layout.update
      function layout:update()
        local box, box_kind = get_box()
        prepare_layout_parts(layout, box_kind)
        layout_update(self, box)
      end

      return TSLayout(layout)
    end,
  },
  extensions = {
    -- ["ui-select"] = {
    --   require("telescope.themes").get_cursor { }
    -- }
  }
}
-- telescope.load_extension("ui-select")

local telescope_builtin = safeRequire("telescope.builtin")
vim.keymap.set("n", "<c-p>", function ()
  -- explicitly giving most likely path for fd because sometimes we launch neovim in neovide through a basic shell
  -- without cargo in PATH.
  telescope_builtin.find_files({ find_command = { os.getenv('HOME').. '/.cargo/bin/fd', '--type', 'f' } })
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

-- alt+shift+p will open a command history searcher, reminiscent of something like commands via cmd p in vscode
vim.keymap.set("n", "<M-P>", function()
    telescope_builtin.command_history({
        filter_fn = function(cmd)
            local patterns = {
                "^w[aq;]?$",
                "^qa?$",
                "^e$",
                "^mes$",
                "^h ",
                "^map ?",
                "^%d+$"
            }
            for _, pattern in ipairs(patterns) do
                if string.match(cmd, pattern) then
                    return false -- A match was found, exclude this command
                end
            end
            return true -- No matches were found, include this command
        end
    })
end, { desc = 'Telescope command_history' })


safeRequire("nvim-lastplace").setup({})
safeRequire("nvim-autopairs").setup({ map_cr = false })
safeRequire("Comment").setup()

safeRequire("nvim-treesitter.configs").setup({
  -- A list of parser names, or "all" (the four listed parsers should always be installed)
  ensure_installed = { "markdown_inline", "c", "lua", "vim", "bash", "comment", "gitcommit", "diff", "git_rebase" },

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

-- safeRequire("trouble").setup({
--   -- your configuration comes here
--   -- or leave it empty to use the default settings
--   -- refer to the configuration section below
-- })

local nvimtree_api = require "nvim-tree.api"

local git_add = function()
  local node = nvimtree_api.tree.get_node_under_cursor()
  local gs = node.git_status.file

  -- If the current node is a directory get children status
  if gs == nil then
    gs = (node.git_status.dir.direct ~= nil and node.git_status.dir.direct[1]) 
         or (node.git_status.dir.indirect ~= nil and node.git_status.dir.indirect[1])
  end

  -- If the file is untracked, unstaged or partially staged, we stage it
  if gs == "??" or gs == "MM" or gs == "AM" or gs == " M" then
    vim.cmd("silent !git add " .. node.absolute_path)

  -- If the file is staged, we unstage
  elseif gs == "M " or gs == "A " then
    vim.cmd("silent !git restore --staged " .. node.absolute_path)
  end

  nvimtree_api.tree.reload()
end

local make_executable = function()
  local node = nvimtree_api.tree.get_node_under_cursor()
  
  if node.type == "file" then
    -- Check if file is already executable
    local is_executable = vim.fn.getfperm(node.absolute_path):sub(3, 3) == "x"
    
    if is_executable then
      -- If the file is executable, remove executable permissions for the user
      vim.cmd("silent !chmod -x " .. vim.fn.shellescape(node.absolute_path))
      print("Removed executable permission from: " .. node.name)
    else
      -- If the file is not executable, add executable permissions for the user
      vim.cmd("silent !chmod +x " .. vim.fn.shellescape(node.absolute_path))
      print("Added executable permission to: " .. node.name)
    end
  else
    print("Selected item is not a file")
  end

  nvimtree_api.tree.reload()
end

local function my_on_attach(bufnr)

  local function opts(desc)
    return { desc = "nvim-tree: " .. desc, buffer = bufnr, noremap = true, silent = true, nowait = true }
  end

  -- default mappings
  nvimtree_api.config.mappings.default_on_attach(bufnr)

  -- custom mappings
  vim.keymap.set('n', '<C-t>', nvimtree_api.tree.change_root_to_parent, opts('Up'))
  vim.keymap.set('n', '-', ':vertical res -5<CR>', opts('Shrink Window (key override)'))
  vim.keymap.set('n', '?', nvimtree_api.tree.toggle_help, opts('Help'))

  vim.keymap.set('n', 'ga', git_add, opts('Git Add'))
  -- vim.keymap.set('n', 'gC', git_commit, opts('Git Commit'))
  vim.keymap.set('n', 'ge', make_executable, opts('Make Executable'))
  -- vim.keymap.set('n', 'go', open)
end

require("nvim-tree").setup({
  on_attach = my_on_attach,
  git = { enable = true },
  -- log = { enable = true },
  update_focused_file = {
    enable = true,
    update_root = true
  }
})


safeRequire("colorizer").setup()

-- general plugin specific binds (TODO: put together when refactoring the plugin configs into files)
vim.keymap.set("n", "<leader>y", safeRequire("osc52").copy_operator, { expr = true, desc = "Copy to host term system clipboard via OSC 52" })
vim.keymap.set("n", "<leader>yy", "<leader>y_", { remap = true, desc = "Copy entire line to host term system clipboard via OSC 52" })
vim.keymap.set("x", "<leader>y", safeRequire("osc52").copy_visual, { desc = "Copy visual selection to host term system clipboard via OSC 52" })
vim.keymap.set("n", "<leader>Y", "ggVG<leader>y", { remap = true, desc = "Copy entire buffer to host clipboard via OSC 52"})

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

vim.cmd("highlight IndentBlanklineIndent1 gui=nocombine guifg=#383838")
vim.cmd("highlight IndentBlanklineIndent2 gui=nocombine guifg=#484848")
vim.cmd("highlight IblScope gui=nocombine guifg=#584868")

require("ibl").setup({
  debounce = 100,
  indent = {
    char = "▏",
    tab_char = "→",
    highlight = {
      "IndentBlanklineIndent1",
      "IndentBlanklineIndent2",
    },
  },
  scope = {
    enabled = true,
    char = '▎',
    show_start = true,
    show_end = true,
    show_exact_scope = true,
    include = {
      node_type = { lua = { "return_statement", "table_constructor" } },
    }
  }, -- i set this for use from iOS terminal emulators
})

-- require('mini.indentscope').setup{
--   options = {
--     try_as_border = true
--   }
-- }

function ef_ten(direction)
    local mode = vim.api.nvim_get_mode().mode
    local is_visual = mode ~= "^v"
    log('ef_ten is_visual', is_visual, mode)

    local tmux_panes_count = vim.fn.system("tmux display -p '#{window_panes}'")
    if tmux_panes_count == "1\n" or tmux_panes_count == "failed to connect to server\n" then
        if direction == '+' then
            vim.cmd("wincmd w")  -- next window
        else
            vim.cmd("wincmd W")  -- previous window
        end
    else
        vim.fn.system("tmux select-pane -t :." .. direction)
    end

end
vim.keymap.set({ 'n' }, '<F10>', function () ef_ten('+') end, {noremap = true})
vim.keymap.set({ 'n' }, '<S-F10>', function () ef_ten('-') end, {noremap = true})

vim.opt.completeopt="menu,menuone,noselect"

local cmp = require'cmp'
local lspkind = safeRequire('lspkind')

local has_words_before = function()
  local line, col = unpack(vim.api.nvim_win_get_cursor(0))
  return col ~= 0 and vim.api.nvim_buf_get_lines(0, line - 1, line, true)[1]:sub(col, col):match("%s") == nil
end

cmp.setup({
  formatting = {
    format = lspkind.cmp_format({
      mode = 'symbol',
      maxwidth = 50, -- prevent the popup from showing more than provided characters (e.g 50 will not show more than 50 characters)
      ellipsis_char = '…', -- when popup menu exceed maxwidth, the truncated part would show ellipsis_char instead (must define maxwidth first)
      symbol_map = { Codeium = "", Cody = "*" },

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
    ---- bringing ctrl-space back as i am no longer using copilot
    ---- it is used for now to target codeium.
    ['<C-Space>'] = cmp.mapping.complete({ config = { sources = { { name = 'cody' }, { name = 'codeium'} } } }),
    ['<C-S-Space>'] = cmp.mapping.complete({ config = { sources = { { name = 'codeium' } } } }),
    ['<C-e>'] = cmp.mapping.abort(),
    ["<CR>"] = cmp.mapping.confirm({
      behavior = cmp.ConfirmBehavior.Replace,
      select = false,
    }),
    -- ["<c-x>"] = cmp.mapping(function(fallback)
    --   if require'snippy'.is_active() then
    --     vim.api.nvim_feedkeys('a'..'\0x7f', 's', true)
    --   else
    --     fallback()
    --   end
    -- end, { "s" }),
    ["<Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        if require'snippy'.can_expand_or_advance() then
          -- log('Tab using select behavior select')
          cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
        else
          -- log('Tab using select behavior insert')
          cmp.select_next_item({ behavior = cmp.SelectBehavior.Insert })
        end
      -- You could replace the expand_or_jumpable() calls with expand_or_locally_jumpable() 
      -- they way you will only jump inside the snippet region
      -- elseif luasnip.expand_or_jumpable() then
      --   luasnip.expand_or_jump()
      elseif require'snippy'.can_expand_or_advance() then
        log('snippy calling expand_or_advance')
        require'snippy'.expand_or_advance()
      elseif has_words_before() then
        log('has_words_before produced '..vim.inspect(has_words_before()))
        cmp.complete()
      else
        log('cmp calling fallback')
        fallback()
      end
    end, { "i", "s" }),

    ["<S-Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        if require'snippy'.can_expand_or_advance() then
          log('using select behavior select')
          cmp.select_prev_item({ behavior = cmp.SelectBehavior.Select })
        else
          log('using select behavior insert')
          cmp.select_prev_item({ behavior = cmp.SelectBehavior.Insert })
        end
      -- elseif luasnip.jumpable(-1) then
      --   luasnip.jump(-1)
      elseif require'snippy'.can_jump(-1) then
        require'snippy'.previous()
      else
        fallback()
      end
    end, { "i", "s" })
  }),
  sources = cmp.config.sources({
    { name = 'nvim_lsp' },
    -- { name = 'vsnip' }, -- For vsnip users.
    -- { name = 'luasnip' }, -- For luasnip users.
    -- { name = 'ultisnips' }, -- For ultisnips users.
    { name = 'snippy' }, -- For snippy users.
    { name = 'buffer' },
    { name = 'cody' },
    { name = 'codeium' },
    -- option = {
    --   keyword_length = 0
    -- }
    { name = 'path',
      option = {
        -- Options go into this table
      },
    },
    { name = 'nvim_lsp_signature_help' },
  }),
  snippet = {
    expand = function(args)
      _G.log("snippy expand function")
      require('snippy').expand_snippet(args.body)
    end
  }
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

require("lazydev").setup({
  -- add any options here, or leave empty to use the default settings
})

require("mason").setup({})
require("mason-lspconfig").setup({
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

require("mason-null-ls").setup({
  ensure_installed = { "shellcheck" },
  automatic_setup = true,
  automatic_installation = true,
  handlers = {
    function(source_name, methods)
      -- print("mason-null-ls-handler: source_name:" .. source_name)
      -- print("mason-null-ls-handler: methods:" .. vim.inspect(methods))
      -- all sources with no handler get passed here

      -- To keep the original functionality of `automatic_setup = true`,
      -- please add the below.
      safeRequire("mason-null-ls.automatic_setup")(source_name, methods)
    end,
    pylint = function ()
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
    cspell = function()
      null_ls.register(null_ls.builtins.diagnostics.cspell.with({
        timeout = 20000,
        method = null_ls.methods.DIAGNOSTICS_ON_SAVE,
      }))
    end,
    cpplint = function()
      null_ls.register(null_ls.builtins.diagnostics.cpplint.with({
        args = { '--linelength=240' },
      }))
    end,

    -- stylua = function(source_name, methods)
    --   null_ls.register(null_ls.builtins.formatting.stylua)
    -- end,
  }
})

null_ls.setup({
  -- debug = true,
  -- this is for cspell to default to hints and not errors (yeesh)
  fallback_severity = vim.diagnostic.severity.HINT,
  sources = {
    null_ls.builtins.code_actions.gitsigns,
    null_ls.builtins.code_actions.ts_node_action,
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

-- keymaps!!
local lsp_attach = function (x, bufnr)
  local engine = x.name;
  log("lsp_attach:" .. engine .. " bufnr=" .. bufnr)
  local bufopts = { noremap=true, silent=true, buffer=bufnr }
  -- vim.keymap.set('n', 'gD', '<cmd>TroubleToggle lsp_type_definitions<cr>', ext(bufopts, "desc", "Go to Type Definition (Trouble UI)"))
  -- vim.keymap.set('n', 'gD', '<cmd>Trouble lsp_definitions<cr>', ext(bufopts, "desc", "Go to Definition (Trouble UI)"))
  -- vim.keymap.set('n', 'gi', goto_preview.goto_preview_implementation, ext(bufopts, "desc", "Go to Implementation (preview window)"))
  -- mnemonic is "args"
  vim.keymap.set('n', '<leader>S', vim.lsp.buf.signature_help, ext(bufopts, "desc", "Signature help"))
  -- vim.keymap.set('n', '<space>wa', vim.lsp.buf.add_workspace_folder, bufopts)
  -- vim.keymap.set('n', '<space>wr', vim.lsp.buf.remove_workspace_folder, bufopts)
  -- vim.keymap.set('n', '<space>wl', function()
  --   print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
  -- end, bufopts)
  -- vim.keymap.set('n', '<space>D', vim.lsp.buf.type_definition, bufopts)
  -- vim.keymap.set('n', '<leader>r', vim.lsp.buf.rename, ext(bufopts, "desc", "Rename"))
  vim.keymap.set('n', '<leader>ca', vim.lsp.with( vim.lsp.buf.code_action, {border = nil} ), ext(bufopts, "desc", "Code Action Menu"))
  vim.keymap.set('v', '<leader>ca', vim.lsp.buf.code_action, ext(bufopts, "desc", "Code Action Menu"))
  -- vim.keymap.set('n', 'gr', '<cmd>Trouble lsp_references<cr>', ext(bufopts, "desc", "Go to References"))
  vim.keymap.set('n', '<leader>=', function() vim.lsp.buf.format { async = true } end, ext(bufopts, "desc", "Format Buffer"))
end

require("mason-lspconfig").setup_handlers {
  -- The first entry (without a key) will be the default handler
  -- and will be called for each installed server that doesn't have
  -- a dedicated handler.
  function (server_name) -- default handler (optional)
    safeRequire("lspconfig")[server_name].setup {
      capabilities = capabilities,
      on_attach = lsp_attach,
    }
  end,
  ["tsserver"] = function () log "exception applied for mason lspconfig setup for tsserver as we want to use typescript-tools instead." end,
  -- Next, you can provide a dedicated handler for specific servers. Don't forget to bring capabilities and on_attach in.
  -- ["tsserver"] = function ()
  --   log('executing tsserver mason-lspconfig handler cb');
  --   safeRequire("lspconfig")["tsserver"].setup {
  --     capabilities = capabilities,
  --     on_attach = lsp_attach,
  --     settings = {
  --       test_option = 'blargle',
  --       typescript = {
  --         tsserver = {
  --           logDirectory = "/tmp/tsserver/",
  --           experimental = {
  --             enableProjectDiagnostics = true
  --           },
  --           enableTracing = true,
  --           trace = "verbose",
  --         },
  --       },
  --     }
  --   }
  -- end,
  ["clangd"] = function ()
    safeRequire("lspconfig")["clangd"].setup {
      on_attach = lsp_attach,
      capabilities = capabilities,
      cmd = {
        "clangd",
        "--offset-encoding=utf-16",
      },
    }
  end,
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
          workspace = {
            library = {
              string.format('%s/.hammerspoon/Spoons/EmmyLua.spoon/annotations', os.getenv 'HOME')
            }
          },
        }
      }
    }
  end,
  -- ["emmet_ls"] = function ()
  --   safeRequire('lspconfig').emmet_ls.setup({
  --     on_attach = lsp_attach,
  --     capabilities = capabilities,
  --     filetypes = { "css", "eruby", "html", "javascript", "javascriptreact", "less", "sass", "scss", "svelte", "pug", "typescriptreact", "vue" },
  --     init_options = {
  --       html = {
  --         options = {
  --           -- For possible options, see: https://github.com/emmetio/emmet/blob/master/src/config.ts#L79-L267
  --           ["bem.enabled"] = true,
  --         },
  --       },
  --     }
  --   })
  -- end
}

-- local vtsls = require("vtsls")
-- local vt_lspc = vtsls.lspconfig;
-- vt_lspc.default_config.cmd = { "node", vim.fn.expand("$HOME") .. '/vtsls/packages/server/bin/vtsls.js', '--stdio' }
-- log('xxx', vt_lspc)
-- require('lspconfig.configs').vtsls = vt_lspc
-- -- require("lspconfig").vtsls.setup({})
-- vtsls.config({})
-- vtsls.config({
--   cmd = 
--     -- -- customize handlers for commands
--     -- handlers = {
--     --     source_definition = function(err, locations) end,
--     --     file_references = function(err, locations) end,
--     --     code_action = function(err, actions) end,
--     -- },
--     -- -- automatically trigger renaming of extracted symbol
--     -- refactor_auto_rename = true,
-- })
-- require("lspconfig.configs").vtsls = vtsls_lspconfig
-- vtsls_lspconfig.setup({
--   cmd = { "node", vim.fn.expand("$HOME") .. '/vtsls/packages/server/bin/vtsls.js', '--stdio' }
-- })

safeRequire("yanky").setup({
  highlight = {
    on_put = true,
    on_yank = true,
    timer = 1000,
  },
})
vim.keymap.set({"n"}, "p", "<Plug>(YankyPutAfter)")
vim.keymap.set({"n"}, "P", "<Plug>(YankyPutBefore)")

vim.keymap.set({"x"}, "P", "<Plug>(YankyPutAfter)")
vim.keymap.set({"x"}, "p", "<Plug>(YankyPutBefore)")
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
  hi CurSearch cterm=bold ctermfg=black ctermbg=yellow guibg=#ff392a guifg=NONE
  hi IncSearch cterm=bold ctermfg=black ctermbg=cyan guibg=#f04050 guifg=NONE gui=NONE

  hi NormalCursor guibg=#00ee00
  hi InsertCursor guibg=#00eeff
  set guicursor=n-v-c-sm:block-NormalCursor,i-ci-ve:ver30-InsertCursor,r-cr-o:hor20-ReplaceCursor

  hi CursorLine guibg=#181818
  set cursorline

  highlight ActiveCursorLine guibg=#222e20
  highlight InactiveCursorLine guibg=#1a1a1a

  highlight NormalModeBackground guibg=#050a13
  highlight InsertModeBackground guibg=#101228

  " just replicating from what zephyr currently sets... These are probably superfluous.
  highlight Normal guifg=#bbc2cf guibg=#050a13
  highlight SignColumn guifg=#bbc2cf guibg=#050a13

  hi Visual term=reverse ctermbg=238 guibg=#855540
  hi NormalFloat guibg=#232336
  hi NonText guibg=#303030

  " pane/window split: only vertical split style matters in vim since horizontal splits are made of statuslines.
  hi WinSeparator guifg=#606780 guibg=#333338
  hi link NvimTreeWinSeparator WinSeparator
  hi NvimTreeNormal guibg=#131320

  hi TSPlaygroundFocus guibg=#2f628e

  hi TroublePreview cterm=bold ctermfg=yellow ctermbg=black guibg=#247343 guifg=NONE
  " hi link CodeActionTitle NormalFloat
  " hi CodeActionHeader gui=underline

  hi link TelescopeNormal NormalFloat 

  highlight @comment.todo.comment cterm=bold,italic guibg=#c04322 guifg=white

]])

require('winhl-manager').setup({
  cursor_line = {
    active = 'ActiveCursorLine',
    inactive = 'InactiveCursorLine'
  },
  background = {
    normal = 'NormalModeBackground',
    insert = 'InsertModeBackground'
  }
})

-- vim.fn.matchadd("DiagnosticInfo", "\\(TODO:\\)")
vim.fn.matchadd("SpecialWordMatchWarning", "\\(HACK:\\)")
vim.fn.matchadd("SpecialWordMatchWarning", "\\(WARN:\\)")
vim.fn.matchadd("SpecialWordMatchWarning", "\\(WARNING:\\)")
-- vim.fn.matchadd("DiagnosticWarn", "\\(XXX:\\)")
-- vim.fn.matchadd("@comment.todo.comment", "\\(PERF:\\)")
-- vim.fn.matchadd("Identifier", "\\(PERFORMANCE:\\)")
-- vim.fn.matchadd("Identifier", "\\(OPTIM:\\)")
-- vim.fn.matchadd("Identifier", "\\(OPTIMIZE:\\)")
-- vim.fn.matchadd("DiagnosticHint", "\\(NOTE:\\)")
-- vim.fn.matchadd("Identifier", "\\(TEST:\\)")
-- vim.fn.matchadd("Identifier", "\\(TESTING:\\)")
-- vim.fn.matchadd("Identifier", "\\(PASSED:\\)")
-- vim.fn.matchadd("Identifier", "\\(FAILED:\\)")

vim.cmd([[

hi link @comment.warning.comment SpecialWordMatchWarning
hi SpecialWordMatchWarning cterm=bold,italic guibg=#b3a320 guifg=white

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

-- vim.keymap.set("n", "<leader>t", ":Trouble document_diagnostics<CR>")
-- vim.keymap.set("n", "<leader>W", ":Trouble workspace_diagnostics<CR>")

vim.keymap.set('n', "<leader>T", ":OnlineThesaurusCurrentWord<CR>", { desc = "Thesaurus lookup" })

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
vim.g.copilot_filetypes = {markdown = true, yaml = true}

-- load refactoring Telescope extension
telescope.load_extension("refactoring")

-- remap to open the Telescope refactoring menu in visual mode
vim.api.nvim_set_keymap(
  "n", "<leader>R", "<cmd>lua require('telescope').extensions.refactoring.refactors()<CR>", { noremap = true, desc = "refactors ()" }
)
vim.api.nvim_set_keymap(
  "v",
  "<leader>r",
  "<Esc><cmd>lua require('telescope').extensions.refactoring.refactors()<CR>",
  { noremap = true, desc = "Open refactoring menu in visual mode"}
)

vim.keymap.set("n", "<leader>r", function()
  return ":IncRename " .. vim.fn.expand("<cword>")
end, { expr = true, desc = "Incremental Rename" })

vim.cmd[[let g:lion_squeeze_spaces = 1]]

-- not needed for default settings
require('deadcolumn').setup{
  scope = 'visible',
  blending = {
    hlgroup = { 'InsertModeBackground', 'bg' }
  }
}

-- putting here late so log global is present for it
safeRequire("heirline_conf.heirline")

vim.keymap.set('n', 'gd', '<CMD>Glance definitions<CR>')
require('glance').setup({
  list = {
    width = 0.2
  }
})

-- switch.vim config

-- vim.cmd[[
--   " This entry duplicates builtins (true <-> false), but being here gives it an appropriate priority
--   au FileType cpp let g:switch_custom_definitions = [
--           \   switch#Words(['public', 'private']),
--           \   switch#Words(['first', 'second']),
--           \   switch#Words(['true', 'false']),
--           \ {
--             \  'const \([A-Za-z][A-Za-z0-9_:<>]*\)&': '\1',
--             \  '\%(const \)\@!\([A-Za-z][A-Za-z0-9_:<>]*\)' : 'const \1&'
--           \ }
--         \ ] + g:switch_custom_definitions
--
--   " highest priority defs are prepended last here
--   let g:switch_custom_definitions = [
--     \   switch#NormalizedCase(['show', 'hide']),
--     \   switch#NormalizedCase(['add', 'remove']),
--     \   switch#NormalizedCase(['before', 'after']),
--     \   switch#NormalizedCase(['begin', 'end']),
--     \   switch#NormalizedCaseWords(['yes', 'no']),
--     \   switch#NormalizedCaseWords(['on', 'off']),
--     \   switch#NormalizedCaseWords(['error', 'warn', 'info']),
--     \ ]
-- ]]

require('snippy').setup({
  mappings = {
    is = {
      ['<C-Tab>'] = 'expand_or_advance',
      ['<C-S-Tab>'] = 'previous',
    },
    x = {
      ['<Tab>'] = 'cut_text',
    },
  },
})

require('lspconfig').emmet_language_server.setup({
  filetypes = {
    "css",
    "eruby",
    "html",
    "markdown",
    "javascript",
    "javascriptreact",
    "less",
    "sass",
    "scss",
    "svelte",
    "pug",
    "typescript",
    "typescriptreact",
    "vue"
  },
  init_options = {
    --- @type table<string, any> https://docs.emmet.io/customization/preferences/
    preferences = {},
    --- @type "always" | "never" defaults to `"always"`
    showexpandedabbreviation = "always",
    --- @type boolean defaults to `true`
    showabbreviationsuggestions = true,
    --- @type boolean defaults to `false`
    showsuggestionsassnippets = false,
    --- @type table<string, any> https://docs.emmet.io/customization/syntax-profiles/
    syntaxprofiles = {},
    --- @type table<string, string> https://docs.emmet.io/customization/snippets/#variables
    variables = {},
    --- @type string[]
    excludelanguages = {},
  },
})

-- note to self: Profiling!
-- require'plenary.profile'.start("profile.log")
-- require'plenary.profile'.stop()

-- Load which-key for keybinding docs
-- local wk = require("which-key")

-- Register TreesJ keybindings
-- wk.register({
--   ["<leader>m"] = { function() require('treesj').toggle() end, "Toggle node under cursor (treesj)" },
--   ["<leader>J"] = { function() require('treesj').split() end, "Split node under cursor (treesj)" },
--   ["<leader>j"] = { function() require('treesj').join() end, "Join node under cursor (treesj)" },
-- })

-- I only ever want these two options so why not just make it a single toggle
function ToggleIndentation()
  local current_indent = vim.bo.shiftwidth
  if current_indent == 2 then
    vim.bo.shiftwidth = 4
    vim.bo.tabstop = 4
  else
    vim.bo.shiftwidth = 2
    vim.bo.tabstop = 2
  end

  -- Re-indent the entire file
  vim.api.nvim_command('normal! ggVG=')
end

-- Map the function to a keybinding
-- TODO do something about how this is a little bit unsafe since it requires total trust in syntax parse.
vim.api.nvim_set_keymap('n', '<leader>i', ':lua ToggleIndentation()<CR>', { noremap = true, silent = true })

vim.keymap.set('n', "<M-C-F11>", "<cmd>lua CycleWindowsOrBuffers(true)<cr>", { desc = "Cycle Windows or Buffers" })
vim.keymap.set('n', "<M-C-S-F11>", "<cmd>lua CycleWindowsOrBuffers(false)<cr>", { desc = "Cycle Windows or Buffers Reverse" })

----- so the below is bad because of infinite recursion
-- -- stop visual paste from clobbering yank register
-- vim.api.nvim_set_keymap('x', 'p', 'P', { silent = true })
-- -- allow original p behavior with P
-- vim.api.nvim_set_keymap('x', 'P', 'p', { silent = true })

-- see yanky config

-- node action config. Unfortunately the bind is not very mnemonic but e is super easy to reach.
vim.keymap.set('n', '<leader>e', require('ts-node-action').node_action, {
  desc = "Treesitter Node Action"
})

vim.keymap.set('n', '<leader>E', function ()
    local actions = require('ts-node-action').available_actions()
    -- run the last one
    log('actions and last', actions, actions[#actions].action())
  end, {
  desc = "Node Action -- last"
})

-- vim.o.foldtext = 'hello'

-- Alright, so this one makes diags show up more easily, but i had to kill it because it would keep clobbering the popup for hover...
-- vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
--   group = vim.api.nvim_create_augroup("float_diagnostic", { clear = true }),
--   callback = function ()
--     vim.diagnostic.open_float(nil, {focus=false})
--   end
-- })

-- require("lspconfig").vtsls.setup({
--   -- cmd = { "node", vim.fn.expand("$HOME") .. '/vtsls/packages/server/bin/vtsls.js', '--stdio' },
--   settings = {
--     vtsls = {
--       enableMoveToFileCodeAction = true,
--       -- refactor_move_to_file = {
--       --   -- controls how path is displayed for selection of destination file
--       --   -- "default" | "vscode" | function(path: string) -> string
--       --   path_display = "default",
--       --   -- If dressing.nvim is installed, telescope will be used for selection prompt. Use this to customize the opts for telescope picker.
--       --   -- telescope_opts = function(items) end,
--       -- }
--     }
--   }
-- })

require('leap').setup{}

vim.keymap.set({'n'}, 's', '<Plug>(leap)')

-- Or just set to grey directly, e.g. { fg = '#777777' },
-- if Comment is saturated.
-- vim.api.nvim_set_hl(0, 'LeapBackdrop', { link = 'Comment' })
-- set leapbackdrop to a grey bgcolor:
vim.api.nvim_set_hl(0, 'LeapBackdrop', { bg = '#4f3f3f' })
vim.api.nvim_set_hl(0, 'LeapLabel', { bg='#ffffff', fg = '#000000', bold=true })

-- a quick way to bufdel cur buffer to make it more practical to manipulate global buflist (poor man organizing bufline)
-- function CurBufDel()
--   local bufnr = vim.fn.bufnr()
--   vim.api.nvim_buf_delete(bufnr, {})
-- end

-- normal shift-X deletes prior to cursor, something i will never use.
vim.keymap.set('n', 'X', ':BD<CR>', { desc = "Delete current buffer with vim-bufkill" })

function CloseAllBufsNotOpenInTabs()
  local all_open_bufs = {}
  for _, tab in ipairs(vim.fn.gettabinfo()) do
    for _, buf in ipairs(vim.fn.tabpagebuflist(tab.tabnr)) do
      all_open_bufs[buf] = true
    end
  end
  -- find bufs not in this list
  for _, buf in ipairs(vim.fn.getbufinfo()) do
    if not all_open_bufs[buf.bufnr] then
      vim.api.nvim_buf_delete(buf.bufnr, {})
    end
  end
end

function CloseAllButThisBuf()
  local current_buf = vim.fn.bufnr()
  for _, tab in ipairs(vim.fn.gettabinfo()) do
    for _, buf in ipairs(vim.fn.tabpagebuflist(tab.tabnr)) do
      if buf ~= current_buf then
        vim.cmd('bunload ' .. buf)
      end
    end
  end
end

function FlattenAllWindows()
  CloseAllBufsNotOpenInTabs()
  CloseAllButThisBuf()
end

vim.keymap.set('n', '<leader>cb', ':lua CloseAllBufsNotOpenInTabs()<CR>', { desc = "Close all buffers not already open in tabs" })
vim.keymap.set('n', '<leader>cc', ':lua FlattenAllWindows()<CR>', { desc = "close all other buffers than windows open in tabs and go to buffer workflow" })

vim.keymap.set('i', '<M-NL>', '<CR>', { noremap = true, desc = "also newline"})

local function setTimeout(callback, delay)
  local timer = vim.loop.new_timer()

  timer:start(delay, 0, function()
    timer:close()
    callback()
  end)

  return timer
end

local function clearTimeout(timerId)
  if timerId then
    timerId:stop()
    timerId:close()
    timerId = nil
  end
end

local function debounce(func, delay)
  local timerId = nil

  return function(...)
    local args = {...} -- Store the vararg parameters in a table

    if timerId then
      -- If a timer is already running, cancel it
      clearTimeout(timerId)
    end

    -- Start a new timer that will call the function after the specified delay
    timerId = setTimeout(function()
      func(unpack(args)) -- Use `unpack` to pass the stored parameters to the function
      timerId = nil
    end, delay)
  end
end

-- debounced autocommand on window resize. Assigns some simple files that record the current state enumerating nvim
-- instances in tmux sessions/windows/panes and what their server sockets are.

-- helpful to record the files that are open in the nvim instances.
local function isFileBuffer(buf)
    -- Check if the buffer has a name and is listed
    local name = vim.fn.bufname(buf)
    local isListed = vim.fn.buflisted(buf)
    return name and #name > 0 and isListed == 1
end

local function getAllBufferPaths()
    local paths = {}
    -- Iterate through each buffer by ID
    for buf = 1, vim.fn.bufnr('$') do
        -- Use the isFileBuffer check to determine if it's an actual file buffer
        if isFileBuffer(buf) then
            -- Get the full path of the buffer
            local path = vim.fn.bufname(buf)
            table.insert(paths, path)
        end
    end
    return paths
end

local function nvim_state_update(ev)
  vim.schedule(function()
    local cmd = {vim.env.HOME .. "/util/nvim-update-win.sh", tostring(vim.fn.getpid()), vim.v.servername, vim.fn.getcwd(), ev.file, ev.event}
    local ret = vim.fn.system(cmd)
    -- log(ev, cmd, 'nvim-update-win.sh -->', ret)
  end)
end

-- add BufEnter again... track the current buffer file
vim.api.nvim_create_autocmd({"VimResized", "BufEnter"}, {
  callback = debounce(nvim_state_update, 400)
})

vim.api.nvim_create_autocmd({"VimLeavePre", "VimEnter"}, {
  callback = nvim_state_update
})

-- set deadcolumn not to appear for trouble v3 buffers
-- vim.api.nvim_create_autocmd({"FileType"}, {
--   pattern = "Trouble",
--   callback = function()
--     vim.opt_local.colorcolumn = ""
--   end
-- })

require("spider").setup {
  skipInsignificantPunctuation = false,
  subwordMovement = true,
  customPatterns = {}, -- check Custom Movement Patterns for details
}

function toggle_scrolloff()
  local enable = vim.opt_local.scrolloff:get() == 0
  vim.opt_local.scrolloff = enable and 8 or 0
end

vim.keymap.set('n', '<leader>z', ':lua toggle_scrolloff()<CR>', { desc = "Toggle scrolloff" })

vim.o.scrolloff = 3;

-- for easy reload automation
vim.api.nvim_create_autocmd({"Signal"}, {
  pattern = "SIGUSR1",
  callback = function()
    print("Received SIGUSR1, quitting Neovim...")
    vim.cmd('qa!')  -- Quit all windows and exit Neovim
  end,
  desc = "Handle SIGUSR1 signal to quit Neovim"
})

vim.keymap.set("n", "<Leader>F", ":Oil --float<CR>")

-- -- -- damn this isnt working and i dont know why
-- -- Function to abort operator-pending state and close WhichKey
-- local function abort_operator_pending_by_hitting_ESC()
--   local mode = vim.api.nvim_get_mode().mode
--   log('FocusLost: current vim mode:', mode)
--   if mode:find("^[vV\22]") then
--     return
--   end
--   vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)
-- end
--
-- -- NOTE NOTE which-key v3 will have automatic FocusLost handling, so we might want to eliminate it once the which-key switchover takes place. OTOH this seems to be sane behavior to clear out various non obvious editor states across focus changes, so poking a hole for visual mode should make it largely desirable.
--
-- -- Autocmd to abort operator-pending state on FocusLost
-- vim.api.nvim_create_autocmd("FocusLost", {
--   callback = function()
--     vim.schedule(function()
--       abort_operator_pending_by_hitting_ESC()
--     end)
--   end,
--   desc = "Abort operator-pending state or close WhichKey on FocusLost. Just indiscriminately mashing Esc"
-- })

-- vim.api.nvim_create_autocmd("FocusGained", {
--   callback = function ()
--     log('FocusGained')
--   end,
--   desc = "FocusGained"
-- })

vim.cmd[[

  function! FindQuoteType()
    let l:quote_chars = ['"', "'", '`']
    let l:cur_pos = col('.')
    let l:cur_line = line('.')
    let l:lines = getline(1, '$')

    for l:quote in l:quote_chars
      let l:left_pos = -1
      let l:right_pos = -1

      " Search for the left quote
      let l:line_idx = l:cur_line - 1
      while l:line_idx >= 0
        let l:line = l:lines[l:line_idx]
        let l:left_pos = strridx(l:line, l:quote)
        if l:left_pos >= 0 || l:line_idx == 0
          break
        endif
        let l:line_idx -= 1
      endwhile

      " Search for the right quote
      let l:line_idx = l:cur_line - 1
      while l:line_idx < len(l:lines)
        let l:line = l:lines[l:line_idx]
        let l:right_pos = stridx(l:line, l:quote, l:line_idx == l:cur_line - 1 ? l:cur_pos : 0)
        if l:right_pos >= 0
          break
        endif
        let l:line_idx += 1
      endwhile

      if l:left_pos >= 0 && l:right_pos >= 0
        return l:quote
      endif
    endfor

    return ''
  endfunction

  function! SelectQuote(mode)
    let l:quote = FindQuoteType()
    if l:quote ==# ''
      return
    endif

    if a:mode ==# 'v'
      execute "normal! vi" . l:quote
    elseif a:mode ==# 'a'
      execute "normal! va" . l:quote
    endif
  endfunction

  vnoremap <silent> iq :<C-u>call SelectQuote('v')<CR>
  vnoremap <silent> aq :<C-u>call SelectQuote('a')<CR>
  omap <silent> iq :normal viq<CR>
  omap <silent> aq :normal vaq<CR>

  " provided by EgZvor from reddit, i am selectively activating some of it
  " Working with marks
  " noremap ` '
  " noremap ' `
  " noremap '' ``
  " noremap `` ''
  " sunmap '
  " sunmap `
  " sunmap ''
  " sunmap ``

  " Who needs lowercase marks?
  " for ch in 'abcdefghijklmnopqrstuvwxyz'
  "   exe 'nnoremap m' . ch .          ' m' . toupper(ch)
  "   exe 'nnoremap m' . toupper(ch) . ' m' . ch
  "   exe "nnoremap '" . ch .          ' `' . toupper(ch)
  "   exe "nnoremap '" . toupper(ch) . ' `' . ch
  " endfor


  " for ESM typescript `gf`
  augroup TypeScriptIncludeExpr
  autocmd!
  autocmd FileType typescript setlocal includeexpr=substitute(v:fname,'\\.js$','.ts','')
  augroup END

]]

-- this is useful for sections of code with two alternative impls to toggle between.
vim.keymap.set('x', 'gci', ':normal gcc<CR>', { desc = 'Invert comments per line' })

local sess_man_conf = require('session_manager.config')
require('session_manager').setup{
  autoload_mode = {
    sess_man_conf.AutoloadMode.CurrentDir,
    -- sess_man_conf.AutoloadMode.LastSession
  }
}

-- disable treesitter for tmux conf filetype, as it is particularly incapable of parsing my current conf file state.
vim.api.nvim_create_autocmd("FileType", {
  pattern = {"tmux"}, -- Replace with the problematic filetypes
  callback = function()
    vim.cmd("TSBufDisable highlight")
  end,
})

-- helper, very sad no hyperlink support in neovim yet. don't send in a long running command.
function MakeTermWindowVimAsPager(command, size, name)
  vim.cmd('botright ' .. size .. ' new')

  local bufNum = vim.api.nvim_get_current_buf()
  local winNum = vim.api.nvim_get_current_win()
  vim.bo[bufNum].buftype = 'nofile'
  vim.bo[bufNum].bufhidden = 'hide'
  vim.wo[winNum].signcolumn = 'no'
  vim.keymap.set('n', 'q', function()
    vim.api.nvim_buf_delete(bufNum, {force = true})
  end, { noremap = true, silent = true, buffer = bufNum})
  local chan_id = vim.fn.termopen({'/bin/sh', '-c', command}, {
    on_exit = function(job_id, exit_code, event_type)
      -- now that the output is done we scroll us to the top
      vim.api.nvim_win_set_cursor(0, {1, 0})
    end
  })
  -- vim.bo[bufNum].buftype = 'terminal'
  if name then
    local bufferName = 'term://' .. name
    log('setting buf name to '.. bufferName)
    vim.api.nvim_buf_set_name(bufNum, bufferName)
    -- TODO find a way to change name to prevent buf name clash
  end
end

-- a one off terminal to run something and closes after
function MakeSimpleTermForCmd(command, size, name)
  vim.cmd('botright ' .. size .. ' new')

  local bufNum = vim.api.nvim_get_current_buf()
  local winNum = vim.api.nvim_get_current_win()
  vim.bo[bufNum].buftype = 'nofile'
  vim.bo[bufNum].bufhidden = 'hide'
  vim.wo[winNum].number = false
  vim.wo[winNum].signcolumn = 'no'

  local chan_id = vim.fn.termopen({'/bin/sh', '-c', command}, {
    on_exit = function(job_id, exit_code, event_type)
      vim.api.nvim_buf_delete(bufNum, {force = true})
    end
  })
  vim.cmd('startinsert')
  -- vim.bo[bufNum].buftype = 'terminal'
  if name then
    vim.api.nvim_buf_set_name(bufNum, name)
    -- TODO find a way to change name to prevent buf name clash
  end
end


-- nvim term really needs tlc for pasting
vim.keymap.set('t', '<M-v>', '<C-\\><C-n>"+pi')

-- open a terminal running shell. command works like a toggle
vim.cmd[[
  " Terminal Function
  let g:term_buf = 0
  let g:term_win = 0
  function! TermToggle(height)
    if win_gotoid(g:term_win)
      hide
    else
      botright new
      exec "resize " . a:height
      try
        exec "buffer " . g:term_buf
      catch
        call termopen($SHELL, {"detach": 0})
        let g:term_buf = bufnr("")
        set nonumber
        set norelativenumber
        set signcolumn=no
      endtry
      startinsert!
      let g:term_win = win_getid()
    endif
  endfunction
]]

function get_current_tab_buffer_names()
    local buffers = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" then
            table.insert(buffers, name)
        end
    end
    return buffers
end

-- neovide
if vim.g.neovide then
  -- Put anything you want to happen only in Neovide here
  vim.g.neovide_scroll_animation_far_lines = 99999
  -- vim.g.neovide_window_blurred = true
  vim.g.neovide_cursor_vfx_mode = "sonicboom"
  vim.g.neovide_cursor_animation_length = 0.03
  vim.g.neovide_hide_mouse_when_typing = true
  vim.g.neovide_transparency = 0.9

  -- these aucmds here make the buffers stop scrolling when swapping around buffers.
  vim.api.nvim_create_autocmd("BufLeave", {
    callback = function()
      vim.g.neovide_scroll_animation_length = 0
      -- vim.g.neovide_cursor_animation_length = 0
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function()
      vim.fn.timer_start(70, function()
        vim.g.neovide_scroll_animation_length = 0.3
        -- vim.g.neovide_cursor_animation_length = 0.08
      end)
    end,
  })

  -- this block is for size adjustment
  vim.g.neovide_scale_factor = 1.0
  local change_scale_factor = function(delta)
    vim.g.neovide_scale_factor = vim.g.neovide_scale_factor * delta
  end
  vim.keymap.set("n", "<D-=>", function()
    change_scale_factor(1.05)
  end)
  vim.keymap.set("n", "<D-->", function()
    change_scale_factor(1/1.05)
  end)

  vim.keymap.set('i', '<D-s>', '<ESC>:w<CR>') -- Save
  vim.keymap.set('n', '<D-s>', ':w<CR>') -- Save
  vim.keymap.set('v', '<D-c>', '"+y') -- Copy
  -- vim.keymap.set('n', '<D-v>', '"+P') -- Paste normal mode
  -- vim.keymap.set('v', '<D-v>', '"+P') -- Paste visual mode
  -- vim.keymap.set('c', '<D-v>', '<C-R>+') -- Paste command mode
  -- vim.keymap.set('t', '<D-v>', '<C-\\><C-n>"+pi') -- Paste to term
  -- vim.keymap.set('i', '<D-v>', '<ESC>l"+Pli') -- Paste insert mode
  vim.keymap.set(
    {'n', 'v', 's', 'x', 'o', 'i', 'l', 'c', 't'},
    '<D-v>',
    function() vim.api.nvim_paste(vim.fn.getreg('+'), true, -1) end,
    { noremap = true, silent = true }
  )

  -- -- so for some reason this does not work with vim.keymap.set but it works like this. something wonky going on.
  vim.api.nvim_set_keymap('n', '<D-p>', '<M-p>', { noremap = false })
  -- vim.cmd[[
  --   nmap <D-p> <m-p>
  -- ]]
  -- THIS DOES NOT WORK:
  -- vim.keymap.set('n', '<D-p>', '<m-p>', { noremap = false })

  ----- this uses native fullscreen, and it sucks. will be replaced soon with a hammerspoon solution.
  -- cmd+enter toggles fullscreen
  vim.keymap.set('n', '<D-CR>', function()
    vim.g.neovide_fullscreen = (not vim.g.neovide_fullscreen)
  end, { noremap = true, desc = 'toggle neovide fullscreen' })

  vim.g.neovide_floating_shadow = true
  vim.g.neovide_floating_z_height = 10
  vim.g.neovide_light_angle_degrees = 45
  vim.g.neovide_light_radius = 5

  vim.g.neovide_refresh_rate_idle = 1

  -- some basic dev workflow edifice we can establish as an outcropping out of neovide:
  -- First, cmd D to git log browsing.
  vim.keymap.set('n', '<D-l>', function ()
    MakeTermWindowVimAsPager('git --no-pager log -p | head -n3000 | ~/.cargo/bin/delta --pager=cat', '40', 'Git Log')
  end)
  vim.keymap.set({'n', 't'}, '<D-d>', function ()
    if vim.bo.buftype == 'terminal' then
      -- In terminal buffer (normal or insert mode)
      -- if such a window already exists, launch the next itereation of it!
      for _, bufName in get_current_tab_buffer_names() do
        ---@type string
        local bufName = bufName
        if (bufName:find()) then
        end
      end
      MakeTermWindowVimAsPager('git diff HEAD^', '50', 'Git DIFF PREV 1')
    else
      -- In non-terminal buffer
      MakeTermWindowVimAsPager('git --no-pager diff | ~/.cargo/bin/delta --pager=cat', '40', 'Git Diff')
    end
  end)
  vim.keymap.set('n', '<D-z>', function ()
    MakeTermWindowVimAsPager('echo test; echo path is $PATH; echo here is a hyperlink:; printf "test lol"', '20', 'test')
  end)

  -- commit (ah this is a bit ridiculous opening vim to write a msg inside vim lol)
  vim.keymap.set('n', '<D-c>', function ()
    -- run ~/util/commit-push-interactive.sh in a terminal split
    MakeSimpleTermForCmd('~/util/commit-push-interactive.sh', '20', 'Git Commit')
  end)

  vim.keymap.set('n', '<D-t>', function ()
    MakeSimpleTermForCmd('zsh', '25', 'zsh')
  end)

  -- override osc52 yank (not useful in neovide) with regular yank
  vim.keymap.set({"n", 'x'}, "<leader>y", '"+y', { desc = "Copy to + clipboard (neovide override)" })
  vim.keymap.set("n", "<leader>Y", 'ggVG"+y', { desc = "Copy entire buffer to clipboard (neovide override)"})

end
