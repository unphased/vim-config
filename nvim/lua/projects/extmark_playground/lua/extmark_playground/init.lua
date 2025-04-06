local config = require("extmark_playground.config")

local M = {}

-- Store the merged configuration
M.opts = {}

-- Placeholder for extmark logic
local function add_mark()
  -- TODO: Implement extmark adding logic
  print(M.opts.greeting .. " Adding mark!")
end

-- Placeholder for extmark logic
local function clear_marks()
  -- TODO: Implement extmark clearing logic
  print("Clearing marks!")
end

-- Function to define commands
local function setup_commands()
  vim.api.nvim_create_user_command("AddPlaygroundMark", add_mark, {
    desc = "Extmark Playground: Add a test mark",
  })
  vim.api.nvim_create_user_command("ClearPlaygroundMarks", clear_marks, {
    desc = "Extmark Playground: Clear test marks",
  })
end

-- The main setup function called by users (or lazy.nvim)
function M.setup(user_opts)
  -- Deep merge user options over defaults (implement deep_extend if needed, or use simple extend for now)
  M.opts = vim.tbl_deep_extend("force", {}, config.defaults, user_opts or {})

  -- Define commands, mappings, autocommands etc. here
  setup_commands()

  print("Extmark Playground setup complete!")
end

return M
