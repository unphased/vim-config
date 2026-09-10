#!/bin/zsh

setopt NO_UNSET

repo=${0:A:h}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/herdr-machine-background.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
  print -u2 "FAIL: $*"
  exit 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "expected output to contain ${(q)2}, got ${(q)1}"
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "expected output not to contain ${(q)2}, got ${(q)1}"
}

assert_equals() {
  [[ "$1" == "$2" ]] || fail "expected ${(q)2}, got ${(q)1}"
}

home="$tmp/home"
bin="$tmp/bin"
mkdir -p "$home/.vim" "$home/util" "$bin" || exit 1

cat >"$bin/herdr" <<'EOF'
#!/bin/sh
printf 'herdr:%s\n' "$*"
printf 'argc:%s\n' "$#"
index=1
for arg do
  printf 'arg%s:<%s>\n' "$index" "$arg"
  index=$((index + 1))
done
if [ -n "${HERDR_TEST_SIGNAL:-}" ]; then
  kill -s "$HERDR_TEST_SIGNAL" "$$"
fi
exit "${HERDR_TEST_STATUS:-0}"
EOF
chmod +x "$bin/herdr"

cat >"$home/.vim/tmux-apply-machine-style.sh" <<'EOF'
#!/bin/sh
[ "${1:-}" = --print-background ] && printf '#2a2926\n'
EOF
chmod +x "$home/.vim/tmux-apply-machine-style.sh"

cat >"$home/util/bgcolor.sh" <<'EOF'
#!/bin/sh
printf 'project:%s\n' "$1"
EOF
chmod +x "$home/util/bgcolor.sh"

output=$(HOME="$home" PATH="$bin:$PATH" HERDR_TEST_STATUS=17 HERDR_HELPER="$repo/zsh/herdr-machine-background.zsh" zsh -f <<'EOF'
source "$HERDR_HELPER"
herdr
printf 'exit:%s\n' "$?"
EOF
) || exit 1
assert_contains "$output" $'\e]11;#2a2926\e\\'
assert_contains "$output" "herdr:"
assert_contains "$output" "project:$PWD"
assert_contains "$output" "exit:17"

run_herdr() {
  HOME="$home" PATH="$bin:$PATH" HERDR_HELPER="$repo/zsh/herdr-machine-background.zsh" \
    zsh -f -c 'source "$HERDR_HELPER"; herdr "$@"' test-herdr "$@"
}

for output in \
  "$(run_herdr --session demo)" \
  "$(run_herdr --session=demo)" \
  "$(run_herdr --remote host)" \
  "$(run_herdr --remote=host)" \
  "$(run_herdr --remote host --session demo --remote-keybindings local --handoff)" \
  "$(run_herdr session attach demo)"
do
  assert_contains "$output" $'\e]11;#2a2926\e\\'
  assert_contains "$output" "project:$PWD"
done

output=$(run_herdr pane run id "two words" "") || exit 1
assert_contains "$output" "argc:5"
assert_contains "$output" "arg4:<two words>"
assert_contains "$output" "arg5:<>"
assert_not_contains "$output" "#2a2926"

for output in \
  "$(run_herdr pane list)" \
  "$(run_herdr --session demo pane list)" \
  "$(run_herdr --remote host pane list)"
do
  assert_contains "$output" "pane list"
  assert_not_contains "$output" "#2a2926"
  assert_not_contains "$output" "project:"
done

output=$(HOME="$home" PATH="$bin:$PATH" HERDR_TEST_SIGNAL=INT HERDR_HELPER="$repo/zsh/herdr-machine-background.zsh" zsh -f <<'EOF'
source "$HERDR_HELPER"
herdr
printf 'exit:%s\n' "$?"
EOF
) || exit 1
assert_contains "$output" "project:$PWD"
assert_contains "$output" "exit:130"

rm "$home/.vim/tmux-apply-machine-style.sh"
output=$(run_herdr --session demo) || exit 1
assert_contains "$output" "herdr:--session demo"
assert_not_contains "$output" "#2a2926"

registry="$tmp/machine-colors.tsv"
machine_id=$(sed -n '1p' /opt/machine-id 2>/dev/null || hostname -s)
printf 'host\tlabel\taccent\taliases\nhost\tmbp\t#8b897e\t%s\n' "$machine_id" >"$registry"
background=$(MACHINE_COLORS_REGISTRY="$registry" TMUX_BIN="$tmp/no-tmux" "$repo/tmux-apply-machine-style.sh" --print-background) || exit 1
[[ "$background" == '#2a2926' ]] || fail "unexpected machine background: $background"

print 'ok'
