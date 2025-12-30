#!/usr/bin/env bash

# NOTE:
# This is an interactive git log viewer.
# We intentionally DO NOT use: set -euo pipefail
# because broken pipes, early pager exits, etc. are expected behavior.

SEP=$'\x1f'
args=("$@")

git -c color.ui=always log --graph --date-order --abbrev-commit --decorate \
  --pretty=format:"%C(bold magenta)%h%Creset -%C(auto)%d%Creset${SEP}%s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset${SEP}%H" \
  "${args[@]}" \
| awk -v FS="$SEP" '
  function tag_summaries(sha,    cmd, t, a, out) {
    cmd = "git for-each-ref refs/tags --points-at " sha \
          " --format=\"%(refname:short)\t%(objecttype)\t%(contents:subject)\""
    out = ""
    while ((cmd | getline t) > 0) {
      split(t, a, "\t")
      if (a[2] == "tag" && a[3] != "") {
        if (out != "") out = out " | "
        out = out a[1] ": " a[3]
      }
    }
    close(cmd)
    return out
  }

  {
    left  = $1
    right = $2
    sha   = $3

    if (sha == "" || sha !~ /^[0-9a-f]{40}$/) {
      print left " " right
      next
    }

    tags = tag_summaries(sha)

    if (tags != "") {
      print left " \033[36m{ " tags " }\033[0m " right
    } else {
      print left " " right
    }
  }
' \
| LESS='-FRS' less -R

