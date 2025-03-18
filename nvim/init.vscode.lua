print("hello from vscode embedded nvim lua init!")

vim.keymap.set({ "n", "x" }, "k", "gk")
vim.keymap.set({ "n", "x" }, "j", "gj")
vim.keymap.set({ "n", "x" }, "gk", "k")
vim.keymap.set({ "n", "x" }, "gj", "j")

vim.keymap.set({ "x", "n" }, "K", "5gk")
vim.keymap.set({ "x", "n" }, "J", "5gj")
vim.keymap.set({ "x", "n" }, "H", "7h")
vim.keymap.set({ "x", "n" }, "L", "7l")
