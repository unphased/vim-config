local config = require("extmark_playground.config")

local M = {}

-- Store the merged configuration
M.opts = {}

-- Namespace for our extmarks
local ns_id = vim.api.nvim_create_namespace("extmark_playground")

-- Buffer-local storage for important extmark IDs
-- Key: buffer handle, Value: table of {extmark_id = true}
local important_marks = {}

-- Keep track of the last mark added per buffer
local last_added_mark = {}

-- Placeholder for extmark logic
local function add_mark()
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0) -- {row, col} (1-based)
  local line = pos[1] - 1 -- API uses 0-based lines
  local col = pos[2]      -- API uses 0-based columns (bytes)

  -- Basic extmark at cursor position
  -- Returns the mark ID
  local mark_id = vim.api.nvim_buf_set_extmark(buf, ns_id, line, col, {
    -- We can add options later like:
    -- virt_text = {{"<- Mark", "Comment"}}, -- Example visual
    -- hl_group = "Search",
  })

  if mark_id then
    print("Added extmark with ID: " .. mark_id .. " at line " .. (line + 1))
    last_added_mark[buf] = mark_id -- Store last added mark ID for this buffer
  else
    print("Failed to add extmark.")
  end
end

-- Placeholder for extmark logic
local function clear_marks()
  local buf = vim.api.nvim_get_current_buf()
  -- Clear all extmarks in our namespace for the current buffer
  -- Range is 0 (start line) to -1 (end line)
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
  important_marks[buf] = nil -- Clear important marks for this buffer
  last_added_mark[buf] = nil -- Clear last added mark for this buffer
  print("Cleared extmark_playground marks for buffer " .. buf)
end

-- Function to mark the last added extmark as important
local function promote_last_mark()
  local buf = vim.api.nvim_get_current_buf()
  local mark_id = last_added_mark[buf]

  if not mark_id then
    print("No mark added in this buffer session to promote.")
    return
  end

  -- Initialize buffer entry if it doesn't exist
  if not important_marks[buf] then
    important_marks[buf] = {}
  end

  -- Add mark ID to the set of important marks for this buffer
  important_marks[buf][mark_id] = true
  print("Promoted mark ID " .. mark_id .. " to important.")

  -- Trigger update after promoting (we'll define update_indicators later)
  -- update_indicators()
end

-- Function to find and display nearest important marks (initially just prints)
local function find_and_show_nearest_important()
  local current_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(current_win)

  if not important_marks[buf] or vim.tbl_isempty(important_marks[buf]) then
    -- print("No important marks in this buffer.")
    -- TODO: Clear any existing indicators if needed
    return
  end

  -- Get visible range (0-based lines)
  local view = vim.fn.winsaveview() -- Save view to restore later if needed
  -- line('w0') and line('w$') give 1-based visible lines
  local top_visible_line = vim.fn.line('w0') - 1
  local bottom_visible_line = vim.fn.line('w$') - 1
  -- vim.fn.winrestview(view) -- Restore view if needed, maybe not here

  -- Get details of all important marks in this buffer
  local important_ids = vim.tbl_keys(important_marks[buf])
  -- Note: nvim_buf_get_extmarks expects a list of IDs if you want specific ones,
  -- but getting *all* in the namespace and filtering might be easier if the
  -- number isn't huge, or we can iterate through our known important IDs.
  -- Let's get all marks in our namespace and filter.
  local all_marks_details = vim.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, { details = true })

  local nearest_above_line = -1
  local nearest_below_line = -1
  local min_dist_below = math.huge

  for _, mark_info in ipairs(all_marks_details) do
    local mark_id = mark_info[1]
    local mark_line = mark_info[2] -- 0-based line
    -- local mark_col = mark_info[3]
    -- local mark_details = mark_info[4] -- The options table used to create it

    -- Check if this mark is one we flagged as important
    if important_marks[buf][mark_id] then
      if mark_line < top_visible_line then
        -- Mark is above the viewport
        if mark_line > nearest_above_line then
          nearest_above_line = mark_line
        end
      elseif mark_line > bottom_visible_line then
        -- Mark is below the viewport
        local dist = mark_line - bottom_visible_line
        if dist < min_dist_below then
          min_dist_below = dist
          nearest_below_line = mark_line
        end
      end
      -- Ignore marks within the visible range for now
    end
  end

  -- Placeholder: Print results (add 1 for display)
  local above_msg = nearest_above_line >= 0 and "Nearest above: line " .. (nearest_above_line + 1) or "No important marks above"
  local below_msg = nearest_below_line >= 0 and "Nearest below: line " .. (nearest_below_line + 1) or "No important marks below"
  -- Use nvim_echo to avoid 'press enter' prompts if possible, might need throttling later
  vim.api.nvim_echo({ { above_msg .. " | " .. below_msg, "ModeMsg" } }, false, {})

  -- TODO: Replace print with actual indicator update (floating windows)
