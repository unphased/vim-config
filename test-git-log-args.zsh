#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/git-log-args-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
source "$script_dir/.aliases.sh" >/dev/null 2>&1

cd "$tmp_dir"
command git init -q -b main
command git config user.name 'Test User'
command git config user.email test@example.com
command git config lgtn.showNotes false
command git config lgtn.remoteTagStatus false
command git config alias.lgtn "!$script_dir/git-lg-tags-notes.sh"
command git config alias.lgf "!$script_dir/git-lg-full.sh"
command git config alias.lgfs "!$script_dir/git-lg-full.sh --stat"
mkdir nested
printf 'base\n' >nested/tracked.txt
printf 'space\n' >'space name.txt'
printf 'gone\n' >deleted.txt
command git add nested/tracked.txt 'space name.txt' deleted.txt
command git commit -qm 'shared base'
command git checkout -qb feature/topic
printf 'feature\n' >>nested/tracked.txt
command git add nested/tracked.txt
command git commit -qm 'feature only -n --all'
command git branch UTF-8
command git checkout -q main
command git rm -q deleted.txt
printf 'main\n' >main.txt
command git add main.txt
command git commit -qm 'main only'
command git branch main.txt feature/topic
command git notes add -m 'inline note'

# Record the final argv, while keeping classification probes and execution real.
git() {
  case "${1-}" in
    lgtn|lgf|lgfs) printf '%s\n' "$@" >"$tmp_dir/argv" ;;
  esac
  command git "$@"
}
failures=0
check_call() {
  local label="$1"
  shift
  local result=0
  "$@" >"$tmp_dir/output" 2>"$tmp_dir/diagnostic" || result=$?
  if (( result != 0 )) || ! diff -u <(printf '%s\n' "${expected[@]}") "$tmp_dir/argv"; then
    print -u2 "FAIL: $label (exit $result)"
    failures=$((failures + 1))
  fi
  if [[ "$(<"$tmp_dir/diagnostic")" != *"git "* ]]; then
    print -u2 "FAIL: $label did not print its assembled command"
    failures=$((failures + 1))
  fi
}

expected=(lgtn --all)
check_call 'default all-branch view' gg
[[ "$(<"$tmp_dir/output")" != *'Notes added'* ]] || failures=$((failures + 1))
expected=(lgtn --stat --all -- .)
check_call 'inferred separator retains notes hiding' ggs .
[[ "$(<"$tmp_dir/output")" != *'Notes added'* ]] || failures=$((failures + 1))
expected=(lgtn --include-notes-dag --stat --all -- .)
check_call 'notes variant still includes notes history' ggsn .
[[ "$(<"$tmp_dir/output")" == *'Notes added'* ]] || failures=$((failures + 1))
expected=(lgtn --include-notes-dag --all -- .)
check_call 'standalone -n still includes notes history' gg -n .
expected=(lgtn --stat --all -- .)
check_call 'explicit separator bypasses notes filtering' ggs --all -- .
[[ "$(<"$tmp_dir/output")" == *'Notes added'* ]] || failures=$((failures + 1))
expected=(lgtn --stat --all -- nested/tracked.txt)
check_call 'automatic path across all refs' ggs nested/tracked.txt
[[ "$(<"$tmp_dir/output")" == *'feature only'* ]] || failures=$((failures + 1))
expected=(lgtn --stat feature/topic)
check_call 'slash-containing branch' ggs feature/topic
expected=(lgtn --stat main feature/topic -- nested/tracked.txt)
check_call 'paths can precede multiple revisions' ggs nested/tracked.txt main feature/topic
expected=(lgtn --stat HEAD --not feature/topic -- nested/tracked.txt)
check_call 'revision operator ordering' ggs HEAD --not feature/topic nested/tracked.txt
expected=(lgtn --stat main..feature/topic)
check_call 'revision range' ggs main..feature/topic
expected=(lgtn -L 1,1:nested/tracked.txt)
check_call 'line history uses native single-commit default' gg -L 1,1:nested/tracked.txt
expected=(lgtn -L1,1:nested/tracked.txt)
check_call 'attached line history also avoids all refs' gg -L1,1:nested/tracked.txt
expected=(lgtn --stat --encoding UTF-8 --all -- nested/tracked.txt)
check_call 'option value also names a branch' ggs --encoding UTF-8 nested/tracked.txt
expected=(lgtn --stat --all -- 'space name.txt' deleted.txt 'nested/*.txt')
check_call 'spaces deleted paths and quoted globs' ggs 'space name.txt' deleted.txt 'nested/*.txt'
expected=(lgtn --stat '--exclude=refs/heads/*' --all -- nested/tracked.txt)
check_call 'exclusions precede inferred all traversal' ggs '--exclude=refs/heads/*' nested/tracked.txt
# --all includes HEAD even when branch refs are excluded, but not feature.
[[ "$(<"$tmp_dir/output")" != *'feature only'* ]] || failures=$((failures + 1))
expected=(lgtn --stat --branches=does-not-exist -- nested/tracked.txt)
check_call 'empty selector must not add all refs' ggs --branches=does-not-exist nested/tracked.txt
expected=(lgtn --stat --max-count=1 --all -- nested/tracked.txt)
check_call 'numeric -n remains commit limit' ggs -n 1 nested/tracked.txt
expected=(lgtn --stat --grep -n --all -- nested/tracked.txt)
check_call 'notes shorthand as option value' ggs --grep -n nested/tracked.txt
[[ "$(<"$tmp_dir/output")" == *'feature only'* ]] || failures=$((failures + 1))
expected=(lgtn --stat --grep --all --all -- nested/tracked.txt)
check_call 'traversal flag as option value' ggs --grep --all nested/tracked.txt
[[ "$(<"$tmp_dir/output")" == *'feature only'* ]] || failures=$((failures + 1))

