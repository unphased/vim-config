#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/git-cli-helpers-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

source "$script_dir/.aliases.sh" >/dev/null 2>&1

cd "$tmp_dir"
git init -q -b main
git config user.name "Test User"
git config user.email "test@example.com"
git config alias.lgtn "!$script_dir/git-lg-tags-notes.sh"
git config alias.ignored '!git ls-files -v | grep "^S"'
git config alias.diff-with-ignored "$(git config --file "$script_dir/.gitconfig" --get alias.diff-with-ignored)"

mkdir nested
printf 'base\n' >nested/tracked.txt
git add nested/tracked.txt
git commit -q -m "shared base"

git checkout -qb feature/topic
printf 'feature\n' >feature.txt
git add feature.txt
git commit -q -m "feature branch only"

git checkout -q main
printf 'main\n' >main.txt
git add main.txt
git commit -q -m "main branch only"

ref_output="$(gg feature/topic 2>/dev/null)"
if [[ "$ref_output" != *"feature branch only"* ]]; then
  print -u2 'FAIL: gg did not traverse a slash-containing ref'
  exit 1
fi
if [[ "$ref_output" == *"main branch only"* ]]; then
  print -u2 'FAIL: an explicit gg ref did not replace the default --all traversal'
  exit 1
fi

path_output="$(gg nested/tracked.txt 2>/dev/null)"
if [[ "$path_output" != *"shared base"* || "$path_output" == *"branch only"* ]]; then
  print -u2 'FAIL: gg no longer recognizes an existing nested path'
  exit 1
fi

printf 'staged\n' >staged.txt
git add staged.txt
diff_output="$(git diff-with-ignored --cached --name-only)"
if [[ "$diff_output" != *"staged.txt"* ]]; then
  print -u2 'FAIL: diff-with-ignored did not forward diff arguments'
  exit 1
fi

print 'git CLI helper tests passed'
