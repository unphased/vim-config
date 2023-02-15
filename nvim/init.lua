-- traditional settings

vim.o.title = true
vim.o.number = true
vim.o.undofile = true
vim.o.undodir = vim.env.HOME .. "/.tmp"
vim.o.termguicolors = true

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
})

-- settings that may require some loader stuff
vim.cmd('colorscheme habamax')

-- mappings

vim.keymap.set({'n', 'v'}, 'k', 'gk')
vim.keymap.set({'n', 'v'}, 'j', 'gj')
vim.keymap.set({'n', 'v'}, 'gk', 'k')
vim.keymap.set({'n', 'v'}, 'gj', 'j')

vim.keymap.set({'v', 'n'}, 'K', '5gk')
vim.keymap.set({'v', 'n'}, 'J', '5gj')
vim.keymap.set({'v', 'n'}, 'H', '7h')
vim.keymap.set({'v', 'n'}, 'L', '7l')

-- Joining lines with Ctrl+N. Keep cursor stationary.
vim.keymap.set('n', '<c-n>', function()
  local line, col = unpack(vim.api.nvim_win_get_cursor(0))
  print("line: " .. line .. " col: " .. col)
  vim.cmd('normal! J')
  vim.api.nvim_win_set_cursor(0, { line, col })
end)

-- make it easier to type a colon
vim.keymap.set('n', ';' , ':')

-- make paste not move the cursor
vim.keymap.set('n', 'P', 'P`[')

-- turn F10 into escape
vim.keymap.set({'', '!'}, '<F10>', '<esc>')
vim.keymap.set({'c'}, '<F10>', '<c-c>')

-- normal and visual mode backspace does what b does
vim.keymap.set({'n', 'v'}, '<bs>', 'b')
-- consistency with pagers in normal mode
vim.keymap.set({'n', 'v'}, ' ', '<c-d>')
vim.keymap.set({'n', 'v'}, 'b', '<c-u>')

-- ctrl+b to go back forward in jumplist
vim.keymap.set('n', '<c-b>', '<tab>')

-- hoping to automate entering visual mode
vim.keymap.set('n', '<cr>', 'v<cr>', {remap = true})

-- allow backtick to do the same thing as percent
vim.keymap.set({'n', 'v', 'o'}, '`', '%')

-- dumping vimL code that I didnt bother porting yet here for expedient bringup
vim.cmd([[

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

  " file search
  xmap <C-P> <ESC><C-P>
  omap <C-P> <ESC><C-P>

  nnoremap <F6> :History<CR>
  inoremap <F6> <ESC>:History<CR>
  nnoremap <c-p> :Files<CR>
  nnoremap <c-g> :GFiles?<CR>

  nnoremap <tab> gt
  nnoremap <s-tab> gT

  nnoremap <leader>f :NeoTreeShowToggle<CR>

]])

-- gvar settings for plugins
vim.g.matchup_matchparen_offscreen = { method = "popup" }
vim.g.matchup_surround_enabled = 1
vim.g.matchup_matchparen_deferred = 1
vim.g.matchup_matchparen_hi_surround_always = 1

function _G.overwrite_file(filename, payload)
  local log_file_path = vim.env.HOME..'/'..filename
  local log_file = io.open(log_file_path, "w")
  log_file:write(payload)
  log_file:close()
end

vim.opt.titlestring = "NVIM %f %h%m%r%w (%{tabpagenr()} of %{tabpagenr('$')})"

-- plugin settings
require("nvim-lastplace").setup {}
require("nvim-autopairs").setup {}
require('Comment').setup()

require('feline').setup()
require('feline').winbar.setup()

require('gitsigns').setup({
  current_line_blame = true, -- Toggle with `:Gitsigns toggle_current_line_blame`
  current_line_blame_opts = {
    virt_text = true,
    virt_text_pos = 'eol', -- 'eol' | 'overlay' | 'right_align'
    delay = 400,
    ignore_whitespace = false,
  },
})

require'nvim-treesitter.configs'.setup {
  -- A list of parser names, or "all" (the four listed parsers should always be installed)
  ensure_installed = { "c", "lua", "vim", "help" },

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
    disable = {"python", "lua"}
  },
  incremental_selection = {
    enable = true,
    keymaps = {
      init_selection = '<CR>',
      --scope_incremental = '<TAB>',
      node_incremental = '<CR>',
      node_decremental = '<S-TAB>',
    },
  },
  matchup = {
    enable = true, -- mandatory, false will disable the whole extension
    disable = {},  -- optional, list of language that will be disabled
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
}

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

require('nvim-cursorline').setup {
  cursorline = {
    enable = false,
    timeout = 5,
    number = true,
  },
  cursorword = {
    enable = true,
    min_length = 2,
    hl = { bold = true, underline = false, strikethrough = true, undercurl = true, italic = true, sp = "red" },
  }
}

-- general plugin specific binds (TODO: put together when refactoring the plugin configs into files)
vim.keymap.set('n', '<leader>y', require('osc52').copy_operator, {expr = true})
vim.keymap.set('n', '<leader>yy', '<leader>c_', {remap = true})
vim.keymap.set('x', '<leader>y', require('osc52').copy_visual)

-- We can explicitly use the server's own clipboard or fallback clipboard file if we somehow know 
-- that we want the buffer that's in there.
-- nnoremap <Leader>p :read !pbpaste<CR>
vim.keymap.set('n', '<leader>p', ':read !pbpaste<CR>')
vim.keymap.set('v', '<leader>p', ':!pbpaste<CR>')

-- do not use read here so that the selected stuff gets slurped.
-- vnoremap <Leader>p :!pbpaste<CR>

-- lspconfig
local opts = {}
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, opts)
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, opts)
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, opts)
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, opts)

-- helper
function string:split(delimiter)
  local result = { }
  local from  = 1
  local delim_from, delim_to = string.find( self, delimiter, from  )
  while delim_from do
    table.insert( result, string.sub( self, from , delim_from-1 ) )
    from  = delim_to + 1
    delim_from, delim_to = string.find( self, delimiter, from  )
  end
  table.insert( result, string.sub( self, from  ) )
  return result
end

function table:print()
  for key, value in pairs(self) do
    print(key, value)
  end
end
