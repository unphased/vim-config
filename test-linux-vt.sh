#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/linux-vt-test.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT HUP INT TERM

home=$tmp_dir/home
bin=$tmp_dir/bin
payload=$tmp_dir/etc/linux-vt
unit=$tmp_dir/etc/systemd/system/linux-vt-setup.service
font_dir=$home/.local/share/consolefonts
mkdir -p "$font_dir" "$bin" "$(dirname -- "$unit")"

cat > "$bin/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = -u ] && printf '0\n'
EOF
cat > "$bin/setfont" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$bin/systemctl" <<'EOF'
#!/bin/sh
case "${1:-}" in
  is-enabled) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$bin/id" "$bin/setfont" "$bin/systemctl"

font_one=$font_dir/font-one.psf
font_two=$font_dir/font-two.psf
printf 'first selected font\n' > "$font_one"
printf 'temporary font\n' > "$font_two"

PATH="$bin:$PATH" \
HOME="$home" \
LINUX_VT_HOME="$home" \
LINUX_VT_PAYLOAD_DIR="$payload" \
LINUX_VT_SYSTEMD_UNIT="$unit" \
  "$repo_dir/linux-vt-font-select.sh" --once "$font_one"

selected=$home/.local/share/consolefonts/linux-vt-selected-font
installed=$payload/linux-vt-selected-font
cmp "$font_one" "$selected"
cmp "$font_one" "$installed"
grep -F "Environment=LINUX_VT_FONT=$installed" "$unit" >/dev/null

PATH="$bin:$PATH" \
HOME="$home" \
LINUX_VT_HOME="$home" \
LINUX_VT_PAYLOAD_DIR="$payload" \
LINUX_VT_SYSTEMD_UNIT="$unit" \
  "$repo_dir/linux-vt-font-select.sh" --apply-only --once "$font_two"

cmp "$font_one" "$selected"
cmp "$font_one" "$installed"

printf 'Linux VT persistence tests passed\n'