end

-- Function to list all extmarks in the current buffer, grouped by namespace
local function list_all_extmarks()
  local buf = vim.api.nvim_get_current_buf()
  print("Scanning buffer " .. buf .. " for all extmarks...")

  -- Get all known namespaces { name = id, ... }
  local namespaces = vim.api.nvim_get_namespaces()
  -- Add our own namespace to the list to check
  namespaces["extmark_playground (self)"] = ns_id

  local found_any = false
  local summary_lines = { "--- Extmark Summary ---" }

  -- Iterate through each known namespace and query marks for it
  for name, id in pairs(namespaces) do
    -- Get marks specifically for this namespace ID
    local marks_in_ns = vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = false }) -- details=false is enough for count

    if #marks_in_ns > 0 then
      found_any = true
      table.insert(summary_lines, string.format("Namespace: %s (ID: %d) - Count: %d", name, id, #marks_in_ns))
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
  vim.api.nvim_create_user_command("AddPlaygroundMark", add_mark, {
    desc = "Extmark Playground: Add a test mark",
  })
  vim.api.nvim_create_user_command("ClearPlaygroundMarks", clear_marks, {
    desc = "Extmark Playground: Clear test marks",
  })
  -- Add command to promote the last added mark
  vim.api.nvim_create_user_command("PromotePlaygroundMark", promote_last_mark, {
    desc = "Extmark Playground: Promote the last added mark to 'important'",
  })
  -- Add a command to manually trigger the check (for testing)
  vim.api.nvim_create_user_command("CheckPlaygroundNearest", find_and_show_nearest_important, {
     desc = "Extmark Playground: Find and show nearest important marks",
  })
  -- Add command to list all marks
  vim.api.nvim_create_user_command("ListAllExtmarks", list_all_extmarks, {
    desc = "Extmark Playground: List all extmarks in the buffer by namespace",
  })
end

-- The main setup function called by users (or lazy.nvim)
function M.setup(user_opts)
  -- Deep merge user options over defaults (implement deep_extend if needed, or use simple extend for now)
  M.opts = vim.tbl_deep_extend("force", {}, config.defaults, user_opts or {})

  -- Define commands, mappings, autocommands etc. here
  setup_commands()

  -- Setup autocommands to update indicators
  local group = vim.api.nvim_create_augroup("ExtmarkPlaygroundUpdates", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    pattern = "*", -- Apply to all buffers for now
    desc = "Update nearest extmark indicators on cursor move",
    callback = function()
      -- TODO: Debounce this call
      vim.schedule(find_and_show_nearest_important) -- Use schedule to avoid issues in fast events
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
     group = group,
     pattern = "*",
     desc = "Update nearest extmark indicators when entering window/buffer",
     callback = function()
        -- No need to schedule here usually
        find_and_show_nearest_important()
     end,
  })

  print("Extmark Playground setup complete!")
end

return M
