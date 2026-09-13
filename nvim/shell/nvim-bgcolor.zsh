# Shell-side background-color integration (event-driven, no polling).
#
# Intended usage:
# - Use `:BgTerm` in Neovim to open a shell terminal buffer that exports:
#     - `NVIM` (servername)
#     - `NVIM_TERM_BUF` (terminal buffer number)
# - Source this file from your zsh config, and install a single hook:
#     source ~/.vim/nvim/shell/nvim-bgcolor.zsh
#     autoload -Uz add-zsh-hook
#     add-zsh-hook chpwd nvim_bgcolor_hook
#     add-zsh-hook precmd nvim_bgcolor_hook
#
# Requirements:
# - `~/util/bgcolor.sh` for computing `#RRGGBB`
# - `nvim` (client mode) for notifying Neovim (optional)

nvim_bgcolor_hook() {
  zmodload zsh/datetime 2>/dev/null || true
  local bgcolor_script="${HOME}/util/bgcolor.sh"
  [[ -x "$bgcolor_script" ]] || return 0
  local debug="${NVIM_BGCOLOR_DEBUG:-}"

  local cwd="${PWD}"
  local terminal_colors
  terminal_colors="$("$bgcolor_script" --format=osc "$cwd" 2>/dev/null)" || return 0

  if [[ -n "$debug" && "$debug" != "0" ]]; then
    {
      printf '%s [nvim-bgcolor] cwd=%q NVIM=%q NVIM_TERM_BUF=%q\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$cwd" "${NVIM:-}" "${NVIM_TERM_BUF:-}"
    } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
  fi

  # Emit paired OSC 10/11 defaults. Herdr requires an explicit foreground before
  # it can render a pane's dynamic default background reliably.
  # In Neovim terminal buffers these may be consumed/rendered oddly by libvterm,
  # so `:BgTerm` exports NVIM_BGCOLOR_NO_OSC11=1 to suppress them there.
  if [[ -z "${NVIM_BGCOLOR_NO_OSC11:-}" ]]; then
    printf '%s' "$terminal_colors" 2>/dev/null || true
  elif [[ -n "$debug" && "$debug" != "0" ]]; then
    {
      printf '%s [nvim-bgcolor] terminal colors suppressed (NVIM_BGCOLOR_NO_OSC11=1)\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
    } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
  fi

  # Extract the background from the paired output for the Neovim notification.
  local hex=""
  local marker=$'\033]11;'
  local rest="${terminal_colors#*${marker}}"
  local cand9="${rest[1,9]}"
  local cand7="${rest[1,7]}"
  if [[ "$cand9" =~ '^#[0-9A-Fa-f]{8}$' ]]; then
    hex="${cand9[1,7]}"
  elif [[ "$cand7" =~ '^#[0-9A-Fa-f]{6}$' ]]; then
    hex="$cand7"
  fi

  if [[ ! "$hex" =~ '^#[0-9A-Fa-f]{6}$' ]]; then
    if [[ -n "$debug" && "$debug" != "0" ]]; then
      {
        printf '%s [nvim-bgcolor] failed to parse background (len=%q colors=%q rest=%q cand7=%q cand9=%q)\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${#terminal_colors}" "$terminal_colors" "$rest" "$cand7" "$cand9"
      } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
    fi
    return 0
  fi

  [[ -n "${NVIM:-}" ]] || return 0
  [[ -n "${NVIM_TERM_BUF:-}" ]] || return 0
  if ! command -v nvim >/dev/null 2>&1; then
    if [[ -n "$debug" && "$debug" != "0" ]]; then
      {
        printf '%s [nvim-bgcolor] nvim not found in PATH\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
      } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
    fi
    return 0
  fi

  # Escape single quotes for Vimscript string literals.
  local cwd_escaped="${cwd//\'/\'\'}"

  # Calls the global Lua function `_G.NvimSetTermBg(bufnr, cwd, hex)` defined by `bgcolor-manager`.
  local expr="luaeval('NvimSetTermBg(_A[1], _A[2], _A[3])', [${NVIM_TERM_BUF}, '${cwd_escaped}', '${hex}'])"
  local nvim_out nvim_status
  local t0="${EPOCHREALTIME:-}"
  nvim_out="$(nvim --headless --server "$NVIM" --remote-expr "$expr" 2>&1)"
  local t1="${EPOCHREALTIME:-}"
  nvim_status=$?

  if [[ -n "$debug" && "$debug" != "0" ]]; then
    local elapsed=""
    if [[ -n "$t0" && -n "$t1" ]]; then
      local -F 6 dt
      dt=$(( t1 - t0 ))
      elapsed="${dt}s"
    fi
    {
      printf '%s [nvim-bgcolor] pushed hex=%q to bufnr=%q status=%q elapsed=%q out=%q\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$hex" "${NVIM_TERM_BUF:-}" "$nvim_status" "$elapsed" "$nvim_out"
    } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
  fi
}

__nvim_bgcolor_update() { nvim_bgcolor_hook }
