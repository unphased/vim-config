#!/bin/sh
set -eu

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
dconf load /org/gnome/shell/extensions/paperwm/ < "${script_dir}/paperwm-config.dconf"
echo "Applied ${script_dir}/paperwm-config.dconf -> system PaperWM config"
