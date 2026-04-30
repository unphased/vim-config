#!/bin/sh
set -u

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
target_home=${LINUX_VT_HOME:-$(dirname -- "$repo_dir")}
changed=0
force=0
systemd=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) force=1 ;;
    --systemd) systemd=1 ;;
    *)
      printf 'usage: %s [--force] [--systemd]\n' "$0" >&2
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

ensure_systemd_unit() {
  unit_src=$repo_dir/linux-vt-setup.service
  unit_dest=/etc/systemd/system/linux-vt-setup.service

  if [ "$(id -u)" -ne 0 ]; then
    log "skipped systemd setup; rerun with sudo and --systemd to install $unit_dest"
    return 0
  fi

  ensure_symlink "$unit_src" "$unit_dest"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable linux-vt-setup.service
    mark_changed "enabled linux-vt-setup.service"
  fi
}

ensure_symlink "$repo_dir/.config/tty-pastel" "$target_home/.config/tty-pastel"
cleanup_old_setup_link

ensure_shell_hook "$target_home/.bashrc"
ensure_shell_hook "$target_home/.zshrc"

if [ "$systemd" -eq 1 ]; then
  ensure_systemd_unit
fi

printf 'changed=%s\n' "$changed"
