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

require("lazy").setup({
  {
     "nvim-neo-tree/neo-tree.nvim",
     branch = "v2.x",
     dependencies = { 
       "nvim-lua/plenary.nvim",
       "nvim-tree/nvim-web-devicons", -- not strictly required, but recommended
       "MunifTanjim/nui.nvim",
     }
  },
  "tpope/vim-surround",
  "tpope/vim-sleuth",
  'AndrewRadev/switch.vim',
  'junegunn/fzf.vim'
}, {
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

vim.keymap.set('n', '<c-n>', function()

end
)

-- settings

vim.o.number = true

