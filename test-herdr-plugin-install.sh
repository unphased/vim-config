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
  printf 'plugin link %s\n' "$root/herdr-plugins/agent-history"
  printf 'plugin link %s\n' "$root/herdr-plugins/copy-pane-id"
  printf 'plugin link %s\n' "$root/herdr-plugins/move-pane-new-tab"
  printf 'plugin link %s\n' "$root/herdr-plugins/pane-load"
  printf 'plugin link %s\n' "$root/herdr-plugins/pane-navigator"
  printf 'plugin link %s\n' "$root/herdr-plugins/reveal-location"
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

python3 - "$root/herdr.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], 'rb') as config_file:
    commands = tomllib.load(config_file)['keys']['command']
missing = [command['key'] for command in commands if not command.get('description', '').strip()]
assert not missing, f'Custom bindings need helper descriptions: {missing}'
copy = [command for command in commands if command['command'] == 'local.copy-pane-id.copy-pane-id']
assert len(copy) == 1, 'Copy pane ID needs exactly one binding'
assert copy[0]['key'] == 'prefix+y' and copy[0]['type'] == 'plugin_action'
assert copy[0]['description'] == 'Copy pane ID'
history = [command for command in commands if command['command'] == 'local.agent-history.open']
assert len(history) == 1, 'Open agent history beside needs exactly one binding'
assert history[0]['key'] == 'prefix+a' and history[0]['type'] == 'plugin_action'
assert history[0]['description'] == 'Open agent history beside'
PY

printf 'PASS: tracked Herdr plugin registration and described custom bindings\n'
