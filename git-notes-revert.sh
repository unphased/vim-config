#!/usr/bin/env bash
#
# git-notes-revert.sh
#
# Revert one or more *notes DAG* commits (refs/notes/* history) by creating a
# single new notes commit that undoes them, and repointing the notes ref.
#
# Why:
#   - `git revert <notes-commit>` only works correctly when HEAD is on the notes
#     ref (otherwise it tries to revert into your main working tree).
#   - This helper does that safely via a temporary worktree.
#
# Usage:
#   git nr [:<notes-ref>|^<notes-ref>|--ref <notes-ref>] <notes-commit>...
#
# Examples:
#   git nr 571f1f7
#   git nr :slu 01766fb  # revert commit(s) on refs/notes/slu
#   git nr --ref refs/notes/commits 571f1f7 8facf9d
#
# Notes:
#   - This rewrites the notes ref by advancing it to a new commit.
#   - If a revert conflicts, the temp worktree is kept for manual resolution.

set -euo pipefail

usage() {
  sed -n '1,160p' "$0" | sed -n '1,/^set -euo pipefail$/p' | sed '$d' | sed 's/^# \{0,1\}//'
}

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not in a git repo" >&2; exit 2; }

notes_ref="refs/notes/commits"
keep_worktree=false
msg=""

positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --keep-worktree)
      keep_worktree=true
      shift
      ;;
    -m|--message)
      msg="${2:-}"
      [[ -n "$msg" ]] || { echo "error: --message requires a value" >&2; exit 2; }
      shift 2
      ;;
    --ref)
      notes_ref="${2:-}"
      [[ -n "$notes_ref" ]] || { echo "error: --ref requires a value" >&2; exit 2; }
      shift 2
      ;;
    :*)
      # Preferred shorthand: :slu -> refs/notes/slu
      notes_ref="refs/notes/${1#:}"
      shift
      ;;
    ^*)
      # Back-compat shorthand: ^slu -> refs/notes/slu
      notes_ref="refs/notes/${1#^}"
      shift
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

expand_notes_ref() {
  local input="$1"
  if [[ "$input" == refs/notes/* ]]; then
    printf '%s' "$input"
  else
    printf 'refs/notes/%s' "$input"
  fi
}

notes_ref="$(expand_notes_ref "$notes_ref")"

if [[ ${#positional[@]} -lt 1 ]]; then
  echo "error: provide at least one notes-commit to revert" >&2
  usage >&2
  exit 2
fi

old_ref="$(git rev-parse -q --verify "$notes_ref" 2>/dev/null || true)"
if [[ -z "$old_ref" ]]; then
  echo "error: notes ref not found: $notes_ref" >&2
  exit 2
fi

commits=()
for c in "${positional[@]}"; do
  sha="$(git rev-parse -q --verify "${c}^{commit}" 2>/dev/null || true)"
  if [[ -z "$sha" ]]; then
    echo "error: invalid commit: $c" >&2
    exit 2
  fi
  commits+=("$sha")
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/git-notes-revert.XXXXXXXX" 2>/dev/null || true)"
if [[ -z "$tmp" || ! -d "$tmp" ]]; then
  echo "error: failed to create temp dir" >&2
  exit 2
fi

cleanup() {
  if [[ "$keep_worktree" == true ]]; then
    echo "nr: kept worktree at $tmp" >&2
    return 0
  fi
  git worktree remove -f "$tmp" >/dev/null 2>&1 || true
  rm -rf "$tmp" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git worktree add --detach "$tmp" "$notes_ref" >/dev/null

shorts=()
for c in "${commits[@]}"; do
  shorts+=("${c:0:7}")
done

if [[ -z "$msg" ]]; then
  msg="notes: revert ${notes_ref#refs/notes/} ${shorts[*]}"
fi

set +e
(
  cd "$tmp" || exit 3
  git revert --no-commit --no-edit "${commits[@]}"
)
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  keep_worktree=true
  echo "nr: revert failed (likely conflict). Resolve in: $tmp" >&2
  echo "nr: then run: git -C \"$tmp\" commit && git update-ref \"$notes_ref\" \$(git -C \"$tmp\" rev-parse HEAD)" >&2
  exit $rc
fi

git -C "$tmp" commit --no-edit -m "$msg" >/dev/null

new_ref="$(git -C "$tmp" rev-parse HEAD)"

git update-ref "$notes_ref" "$new_ref" "$old_ref"

printf 'nr: %s advanced %s -> %s\n' "${notes_ref#refs/notes/}" "${old_ref:0:7}" "${new_ref:0:7}"
