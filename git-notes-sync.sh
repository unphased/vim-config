#!/usr/bin/env bash
#
# git-notes-sync.sh
#
# Sync git notes refs with a remote.
#
# Usage:
#   git gnp [<remote>]        # push refs/notes/* to remote
#   git gnl [<remote>]        # fetch refs/notes/* from remote
#
# Notes:
#   - If <remote> is omitted, we try to infer it from @{upstream}. If that
#     fails, and there is exactly 1 remote configured, we use that.
#   - If notes refs have diverged, fetch/push may be rejected; in that case,
#     you likely want to `git fetch <remote> 'refs/notes/*:refs/notes/<remote>/*'`
#     and then merge notes refs explicitly.

set -euo pipefail

usage() {
  sed -n '1,120p' "$0" | sed -n '1,/^set -euo pipefail$/p' | sed '$d' | sed 's/^# \{0,1\}//'
}

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not in a git repo" >&2; exit 2; }

cmd="${1:-}"
shift || true

case "$cmd" in
  push|pull)
    ;;
  -h|--help|"")
    usage
    exit 0
    ;;
  *)
    echo "error: unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac

remote="${1:-}"

infer_remote_from_upstream() {
  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
  [[ -n "$upstream" && "$upstream" == */* ]] || return 1
  printf '%s' "${upstream%%/*}"
}

infer_remote_if_unambiguous() {
  local inferred remotes_count remotes_list

  inferred="$(infer_remote_from_upstream || true)"
  if [[ -n "$inferred" ]]; then
    printf '%s' "$inferred"
    return 0
  fi

  remotes_list="$(git remote 2>/dev/null || true)"
  remotes_count="$(printf '%s\n' "$remotes_list" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$remotes_count" == "1" ]]; then
    printf '%s' "$remotes_list"
    return 0
  fi

  return 1
}

if [[ -z "$remote" ]]; then
  remote="$(infer_remote_if_unambiguous || true)"
fi

if [[ -z "$remote" ]]; then
  echo "error: missing remote" >&2
  echo "usage: git gnp <remote> | git gnl <remote>" >&2
  echo "hint: set an upstream (git branch -u <remote>/<branch>) to omit <remote>" >&2
  echo "remotes:" >&2
  git remote -v >&2 || true
  exit 2
fi

git remote get-url "$remote" >/dev/null 2>&1 || {
  echo "error: unknown remote: $remote" >&2
  echo "remotes:" >&2
  git remote -v >&2 || true
  exit 2
}

notes_refspec="refs/notes/*:refs/notes/*"

if [[ "$cmd" == "push" ]]; then
  if [[ -z "$(git for-each-ref refs/notes --count=1 --format='%(refname)' 2>/dev/null || true)" ]]; then
    echo "gnp: no local refs/notes/* to push"
    exit 0
  fi
  echo "gnp: pushing refs/notes/* -> $remote"
  git push "$remote" "$notes_refspec"
else
  echo "gnl: fetching refs/notes/* <- $remote"
  git fetch "$remote" "$notes_refspec"
fi

