#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/linux-vt-test.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT HUP INT TERM

home=$tmp_dir/home
bin=$tmp_dir/bin
payload=$tmp_dir/etc/linux-vt
unit=$tmp_dir/etc/systemd/system/linux-vt-setup.service
font_dir=$home/custom-consolefonts
mkdir -p "$font_dir" "$bin" "$(dirname -- "$unit")"

cat > "$bin/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -u ]; then
  [ "${FAKE_ROOT:-0}" -eq 1 ] && printf '0\n' || printf '1000\n'
fi
EOF
cat > "$bin/sudo" <<'EOF'
#!/bin/sh
exec env FAKE_ROOT=1 "$@"
EOF
cat > "$bin/setfont" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$bin/systemctl" <<'EOF'
#!/bin/sh
if [ "${SYSTEMCTL_FAIL:-0}" -eq 1 ] && [ "${1:-}" = daemon-reload ]; then
  exit 1
fi
case "${1:-}" in
  is-enabled) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$bin/id" "$bin/sudo" "$bin/setfont" "$bin/systemctl"

font_one=$font_dir/font-one.psf.gz
font_one_content=$tmp_dir/font-one.psf
font_two=$font_dir/font-two.psf
printf 'first selected font\n' > "$font_one_content"
gzip -c "$font_one_content" > "$font_one"
printf 'temporary font\n' > "$font_two"

PATH="$bin:$PATH" \
HOME="$home" \
LINUX_VT_HOME="$home" \
LINUX_VT_LOCAL_FONT_DIR="$font_dir" \
LINUX_VT_PAYLOAD_DIR="$payload" \
LINUX_VT_SYSTEMD_UNIT="$unit" \
  "$repo_dir/linux-vt-font-select.sh" --once "$font_one"

selected=$home/.local/share/consolefonts/linux-vt-selected-font
installed=$payload/linux-vt-selected-font
cmp "$font_one_content" "$selected"
cmp "$font_one_content" "$installed"
grep -F "Environment=LINUX_VT_FONT=$installed" "$unit" >/dev/null

PATH="$bin:$PATH" \
HOME="$home" \
LINUX_VT_HOME="$home" \
LINUX_VT_LOCAL_FONT_DIR="$font_dir" \
LINUX_VT_PAYLOAD_DIR="$payload" \
LINUX_VT_SYSTEMD_UNIT="$unit" \
  "$repo_dir/linux-vt-font-select.sh" --apply-only --once "$font_two"

cmp "$font_one_content" "$selected"
cmp "$font_one_content" "$installed"

legacy_home=$tmp_dir/legacy-home
legacy_payload=$tmp_dir/legacy-etc/linux-vt
legacy_unit=$tmp_dir/legacy-etc/systemd/system/linux-vt-setup.service
mkdir -p "$legacy_home/.local/share/consolefonts" "$(dirname -- "$legacy_unit")"
gzip -c "$font_one_content" > "$legacy_home/.local/share/consolefonts/Ttyp0-18b-437.psf.gz"

PATH="$bin:$PATH" \
FAKE_ROOT=1 \
LINUX_VT_HOME="$legacy_home" \
LINUX_VT_PAYLOAD_DIR="$legacy_payload" \
LINUX_VT_SYSTEMD_UNIT="$legacy_unit" \
  "$repo_dir/linux-vt-install.sh" --systemd-only

cmp "$font_one_content" "$legacy_payload/linux-vt-selected-font"
grep -F "Environment=LINUX_VT_FONT=$legacy_payload/linux-vt-selected-font" "$legacy_unit" >/dev/null

failure_payload=$tmp_dir/failure-etc/linux-vt
failure_unit=$tmp_dir/failure-etc/systemd/system/linux-vt-setup.service
mkdir -p "$(dirname -- "$failure_unit")"
if PATH="$bin:$PATH" \
  FAKE_ROOT=1 \
  SYSTEMCTL_FAIL=1 \
  LINUX_VT_HOME="$home" \
  LINUX_VT_PAYLOAD_DIR="$failure_payload" \
  LINUX_VT_SYSTEMD_UNIT="$failure_unit" \
    "$repo_dir/linux-vt-install.sh" --systemd-only; then
  printf 'installer ignored systemctl failure\n' >&2
  exit 1
fi

selector_failure_payload=$tmp_dir/selector-failure-etc/linux-vt
selector_failure_unit=$tmp_dir/selector-failure-etc/systemd/system/linux-vt-setup.service
mkdir -p "$(dirname -- "$selector_failure_unit")"
if PATH="$bin:$PATH" \
  HOME="$home" \
  SYSTEMCTL_FAIL=1 \
  LINUX_VT_LOCAL_FONT_DIR="$font_dir" \
  LINUX_VT_PAYLOAD_DIR="$selector_failure_payload" \
  LINUX_VT_SYSTEMD_UNIT="$selector_failure_unit" \
    "$repo_dir/linux-vt-font-select.sh" --once "$font_two"; then
  printf 'selector ignored boot installation failure\n' >&2
  exit 1
fi

cat > "$bin/setfont" <<'EOF'
#!/bin/sh
exit 1
EOF
console=$tmp_dir/tty1
setup_err=$tmp_dir/setup.err
: > "$console"
if PATH="$bin:$PATH" \
  LINUX_VT_FONT="$font_one_content" \
    "$repo_dir/linux-vt-setup.sh" --console "$console" 2> "$setup_err"; then
  printf 'boot setup ignored setfont failure\n' >&2
  exit 1
fi
grep -F "failed to load Linux VT font: $font_one_content" "$setup_err" >/dev/null

printf 'Linux VT persistence tests passed\n'
