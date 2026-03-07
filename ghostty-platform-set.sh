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
    source_file="${HOME}/.vim/ghostty.mac.conf"
    ;;
  linux)
    source_file="${HOME}/.vim/ghostty.linux.conf"
    ;;
  *)
    echo "Usage: $0 [macos|linux|auto]" >&2
    exit 1
    ;;
esac

ln -sfn "$source_file" "$out_file"
printf 'Linked %s -> %s\n' "$out_file" "$source_file"
