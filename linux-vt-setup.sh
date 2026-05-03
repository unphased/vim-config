#!/bin/sh
# Linux virtual terminal setup. Safe to source from interactive shells.
linux_vt_console=

case "${1:-}" in
  --console)
    linux_vt_console=${2:-}
    if [ -z "$linux_vt_console" ]; then
      printf 'usage: %s [--console /dev/ttyN]\n' "${0:-linux-vt-setup.sh}" >&2
      return 2 2>/dev/null || exit 2
    fi
    TERM=linux
    export TERM
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

linux_vt_font="${LINUX_VT_FONT:-ter-118b}"
linux_vt_blank_minutes="${LINUX_VT_BLANK_MINUTES:-1}"
linux_vt_powerdown_minutes="${LINUX_VT_POWERDOWN_MINUTES:-1}"
linux_vt_home="${LINUX_VT_HOME:-$HOME}"
linux_vt_keymap="${LINUX_VT_KEYMAP:-$linux_vt_home/.vim/linux-vt-keymap.map}"
linux_vt_palette="${LINUX_VT_PALETTE:-$linux_vt_home/.config/tty-pastel}"
linux_vt_underline_color="${LINUX_VT_UNDERLINE_COLOR:-14}"
linux_vt_dim_color="${LINUX_VT_DIM_COLOR:-8}"
linux_vt_cursor="${LINUX_VT_CURSOR:-17;0;32}"

case "$linux_vt_underline_color" in
  [0-9]|1[0-5]) ;;
  *) linux_vt_underline_color=14 ;;
esac
case "$linux_vt_dim_color" in
  [0-9]|1[0-5]) ;;
  *) linux_vt_dim_color=8 ;;
esac

if [ -n "$linux_vt_font" ] && command -v setfont >/dev/null 2>&1; then
  if [ -n "$linux_vt_console" ]; then
    setfont -C "$linux_vt_console" "$linux_vt_font" >/dev/null 2>&1 || true
  else
    setfont "$linux_vt_font" >/dev/null 2>&1 || true
  fi
fi

if command -v setvtrgb >/dev/null 2>&1 && [ -r "$linux_vt_palette" ]; then
  if [ -n "$linux_vt_console" ]; then
    setvtrgb -C "$linux_vt_console" "$linux_vt_palette" >/dev/null 2>&1 || true
  else
    setvtrgb "$linux_vt_palette" >/dev/null 2>&1 || true
  fi
fi

# Linux console simulates underline and dim by rendering text in configured
# palette slots rather than drawing underline or lower-intensity glyphs.
# The cursor sequence uses the Linux software cursor: 17 hides the hardware
# cursor and enables a steady software block; 32 sets normal green background.
if [ -n "$linux_vt_console" ]; then
  printf '\033[1;%s]\033[2;%s]\033[?%sc' \
    "$linux_vt_underline_color" \
    "$linux_vt_dim_color" \
    "$linux_vt_cursor" \
    > "$linux_vt_console" 2>/dev/null || true
elif [ -t 1 ]; then
  printf '\033[1;%s]\033[2;%s]\033[?%sc' \
    "$linux_vt_underline_color" \
    "$linux_vt_dim_color" \
    "$linux_vt_cursor" \
    2>/dev/null || true
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
