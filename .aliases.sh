#!/bin/bash

# todo: make me a function
# idempotent alias check (or prints existing alias -- might wanna suppress that 
# too)
if ! alias ls >/dev/null 2>&1; then
	if ls --color=auto -d . >/dev/null 2>&1; then
		alias ls="ls --color=auto"
	elif ls -G -d . >/dev/null 2>&1; then
		alias ls="ls -G"
	fi
fi

__readable_file_list_colors() {
	# GNU dircolors uses background colors for a few file classes:
	# - tw/ow/st: sticky and world-writable directories, common with Samba,
	#   ZFS, exFAT, transfer folders, and camera/media dumps.
	# - su/sg: setuid/setgid files.
	# - bd/cd/or/do: device, orphan, and odd platform-specific file types.
	#
	# Those SGR backgrounds look especially bad when lf applies its inverted
	# cursor to a large pane. Keep these classes foreground-only while leaving
	# extension colors and ordinary directory/executable colors alone.
	printf '%s\n' "$1" |
		awk -v RS=: '
			BEGIN {
				readable["bd"] = "01;33"
				readable["cd"] = "01;33"
				readable["do"] = "01;35"
				readable["or"] = "01;31"
				readable["su"] = "01;32"
				readable["sg"] = "01;32"
				readable["tw"] = "01;34"
				readable["ow"] = "01;34"
				readable["st"] = "01;34"
			}
			NF {
				key = $0
				sub(/=.*/, "", key)
				if (key in readable) {
					$0 = key "=" readable[key]
				}
				printf "%s%s", sep, $0
				sep = ":"
			}
			END { if (sep != "") printf "\n" }
		'
}

if [[ "$(uname)" == Linux ]]; then
	if [[ -n "${LS_COLORS:-}" ]]; then
		LS_COLORS="$(__readable_file_list_colors "$LS_COLORS")"
		export LS_COLORS
	fi

	LF_COLORS="${LF_COLORS:-ln=01;36:or=01;31:tw=01;34:ow=01;34:st=01;34:di=01;34:pi=33:so=01;35:bd=01;33:cd=01;33:su=01;32:sg=01;32:ex=01;32:fi=00}"
	LF_COLORS="$(__readable_file_list_colors "$LF_COLORS")"
	export LF_COLORS
fi

# some versions of htop kill high sierra without being run as root.
# TODO replace me with a version check on htop
# Nah, it's ok. just make sure your system has 2.2.0 or newer and just dont 
# worry about it.
# if [[ "$(uname -a)" =~ "Darwin Kernel Version 17" ]]; then
# 	alias htop="sudo htop"
# fi

if [ "$(uname)" = Linux ] && command -v lsb_release >/dev/null 2>&1 && lsb_release -i | grep Ubuntu; then
	alias open="xdg-open"
fi

# black ass magic
export TERMINFO_DIRS=$TERMINFO_DIRS:$HOME/.local/share/terminfo

alias vv="v ~/.vim/nvim/init.lua"
alias vp="~/.vim/nvim/monitored_autoload_nvim.sh -O ~/.vim/nvim/lua/plugins.lua ~/.vim/nvim/init.lua"
alias l="ls -rt"
alias sl="ls"
alias ll="l -lha"
# alias la="ll -a"
alias ssht="TERM=xterm-256color ssh"
alias v="nvim"
alias vd='v $(git diff --name-only | while read file; do printf "$(git rev-parse --show-toplevel)/$file "; done) -O'
alias g="git"
alias gs="git s" # short status 
alias gco="git checkout"
alias gta="git ta"
alias gtap="git tap"
alias gte="git te"
alias gnp="git notes-push"
alias gnf="git notes-fetch"
alias gnm="git notes-merge"
alias gns="git notes-status"
if [[ -n "${ZSH_VERSION:-}" ]]; then
  # In zsh with extendedglob enabled, `^slu` expands to "everything except slu".
  # The notes helpers intentionally use `^<ref>` shorthands, so disable globbing
  # for these commands to prevent accidental expansion into filenames.
  alias gn="noglob git gn"
  alias gne="noglob git gn --edit"
  alias gnr="noglob git nr"
else
  alias gn="git gn"
  alias gne="git gn --edit"
  alias gnr="git nr"
fi

