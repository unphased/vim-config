local config = require("indicator.config")

local M = {}

-- Store the merged configuration
M.opts = {}

-- Helper function to get namespaces that have marks in a given buffer
local function get_namespaces_with_marks(buf_id)
  local available_namespaces = {} -- Stores {id=ns_id, name=ns_name, count=mark_count}
  local current_namespaces = vim.api.nvim_get_namespaces() -- Get fresh list

  -- Find namespaces that actually have marks in the buffer
  for ns_name, ns_id in pairs(current_namespaces) do
    -- Get actual marks for count
    local marks_in_ns = vim.api.nvim_buf_get_extmarks(buf_id, ns_id, 0, -1, {}) -- Get IDs only for count
    local count = #marks_in_ns

    if count > 0 then
      table.insert(available_namespaces, { id = ns_id, name = ns_name, count = count })
    end
  end
  return available_namespaces
end


-- Function to define commands

local function setup_commands()
  -- Function to open a picker for viewing namespaces with marks
  local function select_namespaces_to_follow()
    local win_id = vim.api.nvim_get_current_win()
    local buf_id = vim.api.nvim_win_get_buf(win_id)

    -- Call the helper function to get namespaces with marks
    local available_namespaces = get_namespaces_with_marks(buf_id)

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
      -- print to indicate the value that was selected
      print("You selected: " .. selected_choice)
    end)
  end

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

  print("Indicator plugin setup complete!")
end

return M
