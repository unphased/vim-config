#!/bin/sh
# ssh-server-security-check.sh
#
# Runs at interactive shell startup and reports the *live* stance of the local
# sshd for a small set of security-sensitive directives.  This gives an
# early-warning picture of each host's ssh server immediately as you log into
# it (or open a local terminal), without waiting for the next ansible run.
#
#   passwordauthentication        must be no
#   kbdinteractiveauthentication   must be no   (also matches the older
#                                                keyboardinteractiveauthentication spelling)
#   permitrootlogin                must be no or prohibit-password
#   pubkeyauthentication           must be yes
#
# How values are obtained (in order of preference):
#   1. LIVE:  `sshd -T`        -- the effective configuration the running sshd
#                                 would actually apply.  Requires root; we use
#                                 passwordless `sudo -n sshd -T` when not root.
#   2. PARSED: /etc/ssh/sshd_config + /etc/ssh/sshd_config.d/*.conf
#                                 -- best-effort fallback when sudo for sshd is
#                                 not allowed.  Banner is annotated as such so
#                                 you never mistake a parsed read for a live one.
#
# To silence entirely:
#   export SSHSEC_CHECK=0              # or any '0'/'no'/'off' value
#   touch ~/.sshsec-skip               # or a file path via SSHSEC_SKIPFILE
#
# Tunables (env):
#   SSHSEC_TTL     seconds between full re-checks when config is unchanged
#                  (default 3600).  The check always re-runs the moment sshd's
#                  config files change (by mtime) so you are never stale.
#
# Suggested sudoers entry to enable the (preferred) LIVE path without a prompt:
#   %sudo ALL=(root) NOPASSWD: /usr/sbin/sshd -T
#
# POSIX sh on purpose: this is executed with /bin/sh from both zsh and bash,
# so behaviour is identical regardless of the user's login shell.

set -u

# ---------------------------------------------------------------------------
# Bail-out / silence controls
# ---------------------------------------------------------------------------
_skip() {
    case "${1:-}" in
        ''|0|n|N|no|No|NO|off|Off|OFF|false|False|FALSE) return 0 ;;
    esac
    return 1
}
if _skip "${SSHSEC_CHECK:-1}"; then
    exit 0
fi
_skipfile="${SSHSEC_SKIPFILE:-$HOME/.sshsec-skip}"
[ -e "$_skipfile" ] && exit 0

# Only meaningful for interactive use; the caller already gates on that but be
# defensive -- we are executed (not sourced), so `exit` is safe here.
case "$-" in
    *i*) : ;;        # we were invoked from an interactive shell
    *)
        # /bin/sh is usually non-interactive even when launched by an
        # interactive zsh/bash, so do NOT bail here on $- alone.
        ;;
esac

# ---------------------------------------------------------------------------
# Paths / tunables
# ---------------------------------------------------------------------------
_ttl=$(( ${SSHSEC_TTL:-3600} + 0 ))
_host="$(uname -n 2>/dev/null || hostname 2>/dev/null || echo unknown)"
_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/sshsec"
_cache_file="$_cache_dir/$_host.state"

# Locate sshd binary.  Prefer well-known locations then PATH.
_sshd_bin=""
for _p in /usr/sbin/sshd /usr/local/sbin/sshd /opt/homebrew/sbin/sshd /usr/pkg/sbin/sshd /sbin/sshd; do
    if [ -x "$_p" ]; then
        _sshd_bin="$_p"
        break
    fi
done
if [ -z "$_sshd_bin" ]; then
    if command -v sshd >/dev/null 2>&1; then
        _sshd_bin="$(command -v sshd)"
    fi
fi

# Config files whose mtime drives cache invalidation.
_cfg_file="${SSHSEC_CFG_FILE:-/etc/ssh/sshd_config}"
_cfg_dir="${SSHSEC_CFG_DIR:-/etc/ssh/sshd_config.d}"
_cfg_files="$_cfg_file"
if [ -d "$_cfg_dir" ]; then
    # shellcheck disable=SC2011,SC2086
    _cfg_files="$_cfg_files $(echo "$_cfg_dir"/*.conf 2>/dev/null)"
