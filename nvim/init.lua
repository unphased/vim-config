-- -- -- TODO LIST
--[[

- todo list (track stuff to port over, track stuff i want to achieve)
- still want that one key to cycle windows and then tabs, even while trying to make the ctrl-w w, gt defaults
- yank window to new tab in next/prev direction or into new tab (also like how this is consistent with how the analogous one works in tmux)
- my prized alt-, and friends automations (to be fair i've been getting good at manually leveraging dot-repeat which is decently good retraining)
- \p for toggle paste and removing indent markers and stuff like that in paste mode to make it work like a copy-mode
- f10 handling for tmux
- prevent mouse interaction from messing with insert mode cursor position
- implement insert mode ctrl backspace
- implement insert mode reliable ctrl/alt arrows
- implement semantic highlight removal (i want this in possibly lua right now but also definitely dockerfile) by literally selecting them out at the highlight group level (ah dang, no worky for dockerls)

--]]

-- traditional settings

vim.o.title = true
vim.o.number = true
vim.o.undofile = true
vim.o.undodir = vim.env.HOME .. "/.tmp"
vim.o.termguicolors = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.numberwidth = 3
-- vim.o.cmdheight = 0

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

-- plugins
require("lazy").setup("plugins", {
  change_detection = {
    -- automatically check for config file changes and reload the ui
    enabled = true,
    notify = true, -- get a notification when changes are found
  },
  checker = { enabled = true, notify = false, },
})

-- mappings
vim.keymap.set("n", "<leader>w", ":set wrap!<cr>")

--- disabling for now since regular works with cmp cmdline completion
-- vim.keymap.set({ "n", "v" }, "/", "/\\V")
vim.keymap.set({ "n", "v" }, "k", "gk")
vim.keymap.set({ "n", "v" }, "j", "gj")
vim.keymap.set({ "n", "v" }, "gk", "k")
vim.keymap.set({ "n", "v" }, "gj", "j")

vim.keymap.set({ "v", "n" }, "K", "5gk")
vim.keymap.set({ "v", "n" }, "J", "5gj")
vim.keymap.set({ "v", "n" }, "H", "7h")
vim.keymap.set({ "v", "n" }, "L", "7l")

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
vim.keymap.set({ "n", "v" }, "<bs>", "b")
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

-- dumping vimL code that I didnt bother porting yet here for expedient bringup
vim.cmd([[

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
  highlight GitSignsChangeInline guibg=#302ee8 guifg=NONE
  highlight GitSignsDeleteInline guibg=#68221a guifg=NONE
  highlight GitSignsAddInline guibg=#30582e guifg=NONE

  " highlight GitSignsAddLnInline guibg=#30ff2e guifg=NONE
  " highlight GitSignsChangeLnInline guibg=#0000ff guifg=NONE
  highlight GitSignsDeleteLnInline gui=underdouble guisp=#800000 guibg=NONE guifg=NONE
  " highlight GitSignsDeleteVirtLn guibg=NONE guifg=NONE
  highlight GitSignsDeleteVirtLnInLine guibg=#800000

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

  nnoremap = :vertical res +5<CR>
  nnoremap - :vertical res -5<CR>
  nnoremap + :res +4<CR>
  nnoremap _ :res -4<CR>


  nnoremap <tab> gt
  nnoremap <s-tab> gT

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
]])

-- gvar settings for plugins
vim.g.matchup_matchparen_offscreen = { method = "popup" }
vim.g.matchup_surround_enabled = 1
vim.g.matchup_matchparen_deferred = 1
vim.g.matchup_matchparen_hi_surround_always = 1

vim.opt.titlestring = "NVIM %f %h%m%r%w (%{tabpagenr()} of %{tabpagenr('$')})"

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
    end, {expr=true})

    map('n', '[c', function()
      if vim.wo.diff then return '[c' end
      vim.schedule(function() gs.prev_hunk() end)
      return '<Ignore>'
    end, {expr=true})
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