# Local notes DAG history viewers. These inspect refs/notes/* history; they are
# separate from the `git notes-*` commands, which sync notes refs.
gnl() {
  local -a refs
  refs=($(git for-each-ref refs/notes --format='%(refname)' 2>/dev/null))
  if [[ ${#refs[@]} -eq 0 ]]; then
    echo "gnl: no refs/notes/* found" >&2
    return 1
  fi
  git log --graph --oneline "${refs[@]}"
}

gnlp() {
  local -a refs
  refs=($(git for-each-ref refs/notes --format='%(refname)' 2>/dev/null))
  if [[ ${#refs[@]} -eq 0 ]]; then
    echo "gnlp: no refs/notes/* found" >&2
    return 1
  fi
  git log --graph --oneline -p "${refs[@]}"
}

gnls() {
  local -a refs
  refs=($(git for-each-ref refs/notes --format='%(refname)' 2>/dev/null))
  if [[ ${#refs[@]} -eq 0 ]]; then
    echo "gnls: no refs/notes/* found" >&2
    return 1
  fi
  git log --graph --oneline --stat "${refs[@]}"
}

# Notes DAG, patch view (mnemonic: git log notes -p)
alias glnp="gnlp"
alias glpo="git --no-pager log -p --color=always | less"
alias glpa="git log -p --all"
alias glpf="git log -p --follow"
alias glp="git log -p"
alias glpr="git --no-pager -c color.ui=always log -p --no-ext-diff | less -R"
alias glpe="GIT_EXTERNAL_DIFF=sift GIT_PAGER=less git log -p --ext-diff --pretty=format:'%C(bold yellow)%H%Creset%C(auto)%d%Creset %s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset'"
alias glpen="git --no-pager log -p --color=always | less"
# alias glpes="git log -p --ext-diff --stat"
alias gd="git --no-pager diff --color=always | less"
alias gf='git fetch'

__git_terminal_cols() {
  local term_size term_cols

  if command -v stty >/dev/null 2>&1 && [[ -r /dev/tty ]]; then
    term_size="$(stty size </dev/tty 2>/dev/null || true)"
    term_cols="${term_size##* }"
  fi

  if [[ ! "$term_cols" =~ ^[0-9]+$ || "$term_cols" -le 0 ]]; then
    term_cols="${COLUMNS:-}"
  fi

  if [[ "$term_cols" =~ ^[0-9]+$ && "$term_cols" -gt 0 ]]; then
    printf '%s\n' "$term_cols"
  fi
}

__git_args_include_width_adjustable_stat() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      --stat|--stat=*|--patch-with-stat|--patch-with-stat=*)
        return 0
        ;;
    esac
  done

  return 1
}

__git_set_stat_width_args() {
  local term_cols stat_cols

  stat_width_args=()
  __git_args_include_width_adjustable_stat "$@" || return 0

  stat_cols="${GIT_STAT_WIDTH:-}"
  if [[ -z "$stat_cols" ]]; then
    term_cols="$(__git_terminal_cols)"
    if [[ -z "$term_cols" ]]; then
      return 0
    fi

    stat_cols="$term_cols"
    if (( stat_cols > 5 )); then
      stat_cols=$((stat_cols - 5))
    fi
  fi

  if [[ ! "$stat_cols" =~ ^[0-9]+$ || "$stat_cols" -le 0 ]]; then
    return 0
  fi

  stat_width_args=("--stat-width=$stat_cols" "--stat-name-width=$stat_cols")
}

# an override of gfa from omz, --tags sometimes causes conflicts
alias gfa='git fetch --all --prune --jobs=10'
unalias gds 2>/dev/null || true
gds() {
  local -a stat_width_args
  __git_set_stat_width_args --stat "$@"
  git diff "${stat_width_args[@]}" --stat "$@"
}
# The everyday high-level diff view; `search` retains the old search utility.
alias s=gds
alias di="git diff-with-ignored"
alias gc!="git commit --amend"

alias gsp="git stash pop"

# unfortunately the mnemonic of ext is sticking, so even though difftool is used to run sift 
# i will keep using the "e"
alias gde="GIT_EXTERNAL_DIFF=sift GIT_PAGER=less git diff --ext-diff"
alias de="gde"
alias gdc="gd --cached"
#unalias gg # some git gui thing from ohmyzsh
unalias gg ggn ggs ggsn ggf ggfs 2>/dev/null || true

# Without --: infer paths/revisions, default to --all for path-only calls, and
# report the assembled command. A literal -- bypasses inference completely.
# Bare operands must resolve as exactly one of path or revision. Keep every
# other argument in its original order and append only inferred paths after --.
# Unsupported options need --option=value or the explicit-separator escape hatch.
__git_log_path_candidate() {
  local operand=$1
  [[ -e "$operand" || -L "$operand" ]] && return 0
  case "$operand" in
    .|..|./*|../*|/*|*'*'*|*'?'*|*'['*|:\(*|:!*|:^*) return 0 ;;
  esac
  git ls-files --error-unmatch -- "$operand" >/dev/null 2>&1 && return 0
  [[ -n "$(git log --all -1 --format=%H --no-notes -- "$operand" 2>/dev/null)" ]]
}

__git_log_run() {
  local label=$1 mode=$2 arg
  shift 2
  printf '%s (%s):' "$label" "$mode" >&2
  for arg in "$@"; do
    printf ' %q' "$arg" >&2
  done
  printf '\n' >&2
  # Distinguish a user-supplied separator from one assembled by this wrapper.
  GIT_LGTN_ARGUMENT_MODE="$mode" "$@"
}

__git_log_view() {
  local label=$1 log_alias=$2 include_notes=$3 add_stat=$4
  shift 4
  local arg rev_check path_check has_selector=false passthrough=false
  local -a cmd=() ordered=() paths=()

  cmd=(git "$log_alias")
  [[ "$include_notes" == true && "$log_alias" == lgtn ]] && cmd+=(--include-notes-dag)
  [[ "$add_stat" == true ]] && cmd+=(--stat)

  # Any literal separator opts out completely: preserve every user argument.
  for arg in "$@"; do
    if [[ "$arg" == -- ]]; then passthrough=true; break; fi
  done
  if [[ "$passthrough" == true ]]; then
    cmd+=("$@")
    __git_log_run "$label" passthrough "${cmd[@]}"
    return $?
  fi

  while [[ $# -gt 0 ]]; do
    arg=$1; shift
    case "$arg" in
      --include-notes-dag)
        if [[ "$log_alias" != lgtn ]]; then
          printf '%s: --include-notes-dag is only supported by gg/ggs notes views\n' "$label" >&2
          return 2
        fi
        include_notes=true
        ;;
      -n)
        if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
          ordered+=("--max-count=$1"); shift
        elif [[ "$log_alias" == lgtn ]]; then
          include_notes=true
        else
          printf '%s: -n requires a commit count in full-message views\n' "$label" >&2
          return 2
        fi
        ;;
      --all|--reflog|--alternate-refs)
        ordered+=("$arg"); has_selector=true
        ;;
      --branches|--tags|--remotes|--branches=*|--tags=*|--remotes=*)
        ordered+=("$arg"); has_selector=true
        ;;
      --glob=*)
        ordered+=("$arg"); has_selector=true
        ;;
      --glob)
        if [[ $# -eq 0 ]]; then echo "gg: --glob needs a pattern" >&2; return 2; fi
        ordered+=("$arg" "$1"); shift; has_selector=true
        ;;
      -L)
        if [[ $# -eq 0 ]]; then echo "gg: -L needs a line range and file" >&2; return 2; fi
        ordered+=("$arg" "$1"); shift; has_selector=true
        ;;
      -L*)
        # Line history requires one starting commit; retain Git's HEAD default.
        ordered+=("$arg"); has_selector=true
        ;;
      --author|--committer|--grep|--grep-reflog|--since|--after|--until|--before|--max-count|--skip|--date|--diff-filter|--exclude|--decorate-refs|--decorate-refs-exclude|--stat-width|--stat-name-width|--stat-count|--encoding|--output|-S|-G|-O|-U)
        if [[ $# -eq 0 ]]; then echo "gg: $arg needs a value" >&2; return 2; fi
        ordered+=("$arg" "$1"); shift
        ;;
      --*=*)
        ordered+=("$arg")
        ;;
      --not|--oneline|--graph|--decorate|--no-decorate|--color|--no-color|--ext-diff|--no-ext-diff|--textconv|--no-textconv|--stat|--shortstat|--numstat|--name-only|--name-status|--summary|--check|--patch|--no-patch|--raw|--binary|--full-index|--abbrev|--pretty|--format|--notes|--no-notes|--follow|--no-merges|--merges|--first-parent|--root|--reverse|--topo-order|--date-order|--author-date-order|--boundary|--left-right|--cherry|--cherry-mark|--cherry-pick|--right-only|--left-only|--ancestry-path|--full-history|--simplify-merges|--simplify-by-decoration|--dense|--sparse|--walk-reflogs|--no-walk|--no-renames|--find-renames|--find-copies|--find-copies-harder|--ignore-space-change|--ignore-all-space|--ignore-space-at-eol|--word-diff|--color-moved|--patch-with-stat|--patch-with-raw|-p|-u|-v|-q|-s|-w|-m|-c|-t|-i|-E|-M|-C|-B)
        ordered+=("$arg")
        ;;
      -[0-9]*|-n[0-9]*|-S*|-G*|-U*|-O*)
        ordered+=("$arg")
        ;;
      -*)
        printf 'gg: unknown option %q; use --option=value or an explicit -- to bypass inference\n' "$arg" >&2
        return 2
        ;;
      *)
        path_check=false
        __git_log_path_candidate "$arg" && path_check=true
        rev_check="$(git rev-parse --revs-only --no-flags "$arg" 2>/dev/null)"
        if [[ "$path_check" == true && -n "$rev_check" ]]; then
          printf 'gg: %q is both a path and revision; use -- %q for the path or %q -- for the revision\n' "$arg" "$arg" "$arg" >&2
          return 2
        elif [[ "$path_check" == true ]]; then
          paths+=("$arg")
        elif [[ -n "$rev_check" ]]; then
          ordered+=("$arg"); has_selector=true
        else
          printf 'gg: cannot classify operand %q; use -- %q for a path or %q -- for a revision\n' "$arg" "$arg" "$arg" >&2
          return 2
        fi
        ;;
    esac
  done

  if [[ "$include_notes" == true && "$log_alias" == lgtn ]]; then
    cmd=(git "$log_alias" --include-notes-dag)
    [[ "$add_stat" == true ]] && cmd+=(--stat)
  fi
  # Ref-selection modifiers such as --exclude must precede the default --all.
  [[ "$has_selector" == true ]] || ordered+=(--all)
  cmd+=("${ordered[@]}")
  [[ ${#paths[@]} -gt 0 ]] && cmd+=(-- "${paths[@]}")
  __git_log_run "$label" auto "${cmd[@]}"
}

__git_lgtn_hint() {
  printf '%s\n' 'gg tip: -n alone/--include-notes-dag shows the notes DAG; -n N limits commits; --stat adds stats.' >&2
}

__git_log_view_with_hint() {
  local view_status
  if __git_log_view "$@"; then view_status=0; else view_status=$?; fi
  __git_lgtn_hint
  return "$view_status"
}

gg()   { __git_log_view_with_hint gg lgtn false false "$@"; }
ggn()  { __git_log_view gg lgtn true false "$@"; }
ggs()  { __git_log_view_with_hint ggs lgtn false true "$@"; }
ggsn() { __git_log_view ggsn lgtn true true "$@"; }
# Full-message variants; keep gf available for git fetch.
ggf()  { __git_log_view ggf lgf false false "$@"; }
ggfs() { __git_log_view ggfs lgfs false false "$@"; }
alias gfp="git push --force-with-lease"
alias gca="git commit -av"
alias gcm="git commit-message"
#unalias gcp # I rarely cherry pick (if not using ohmyzsh, this will cause bash to emit a warning)

alias gc="git commit -v"

alias gp="git push"
alias k="l" # this is a bit tongue in cheek

alias gl="git pull"

alias gr="git remote"

# actually zsh with prezto won't need this since it has its own fallback 
# mechanism for make. But, this is useful in e.g. bash.
which colormake > /dev/null 2>&1 && alias make="colormake"

alias mk="make"

# Pi self-updates replace local core patches. Package/model-only updates can
# pass through without the self-update warning.
pi() {
	if [ "${1-}" = "update" ]; then
		# Keep this small parser aligned with Pi's package-update targets so that
		# extension and model updates do not look like self-updates. Be
		# conservative whenever --self, --all, or a self positional target is
		# present, since those requests may replace Pi itself.
		local update_arg update_source="" update_has_self=0 update_has_all=0
		local update_has_extensions=0 update_has_models=0 update_has_extension=0
		local update_first_arg=1 update_skip_arg=0
		for update_arg in "$@"; do
			if [ "$update_first_arg" -eq 1 ]; then
				update_first_arg=0
				continue
			fi
			if [ "$update_skip_arg" -eq 1 ]; then
				update_skip_arg=0
				case "$update_arg" in
					-*) ;;
					*) continue ;;
				esac
			fi
			case "$update_arg" in
				--self) update_has_self=1 ;;
				--all) update_has_all=1 ;;
				--extensions) update_has_extensions=1 ;;
				--models) update_has_models=1 ;;
				--extension) update_has_extension=1; update_skip_arg=1 ;;
				--*) ;;
				*) [ -n "$update_source" ] || update_source="$update_arg" ;;
			esac
		done
		if [ "$update_has_self" -eq 0 ] && [ "$update_has_all" -eq 0 ] \
			&& [ "$update_source" != "self" ] && [ "$update_source" != "pi" ] \
			&& { [ "$update_has_extensions" -eq 1 ] || [ "$update_has_models" -eq 1 ] \
				|| [ "$update_has_extension" -eq 1 ] || [ -n "$update_source" ]; }; then
			# Do not make a Pi package/model update depend on the NAS being online.
			command pi "$@"
			return $?
		fi

		printf '%s\n' \
			'Pi updates that include Pi itself replace local core patches.' \
			'For a Pi self-update, cancel and run: make -C "$HOME/util/pi" pi-upgrade' \
			'Package/model-only updates can safely continue.' >&2
		if [ ! -t 0 ]; then
			printf '%s\n' 'Canceled: no interactive terminal available.' >&2
			return 2
		fi
		printf '%s' 'Run the original pi update command anyway? [y/N] ' >&2
		local reply
		IFS= read -r reply
		case "$reply" in
			y|Y|yes|YES|Yes) ;;
			*) printf '%s\n' 'Canceled.' >&2; return 2 ;;
		esac
		command pi "$@"
		return $?
	fi

	if [ "${PI_CRW_DISABLED:-0}" = "1" ]; then
		command pi "$@"
		return $?
	fi

	# Explicit endpoint/key pairs always win, which allows one launch to target
	# any CRW host without changing shell configuration.
	if [ -n "${CRW_API_URL:-}" ] && [ -n "${CRW_API_KEY:-}" ]; then
		command pi "$@"
		return $?
	fi

	# Prefer the workstation's localhost-only service. Fetch its key just for
	# this Pi process so local subagents inherit the same endpoint.
	local crw_key crw_api_url crw_local_env
	crw_local_env="$HOME/Library/Application Support/crw/stack/.env"
	if [ -f "$crw_local_env" ] \
		&& curl -fsS --connect-timeout 1 --max-time 2 http://127.0.0.1:3210/health \
			-o /dev/null 2>/dev/null; then
		crw_key="$(awk -F= '$1 == "CRW_API_KEY" { sub(/^[^=]*=/, ""); print; exit }' \
			"$crw_local_env")"
		if [ -n "$crw_key" ]; then
			CRW_API_URL=http://127.0.0.1:3210 CRW_API_KEY="$crw_key" command pi "$@"
			return $?
		fi
	fi

	# Otherwise try the remote NAS service. The child Pi process and its local
	# subagents inherit the selected endpoint and key.
	crw_api_url="${CRW_API_URL:-http://slu-nas-eos:3000}"
	# The bootstrap leaves .env mode 0600 but assigns it to the operator who
	# invoked sudo, so ordinary SSH access is sufficient. Keep the sudo fallback
	# for older/root-owned deployments when a narrow NOPASSWD rule exists. Try
	# both over one connection so an unavailable NAS delays Pi by about 2s total.
	if ! crw_key="$(ssh -o BatchMode=yes -o RequestTTY=no -o ConnectTimeout=2 \
		nas "awk -F= '\$1 == \"CRW_API_KEY\" { print \$2 }' /opt/crw-stack/.env || sudo -n awk -F= '\$1 == \"CRW_API_KEY\" { print \$2 }' /opt/crw-stack/.env" \
		2>/dev/null)"; then
		crw_key=""
	fi
	if [ -z "$crw_key" ]; then
		printf '%s\n' 'Unable to retrieve the CRW API key from nas; starting Pi anyway.' >&2
		command pi "$@"
		return $?
	fi

	CRW_API_URL="$crw_api_url" CRW_API_KEY="$crw_key" command pi "$@"
}

alias gcp="git commit-push"

alias gcb='git checkout -b'

#Dupes of useful ones from omz
alias gp="git push"
alias gst="git status-with-ignored"
alias ga="git add"
alias gb="git branch"

alias ds="dirs -v | head -10"
# d: git diff (paged through delta), and stash the list of files appearing in
# the diff into ~/.vim/.search-found so `os a` can open them all.
unalias d 2>/dev/null || true
d() {
	local arg
	local -a stat_width_args name_only_args
	__git_set_stat_width_args "$@"
	for arg in "$@"; do
		case "$arg" in
			--stat|--stat=*|--patch-with-stat|--patch-with-stat=*|--numstat|--shortstat)
				;;
			*)
				name_only_args+=("$arg")
				;;
		esac
	done
	git diff --no-ext-diff --name-only "${name_only_args[@]}" > "$HOME/.vim/.search-found" 2>/dev/null
	git diff --no-ext-diff "${stat_width_args[@]}" "$@"
}

alias nri="rm -rf ./node_modules/ && npm i"

# alias ts="tmux split-window"
# # V is the easier mnemonic. But in tmux parlance this is a horizontal split.
# alias tv="tmux split-window -h"

# alias iack="ack -i"

# if [ "$(uname)" != "MSYS_NT-10.0" ]; then
# 	alias vim="TERM=xterm-256color-italic vim"
# fi

alias c="cd"

# TODO: deal with this abomination (i.e. make it worse by generalizing it)
if [[ $(uname) == Linux ]]; then
	# need to use a non custom term to not confuse nano. Also enabling the 
	# experimental undo functionality for nano
	alias nano="TERM=xterm-256color nano -u"
	# # this is a trick seen here http://superuser.com/a/479816/98199
	# # it is slightly horrifying and basically turns sudo into a function now. It 
	# # will quickly be seen whether this is a sane approach
	# function sudo() {
	# 	case $* in
	# 		nano* ) shift 1; TERM=xterm-256color command sudo nano -u "$@" ;;
	# 		* ) command sudo "$@" ;;
	# 	esac
	# }

	# We can compile and install a newer nano on OSX but there is DEFINITELY no 
	# reason to use it over vim on a machine running OSX. None at all.
fi

alias dc="cd"

# Very useful command debugger
BLACK="\x1b[30m"
RESET="\x1b[0m"
execute () {
  CTR=1
  echo "Executing the following:"
  for arg in "$@"; do
    printf "$BLACK"'$'"%s=$RESET%s " $CTR "$arg"
    (( CTR ++ ))
  done
  echo "" # new line
  "$@"
}

# unfortunately this is turning into a place where i collect environment 
# settings for both zsh/bash. Not that theres anything wrong with that per se, 
# but it means this file shouldn't be called aliases.sh any longer...

# fix TERM=screen-* causing LESS to use italics.
export LESS_TERMCAP_mb=$'\E[1;31m'       # begin blinking
export LESS_TERMCAP_md=$'\E[1;38;5;74m'  # begin bold
export LESS_TERMCAP_me=$'\E[0m'           # end mode
export LESS_TERMCAP_se=$'\E[0m'          # end standout-mode (clear bg)
export LESS_TERMCAP_so=$'\E[30;48;5;74m'    # begin standout-mode / info box (use bgcolor)
export LESS_TERMCAP_ue=$'\E[0m'           # end underline
export LESS_TERMCAP_us=$'\E[4;38;5;146m' # begin underline

export OSTYPE

# # because omz people are slightly incompetent and regressed these aliases i did 
# # start to use (these may come back later when #4585 completes)
alias gdc='git diff --cached'
alias gap='git add --patch'
alias gsl='git stash list -p'

alias grepc='grep --color=always --exclude=\*{.,-}min.\*'
# alias cack='ack --color'
# alias ackc='ack --color'
# alias agc='ag --color'
alias mkae='make'

# only for macos
# if [[ "$(uname -a)" =~ "Darwin Kernel" ]]; then
#   alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
# fi

# to make fzf's file finding usage (mainly when using vim but should work for 
# non-vim) work like i want, which is let me comb through all the files ever. 
# Except for git repoes.
export FZF_DEFAULT_COMMAND="fd --type file"

# i'm trying to not export PATH in the aliases script here. But, so far it is 
# my only way to dedupe a sane config across OS's, bash & omz & prezto.

# set PATH so it includes user's private bin directories
export PATH="$HOME/.cargo/bin:$HOME/bin:$HOME/.local/bin:$PATH"

export PATH=$HOME/util:$PATH

# source $HOME/.vim/work/aliases/rtr.sh

# Not sure how i feel about this but it's how they want it done
export PATH=$PATH:/usr/local/go/bin

export EDITOR=nvim

# for pip3 on macos (ehhhh)
# [[ -d $HOME/Library/Python/3.8/bin && ! "$PATH" =~ $HOME/Library/Python/3.8/bin ]] && export 
# PATH=$HOME/Library/Python/3.8/bin:$PATH

# for when tmux panes lose the ssh agent env vars
fixssh() {
  eval $(tmux show-env -s |grep '^SSH_')
}

# for adam costello's par
export PARINIT="rTbgqR B=.,?'_A_a_@ Q=_s>|"

export MACHINE_ID=$(cat /opt/machine-id)
export GIT_DELTA_HYPERLINK_FORMAT="file://$MACHINE_ID{path}:{line}"

## this alias broke all of git tab completions but curiously only for macos.
# alias git="git --config-env=delta.hyperlinks-file-link-format=GIT_DELTA_HYPERLINK_FORMAT"

# Temporarily pointing aider at local install. This may be temporary as pipx does a decent job of maintaining it
# normally but This is the cleanest way i came up with so far to quickly target a local install IF ONE EXISTS.
AIDER_PROGRAM=~/aider/venv/bin/aider
AIDER_PROGRAM2=~/.local/bin/aider
AIDER_CMD=aider

if [[ -x "$AIDER_PROGRAM2" ]]; then
  AIDER_CMD="$AIDER_PROGRAM2"
fi

if [[ -x "$AIDER_PROGRAM" ]]; then
  AIDER_CMD="$AIDER_PROGRAM"
fi

aider_function() {
  # Push title to stack
  echo -ne "\033[22;0t"
  # Set title
  echo -ne "\033]0;AIDER\007"
  # Set trap to restore title when exiting aider
  trap 'echo -ne "\033[23;0t"; trap - INT TERM EXIT' INT TERM EXIT
  "$AIDER_CMD" "$@"
  # Restore the title after aider finishes
  echo -ne "\033[23;0t"
  # Remove the trap after finishing
  trap - INT TERM EXIT
}

alias aider='aider_function'

# neovim launcher
nv() {
  local launcher neovide_config neovim_bin
  launcher="$(command -v neovide-launch.sh 2>/dev/null || true)"
  [[ -n "$launcher" ]] || launcher="neovide"
  neovide_config="$HOME/.vim/neovide-config.toml"
  [[ -f "$neovide_config" ]] || neovide_config=""
  neovim_bin="$(command -v nvim 2>/dev/null || true)"
  local cwd frame
  cwd="$(pwd -P)"
  if [[ "${1:-}" == "-C" || "${1:-}" == "--cwd" ]]; then
    cwd="${2:-}"
    shift 2 || true
  elif [[ -n "${1:-}" && "${1:-}" != -* && -d "${1:-}" ]]; then
    cwd="$1"
    shift
  fi

  [[ -d "$cwd" ]] || cwd="$HOME"

  frame="full"
  [[ "$(uname -s)" == "Darwin" ]] && frame="transparent"

  local -a env_args
  # Neovide is a separate GUI window; do not bind its nvim instance to the launching Herdr pane.
  env_args=(NEOVIDE_FRAME="$frame" HERDR_ENV=0)
  [[ -n "$neovide_config" ]] && env_args+=(NEOVIDE_CONFIG="$neovide_config")
  [[ -n "$neovim_bin" ]] && env_args+=(NEOVIM_BIN="$neovim_bin")

  local -a start_cmd
  if command -v setsid >/dev/null 2>&1; then
    start_cmd=(setsid)
  elif command -v nohup >/dev/null 2>&1; then
    start_cmd=(nohup)
  else
    start_cmd=()
  fi

  (
    cd "$cwd" && \
    exec </dev/null >/dev/null && \
    env "${env_args[@]}" "${start_cmd[@]}" "$launcher" "$@"
  ) &
  disown 2>/dev/null || true
}

# just sets the N prefix to a sane and safe location in home dir. Although the default is reasonable and works almost
# out of the box on macos (it isn't though, on account of /usr/local/n needing chowning) the default path does not work
# on linux without perm shenanigans. So this is a good way to establish a better N prefix to use.
export N_PREFIX=$HOME/.n
export PATH=$N_PREFIX/bin:$PATH
# note on some systems specifically ones where i dont set up THIS script, it's fine and low effort to just run n with
# sudo, it's not like that will affect the user running node.

# Machine specific/contextual visual stuff!
# - tmux status bar will have a salient color specific to machines/environments. To make this work an env var is
#   provided for tmux config to leverage.
# - non tmux shell environment will have entire shell bgcolor set to a subtler version of that color.
# - root shells will have a salient bgcolor? (not sure about this one as root shell wont be running my zsh and easy to
# recognize)

# Still planning -- I might try to define these colors in the hardware mac address file. we'll see...

alias civ="civit_dl"

# Sucks it took me 10 years longer than it should have to derive these helpers
alias last2='!-2 && !!'
alias last3='!-3 && !-2 && !!'
alias last4='!-4 && !-3 && !-2 && !!'
alias last5='!-5 && !-4 && !-3 && !-2 && !!'
alias last6='!-6 && !-5 && !-4 && !-3 && !-2 && !!'

# OpenCode with profile support
# oc       - default (currently omo via symlink)
# ocs      - slim mode (token efficient, runtime fallback)
# och      - heavy mode (full omo with metis/momus/prometheus)
alias oc='opencode-launch'
alias ocs='opencode-launch --slim'
alias och='opencode-launch --omo'

# Took a while to learn about the sane way to run rsync:
# --info=progress2 furnishes the progress 
# --no-i-r allows the reported progress to be the FULL progress
alias rsync='rsync --info=progress2 --no-i-r --partial --partial-dir=.rsync-partial'

__eject_decode_findmnt() {
  printf '%b' "$1"
}

__eject_findmnt_target_for_path() {
  __eject_decode_findmnt "$(findmnt -T "$1" -n -o TARGET 2>/dev/null | head -n 1)"
}

__eject_findmnt_source_for_path() {
  __eject_decode_findmnt "$(findmnt -T "$1" -n -o SOURCE 2>/dev/null | head -n 1)"
}

__eject_findmnt_target_for_dev() {
  __eject_decode_findmnt "$(findmnt -rn -S "$1" -o TARGET 2>/dev/null | head -n 1)"
}

eject() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "eject: Linux-only helper" >&2
    return 1
  fi

  if [[ $# -gt 0 ]]; then
    command /usr/bin/eject "$@"
    return
  fi

  local target mountpoint source_dev disk_name disk_dev removable hotplug tran
  local dev mp failed_mountpoint
  local -a mounted_devs

  target="$(pwd -P)"
  mountpoint="$(__eject_findmnt_target_for_path "$target")"
  source_dev="$(__eject_findmnt_source_for_path "$target")"

  [[ -n "$mountpoint" ]] || { echo "eject: could not find a mount containing $target" >&2; return 1; }
  [[ "$target" == "$mountpoint" ]] || { echo "eject: run from the mounted filesystem root, not from $target" >&2; return 1; }

  case "$mountpoint" in
    /run/media/*|/media/*|/mnt/*) ;;
    *) echo "eject: $mountpoint is not under /run/media, /media, or /mnt" >&2; return 1 ;;
  esac

  case "$mountpoint" in
    /|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/home|/home/*|/opt|/opt/*|/root|/root/*|/srv|/srv/*|/usr|/usr/*|/var|/var/*)
      echo "eject: refusing to operate on system mountpoint $mountpoint" >&2
      return 1
      ;;
  esac

  [[ "$source_dev" == /dev/* ]] || { echo "eject: $mountpoint is mounted from $source_dev, not a block device" >&2; return 1; }
  source_dev="${source_dev%%\[*}"
  source_dev="$(readlink -f "$source_dev")" || { echo "eject: could not resolve block device for $mountpoint" >&2; return 1; }
  [[ -b "$source_dev" ]] || { echo "eject: $source_dev is not a block device" >&2; return 1; }

  disk_name="$(lsblk -no PKNAME "$source_dev" | head -n 1 | tr -d '[:space:]')"
  if [[ -z "$disk_name" ]]; then
    disk_dev="$source_dev"
  else
    disk_dev="/dev/$disk_name"
  fi
  [[ -b "$disk_dev" ]] || { echo "eject: $disk_dev is not a block device" >&2; return 1; }

  removable="$(lsblk -dno RM "$disk_dev" | tr -d '[:space:]')"
  hotplug="$(lsblk -dno HOTPLUG "$disk_dev" | tr -d '[:space:]')"
  tran="$(lsblk -dno TRAN "$disk_dev" | tr -d '[:space:]')"
  if [[ "$removable" != 1 && "$hotplug" != 1 && "$tran" != usb && "$tran" != mmc && "$tran" != firewire ]]; then
    echo "eject: $disk_dev does not look removable or hotplugged (RM=$removable HOTPLUG=$hotplug TRAN=${tran:-unknown})" >&2
    return 1
  fi

  while IFS= read -r dev; do
    mp="$(__eject_findmnt_target_for_dev "$dev")"
    [[ -n "$mp" ]] && mounted_devs+=("$dev")
  done < <(lsblk -nrpo NAME "$disk_dev")
  [[ ${#mounted_devs[@]} -gt 0 ]] || { echo "eject: no mounted filesystems found on $disk_dev" >&2; return 1; }

  for dev in "${mounted_devs[@]}"; do
    mp="$(__eject_findmnt_target_for_dev "$dev")"
    [[ -n "$mp" ]] || continue
    case "$mp" in
      /run/media/*|/media/*|/mnt/*) ;;
      *) echo "eject: refusing to power off $disk_dev while $dev is mounted at non-removable-media path $mp" >&2; return 1 ;;
    esac
  done

  echo "Unmounting filesystems on $disk_dev:"
  for dev in "${mounted_devs[@]}"; do
    mp="$(__eject_findmnt_target_for_dev "$dev")"
    echo "  $dev${mp:+ mounted at $mp}"
  done

  builtin cd / || return

  for dev in "${mounted_devs[@]}"; do
    if ! sudo udisksctl unmount -b "$dev"; then
      failed_mountpoint="$(__eject_findmnt_target_for_dev "$dev")"
      if command -v cwd-holders >/dev/null 2>&1; then
        cwd-holders "${failed_mountpoint:-$mountpoint}" >&2
      else
        echo "eject: install cwd-holders for detailed cwd/SSH/tmux diagnostics" >&2
      fi
      return 1
    fi
  done

  echo "Powering off $disk_dev"
  sudo udisksctl power-off -b "$disk_dev"
}
