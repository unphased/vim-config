#!/usr/bin/env bash
#
# git-lg-tags-annotations.sh
#
# Dense, “subway graph” git log that also shows *annotated tag subjects*
# inline, inside the normal decoration parens area (next to `tag: ...`).
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
#   4) For annotated tags only, take the first line of the annotation and
#      inject it next to the corresponding `tag: <name>` decoration.
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
# Step 1: Produce a multi-field log line for each commit
###############################################################################
#
# We print multiple “fields” separated by SEP:
#   field 1: "<abbrev-hash> -"                  (graph prefix included)
#   field 2: "<start decoration color seq>"     (%C(auto))
#   field 3: "<decorations>"                    (%d, branches only)
#   field 4: "<reset color seq>"                (%Creset)
#   field 5: "<commit subject + time + author>"
#   field 6: "<full 40-hex SHA>"                (used to look up tags)
#
# Field 6 is hidden from the user later; it’s only to support lookups.
#
# `-c color.ui=always` forces color even when piped.

TAG_COLOR=$(
  git config --get-color color.decorate.tag "yellow" 2>/dev/null \
    || printf '\033[33m'
)
ANNO_COLOR=$(
  git config --get-color color.lgt.annotation "cyan" 2>/dev/null \
    || printf '\033[36m'
)
UNPUSHED_COLOR=$(
  git config --get-color color.lgt.unpushed "red bold" 2>/dev/null \
    || printf '\033[1;31m'
)

gitdir="$(git rev-parse --git-dir 2>/dev/null || true)"
unpushed_file=""
if [[ -n "$gitdir" ]]; then
  unpushed_file="${gitdir}/lgt-unpushed-tags"
fi

git -c color.ui=always log \
  --graph \
  --date-order \
  --abbrev-commit \
  --decorate \
  --decorate-refs-exclude=refs/tags \
  --pretty=format:"%C(bold magenta)%h%Creset -${SEP}%C(auto)${SEP}%d${SEP}%Creset${SEP}%s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset${SEP}%H" \
  "$@" \
| awk -v FS="$SEP" -v TAG_COLOR="$TAG_COLOR" -v ANNO_COLOR="$ANNO_COLOR" -v UNPUSHED_COLOR="$UNPUSHED_COLOR" -v UNPUSHED_FILE="$unpushed_file" '
  BEGIN {
    if (UNPUSHED_FILE != "") {
      while ((getline line < UNPUSHED_FILE) > 0) {
        if (line != "") unpushed[line] = 1
      }
      close(UNPUSHED_FILE)
    }
  }

  #############################################################################
  # Helpers
  #############################################################################
  function ltrim(s) { sub(/^[[:space:]]+/, "", s); return s }

  function insert_before_last_paren(s, addition,    i) {
    for (i = length(s); i > 0; i--) {
      if (substr(s, i, 1) == ")") {
        return substr(s, 1, i - 1) addition substr(s, i)
      }
    }
    return s addition
  }

  # Load annotated tag subjects for a commit SHA.
  #
  # We run:
  #   git for-each-ref refs/tags --points-at <sha> --format="name<TAB>type<TAB>subject"
  #
  # Where:
  #   %(refname:short)    -> tag name (e.g., deployed/prod-...)
  #   %(objecttype)       -> "tag" for annotated tags, "commit" for lightweight
  #   %(contents:subject) -> first line of the tag annotation message
  #
  # Populates:
  #   subjects[tagname] = subject
  #   order[1..n]       = tagname (stable-ish ordering from git)
  #
  function load_tag_subjects(sha, subjects, order,    cmd, t, a, n, tag, subj, prefix) {
    cmd = "git for-each-ref refs/tags --points-at " sha \
          " --format=\"%(refname:short)\t%(objecttype)\t%(contents:subject)\""

    n = 0
    while ((cmd | getline t) > 0) {
      split(t, a, "\t")
      tag  = a[1]
      subj = ""

      if (tag == "") continue

      # Only annotated tags ("tag") have their own annotation message.
      if (a[2] == "tag") {
        subj = a[3]
        if (subj != "") {
          # If the subject redundantly starts with the tag name, strip it.
          prefix = tag ":"
          if (substr(subj, 1, length(prefix)) == prefix) {
            subj = ltrim(substr(subj, length(prefix) + 1))
          } else {
            prefix = tag " -"
            if (substr(subj, 1, length(prefix)) == prefix) {
              subj = ltrim(substr(subj, length(prefix) + 1))
            }
          }
        }
      }

      subjects[tag] = subj
      order[++n] = tag
    }

    close(cmd)
    return n
  }

  #############################################################################
  # Main: rewrite each log line
  #############################################################################
  #
  {
    left             = $1  # hash + trailing " -"
    deco_color_start = $2  # start color seq for decorations
    deco_text        = $3  # %d (leading space + parens), may be empty
    color_reset      = $4  # reset seq (also used when we temporarily colorize)
    right            = $5  # subject + times + author
    sha_raw          = $6  # full commit SHA (may have --graph/--stat trailing chars)

    sha = ""
    if (sha_raw ~ /^[0-9a-f]{40}/) {
      sha = substr(sha_raw, 1, 40)
    }

    # Defensive: if a line somehow lacks SHA, just print it unchanged.
    if (sha == "") {
      print left deco_color_start deco_text color_reset " " right
      next
    }

    delete subjects
    delete order
    n = load_tag_subjects(sha, subjects, order)

    if (n > 0) {
      anno_color = ANNO_COLOR
      tag_color = TAG_COLOR
      unpushed_color = UNPUSHED_COLOR
      tag_block = ""

      for (i = 1; i <= n; i++) {
        tag = order[i]
        subj = subjects[tag]
        if (tag == "") continue

        if (tag_block != "") tag_block = tag_block ", "
        tag_block = tag_block "tag: " tag
        if (tag in unpushed) {
          tag_block = tag_block " " unpushed_color "UNPUSHED" color_reset tag_color
        }
        if (subj != "") tag_block = tag_block " " anno_color subj color_reset tag_color
      }

      if (tag_block != "") {
        if (deco_text != "") {
          deco_text = insert_before_last_paren(deco_text, ", " tag_color tag_block)
        } else {
          deco_text = tag_color " (" tag_block ")"
        }
      }
    }

    print left deco_color_start deco_text color_reset " " right
  }
' 2>/dev/null \
| LESS='-FRS' less -R
