#!/usr/bin/env bash
set -euo pipefail

platform="${1:-auto}"
out_file="${HOME}/.vim/ghostty.platform.conf"

if [[ "$platform" == "auto" ]]; then
  case "$(uname -s)" in
    Darwin) platform="macos" ;;
    Linux) platform="linux" ;;
    *)
      echo "Unsupported OS for auto-detect: $(uname -s)" >&2
      exit 1
      ;;
  esac
fi

case "$platform" in
  macos)
    target="${HOME}/.vim/ghostty.binds.macos.conf"
    ;;
  linux)
    target="${HOME}/.vim/ghostty.binds.linux.conf"
    ;;
  *)
    echo "Usage: $0 [macos|linux|auto]" >&2
    exit 1
    ;;
esac

printf 'config-file = %s\n' "$target" > "$out_file"
printf 'Wrote %s -> %s\n' "$out_file" "$target"