fi
_cfg_mtime=0
for _f in $_cfg_files; do
    [ -e "$_f" ] || continue
    if [ "$(stat -c '%Y' "$_f" 2>/dev/null || stat -f '%m' "$_f" 2>/dev/null || echo 0)" -gt "$_cfg_mtime" ]; then
        _cfg_mtime="$(stat -c '%Y' "$_f" 2>/dev/null || stat -f '%m' "$_f" 2>/dev/null || echo 0)"
    fi
done

_now=$(date +%s 2>/dev/null || echo 0)

# ---------------------------------------------------------------------------
# Normalise a directive key to the canonical spelling we care about.
#   keyboardinteractiveauthentication -> kbdinteractiveauthentication
# ---------------------------------------------------------------------------
_normkey() {
    _k="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$_k" in
        keyboardinteractiveauthentication) _k=kbdinteractiveauthentication ;;
    esac
    printf '%s' "$_k"
}

# ---------------------------------------------------------------------------
# Gather effective values.  Emits "<key> <value>" pairs (lowercase keys) for
# whichever source we managed to consult.  Sets sshsec_source.
# ---------------------------------------------------------------------------
sshsec_source=""
sshsec_lines=""

Gather() {
    sshsec_source=""
    sshsec_lines=""

    # --- 1. LIVE via sshd -T -------------------------------------------------
    _live=""
    if [ -n "$_sshd_bin" ]; then
        if [ "$(id -u 2>/dev/null || echo 99999)" = 0 ]; then
            # Already root; no sudo needed.
            _live="$("$_sshd_bin" -T 2>/dev/null)" && [ -n "$_live" ] || _live=""
        elif command -v sudo >/dev/null 2>&1; then
            # Passwordless sudo only -- never prompt on shell startup.
            _live="$(sudo -n "$_sshd_bin" -T 2>/dev/null)" && [ -n "$_live" ] || _live=""
        fi
    fi
    if [ -n "$_live" ]; then
        sshsec_source="live sshd -T"
        sshsec_lines="$(printf '%s\n' "$_live" | while IFS=' 	' read -r _k _v; do
            [ -n "$_k" ] || continue
            _k="$(_normkey "$_k")"
            # sshd -T prints "key value"; collapse internal whitespace in value.
            _v=$(printf '%s' "$_v" | tr -s ' \t' ' ' | sed 's/^ //; s/ $//')
            [ -n "$_v" ] || continue
            printf '%s %s\n' "$_k" "$_v"
        done)"
        return
    fi

    # --- 2. PARSED fallback --------------------------------------------------
    # OpenSSH: for each parameter the FIRST obtained value is used.  Default
    # layouts put `Include /etc/ssh/sshd_config.d/*.conf` at the TOP of the
    # main file, so we read drop-in files first, then the main config, and keep
    # the first occurrence of each key.  Lines after a `Match` keyword are
    # conditional and ignored for the global stance.
    if [ ! -e "$_cfg_file" ] && [ ! -d "$_cfg_dir" ]; then
        sshsec_source="unavailable"
        return
    fi

    _dropins=""
    if [ -d "$_cfg_dir" ]; then
        # Only collect files that actually exist; a non-matching glob must not
        # leave awk with a bogus literal filename (it would abort and skip the
        # main config). POSIX sh has no nullglob, so test each expansion.
        for _df in "$_cfg_dir"/*.conf; do
            [ -e "$_df" ] || continue
            _dropins="$_dropins $_df"
        done
    fi

    _awk_out="$(awk '
        function trim(s){ sub(/^[ \t\r]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
        FNR==1 { in_match=0 }
        {
            line=$0
            sub(/#.*/,"",line)
            line=trim(line)
            if (line=="") next
            n=split(line, a, /[ \t]+/)
            key=tolower(a[1])
            if (key=="match") { in_match=1; next }
            if (in_match) next
            val=substr(line, length(a[1])+1)
            val=trim(val)
            if (key=="keyboardinteractiveauthentication") key="kbdinteractiveauthentication"
            if (!(key in seen)) { seen[key]=1; printf "%s %s\n", key, val }
        }
    ' $_dropins "$_cfg_file" 2>/dev/null)"
    sshsec_source="parsed /etc/ssh (sshd -T needs root)"
    sshsec_lines="$_awk_out"
}

