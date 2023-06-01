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

-- Inspect and print comment nodes
for _, node in ipairs(comment_nodes) do
  local start_row, start_col, end_row, end_col = node:range()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row+1, false)

  -- Process each line to include only the part within the node's range
  for i, line in ipairs(lines) do
    if i == 1 then -- For the first line, remove characters before the starting column
      line = string.sub(line, start_col + 1)
    end
    if i == #lines then -- For the last line, remove characters after the ending column
      line = string.sub(line, 1, end_col)
    end
    lines[i] = line
  end

  print(vim.inspect({ 
    start_pos = {start_row, start_col},
    end_pos = {end_row, end_col},
    content = lines
  }))
end


