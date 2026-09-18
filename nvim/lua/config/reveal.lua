-- One atomic record per editor: no shared-file lock or space-delimited fields.
local M = {}
local uv = vim.uv or vim.loop
local focused_at = 0
local record_path
local warned = false

local function absolute(path)
  if path == '' then return '' end
  return uv.fs_realpath(path) or vim.fn.fnamemodify(path, ':p')
end

function M.remove()
  if record_path then uv.fs_unlink(record_path) end
end

function M.publish()
  if not record_path or vim.v.servername == '' then return end
  local name = vim.bo.buftype == '' and vim.api.nvim_buf_get_name(0) or ''
  local data = {
    version = 1,
    pid = vim.fn.getpid(),
    socket = vim.v.servername,
    cwd = absolute(vim.fn.getcwd()),
    file = absolute(name),
    updated_at = os.time(),
    focused_at = focused_at,
    neovide = not not vim.g.neovide,
  }
  -- GUI editors may inherit terminal env; that does not make them terminal panes.
  if not data.neovide then
    if vim.env.HERDR_ENV == '1' and vim.env.HERDR_SOCKET_PATH and vim.env.HERDR_PANE_ID then
      data.herdr_socket = vim.env.HERDR_SOCKET_PATH
      data.herdr_pane_id = vim.env.HERDR_PANE_ID
    elseif vim.env.TMUX and vim.env.TMUX_PANE then
      data.tmux_socket = vim.env.TMUX:match('^(.-),')
      data.tmux_pane_id = vim.env.TMUX_PANE
    end
  end
  local temp = record_path .. '.tmp'
  local ok, err = pcall(function()
    local fd = assert(uv.fs_open(temp, 'w', 384)) -- 0600
    local bytes = vim.json.encode(data) .. '\n'
    local written, write_err = uv.fs_write(fd, bytes, 0)
    uv.fs_close(fd)
    assert(written == #bytes, write_err or 'short registry write')
    assert(uv.fs_rename(temp, record_path))
  end)
  if not ok then
    uv.fs_unlink(temp)
    if not warned then
      warned = true
      vim.schedule(function() vim.notify('reveal registry: ' .. tostring(err), vim.log.levels.WARN) end)
    end
  end
end

function M.setup()
  local state = vim.env.XDG_STATE_HOME
  if not state or state == '' then state = vim.env.HOME .. '/.local/state' end
  local dir = state .. '/reveal-location/editors'
  vim.fn.mkdir(dir, 'p', 448) -- 0700
  if vim.v.servername == '' then vim.fn.serverstart() end
  record_path = dir .. '/' .. vim.fn.getpid() .. '.json'
  local group = vim.api.nvim_create_augroup('RevealLocationRegistry', {clear = true})
  vim.api.nvim_create_autocmd({'BufEnter', 'DirChanged', 'VimEnter'}, {
    group = group, callback = M.publish,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group, callback = function() focused_at = os.time(); M.publish() end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {group = group, callback = M.remove})
  M.publish()
end

return M
