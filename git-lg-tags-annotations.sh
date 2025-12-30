#!/usr/bin/env bash
#
# git-lg-tags-annotations.sh
#
# Dense, “subway graph” git log that also shows *annotated tag subjects*
# inline, right after the normal decoration list (%d).
#
# Why:
#   - Your commits are high-velocity (AI generated).
#   - You want a manual “signal” channel without fighting the commit messages.
#   - Annotated tags are perfect: they are named pointers with a message.
#
# What it does:
#   1) Run `git log --graph` with a custom pretty format.
#   2) For each commit line, extract the full commit SHA.
#   3) Ask git: “which tags point at this SHA?”
#   4) For annotated tags only, take the first line of the annotation
#      and inject it into the log output immediately after %d.
#   5) Page through `less` with colors preserved.
#
# Notes:
#   - Lightweight tags have no annotation message. We ignore them.
#   - If you quit `less` early, awk can get SIGPIPE and complain; we
#     silence awk stderr because that’s expected for an interactive viewer.

# A rarely-used ASCII control character used to separate fields safely.
# We want to split the output line into multiple fields without risking
# collisions with normal text.
SEP=$'\x1f'

###############################################################################
# Step 1: Produce a 3-field log line for each commit
###############################################################################
#
# We print 3 “fields” separated by SEP:
#   field 1: "<abbrev-hash> -<decorations>"    (includes tags/branches via %d)
#   field 2: "<commit subject + time + author>"
#   field 3: "<full 40-hex SHA>"              (used to look up tags)
#
# Field 3 is hidden from the user later; it’s only to support lookups.
#
# `-c color.ui=always` forces color even when piped.

git -c color.ui=always log \
  --graph \
  --date-order \
  --abbrev-commit \
  --decorate \
  --pretty=format:"%C(bold magenta)%h%Creset -%C(auto)%d%Creset${SEP}%s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset${SEP}%H" \
  "$@" \
| awk -v FS="$SEP" '
  #############################################################################
  # Helper: collect annotated tag subjects for a given commit SHA
  #############################################################################
  #
  # We run:
  #   git for-each-ref refs/tags --points-at <sha> --format="name<TAB>type<TAB>subject"
  #
  # Where:
  #   %(refname:short)    -> tag name (e.g., deployed/prod-...)
  #   %(objecttype)       -> "tag" for annotated tags, "commit" for lightweight
  #   %(contents:subject) -> first line of the tag annotation message
  #
  # We return a single summary string, like:
  #   "tag1: subject | tag2: subject"
  #
  function tag_summaries(sha,    cmd, t, a, out) {
    cmd = "git for-each-ref refs/tags --points-at " sha \
          " --format=\"%(refname:short)\t%(objecttype)\t%(contents:subject)\""

    out = ""

    # Read each matching tag line from the command output.
    while ((cmd | getline t) > 0) {
      split(t, a, "\t")
      # a[1] = tag name
      # a[2] = objecttype ("tag" or "commit")
      # a[3] = tag annotation subject (first line), if any

      # Only annotated tags ("tag") have message content worth showing.
      if (a[2] == "tag" && a[3] != "") {
        if (out != "") out = out " | "
        out = out a[1] ": " a[3]
      }
    }

    close(cmd)
    return out
  }

  #############################################################################
  # Main: rewrite each log line
  #############################################################################
  #
  # Input fields from git log:
  #   $1 = "<abbrev-hash> - (decorations...)"
  #   $2 = "<commit subject + timestamp + author...>"
  #   $3 = "<full SHA>"
  #
  # Output:
  #   - If no annotated tags: print "$1 $2"
  #   - If annotated tags exist: print "$1 {tags} $2"
  #
  {
    left  = $1  # hash + decorations (%d lives here)
    right = $2  # subject + times + author
    sha   = $3  # full commit SHA

    # Defensive: if a line somehow lacks SHA, just print it unchanged.
    if (sha == "" || sha !~ /^[0-9a-f]{40}$/) {
      print left " " right
      next
    }

    tags = tag_summaries(sha)

    if (tags != "") {
      # Cyan block inserted immediately after decorations.
      # This is the key “move”: it sits next to the tag names in %d,
      # not at the end of the line.
      print left " \033[36m{ " tags " }\033[0m " right
    } else {
      print left " " right
    }
  }
' 2>/dev/null \
| LESS='-FRS' less -R

