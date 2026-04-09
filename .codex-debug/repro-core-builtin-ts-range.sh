#!/bin/zsh
set -u

repo_root="/Users/slu/.vim"
nvim_bin="${NVIM_BIN:-/opt/homebrew/bin/nvim}"
state_root="${repo_root}/.codex-debug/state"
cache_root="${repo_root}/.codex-debug/cache"
tmp_root="${repo_root}/.codex-debug/tmp"
init_file="${repo_root}/.codex-debug/minimal-core-ts-range-parse.lua"
fixture="${1:-simple}"

mkdir -p "${state_root}" "${cache_root}" "${tmp_root}"
export XDG_STATE_HOME="${state_root}"
export XDG_CACHE_HOME="${cache_root}"
export TMPDIR="${tmp_root}"

tmp_target=""
cleanup() {
  if [[ -n "${tmp_target}" && -f "${tmp_target}" ]]; then
    rm -f "${tmp_target}"
  fi
}
trap cleanup EXIT

make_md_tmp() {
  local base
  base="$(mktemp "${TMPDIR:-/tmp}/codex-md.XXXXXX")"
  mv "${base}" "${base}.md"
  printf '%s.md' "${base}"
}

make_lua_tmp() {
  local base
  base="$(mktemp "${TMPDIR:-/tmp}/codex-lua.XXXXXX")"
  mv "${base}" "${base}.lua"
  printf '%s.lua' "${base}"
}

case "${fixture}" in
  simple)
    tmp_target="$(make_md_tmp)"
    cat > "${tmp_target}" <<'EOF'
# hi

text
EOF
    export CODEX_TS_LANG=markdown
    ;;
  bash-fence)
    tmp_target="$(make_md_tmp)"
    cat > "${tmp_target}" <<'EOF'
# hi

```bash
echo test
```
EOF
    export CODEX_TS_LANG=markdown
    ;;
  lua-simple)
    tmp_target="$(make_lua_tmp)"
    cat > "${tmp_target}" <<'EOF'
local x = 1
return x
EOF
    export CODEX_TS_LANG=lua
    ;;
  *)
    echo "usage: $0 [simple|bash-fence|lua-simple]"
    exit 2
    ;;
esac

export CODEX_TS_PARSE_MODE="${CODEX_TS_PARSE_MODE:-range}"

start=$(python3 - <<'PY'
import time
print(time.time())
PY
)

"${nvim_bin}" --headless -n -i NONE -u "${init_file}" --noplugin "${tmp_target}" +qall!
rc=$?

end=$(python3 - <<'PY'
import time
print(time.time())
PY
)

elapsed=$(python3 - <<PY
start = float(${start})
end = float(${end})
print(round(end - start, 3))
PY
)

printf 'fixture=%s lang=%s mode=%s rc=%s elapsed=%ss\n' "${fixture}" "${CODEX_TS_LANG}" "${CODEX_TS_PARSE_MODE}" "${rc}" "${elapsed}"
