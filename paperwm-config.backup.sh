#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dconf dump /org/gnome/shell/extensions/paperwm/ > "${script_dir}/paperwm-config.dconf"
echo "Backed up system PaperWM config -> ${script_dir}/paperwm-config.dconf"
