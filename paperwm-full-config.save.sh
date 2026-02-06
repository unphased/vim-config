#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dconf dump /org/gnome/shell/extensions/paperwm/ > "${script_dir}/paperwm-full-config.dconf"
echo "Saved PaperWM config to ${script_dir}/paperwm-full-config.dconf"
