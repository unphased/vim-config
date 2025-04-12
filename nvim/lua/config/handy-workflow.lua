local M = {}

-- a one off terminal to run something and closes after
local function MakeSimpleTermForCmd(command, size, name)
  vim.cmd('botright ' .. size .. ' new')

  local bufNum = vim.api.nvim_get_current_buf()
  local winNum = vim.api.nvim_get_current_win()
  vim.bo[bufNum].buftype = 'nofile'
  vim.bo[bufNum].bufhidden = 'hide'
  vim.wo[winNum].number = false
  vim.wo[winNum].signcolumn = 'no'

  local chan_id = vim.fn.termopen({'/bin/sh', '-c', command}, {
    on_exit = function(job_id, exit_code, event_type)
      vim.api.nvim_buf_delete(bufNum, {force = true})
    end
  })
  vim.cmd('startinsert')
  -- vim.bo[bufNum].buftype = 'terminal'
  if name then
    vim.api.nvim_buf_set_name(bufNum, name)
    -- TODO find a way to change name to prevent buf name clash
  end
end

M.MakeSimpleTermForCmd = MakeSimpleTermForCmd;

-- commit (ah this is a bit ridiculous opening vim to write a msg inside vim lol but it really works)
vim.keymap.set('n', '<M-c>', function ()
  -- run ~/util/commit-push-interactive.sh in a terminal split
  MakeSimpleTermForCmd('~/util/commit-push-interactive.sh', '20', 'Git Commit')
end)
vim.keymap.set('n', '<M-t>', function () MakeSimpleTermForCmd('zsh', '25', 'zsh') end)

-- helper, very sad no hyperlink support in neovim yet. don't send in a long running command.
local function MakeTermWindowVimAsPager(command, size, name, target_buf)
  if target_buf then
    -- i need to abandon the current buffer in this window: Create a new buffer, switch this window to it, then delete
    -- the old defunct buffer (or not! would be nice to be able to re-view it with future features)
    vim.cmd('enew')
  else
    -- Create a new window and buffer if no target is provided
    vim.cmd('botright ' .. size .. ' new')
  end

  local bufNum = vim.api.nvim_get_current_buf()
  vim.bo[bufNum].buftype = 'nofile'
  vim.bo[bufNum].bufhidden = 'hide'
  vim.wo[vim.api.nvim_get_current_win()].signcolumn = 'no'

  if target_buf then
    -- delete the buffer now that we have switched away from it TODO sometimes may want to keep it, add option for that
    vim.api.nvim_buf_delete(target_buf, {force = true})
  end

  vim.keymap.set('n', 'q', function()
    vim.api.nvim_buf_delete(bufNum, {force = true})
  end, { noremap = true, silent = true, buffer = bufNum})

  local chan_id = vim.fn.termopen({'/bin/sh', '-c', "printf 'in dir '; pwd; echo 'Launching " .. command .. ":' && " .. command}, {
    on_exit = function(job_id, exit_code, event_type)
      -- now that the output is done we scroll us to the top
      vim.api.nvim_win_set_cursor(0, {1, 0})
    end
  })

  if name then
    local bufferName = 'term:' .. name
    log('setting buf name to '.. bufferName)
    vim.api.nvim_buf_set_name(bufNum, bufferName)
    -- TODO find a way to change name to prevent buf name clash
  end

  return bufNum
end

M.MakeTermWindowVimAsPager = MakeTermWindowVimAsPager;


  -- vim.keymap.set('n', '<D-z>', function ()
  --   MakeTermWindowVimAsPager('echo test; echo path is $PATH; echo here is a hyperlink:; printf "test lol"', '20', 'test')
  -- end)

-- log
vim.keymap.set('n', '<M-l>', function ()
  MakeTermWindowVimAsPager('git --no-pager  log -p --color-moved --color=always | head -n3000 | ~/.cargo/bin/delta --pager=none', '40', 'Git Log')
end)

function get_current_tab_buffer_names()
    local buffers = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" then
            table.insert(buffers, { name = name, buf = buf })
        end
    end
    return buffers
end

-- pretty dope nvim self contained git diff viewer. repeated hits on this iterates thru a diff from current state to N
-- commits ago, good for quickly viewing a diff for a collapsed stack of recent commits.
local function display_diff(back)
  if vim.bo.buftype == 'terminal' then
    -- In terminal buffer (normal or insert mode), when this is called i will hop back and forth producing a delta from
    -- current state to N commits back in history. 
    local max_diff_num = 0
    local max_diff_bufnum
    for _, data in ipairs(get_current_tab_buffer_names()) do
      local bufName = data.name
      local diff_num = bufName:match("Git DIFF PREV (%d+)")
      if diff_num then
        max_diff_num = math.max(max_diff_num, tonumber(diff_num) or 0)
        max_diff_bufnum = data.buf
      end
    end


    -- Increment the max number for the new diff
    local new_diff_num = max_diff_num + (back and 1 or -1)
    if (new_diff_num < 1) then
      new_diff_num = 1
    end

    log('display_diff targeting buf ' .. tostring(new_diff_num == 1 and nil or max_diff_bufnum) .. ' for opening into')

    local commits_back = string.rep("^", new_diff_num)
    -- the grep and tail are to actually make it count just the changed lines.
    MakeTermWindowVimAsPager('output="$(git --no-pager diff HEAD' .. commits_back .. ")\"; echo \"Line count: $(echo \"$output\" | grep '^[-+][^-+]' | tail -n +3 | wc -l)\"; echo \"Diffing from $(git rev-parse --short HEAD" .. commits_back .. ") - $(git log -1 --format=\"%s\" HEAD" .. commits_back .. ")\"; echo \"$output\" | ~/.cargo/bin/delta --pager=none",
      '50', 'Git DIFF PREV ' .. new_diff_num, new_diff_num == 1 and nil or max_diff_bufnum)

  else
    -- In non-terminal buffer
    MakeTermWindowVimAsPager('git --no-pager diff | ~/.cargo/bin/delta --pager=none', '40', 'Git Diff')
  end
end

vim.keymap.set({'n', 't'}, '<M-d>', function() display_diff(true) end)

-- addendum to the above which lets me quickly walk back one commit browsing the diff chain.
vim.keymap.set({'n', 't'}, '<M-D>', function() display_diff(false) end)

return M
