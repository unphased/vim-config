#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin_dir="$root/herdr-plugins/move-pane-new-tab"
script="$plugin_dir/move-pane-new-tab.sh"
windows_script="$plugin_dir/move-pane-new-tab.ps1"
manifest="$plugin_dir/herdr-plugin.toml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$manifest" ]] || fail 'plugin manifest is missing'
[[ -x "$script" ]] || fail 'move-pane-new-tab.sh is missing or not executable'
[[ -f "$windows_script" ]] || fail 'move-pane-new-tab.ps1 is missing'
grep -Fq 'id = "move-pane-new-tab"' "$manifest" || fail 'move pane action is missing from the manifest'
grep -Fq 'contexts = ["pane"]' "$manifest" || fail 'pane context is missing from the manifest'
grep -Fq 'command = ["sh", "move-pane-new-tab.sh"]' "$manifest" || fail 'shell command is missing from the manifest'
grep -Fq 'command = ["powershell.exe", "-NoLogo", "-NoProfile", "-File", "move-pane-new-tab.ps1"]' "$manifest" || fail 'Windows command is missing from the manifest'

cat >"$tmp/herdr" <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" >"$HERDR_TEST_ARGS"
MOCK
chmod +x "$tmp/herdr"

HERDR_TEST_ARGS="$tmp/args" \
HERDR_BIN_PATH="$tmp/herdr" \
HERDR_PANE_ID='w7:p4' \
HERDR_WORKSPACE_ID='w7' \
  "$script"

cat >"$tmp/expected-args" <<'ARGS'
pane
move
w7:p4
--new-tab
--workspace
w7
--focus
ARGS
cmp -s "$tmp/expected-args" "$tmp/args" || fail 'move pane invocation arguments differ'

powershell=''
if command -v pwsh >/dev/null 2>&1; then
  powershell=$(command -v pwsh)
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell=$(command -v powershell.exe)
fi

if [[ -n "$powershell" ]]; then
  cat >"$tmp/herdr.ps1" <<'POWERSHELL_MOCK'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
[IO.File]::WriteAllLines($env:HERDR_TEST_ARGS, $Rest)
POWERSHELL_MOCK
  HERDR_TEST_ARGS="$tmp/windows-args" \
  HERDR_BIN_PATH="$tmp/herdr.ps1" \
  HERDR_PANE_ID='w7:p4' \
  HERDR_WORKSPACE_ID='w7' \
    "$powershell" -NoLogo -NoProfile -File "$windows_script"
  cmp -s "$tmp/expected-args" "$tmp/windows-args" || fail 'Windows move pane invocation arguments differ'
fi

printf 'PASS: Herdr move-pane-new-tab plugin\n'
