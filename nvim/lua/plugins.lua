return {
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
  "tpope/vim-repeat",
  "numToStr/Comment.nvim",
  'AndrewRadev/switch.vim',
  'junegunn/fzf.vim',
  'github/copilot.vim',
  'ethanholz/nvim-lastplace',
  {
    'dundalek/lazy-lsp.nvim', dependencies = { 'neovim/nvim-lspconfig' }
  }
}