# ---------------------------------------------------------------------------
# Expected-value policy.  Emits: <result> <actual> <expected-summary>
# result = "pass" or "fail".
# ---------------------------------------------------------------------------
Evaluate() {
    # args: key actual
    _ek="$1"; _av="$2"
    _exp=""
    case "$_ek" in
        passwordauthentication)
            _exp="no"
            [ "$_av" = no ] && _res=pass || _res=fail
            ;;
        kbdinteractiveauthentication)
            _exp="no"
            [ "$_av" = no ] && _res=pass || _res=fail
            ;;
        permitrootlogin)
            _exp="no|prohibit-password"
            case "$_av" in
                no|prohibit-password) _res=pass ;;
                without-password) _res=pass ;;   # older spelling; equivalent
                *) _res=fail ;;
            esac
            ;;
        pubkeyauthentication)
            _exp="yes"
            [ "$_av" = yes ] && _res=pass || _res=fail
            ;;
        *)
            _res=skip
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Print a copy-pasteable one-liner to enable the LIVE (sshd -T) path, shown
# only when we fell back to parsing. Tails off with a cache-clear reminder so
# the fix takes effect immediately instead of after the TTL/mtime window.
# ---------------------------------------------------------------------------
_hint_one_liner() {
    case "$1" in
        parsed*) : ;;   # only hint when we are NOT already live
        *) return 0 ;;
    esac

    # The inline one-liner is intentionally Darwin-only: on Linux the sudoers
    # rule is provisioned by ansible, so a per-shell hint there is just noise.
    [ "$(uname -s 2>/dev/null)" = Darwin ] || return 0

    _grp=admin

    _hintBin="${_sshd_bin:-/usr/sbin/sshd}"
    [ -n "$_hintBin" ] || _hintBin=/usr/sbin/sshd

    # Build a flat, paste-safe one-liner (no nested sh -c, so it parses the
    # same whether pasted into zsh, bash, or sh). The rule text is
    # single-quoted so the `(root)` parentheses are never seen as shell
    # operators. `sudo tee` writes as root; chmod and visudo-c run via sudo
    # too (sudo credential caching means one prompt for the whole chain).
    _cmd="echo '%${_grp} ALL=(root) NOPASSWD: ${_hintBin} -T' | sudo tee /etc/sudoers.d/sshsec-t-check >/dev/null && sudo chmod 0440 /etc/sudoers.d/sshsec-t-check && sudo visudo -c"

    printf '\033[2m Enable live (sshd -T) with one-time sudoers (run as root):\033[0m\n'
    printf '\033[0;36m %s\033[0m\n' "$_cmd"
    printf '\033[2m then clear cache: rm -rf ~/.cache/sshsec\033[0m\n'
    printf '\n'
}

# Compiled-in OpenSSH defaults used when a directive is absent from the parsed
# config (fallback path only).  These match `man sshd_config`.
DefaultFor() {
    case "$1" in
        passwordauthentication)        printf 'yes' ;;   # dangerous default
        kbdinteractiveauthentication) printf 'yes' ;;   # dangerous default
        permitrootlogin)              printf 'prohibit-password' ;;
        pubkeyauthentication)         printf 'yes' ;;
        *)                            printf '' ;;
    esac
}

Build() {
    sshsec_fail_count=0
    sshsec_report=""
    sshsec_allpass=1
    _checked="passwordauthentication kbdinteractiveauthentication permitrootlogin pubkeyauthentication"

    for _ek in $_checked; do
        _actual=""
        if [ -n "$sshsec_lines" ]; then
            _actual="$(printf '%s\n' "$sshsec_lines" | awk -v k="$_ek" '$1==k{print $2; exit}')"
        fi
        if [ -z "$_actual" ]; then
            if [ "$sshsec_source" = "live sshd -T" ]; then
                # sshd -T always prints every directive; absence here means we
                # genuinely couldn't read it -- treat as unknown/fail.
                _actual="??"
            else
                _actual="$(DefaultFor "$_ek")"
                _actual="${_actual}(default)"
            fi
        fi

        Evaluate "$_ek" "$_actual"
        _exp=""
        case "$_ek" in
            passwordauthentication)        _exp="no" ;;
            kbdinteractiveauthentication) _exp="no" ;;
            permitrootlogin)             _exp="no / prohibit-password" ;;
            pubkeyauthentication)        _exp="yes" ;;
        esac

        if [ "$_res" = pass ]; then
            _mark="\033[1;32m✓\033[0m"
            _valcol="\033[32m$_actual\033[0m"
        else
            _mark="\033[1;31m✗\033[0m"
            _valcol="\033[1;31m$_actual\033[0m"
            sshsec_fail_count=$((sshsec_fail_count + 1))
            sshsec_allpass=0
        fi
        # Pad directive name to 30 for alignment (literal spaces -- fine).
        _pname=$(printf '%-30s' "$_ek")
        # Build a single coloured line; %b here interprets the \033 escapes.
        _line="$(printf '%b %s = %b   want %s' "$_mark" "$_pname" "$_valcol" "$_exp")"
        # Accumulate with a REAL newline separator (command substitution
        # strips trailing newlines, so the separator must go between lines,
        # not at the end).
        if [ -z "$sshsec_report" ]; then
            sshsec_report="$_line"
        else
            sshsec_report="$sshsec_report
