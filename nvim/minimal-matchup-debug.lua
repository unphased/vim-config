vim.cmd([[
  set nocompatible
  " load match-up
  let &rtp  = '~/.local/share/nvim/lazy/vim-matchup,' . &rtp
  let &rtp .= ',~/.local/share/nvim/lazy/vim-matchup/after'

  " load treesitter
  let &rtp  = '~/.local/share/nvim/lazy/nvim-treesitter,' . &rtp
  let &rtp .= ',~/.local/share/nvim/lazy/nvim-treesitter/after'

  " load other plugins, if necessary
  " let &rtp = '~/path/to/other/plugin,' . &rtp
  filetype plugin indent on
  set nocompatible
  syntax enable
]])

-- set up treesitter
require("nvim-treesitter.configs").setup({
  matchup = {
    enable = true,
    disable = {},
  },
})

-- match-up options
vim.g.matchup_matchparen_offscreen = { method = "popup" }
vim.g.matchup_surround_enabled = 1
vim.g.matchup_matchparen_deferred = 1
vim.g.matchup_matchparen_hi_surround_always = 1
