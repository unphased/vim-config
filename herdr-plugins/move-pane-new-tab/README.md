# Herdr Separate Pane

Adds **Separate pane** to Herdr's pane right-click menu. If the selected pane shares its tab with another pane, it moves into a new focused tab. If it is the tab's only pane, it moves into a new focused workspace.

## Install

Register the tracked Herdr plugins on each machine running a Herdr server:

```bash
make -C ~/.vim bootstrap-herdr
```

Then right-click a pane and select **Separate pane**. The same behavior is available with `prefix+space`.

Herdr does not watch plugin manifests. Rerun the bootstrap after adding or changing a tracked `herdr-plugin.toml`.

## Test

From the repository root:

```bash
./test-herdr-move-pane-new-tab-plugin.sh
```