expected=(lgtn --stat -- nested/tracked.txt)
check_call 'explicit separator disables default all' ggs -- nested/tracked.txt
[[ "$(<"$tmp_dir/output")" != *'feature only'* ]] || failures=$((failures + 1))
expected=(lgtn --stat main.txt --)
check_call 'explicit separator forces revision on collision' ggs main.txt --
expected=(lgtn --stat -- main.txt)
check_call 'explicit separator forces path on collision' ggs -- main.txt
expected=(lgtn --stat --encoding UTF-8 HEAD -- nested/tracked.txt)
check_call 'explicit separator preserves original options' ggs --encoding UTF-8 HEAD -- nested/tracked.txt
expected=(lgtn --stat feature/topic --grep -n -- nested/tracked.txt)
check_call 'passthrough does not intercept option value -n' ggs feature/topic --grep -n -- nested/tracked.txt
[[ "$(<"$tmp_dir/output")" == *'feature only'* ]] || failures=$((failures + 1))
expected=(lgtn --stat feature/topic --grep --all -- nested/tracked.txt)
check_call 'passthrough does not rewrite option value --all' ggs feature/topic --grep --all -- nested/tracked.txt
[[ "$(<"$tmp_dir/output")" == *'feature only'* ]] || failures=$((failures + 1))

if ggs main.txt >"$tmp_dir/output" 2>"$tmp_dir/diagnostic"; then
  print -u2 'FAIL: ambiguous ref/path silently picked one'
  failures=$((failures + 1))
fi
[[ "$(<"$tmp_dir/diagnostic")" == *'both a path and revision'* ]] || failures=$((failures + 1))
if ggs --unsupported-auto-option nested/tracked.txt >/dev/null 2>"$tmp_dir/diagnostic"; then
  print -u2 'FAIL: unknown option was guessed'
  failures=$((failures + 1))
fi
if ggs does-not-exist -- >/dev/null 2>"$tmp_dir/diagnostic"; then
  print -u2 'FAIL: Git revision error was swallowed'
  failures=$((failures + 1))
fi

for helper in ggf ggfs; do
  for flag in -n --include-notes-dag; do
    if "$helper" "$flag" >/dev/null 2>"$tmp_dir/diagnostic"; then
      print -u2 "FAIL: $helper silently discarded $flag"
      failures=$((failures + 1))
    fi
  done
done
expected=(lgf feature/topic -- nested/tracked.txt)
check_call 'full messages share inference' ggf nested/tracked.txt feature/topic
expected=(lgfs --all -- nested/tracked.txt)
check_call 'full-message stats share inference' ggfs nested/tracked.txt
cd nested
expected=(lgtn --stat --all -- tracked.txt)
check_call 'caller-relative stat path' ggs tracked.txt
expected=(lgfs --all -- tracked.txt)
check_call 'caller-relative full-message path' ggfs tracked.txt
[[ "$(<"$tmp_dir/output")" == *'shared base'* && "$(<"$tmp_dir/output")" == *'feature only'* ]] || failures=$((failures + 1))

# A failed formatter must not be hidden by the downstream cat/pager.
mkdir "$tmp_dir/mockbin"
printf '#!/bin/sh\necho formatter-failed >&2\nexit 24\n' >"$tmp_dir/mockbin/awk"
chmod +x "$tmp_dir/mockbin/awk"
if PATH="$tmp_dir/mockbin:$PATH" "$script_dir/git-lg-tags-notes.sh" HEAD -- tracked.txt >/dev/null 2>"$tmp_dir/diagnostic"; then
  print -u2 'FAIL: formatter failure was swallowed'
  failures=$((failures + 1))
fi
[[ "$(<"$tmp_dir/diagnostic")" == *'formatter-failed'* ]] || failures=$((failures + 1))

# Empty inferred path arrays must also work in Bash with nounset enabled.
if ! bash -c 'source "$1" >/dev/null 2>&1; set -eu; cd "$2"; ggs -n 0 HEAD; gg -n 0; ggs -n 1 nested/tracked.txt' _ "$script_dir/.aliases.sh" "$tmp_dir" >/dev/null 2>"$tmp_dir/diagnostic"; then
  print -u2 'FAIL: Bash argument inference with nounset'
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  print -u2 "$failures Git log argument checks failed"
  exit 1
fi
print 'Git log argument inference tests passed'
