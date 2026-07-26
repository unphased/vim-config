#!/bin/bash
#
# git-notes-sync.sh
#
# Sync git notes refs with a remote.
#
# Usage:
#   git notes-push [<remote>]    # push refs/notes/* to remote
#   git notes-fetch [<remote>]   # ff-fetch remote notes into local refs
#   git notes-merge [<remote>]   # reconcile remote notes (default: union)
#   git notes-status [<remote>]  # compare local and remote notes history
#
# Workflow:
#   - After adding/editing notes locally, run `git notes-push [remote]` to
#     publish them. Normal branch push/pull does not move notes refs.
#   - Before editing notes in another clone, run `git notes-fetch [remote]` so
#     that clone fast-forwards its local `refs/notes/*` first.
#   - `git notes-fetch` is safe against clobbering local notes: it rejects
#     non-fast-forward updates instead of overwriting your local notes refs.
#   - If `git notes-fetch` or `git notes-push` rejects, run
#     `git notes-merge [remote]` to fetch the remote notes into
#     `refs/notes-sync/<remote>/*` and merge them into your local
#     `refs/notes/*`, then push again with `git notes-push [remote]`.
#   - `git notes-merge` defaults to the `union` merge strategy so both sides
#     are kept. Pass `--strategy manual|ours|theirs|union|cat_sort_uniq` to
#     override.
#   - `git notes-status` refreshes `refs/notes-sync/<remote>/*`, then reports
#     local-only and remote-only history plus the number of attached objects
#     whose notes differ. It does not change local `refs/notes/*` or the remote.
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
  push|fetch|merge|status)
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
  echo "usage: git notes-{push,fetch,merge,status} <remote>" >&2
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
remote_notes_refspec="+refs/notes/*:${notes_sync_prefix}/*"

if [[ "$cmd" == "push" ]]; then
  if [[ -z "$(git for-each-ref refs/notes --count=1 --format='%(refname)' 2>/dev/null || true)" ]]; then
    echo "notes-push: no local refs/notes/* to push"
    exit 0
  fi
  echo "notes-push: pushing refs/notes/* -> $remote"
  git push "$remote" "$notes_refspec"
elif [[ "$cmd" == "fetch" ]]; then
  echo "notes-fetch: fetching refs/notes/* <- $remote"
  git fetch "$remote" "$notes_refspec"
elif [[ "$cmd" == "status" ]]; then
  echo "notes-status: refreshing refs/notes/* <- $remote"
  git fetch --quiet --prune "$remote" "$remote_notes_refspec"

  notes_names="$(
    {
      git for-each-ref refs/notes --format='%(refname)' \
        | sed 's#^refs/notes/##'
      git for-each-ref "$notes_sync_prefix" --format='%(refname)' \
        | sed "s#^${notes_sync_prefix}/##"
    } | sort -u
  )"

  if [[ -z "$notes_names" ]]; then
    echo "notes-status: no local or remote refs/notes/* found"
    exit 0
  fi

  while IFS= read -r name; do
    local_ref="refs/notes/$name"
    remote_ref="${notes_sync_prefix}/$name"
    local_sha="$(git rev-parse -q --verify "$local_ref" 2>/dev/null || true)"
    remote_sha="$(git rev-parse -q --verify "$remote_ref" 2>/dev/null || true)"

    if [[ -z "$remote_sha" ]]; then
      local_commits="$(git rev-list --count "$local_ref")"
      local_objects="$(git ls-tree -r --name-only "$local_ref" | wc -l | tr -d ' ')"
      printf 'notes-status: %s: not on remote (local-only commits: %s; attached objects: %s)\n' \
        "$name" "$local_commits" "$local_objects"
      continue
    fi

    if [[ -z "$local_sha" ]]; then
      remote_commits="$(git rev-list --count "$remote_ref")"
      remote_objects="$(git ls-tree -r --name-only "$remote_ref" | wc -l | tr -d ' ')"
      printf 'notes-status: %s: missing locally (remote-only commits: %s; attached objects: %s)\n' \
        "$name" "$remote_commits" "$remote_objects"
      continue
    fi

    if [[ "$local_sha" == "$remote_sha" ]]; then
      attached_objects="$(git ls-tree -r --name-only "$local_ref" | wc -l | tr -d ' ')"
      printf 'notes-status: %s: up to date (attached objects: %s)\n' "$name" "$attached_objects"
      continue
    fi

    read -r local_only remote_only < <(
      git rev-list --left-right --count "$local_ref...$remote_ref"
    )
    changed_objects="$(
      git diff --name-only "$remote_ref" "$local_ref" | wc -l | tr -d ' '
    )"

    if [[ "$remote_only" -eq 0 ]]; then
      printf 'notes-status: %s: remote behind (local-only commits: %s; differing attached objects: %s)\n' \
        "$name" "$local_only" "$changed_objects"
    elif [[ "$local_only" -eq 0 ]]; then
      printf 'notes-status: %s: local behind (remote-only commits: %s; differing attached objects: %s)\n' \
        "$name" "$remote_only" "$changed_objects"
    else
      printf 'notes-status: %s: diverged (local-only commits: %s; remote-only commits: %s; differing attached objects: %s)\n' \
        "$name" "$local_only" "$remote_only" "$changed_objects"
    fi
  done <<<"$notes_names"
else
  echo "notes-merge: fetching refs/notes/* <- $remote into ${notes_sync_prefix}/*"
  git fetch --prune "$remote" "$remote_notes_refspec"

  remote_refs=()
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    remote_refs+=("$ref")
  done < <(git for-each-ref "$notes_sync_prefix" --format='%(refname)' 2>/dev/null || true)

  if [[ ${#remote_refs[@]} -eq 0 ]]; then
    echo "notes-merge: no remote refs/notes/* found on $remote"
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
      printf 'notes-merge: created %s from %s\n' "${local_ref#refs/notes/}" "$remote"
      created=$((created + 1))
      continue
    fi

    if [[ "$local_sha" == "$remote_sha" ]]; then
      printf 'notes-merge: already up to date %s\n' "${local_ref#refs/notes/}"
      unchanged=$((unchanged + 1))
      continue
    fi

    printf 'notes-merge: merging %s using %s\n' "${local_ref#refs/notes/}" "$merge_strategy"
    git notes --ref "$local_ref" merge -s "$merge_strategy" "$remote_ref"
    merged=$((merged + 1))
  done

  printf 'notes-merge: done (%d merged, %d created, %d unchanged)\n' "$merged" "$created" "$unchanged"
fi