local tele_actions = require('telescope.actions')
require('telescope').setup{
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
local telescope_builtin = require("telescope.builtin")
vim.keymap.set("n", "<c-p>", function ()
  telescope_builtin.find_files({ find_command = { 'fd', '--type', 'f' } })
end)
-- hard to believe ctrl+G was not already bound by vim
vim.keymap.set("n", "<c-g>", telescope_builtin.live_grep, { desc = "Telescope Live Grep" })
vim.keymap.set("n", "<leader>m", telescope_builtin.man_pages, { desc = "Telescope Man Pages" })
vim.keymap.set("n", "<f6>", telescope_builtin.oldfiles, { desc = "Telescope Recent Files" })
vim.keymap.set("n", "<leader>b", telescope_builtin.buffers, { desc = "Telescope Buffers" })
-- "vim help"
vim.keymap.set('n', '<leader>vh', telescope_builtin.help_tags, { desc = "Telescope Help Tags" })

require("nvim-lastplace").setup({})
require("nvim-autopairs").setup({ map_cr = false })
require("Comment").setup()

require("nvim-treesitter.configs").setup({
  -- A list of parser names, or "all" (the four listed parsers should always be installed)
  ensure_installed = { "c", "lua", "vim", "help", "bash", "comment" },

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
  --     init_selection = '<CR>',
  --     --scope_incremental = '<TAB>',
  --     node_incremental = '<CR>',
  --     node_decremental = '<S-TAB>',
  --   },
  -- },
  matchup = {
    enable = false, -- mandatory, false will disable the whole extension
    disable = {}, -- optional, list of language that will be disabled
  },

  textobjects = {
    swap = {
      enable = true,
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
        ["ai"] = "@parameter.inner",
        ["aa"] = "@parameter.outer",
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

-- require('lazy-lsp').setup {
--   -- By default all available servers are set up. Exclude unwanted or misbehaving servers.
--   excluded_servers = {
--     "ccls", "zk",
--   },
--   -- Default config passed to all servers to specify on_attach callback and other options.
--   default_config = {
--     flags = {
--       debounce_text_changes = 150,
--     },
--     -- on_attach = on_attach,
--     -- capabilities = capabilities,
--   },
--   -- Override config for specific servers that will passed down to lspconfig setup.
--   configs = {
--     sumneko_lua = {
--       cmd = {"lua-language-server"},
--       -- on_attach = on_lua_attach,
--       -- capabilities = capabilities,
--       settings = {
--         Lua = {
--           runtime = {
--             version = 'LuaJIT',
--           },
--           diagnostics = {
--             globals = { 'vim' }
--           }
--         }
--       }
--     },
--   },
-- }

require("trouble").setup({
  -- your configuration comes here
  -- or leave it empty to use the default settings
  -- refer to the configuration section below
})

require("neo-tree").setup({
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

require("nvim-cursorline").setup({
  cursorline = { enable = false },
  -- cursorline = {
  --   enable = true,
  --   timeout = 5,
  --   number = true,
  --   hl = { bg = "#262626" }, -- seems to be overridden by at least a few CSs but worth specifying?
  -- },
  cursorword = {
    enable = true,
    min_length = 2,
    hl = { bold = true, underline = false },
  },
})

vim.cmd([[ 
  set cursorline
]])

require("colorizer").setup()

-- general plugin specific binds (TODO: put together when refactoring the plugin configs into files)
vim.keymap.set("n", "<leader>y", require("osc52").copy_operator, { expr = true })
vim.keymap.set("n", "<leader>yy", "<leader>c_", { remap = true })
vim.keymap.set("x", "<leader>y", require("osc52").copy_visual)

-- We can explicitly use the server's own clipboard or fallback clipboard file if we somehow know
-- that we want the buffer that's in there.
-- nnoremap <Leader>p :read !pbpaste<CR>
vim.keymap.set("n", "<leader>p", ":read !pbpaste<CR>")
vim.keymap.set("v", "<leader>p", ":!pbpaste<CR>")

-- do not use read here so that the selected stuff gets slurped.
-- vnoremap <Leader>p :!pbpaste<CR>

-- lspconfig
-- set border
local _border = "rounded"

vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(
  vim.lsp.handlers.hover, {
    border = _border
  }
)

vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(
  vim.lsp.handlers.signature_help, {
    border = _border
  }
)

vim.diagnostic.config{
  float={border=_border}
}

local opts = {}
vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, { desc = "Open diagnostic in float" })
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Go to previous diagnostic" })
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Go to next diagnostic" })
vim.keymap.set("n", "<leader>q", vim.diagnostic.setloclist, { desc = "Set diagnostics to location list" })

-- indent-blankline

vim.opt.list = true
-- opting to not use eol since it's too noisy looking imo
-- "eol:↴"
vim.opt.listchars = "tab:→ ,extends:»,precedes:«,trail:·,nbsp:◆"

vim.cmd("highlight IndentBlanklineContextChar guifg=#66666f gui=nocombine")
vim.cmd("highlight IndentBlanklineContextStart gui=underdouble guisp=#66666f")
vim.cmd("highlight IndentBlanklineIndent1 gui=nocombine guifg=#383838")
vim.cmd("highlight IndentBlanklineIndent2 gui=nocombine guifg=#484848")
require("indent_blankline").setup({
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


-- local navic = require("nvim-navic")
--
-- require("lsp-zero").extend_lspconfig({
--   set_lsp_keymaps = false,
--   -- review whether an autocmd is preferable to this. possibly not
--   on_attach = function(client, bufnr)
--     -- print("lsp zero lspconfig extend client", vim.inspect(client.name))
--     local opts = { buffer = bufnr }
--
--     -- enable navic
--     if client.server_capabilities.documentSymbolProvider then
--         navic.attach(client, bufnr)
--     end
--
--     vim.keymap.set("n", "?", vim.lsp.buf.hover, opts)
--     vim.keymap.set("n", "<leader>r", vim.lsp.buf.rename, opts)
--     ---
--     -- and many more...
--     ---
--   end,
-- })

-- navic.setup()
-- vim.o.winbar = "%{%v:lua.require'nvim-navic'.get_location()%}"
--
-- require("mason").setup()
-- require("mason-lspconfig").setup()
--
-- require("mason-lspconfig").setup_handlers({
--   function(server_name)
--     -- print("mason-lspconfig setup_handlers", server_name)
--     require("lspconfig")[server_name].setup({})
--   end,
--   ["lua_ls"] = function()
--     require("lspconfig")["lua_ls"].setup({
--       settings = {
--         Lua = {
--           diagnostics = {
--             enable = true,
--             globals = { "vim" },
--           },
--           runtime = {
--             version = "LuaJIT",
--           },
--         },
--       },
--     })
--   end,
-- })
--
-- ---
-- -- Diagnostic config
-- ---
--
-- require("lsp-zero").set_sign_icons()
-- --- Not sure -- the next line disables/interferes w/ Trouble inline virtual text stuff
-- -- vim.diagnostic.config(require('lsp-zero').defaults.diagnostics({}))
--
-- ---
-- -- Snippet config
-- ---
--
--
-- ---
-- -- Autocompletion
-- ---
--
-- vim.opt.completeopt = { "menu", "menuone" }
--
local null_ls = require("null-ls")
-- --
-- -- null_ls.setup({
-- --   sources = {
-- --     null_ls.builtins.diagnostics.shellcheck,
-- --     null_ls.builtins.diagnostics.hadolint,
-- --     null_ls.builtins.diagnostics.yamllint,
-- --     null_ls.builtins.diagnostics.selene,
-- --   }
-- -- })
-- -- local null_ls = require 'null-ls'

require("mason-null-ls").setup({
  ensure_installed = { "shellcheck" },
  automatic_setup = true,
})
require("mason-null-ls").setup_handlers({
  function(source_name, methods)
    -- print("mason-null-ls-handler: source_name:" .. source_name)
    -- print("mason-null-ls-handler: methods:" .. vim.inspect(methods))
    -- all sources with no handler get passed here

    -- To keep the original functionality of `automatic_setup = true`,
    -- please add the below.
    require("mason-null-ls.automatic_setup")(source_name, methods)
  end,

  -- stylua = function(source_name, methods)
  --   null_ls.register(null_ls.builtins.formatting.stylua)
  -- end,

  ---- Semgrep is cool but takes way long to run (need to find out how to extend timeout) and also does not commonly emit much output. So I'm not really interested in it right now.
  -- semgrep = function(source_name, methods)
  --   null_ls.register(null_ls.builtins.diagnostics.semgrep.with({
  --     extra_args = { "--config", "auto" },
  --   }))
  -- end,
  --
  -- print("semgrep obtained as:", vim.inspect(null_ls.builtins.diagnostics.semgrep)),
  -- print("semgrep prospective:", vim.inspect(null_ls.builtins.diagnostics.semgrep.with({
  --   extra_args = { "--config", "auto" },
  -- })))
})

null_ls.setup({
  debug = true,
  sources = null_ls.builtins.code_actions.gitsigns
})

vim.opt.completeopt="menu,menuone,noselect"

local cmp = require'cmp'
local lspkind = require('lspkind')

local luasnip = require("luasnip")
-- luasnip.config.set_config({
  -- region_check_events = "InsertEnter",
  -- delete_check_events = "InsertLeave",
-- })

require("luasnip.loaders.from_vscode").lazy_load()

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
  snippet = {
    expand = function(args)
      require'luasnip'.lsp_expand(args.body)
    end
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
      elseif luasnip.expand_or_jumpable() then
        luasnip.expand_or_jump()
      elseif has_words_before() then
        cmp.complete()
      else
        fallback()
      end
    end, { "i", "s" }),

    ["<S-Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_prev_item()
      elseif luasnip.jumpable(-1) then
        luasnip.jump(-1)
      else
        fallback()
      end
    end, { "i", "s" }),
  }),
  sources = cmp.config.sources({
    { name = 'nvim_lsp' },
    -- { name = 'vsnip' }, -- For vsnip users.
    { name = 'luasnip' }, -- For luasnip users.
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
local cmp_autopairs = require('nvim-autopairs.completion.cmp')
cmp.event:on(
  'confirm_done',
  cmp_autopairs.on_confirm_done()
)

require("neodev").setup({
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

local capabilities = require('cmp_nvim_lsp').default_capabilities()

local ext = function(table, key, value)
  local tbl = table
  tbl[key] = value
  return tbl
end

local goto_preview = require('goto-preview')

-- keymaps!!
local lsp_attach = function (x, bufnr)
  local engine = x.name;
  print("lsp_attach:", engine, "bufnr="..bufnr)
  local bufopts = { noremap=true, silent=true, buffer=bufnr }
  vim.keymap.set('n', 'gD', goto_preview.goto_preview_type_definition, ext(bufopts, "desc", "Go to Type Definition (preview window)"))
  vim.keymap.set('n', 'gd', goto_preview.goto_preview_definition, ext(bufopts, "desc", "Go to Definition (preview window)"))
  vim.keymap.set('n', '?', vim.lsp.buf.hover, ext(bufopts, "desc", "Hover"))

  vim.keymap.set('n', 'gi', goto_preview.goto_preview_implementation, ext(bufopts, "desc", "Go to Implementation (preview window)"))
  vim.keymap.set('n', '<leader>h', vim.lsp.buf.signature_help, ext(bufopts, "desc", "Signature help"))
  -- vim.keymap.set('n', '<space>wa', vim.lsp.buf.add_workspace_folder, bufopts)
  -- vim.keymap.set('n', '<space>wr', vim.lsp.buf.remove_workspace_folder, bufopts)
  -- vim.keymap.set('n', '<space>wl', function()
  --   print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
  -- end, bufopts)
  -- vim.keymap.set('n', '<space>D', vim.lsp.buf.type_definition, bufopts)
  vim.keymap.set('n', '<leader>r', vim.lsp.buf.rename, ext(bufopts, "desc", "Rename"))
  vim.keymap.set('n', '<leader>ca', function() vim.cmd('CodeActionMenu') end, ext(bufopts, "desc", "Code Action Menu"))
  vim.keymap.set('n', 'gr', goto_preview.goto_preview_references, ext(bufopts, "desc", "Go to References"))
  vim.keymap.set('n', '<leader>=', function() vim.lsp.buf.format { async = true } end, ext(bufopts, "desc", "Format Buffer"))
end

require("mason-lspconfig").setup_handlers {
  -- The first entry (without a key) will be the default handler
  -- and will be called for each installed server that doesn't have
  -- a dedicated handler.
  function (server_name) -- default handler (optional)
    require("lspconfig")[server_name].setup {
      capabilities = capabilities,
      on_attach = lsp_attach,
    }
  end,
  -- Next, you can provide a dedicated handler for specific servers. Don't forget to bring capabilities and on_attach in.
  ["dockerls"] = function ()
    print("dockerls caps =" .. vim.inspect(capabilities))
    require("lspconfig")["dockerls"].setup {
      capabilities = capabilities,
      on_attach = lsp_attach,
    }
  end,
  ["lua_ls"] = function ()
    require("lspconfig")["lua_ls"].setup {
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

require("yanky").setup({
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
  hi incSearch cterm=bold ctermfg=black ctermbg=yellow guibg=#a04080 guifg=NONE
  hi Visual term=reverse ctermbg=238 guibg=#505760
  hi VertSplit guifg=#505760
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

vim.keymap.set("n", "<leader>t", ":Trouble<CR>")

-- set the icons for diagnostic
vim.cmd [[
  sign define DiagnosticSignError text=✘  linehl= texthl=DiagnosticSignError numhl=
  sign define DiagnosticSignWarn text= linehl= texthl=DiagnosticSignWarn numhl= 
  sign define DiagnosticSignInfo text=  linehl= texthl=DiagnosticSignInfo numhl= 
  sign define DiagnosticSignHint text=⚑  linehl= texthl=DiagnosticSignHint numhl=
]]

-- helper for debug
local should_profile = os.getenv("NVIM_PROFILE")
if should_profile then
  require("profile").instrument_autocmds()
  if should_profile:lower():match("^start") then
    require("profile").start("*")
  else
    require("profile").instrument("*")
  end
end

local function toggle_profile()
  local prof = require("profile")
  if prof.is_recording() then
    prof.stop()
    vim.ui.input({ prompt = "Save profile to:", completion = "file", default = "profile.json" }, function(filename)
      if filename then
        prof.export(filename)
        vim.notify(string.format("Wrote %s", filename))
      end
    end)
  else
    prof.start("*")
  end
end
vim.keymap.set("", "<f1>", toggle_profile)

-- helper
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

-- putting here late so log global is present for it
require("heirline_conf.heirline")

