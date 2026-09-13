#!/bin/zsh

setopt NO_UNSET

repo=${0:A:h}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nvim-bgcolor-hook.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
  print -u2 "FAIL: $*"
  exit 1
}

home="$tmp/home"
bin="$tmp/bin"
mkdir -p "$home/util" "$bin" || exit 1

cat >"$home/util/bgcolor.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$BGCOLOR_TEST_ARGS"
if [ "${1:-}" = --format=osc ]; then
  printf '\033]10;#e0e0e0\033\\\033]11;#123456\033\\'
else
  printf '\033]11;#123456\033\\'
fi
EOF
chmod +x "$home/util/bgcolor.sh"

cat >"$bin/nvim" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$NVIM_TEST_ARGS"
EOF
chmod +x "$bin/nvim"

export HOME="$home"
export PATH="$bin:$PATH"
export BGCOLOR_TEST_ARGS="$tmp/bgcolor.args"
export NVIM_TEST_ARGS="$tmp/nvim.args"
source "$repo/nvim/shell/nvim-bgcolor.zsh"

unset NVIM NVIM_TERM_BUF NVIM_BGCOLOR_NO_OSC11
output=$(nvim_bgcolor_hook)
expected=$'\033]10;#e0e0e0\033\\\033]11;#123456\033\\'
[[ "$output" == "$expected" ]] || fail "unexpected terminal output: ${(q)output}"
[[ "$(<"$BGCOLOR_TEST_ARGS")" == "--format=osc $PWD" ]] || \
  fail "resolver was not called with paired OSC format: $(<"$BGCOLOR_TEST_ARGS")"

export NVIM="$tmp/nvim.sock"
export NVIM_TERM_BUF=12
nvim_bgcolor_hook >/dev/null
[[ "$(<"$NVIM_TEST_ARGS")" == *"#123456"* ]] || \
  fail "background was not extracted for Neovim: $(<"$NVIM_TEST_ARGS")"

export NVIM_BGCOLOR_NO_OSC11=1
output=$(nvim_bgcolor_hook)
[[ -z "$output" ]] || fail "terminal color output was not suppressed: ${(q)output}"

print 'ok'
