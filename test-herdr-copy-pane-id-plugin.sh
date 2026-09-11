#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin_dir="$root/herdr-plugins/copy-pane-id"
script="$plugin_dir/copy-pane-id.sh"
windows_script="$plugin_dir/copy-pane-id.ps1"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$plugin_dir/herdr-plugin.toml" ]] || fail 'plugin manifest is missing'
[[ -x "$script" ]] || fail 'copy-pane-id.sh is missing or not executable'
[[ -f "$windows_script" ]] || fail 'copy-pane-id.ps1 is missing'

# The pane entrypoint must emit only an OSC 52 clipboard assignment for its payload.
HERDR_PLUGIN_ENTRYPOINT_ID=osc52 COPY_TEXT='w7:p4' "$script" >"$tmp/osc52"
printf '\033]52;c;dzc6cDQ=\007' >"$tmp/expected-osc52"
cmp -s "$tmp/expected-osc52" "$tmp/osc52" || fail 'OSC 52 output differs from expected bytes'

tricky_text=$'x;$(not-a-command)\033\007'
tricky_payload=$(printf '%s' "$tricky_text" | base64 | tr -d '\r\n')
HERDR_PLUGIN_ENTRYPOINT_ID=osc52 COPY_TEXT="$tricky_text" "$script" >"$tmp/tricky-osc52"
printf '\033]52;c;%s\007' "$tricky_payload" >"$tmp/expected-tricky-osc52"
cmp -s "$tmp/expected-tricky-osc52" "$tmp/tricky-osc52" || fail 'control-like payload was not safely encoded'

# The menu action must open an unfocused, short-lived background tab. Its pane
# output reaches Herdr's client-side clipboard forwarding without taking over or
# injecting input into the clicked pane.
cat >"$tmp/herdr" <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" >"$HERDR_TEST_ARGS"
MOCK
chmod +x "$tmp/herdr"

HERDR_TEST_ARGS="$tmp/args" \
HERDR_BIN_PATH="$tmp/herdr" \
HERDR_PLUGIN_ID='local.copy-pane-id' \
HERDR_PANE_ID='w7:p4' \
HERDR_WORKSPACE_ID='w7' \
  "$script"

cat >"$tmp/expected-args" <<'ARGS'
plugin
pane
open
--plugin
local.copy-pane-id
--entrypoint
osc52
--placement
tab
--workspace
w7
--env
COPY_TEXT=w7:p4
--no-focus
ARGS
cmp -s "$tmp/expected-args" "$tmp/args" || fail 'plugin pane invocation arguments differ'

# Exercise the Windows implementation when PowerShell is available (for example,
# on Windows CI or a developer machine with PowerShell Core installed).
powershell=''
if command -v pwsh >/dev/null 2>&1; then
  powershell=$(command -v pwsh)
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell=$(command -v powershell.exe)
fi

if [[ -n "$powershell" ]]; then
  HERDR_PLUGIN_ENTRYPOINT_ID=osc52-windows COPY_TEXT='w7:p4' \
    "$powershell" -NoLogo -NoProfile -File "$windows_script" >"$tmp/windows-osc52"
  cmp -s "$tmp/expected-osc52" "$tmp/windows-osc52" || fail 'Windows OSC 52 output differs from expected bytes'

  cat >"$tmp/herdr.ps1" <<'POWERSHELL_MOCK'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
[IO.File]::WriteAllLines($env:HERDR_TEST_ARGS, $Rest)
POWERSHELL_MOCK
  HERDR_TEST_ARGS="$tmp/windows-args" \
  HERDR_BIN_PATH="$tmp/herdr.ps1" \
  HERDR_PLUGIN_ID='local.copy-pane-id' \
  HERDR_PANE_ID='w7:p4' \
  HERDR_WORKSPACE_ID='w7' \
    "$powershell" -NoLogo -NoProfile -File "$windows_script"
  sed 's/osc52-windows/osc52/' "$tmp/windows-args" >"$tmp/windows-args-normalized"
  cmp -s "$tmp/expected-args" "$tmp/windows-args-normalized" || fail 'Windows plugin pane invocation arguments differ'
fi

printf 'PASS: Herdr copy-pane-id plugin\n'
