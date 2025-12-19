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
# - `nvr` for notifying Neovim (optional but recommended)

nvim_bgcolor_hook() {
  local bgcolor_script="${HOME}/util/bgcolor.sh"
  [[ -x "$bgcolor_script" ]] || return 0
  local debug="${NVIM_BGCOLOR_DEBUG:-}"

  local cwd="${PWD}"
  local osc11
  osc11="$("$bgcolor_script" "$cwd" 2>/dev/null)" || return 0

  if [[ -n "$debug" && "$debug" != "0" ]]; then
    {
      printf '%s [nvim-bgcolor] cwd=%q NVIM=%q NVIM_TERM_BUF=%q\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$cwd" "${NVIM:-}" "${NVIM_TERM_BUF:-}"
    } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
  fi

  # Emit OSC 11 for terminals that honor it.
  # In Neovim terminal buffers this may be consumed/rendered oddly by libvterm,
  # so `:BgTerm` exports NVIM_BGCOLOR_NO_OSC11=1 to suppress it there.
  if [[ -z "${NVIM_BGCOLOR_NO_OSC11:-}" ]]; then
    printf '%s' "$osc11" 2>/dev/null || true
  elif [[ -n "$debug" && "$debug" != "0" ]]; then
    {
      printf '%s [nvim-bgcolor] osc11 suppressed (NVIM_BGCOLOR_NO_OSC11=1)\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
    } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
  fi

  # Parse hex out of OSC11 output. Format:
  #   ESC ] 11 ; <color> ESC \
  # Our `bgcolor.sh` always emits this exact prefix, so slice by position instead
  # of pattern-matching control characters (which is fragile in zsh `[[ ... == ... ]]`).
  local hex=""
  local rest="${osc11[6,-1]}" # drop leading ESC]11;
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
        printf '%s [nvim-bgcolor] failed to parse hex from osc11 (len=%q osc11=%q rest=%q cand7=%q cand9=%q)\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${#osc11}" "$osc11" "$rest" "$cand7" "$cand9"
      } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
    fi
    return 0
  fi

  [[ -n "${NVIM:-}" ]] || return 0
  [[ -n "${NVIM_TERM_BUF:-}" ]] || return 0
  if ! command -v nvr >/dev/null 2>&1; then
    if [[ -n "$debug" && "$debug" != "0" ]]; then
      {
        printf '%s [nvim-bgcolor] nvr not found in PATH\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
      } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
    fi
    return 0
  fi

  # Escape single quotes for Vimscript string literals.
  local cwd_escaped="${cwd//\'/\'\'}"

  # Calls the global Lua function `_G.NvimSetTermBg(bufnr, cwd, hex)` defined by `bgcolor-manager`.
  local expr="luaeval('NvimSetTermBg(_A[1], _A[2], _A[3])', [${NVIM_TERM_BUF}, '${cwd_escaped}', '${hex}'])"
  local nvr_out nvr_status
  nvr_out="$(nvr --servername "$NVIM" --remote-expr "$expr" 2>&1)"
  nvr_status=$?

  if [[ -n "$debug" && "$debug" != "0" ]]; then
    {
      printf '%s [nvim-bgcolor] pushed hex=%q to bufnr=%q status=%q out=%q\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$hex" "${NVIM_TERM_BUF:-}" "$nvr_status" "$nvr_out"
    } >>/tmp/nvim-bgcolor-hook.log 2>/dev/null || true
  fi
}

__nvim_bgcolor_update() { nvim_bgcolor_hook }
