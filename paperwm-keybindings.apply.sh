#!/usr/bin/env bash
set -euo pipefail

# Run this script when you want to apply the keybinds stored in
# paperwm-keybindings.dconf (single source of truth).
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dconf load / < "${script_dir}/paperwm-keybindings.dconf"
