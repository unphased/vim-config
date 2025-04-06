local config = require("indicator.config")

local M = {}

-- Store the merged configuration
M.opts = {}

-- Cache for namespace ID -> name mapping
local namespace_cache = {}
local namespace_cache_populated = false

-- Function to update the cache of namespace IDs to names
local function update_namespace_cache()
  namespace_cache = {} -- Clear existing cache
  local namespaces = vim.api.nvim_get_namespaces()
  for name, id in pairs(namespaces) do
    namespace_cache[id] = name
  end
  namespace_cache_populated = true
  -- print("Namespace cache updated.") -- Optional debug message
end

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
  -- Function to open a picker for viewing namespaces with marks
  local function select_namespaces_to_follow()
    local win_id = vim.api.nvim_get_current_win()
    local buf_id = vim.api.nvim_win_get_buf(win_id)

    -- Always update the cache to ensure we see all current namespaces
    update_namespace_cache()

    local available_namespaces = {} -- Stores {id=ns_id, name=ns_name, count=mark_count}

    -- Find namespaces that actually have marks in the *current* buffer
    for ns_id, ns_name in pairs(namespace_cache) do
      -- Get actual marks for count
      local marks_in_ns = vim.api.nvim_buf_get_extmarks(buf_id, ns_id, 0, -1, {}) -- Get IDs only for count
      local count = #marks_in_ns

      if count > 0 then
        table.insert(available_namespaces, { id = ns_id, name = ns_name, count = count })
      end
    end

    if #available_namespaces == 0 then
      vim.notify("Indicator: No extmarks found in the current buffer.", vim.log.levels.INFO)
      return
    end

    -- Sort namespaces alphabetically for consistent order
    table.sort(available_namespaces, function(a, b) return a.name < b.name end)

    -- Prepare choices for vim.ui.select
    local choices = {}
    for i, ns_info in ipairs(available_namespaces) do
      local display_text = string.format("%s (ID: %d) - %d marks", ns_info.name, ns_info.id, ns_info.count)
      table.insert(choices, display_text)
    end

    vim.ui.select(choices, {
      prompt = "Available namespaces with marks:",
    }, function(selected_choice)
      if not selected_choice then
        return
      end
    end)
  end

  -- Add command to list all marks
  vim.api.nvim_create_user_command("IndicatorListExtmarks", list_all_extmarks, {
    desc = "Indicator: List all extmarks in the buffer by namespace",
  })
  -- Add command to select namespaces to follow
  vim.api.nvim_create_user_command("IndicatorFollow", select_namespaces_to_follow, {
    desc = "Indicator: Select extmark namespaces to follow in this window",
  })
end

-- The main setup function called by users (or lazy.nvim)
function M.setup(user_opts)
  -- Deep merge user options over defaults (implement deep_extend if needed, or use simple extend for now)
  M.opts = vim.tbl_deep_extend("force", {}, config.defaults, user_opts or {})

  setup_commands()

  -- Initial population of namespace cache
  update_namespace_cache()

  print("Indicator plugin setup complete!")
end

return M
