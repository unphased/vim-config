#!/bin/bash
#
# git-lg-full.sh
#
# Subway-graph log with the complete commit message (subject and body).
# The --stat width is passed explicitly because git log is piped through the
# pager here and otherwise falls back to an 80-column assumption.

set -eu

stat_width_args=()
stat_requested=false
for arg in "$@"; do
  case "$arg" in
    --stat|--stat=*|--patch-with-stat|--patch-with-stat=*)
      stat_requested=true
      break
      ;;
  esac
done

if [[ "$stat_requested" == true ]]; then
  stat_cols="${GIT_STAT_WIDTH:-}"
  if [[ -z "$stat_cols" ]]; then
    term_size=""
    term_cols=""

    if command -v stty >/dev/null 2>&1 && [[ -r /dev/tty ]]; then
      term_size="$(stty size </dev/tty 2>/dev/null || true)"
      term_cols="${term_size##* }"
    fi

    if [[ ! "$term_cols" =~ ^[0-9]+$ ]] || [[ "$term_cols" -le 0 ]]; then
      term_cols="${COLUMNS:-}"
    fi

    if [[ "$term_cols" =~ ^[0-9]+$ ]] && [[ "$term_cols" -gt 0 ]]; then
      stat_cols="$term_cols"
      # Leave room for the variable-width subway graph prefix.
      if (( stat_cols > 7 )); then
        stat_cols=$((stat_cols - 7))
      fi
    fi
  fi

  if [[ "$stat_cols" =~ ^[0-9]+$ ]] && [[ "$stat_cols" -gt 0 ]]; then
    stat_width_args=(--stat-width="$stat_cols" --stat-name-width="$stat_cols")
  fi
fi

run_log() {
  git --no-pager -c color.ui=always log \
    --no-notes \
    --graph \
    --date-order \
    --abbrev-commit \
    --decorate \
    --pretty=format:"%C(bold magenta)%h%Creset -%C(auto)%d%Creset %s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset%n%b" \
    ${stat_width_args[@]+"${stat_width_args[@]}"} \
    "$@"
}

if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then
  set +e
  run_log | LESS='-FRS' less -R
  pipeline_status=("${PIPESTATUS[@]}")
  set -e

  # Quitting less early closes its pipe; treat git's resulting SIGPIPE as
  # success, but still report real git or pager failures.
  if (( pipeline_status[1] != 0 )); then
    exit "${pipeline_status[1]}"
  fi
  if (( pipeline_status[0] != 0 && pipeline_status[0] != 141 )); then
    exit "${pipeline_status[0]}"
  fi
else
  run_log
fi
