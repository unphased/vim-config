#!/bin/sh
set -eu

script_dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
dconf dump /org/gnome/shell/extensions/paperwm/ > "${script_dir}/paperwm-config.dconf"
echo "Backed up system PaperWM config -> ${script_dir}/paperwm-config.dconf"
