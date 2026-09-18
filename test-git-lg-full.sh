#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/git-lg-full-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

cd "$tmp_dir"
git init -q
git config user.name "Test User"
git config user.email "test@example.com"

printf 'a1\n' >tracked-a.txt
git add tracked-a.txt
git commit -q -m "add tracked a"

printf 'b1\n' >tracked-b.txt
git add tracked-b.txt
git commit -q -m "add tracked b"

printf 'a2\n' >>tracked-a.txt
git add tracked-a.txt
git commit -q -m "change tracked a"

assert_path_filter() {
  local label="$1"
  shift
  local output
  output="$(GIT_STAT_WIDTH=120 git \
    -c "alias.lgfs=!$script_dir/git-lg-full.sh --stat" \
    lgfs --all "$@")"

  if [[ "$output" != *"add tracked a"* || "$output" != *"change tracked a"* ]]; then
    printf 'FAIL: %s omitted matching commits\n' "$label" >&2
    exit 1
  fi
  if [[ "$output" == *"add tracked b"* || "$output" == *"tracked-b.txt"* ]]; then
    printf 'FAIL: %s included history outside the path filter\n' "$label" >&2
    exit 1
  fi
  if [[ "$output" != *"tracked-a.txt"* ]]; then
    printf 'FAIL: %s did not preserve --stat output\n' "$label" >&2
    exit 1
  fi
}

assert_path_filter "implicit path" tracked-a.txt
assert_path_filter "explicit -- path" -- tracked-a.txt

printf 'git-lg-full tests passed\n'
