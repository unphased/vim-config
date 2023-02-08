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
  'junegunn/fzf',
  'github/copilot.vim',
  'ethanholz/nvim-lastplace',
  {
    'dundalek/lazy-lsp.nvim', dependencies = { 'neovim/nvim-lspconfig' }
  },
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    dependencies = {
      -- show treesitter nodes
      "nvim-treesitter/playground", -- enable more advanced treesitter-aware text objects
      "nvim-treesitter/nvim-treesitter-textobjects", -- add rainbow highlighting to parens and brackets
      "p00f/nvim-ts-rainbow",
      "JoosepAlviste/nvim-ts-context-commentstring"
    }
  }, -- show nerd font icons for LSP types in completion menu
  "onsails/lspkind-nvim", -- status line plugin
  "feline-nvim/feline.nvim",
  'lewis6991/gitsigns.nvim',
  'lambdalisue/suda.vim'
}
