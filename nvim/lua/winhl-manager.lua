-- Default configuration
local default_config = {
  cursor_line = {
    active = 'ActiveCursorLine',
    inactive = 'InactiveCursorLine'
  },
  background = {
    normal = 'NormalModeBackground',
    insert = 'InsertModeBackground'
  }
}

-- Initialize a table to store winhl states
local winhl_states = {}

-- Function to update winhl
local function update_winhl(win_id, config, force_mode)
  win_id = win_id or vim.api.nvim_get_current_win()
  local winhl_list = {}

  -- CursorLine state
  if winhl_states[win_id] and winhl_states[win_id].active then
    table.insert(winhl_list, 'CursorLine:' .. config.cursor_line.active)
  else
    table.insert(winhl_list, 'CursorLine:' .. config.cursor_line.inactive)
  end

  -- Insert mode state
  local mode = force_mode or (winhl_states[win_id] and winhl_states[win_id].mode) or 'n'
  -- log("Current mode for window " .. win_id .. ": " .. mode)
  if mode == 'i' then
    -- log("Applying insert mode background: " .. config.background.insert)
    table.insert(winhl_list, 'Normal:' .. config.background.insert)
    table.insert(winhl_list, 'SignColumn:' .. config.background.insert)
  else
    -- log("Applying normal mode background: " .. config.background.normal)
    table.insert(winhl_list, 'Normal:' .. config.background.normal)
    table.insert(winhl_list, 'SignColumn:' .. config.background.normal)
  end

  -- Set the winhl option
  local winhl_string = table.concat(winhl_list, ',')
  -- log("Setting winhl for window " .. win_id .. " to: " .. winhl_string)
  vim.api.nvim_win_set_option(win_id, 'winhl', winhl_string)
end

-- Function to update all windows
local function update_all_windows(config)
  for _, win_id in ipairs(vim.api.nvim_list_wins()) do
    update_winhl(win_id, config)
  end
end

-- Set up autocommands
local function setup_autocmds(config)
  local augroup = vim.api.nvim_create_augroup('WinHLStateManagement', { clear = true })

  vim.api.nvim_create_autocmd('WinEnter', {
    group = augroup,
    callback = function()
      local win_id = vim.api.nvim_get_current_win()
      winhl_states[win_id] = { active = true }
      update_winhl(win_id, config)
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', {
    group = augroup,
    callback = function()
      local win_id = vim.api.nvim_get_current_win()
      winhl_states[win_id] = { active = false }
      update_winhl(win_id, config)
    end,
  })

  vim.api.nvim_create_autocmd('InsertEnter', {
    group = augroup,
    callback = function()
      local win_id = vim.api.nvim_get_current_win()
      log("InsertEnter triggered for window " .. win_id)
      winhl_states[win_id] = winhl_states[win_id] or {}
      winhl_states[win_id].mode = 'i'
      update_winhl(win_id, config, 'i')
    end,
  })

  vim.api.nvim_create_autocmd('InsertLeave', {
    group = augroup,
    callback = function()
      local win_id = vim.api.nvim_get_current_win()
      log("InsertLeave triggered for window " .. win_id)
      winhl_states[win_id] = winhl_states[win_id] or {}
      winhl_states[win_id].mode = 'n'
      update_winhl(win_id, config, 'n')
    end,
  })

  vim.api.nvim_create_autocmd('ColorScheme', {
    group = augroup,
    callback = function()
      update_all_windows(config)
    end,
  })
end

-- Main setup function
local function setup(user_config)
  -- Merge user config with default config
  local config = vim.tbl_deep_extend('force', default_config, user_config or {})

  setup_autocmds(config)
  update_all_windows(config)
end

return {
  setup = setup
}
