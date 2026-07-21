#!/bin/sh
set -eu

# Run this script when you want to apply the keybinds stored in
# paperwm-keybindings.dconf (single source of truth).
script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
dconf load / < "${script_dir}/paperwm-keybindings.dconf"
