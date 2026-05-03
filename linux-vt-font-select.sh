#!/bin/sh
set -u

local_font_dir=${LINUX_VT_LOCAL_FONT_DIR:-"$HOME/.local/share/consolefonts"}
console=
list_only=0
once=0

usage() {
  cat <<'EOF'
usage: linux-vt-font-select.sh [--console /dev/ttyN] [--list] [--once] [--reset] [FONT]

Interactively select a Linux virtual terminal font from system console font
directories and ~/.local/share/consolefonts, then apply it with setfont.

Options:
  --console DEV  Apply to a specific console, e.g. /dev/tty2.
  --list         List discovered fonts and exit.
  --once         Exit immediately after applying one selected font.
  --reset        Reset console font with setfont -R and exit.
  FONT           Apply a font by path or by discovered basename.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

quote_words() {
  for word do
    quoted=$(printf '%s\n' "$word" | sed "s/'/'\\\\''/g")
    printf " '%s'" "$quoted"
  done
}

show_command() {
  printf '+ %s' "$1" >&2
  shift
  quote_words "$@" >&2
  printf '\n' >&2
}

run_setfont() {
  if [ -n "$console" ]; then
    show_command setfont -C "$console" "$@"
    setfont -C "$console" "$@"
    return $?
  fi

  err_file=$(mktemp "${TMPDIR:-/tmp}/linux-vt-setfont.XXXXXX") || exit 1
  show_command setfont "$@"
  setfont "$@" 2>"$err_file"
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -f -- "$err_file"
    return 0
  fi

  err_text=$(cat "$err_file")
  rm -f -- "$err_file"

  printf '%s\n' "$err_text" >&2

  if command -v sudo >/dev/null 2>&1; then
    show_command sudo setfont "$@"
    sudo setfont "$@"
    return $?
  fi

  return "$status"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --console|-C)
      shift
      [ "$#" -gt 0 ] || die 'missing argument for --console'
      console=$1
      ;;
    --list|-l)
      list_only=1
      ;;
    --once)
      once=1
      ;;
    --reset)
      run_setfont -R
      exit $?
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
  shift
done

command -v setfont >/dev/null 2>&1 || die 'setfont not found'

font_info() {
  font=$1
  case "$font" in
    *.gz)
      gzip -cd -- "$font" 2>/dev/null | file - 2>/dev/null | sed 's#^[^:]*: ##'
      ;;
    *)
      file -- "$font" 2>/dev/null | sed 's#^[^:]*: ##'
      ;;
  esac
}

print_font_entry() {
  source=$1
  font=$2
  name=$(basename -- "$font")
  info=$(font_info "$font")
  [ -n "$info" ] || info='unknown font data'

  glyph_count=$(printf '%s\n' "$info" | sed -n 's/.* \([0-9][0-9]*\) characters.*/\1/p')
  case "$glyph_count" in
    ''|*[!0-9]*)
      ;;
    *)
      # The Linux console rejects PSF fonts beyond its 512-glyph slot limit.
      [ "$glyph_count" -le 512 ] || return 0
      ;;
  esac

  printf '%s/%s  --  %s\t%s\n' "$source" "$name" "$info" "$font"
}

build_font_list() {
  {
    if [ -d "$local_font_dir" ]; then
      find "$local_font_dir" -maxdepth 1 -type f \
        \( -name '*.psf' -o -name '*.psfu' -o -name '*.fnt' \
        -o -name '*.psf.gz' -o -name '*.psfu.gz' -o -name '*.fnt.gz' \) \
        -print 2>/dev/null | while IFS= read -r font; do
          print_font_entry local "$font"
        done
    fi

    for dir in /usr/share/kbd/consolefonts /usr/share/consolefonts; do
      [ -d "$dir" ] || continue
      find "$dir" -maxdepth 1 -type f \
        \( -name '*.psf' -o -name '*.psfu' -o -name '*.fnt' \
        -o -name '*.psf.gz' -o -name '*.psfu.gz' -o -name '*.fnt.gz' \) \
        -print 2>/dev/null | while IFS= read -r font; do
          print_font_entry system "$font"
        done
    done
  } | sort -f
}

apply_font() {
  font=$1
  run_setfont "$font"
}

find_font_by_name() {
  wanted=$1
  font_list=$2

  awk -F '\t' -v wanted="$wanted" '
    {
      path = $2
      name = path
      sub(/^.*\//, "", name)
      short = name
      sub(/\.(psf|psfu|fnt)(\.gz)?$/, "", short)
      if (found == "" && (path == wanted || name == wanted || short == wanted)) {
        found = path
      }
    }
    END {
      if (found != "") {
        print found
      }
    }
  ' "$font_list"
}

choose_font() {
  list_file=$1
  start_pos=${2:-1}

  case "$start_pos" in
    ''|0|*[!0-9]*)
      start_pos=1
      ;;
  esac

  if command -v fzf >/dev/null 2>&1; then
    choice=$(awk -F '\t' '{ printf "%d\t%s\n", NR, $1 }' "$list_file" |
      fzf --prompt='VT font> ' --height=80% --reverse \
        --delimiter='\t' --with-nth=2.. --bind="load:pos($start_pos)") || {
      return 1
    }
    position=$(printf '%s\n' "$choice" | awk -F '\t' '{ print $1 }')
    font=$(sed -n "${position}p" "$list_file" | awk -F '\t' '{ print $2 }')
  else
    nl -w2 -s'. ' "$list_file" | sed 's/\t.*$//' >&2
    printf 'Font number: ' >&2
    IFS= read -r number || {
      return 1
    }
    case "$number" in
      ''|*[!0-9]*)
        return 1
        ;;
    esac
    position=$number
    font=$(sed -n "${position}p" "$list_file" | awk -F '\t' '{ print $2 }')
  fi

  [ -n "$font" ] || return 1
  printf '%s\t%s\n' "$position" "$font"
}

font_list=$(mktemp "${TMPDIR:-/tmp}/linux-vt-fonts.XXXXXX") || exit 1
trap 'rm -f -- "$font_list"' EXIT HUP INT TERM

build_font_list > "$font_list"

if [ ! -s "$font_list" ]; then
  die 'no console fonts found'
fi

if [ "$list_only" -eq 1 ]; then
  sed 's/\t/ -> /' "$font_list"
  exit 0
fi

if [ "$#" -gt 0 ]; then
  if [ -r "$1" ]; then
    apply_font "$1"
    exit $?
  fi

  resolved=$(find_font_by_name "$1" "$font_list")
  [ -n "$resolved" ] || die "font not found: $1"
  apply_font "$resolved"
  exit $?
fi

font_position=1

while :; do
  selection=$(choose_font "$font_list" "$font_position") || exit 0
  font_position=$(printf '%s\n' "$selection" | awk -F '\t' '{ print $1 }')
  selected=$(printf '%s\n' "$selection" | awk -F '\t' '{ print $2 }')
  if apply_font "$selected"; then
    printf 'Applied: %s\n' "$selected"
  else
    printf 'Failed: %s\n' "$selected" >&2
  fi

  [ "$once" -eq 1 ] && exit 0
done
