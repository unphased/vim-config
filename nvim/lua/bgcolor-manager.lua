local M = {}

local DEFAULT_COLOR = "#2f9117"

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- When true, the global highlight namespace (ns 0) tracks the active window's
-- resolved background color.  This affects UI elements that live outside any
-- window: the command line, message area, Neovide title-bar / window chrome,
-- etc.  When false, namespace 0 is left untouched and those elements keep
-- whatever the colorscheme originally set.
local global_ui_follows_active = true

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local win_ns = {}      -- win_id  -> namespace_id
local win_hex = {}     -- win_id  -> last applied hex
local path_cache = {}  -- anchor_path -> hex (avoids re-forking bgcolor.sh)
local last_global_hex  ---@type string|nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local HIGHLIGHT_GROUPS = {
  "NormalModeBackground",
  "InsertModeBackground",
  "Normal",
  "NormalNC",
  "SignColumn",
}

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param s unknown
---@return string|nil
local function sanitize_hex(s)
  if type(s) ~= "string" then
    return nil
  end
  local val = trim(s)
  if val:match("^#%x%x%x%x%x%x%x%x$") then
    val = val:sub(1, 7)
  end
  if val:match("^#%x%x%x%x%x%x$") then
    return val
  end
  return nil
end

---@param path string
---@return string|nil
local function compute_hex_for_path(path)
  if path_cache[path] then
    return path_cache[path]
  end

  local script = (vim.env.HOME or "") .. "/util/bgcolor.sh"
  if vim.fn.executable(script) ~= 1 then
    return nil
  end

  local out = vim.fn.system({ script, "--format=hex", path })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local hex = sanitize_hex(out)
  if hex then
    path_cache[path] = hex
  end
  return hex
end

---@return string|nil
local function get_nvimtree_root()
  local ok, core = pcall(require, "nvim-tree.core")
  if not ok or type(core) ~= "table" or type(core.get_cwd) ~= "function" then
    return nil
  end
  return core.get_cwd()
end

---@param win_id number
---@return boolean
local function is_floating(win_id)
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win_id)
  return ok and cfg.relative ~= nil and cfg.relative ~= ""
end

---@param win_id number
---@return number
local function get_or_create_ns(win_id)
  if not win_ns[win_id] then
    win_ns[win_id] = vim.api.nvim_create_namespace("bgcolor_win_" .. win_id)
  end
  return win_ns[win_id]
end

-- ---------------------------------------------------------------------------
-- Anchor / hex resolution
-- ---------------------------------------------------------------------------

--- Resolve the anchor path and/or direct hex for a given window's buffer.
---@param win_id? number  defaults to current window
---@return string|nil anchor, string|nil direct_hex
local function get_anchor_or_direct_hex(win_id)
  win_id = win_id or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win_id)
  local buftype = vim.bo[bufnr].buftype
  local filetype = vim.bo[bufnr].filetype

  if filetype == "NvimTree" then
    return get_nvimtree_root() or vim.fn.getcwd(0), nil
  end

  if buftype == "terminal" then
    local direct_hex = sanitize_hex(vim.b[bufnr].nvim_term_bg_hex)
    if direct_hex then
      return nil, direct_hex
    end
    local cwd = vim.b[bufnr].nvim_term_cwd
    if type(cwd) == "string" and cwd ~= "" then
      return cwd, nil
    end
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    return name, nil
  end

  -- Fallback: window-local cwd.
  local winnr = vim.fn.win_id2win(win_id)
  return vim.fn.getcwd(winnr > 0 and winnr or 0), nil
end

--- Compute the resolved hex color for a window.
---@param win_id? number  defaults to current window
---@return string
local function resolve_hex(win_id)
  local anchor, direct_hex = get_anchor_or_direct_hex(win_id)
  if direct_hex then
    return direct_hex
  end
  return compute_hex_for_path(anchor) or DEFAULT_COLOR
end

-- ---------------------------------------------------------------------------
-- Highlight application
-- ---------------------------------------------------------------------------

