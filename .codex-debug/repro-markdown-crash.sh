#!/bin/zsh
set -u

repo_root="/Users/slu/.vim"
nvim_bin="${NVIM_BIN:-/opt/homebrew/bin/nvim}"
prepend_rtp="${CODEX_PREPEND_RTP:-}"
target_file="${2:-README.md}"
mode="${1:-minimal-ts-context}"
variant="${3:-}"
state_root="${repo_root}/.codex-debug/state"
cache_root="${repo_root}/.codex-debug/cache"
tmp_root="${repo_root}/.codex-debug/tmp"

mkdir -p "${state_root}" "${cache_root}" "${tmp_root}"
export XDG_STATE_HOME="${state_root}"
export XDG_CACHE_HOME="${cache_root}"
export TMPDIR="${tmp_root}"
if [[ -n "${variant}" ]]; then
  export CODEX_RM_PARSE_MODE="${variant}"
fi

tmp_init=""
tmp_target=""
cleanup() {
  if [[ -n "${tmp_init}" && -f "${tmp_init}" ]]; then
    rm -f "${tmp_init}"
  fi
  if [[ -n "${tmp_target}" && -f "${tmp_target}" ]]; then
    rm -f "${tmp_target}"
  fi
}
trap cleanup EXIT

make_lua_tmp() {
  local base
  base="$(mktemp "${TMPDIR:-/tmp}/$1.XXXXXX")"
  mv "${base}" "${base}.lua"
  printf '%s.lua' "${base}"
}

make_md_tmp() {
  local base
  base="$(mktemp "${TMPDIR:-/tmp}/$1.XXXXXX")"
  mv "${base}" "${base}.md"
  printf '%s.md' "${base}"
}

run_case() {
  local label="$1"
  shift

  local start end elapsed rc
  start=$(python3 - <<'PY'
import time
print(time.time())
PY
)

  "$@"
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

  printf '%s: rc=%s elapsed=%ss\n' "${label}" "${rc}" "${elapsed}"
}

run_nvim() {
  if [[ -n "${prepend_rtp}" ]]; then
    "${nvim_bin}" --cmd "set rtp^=${prepend_rtp}" "$@"
  else
    "${nvim_bin}" "$@"
  fi
}

resolve_target_file() {
  case "${target_file}" in
    simple)
      tmp_target="$(make_md_tmp codex-simple)"
      cat > "${tmp_target}" <<'EOF'
# hi

text
EOF
      target_file="${tmp_target}"
      ;;
    bash-fence)
      tmp_target="$(make_md_tmp codex-bash)"
      cat > "${tmp_target}" <<'EOF'
# hi

```bash
echo test
```
EOF
      target_file="${tmp_target}"
      ;;
    shell-fence)
      tmp_target="$(make_md_tmp codex-shell)"
      cat > "${tmp_target}" <<'EOF'
# hi

```shell
echo test
```
EOF
      target_file="${tmp_target}"
      ;;
    lua-simple)
      tmp_target="$(mktemp "${TMPDIR:-/tmp}/codex-lua.XXXXXX")"
      mv "${tmp_target}" "${tmp_target}.lua"
      tmp_target="${tmp_target}.lua"
      cat > "${tmp_target}" <<'EOF'
local x = 1
return x
EOF
      target_file="${tmp_target}"
      ;;
    readme)
      target_file="README.md"
      ;;
  esac
}

make_minimal_ts_context_init() {
  tmp_init="$(make_lua_tmp minimal-ts-context)"
  cat > "${tmp_init}" <<'EOF'
local ts_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter")
local ctx_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter-context")

vim.opt.runtimepath:append(ts_path)
vim.opt.runtimepath:append(ctx_path)

require("nvim-treesitter").install({
  "markdown",
  "markdown_inline",
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    pcall(vim.treesitter.start, args.buf, "markdown")
  end,
})

require("treesitter-context").setup()
EOF
}

