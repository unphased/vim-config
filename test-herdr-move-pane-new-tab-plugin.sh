#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin_dir="$root/herdr-plugins/move-pane-new-tab"
script="$plugin_dir/move-pane-new-tab.sh"
wrapper="$plugin_dir/move-pane-new-tab.cmd"
windows_script="$plugin_dir/move-pane-new-tab.ps1"
manifest="$plugin_dir/herdr-plugin.toml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$manifest" ]] || fail 'move pane manifest is missing'
[[ -x "$script" ]] || fail 'move-pane-new-tab.sh is missing or not executable'
[[ -x "$wrapper" ]] || fail 'move-pane-new-tab.cmd is missing or not executable'
[[ -f "$windows_script" ]] || fail 'move-pane-new-tab.ps1 is missing'
grep -Fq 'id = "move-pane-new-tab"' "$manifest" || fail 'separate pane action is missing from the manifest'
grep -Fq 'title = "Separate pane"' "$manifest" || fail 'separate pane action title is missing from the manifest'
grep -Fq 'contexts = ["pane"]' "$manifest" || fail 'pane context is missing from the manifest'
grep -Fq 'platforms = ["linux", "macos", "windows"]' "$manifest" || fail 'separate pane action platform coverage is missing from the manifest'
grep -Fq 'command = ["./move-pane-new-tab.cmd"]' "$manifest" || fail 'cross-platform command is missing from the manifest'
grep -Fq 'key = "prefix+space"' "$root/herdr.toml" || fail 'separate pane keybinding is missing'
grep -Fq 'type = "plugin_action"' "$root/herdr.toml" || fail 'separate pane plugin-action binding is missing'
grep -Fq 'command = "local.move-pane-new-tab.move-pane-new-tab"' "$root/herdr.toml" || fail 'separate pane action is not bound'

cat >"$tmp/herdr" <<'MOCK'
#!/bin/sh
set -eu
if [ "${1:-} ${2:-}" = "tab list" ]; then
  printf '%s\n' "$HERDR_TAB_LIST_JSON"
else
  printf '%s\n' "$@" >"$HERDR_TEST_ARGS"
fi
MOCK
chmod +x "$tmp/herdr"

run_case() {
  local pane_count=$1
  local expected=$2
  HERDR_TEST_ARGS="$tmp/args" \
  HERDR_BIN_PATH="$tmp/herdr" \
  HERDR_PANE_ID='w7:p4' \
  HERDR_TAB_ID='w7:t1' \
  HERDR_WORKSPACE_ID='w7' \
  HERDR_TAB_LIST_JSON=$(printf '{"result":{"tabs":[{"tab_id":"w7:t1","pane_count":%s}]}}' "$pane_count") \
    "$wrapper"
  cmp -s "$expected" "$tmp/args" || fail "move pane arguments differ for pane count $pane_count"
}

cat >"$tmp/expected-new-tab-args" <<'ARGS'
pane
move
w7:p4
--new-tab
--workspace
w7
--focus
ARGS
cat >"$tmp/expected-new-workspace-args" <<'ARGS'
pane
move
w7:p4
--new-workspace
--focus
ARGS

run_case 2 "$tmp/expected-new-tab-args"
run_case 1 "$tmp/expected-new-workspace-args"

powershell=''
if command -v pwsh >/dev/null 2>&1; then
  powershell=$(command -v pwsh)
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell=$(command -v powershell.exe)
fi

if [[ -n "$powershell" ]]; then
  cat >"$tmp/herdr.ps1" <<'POWERSHELL_MOCK'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
if ($Rest.Count -ge 2 -and $Rest[0] -eq "tab" -and $Rest[1] -eq "list") {
    Write-Output $env:HERDR_TAB_LIST_JSON
} else {
    [IO.File]::WriteAllLines($env:HERDR_TEST_ARGS, $Rest)
}
POWERSHELL_MOCK

  for pane_count in 2 1; do
    if [[ "$pane_count" -eq 2 ]]; then
      expected="$tmp/expected-new-tab-args"
    else
      expected="$tmp/expected-new-workspace-args"
    fi
    HERDR_TEST_ARGS="$tmp/windows-args" \
    HERDR_BIN_PATH="$tmp/herdr.ps1" \
    HERDR_PANE_ID='w7:p4' \
    HERDR_TAB_ID='w7:t1' \
    HERDR_WORKSPACE_ID='w7' \
    HERDR_TAB_LIST_JSON=$(printf '{"result":{"tabs":[{"tab_id":"w7:t1","pane_count":%s}]}}' "$pane_count") \
      "$powershell" -NoLogo -NoProfile -File "$windows_script"
    cmp -s "$expected" "$tmp/windows-args" || fail "Windows move pane arguments differ for pane count $pane_count"
  done
fi

printf 'PASS: Herdr separate-pane plugin\n'
