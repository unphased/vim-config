#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
herdr=${HERDR:-herdr}

while IFS= read -r -d '' manifest; do
  if [[ ! -f "$root/$manifest" ]]; then
    printf 'tracked Herdr plugin manifest is missing: %s\n' "$root/$manifest" >&2
    exit 1
  fi
  "$herdr" plugin link "$root/${manifest%/*}"
done < <(git -C "$root" ls-files -z -- 'herdr-plugins/*/herdr-plugin.toml')