make_minimal_ts_range_parse_init() {
  tmp_init="$(make_lua_tmp minimal-ts-range-parse)"
  cat > "${tmp_init}" <<'EOF'
local ts_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter")

vim.opt.runtimepath:append(ts_path)

local lang = vim.env.CODEX_TS_LANG or "markdown"
local pattern = lang
local parser_lang = lang

local langs = { lang }
if lang == "markdown" and vim.env.CODEX_TS_NO_INLINE ~= "1" then
  table.insert(langs, "markdown_inline")
end

require("nvim-treesitter").install(langs)

vim.api.nvim_create_autocmd("FileType", {
  pattern = pattern,
  callback = function(args)
    pcall(vim.treesitter.start, args.buf, parser_lang)
    vim.schedule(function()
      local parser = vim.treesitter.get_parser(args.buf)
      local mode = vim.env.CODEX_TS_PARSE_MODE or "range"
      if mode == "full" then
        parser:parse()
      elseif mode == "skip" then
        return
      else
        parser:parse({ 0, 0, 0, 1 }, function(...) end)
      end
    end)
  end,
})
EOF
}

make_minimal_ts_context_no_number_init() {
  tmp_init="$(make_lua_tmp minimal-ts-context-no-number)"
  cat > "${tmp_init}" <<'EOF'
local ts_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter")
local ctx_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter-context")

vim.opt.runtimepath:append(ts_path)
vim.opt.runtimepath:append(ctx_path)

vim.opt.number = false
vim.opt.relativenumber = false

require("nvim-treesitter").install({
  "markdown",
  "markdown_inline",
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    pcall(vim.treesitter.start, args.buf, "markdown")
  end,
})

require("treesitter-context").setup({
  line_numbers = false,
})
EOF
}

make_vendor_ts_context_init() {
  tmp_init="$(make_lua_tmp vendor-ts-context)"
  cat > "${tmp_init}" <<'EOF'
local ts_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter")
local ctx_path = "/Users/slu/.vim/.codex-debug/vendor/nvim-treesitter-context"

vim.opt.runtimepath:append(ts_path)
vim.opt.runtimepath:append(ctx_path)

require("nvim-treesitter").install({
  "markdown",
  "markdown_inline",
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    pcall(vim.treesitter.start, args.buf, "markdown")
  end,
})

require("treesitter-context").setup()
EOF
}

make_minimal_render_markdown_init() {
  tmp_init="$(make_lua_tmp minimal-render-markdown)"
  cat > "${tmp_init}" <<'EOF'
local ts_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter")
local mini_path = vim.fn.expand("~/.local/share/nvim/lazy/mini.nvim")
local rm_path = vim.fn.expand("~/.local/share/nvim/lazy/render-markdown.nvim")

vim.opt.runtimepath:append(ts_path)
vim.opt.runtimepath:append(mini_path)
vim.opt.runtimepath:append(rm_path)

require("nvim-treesitter").install({
  "markdown",
  "markdown_inline",
  "html",
  "yaml",
  "lua",
  "bash",
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    pcall(vim.treesitter.start, args.buf, "markdown")
  end,
})

require("render-markdown").setup({
  code = {
    conceal_delimiters = false,
  },
})

vim.cmd.runtime("plugin/render-markdown.lua")
EOF
}

make_vendor_render_markdown_init() {
  tmp_init="$(make_lua_tmp vendor-render-markdown)"
  cat > "${tmp_init}" <<'EOF'
local ts_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter")
local mini_path = vim.fn.expand("~/.local/share/nvim/lazy/mini.nvim")
local rm_path = "/Users/slu/.vim/.codex-debug/vendor/render-markdown.nvim"

vim.opt.runtimepath:append(ts_path)
vim.opt.runtimepath:append(mini_path)
vim.opt.runtimepath:append(rm_path)

require("nvim-treesitter").install({
  "markdown",
  "markdown_inline",
  "html",
  "yaml",
  "lua",
  "bash",
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    pcall(vim.treesitter.start, args.buf, "markdown")
  end,
})

require("render-markdown").setup({
  code = {
    conceal_delimiters = false,
  },
})

vim.cmd.runtime("plugin/render-markdown.lua")
EOF
}

make_minimal_render_markdown_setup_only_init() {
  tmp_init="$(make_lua_tmp minimal-render-markdown-setup-only)"
  cat > "${tmp_init}" <<'EOF'
local ts_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter")
local mini_path = vim.fn.expand("~/.local/share/nvim/lazy/mini.nvim")
local rm_path = vim.fn.expand("~/.local/share/nvim/lazy/render-markdown.nvim")

vim.opt.runtimepath:append(ts_path)
vim.opt.runtimepath:append(mini_path)
vim.opt.runtimepath:append(rm_path)

require("nvim-treesitter").install({
  "markdown",
  "markdown_inline",
  "html",
  "yaml",
  "lua",
  "bash",
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    pcall(vim.treesitter.start, args.buf, "markdown")
  end,
})

require("render-markdown").setup({
  code = {
    conceal_delimiters = false,
  },
})
EOF
}

