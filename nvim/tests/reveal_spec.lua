local root = assert(vim.env.REVEAL_TEST_ROOT)
package.path = root .. '/nvim/lua/?.lua;' .. package.path
local reveal = require('config.reveal')
local state_dir = assert(vim.env.XDG_STATE_HOME) .. '/reveal-location/editors'
local record_path = state_dir .. '/' .. vim.fn.getpid() .. '.json'
local function record()
  return vim.json.decode(table.concat(vim.fn.readfile(record_path), '\n'))
end
reveal.setup()
local first = record()
assert(first.version == 1 and first.pid == vim.fn.getpid())
assert(first.socket == vim.v.servername and first.socket ~= '')
assert(first.file == '' and first.neovide == false)
assert(first.focused_at == 0)
assert(first.herdr_socket == '/tmp/reveal-test-herdr.sock')
assert(first.herdr_pane_id == 'w-test:p-test')
assert(first.tmux_socket == nil, 'Herdr must win over inherited TMUX')
local file = vim.env.XDG_STATE_HOME .. '/file with spaces #.md'
vim.fn.writefile({'one', 'two'}, file)
vim.cmd.edit(vim.fn.fnameescape(file))
assert(record().file == vim.uv.fs_realpath(file))
vim.api.nvim_exec_autocmds('FocusGained', {})
assert(record().focused_at > 0)
local focus = record().focused_at
vim.cmd.cd(vim.fn.fnameescape(vim.env.XDG_STATE_HOME))
assert(record().cwd == vim.uv.fs_realpath(vim.env.XDG_STATE_HOME))
assert(record().focused_at == focus, 'cwd activity is not focus')
reveal.setup() -- reload must not accumulate autocmds
assert(#vim.api.nvim_get_autocmds({group='RevealLocationRegistry',event='BufEnter'}) == 1)
vim.g.neovide = true
reveal.publish()
local gui = record()
assert(gui.neovide and gui.herdr_socket == nil and gui.tmux_socket == nil)
vim.g.neovide = nil
vim.env.HERDR_ENV = nil
reveal.publish()
local tmux = record()
assert(tmux.tmux_socket == '/tmp/reveal-test-tmux.sock' and tmux.tmux_pane_id == '%777')
reveal.remove()
assert(vim.uv.fs_stat(record_path) == nil)
print('PASS: reveal registry lifecycle, JSON paths, container precedence, and focus timestamps')
vim.cmd('qa!')
