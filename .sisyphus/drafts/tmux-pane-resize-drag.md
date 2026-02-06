# Draft: Tmux Pane Resize Drag Bug

## Requirements (confirmed)
- User reports tmux mouse drag-to-resize panes fails for horizontal splits; works from corners or vertical split borders.
- Behavior is correct with an empty tmux config, so regression is caused by something in `.tmux.conf`.
- Goal: identify likely config culprits and define good bisection split points for commenting out sections.

## Technical Decisions
- Use a bisection-style disable strategy by commenting out large, clearly delimited sections first, then halving within the failing section.
- Prioritize disabling any mouse-focused plugins/bindings before unrelated aesthetics.

## Research Findings
- `.tmux.conf` explicitly enables mouse: `set -g mouse on`.
- There is a mouse-focused plugin configured: `set -g @plugin 'nhdaly/tmux-better-mouse-mode'` plus multiple `@scroll-*` options. This is the strongest single suspect because it is designed to alter mouse interactions.
- Config sets an unusually low `escape-time`: `set -s escape-time 5`. This can sometimes break escape-sequence based inputs (mouse events are escape-sequence heavy), so it's a second high-value suspect.
- Pane border presentation is customized: `setw -g pane-border-status top`, `setw -g pane-border-format ...`, `setw -g pane-border-indicators both`. Unlikely, but it changes border rows and could affect the exact row you try to drag.
- There are custom mouse binds for the status line (wheel up/down to change windows, double click to zoom) but no explicit `MouseDrag1Border` rebind is visible in this file.

### High-Value Bisect Split Points (in this file)
- **Section A: Terminal + key encoding** (default-terminal, terminal-features/overrides, user-keys, xterm-keys, escape-time)
- **Section B: Keybinds (non-mouse)** (most of the file: pane navigation, resize via keys, window cycling)
- **Section C: Mouse core + mouse binds** (`set -g mouse on` through the status wheel/double-click binds)
- **Section D: Borders + status aesthetics** (status-format, pane-border-format, pane-border-status top)
- **Section E: Plugins** (TPM install, resurrect, better-mouse-mode, `run-shell tpm`)

### Suggested Bisect Order (fastest signal first)
1. Disable only `nhdaly/tmux-better-mouse-mode` (leave other plugins intact).
2. If still broken, restore plugin and increase `escape-time` (e.g. comment out the `set -s escape-time 5` line to fall back to default).
3. If still broken, temporarily revert border-status customization: comment out `setw -g pane-border-status top` (and optionally `pane-border-format`).
4. If still broken, comment out the entire mouse subsection (status wheel/double click binds) to rule out accidental binding collisions.

## Open Questions
- What tmux version and terminal emulator are in use?
- Does the issue reproduce only on one machine/terminal or everywhere?
- Which parts of the config touch mouse bindings, key tables, or terminal overrides?

## Scope Boundaries
- INCLUDE: pinpointing suspicious tmux options/bindings/plugins; proposing a bisect strategy and checkpoints.
- EXCLUDE: implementing a fixed config (executor will do changes during bisect).
