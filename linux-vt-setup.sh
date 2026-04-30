# Linux virtual terminal setup. Safe to source from interactive shells.
linux_vt_console=

case "${1:-}" in
  --console)
    linux_vt_console=${2:-}
    if [ -z "$linux_vt_console" ]; then
      printf 'usage: %s [--console /dev/ttyN]\n' "${0:-linux-vt-setup.sh}" >&2
      return 2 2>/dev/null || exit 2
    fi
    ;;
  "")
    case "${TERM:-}" in
      linux) ;;
      *) return 0 2>/dev/null || exit 0 ;;
    esac
    ;;
  *)
    printf 'usage: %s [--console /dev/ttyN]\n' "${0:-linux-vt-setup.sh}" >&2
    return 2 2>/dev/null || exit 2
    ;;
esac

linux_vt_font="${LINUX_VT_FONT:-ter-v20n}"
linux_vt_blank_minutes="${LINUX_VT_BLANK_MINUTES:-1}"
linux_vt_powerdown_minutes="${LINUX_VT_POWERDOWN_MINUTES:-1}"
linux_vt_keymap="${LINUX_VT_KEYMAP:-$HOME/.vim/linux-vt-keymap.map}"

if [ -n "$linux_vt_font" ] && command -v setfont >/dev/null 2>&1; then
  if [ -n "$linux_vt_console" ]; then
    setfont -C "$linux_vt_console" "$linux_vt_font" >/dev/null 2>&1 || true
  else
    setfont "$linux_vt_font" >/dev/null 2>&1 || true
  fi
fi

if command -v setvtrgb >/dev/null 2>&1 && [ -r "$HOME/.config/tty-pastel" ]; then
  if [ -n "$linux_vt_console" ]; then
    setvtrgb -C "$linux_vt_console" "$HOME/.config/tty-pastel" >/dev/null 2>&1 || true
  else
    setvtrgb "$HOME/.config/tty-pastel" >/dev/null 2>&1 || true
  fi
fi

if command -v loadkeys >/dev/null 2>&1 && [ -r "$linux_vt_keymap" ]; then
  if [ -n "$linux_vt_console" ]; then
    loadkeys -C "$linux_vt_console" "$linux_vt_keymap" >/dev/null 2>&1 || true
  else
    loadkeys "$linux_vt_keymap" >/dev/null 2>&1 || true
  fi
fi

if command -v setterm >/dev/null 2>&1 && [ -n "$linux_vt_console" ]; then
  setterm \
    --blank "$linux_vt_blank_minutes" \
    --powersave powerdown \
    --powerdown "$linux_vt_powerdown_minutes" \
    < "$linux_vt_console" > "$linux_vt_console" 2>/dev/null || true
elif command -v setterm >/dev/null 2>&1 && [ -t 1 ]; then
  setterm \
    --blank "$linux_vt_blank_minutes" \
    --powersave powerdown \
    --powerdown "$linux_vt_powerdown_minutes" \
    2>/dev/null || true
fi
