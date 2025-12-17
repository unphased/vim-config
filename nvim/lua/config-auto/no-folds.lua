local group = vim.api.nvim_create_augroup("no_folds", { clear = true })

local function disable_folds()
  vim.opt_local.foldenable = false
  vim.opt_local.foldmethod = "manual"
  vim.opt_local.foldexpr = "0"
  vim.opt_local.foldlevel = 99
  vim.opt_local.foldlevelstart = 99
  vim.opt_local.foldcolumn = "0"
end

disable_folds()

vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType", "WinNew" }, {
  group = group,
  callback = disable_folds,
  desc = "Disable folding everywhere",
})
