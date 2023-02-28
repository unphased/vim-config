return {
  {
    'unphased/zephyr-nvim',
    lazy = false,
    priority = 1000,
    config = function ()
      vim.cmd([[
        colorscheme zephyr
      ]])
    end
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
  -- {
  --    "zbirenbaum/copilot-cmp",
  --    dependencies = { "zbirenbaum/copilot.lua" },
  -- },
  'ethanholz/nvim-lastplace',
  { 'github/copilot.vim', init = function()
    vim.cmd([[
      imap <silent><script><expr> <c-space> copilot#Accept("\<CR>")
      let g:copilot_no_tab_map = v:true
    ]])
  end },
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
  -- "onsails/lspkind-nvim",
  { "jose-elias-alvarez/null-ls.nvim", dependencies = { 'nvim-lua/plenary.nvim' } },
  "jay-babu/mason-null-ls.nvim",
  "inkarkat/vim-ingo-library",
  { "inkarkat/vim-SearchHighlighting", init = function ()
    vim.keymap.set('n', '<CR>', '<Plug>SearchHighlightingStar')
  end },
  {
    'VonHeikemen/lsp-zero.nvim',
    branch = 'v1.x',
    dependencies = {
      -- LSP Support
      {'neovim/nvim-lspconfig'},             -- Required
      {'williamboman/mason.nvim'},           -- Optional
      {'williamboman/mason-lspconfig.nvim'}, -- Optional

      -- Autocompletion
      {'hrsh7th/nvim-cmp'},         -- Required
      {'hrsh7th/cmp-nvim-lsp'},     -- Required
      {'hrsh7th/cmp-buffer'},       -- Optional
      {'hrsh7th/cmp-cmdline'},       -- Optional
      {'hrsh7th/cmp-path'},         -- Optional
      {'saadparwaiz1/cmp_luasnip'}, -- Optional
      {'hrsh7th/cmp-nvim-lua'},     -- Optional

      -- Snippets
      {'L3MON4D3/LuaSnip'},             -- Required
      {'rafamadriz/friendly-snippets'}, -- Optional
    }
  },
  'rhysd/conflict-marker.vim'
}
