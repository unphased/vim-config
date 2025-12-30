#!/usr/bin/env bash
#
# git-tag-annotate.sh
#
# Create an annotated tag with a short annotation (subject = first line).
#
# Usage:
#   git ta <tag> [<commit-ish>]
#   git ta <tag> [<commit-ish>] -- <message...>
#   git ta -m "message" <tag> [<commit-ish>]
#
# Options:
#   -m, --message <msg>     Use <msg> as the annotation message.
#   -F, --file <path>       Read the annotation message from <path>.
#   --at <commit-ish>       Target commit (default: HEAD).
#   -f, --force             Replace tag if it already exists.
#   -p, --push              Push the created tag to the remote.
#   -r, --remote <name>     Remote to push to (default: origin).
#   -h, --help              Show help.
#
# Notes:
#   - If no message is provided, git will open $GIT_EDITOR/$EDITOR for you.
#   - The first line of the message is what `git lgt` shows inline.

set -euo pipefail

usage() {
  sed -n '1,120p' "$0" | sed -n '1,/^set -euo pipefail$/p' | sed '$d' | sed 's/^# \{0,1\}//'
}

remote="origin"
push=false
force=false
commitish="HEAD"
message=""
message_file=""

positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -p|--push)
      push=true
      shift
      ;;
    -r|--remote)
      remote="${2:-}"
      [[ -n "$remote" ]] || { echo "error: --remote requires a value" >&2; exit 2; }
      shift 2
      ;;
    -f|--force)
      force=true
      shift
      ;;
    --at)
      commitish="${2:-}"
      [[ -n "$commitish" ]] || { echo "error: --at requires a commit-ish" >&2; exit 2; }
      shift 2
      ;;
    -m|--message)
      message="${2:-}"
      [[ -n "$message" ]] || { echo "error: --message requires a value" >&2; exit 2; }
      shift 2
      ;;
    -F|--file)
      message_file="${2:-}"
      [[ -n "$message_file" ]] || { echo "error: --file requires a path" >&2; exit 2; }
      shift 2
      ;;
    --)
      shift
      if [[ $# -gt 0 ]]; then
        message="$*"
      fi
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

if [[ ${#positional[@]} -lt 1 ]]; then
  usage >&2
  exit 2
fi

tag="${positional[0]}"
if [[ ${#positional[@]} -ge 2 ]]; then
  commitish="${positional[1]}"
fi

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not in a git repo" >&2; exit 2; }

target_sha="$(git rev-parse --verify "${commitish}^{commit}" 2>/dev/null || true)"
if [[ -z "$target_sha" ]]; then
  echo "error: invalid commit-ish: $commitish" >&2
  exit 2
fi

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  if [[ "$force" != true ]]; then
    echo "error: tag already exists: $tag (use --force to replace)" >&2
    exit 1
  fi
  git tag -d "$tag" >/dev/null
fi

tag_args=(tag -a "$tag" "$target_sha")

if [[ -n "$message_file" ]]; then
  [[ -f "$message_file" ]] || { echo "error: message file not found: $message_file" >&2; exit 2; }
  tag_args+=(-F "$message_file")
elif [[ -n "$message" ]]; then
  tag_args+=(-m "$message")
fi

git "${tag_args[@]}"

if [[ "$push" == true ]]; then
  git push "$remote" "refs/tags/$tag"
fi

printf 'ta: created %s at %s\n' "$tag" "${target_sha:0:12}"
