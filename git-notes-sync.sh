#!/usr/bin/env bash
#
# git-notes-sync.sh
#
# Sync git notes refs with a remote.
#
# Usage:
#   git gnp [<remote>]        # push refs/notes/* to remote
#   git gnl [<remote>]        # ff-fetch refs/notes/* from remote into local refs
#   git gnm [<remote>]        # reconcile remote notes into local refs (default: union)
#
# Workflow:
#   - After adding/editing notes locally, run `git gnp [remote]` to publish
#     them. Normal branch push/pull does not move notes refs.
#   - Before editing notes in another clone, run `git gnl [remote]` so that
#     clone fast-forwards its local `refs/notes/*` first.
#   - `git gnl` is safe against clobbering local notes: it rejects
#     non-fast-forward updates instead of overwriting your local notes refs.
#   - If `git gnl` or `git gnp` rejects, run `git gnm [remote]` to fetch the
#     remote notes into `refs/notes-sync/<remote>/*` and merge them into your
#     local `refs/notes/*`, then push again with `git gnp [remote]`.
#   - `git gnm` defaults to the `union` merge strategy so both sides are kept.
#     Pass `--strategy manual|ours|theirs|union|cat_sort_uniq` to override.
#   - Only force-push notes refs when you intentionally want local notes
#     history to replace remote history.
#
# Remote selection:
#   - If <remote> is omitted, we try to infer it from @{upstream}. If that
#     fails, and there is exactly 1 remote configured, we use that.

set -euo pipefail

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not in a git repo" >&2; exit 2; }

cmd="${1:-}"
shift || true

case "$cmd" in
  push|pull|merge)
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
merge_strategy="union"

if [[ "$cmd" == "merge" ]]; then
  remote=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--strategy)
        merge_strategy="${2:-}"
        [[ -n "$merge_strategy" ]] || { echo "error: --strategy requires a value" >&2; exit 2; }
        shift 2
        ;;
      -*)
        echo "error: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
      *)
        if [[ -n "$remote" ]]; then
          echo "error: too many arguments" >&2
          usage >&2
          exit 2
        fi
        remote="$1"
        shift
        ;;
    esac
  done
else
  if [[ $# -gt 1 ]]; then
    echo "error: too many arguments" >&2
    usage >&2
    exit 2
  fi
fi

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
notes_sync_prefix="refs/notes-sync/$remote"

if [[ "$cmd" == "push" ]]; then
  if [[ -z "$(git for-each-ref refs/notes --count=1 --format='%(refname)' 2>/dev/null || true)" ]]; then
    echo "gnp: no local refs/notes/* to push"
    exit 0
  fi
  echo "gnp: pushing refs/notes/* -> $remote"
  git push "$remote" "$notes_refspec"
elif [[ "$cmd" == "pull" ]]; then
  echo "gnl: fetching refs/notes/* <- $remote"
  git fetch "$remote" "$notes_refspec"
else
  remote_notes_refspec="refs/notes/*:${notes_sync_prefix}/*"
  echo "gnm: fetching refs/notes/* <- $remote into ${notes_sync_prefix}/*"
  git fetch "$remote" "$remote_notes_refspec"

  remote_refs=()
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    remote_refs+=("$ref")
  done < <(git for-each-ref "$notes_sync_prefix" --format='%(refname)' 2>/dev/null || true)

  if [[ ${#remote_refs[@]} -eq 0 ]]; then
    echo "gnm: no remote refs/notes/* found on $remote"
    exit 0
  fi

  merged=0
  created=0
  unchanged=0

  for remote_ref in "${remote_refs[@]}"; do
    suffix="${remote_ref#${notes_sync_prefix}/}"
    local_ref="refs/notes/$suffix"
    remote_sha="$(git rev-parse --verify "$remote_ref")"
    local_sha="$(git rev-parse -q --verify "$local_ref" 2>/dev/null || true)"

    if [[ -z "$local_sha" ]]; then
      git update-ref "$local_ref" "$remote_sha"
      printf 'gnm: created %s from %s\n' "${local_ref#refs/notes/}" "$remote"
      created=$((created + 1))
      continue
    fi

    if [[ "$local_sha" == "$remote_sha" ]]; then
      printf 'gnm: already up to date %s\n' "${local_ref#refs/notes/}"
      unchanged=$((unchanged + 1))
      continue
    fi

    printf 'gnm: merging %s using %s\n' "${local_ref#refs/notes/}" "$merge_strategy"
    git notes --ref "$local_ref" merge -s "$merge_strategy" "$remote_ref"
    merged=$((merged + 1))
  done

  printf 'gnm: done (%d merged, %d created, %d unchanged)\n' "$merged" "$created" "$unchanged"
fi
