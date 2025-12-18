local M = {}

local DEFAULT_COLOR = "#2f9117"

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
  local script = (vim.env.HOME or "") .. "/util/bgcolor.sh"
  if vim.fn.executable(script) ~= 1 then
    return nil
  end

  local out = vim.fn.system({ script, "--format=hex", path })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  return sanitize_hex(out)
end

---@return string|nil
local function get_nvimtree_root()
  local ok, core = pcall(require, "nvim-tree.core")
  if not ok or type(core) ~= "table" or type(core.get_cwd) ~= "function" then
    return nil
  end
  return core.get_cwd()
end

---@return string|nil, string|nil
local function get_anchor_or_direct_hex()
  local bufnr = vim.api.nvim_get_current_buf()
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
    return vim.fn.getcwd(0), nil
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    return name, nil
  end

  return vim.fn.getcwd(0), nil
end

local last_applied_hex ---@type string|nil

---@param hex string
local function apply_hex(hex)
  if hex == last_applied_hex then
    return
  end

  for _, group in ipairs({ "NormalModeBackground", "Normal", "NormalNC", "SignColumn" }) do
    pcall(vim.api.nvim_set_hl, 0, group, { bg = hex })
  end

  last_applied_hex = hex
end

function M.update()
  local anchor, direct_hex = get_anchor_or_direct_hex()

  local hex = direct_hex
  if not hex then
    hex = compute_hex_for_path(anchor) or DEFAULT_COLOR
  end

  apply_hex(hex)
end

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

  if num == vim.api.nvim_get_current_buf() then
    M.update()
  end
  return true
end

---@param opts? { default_color?: string }
function M.setup(opts)
  opts = opts or {}

  DEFAULT_COLOR = sanitize_hex(opts.default_color) or DEFAULT_COLOR

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
      last_applied_hex = nil
      M.update()
    end,
    desc = "Reapply background color after colorscheme changes",
  })

  M.update()
end

return M

