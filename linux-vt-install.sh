#!/bin/sh
set -u

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
changed=0
force=0

case "${1:-}" in
  --force) force=1 ;;
  "" ) ;;
  *)
    printf 'usage: %s [--force]\n' "$0" >&2
    exit 2
    ;;
esac

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

ensure_shell_hook() {
  rc_file=$1
  [ -e "$rc_file" ] || return 0

  if grep -F '.config/linux-vt-setup.sh' "$rc_file" >/dev/null 2>&1; then
    return 0
  fi

  {
    printf '\n'
    printf '# Linux virtual terminal colors, font, and OLED blanking.\n'
    printf '[ -r "$HOME/.config/linux-vt-setup.sh" ] && . "$HOME/.config/linux-vt-setup.sh"\n'
  } >> "$rc_file"
  mark_changed "added Linux VT setup hook to $rc_file"
}

ensure_symlink "$repo_dir/.config/tty-pastel" "$HOME/.config/tty-pastel"
ensure_symlink "$repo_dir/.config/linux-vt-setup.sh" "$HOME/.config/linux-vt-setup.sh"

ensure_shell_hook "$HOME/.bashrc"
ensure_shell_hook "$HOME/.zshrc"

printf 'changed=%s\n' "$changed"
