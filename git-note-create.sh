#!/usr/bin/env bash
#
# git-note-create.sh
#
# Quick git-notes writer with a "heading/body" CLI similar to `git ta`.
#
# Usage:
#   git gn [^<notes-ref>] <heading...> [-- <body...>] [@<commit-ish>]
#   git gn --ref <notes-ref> <heading...> [-- <body...>] [--at <commit-ish>]
#
# Shorthands:
#   - `@<commit-ish>` sets the target object (default: HEAD)
#     - `@-<N>` is sugar for `@HEAD~<N>` (e.g. `@-1` -> previous commit)
#   - `^<notes-ref>` or `:<notes-ref>` sets the notes ref (default: refs/notes/commits)
#     If <notes-ref> does not start with `refs/notes/`, it is treated as a
#     short name and expanded to `refs/notes/<notes-ref>`.
#
# Behavior:
#   - Writes an entry to git notes using `append` (so multiple notes accumulate).
#   - The "heading" becomes the first line; optional body becomes subsequent lines.
#
# Options:
#   -e, --edit              Open editor to edit note instead of using args.
#   -R, --replace           Replace existing note (vs append).
#   --ref <notes-ref>       Notes ref to write to.
#   --at <commit-ish>       Commit/object to attach note to.
#   -h, --help              Show help.

set -euo pipefail

usage() {
  sed -n '1,140p' "$0" | sed -n '1,/^set -euo pipefail$/p' | sed '$d' | sed 's/^# \{0,1\}//'
}

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not in a git repo" >&2; exit 2; }

notes_ref="refs/notes/commits"
commitish="HEAD"
commitish_set=false
edit=false
replace=false

positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positional+=(-- "$@")
      break
      ;;
    -e|--edit)
      edit=true
      shift
      ;;
    -R|--replace)
      replace=true
      shift
      ;;
    --ref)
      notes_ref="${2:-}"
      [[ -n "$notes_ref" ]] || { echo "error: --ref requires a value" >&2; exit 2; }
      shift 2
      ;;
    --at)
      commitish="${2:-}"
      [[ -n "$commitish" ]] || { echo "error: --at requires a value" >&2; exit 2; }
      commitish_set=true
      shift 2
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

heading_parts=()
body_parts=()
in_body=false

for arg in "${positional[@]}"; do
  if [[ "$arg" == -- ]]; then
    in_body=true
    continue
  fi

  # After `--`, treat everything literally as note body (no @/^ shorthands).
  if [[ "$in_body" == true ]]; then
    body_parts+=("$arg")
    continue
  fi

  if [[ "$arg" == @* ]]; then
    commitish="${arg#@}"
    if [[ "$commitish" =~ ^-([0-9]+)(.*)$ ]]; then
      commitish="HEAD~${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    fi
    commitish_set=true
    continue
  fi
  if [[ "$arg" =~ ^:[A-Za-z].* ]]; then
    notes_ref="$(expand_notes_ref "${arg#:}")"
    continue
  fi
  if [[ "$arg" == ^* ]]; then
    notes_ref="$(expand_notes_ref "${arg#^}")"
    continue
  fi

  # Convenience: in edit mode, allow a bare commit-ish (no leading `@`) so
  # `gne <sha>` edits the note on that object.
  if [[ "$edit" == true && "$commitish_set" == false ]]; then
    commitish="$arg"
    commitish_set=true
    continue
  fi

  if [[ "$in_body" == true ]]; then
    body_parts+=("$arg")
  else
    heading_parts+=("$arg")
  fi
done

target_sha="$(git rev-parse --verify "${commitish}^{object}" 2>/dev/null || true)"
if [[ -z "$target_sha" ]]; then
  echo "error: invalid object/commit-ish: $commitish" >&2
  exit 2
fi

if [[ "$edit" == true ]]; then
  git notes --ref "$notes_ref" edit "$target_sha"
  printf 'gn: edited note (%s) on %s\n' "${notes_ref#refs/notes/}" "${target_sha:0:12}"
  exit 0
fi

if [[ ${#heading_parts[@]} -eq 0 ]]; then
  echo "error: missing heading (first line of note)" >&2
  usage >&2
  exit 2
fi

heading="${heading_parts[*]}"
body="${body_parts[*]}"
message="$heading"
if [[ -n "$body" ]]; then
  message+=$'\n\n'"$body"
fi

if [[ "$replace" == true ]]; then
  git notes --ref "$notes_ref" add -f -m "$message" "$target_sha"
else
  git notes --ref "$notes_ref" append -m "$message" "$target_sha"
fi

printf 'gn: wrote note (%s) on %s\n' "${notes_ref#refs/notes/}" "${target_sha:0:12}"
