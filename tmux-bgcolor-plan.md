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
- Provide a reusable function/library that maps normalized paths (repo root, host, etc.) to palette colors.
- Support composable rules: repo-scoped palettes, subdirectory suffixes, or pattern maps defined in a config file.
- Return consistent keys so different consumers make the same caching decisions.

### 4. Application Adapters Using OSC 11
- Each adapter owns only two tasks: decide which path to ask the resolver about, then emit OSC 11 with the chosen color.
- Shell/tmux integration: zsh prompt hook resolves `$PWD` (or git root) and prints `OSC 11` directly; when inside tmux,
  tmux propagates the color to the pane automatically.
- Long-lived daemons (e.g. direnv, task runners) can also print OSC 11 when they enter a new context, no tmux-specific
  code required.
- Provide a small helper (`print-osc11.sh`?) that ensures the escape sequence is emitted correctly and can be reused by
  scripts that prefer delegation.

### 5. Neovim Integration
- Lua layer queries the resolver with the buffer file path (not process CWD), parses metadata, and sets both the global
  UI background (affects command line, titles, Neovide chrome) and a buffer-local `Normal` highlight.

### 6. Telemetry & Guardrails
- Normalize exit codes and structured stdout so adapters can detect “no color” vs. “error”.
- Provide optional verbose logging hooks (`COLOR_CONTEXT_DEBUG=1`) for troubleshooting thrashing or incorrect colors.

## Implementation Steps (Draft)
1. Finalize the resolver contract: argument/env expectations, stdout schema, exit codes, and env flags (e.g. debug,
   cache bypass).
2. Implement override discovery inside the resolver with optional caching.
3. Port deterministic palette logic from `color-pane.sh` into a shared library the resolver can source.
4. Provide a reusable OSC 11 helper (shell function or script) that validates hex values and emits the escape sequence.
5. Update shell/tmux integrations to consume the resolver + OSC helper, removing tmux-specific color plumbing.
6. Rework Neovim Lua to request colors per buffer, set global UI background, and manage buffer-local highlights.
7. Document adapter usage patterns and add tests/fixtures covering overrides and deterministic fallbacks.

## Open Questions
- Do we want a shared palette definition file to make deterministic colors easier to tweak without touching code?
- How should we coordinate OSC 11 emissions across multiple apps (e.g. shells, Neovim, background jobs) so the last
  writer is intentional and not noisy?
- What caching policy (per repo, time-to-live, manual invalidation) provides good performance without stale overrides?
- How do we expose resolver results to GUI clients beyond Neovide (e.g. Ghostty integrations)?
