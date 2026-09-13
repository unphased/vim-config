# Herdr Separate Pane

Provides a **Separate pane** plugin action. If the focused pane shares its tab with another pane, it moves into a new focused tab. If it is the tab's only pane, it moves into a new focused workspace.

Herdr 0.9.0 does not add plugin actions to its pane right-click menu. The manifest's `contexts = ["pane"]` field describes the action's context; it does not add a menu item.

## Install

Register the tracked Herdr plugins on each machine running a Herdr server:

```bash
make -C ~/.vim bootstrap-herdr
```

Focus the target pane and press `prefix+space` to invoke the action. It is also available directly from the Herdr CLI:

```bash
herdr plugin action invoke local.move-pane-new-tab.move-pane-new-tab
```

Herdr does not watch plugin manifests. Rerun the bootstrap after adding or changing a tracked `herdr-plugin.toml`. The Unix implementation uses `jq` to read the active tab's pane count; install it on macOS/Linux if it is not already available.

## Test

From the repository root:

```bash
./test-herdr-move-pane-new-tab-plugin.sh
```
