# Dev tool background color system

## Goals
- Standardize on OSC 11 background sequences so any shell/app (including tmux panes) can set its own background with a
  simple `printf`, removing tmux-specific coupling while keeping visual context consistent.
- Share one color policy across shells, Neovim buffers, Neovide windows, etc. so location-based cues remain aligned even
  when buffers diverge from process working directories.
- Continue to support per-directory overrides (e.g. `.tmux-bgcolor`) while also enabling deterministic fallbacks when no
  override exists.
- Offer lightweight, composable entry points (POSIX shell preferred) that apps can call to obtain color decisions and
  then apply them with their native mechanisms (OSC 11, Neovim highlights, future integrations).

## Current Pain Points
- **Path context remains tricky:** Neovim buffers, LSP-driven edits, and shell jobs may all point at different
  directories, so we still need a first-class way to declare “what location are we coloring?” beyond `$PWD`.
- **Override discovery is duplicated:** `.tmux-bgcolor` lookup and git-root discovery still live in both Lua and shell
  code, increasing maintenance cost.
- **Highlight layering in Neovim:** We must coordinate global background (for command line/UI) with per-buffer `Normal`
  highlights so buffer-specific colors persist without fighting each other.
- **Color emission collisions:** With OSC 11 available to everyone, we need simple conventions to avoid competing
  processes from thrashing the terminal background (e.g. last-writer wins rules, opt-in behaviors).

## Proposed Architecture

### 1. Color Resolver CLI
- Single POSIX-friendly script takes a path (arg/env) and emits structured metadata such as
  `color=<hex> source=override anchor=/repo`.
- Responsible for: normalizing the subject path, consulting overrides, falling back to deterministic palette logic, and
  providing stable identifiers so callers can avoid reapplying colors unnecessarily.

### 2. Override & Metadata Store
- Centralize `.tmux-bgcolor` discovery.
- Cache lookup results by absolute path to minimize repeated filesystem walks while still allowing invalidation knobs
  (env var or timestamp awareness).

### 3. Deterministic Palette Engine
- Encapsulate deterministic mapping logic (repo root, host, etc.) inside the resolver so a single executable can reuse it.
- Support composable rules: repo-scoped palettes, subdirectory suffixes, or pattern maps defined in a config file.
- Return consistent keys so different consumers make the same caching decisions.

### 4. Application Adapters Using OSC 11
- Each adapter owns only two tasks: decide which path to ask the resolver about, then emit OSC 11 with the chosen color.
- Shell/tmux integration: zsh prompt hook resolves `$PWD` (or git root) and prints `OSC 11` directly; when inside tmux,
  tmux propagates the color to the pane automatically.
- Long-lived daemons (e.g. direnv, task runners) can also print OSC 11 when they enter a new context, no tmux-specific
  code required.

### 5. Neovim Integration
- Lua layer queries the resolver with the buffer file path (not process CWD), parses metadata, and sets both the global
  UI background (affects command line, titles, Neovide chrome) and a buffer-local `Normal` highlight.

### 6. Telemetry & Guardrails
- Normalize exit codes and structured stdout so adapters can detect “no color” vs. “error”.
- Provide optional verbose logging hooks (`COLOR_CONTEXT_DEBUG=1`) for troubleshooting thrashing or incorrect colors.

## Implementation Steps (Draft)
1. Implement `~/util/bgcolor.sh` to accept a target path, find overrides (if any), derive deterministic fallbacks, and
   emit either OSC 11 (default) or raw hex when `--format=hex` is passed.
2. Fold the relevant logic from `color-pane.sh` and `set-bgcolor-by-cwd-tmux.zsh` into the new script, then retire the
   old helpers.
3. Update zsh/tmux prompt hooks to call `bgcolor.sh` directly and remove legacy tmux-specific background commands.
4. Adjust Neovim Lua integration to invoke `bgcolor.sh --format=hex` per buffer and apply the returned color to global and
   buffer-local highlights.
5. Add inline documentation and perform manual smoke tests across shells, tmux panes, and Neovim to confirm consistent
   behavior.

## Tactical Plan (Next Iteration)

### Background Resolver Script (~/util/bgcolor.sh)
- Consolidate the logic currently spread across `color-pane.sh` and `set-bgcolor-by-cwd-tmux.zsh` into a single script
  (`~/util/bgcolor.sh`).
- Default behavior: accept an optional path argument (fall back to `$PWD`), locate the repo root, check for
  `.tmux-bgcolor`, derive the deterministic color when no override is found, and emit an OSC 11 sequence.
- Provide lightweight output controls such as `--format=hex` (for Neovim) and `--format=osc11` (default) so other tools
  can reuse the same script without extra plumbing.
- Keep the implementation stateless for v1—every invocation recomputes so we can deliver quickly.

### Shell & Tmux Flow (~/.oh-my-zsh)
- Remove `~/util/set-bgcolor-by-cwd-tmux.zsh` and replace its usage in prompt hooks with direct calls to
  `~/util/bgcolor.sh`.
- Ensure the zsh prompt hook captures the desired path (usually `$PWD` or git root) and lets tmux propagate OSC 11 to the
  pane automatically.
- Verify no other shell scripts depend on the old helper; update or delete them as part of the rollout.

### Neovim Integration (~/nvim)
- Identify the Lua module currently invoking `.tmux-bgcolor` logic and update it to run the resolver via `vim.system()`
  or `vim.fn.system()` with the active buffer path.
- Apply the resolved color by setting the global background highlight (affects command line/Neovide) and a buffer-local
  `Normal` highlight so per-buffer colors persist across window splits.
- Use the script’s `--format=hex` (or similar) option so Neovim receives raw color values rather than emitting OSC 11
  directly.
- Ensure the Neovim code paths avoid redundant resolver calls on rapid buffer switches (e.g. memoize per buffer number).

### Validation & Rollout
- Smoke-test the new script directly (`bgcolor.sh`, `bgcolor.sh --format=hex`) to ensure override and fallback behavior.
- Use a temporary tmux session to confirm OSC 11 output updates pane backgrounds and that prompts reapply colors after
  commands exit.
- Document quick usage notes in the repo (or inline script comments) describing the default behavior and available
  formats.

## Future Directions
- Split shared logic into a sourceable library if multiple long-lived processes need direct function access.
- Reintroduce memoization or caching once we have profiling data that justifies the complexity.
- Offer a dedicated OSC 11 helper script for environments that only need to emit the escape sequence.
- Build out automated tests/fixtures beyond manual smoke tests to cover edge cases and regressions.
- Add richer output modes (e.g. JSON metadata) if more consumers require structured data.

## Open Questions
- Do we want a shared palette definition file to make deterministic colors easier to tweak without touching code?
- How should we coordinate OSC 11 emissions across multiple apps (e.g. shells, Neovim, background jobs) so the last
  writer is intentional and not noisy?
- What caching policy (per repo, time-to-live, manual invalidation) provides good performance without stale overrides?
- How do we expose resolver results to GUI clients beyond Neovide (e.g. Ghostty integrations)?
- Could OSC 11-based background flashing serve as a lightweight alert mechanism (e.g. temporary pulses for notifications)?