--- Apply hex to a specific window via its own highlight namespace.
--- Each window gets a dedicated namespace so that splits from different repos
--- can display independent background colors simultaneously.
---@param win_id number
---@param hex string
local function apply_hex_to_win(win_id, hex)
  if win_hex[win_id] == hex then
    return
  end

  local ns = get_or_create_ns(win_id)
  for _, group in ipairs(HIGHLIGHT_GROUPS) do
    pcall(vim.api.nvim_set_hl, ns, group, { bg = hex })
  end
  pcall(vim.api.nvim_win_set_hl_ns, win_id, ns)
  win_hex[win_id] = hex
end

--- Apply hex to the global namespace (ns 0).
--- This controls UI elements outside any window: the command line bar, the
--- message area, Neovide title-bar / window chrome, etc.  Gated behind the
--- `global_ui_follows_active` flag so users can opt out if they prefer those
--- elements to stay at the colorscheme default.
---@param hex string
local function apply_hex_global(hex)
  if hex == last_global_hex then
    return
  end
  for _, group in ipairs(HIGHLIGHT_GROUPS) do
    pcall(vim.api.nvim_set_hl, 0, group, { bg = hex })
  end
  last_global_hex = hex
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Update the background color for the current window (and optionally global UI).
function M.update()
  local win_id = vim.api.nvim_get_current_win()
  if is_floating(win_id) then
    return
  end

  local hex = resolve_hex(win_id)
  apply_hex_to_win(win_id, hex)

  if global_ui_follows_active then
    apply_hex_global(hex)
  end
end

--- Recompute and apply colors for every visible (non-floating) window.
local function update_all_windows()
  for _, win_id in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win_id) and not is_floating(win_id) then
      local hex = resolve_hex(win_id)
      apply_hex_to_win(win_id, hex)
    end
  end
  -- Sync global UI to the current window.
  if global_ui_follows_active then
    local cur = vim.api.nvim_get_current_win()
    if win_hex[cur] then
      apply_hex_global(win_hex[cur])
    end
  end
end

--- Accept a terminal buffer's cwd/hex from the shell integration hook
--- (`nvim-bgcolor.zsh`).  If the terminal is visible in any window, that
--- window's color is updated immediately.
---@param bufnr number|string
---@param cwd string|nil
---@param hex string|nil
---@return boolean
function M.set_term_state(bufnr, cwd, hex)
  local num = bufnr
  if type(num) == "string" then
    num = tonumber(num)
  end
  if type(num) ~= "number" or num <= 0 then
    return false
  end
  if not vim.api.nvim_buf_is_valid(num) then
    return false
  end

  if type(cwd) == "string" and cwd ~= "" then
    vim.b[num].nvim_term_cwd = cwd
  end

  local sanitized = sanitize_hex(hex)
  if sanitized then
    vim.b[num].nvim_term_bg_hex = sanitized
  end

  for _, win_id in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win_id) and vim.api.nvim_win_get_buf(win_id) == num then
      local resolved = resolve_hex(win_id)
      apply_hex_to_win(win_id, resolved)
      if win_id == vim.api.nvim_get_current_win() and global_ui_follows_active then
        apply_hex_global(resolved)
      end
    end
  end
  return true
end

--- Flush the path→hex cache and reapply all windows.  Call this after editing
--- a `.tmux-bgcolor` file or changing the color policy.
function M.clear_cache()
  path_cache = {}
  win_hex = {}
  last_global_hex = nil
  update_all_windows()
end

---@param opts? { default_color?: string, global_ui_follows_active?: boolean }
function M.setup(opts)
  opts = opts or {}

  DEFAULT_COLOR = sanitize_hex(opts.default_color) or DEFAULT_COLOR
  if opts.global_ui_follows_active ~= nil then
    global_ui_follows_active = opts.global_ui_follows_active
  end

  _G.NvimSetTermBg = function(bufnr, cwd, hex)
    return M.set_term_state(bufnr, cwd, hex)
  end

  local augroup = vim.api.nvim_create_augroup("BgColorManager", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "DirChanged" }, {
    group = augroup,
    callback = function()
      M.update()
    end,
    desc = "Update background color for focused window/buffer",
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      -- ColorScheme clears all custom highlights — flush caches and reapply.
      path_cache = {}
      last_global_hex = nil
      win_hex = {}
      update_all_windows()
    end,
    desc = "Reapply background colors after colorscheme changes",
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed then
        win_ns[closed] = nil
        win_hex[closed] = nil
      end
    end,
    desc = "Clean up bgcolor state for closed windows",
  })

  update_all_windows()
end

return M