make_minimal_render_markdown_no_manager_init() {
  tmp_init="$(make_lua_tmp minimal-render-markdown-no-manager)"
  cat > "${tmp_init}" <<'EOF'
local ts_path = vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter")
local mini_path = vim.fn.expand("~/.local/share/nvim/lazy/mini.nvim")
local rm_path = vim.fn.expand("~/.local/share/nvim/lazy/render-markdown.nvim")

vim.opt.runtimepath:append(ts_path)
vim.opt.runtimepath:append(mini_path)
vim.opt.runtimepath:append(rm_path)

require("nvim-treesitter").install({
  "markdown",
  "markdown_inline",
  "html",
  "yaml",
  "lua",
  "bash",
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    pcall(vim.treesitter.start, args.buf, "markdown")
  end,
})

require("render-markdown").setup({
  code = {
    conceal_delimiters = false,
  },
})
require("render-markdown.core.colors").init()
require("render-markdown.core.command").init()
require("render-markdown.core.log").init()
EOF
}

resolve_target_file

case "${mode}" in
  baseline)
    run_case "baseline" \
      run_nvim --headless -n -i NONE -u NONE --noplugin "${target_file}" +qall!
    ;;
  minimal-ts-context)
    make_minimal_ts_context_init
    run_case "minimal-ts-context" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    ;;
  minimal-ts-range-parse)
    make_minimal_ts_range_parse_init
    run_case "minimal-ts-range-parse" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    ;;
  minimal-ts-context-no-number)
    make_minimal_ts_context_no_number_init
    run_case "minimal-ts-context-no-number" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    ;;
  minimal-render-markdown)
    make_minimal_render_markdown_init
    run_case "minimal-render-markdown" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    ;;
  vendor-render-markdown)
    make_vendor_render_markdown_init
    run_case "vendor-render-markdown" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    ;;
  vendor-ts-context)
    make_vendor_ts_context_init
    run_case "vendor-ts-context" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    ;;
  minimal-render-markdown-setup-only)
    make_minimal_render_markdown_setup_only_init
    run_case "minimal-render-markdown-setup-only" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    ;;
  minimal-render-markdown-no-manager)
    make_minimal_render_markdown_no_manager_init
    run_case "minimal-render-markdown-no-manager" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    ;;
  live)
    run_case "live" \
      run_nvim --headless -n -i NONE "${target_file}" +qall!
    ;;
  live-isolated)
    run_case "live-isolated" \
      env XDG_CONFIG_HOME="${repo_root}/.codex-debug" \
      run_nvim --headless -n -i NONE "${target_file}" +qall!
    ;;
  compare)
    run_case "baseline" \
      run_nvim --headless -n -i NONE -u NONE --noplugin "${target_file}" +qall!
    make_minimal_ts_context_init
    run_case "minimal-ts-context" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    make_minimal_ts_context_no_number_init
    run_case "minimal-ts-context-no-number" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    make_minimal_render_markdown_init
    run_case "minimal-render-markdown" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    make_minimal_render_markdown_setup_only_init
    run_case "minimal-render-markdown-setup-only" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    make_minimal_render_markdown_no_manager_init
    run_case "minimal-render-markdown-no-manager" \
      run_nvim --headless -n -i NONE -u "${tmp_init}" --noplugin "${target_file}" +qall!
    run_case "live" \
      run_nvim --headless -n -i NONE "${target_file}" +qall!
    ;;
  *)
    echo "usage: $0 [baseline|minimal-ts-context|minimal-ts-context-no-number|minimal-ts-range-parse|minimal-render-markdown|minimal-render-markdown-setup-only|minimal-render-markdown-no-manager|vendor-render-markdown|vendor-ts-context|live|live-isolated|compare] [path] [variant]"
    echo "path can also be one of: simple, bash-fence, shell-fence, lua-simple, readme"
    echo "variant currently supports vendor parse modes: range, full, skip"
    exit 2
    ;;
esac
