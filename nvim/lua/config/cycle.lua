local M = {}
-- Helper function to determine if a buffer is "real"
local function is_real_buffer(buf)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
  local modifiable = vim.api.nvim_get_option_value("modifiable", { buf = buf })
  local listed = vim.api.nvim_get_option_value("buflisted", { buf = buf })
  local name = vim.api.nvim_buf_get_name(buf)
  
  return buftype == ""
     and modifiable
     and listed
     and name ~= ""  -- Ensure the buffer has a name (file path)
end

-- Filters out windows:
-- - made by nvim-treesitter-context
-- - made by Neotree
-- - made by Trouble
-- - terminal windows
-- Does so by filtering out not focusable, then filtering out non-real buffers
local function filter_to_real_wins(window_list)
  local real_wins = {}
  for _, win in ipairs(window_list) do
    local buf = vim.api.nvim_win_get_buf(win)
    local win_config = vim.api.nvim_win_get_config(win)

    if win_config.focusable and is_real_buffer(buf) then
      table.insert(real_wins, win)
    end
  end
  return real_wins
end

-- Return the first index with the given value (or nil if not found).
local function indexOf(array, value)
  for i, v in ipairs(array) do
    if v == value then
      return i
    end
  end
  return nil
end

-- cycle thruogh the windows with tab. If the current tab has only one window, actually cycle through all the buffers which are not already open in other tabs (if applicable).
M.CycleWindowsOrBuffers = function (forward, fallback_tmux)
  local curwin = vim.api.nvim_get_current_win()
  local wins = filter_to_real_wins(vim.api.nvim_list_wins())
  local tabs = vim.api.nvim_list_tabpages()
  local curtab = vim.api.nvim_get_current_tabpage()
  local wins_in_curtab = filter_to_real_wins(vim.api.nvim_tabpage_list_wins(curtab))
  -- log("curwin, wins, tabs, curtab, wins_in_curtab", curwin, wins, tabs, curtab, wins_in_curtab)
  if #wins == 1 then
    -- log("CycleWindowsOrBuffers only one window, cycling buffer " .. (forward and "forward" or "backward"))
    local all_buffers = vim.api.nvim_list_bufs()
    local real_buffers = vim.tbl_filter(function(buf)
      return is_real_buffer(buf)
    end, all_buffers)
    -- log("All buffers:", all_buffers)
    -- log("Filtered real buffers:", real_buffers)
    
    -- Log detailed information about real buffers
    local buffer_details = {}
    for _, buf in ipairs(real_buffers) do
        local name = vim.api.nvim_buf_get_name(buf)
        table.insert(buffer_details, string.format("Buffer %d: %s", buf, name))
    end
    -- log("Real buffer details:", buffer_details)
    
    local current_buf = vim.api.nvim_get_current_buf()
    local current_index = indexOf(real_buffers, current_buf)
    
    if #real_buffers > 1 then
      local next_index
      if forward then
        next_index = (current_index % #real_buffers) + 1
      else
        next_index = ((current_index - 2 + #real_buffers) % #real_buffers) + 1
      end
      vim.api.nvim_set_current_buf(real_buffers[next_index])
    elseif fallback_tmux then
      if vim.env.TMUX then
        local cmd = forward and "next-window" or "previous-window"
        vim.fn.system({"tmux", cmd})
       elseif vim.g.neovide then
         -- NOTE: No current implementation for Neovide window cycling.
         --
         -- A BETTER APPROACH: Use Neovim RPC to focus other Neovide instances via :NeovideFocus command.
         -- This is fully portable across macOS/Linux and doesn't require external dependencies.
         --
         -- How it works:
         -- 1. Each Neovide instance sets NVIM environment variable pointing to its RPC socket.
         -- 2. List all Neovide processes and their NVIM sockets.
         -- 3. Send RPC command to target instance: nvim --server "$SOCKET" --remote-expr "execute('NeovideFocus')"
         -- 4. This brings that Neovide window to front without OS-specific hacks.
         --
         -- Example implementation:
         -- local function focus_neovide_instance(socket_path)
         --   if vim.fn.exists(":NeovideFocus") == 2 then
         --     vim.cmd("NeovideFocus")
         --   else
         --     -- Fallback: send RPC to target instance
         --     vim.fn.system({"nvim", "--server", socket_path, "--remote-expr", "execute('NeovideFocus')"})
         --   end
         -- end
         --
         -- To list instances:
         -- - macOS: Hammerspoon already tracks PIDs/CWDs; extend to get NVIM sockets
         -- - Linux: pgrep -f neovide, then inspect /proc/$PID/environ for NVIM=...
         --
         -- For cycling: Collect list of sockets, find current, activate next/prev.
         --
         -- TODO: Implement this RPC-based approach for true portability.
         -- For now, no Neovide window cycling when not in tmux.
      end
    end
  elseif #tabs == 1 then
    -- log("CycleWindowsOrBuffers only one tab, going forward to next window", forward)
    -- vim.cmd("wincmd " .. (forward and "w" or "W"))
    -- the above is wrong as it wont take into account the filter
    local curWinIdx = indexOf(wins, curwin)
    local targetWinIdx = curWinIdx + (forward and 1 or -1)
    if targetWinIdx > #wins then
      targetWinIdx = 1
    end
    if targetWinIdx < 1 then
      targetWinIdx = #wins
    end
    -- log('targeting win index ' .. targetWinIdx)
    local targetWin = wins[targetWinIdx]
    vim.api.nvim_set_current_win(targetWin)
  -- boundary
  elseif forward and wins_in_curtab[#wins_in_curtab] == curwin then
    -- log("CycleWindowsOrBuffers in last window in tab so going forward to next tab")
    vim.cmd("tabnext")
  elseif not forward and curwin == wins_in_curtab[1] then
    -- log("CycleWindowsOrBuffers in first window in tab so going back to prev tab")
    vim.cmd("tabprevious")
  else
    -- log("CycleWindowsOrBuffers in the last case (multiple tabs, not at end), cycling window " .. (forward and "forward" or "backward"))
    vim.cmd("wincmd " .. (forward and "w" or "W"))
  end
end

return M
