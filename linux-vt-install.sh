#!/bin/sh
set -u

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
target_home=${LINUX_VT_HOME:-$(dirname -- "$repo_dir")}
changed=0
force=0
systemd=1
systemd_only=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) force=1 ;;
    --systemd) systemd=1 ;;
    --no-systemd) systemd=0 ;;
    --systemd-only)
      systemd=1
      systemd_only=1
      ;;
    *)
      printf 'usage: %s [--force] [--no-systemd]\n' "$0" >&2
      exit 2
      ;;
  esac
  shift
done

log() {
  printf '%s\n' "$*"
}

mark_changed() {
  changed=1
  log "$*"
}

ensure_symlink() {
  src=$1
  dest=$2
  parent=$(dirname -- "$dest")

  mkdir -p -- "$parent"

  if [ -L "$dest" ]; then
    current=$(readlink -- "$dest" 2>/dev/null || true)
    if [ "$current" = "$src" ]; then
      return 0
    fi

    rm -f -- "$dest"
    ln -s -- "$src" "$dest"
    mark_changed "linked $dest -> $src"
    return 0
  fi

  if [ -e "$dest" ]; then
    if [ "$force" -eq 1 ] || cmp -s -- "$src" "$dest"; then
      rm -f -- "$dest"
      ln -s -- "$src" "$dest"
      mark_changed "linked $dest -> $src"
    else
      log "preserved $dest; existing file differs from $src"
    fi
    return 0
  fi

  ln -s -- "$src" "$dest"
  mark_changed "linked $dest -> $src"
}

replace_line() {
  file=$1
  old=$2
  new=$3
  parent=$(dirname -- "$file")
  tmp=$parent/.linux-vt-install.$$

  awk -v old="$old" -v new="$new" '
    $0 == old { print new; next }
    { print }
  ' "$file" > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }

  cat "$tmp" > "$file" || {
    rm -f -- "$tmp"
    return 1
  }
  rm -f -- "$tmp"
}

ensure_shell_hook() {
  rc_file=$1
  [ -e "$rc_file" ] || return 0

  old_hook='[ -r "$HOME/.config/linux-vt-setup.sh" ] && . "$HOME/.config/linux-vt-setup.sh"'
  new_hook='[ -r "$HOME/.vim/linux-vt-setup.sh" ] && . "$HOME/.vim/linux-vt-setup.sh"'

  if grep -F "$new_hook" "$rc_file" >/dev/null 2>&1; then
    return 0
  fi

  if grep -F "$old_hook" "$rc_file" >/dev/null 2>&1; then
    replace_line "$rc_file" "$old_hook" "$new_hook" || return 1
    mark_changed "updated Linux VT setup hook in $rc_file"
    return 0
  fi

  {
    printf '\n'
    printf '# Linux virtual terminal colors, font, and OLED blanking.\n'
    printf '%s\n' "$new_hook"
  } >> "$rc_file"
  mark_changed "added Linux VT setup hook to $rc_file"
}

cleanup_old_setup_link() {
  dest=$target_home/.config/linux-vt-setup.sh
  old_src=$repo_dir/.config/linux-vt-setup.sh

  [ -L "$dest" ] || return 0

  current=$(readlink -- "$dest" 2>/dev/null || true)
  if [ "$current" = "$old_src" ]; then
    rm -f -- "$dest"
    mark_changed "removed obsolete $dest symlink"
  fi
}

write_systemd_unit() {
  unit_dest=$1
  payload_dir=$2
  tmp=$unit_dest.$$

  {
    printf '%s\n' '[Unit]'
    printf '%s\n' 'Description=Linux virtual terminal setup'
    printf '%s\n' 'Documentation=man:setterm(1) man:loadkeys(1) man:setfont(8) man:setvtrgb(8)'
    printf '%s\n' 'ConditionPathExists=/dev/tty1'
    printf 'RequiresMountsFor=%s\n' "$payload_dir"
    printf '%s\n' 'After=systemd-vconsole-setup.service'
    printf '%s\n' 'Before=getty@tty1.service display-manager.service'
    printf '%s\n' ''
    printf '%s\n' '[Service]'
    printf '%s\n' 'Type=oneshot'
    printf '%s\n' 'RemainAfterExit=yes'
    printf '%s\n' 'Environment=TERM=linux'
    printf 'Environment=LINUX_VT_HOME=%s\n' "$target_home"
    printf 'Environment=LINUX_VT_KEYMAP=%s/linux-vt-keymap.map\n' "$payload_dir"
    printf 'Environment=LINUX_VT_PALETTE=%s/tty-pastel\n' "$payload_dir"
    printf 'ExecStart=/usr/bin/sh %s/linux-vt-setup.sh --console /dev/tty1\n' "$payload_dir"
    printf '%s\n' ''
    printf '%s\n' '[Install]'
    printf '%s\n' 'WantedBy=multi-user.target'
  } > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }

  if [ -e "$unit_dest" ] && cmp -s -- "$tmp" "$unit_dest"; then
    rm -f -- "$tmp"
    return 0
  fi

  mv -f -- "$tmp" "$unit_dest"
  mark_changed "installed $unit_dest"
}

install_file() {
  src=$1
  dest=$2
  mode=$3

  if [ ! -e "$dest" ] || ! cmp -s -- "$src" "$dest"; then
    cp -- "$src" "$dest" || return 1
    chmod "$mode" "$dest" || return 1
    mark_changed "installed $dest"
    return 0
  fi

  chmod "$mode" "$dest" || return 1
}

# System-owned runtime files are always converged by content. --force only
# affects replacement of conflicting user files such as ~/.config/tty-pastel.
install_systemd_payload() {
  payload_dir=$1

  mkdir -p -- "$payload_dir" || return 1
  install_file "$repo_dir/linux-vt-setup.sh" "$payload_dir/linux-vt-setup.sh" 0755 || return 1
  install_file "$repo_dir/linux-vt-keymap.map" "$payload_dir/linux-vt-keymap.map" 0644 || return 1
  install_file "$repo_dir/.config/tty-pastel" "$payload_dir/tty-pastel" 0644 || return 1
}

ensure_systemd_unit() {
  unit_dest=/etc/systemd/system/linux-vt-setup.service
  payload_dir=/etc/linux-vt

  if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
      log "skipped systemd setup; sudo is not available to install $unit_dest"
      return 0
    fi

    if [ "$force" -eq 1 ]; then
      sudo LINUX_VT_HOME="$target_home" "$repo_dir/linux-vt-install.sh" --force --systemd-only || return $?
    else
      sudo LINUX_VT_HOME="$target_home" "$repo_dir/linux-vt-install.sh" --systemd-only || return $?
    fi
    return 0
  fi

  install_systemd_payload "$payload_dir"
  write_systemd_unit "$unit_dest" "$payload_dir"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    if systemctl is-enabled linux-vt-setup.service >/dev/null 2>&1; then
      :
    else
      systemctl enable linux-vt-setup.service
      mark_changed "enabled linux-vt-setup.service"
    fi
  fi
}

if [ "$systemd_only" -eq 0 ]; then
  ensure_symlink "$repo_dir/.config/tty-pastel" "$target_home/.config/tty-pastel"
  cleanup_old_setup_link

  ensure_shell_hook "$target_home/.bashrc"
  ensure_shell_hook "$target_home/.zshrc"
fi

if [ "$systemd" -eq 1 ]; then
  ensure_systemd_unit
fi

printf 'changed=%s\n' "$changed"
