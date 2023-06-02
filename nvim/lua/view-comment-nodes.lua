-- Get the current buffer's language
local bufnr = vim.api.nvim_get_current_buf()
local lang = vim.api.nvim_buf_get_option(bufnr, 'filetype')

-- Get the parser for the current buffer's language
local parser = vim.treesitter.get_parser(bufnr, lang)

-- Parse a query that matches comment nodes
local query = vim.treesitter.query.parse(lang, '((comment) @comment)')

local get_comment_nodes = function()
  local root = parser:parse()[1]:root()
  local results = query:iter_captures(root, bufnr)

  local comment_nodes = {}
  for id, node in results do
    local name = query.captures[id] -- This should be "comment" for comment nodes
    if name == 'comment' then
      table.insert(comment_nodes, node)
    end
  end

  return comment_nodes
end

local comment_nodes = get_comment_nodes()

-- Inspect, merge, and print comment nodes
local merged_comments = {}
local last_end_row = -1
for _, node in ipairs(comment_nodes) do
  local start_row, start_col, end_row, end_col = node:range()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row+1, false)

  -- local to_add = ""
  -- if #lines == 1 then
  --   local front_of_line = string.sub(lines[1], 1, start_col)
  --   local is_solely_comment = front_of_line:match("^%s*$")
  --   if is_solely_comment then
  --     to_add = string.sub(lines[1], start_col + 1)
  --   end
  --   end
  -- end

  local is_content_before_comment_whitespace

  for i, line in ipairs(lines) do
    if i == 1 then -- For the first line, remove characters before the starting column
      line = string.sub(line, start_col + 1)
      -- Extract the content before the comment on the same line and check if it's all whitespace
      local line_before_comment = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1]
      local content_before_comment = string.sub(line_before_comment, 1, start_col)
      is_content_before_comment_whitespace = content_before_comment:match("^%s*$") ~= nil
    end
    if i == #lines then -- For the last line, remove characters after the ending column
      line = string.sub(line, 1, end_col)
    end
    lines[i] = line
  end

  if start_row == last_end_row + 1 and #merged_comments > 0 and is_content_before_comment_whitespace then
    -- If the current comment node is consecutive to the last one and the preceding part of the line before the comment is solely whitespace, append its content
    for _, line in ipairs(lines) do
      table.insert(merged_comments[#merged_comments].content, line)
    end
    -- Update the end position
    merged_comments[#merged_comments].end_pos = {end_row, end_col}
  else
    -- If the current comment node is not consecutive to the last one or the preceding part of the line before the comment is not solely whitespace, add a new block
    table.insert(merged_comments, {
      start_pos = {start_row, start_col},
      end_pos = {end_row, end_col},
      content = lines
    })
  end

  last_end_row = end_row

end

function shell_quote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- i think we just need to order these by decreasing specificity so that the more correct ones get applied first.
-- if we can reduce them all to single patterns then we can simplify the architecture as well.
local comment_delimiters = {
  lua = {
    multiline = {
      prefix = { "%-%-%[=*%[" }, -- '--[[', '--[=[', and so on
      suffix = { '%-*%]=*%]' } -- ']]', '--]]', '--]=]', and so on
    }
  },
  cpp = {
    multiline = {
      prefix = { '/%*+' }, -- '/*', '/**' and so on
      suffix = { '%*+/' } -- '*/', '**/' and so on
    }
  },
  c = {
    multiline = {
      prefix = { '/%*+' }, -- '/*', '/**' and so on
      suffix = { '%*+/' } -- '*/', '**/' and so on
    }
  }
  -- Add other languages here
}

for _, block in ipairs(merged_comments) do
  if #block.content == 1 then
    goto continue
  end
  local comment_prefixes = comment_delimiters[lang].multiline.prefix
  local comment_suffixes = comment_delimiters[lang].multiline.suffix
  
  for i, line in ipairs(block.content) do
    -- Remove prefixes from the first line of a block
    if i == 1 then
      for _, prefix in ipairs(comment_prefixes) do
        line = line:gsub("^%s*"..prefix, "")
      end
    end

    -- Remove suffixes from the last line of a block
    if i == #block.content then
      for _, suffix in ipairs(comment_suffixes) do
        line = line:gsub(suffix.."%s*$", "")
      end
    end
    
    block.content[i] = line
  end

  local command = "echo " .. shell_quote(table.concat(block.content, "\n"))
    .. " | PARINIT=\"rTbgqR B=.,?'_A_a_@ Q=_s>|\" par 79"
  local handle = io.popen(command, 'r')
  local result = handle:read("*a")
  handle:close()

  print(vim.inspect({ 
    start_pos = block.start_pos,
    end_pos = block.end_pos,
  }))
  print("Before:", "\n"..table.concat(block.content, "\n"))
  print("After:", "\n"..result)
  ::continue::
end

  --[[
    Yeah this is a text thing and 
    this is a second line for it and it is a really long line so i hope this lets it get reformatted by par so lets
    see how it goes man
  --]]

  -- Yeah this is a text thing and 
  -- this is a second line for it and it is a really long line so i hope this lets it get reformatted by par so lets
  -- see how it goes man
