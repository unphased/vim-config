#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
untracked="$root/herdr-plugins/untracked-test-$$"
cleanup() { rm -rf "$tmp" "$untracked"; }
trap cleanup EXIT

mkdir -p "$untracked"
printf 'id = "untracked"\n' >"$untracked/herdr-plugin.toml"

cat >"$tmp/herdr" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >>"$HERDR_TEST_LOG"
MOCK
chmod +x "$tmp/herdr"

HERDR="$tmp/herdr" HERDR_TEST_LOG="$tmp/calls" "$root/herdr-plugins/install.sh"
{
  printf 'plugin link %s\n' "$root/herdr-plugins/copy-pane-id"
  printf 'plugin link %s\n' "$root/herdr-plugins/move-pane-new-tab"
} >"$tmp/expected"
cmp -s "$tmp/expected" "$tmp/calls" || {
  printf 'unexpected Herdr registration calls:\n' >&2
  cat "$tmp/calls" >&2
  exit 1
}

: >"$tmp/calls"
HERDR_TEST_LOG="$tmp/calls" make -s -C "$root" \
  HERDR="$tmp/herdr" HERDR_CONFIG_DIR="$tmp/config" bootstrap-herdr
[[ -L "$tmp/config/config.toml" ]] || {
  echo 'bootstrap did not create the Herdr config symlink' >&2
  exit 1
}
[[ "$(readlink "$tmp/config/config.toml")" == "$root/herdr.toml" ]] || {
  echo 'bootstrap created the wrong Herdr config symlink' >&2
  exit 1
}
cmp -s "$tmp/expected" "$tmp/calls" || {
  echo 'bootstrap did not register the tracked plugins' >&2
  exit 1
}

mkdir -p "$tmp/existing"
printf 'keep me\n' >"$tmp/existing/config.toml"
make -s -C "$root" HERDR_CONFIG_DIR="$tmp/existing" install-herdr-config >/dev/null
grep -Fxq 'keep me' "$tmp/existing/config.toml" || {
  echo 'bootstrap replaced an existing Herdr config' >&2
  exit 1
}

printf 'PASS: tracked Herdr plugin registration\n'
