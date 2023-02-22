return {
  {
    'glepnir/zephyr-nvim',
    lazy = false,
    priority = 1000,
  },
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
  -- 'junegunn/fzf.vim',
  -- 'junegunn/fzf',
  { 'nvim-telescope/telescope.nvim', dependencies = { 'nvim-lua/plenary.nvim' }, branch = "0.1.x" },
  { 'nvim-telescope/telescope-fzf-native.nvim', build = 'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release && cmake --install build --prefix build' },
  'norcalli/nvim-colorizer.lua',
  'github/copilot.vim',
  'ethanholz/nvim-lastplace',
  -- {
  --   'dundalek/lazy-lsp.nvim', dependencies = { 'neovim/nvim-lspconfig' }
  -- },
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    dependencies = {
      -- show treesitter nodes
      "nvim-treesitter/playground", -- enable more advanced treesitter-aware text objects
      "nvim-treesitter/nvim-treesitter-textobjects", -- add rainbow highlighting to parens and brackets
      -- "p00f/nvim-ts-rainbow",
      "JoosepAlviste/nvim-ts-context-commentstring"
    }
  }, -- show nerd font icons for LSP types in completion menu
  "nvim-treesitter/nvim-treesitter-context",
  -- "onsails/lspkind-nvim", -- status line plugin
  "MunifTanjim/nougat.nvim",
  'lewis6991/gitsigns.nvim',
  'lambdalisue/suda.vim',
  ---- Not sure about this one because i am trying to stick to treesitter for stuff like this at the moment
  -- {
  --   "SmiteshP/nvim-navic",
  --   dependencies = { "neovim/nvim-lspconfig" }
  -- }
  -- "rafi/awesome-vim-colorschemes",
  -- "jlanzarotta/colorSchemeExplorer",
  "ojroques/nvim-osc52",
  "yamatsum/nvim-cursorline",
  "andymass/vim-matchup",
  "AndrewRadev/splitjoin.vim",
  "windwp/nvim-autopairs",
  "lukas-reineke/indent-blankline.nvim",
  {
    "folke/trouble.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
  },
  "onsails/lspkind-nvim",
  -- {
  --   "glepnir/lspsaga.nvim",
  --   event = "BufRead",
  --   config = function()
  --     require("lspsaga").setup({})
  --   end,
  --   dependencies = {
  --     { 'neovim/nvim-lspconfig' },
  --     {"nvim-tree/nvim-web-devicons"},
  --     --Please make sure you install markdown and markdown_inline parser
  --     {"nvim-treesitter/nvim-treesitter"}
  --   }
  -- },
  {
    "hrsh7th/nvim-cmp",
    -- load cmp on InsertEnter
    event = "InsertEnter",
    -- these dependencies will only be loaded when cmp loads
    -- dependencies are always lazy-loaded unless specified otherwise
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      "hrsh7th/cmp-cmdline",
    },
    config = function()
      -- ...
    end,
  },
  'neovim/nvim-lspconfig',
  "williamboman/mason.nvim",
  "williamboman/mason-lspconfig.nvim",
}
