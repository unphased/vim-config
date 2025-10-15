# Dev tool background color system

## Goals
- Centralize color selection logic so terminal shells, Neovim, and other tools share the same behavior: provide context
  for the area that is open based on its location by setting the color.
- Allow per-directory overrides (e.g. `.tmux-bgcolor`) that supersede deterministic mapping.
- Expose modular entry points (preferably small POSIX/Bash scripts) so different environments can consume the same
  resolver while applying colors in their own way.

## Current Pain Points
- **Context mismatch:** Neovim’s working directory can differ from an active buffer’s directory, so delegating to a CWD-based script yields incorrect colors.
- **Duplicated override logic:** `.tmux-bgcolor` lookup and git-root discovery exist in both Lua and shell scripts.
- **Mixed concerns:** `set-bgcolor-by-cwd-tmux.zsh` both resolves colors and applies them, making reuse harder.
- Complexity exists due to different situations requiring different mechanisms to apply the color: if under tmux, must
set with tmux and nvim stays hands off.

## Proposed Architecture

### 1. Path Context Providers
- Each caller provides the directory it cares about (`$PWD`, Neovim buffer dir, etc.).
- Expose a consistent interface: pass a directory via first argument or env var like `TMUX_BG_DIR`.
- Responsibility: identify *what* location we want to color.

### 2. Override Discovery
- Walk upward from the provided directory to find `.tmux-bgcolor` (and eventual extended markers).
- Return both the file path found and the color contents.
- Implement once (POSIX shell preferred); callers rely on it instead of duplicating logic.
- Optional caching keyed by absolute path to avoid repeated filesystem walks.

### 3. Deterministic Color Selection
- Given a directory (and optional override), compute the fallback color.
- Base logic currently lives in `color-pane.sh`; refactor into a reusable function/script.
- Should accept future extensions:
  - Repo-relative subdirectory rules.
  - Alternate lookup mechanisms (e.g. config file mapping patterns to colors).

### 4. Application Layer
- Thin wrappers that take a resolved color and apply it to a UI.
- For tmux: use `TMUX_PANE`/`color-pane.sh` (possibly rewritten to consume the shared selector).
- For Neovide/Vim: apply highlights directly in Lua—no tmux detection needed; just use the resolver output.
- Other consumers simply call the shared resolver and handle the result.

### 5. Error Handling & Reporting
- Standardize exit codes and stdout:
  - Success with override: e.g. `color:<hex> source:override path:/foo/.tmux-bgcolor`.
  - Success with deterministic fallback: `color:<hex> source:deterministic key:<repo>`.
  - No color available: return explicit status so callers can skip applying.
- Logging hooks (optional) so invoking environments can `echom`/`notify` as desired.

## Implementation Steps (Draft)
1. Sketch API for a `tmux-bgcolor-resolve` script:
   - Input: directory (arg/env).
   - Output: structured line(s) describing color & source.
   - Exit codes: 0 success, non-zero error/no color.
2. Move override detection into that resolver (recursive `.tmux-bgcolor`).
3. Extract deterministic selection logic from `color-pane.sh` into the resolver.
4. Update `color-pane.sh` to accept an explicit color (and fall back to resolver when none supplied).
5. Adjust `set-bgcolor-by-cwd-tmux.zsh` to:
   - Determine path context (default `$PWD`).
   - Call resolver, parse output, and invoke color application layer.
6. Modify Neovim Lua:
   - Compute buffer directory.
   - Call resolver via `system()` with the directory context.
   - Apply the returned color to highlights regardless of tmux presence (Lua handles both terminal and Neovide cases).
7. Add tests/examples for both override and deterministic paths.

## Open Questions
- Do we want separate config files for subdirectory-specific colors?
- Should overrides allow disabling coloring (e.g. writing `off`)?
- What caching strategy balances freshness vs. performance?
- How should concurrent callers (multiple tmux panes) coordinate color changes, if at all?
