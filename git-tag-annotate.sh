#!/usr/bin/env bash
#
# git-tag-annotate.sh
#
# Create an annotated tag for quick human notes (subject = first line).
#
# Usage:
#   git ta <category> <heading...> [-- <body...>] [@<commit-ish>]
#
# Examples:
#   git ta deployed/prod Deployed at 2025-12-11T22:47:23+07:00
#   git ta note Investigate CI flake -- likely due to cache race @HEAD~2
#   git tap note Hotfix deployed -- see incident 1234
#
# Options:
#   --at <commit-ish>       Target commit (default: HEAD). Shorthand: @<commit-ish>
#   --tag <name>            Override generated tag name.
#   -f, --force             Replace tag if it already exists.
#   -e, --edit              Open editor to edit the message before saving.
#   -p, --push              Push the created tag to the remote.
#   -r, --remote <name>     Remote to push to (default: origin).
#   -h, --help              Show help.
#
# Notes:
#   - We generate a tag name: <category>-<N> (N increments per category).
#   - The first line (“heading”) is what `git lgt` shows inline.

set -euo pipefail

usage() {
  sed -n '1,120p' "$0" | sed -n '1,/^set -euo pipefail$/p' | sed '$d' | sed 's/^# \{0,1\}//'
}

remote="origin"
push=false
force=false
commitish="HEAD"
tag_override=""
edit=false

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
    -e|--edit)
      edit=true
      shift
      ;;
    --at)
      commitish="${2:-}"
      [[ -n "$commitish" ]] || { echo "error: --at requires a commit-ish" >&2; exit 2; }
      shift 2
      ;;
    --tag)
      tag_override="${2:-}"
      [[ -n "$tag_override" ]] || { echo "error: --tag requires a value" >&2; exit 2; }
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

if [[ ${#positional[@]} -lt 2 ]]; then
  usage >&2
  exit 2
fi

category="${positional[0]}"

heading_parts=()
body_parts=()
in_body=false

for ((i=1; i<${#positional[@]}; i++)); do
  arg="${positional[i]}"
  if [[ "$arg" == -- ]]; then
    in_body=true
    continue
  fi
  if [[ "$arg" == @* ]]; then
    commitish="${arg#@}"
    continue
  fi

  if [[ "$in_body" == true ]]; then
    body_parts+=("$arg")
  else
    heading_parts+=("$arg")
  fi
done

if [[ ${#heading_parts[@]} -eq 0 ]]; then
  echo "error: missing heading (first line of annotation)" >&2
  usage >&2
  exit 2
fi

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not in a git repo" >&2; exit 2; }

target_sha="$(git rev-parse --verify "${commitish}^{commit}" 2>/dev/null || true)"
if [[ -z "$target_sha" ]]; then
  echo "error: invalid commit-ish: $commitish" >&2
  exit 2
fi

sanitize_category() {
  local input="$1"
  local output
  output="$(printf '%s' "$input" | tr ' ' '-' | tr -c 'A-Za-z0-9._/-' '-')"
  output="$(
    printf '%s' "$output" | sed -E '
      s/-+/-/g;
      s#/+#/#g;
      s#^/##;
      s#/$##;
      s/^-+//;
      s/-+$//;
    '
  )"
  printf '%s' "$output"
}

category="$(sanitize_category "$category")"
if [[ -z "$category" ]]; then
  echo "error: invalid/empty category after sanitization" >&2
  exit 2
fi

next_category_tag_number() {
  local prefix="$1"
  local max=0
  local name suffix

  while IFS= read -r name; do
    [[ "$name" == "$prefix-"* ]] || continue
    suffix="${name#"$prefix-"}"
    [[ -n "$suffix" ]] || continue
    [[ "$suffix" =~ ^[0-9]+$ ]] || continue
    (( suffix > max )) && max=$suffix
  done < <(git for-each-ref --format='%(refname:short)' "refs/tags/${prefix}-*" 2>/dev/null || true)

  printf '%s' "$((max + 1))"
}

tag="$tag_override"
if [[ -z "$tag" ]]; then
  n="$(next_category_tag_number "$category")"
  tag="${category}-${n}"

  while git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; do
    n=$((n + 1))
    tag="${category}-${n}"
  done
else
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    if [[ "$force" != true ]]; then
      echo "error: tag already exists: $tag (use --force to replace)" >&2
      exit 1
    fi
    git tag -d "$tag" >/dev/null
  fi
fi

heading="${heading_parts[*]}"
body="${body_parts[*]}"
message="$heading"
if [[ -n "$body" ]]; then
  message+=$'\n\n'"$body"
fi

tag_args=(tag -a "$tag" "$target_sha" -m "$message")
if [[ "$edit" == true ]]; then
  tag_args+=(-e)
fi

git "${tag_args[@]}"

if [[ "$push" == true ]]; then
  git push "$remote" "refs/tags/$tag"
fi

printf 'ta: created %s at %s\n' "$tag" "${target_sha:0:12}"
