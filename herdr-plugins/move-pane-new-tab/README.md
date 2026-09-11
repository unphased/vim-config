# Herdr Move Pane to New Tab

Adds **Move pane to new tab** to Herdr's pane right-click menu. The selected pane is moved out of its current tab into a new focused tab.

## Install

Register the tracked Herdr plugins on each machine running a Herdr server:

```bash
make -C ~/.vim bootstrap-herdr
```

Then right-click a pane and select **Move pane to new tab**.

Herdr does not watch plugin manifests. Rerun the bootstrap after adding or changing a tracked `herdr-plugin.toml`.

## Test

From the repository root:

```bash
./test-herdr-move-pane-new-tab-plugin.sh
```
