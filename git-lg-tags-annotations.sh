#!/usr/bin/env bash
#
# git-lgt
#
# Purpose:
#   A readable replacement for a giant git alias.
#   Shows a dense `git log --graph` view, and for commits that have
#   *annotated tags*, injects a short human-written note right after
#   the tag list in the log output.
#
# Why:
#   - Commits are written by an AI at very high velocity.
#   - Annotated tags act as manual "checkpoints" or "signals".
#   - We want to see those signals inline in the history graph.
#
# Design constraints:
#   - Must behave like a normal pager (less).
#   - Broken pipes / quitting early are expected.
#   - No reliance on PATH; called via a hard-coded alias.
#   - Only show the *first line* of tag annotations (subjects).
#   - Do NOT show anything for lightweight tags (they have no message).

###############################################################################
# Configuration
###############################################################################

# A rarely-used ASCII control character used as a safe field separator
# between parts of the `git log` output.
SEP=$'\x1f'

# Pass through any arguments given to `git lgt`
# (e.g. -n 100, --since=..., pathspecs, etc.)
args=("$@")

###############################################################################
# Git log phase
###############################################################################
#
# We emit three logical fields per commit, separated by SEP:
#
#   field 1: "<hash> - (decorations)"
#   field 2: "<subject> <date> <author>"
#   field 3: "<full 40-char commit SHA>"
#
# Fields 1 and 2 are already colorized by git.
# Field 3 is used internally to look up tags.

git -c color.ui=always log \
  --graph \
  --date-order \
  --abbrev-commit \
  --decorate \
  --pretty=format:"%C(bold magenta)%h%Creset -%C(auto)%d%Creset${SEP}%s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset${SEP}%H" \
  "${args[@]}" \
| awk -v FS="$SEP" '

###############################################################################
# awk helper: collect annotated tag subjects for a commit
###############################################################################
#
# Given a commit SHA, query all tags that point *exactly* at it.
# For each tag:
#   - objecttype == "tag"   → annotated tag
#   - objecttype == "commit" → lightweight tag (ignored)
#
# We return a string like:
#   "signal/2025-12-30: auth refactor stable | deployed/prod: live"
#
function tag_summaries(sha,    cmd, t, a, out) {
  cmd = "git for-each-ref refs/tags --points-at " sha \
        " --format=\"%(refname:short)\t%(objecttype)\t%(contents:subject)\""

  out = ""

  # Read each matching tag line from git
  while ((cmd | getline t) > 0) {
    split(t, a, "\t")

    # a[1] = tag name
    # a[2] = object type ("tag" or "commit")
    # a[3] = annotation subject (first line)

    # Only annotated tags ("tag") have meaningful annotations
    if (a[2] == "tag" && a[3] != "") {
      if (out != "") out = out " | "
      out = out a[1] ": " a[3]
    }
  }

  close(cmd)
  return out
}

###############################################################################
# Main awk processing loop
###############################################################################
#
# For each line from git log:
#   - Extract the three fields
#   - If this is not a real commit line, print it unchanged
#   - Otherwise, look for annotated tags
#   - If found, inject them *after* the decoration block

{
  left  = $1   # "<hash> - (decorations)"
  right = $2   # "<subject> <time> <author>"
  sha   = $3   # full commit SHA

  # Defensive: some graph continuation lines may not have a SHA
  if (sha == "" || sha !~ /^[0-9a-f]{40}$/) {
    print left " " right
    next
  }

  tags = tag_summaries(sha)

  if (tags != "") {
    # Insert the tag annotation summary in cyan
    # immediately after the decoration block
    print left " \033[36m{ " tags " }\033[0m " right
  } else {
    # No annotated tags → print the original line
    print left " " right
  }
}
' \
###############################################################################
# Pager
###############################################################################
#
# -R : pass through ANSI color codes
# -F : quit if output fits on one screen
# -S : disable line wrapping (horizontal scroll instead)

| LESS='-FRS' less -R