$_line"
        fi
    done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
mkdir -p "$_cache_dir" 2>/dev/null

_must_rerun=1
_cached_fail_count=0
_cached_report=""
_cached_source=""
if [ -r "$_cache_file" ]; then
    # cache format, one record per logical line:
    #   ts::cfg_mtime::source::fail_count::<report (may contain newlines)>
    _c_ts=""; _c_cfg="0"
    {
        read -r _c_ts
        read -r _c_cfg
        read -r _c_src
        read -r _c_fail
    } < "$_cache_file" 2>/dev/null
    _c_rest="$(sed -n '5,$p' "$_cache_file" 2>/dev/null)"
    _c_ts="${_c_ts:-0}"; _c_cfg="${_c_cfg:-0}"; _c_fail="${_c_fail:-0}"

    if [ "$_now" -gt 0 ] && [ "$(( _now - ${_c_ts:-0} ))" -lt "$_ttl" ] \
       && [ "${_c_cfg:-0}" -ge "$_cfg_mtime" ]; then
        _must_rerun=0
        _cached_fail_count="${_c_fail:-0}"
        _cached_report="$_c_rest"
        _cached_source="$_c_src"
    fi
fi

if [ "$_must_rerun" = 1 ]; then
    Gather
    Build
    # Write cache atomically-ish.
    _tmp="$_cache_file.tmp.$$"
    {
        printf '%s\n' "$_now"
        printf '%s\n' "$_cfg_mtime"
        printf '%s\n' "$sshsec_source"
        printf '%s\n' "$sshsec_fail_count"
        printf '%s' "$sshsec_report"
    } > "$_tmp" 2>/dev/null
    mv "$_tmp" "$_cache_file" 2>/dev/null || rm -f "$_tmp" 2>/dev/null

    # Fresh-check results write-through complete; emission is handled below.
fi

# If we hit the cache, restore the cached results for emission.
if [ "$_must_rerun" = 0 ]; then
    sshsec_report="$_cached_report"
    sshsec_source="$_cached_source"
    sshsec_fail_count="$_cached_fail_count"
fi

if [ "${sshsec_fail_count:-0}" -gt 0 ]; then
    printf '\n'
    printf '\033[1;7;31m !! SSH SERVER SECURITY CHECK -- %s !! \033[0m\n' "$_host"
    printf '\033[1;31m source: %s\033[0m\n' "$sshsec_source"
    printf '\n'
    printf '%b\n' "$sshsec_report"
    printf '\n'
    printf '\033[2m Silence: export SSHSEC_CHECK=0   or   touch ~/.sshsec-skip\033[0m\n'
elif [ "${sshsec_source:-}" = "unavailable" ]; then
    : # no sshd / no config on this host -- nothing to report
else
    # All checks passed: emit a green confirmation on every interactive
    # startup so the security posture is visible even when nothing is wrong.
    printf '\033[1;32mSSH server security OK\033[0m on %s (%s)\n' \
        "$_host" "$sshsec_source"
fi

# Whenever we are NOT live (fell back to parsing), surface a dim, copy-pasteable
# one-liner to enable the live `sshd -T` path -- in both the failure and
# all-pass cases, since "parsed" means we could not query the running server.
_hint_one_liner "$sshsec_source"

exit 0