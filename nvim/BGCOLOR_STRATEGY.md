## Background color strategy (approved)

Goal: Assign a deterministic project background color without relying on Neovim’s global `cwd` constantly changing.

### Color source of truth

- Use `~/util/bgcolor.sh --format=hex <path>` to compute `#RRGGBB`.
  - Supports `.tmux-bgcolor` overrides up the directory tree.
  - Falls back to deterministic hashing of git repo root (or absolute dir if not in git).
- Neovim applies background via highlights (`Normal`/`NormalNC`) for consistent behavior in Neovide and TUI.

### Anchor path selection (per active window)

When updating background, pick an anchor path based on the currently focused window/buffer:

- File buffers: anchor is the buffer’s file path (repo boundary derived from its directory).
- NvimTree: anchor is the NvimTree “root” directory.
  - Configure nvim-tree to update **window-local cwd** (`:lcd`) on root changes (not global `:cd`).
  - Use Neovim `DirChanged` (scope=window) + `WinEnter`/`BufEnter` to refresh background.
- Terminal buffers: anchor is the **live shell cwd**, pushed from shell integration (no polling).
  - Shell computes the color (same `bgcolor.sh`) and sends it to Neovim via `nvim --server ... --remote-expr ...` along with the terminal buffer id.
  - Neovim stores per-terminal-buffer `cwd`/`color` and applies it when that terminal is focused.

### Shell integration (zsh)

- Terminals that need live-cwd background must be launched via a Neovim wrapper that injects:
  - `NVIM` (servername) and `NVIM_TERM_BUF` (terminal buffer number)
- zsh hook (e.g. `chpwd`/`precmd`) computes:
  - `hex=$(bgcolor.sh --format=hex "$PWD")`
  - emits OSC11 locally
  - calls `nvim --server "$NVIM" --remote-expr ...` to notify Neovim with `(bufnr, cwd, hex)`

Recommended: use a single hook function that always emits OSC11 and conditionally pushes to Neovim when `NVIM`/`NVIM_TERM_BUF` are set (see `nvim/shell/nvim-bgcolor.zsh`).
