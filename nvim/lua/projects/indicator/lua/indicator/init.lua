local config = require("indicator.config")

local M = {}

-- Store the merged configuration
M.opts = {}

-- Window-local state: { window_id = { namespace_id = true, ... }, ... }
local followed_namespaces_by_window = {}

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
-- Placeholder function to update offscreen indicators for the current window
local function update_indicators()
  local win_id = vim.api.nvim_get_current_win()
  local buf_id = vim.api.nvim_win_get_buf(win_id)

  local followed_ns = followed_namespaces_by_window[win_id]

  if not followed_ns or vim.tbl_isempty(followed_ns) then
    -- print("Indicator: No namespaces followed for window " .. win_id)
    -- TODO: Clear/hide floating windows for this window
    return
  end

  if not namespace_cache_populated then
    update_namespace_cache() -- Ensure cache is populated if needed
  end

  local followed_names = {}
  for ns_id, _ in pairs(followed_ns) do
    table.insert(followed_names, namespace_cache[ns_id] or ("Unknown NS ID: " .. ns_id))
  end

  -- Placeholder: Print followed namespaces
  -- vim.api.nvim_echo({{"Indicator: Following " .. table.concat(followed_names, ", ") .. " in win " .. win_id}}, false, {})

  -- TODO:
  -- 1. Get viewport lines (line('w0'), line('w$'))
  -- 2. Iterate through followed_ns IDs
  -- 3. For each ns_id, get extmarks in buf_id: nvim_buf_get_extmarks(buf_id, ns_id, 0, -1, {details=true})
  -- 4. Combine all marks from followed namespaces.
  -- 5. Find the nearest mark above line('w0') and nearest below line('w$').
  -- 6. Calculate distances.
  -- 7. Create/update floating windows at top-right and bottom-right of win_id
  --    - Use nvim_open_win() with relative = 'win', anchor = 'NE'/'SE', etc.
  --    - Set content using nvim_buf_set_lines() (e.g., "↑ 15", "↓ 120")
  --    - Need to manage these floating window IDs per main window ID.
end

local function setup_commands()
  -- Function to open a picker for selecting namespaces to follow in the current window
local function select_namespaces_to_follow()
  local win_id = vim.api.nvim_get_current_win()
  local buf_id = vim.api.nvim_win_get_buf(win_id)

  if not namespace_cache_populated then
    update_namespace_cache() -- Ensure cache is fresh before showing picker
  end

  local available_namespaces = {} -- Stores {id=ns_id, name=ns_name, count=mark_count}
  local current_followed = followed_namespaces_by_window[win_id] or {}

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
    vim.notify("Indicator: No extmarks found in the current buffer to follow.", vim.log.levels.INFO)
    return
  end

  -- Sort namespaces alphabetically for consistent order
  table.sort(available_namespaces, function(a, b) return a.name < b.name end)

  -- Prepare choices for vim.ui.select
  local choices = {}
  local choice_to_ns_id = {} -- Map display string back to ns_id
  for i, ns_info in ipairs(available_namespaces) do
    local is_followed = current_followed[ns_info.id]
    local prefix = is_followed and "[x] " or "[ ] "
    local display_text = string.format("%s%s (ID: %d) - %d marks", prefix, ns_info.name, ns_info.id, ns_info.count)
    table.insert(choices, display_text)
    choice_to_ns_id[display_text] = ns_info.id
  end

  vim.ui.select(choices, {
    prompt = "Select namespaces to follow in this window:",
    multi = true,
  }, function(selected_choices)
    if not selected_choices then
      -- print("Indicator: Selection cancelled.") -- Optional
      return
    end

    -- Update the followed set for the current window
    local new_followed_set = {}
    for _, choice_text in ipairs(selected_choices) do
      local ns_id = choice_to_ns_id[choice_text]
      if ns_id then
        new_followed_set[ns_id] = true
      end
    end
    followed_namespaces_by_window[win_id] = new_followed_set

    -- Trigger an update of the indicators
    update_indicators()
    -- Optional: Notify user
    local num_selected = 0
    for _ in pairs(new_followed_set) do num_selected = num_selected + 1 end
    vim.notify(string.format("Indicator: Now following %d namespace(s) in window %d.", num_selected, win_id), vim.log.levels.INFO)
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

  -- Setup autocommands
  local group = vim.api.nvim_create_augroup("IndicatorUpdates", { clear = true })

  -- Update indicators on scroll, resize, entering a window, etc.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled", "WinResized", "BufWinEnter", "WinEnter" }, {
    group = group,
    pattern = "*",
    desc = "Update indicator positions",
    callback = function()
      -- TODO: Debounce this call heavily, especially for CursorMoved/WinScrolled
      vim.schedule(update_indicators)
    end,
  })

  -- Refresh namespace cache if namespaces change globally
  vim.api.nvim_create_autocmd({ "Namespace" }, {
     group = group,
     pattern = "*",
     desc = "Update indicator namespace cache",
     callback = function()
        -- No need to schedule this, it's infrequent
        update_namespace_cache()
        -- Might need to trigger update_indicators for all relevant windows if cache changes affect display
     end,
  })

  -- Clean up window state when a window is closed
  vim.api.nvim_create_autocmd({ "WinClosed" }, {
    group = group,
    pattern = "*", -- Pattern is matched against the window ID as a string
    desc = "Clean up indicator state for closed window",
    callback = function(args)
      local closed_win_id = tonumber(args.match) -- args.match contains the window ID string
      if closed_win_id and followed_namespaces_by_window[closed_win_id] then
        -- print("Indicator: Cleaning state for closed window " .. closed_win_id) -- Optional debug
        followed_namespaces_by_window[closed_win_id] = nil
        -- TODO: Ensure floating indicator windows associated with this win_id are also closed.
      end
    end,
  })

  print("Indicator plugin setup complete!")
end

return M
