vim.cmd([[ colorscheme habamax ]])

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

-- mappings

vim.keymap.set('n', 'k', 'gk')
vim.keymap.set('n', 'j', 'gj')
vim.keymap.set('n', 'gk', 'k')
vim.keymap.set('n', 'gj', 'j')

vim.keymap.set('n', 'K', '5gk')
vim.keymap.set('n', 'J', '5gj')
vim.keymap.set('n', 'H', '7h')
vim.keymap.set('n', 'L', '7l')

-- Joining lines with Ctrl+N
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
vim.keymap.set({'i', 's', 'c'}, '<F10>', '<esc>')

-- example of vimL code didnt bother porting
vim.cmd([[
  noremap <C-S> :update<CR>
  vnoremap <C-S> <ESC>:update<CR>
  cnoremap <C-S> <C-C>:update<CR>
  inoremap <C-S> <ESC>:update<CR>
  noremap <m-s> :update<CR>
  vnoremap <m-s> <ESC>:update<CR>
  cnoremap <m-s> <C-C>:update<CR>
  inoremap <m-s> <ESC>:update<CR>
]])

-- settings

vim.o.title = true
vim.o.number = true
vim.o.undofile = true
vim.o.undodir = vim.env.HOME .. "/.tmp"

-- autocmds
-- autocmd BufEnter * let &titlestring = "NVIM " . expand("%:t")
vim.opt.titlestring = "NVIM %f %h%m%r%w (%{tabpagenr()} of %{tabpagenr('$')})"

-- plugin settings
require('lazy-lsp').setup {
  -- By default all available servers are set up. Exclude unwanted or misbehaving servers.
  excluded_servers = {
    "ccls", "zk",
  },
  -- Default config passed to all servers to specify on_attach callback and other options.
  default_config = {
    flags = {
      debounce_text_changes = 150,
    },
    -- on_attach = on_attach,
    -- capabilities = capabilities,
  },
  -- Override config for specific servers that will passed down to lspconfig setup.
  configs = {
    sumneko_lua = {
      cmd = {"lua-language-server"},
      -- on_attach = on_lua_attach,
      -- capabilities = capabilities,
      settings = {
        Lua = {
          runtime = {
            version = 'LuaJIT',
          },
          diagnostics = {
            globals = { 'vim' }
          }
        }
      }
    },
  },
}
