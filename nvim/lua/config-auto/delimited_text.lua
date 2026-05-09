local group = vim.api.nvim_create_augroup("slu_delimited_text_no_wrap", { clear = true })

local function disable_delimited_text_wrapping(args)
  local bufnr = args.buf

  vim.bo[bufnr].textwidth = 0
  vim.bo[bufnr].formatoptions = vim.bo[bufnr].formatoptions:gsub("[ta]", "")

  if vim.api.nvim_get_current_buf() == bufnr then
    vim.wo.wrap = false
  end
end

local function configure_tsv_tabs(args)
  local bufnr = args.buf

  vim.bo[bufnr].expandtab = false
  vim.bo[bufnr].softtabstop = 0

  -- TSV uses tab as data, so bypass completion/snippet mappings and insert it literally.
  vim.keymap.set("i", "<Tab>", "<C-V><Tab>", {
    buffer = bufnr,
    desc = "Insert literal tab in TSV",
  })
end

local function configure_delimited_text(args)
  disable_delimited_text_wrapping(args)

  local extension = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(args.buf), ":e")
  if extension == "tsv" or vim.bo[args.buf].filetype == "tsv" then
    configure_tsv_tabs(args)
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
    configure_delimited_text(args)
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = { "tsv", "csv" },
  callback = configure_delimited_text,
})

vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
  group = group,
  pattern = { "*.tsv", "*.csv" },
  callback = configure_delimited_text,
})

for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    local extension = vim.fn.fnamemodify(name, ":e")
    if extension == "tsv" or extension == "csv" then
      vim.bo[bufnr].filetype = extension
      configure_delimited_text({ buf = bufnr })
    end
  end
end
