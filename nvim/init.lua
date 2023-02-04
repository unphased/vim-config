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

-- settings

vim.o.number = true
vim.o.undofile = true
vim.o.undodir = vim.env.HOME .. "/.tmp"

print ("undodir: " .. vim.o.undodir)

