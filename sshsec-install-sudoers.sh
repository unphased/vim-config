#!/bin/sh
# sshsec-install-sudoers.sh
#
# Installs a sudoers drop-in that lets the local user run
#   sudo /usr/sbin/sshd -T
# WITHOUT a password, so ssh-server-security-check.sh can read sshd's *live*
# effective configuration on every interactive shell startup.
#
# `sshd -T` is read-only: it prints the merged config and exits. It does not
# start a daemon and discloses no secrets (no host-key material, no
# passwords). The sudoers rule pins the command to exactly `/usr/sbin/sshd -T`
# (absolute path, fixed arg), so extra flags -- notably `-f /arbitrary` (read a
# different config) and `-C ...` (resolve Match blocks for a connection) -- are
# rejected by sudoers and cannot be smuggled in.
#
# Idempotent: re-running detects an identical rule and leaves it untouched. The
# drop-in is validated with `visudo -c -f` before it is installed, and the old
# file is only replaced once the new one passes validation.
#
# Usage:
#   sudo sh ~/.vim/sshsec-install-sudoers.sh                 # install / refresh
#   sudo sh ~/.vim/sshsec-install-sudoers.sh --remove        # remove the rule
#
# Overrides (env, optional):
#   SUDO_GROUP   group granted the exception (default: admin on mac, otherwise
#                %sudo if it exists, else %wheel)
#   SUDO_USER    single user name to scope to instead of a group
#   SSHD_BIN      absolute sshd path (default: /usr/sbin/sshd, or `command -v sshd`)
#   DROPIN        drop-in path (default: /etc/sudoers.d/sshd-t-check)

set -u

DROPIN="${DROPIN:-/etc/sudoers.d/sshd-t-check}"
action="install"
[ "${1:-}" = "--remove" ] && action="remove"

# ----------------------------------------------------------------------------
# Root check
# ----------------------------------------------------------------------------
if [ "$(id -u)" != 0 ]; then
    echo "sshsec-install-sudoers: must run as root (try: sudo sh $0)" 1>&2
    exit 1
fi

# ----------------------------------------------------------------------------
# Remove mode
# ----------------------------------------------------------------------------
if [ "$action" = "remove" ]; then
    if [ -e "$DROPIN" ]; then
        rm -f "$DROPIN"
        echo "Removed $DROPIN"
    else
        echo "Nothing to remove: $DROPIN does not exist"
    fi
    exit 0
fi

# ----------------------------------------------------------------------------
# Resolve the principal (group or user) and the sshd binary
# ----------------------------------------------------------------------------
_os="$(uname -s)"
SSHD_BIN="${SSHD_BIN:-}"
if [ -z "$SSHD_BIN" ]; then
    if [ -x /usr/sbin/sshd ]; then
        SSHD_BIN=/usr/sbin/sshd
    elif command -v sshd >/dev/null 2>&1; then
        SSHD_BIN="$(command -v sshd)"
    else
        echo "sshsec-install-sudoers: sshd binary not found" 1>&2
        exit 1
    fi
fi

principal="${SUDO_USER:-}"
if [ -z "$principal" ]; then
    sudo_group="${SUDO_GROUP:-}"
    if [ -z "$sudo_group" ]; then
        case "$_os" in
            Darwin) sudo_group=admin ;;
            *)
                if getent group sudo >/dev/null 2>&1; then
                    sudo_group=sudo
                elif getent group wheel >/dev/null 2>&1; then
                    sudo_group=wheel
                else
                    echo "sshsec-install-sudoers: could not find a sudo/wheel group on this system; set SUDO_GROUP or SUDO_USER" 1>&2
                    exit 1
                fi
                ;;
        esac
    fi
    principal="%$sudo_group"
fi

# Sanity: a single-user scope should be a bare name (no leading %).
case "$principal" in
    %*) : ;;                       # group principal
    *)  echo "$principal" | grep -Eq '^[A-Za-z_][A-Za-z0-9_-]*$' || {
            echo "sshsec-install-sudoers: invalid SUDO_USER '$principal'" 1>&2
            exit 1
        }
        ;;
esac

# ----------------------------------------------------------------------------
# Build the rule. Pin args to exactly "sshd -T": no wildcards, so additional
# flags are rejected by sudoers.
# ----------------------------------------------------------------------------
marker="# managed by ~/.vim/sshsec-install-sudoers.sh -- do not edit"
new_rule="$principal ALL=(root) NOPASSWD: $SSHD_BIN -T"
new_content="$marker
$new_rule
"

# ----------------------------------------------------------------------------
# Idempotency: skip if an identical rule is already in place.
# ----------------------------------------------------------------------------
if [ -e "$DROPIN" ]; then
    existing_rule="$(grep -v '^#' "$DROPIN" 2>/dev/null | sed 's/[ 	]*$//' | grep -v '^$')"
    if [ "$existing_rule" = "$new_rule" ]; then
        echo "Rule already current in $DROPIN -- nothing to do"
        exit 0
    fi
    echo "Existing rule in $DROPIN differs; replacing."
fi

# ----------------------------------------------------------------------------
# Validate before installing. visudo -c -f returns nonzero on a syntax error.
# ----------------------------------------------------------------------------
tmp="${TMPDIR:-/tmp}/sshsec-sudoers.$$"
printf '%s' "$new_content" > "$tmp"
mode_set=0
if command -v visudo >/dev/null 2>&1; then
    if visudo -c -f "$tmp" >/dev/null 2>&1; then
        mode_set=1
    else
        echo "sshsec-install-sudoers: visudo rejected the generated rule:" 1>&2
        cat "$tmp" 1>&2
        rm -f "$tmp"
        exit 1
    fi
fi

install -m 0440 "$tmp" "$DROPIN" 2>/dev/null || cp "$tmp" "$DROPIN" && chmod 0440 "$DROPIN"
rm -f "$tmp"

# Final paranoia: make sure the live sudoers tree parses with the new file in.
if command -v visudo >/dev/null 2>&1; then
    if ! visudo -c >/dev/null 2>&1; then
        echo "sshsec-install-sudoers: WARNING -- 'visudo -c' reported an error after installing $DROPIN; please inspect." 1>&2
        echo "Rule installed in $DROPIN:"
        cat "$DROPIN"
        exit 1
    fi
fi

echo "Installed $DROPIN:"
cat "$DROPIN"
echo
echo "On the next interactive shell the check should now read 'live sshd -T'."