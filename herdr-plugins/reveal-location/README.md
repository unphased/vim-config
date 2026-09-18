# Present-state file reveal

Control-click an OSC8 `file://` link in Herdr to reuse a project Neovim in the **clicked workspace**, or open Neovim in a new side-by-side split from the clicked pane. The plugin accepts links from **any** producer; it does not detect raw `src/foo.ts:42` text. No Ghostty patch or OS URL registration is needed.

```mermaid
flowchart LR
  P[Pi display transformer] --> O[OSC8 file link]
  A[Other OSC8 producers] --> O
  O --> H[Herdr Control-click]
  H --> R[~/util/reveal-location]
  N[Workspace-scoped Neovim registry] --> R
  R -->|matching editor, any tab| E[RPC open + focus pane]
  R -->|no matching editor| S[Right-hand split + Neovim]
```

## Install and use

This requires the companion `~/util/reveal-location` and the Pi extension in `~/util/pi/extensions/file-links/`.

```sh
herdr plugin link ~/.vim/herdr-plugins/reveal-location
# Or use the repository's bootstrap, once these files are tracked:
make -C ~/.vim bootstrap-herdr
```

Neovim loads `config.reveal` from `init.lua`. Existing editors can publish immediately without re-sourcing their whole config:

```vim
:lua require('config.reveal').setup()
```

Use Pi `/reload` to load the file-links extension. It transforms assistant Markdown only: existing files in inline code and conservative prose references become explicit links. Fenced code, existing links, and unresolved paths stay unchanged. Built-in Pi tool path links also work. `PI_HYPERLINKS=0` disables OSC8; unset/auto detection is supplemented inside Herdr unless Pi settings explicitly disable hyperlinks.

**Control-click**, not Ghostty-native Cmd-click, is the managed reveal gesture. Herdr supplies the URL and clicked-pane context, and invokes this plugin server-side. The helper executes on the machine where the pane's Herdr server runs. Remote-to-local editor routing is not implemented.

## Target and selection rules

- `file:///absolute/path` opens the current file; without a location, an existing cursor is preserved.
- `file:///absolute/path#L42C7` or `#L42` opens a one-based line/byte-column. This fragment is our convention, not an OS standard. Out-of-range positions are clamped by Neovim.
- Legacy local `file://HOST/path:42:7` and `path:42` arguments are supported by the helper. URI paths must be percent-encoded. Literal existing filenames win over ambiguous numeric suffixes.
- Foreign hosts, missing files, unsupported fragments, control characters, and special files are rejected. No automatic SSH or project-wide searching.
- Text/source files use only registered terminal Neovims on the clicked Herdr server **in that workspace**, across all its tabs. Neovide and other workspaces are excluded. Exact current file wins; otherwise match the same Git/worktree root (including sibling CWDs), then CWD depth and recency. Without Git, use ancestor-CWD matching. PID, attached UI, and RPC identity are checked. A higher-ranked live editor that times out aborts with an error instead of opening duplicates.
- Modified buffers are preserved. Navigation uses structured data through Neovim RPC, never shell-evaluated paths.
- No matching workspace editor: create a right-hand split relative to the **clicked** pane, set its CWD to the target's Git/worktree root (or parent directory), launch configured Neovim directly, and focus it. No shell input is injected into the source pane. The next link can reuse this editor.
- Explicit `~/util/reveal-location --neovide -- 'file:///absolute/path#L42'` retains GUI selection and `NeovideFocus`. Outside Herdr, the helper retains global editor selection and Neovide fallback.
- Directories/nontext files are revealed in Finder on macOS; Linux opens the directory or the file's parent. The helper does not launch linked applications/executables via file associations.

The registry is `${XDG_STATE_HOME:-~/.local/state}/reveal-location/editors/<pid>.json`, atomically maintained by each UI-attached editor. Headless helpers and incomplete GUI startup handshakes do not register. Neovide ignores inherited Herdr/tmux variables. The old `nvim-in-tmux.state` is no longer consumed. An editor with both terminal environments is treated as Herdr-hosted; nested-tmux navigation is not yet modeled. Herdr pane focus does not promise to foreground another outer-terminal window/client.

Every helper request appends a private JSONL trace to `${XDG_STATE_HOME:-~/.local/state}/reveal-location/reveal.log`: incoming target, clicked-pane identity, editor selection, action, outcome, and duration. Dry runs are marked in every record. Logging is best-effort and does not affect navigation; the log is append-only and may be cleared when desired.

Failed reveals also appear in Herdr's plugin log and request a notification. Inspect with:

```sh
herdr plugin log list --plugin local.reveal-location
tail -f ~/.local/state/reveal-location/reveal.log
~/util/reveal-location --dry-run -- 'file:///absolute/path#L42'
```

`--dry-run` may perform read-only editor probes but does not navigate, focus, or launch anything.

If Control-click produces no new helper entry and no Herdr plugin entry, dispatch never reached the helper. A URL printed in parentheses next to a styled label is Pi's **non-OSC8 fallback**, not a working OSC8 link. Reload the updated file-links extension and check again. Herdr clicks log `navigate` for reuse or `split-herdr` for creation, including source/workspace and created-pane identity. `launch-neovide` is reserved for outside-Herdr or explicit GUI mode. To make an already-running terminal editor eligible, publish from it with the setup command above. A hit-Enter or confirmation prompt can block normal RPC: dismiss it in that editor before setup or retrying. Probe timings/reasons are included in the `selection` log entry. `launch-neovide` success confirms process creation only, not GUI readiness.

## Validation

`make -C ~/.vim test` tests publication, lifecycle/container precedence, adapter argv safety, and error notifications. `make -C ~/util test-reveal` includes disposable headless Neovim RPC tests. Pi's suite tests Markdown conversion and actual renderer OSC8 output.

Disposable Herdr sessions exercised the real Pi extension and plain-shell OSC8 links through `pane.link.activate` → production plugin/helper → exact line/column. The workspace-policy smoke additionally verified: a matching editor in another workspace is ignored; clicking an unfocused source creates and focuses a local split; the second click reuses it without another split; and moving the editor to another tab in the same workspace still permits reuse. No existing editor buffers were changed during the smoke test. GUI Control-click transport was previously verified in `spikes/terminal-links/`; the production smoke uses that same Herdr activation API without stealing window focus.
