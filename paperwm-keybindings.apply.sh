#!/usr/bin/env bash
set -euo pipefail

gsettings set org.gnome.shell.extensions.paperwm.keybindings switch-left "['<Super>h']"
gsettings set org.gnome.shell.extensions.paperwm.keybindings switch-down "['<Super>j']"
gsettings set org.gnome.shell.extensions.paperwm.keybindings switch-up "['<Super>k']"
gsettings set org.gnome.shell.extensions.paperwm.keybindings switch-right "['<Super>l']"
gsettings set org.gnome.desktop.wm.keybindings hide-window "[]"
