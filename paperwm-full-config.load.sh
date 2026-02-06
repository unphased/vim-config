#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dconf load /org/gnome/shell/extensions/paperwm/ < "${script_dir}/paperwm-full-config.dconf"
echo "Loaded PaperWM config from ${script_dir}/paperwm-full-config.dconf"
