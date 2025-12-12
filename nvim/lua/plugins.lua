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
  -- { 'dasupradyumna/midnight.nvim', lazy = false, priority = 1000 },
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = {
      "nvim-tree/nvim-web-devicons"
    }
  },
  {
    "antosha417/nvim-lsp-file-operations",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-tree.lua",
    },
    config = function()
      require("lsp-file-operations").setup()
    end,
  },
  "tpope/vim-surround",
  -- "tpope/vim-sleuth",
  {
    'nmac427/guess-indent.nvim',
    init = function()
      require('guess-indent').setup {
        auto_cmd = true,
        override_editorconfig = true
      }
    end,
  },
  "tpope/vim-repeat",
  {
    "folke/ts-comments.nvim",
    opts = {},
    event = "VeryLazy",
    enabled = vim.fn.has("nvim-0.10.0") == 1,
  },
  -- "numToStr/Comment.nvim",
  -- 'AndrewRadev/switch.vim',
  {
    'junegunn/fzf.vim',
    dependencies = {
      { 'junegunn/fzf', build = './install --bin' },
    },
    init = function()
      vim.g.fzf_layout = {
        window = {
          width = 0.95,
          height = 1.0,
          xoffset = 0.0,
          yoffset = 0.0,
        },
      }
      vim.g.fzf_preview_window = { 'up:50%', 'ctrl-/' }
    end,
  },
  { 'nvim-telescope/telescope.nvim', dependencies = { 'nvim-lua/plenary.nvim' } },
  -- 'nvim-telescope/telescope-ui-select.nvim',
  'norcalli/nvim-colorizer.lua',
  -- {
  --    "zbirenbaum/copilot-cmp",
  --    dependencies = { "zbirenbaum/copilot.lua" },
  -- },
  'ethanholz/nvim-lastplace',
  -- {
  --   'dundalek/lazy-lsp.nvim', dependencies = { 'neovim/nvim-lspconfig' }
  -- },
  'nvim-treesitter/nvim-treesitter-textobjects',
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    -- commit = "15d327fe6324d8269451131ec34ad4f2a8ef1e01",
    -- dependencies = {
      -- show treesitter nodes
      -- removing this dependency because specifying my own fork of nvim-treesitter-textobjects now.
      -- "nvim-treesitter/nvim-treesitter-textobjects", -- add rainbow highlighting to parens and brackets
      -- "p00f/nvim-ts-rainbow",
      -- "JoosepAlviste/nvim-ts-context-commentstring"
    -- }
  }, -- show nerd font icons for LSP types in completion menu
  "nvim-treesitter/nvim-treesitter-context",
  "onsails/lspkind-nvim", -- status line plugin
  -- {
  --   "MunifTanjim/nougat.nvim",
  --   config = function ()
  --     require("nougat")
  --   end
  -- },
  'lewis6991/gitsigns.nvim',
  'SmiteshP/nvim-navic',
  'lambdalisue/suda.vim',
  ---- Not sure about this one because i am trying to stick to treesitter for stuff like this at the moment
  -- {
  --   "SmiteshP/nvim-navic",
  --   dependencies = { "neovim/nvim-lspconfig" }
  -- }
  -- "rafi/awesome-vim-colorschemes",
  -- "jlanzarotta/colorSchemeExplorer",
  "ojroques/nvim-osc52",
  -- "yamatsum/nvim-cursorline",
  "andymass/vim-matchup",
  -- "AndrewRadev/splitjoin.vim",
  "AndrewRadev/linediff.vim",
  "windwp/nvim-autopairs",
  -- "google/vim-searchindex", -- give search index output (i of n matches) that isn't clamped to 99
  { "lukas-reineke/indent-blankline.nvim", main = 'ibl' },
  {
    "folke/trouble.nvim",
    keys = {
      {
        "<leader>xx",
        "<cmd>Trouble diagnostics toggle focus=true<cr>",
        desc = "Diagnostics (Trouble)",
      },
      {
        "<leader>xX",
        "<cmd>Trouble diagnostics toggle filter.buf=0<cr>",
        desc = "Buffer Diagnostics (Trouble)",
      },
      {
        "<leader>cs",
        "<cmd>Trouble symbols toggle focus=false<cr>",
        desc = "Symbols (Trouble)",
      },
      {
        "<C-t>",
        "<cmd>Trouble lsp toggle focus=true<cr>",
        desc = "LSP Definitions / references / ... (Trouble)",
      },
      {
        "<leader>xL",
        "<cmd>Trouble loclist toggle<cr>",
        desc = "Location List (Trouble)",
      },
      {
        "<leader>xQ",
        "<cmd>Trouble qflist toggle<cr>",
        desc = "Quickfix List (Trouble)",
      },
    },
    opts = {
      modes = {
        diagnostics = {
          sort = { "filename", "pos", "severity", "message" },
        }
      },
      preview = {
        scratch = true,
        type = "main",
        border = "rounded",
        title = "Trouble Preview",
        title_pos = "left",
        -- size = { height = 0.7 },
      },
    }, -- for default options, refer to the configuration section for custom setup.
  },
  -- "onsails/lspkind-nvim",
  -- { "jose-elias-alvarez/null-ls.nvim", dependencies = { 'nvim-lua/plenary.nvim' } },
  -- "jay-babu/mason-null-ls.nvim",
  "inkarkat/vim-ingo-library",
  -- { "inkarkat/vim-SearchHighlighting", init = function ()
  --   -- This is set to be disabled in favor of STS *maybe*
  --   vim.keymap.set('n', '<CR>', function ()
  --     if vim.bo.buftype == 'quickfix' or vim.bo.buftype == 'loclist' then
  --       return '<CR>'
  --     else
  --       return '<Plug>SearchHighlightingStar'
  --     end
  --   end, { expr = true })
  --   -- vim.cmd([[
  --   --   nmap <silent> <CR> <Plug>SearchHighlightingStar
  --   --   "" doesn't work
  --   --   " vmap <silent> <CR> <Plug>SearchHighlightingStar
  --   -- ]])
  -- end },
  -- {
  --   'VonHeikemen/lsp-zero.nvim',
  --   branch = 'v2.x',
  --   dependencies = {
  --     -- LSP Support
  --     {'neovim/nvim-lspconfig'},             -- Required
  --     {'williamboman/mason.nvim'},           -- Optional
  --     {'williamboman/mason-lspconfig.nvim'}, -- Optional
  --
  --     -- Autocompletion
  --     {'hrsh7th/nvim-cmp'},         -- Required
  --     {'hrsh7th/cmp-nvim-lsp'},     -- Required
  --     {'hrsh7th/cmp-nvim-lsp-signature-help'},
  --     {'hrsh7th/cmp-buffer'},       -- Optional
  --     {'hrsh7th/cmp-cmdline'},       -- Optional
  --     {'hrsh7th/cmp-path'},         -- Optional
  --     {'hrsh7th/cmp-nvim-lua'},     -- Optional
  --
  --     -- Snippets
  --     -- {'rafamadriz/friendly-snippets'}, -- Optional
  --   }
  -- },

  'neovim/nvim-lspconfig',
  'williamboman/mason.nvim',
  'williamboman/mason-lspconfig.nvim',

  -- Autocompletion
  'hrsh7th/nvim-cmp',
  'hrsh7th/cmp-nvim-lsp',
  'hrsh7th/cmp-nvim-lsp-signature-help',
  'hrsh7th/cmp-buffer',
  'hrsh7th/cmp-cmdline',
  'hrsh7th/cmp-path',
  'hrsh7th/cmp-nvim-lua',
  'rhysd/conflict-marker.vim',
  {
    "aaronhallaert/advanced-git-search.nvim",
    config = function()
      require("telescope").load_extension("advanced_git_search")
    end,
    dependencies = {
      "nvim-telescope/telescope.nvim",
      -- to show diff splits and open commits in browser
      "tpope/vim-fugitive",
    },
  },
  {
    "rebelot/heirline.nvim",
    -- You can optionally lazy-load heirline on UiEnter
    -- to make sure all required plugins and colorschemes are loaded before setup
    event = "UiEnter",
  },
  "gbprod/yanky.nvim",
  "mbbill/undotree",
  -- { 'github/copilot.vim', init = function()
  --   vim.cmd([[
  --     let g:copilot_no_tab_map = v:true
  --     imap <silent><script><expr> <c-space> copilot#Accept("\<CR>")
  --   ]])
  -- end },
  -- 'weilbith/nvim-code-action-menu',
  'wesQ3/vim-windowswap',
  -- 'stevearc/profile.nvim',
  -- For more proper profiling, also check out https://github.com/nvim-lua/plenary.nvim#plenaryprofile
  -- https://github.com/norcalli/profiler.nvim is another but this seems only for requires
  { 'simrat39/symbols-outline.nvim',
    config = function()
      require('symbols-outline').setup({
        keymaps = {
          -- These keymaps can be a string or a table for multiple keys
          close = {"<Esc>", "q"},
          goto_location = "<Cr>",
          focus_location = "o",
          hover_symbol = "<C-space>",
          toggle_preview = "p",
          rename_symbol = "r",
          code_actions = "a",
          fold = "h",
          unfold = "l",
          fold_all = "W",
          unfold_all = "E",
          fold_reset = "R",
        },
        auto_preview = false,
      })
      vim.cmd([[
        nnoremap <silent> <leader>s :SymbolsOutline<CR>
      ]])
    end
  },
  -- {
  --   "iamcco/markdown-preview.nvim",
  --   build = function() vim.fn["mkdp#util#install"]() end,
  --   init = function ()
  --     vim.g.mkdp_auto_start = 0
  --     vim.g.mkdp_auto_close = 0
  --     vim.g.mkdp_refresh_slow = 0
  --     vim.g.mkdp_command_for_global = 0
  --     vim.g.mkdp_echo_preview_url = 1
  --     vim.g.mkdp_page_title = "Markdown Preview"
  --     --- below is for debug, not sure if it works tho
  --     -- vim.cmd([[
  --     --   let $NVIM_MKDP_LOG_FILE = $HOME . '/.tmp/mkdp-log.log'
  --     --   let $NVIM_MKDP_LOG_LEVEL = 'debug'
  --     -- ]])
  --   end
  -- },
  {
    "wallpants/github-preview.nvim",
    -- dir = '~/github-preview.nvim', -- Or the full path to your local clone
    cmd = { "GithubPreviewToggle" },
    keys = { "<leader>mpt" },
    opts = {
      host = "localhost",

      -- port used by local server
      port = 6041,

      -- set to "true" to force single-file mode & disable repository mode
      single_file = false,

      theme = {
        -- "system" | "light" | "dark"
        name = "system",
        high_contrast = false,
      },

      -- define how to render <details> tags on init/content-change
      -- true: <details> tags are rendered open
      -- false: <details> tags are rendered closed
      details_tags_open = true,

      cursor_line = {
        disable = false,

        -- CSS color
        -- if you provide an invalid value, cursorline will be invisible
        color = "#c86414",
        opacity = 0.2,
      },

      scroll = {
        disable = false,

        -- Between 0 and 100
        -- VERY LOW and VERY HIGH numbers might result in cursorline out of screen
        top_offset_pct = 35,
      },

      -- for debugging
      -- nil | "debug" | "verbose"
      -- log_level = "debug",
    },
    config = function(_, opts)
        local gpreview = require("github-preview")
        gpreview.setup(opts)

        local fns = gpreview.fns
        vim.keymap.set("n", "<leader>mpt", fns.toggle)
        vim.keymap.set("n", "<leader>mps", fns.single_file_toggle)
        vim.keymap.set("n", "<leader>mpd", fns.details_tags_toggle)
    end,
  },
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      -- your configuration comes here
      -- or leave it empty to use the default settings
      -- refer to the configuration section below
      plugins = {
        marks = false,
        registers = false,
      }
    },
    keys = {
      {
        "<leader>?",
        function()
          require("which-key").show({ global = false })
        end,
        desc = "Buffer Local Keymaps (which-key)",
      },
    },
  },
  'mechatroner/rainbow_csv',
  {
    'goolord/alpha-nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    config = function ()
        require'alpha'.setup(require'alpha.themes.startify'.config)
    end
  },
  "folke/lazydev.nvim",
  'nvim-lua/plenary.nvim',
  {
    'ruifm/gitlinker.nvim',
    dependencies = { 'nvim-lua/plenary.nvim' },
  },
  -- {
  --   'rmagatti/goto-preview',
  --   init = function()
  --     require('goto-preview').setup {
  --       default_mappings = false,
  --       post_open_hook = function(bufnr)
  --         vim.cmd("setlocal winblend=10")
  --         vim.keymap.set('n', '<Esc>', '<cmd>q<CR>', { buffer = bufnr, silent = true } )
  --         vim.keymap.set('n', 'q', '<cmd>q<CR>', { buffer = bufnr, silent = true } )
  --       end,
  --     }
  --   end
  -- },
  "dnlhc/glance.nvim",
  ------- temporary -- broken on nvim nightly
  "RRethy/vim-illuminate",
  "unphased/syntax-tree-surfer",
  {
    "t-troebst/perfanno.nvim",
    init = function()
      require("perfanno").setup()
    end
  },
  {
    "ggandor/leap.nvim",
    -- keys = {
    --   { "s", mode = { "n", "o" }, desc = "Leap forward to" },
    --   -- { "S", mode = { "n", "o" }, desc = "Leap backward to" },
    --   -- { "gs", mode = { "n", "o" }, desc = "Leap from windows" },
    -- },
  },
  { "chrisgrieser/nvim-spider", lazy = true },
  -- "bekaboo/dropbar.nvim",
  "bekaboo/deadcolumn.nvim",
  "ThePrimeagen/refactoring.nvim",
  { "saecki/live-rename.nvim" },
  'tommcdo/vim-lion',
  -- {
  --   "HampusHauffman/block.nvim",
  --   config = function()
  --     require("block").setup({
  --       percent = 0.8,
  --       depth = 10,
  --       automatic = true,
  --       colors = {
  --          "#222222",
  --          "#333333",
  --          "#444444",
  --          -- "#555555",
  --       }
  --     })
  --   end
  -- },
  'dcampos/nvim-snippy',
  'honza/vim-snippets',
  'dcampos/cmp-snippy',
  {
    'johmsalas/text-case.nvim',
    config = function()
      require('textcase').setup {}
    end
  },
  {
    'stevearc/dressing.nvim',
    opts = {
      select = {
        backend = {
          "nui",
          "builtin"
        }
      }
    },
  },
  -- {
  --   "luckasRanarison/clear-action.nvim",
  --   opts = {
  --     silent = true,
  --     signs = {
  --       position = "eol",
  --       label_fmt = function(actions)
  --         local title = actions[1].title
  --         return #title < 20 and title or title:sub(1, 20) .. "…" -- truncating
  --       end,
  --       show_label = true,
  --     },
  --     popup = {
  --       border = false,
  --       highlights = {
  --         title = "NormalFloat",
  --       },
  --     },
  --     mappings = {
  --       code_action = '<leader>a',
  --     }
  --   }
  -- },
  -- {
  --   'Wansmer/treesj',
  --   -- I am still committed to changing out semicolon (that one is a dumb streamliner for colon that ill get rid of)
  --   -- and comma... I think clever-f has no downsides but i might convince myself to return to regular semicolon and
  --   -- comma. Anyway though in the meantime im going to see if comma works for me as a place to do expandjoin
  --   dependencies = { 'nvim-treesitter/nvim-treesitter' },
  --   config = function()
  --     require('treesj').setup(
  --       { use_default_keymaps = false }
  --     )
  --   end,
  -- },
  'MunifTanjim/nui.nvim',
  {
    'unphased/ts-node-action',
    dependencies = { 'nvim-treesitter' },
    opts = {},
  },
  ---- sadly i have to disable this because the reason for having it (move to file code action) is no longer working
  ---- and besides, i need to integrate volar with ts-ls and doubt it can work for this.
  -- {
  --   "pmizio/typescript-tools.nvim",
  --   dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
  --   opts = {},
  -- },
  -- {
  --   'yioneko/nvim-vtsls',
  --   branch = 'feat-move-to-file-action'
  -- }
  'qpkorr/vim-bufkill',
  -- {
  --   "smilhey/cabinet.nvim", 
  --   config = function () 
  --       local cabinet = require("cabinet")
  --       cabinet:setup()
  --   end
  -- },
  {
    'bloznelis/before.nvim',
    config = function()
      local before = require('before')
      before.setup()

      vim.keymap.set('n', '(', before.jump_to_last_edit, { desc = 'jump to last edit' })
      vim.keymap.set('n', ')', before.jump_to_next_edit, { desc = 'jump to next edit' })
    end
  },
  {
    'AckslD/muren.nvim',
    config = true,
  },
  'skwee357/nvim-prose',
  -- { -- -- does not play nice with possession for some reason
  --   "mhanberg/output-panel.nvim",
  --   event = "VeryLazy",
  --   config = function()
  --     require("output_panel").setup()
  --   end
  -- },
  -- {
  --   -- precognition provides a preview line under cursor in normal mode to help learn word hops
  --   "tris203/precognition.nvim",
  --   --event = "VeryLazy",
  --   opts = {
  --   -- startVisible = true,
  --   -- showBlankVirtLine = true,
  --   -- highlightColor = { link = "Comment" },
  --   -- hints = {
  --   --      Caret = { text = "^", prio = 2 },
  --   --      Dollar = { text = "$", prio = 1 },
  --   --      MatchingPair = { text = "%", prio = 5 },
  --   --      Zero = { text = "0", prio = 1 },
  --   --      w = { text = "w", prio = 10 },
  --   --      b = { text = "b", prio = 9 },
  --   --      e = { text = "e", prio = 8 },
  --   --      W = { text = "W", prio = 7 },
  --   --      B = { text = "B", prio = 6 },
  --   --      E = { text = "E", prio = 5 },
  --   -- },
  --   -- gutterHints = {
  --   --     G = { text = "G", prio = 10 },
  --   --     gg = { text = "gg", prio = 9 },
  --   --     PrevParagraph = { text = "{", prio = 8 },
  --   --     NextParagraph = { text = "}", prio = 8 },
  --   -- },
  --   -- disabled_fts = {
  --   --     "startify",
  --   -- },
  --   },
  -- },
  {
    'stevearc/oil.nvim',
    opts = {},
    -- Optional dependencies
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("oil").setup()
    end
  },
  {
    "LintaoAmons/bookmarks.nvim",
    -- tag = "v0.5.4", -- optional, pin the plugin at specific version for stability
    dependencies = {
      {"nvim-telescope/telescope.nvim"},
      {"kkharji/sqlite.lua"},
      {"stevearc/dressing.nvim"} -- optional: to have the same UI shown in the GIF
    }
  },
  -- 'Shatur/neovim-session-manager',
  'Vimjas/vim-python-pep8-indent',
  {
    "mikavilpas/yazi.nvim",
    event = "VeryLazy",
    ---@type LazySpec
    keys = {
      {
        "<leader>-",
        "<cmd>Yazi<cr>",
        desc = "Open yazi at the current file",
      },
      {
        "<leader>cw",
        "<cmd>Yazi cwd<cr>",
        desc = "Open the file manager in nvim's working directory" ,
      },
      {
        -- NOTE: this requires a version of yazi that includes
        -- https://github.com/sxyazi/yazi/pull/1305 from 2024-07-18
        '<c-up>',
        "<cmd>Yazi toggle<cr>",
        desc = "Resume the last yazi session",
      },
    },
    ---@type YaziConfig
    opts = {
      -- if you want to open yazi instead of netrw, see below for more info
      open_for_directories = false,
      keymaps = {
        show_help = '<f1>',
      },
    },
  },
  -- { 'echasnovski/mini.indentscope', version = '*' },
  -- {
  --   "Exafunction/codeium.nvim",
  --   dependencies = {
  --     "nvim-lua/plenary.nvim",
  --     "hrsh7th/nvim-cmp",
  --   },
  --   config = function()
  --     require("codeium").setup({
  --     })
  --   end
  -- },
  -- {
  --   "sourcegraph/sg.nvim",
  --   dependencies = { "nvim-lua/plenary.nvim", --[[ "nvim-telescope/telescope.nvim ]] },
  --
  --   -- If you have a recent version of lazy.nvim, you don't need to add this!
  --   build = "nvim -l build/init.lua",
  --   config = function ()
  --     require('sg').setup{}
  --   end
  -- },
  {
    'MeanderingProgrammer/render-markdown.nvim',
    dependencies = { 'nvim-treesitter/nvim-treesitter', 'nvim-mini/mini.nvim' },            -- if you use the mini.nvim suite
    -- dependencies = { 'nvim-treesitter/nvim-treesitter', 'nvim-mini/mini.icons' },        -- if you use standalone mini plugins
    -- dependencies = { 'nvim-treesitter/nvim-treesitter', 'nvim-tree/nvim-web-devicons' }, -- if you prefer nvim-web-devicons
    ---@module 'render-markdown'
    ---@type render.md.UserConfig
    opts = {
      code = {
        conceal_delimiters = false,
      }
    },
  },
  -- {
  --   "OXY2DEV/markview.nvim",
  --   priority = 101,
  --   lazy = false,
  --   -- dependencies = { 'nvim-treesitter/nvim-treesitter' }
  --
  --   -- For blink.cmp's completion
  --   -- source
  --   -- dependencies = {
  --   --     "saghen/blink.cmp"
  --   -- },
  -- },
  -- {
  --   'MeanderingProgrammer/render-markdown.nvim',
  --   opts = {
  --     code = {
  --       -- left_pad = 3
  --     }
  --   },
  --   dependencies = { 'nvim-treesitter/nvim-treesitter', 'echasnovski/mini.nvim' }, -- if you use the mini.nvim suite
  --   -- dependencies = { 'nvim-treesitter/nvim-treesitter', 'echasnovski/mini.icons' }, -- if you use standalone mini plugins
  --   -- dependencies = { 'nvim-treesitter/nvim-treesitter', 'nvim-tree/nvim-web-devicons' }, -- if you prefer nvim-web-devicons
  -- },

  -- {
  --   'brianhuster/live-preview.nvim',
  --   dir = '~/live-preview.nvim', -- Or the full path to your local clone
  --   dependencies = {
  --       -- You can choose one of the following pickers
  --       'nvim-telescope/telescope.nvim',
  --       'ibhagwan/fzf-lua',
  --       'echasnovski/mini.pick',
  --   },
  -- },

  -- {
  --   "jake-stewart/multicursor.nvim",
  --   -- branch = "1.0",
  --   config = function()
  --     local mc = require("multicursor-nvim")
  --
  --     -- Add cursors above/below the main cursor.
  --     vim.keymap.set({"n", "v"}, "<s-up>",    function() mc.lineAddCursor(-1) end)
  --     vim.keymap.set({"n", "v"}, "<s-down>",  function() mc.lineAddCursor(1) end)
  --
  --     -- Add a cursor and jump to the next word under cursor.
  --     vim.keymap.set({"n", "v"}, "<c-d>",     function() mc.addCursor("*") end)
  --
  --     -- Jump to the next word under cursor but do not add a cursor.
  --     vim.keymap.set({"n", "v"}, "<c-e>",     function() mc.skipCursor("*") end)
  --
  --     -- Rotate the main cursor.
  --     vim.keymap.set({"n", "v"}, "<s-left>",  mc.nextCursor)
  --     vim.keymap.set({"n", "v"}, "<s-right>", mc.prevCursor)
  --
  --     -- Delete the main cursor.
  --     vim.keymap.set({"n", "v"}, "<leader>x", mc.deleteCursor)
  --
  --     -- Add and remove cursors with control + left click.
  --     vim.keymap.set("n", "<c-leftmouse>", mc.handleMouse)
  --
  --     -- mnemonic is, "change" focused
  --     vim.keymap.set({"n", "v"}, "<c-c>", function()
  --       if mc.cursorsEnabled() then
  --         -- Stop other cursors from moving.
  --         -- This allows you to reposition the main cursor.
  --         mc.disableCursors()
  --       else
  --         mc.addCursor()
  --       end
  --     end)
  --
  --     -- vim.keymap.set("n", "<esc>", function()
  --     --   if not mc.cursorsEnabled() then
  --     --     mc.enableCursors()
  --     --   elseif mc.hasCursors() then
  --     --     mc.clearCursors()
  --     --   else
  --     --     -- Default <esc> handler.
  --     --   end
  --     -- end)
  --
  --     -- Align cursor columns.
  --     vim.keymap.set("n", "<leader>a", mc.alignCursors)
  --
  --     -- Split visual selections by regex.
  --     vim.keymap.set("v", "U", mc.splitCursors)
  --
  --     -- Append/insert for each line of visual selections.
  --     vim.keymap.set("v", "I", mc.insertVisual)
  --     vim.keymap.set("v", "A", mc.appendVisual)
  --
  --     -- match new cursors within visual selections by regex.
  --     vim.keymap.set("v", "M", mc.matchCursors)
  --
  --     -- Rotate visual selection contents.
  --     vim.keymap.set("v", "<leader>t", function() mc.transposeCursors(1) end)
  --     vim.keymap.set("v", "<leader>T", function() mc.transposeCursors(-1) end)
  --
  --     -- Customize how cursors look.
  --     vim.api.nvim_set_hl(0, "MultiCursorCursor", { link = "NormalCursorMulti" })
  --     vim.api.nvim_set_hl(0, "MultiCursorVisual", { link = "VisualMulti" })
  --     vim.api.nvim_set_hl(0, "MultiCursorDisabledCursor", { link = "VisualCursorDisabled" })
  --     vim.api.nvim_set_hl(0, "MultiCursorDisabledVisual", { link = "VisualMultiDisabled" })
  --   end,
  -- },
  "sindrets/diffview.nvim",
  {
    "NeogitOrg/neogit",
    dependencies = {
      "nvim-lua/plenary.nvim",         -- required
      "sindrets/diffview.nvim",        -- optional - Diff integration

      -- Only one of these is needed.
      -- "nvim-telescope/telescope.nvim", -- optional
      -- "junegunn/fzf.vim",              -- optional
      -- "echasnovski/mini.pick",         -- optional
    },
    config = true
  },

  ---- disabling because of https://github.com/folke/noice.nvim/issues/679 not being addressed for neovide
  -- {
  --   "folke/noice.nvim",
  --   event = "VeryLazy",
  --   dependencies = {
  --     -- if you lazy-load any plugin below, make sure to add proper `module="..."` entries
  --     "MunifTanjim/nui.nvim",
  --     -- OPTIONAL:
  --     --   `nvim-notify` is only needed, if you want to use the notification view.
  --     --   If not available, we use `mini` as the fallback
  --     "rcarriga/nvim-notify",
  --   }
  -- },

  -- {
  --   'milanglacier/minuet-ai.nvim',
  -- },
  -- 'mfussenegger/nvim-dap',
  -- 'mfussenegger/nvim-dap-python',
  {
    -- Treat your local directory as a plugin
    'indicator', -- This name matches the directory in lua/projects/
    -- Optional: Specify configuration options
    opts = {
      -- You can override defaults here, e.g.:
      -- greeting = "Custom Greeting!"
    },
    dev = true,
    -- Optional: If lazy loading, specify triggers (commands, events, etc.)
    -- cmd = { "AddPlaygroundMark", "ClearPlaygroundMarks" }, -- Example: Load when commands are used
    -- event = "VeryLazy", -- Example: Load after startup
    -- For now, let's load it eagerly during startup for easy testing:
    lazy = false,
  },
  {
    "hinell/lsp-timeout.nvim",
    dependencies={ "neovim/nvim-lspconfig" }
  },
  {
    'rmagatti/auto-session',
    lazy = false,

    ---enables autocomplete for opts
    ---@module "auto-session"
    ---@type AutoSession.Config
    opts = {
      suppressed_dirs = { '~/', '~/Projects', '~/Downloads', '/' },
      auto_restore = true,
      auto_save = true
      -- log_level = 'debug',
    }
  },
  'skwee357/nvim-prose',
  { "nvzone/volt", lazy = true },
  {
    "nvzone/minty",
    cmd = { "Shades", "Huefy" },
  }
}
