local group = vim.api.nvim_create_augroup("slu_delimited_text_no_wrap", { clear = true })

local function disable_delimited_text_wrapping(args)
  local bufnr = args.buf

  vim.bo[bufnr].textwidth = 0
  vim.bo[bufnr].formatoptions = vim.bo[bufnr].formatoptions:gsub("[ta]", "")

  if vim.api.nvim_get_current_buf() == bufnr then
    vim.wo.wrap = false
  end
end

vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  group = group,
  pattern = { "*.tsv", "*.csv" },
  callback = function(args)
    local extension = vim.fn.fnamemodify(args.file, ":e")
    if extension == "tsv" or extension == "csv" then
      vim.bo[args.buf].filetype = extension
    end
    disable_delimited_text_wrapping(args)
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = { "tsv", "csv" },
  callback = disable_delimited_text_wrapping,
})

vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
  group = group,
  pattern = { "*.tsv", "*.csv" },
  callback = disable_delimited_text_wrapping,
})

for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    local extension = vim.fn.fnamemodify(name, ":e")
    if extension == "tsv" or extension == "csv" then
      vim.bo[bufnr].filetype = extension
      disable_delimited_text_wrapping({ buf = bufnr })
    end
  end
end
