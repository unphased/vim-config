# Linux virtual terminal setup. Safe to source from interactive shells.
case "${TERM:-}" in
  linux) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

linux_vt_font="${LINUX_VT_FONT:-ter-v20n}"
linux_vt_blank_minutes="${LINUX_VT_BLANK_MINUTES:-1}"
linux_vt_powerdown_minutes="${LINUX_VT_POWERDOWN_MINUTES:-1}"

if [ -n "$linux_vt_font" ] && command -v setfont >/dev/null 2>&1; then
  setfont "$linux_vt_font" >/dev/null 2>&1 || true
fi

if command -v setvtrgb >/dev/null 2>&1 && [ -r "$HOME/.config/tty-pastel" ]; then
  setvtrgb "$HOME/.config/tty-pastel" >/dev/null 2>&1 || true
fi

if command -v setterm >/dev/null 2>&1 && [ -t 1 ]; then
  setterm \
    --blank "$linux_vt_blank_minutes" \
    --powersave powerdown \
    --powerdown "$linux_vt_powerdown_minutes" \
    2>/dev/null || true
fi
