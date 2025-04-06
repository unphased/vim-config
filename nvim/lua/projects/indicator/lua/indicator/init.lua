local config = require("indicator.config")

local M = {}

-- Store the merged configuration
M.opts = {}

-- Function to list all extmarks in the current buffer, grouped by namespace
local function list_all_extmarks()
  local buf = vim.api.nvim_get_current_buf()
  print("Scanning buffer " .. buf .. " for all extmarks...")

  -- Get all known namespaces { name = id, ... }
  local namespaces = vim.api.nvim_get_namespaces()

  -- Add our own namespace to the list to check
  -- namespaces["indicator (self)"] = ns_id

  local found_any = false
  local summary_lines = { "--- Extmark Summary ---" }

  -- Iterate through each known namespace and query marks for it
  for name, id in pairs(namespaces) do
    -- Get marks specifically for this namespace ID
    local marks_in_ns = vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = false }) -- details=false is enough for count

    if #marks_in_ns > 0 then
      found_any = true
      table.insert(summary_lines, string.format("Namespace: %s (ID: %d) - Count: %d", name, id, #marks_in_ns))

      -- can dump details instead if needed: it produces a huge amount of output though.
      -- local marks_details = vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })
         -- for _, mark_info in ipairs(marks_details) do
         --   local mark_id = mark_info[1]
         --   local mark_line = mark_info[2] + 1 -- 1-based
         --   local mark_col = mark_info[3]
         --   local mark_opts = mark_info[4]
         --   table.insert(summary_lines, string.format("  - Mark ID: %d, Line: %d, Col: %d, Opts: %s",
         --                                            mark_id, mark_line, mark_col, vim.inspect(mark_opts)))
         -- end

    end
  end

  if not found_any then
    print("No extmarks found in known namespaces for this buffer.")
    return
  end

  table.insert(summary_lines, "---------------------")
  -- Use nvim_echo to print multiple lines without requiring "Press ENTER"
  vim.api.nvim_echo({ { table.concat(summary_lines, "\n") } }, true, {})
end

-- Function to define commands
local function setup_commands()
  -- Add command to list all marks
  vim.api.nvim_create_user_command("IndicatorListExtmarks", list_all_extmarks, {
    desc = "Indicator: List all extmarks in the buffer by namespace",
  })
end

-- The main setup function called by users (or lazy.nvim)
function M.setup(user_opts)
  -- Deep merge user options over defaults (implement deep_extend if needed, or use simple extend for now)
  M.opts = vim.tbl_deep_extend("force", {}, config.defaults, user_opts or {})

  -- Define commands, mappings, autocommands etc. here
  setup_commands()

  print("Indicator plugin setup complete!")
end

return M
