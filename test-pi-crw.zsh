#!/usr/bin/env zsh

source "${0:A:h}/.aliases.sh" >/dev/null 2>&1
set -eu
unset CRW_API_URL CRW_API_KEY PI_CRW_DISABLED

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work"
export PATH="$work/bin:$PATH"
local_stack="$HOME/Library/Application Support/crw/stack"
mkdir -p "$work/bin" "$local_stack"
printf 'CRW_API_KEY=mac-test-key\n' >"$local_stack/.env"
chmod 600 "$local_stack/.env"

cat >"$work/bin/pi" <<'MOCK'
#!/bin/sh
printf '%s %s\n' "${CRW_API_URL:-none}" "${CRW_API_KEY:-none}"
MOCK
chmod +x "$work/bin/pi"

curl() {
	case "$*" in
		*slu-nas-eos:3000/health*) [[ "${nas_health:-up}" == up ]] ;;
		*127.0.0.1:3210/health*) [[ "${mac_health:-up}" == up ]] ;;
		*) return 1 ;;
	esac
}
ssh() {
	printf 'ssh\n' >>"$work/ssh.log"
	[[ "${nas_key:-up}" == up ]] && printf 'nas-test-key\n'
}

check() {
	local expected="$1" actual
	actual=$(pi)
	if [[ "$actual" != "$expected" ]]; then
		printf 'Expected %s, got %s\n' "$expected" "$actual" >&2
		return 1
	fi
}

check 'http://slu-nas-eos:3000 nas-test-key'
nas_key=down check 'http://127.0.0.1:3210 mac-test-key'
: >"$work/ssh.log"
nas_health=down check 'http://127.0.0.1:3210 mac-test-key'
nas_health=down mac_health=down check 'none none' 2>/dev/null
CRW_API_URL=http://override.example CRW_API_KEY=custom-key check 'http://override.example custom-key'
PI_CRW_DISABLED=1 check 'none none'
[[ ! -s "$work/ssh.log" ]]
CRW_API_URL=http://override.example check 'http://override.example nas-test-key'
