#!/usr/bin/env bash
#
# git-lg-tags-notes.sh
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
#   - When you pass `--all`, git will normally include `refs/notes/*` histories
#     (git’s internal notes DAG commits) which is often too noisy; this script
#     hides those by default unless you pass `--include-notes-dag`.

# A rarely-used ASCII control character used to separate fields safely.
# We want to split the output line into multiple fields without risking
# collisions with normal text.
SEP=$'\x1f'

###############################################################################
# Args: default to hiding the notes DAG in `--all` views
###############################################################################
#
# If you want to browse the notes DAG commits themselves, run:
#   git lgtn --all --include-notes-dag
#
# Notes are still shown inline (via `git notes ...`) even when the notes DAG
# commits are excluded from the main log traversal.

include_notes_dag=false
log_args=()

for arg in "$@"; do
  case "$arg" in
    --include-notes-dag)
      include_notes_dag=true
      ;;
    *)
      log_args+=("$arg")
      ;;
  esac
done

has_all=false
for arg in "${log_args[@]}"; do
  [[ "$arg" == "--all" ]] && { has_all=true; break; }
done

if [[ "$has_all" == true && "$include_notes_dag" == false ]]; then
  # `--all` includes every ref under `refs/` (including `refs/notes/*`), which
  # makes the output very noisy. We treat `--all` as “branches + remotes + tags”
  # for the default view, and reserve the true “all refs (including notes DAG)”
  # behavior for `--include-notes-dag`.
  filtered=()
  for arg in "${log_args[@]}"; do
    [[ "$arg" == "--all" ]] && continue
    filtered+=("$arg")
  done
  log_args=("${filtered[@]}" --branches --remotes --tags)
fi

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
  git config --get-color color.lgtn.annotation "cyan" 2>/dev/null \
    || printf '\033[36m'
)
NOTE_COLOR=$(
  git config --get-color color.lgtn.note "blue" 2>/dev/null \
    || printf '\033[32m'
)
NOTE_META_COLOR=$(
  git config --get-color color.lgtn.noteMeta "cyan" 2>/dev/null \
    || printf '\033[36m'
)
NOTE_META_LINES_COLOR=$(
  git config --get-color color.lgtn.noteMetaLines "green" 2>/dev/null \
    || printf '\033[32m'
)
NOTE_META_LINES_WARN_COLOR=$(
  git config --get-color color.lgtn.noteMetaLinesWarn "yellow" 2>/dev/null \
    || printf '\033[33m'
)
NOTE_META_LINES_HOT_COLOR=$(
  git config --get-color color.lgtn.noteMetaLinesHot "red bold" 2>/dev/null \
    || printf '\033[1;31m'
)
NOTE_META_BYTES_COLOR=$(
  git config --get-color color.lgtn.noteMetaBytes "magenta" 2>/dev/null \
    || printf '\033[35m'
)
NOTE_META_BYTES_WARN_COLOR=$(
  git config --get-color color.lgtn.noteMetaBytesWarn "yellow" 2>/dev/null \
    || printf '\033[33m'
)
NOTE_META_BYTES_HOT_COLOR=$(
  git config --get-color color.lgtn.noteMetaBytesHot "red bold" 2>/dev/null \
    || printf '\033[1;31m'
)
NOTES_COMMIT_COLOR=$(
  git config --get-color color.lgtn.notesCommit "cyan bold" 2>/dev/null \
    || printf '\033[1;36m'
)
UNPUSHED_COLOR=$(
  git config --get-color color.lgtn.unpushed "red bold" 2>/dev/null \
    || printf '\033[1;31m'
)
UNPUSHED_LABEL=$(
  git config --get lgtn.unpushedLabel 2>/dev/null \
    || printf 'UNPUSHED'
)
REMOTE_TAG_STATUS=$(
  git config --bool lgtn.remoteTagStatus 2>/dev/null \
    || printf 'false'
)
LGTN_REMOTE=$(
  git config --get lgtn.remote 2>/dev/null \
    || printf 'origin'
)

# Optional: inline first-line display of git notes.
# Enable with: `git config lgtn.showNotes true`
# Configure refs with: `git config --add lgtn.notesRef commits` (or refs/notes/<name>)
SHOW_NOTES="$(
  git config --bool lgtn.showNotes 2>/dev/null \
    || printf 'false'
)"

expand_notes_ref() {
  if [[ "$1" == refs/notes/* ]]; then
    printf '%s' "$1"
  else
    printf 'refs/notes/%s' "$1"
  fi
}

notes_map_file=""
if [[ "$SHOW_NOTES" == "true" ]]; then
  mapfile -t notes_refs < <(git config --get-all lgtn.notesRef 2>/dev/null || true)
  if [[ ${#notes_refs[@]} -eq 0 ]]; then
    mapfile -t notes_refs < <(git for-each-ref refs/notes --format='%(refname)' 2>/dev/null || true)
    if [[ ${#notes_refs[@]} -eq 0 ]]; then
      notes_refs=(refs/notes/commits)
    fi
  fi

  notes_map_file="$(mktemp "${TMPDIR:-/tmp}/lgtn-notes.XXXXXXXX" 2>/dev/null || true)"
  if [[ -n "$notes_map_file" ]]; then
    trap 'rm -f "$notes_map_file" 2>/dev/null || true' EXIT

    for ref in "${notes_refs[@]}"; do
      ref_full="$(expand_notes_ref "$ref")"
      ref_short="${ref_full#refs/notes/}"

      if command -v python3 >/dev/null 2>&1; then
        git notes --ref "$ref_full" list 2>/dev/null \
        | python3 /dev/fd/3 "$ref_short" 3<<'PY' >>"$notes_map_file"
import subprocess
import sys

ref_short = sys.argv[1] if len(sys.argv) > 1 else "commits"
pairs = []
note_ids = []

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split()
    if len(parts) < 2:
        continue
    note, obj = parts[0], parts[1]
    pairs.append((obj, note))
    note_ids.append(note)

if not pairs:
    sys.exit(0)

proc = subprocess.Popen(
    ["git", "cat-file", "--batch"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
assert proc.stdin is not None
assert proc.stdout is not None

proc.stdin.write(("\n".join(note_ids) + "\n").encode("ascii", "replace"))
proc.stdin.close()

out = proc.stdout

def read_header():
    line = out.readline()
    if not line:
        return None
    return line.decode("ascii", "replace").strip()

def read_exact(n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = out.read(n - len(data))
        if not chunk:
            break
        data += chunk
    return data

for (obj, _note_id) in pairs:
    header = read_header()
    if header is None:
        break
    hparts = header.split()
    if len(hparts) >= 2 and hparts[1] == "missing":
        sys.stdout.write(f"{obj}\t{ref_short}\t\t0\t0\n")
        continue
    if len(hparts) < 3:
        continue
    size = int(hparts[2])
    total_bytes = size

    first = b""
    consumed = 0
    while consumed < size:
        b = out.read(1)
        if not b:
            break
        consumed += 1
        if b == b"\n":
            break
        first += b

    remaining = size - consumed
    rest = b""
    if remaining > 0:
        rest = read_exact(remaining)

    out.read(1)  # trailing newline after the object

    first_line = first.decode("utf-8", "replace").replace("\t", " ").rstrip("\r")
    # Notes are plain text; count lines (including first line). If the note ends
    # with a trailing newline, Git will store it, so avoid overcounting an empty
    # final line.
    content = first + b"\n" + rest if consumed < total_bytes else first + rest
    line_count = content.count(b"\n") + 1 if content else 0
    if content.endswith(b"\n"):
        line_count -= 1
    sys.stdout.write(f"{obj}\t{ref_short}\t{first_line}\t{line_count}\t{total_bytes}\n")

proc.wait()
PY
      else
        git notes --ref "$ref_full" list 2>/dev/null \
        | while read -r note obj; do
            first="$(git cat-file -p "$note" 2>/dev/null | sed -n '1p' | tr '\t' ' ' | tr -d '\r')"
            bytes="$(git cat-file -s "$note" 2>/dev/null || printf '0')"
            lines="$(git cat-file -p "$note" 2>/dev/null | wc -l | tr -d ' ')"
            printf '%s\t%s\t%s\t%s\t%s\n' "$obj" "$ref_short" "$first" "$lines" "$bytes"
          done >>"$notes_map_file"
      fi
    done

    [[ -s "$notes_map_file" ]] || notes_map_file=""
  fi
fi

git -c color.ui=always log \
  --graph \
  --date-order \
  --abbrev-commit \
  --decorate \
  --decorate-refs-exclude=refs/tags \
  --pretty=format:"%C(bold magenta)%h%Creset -${SEP}%C(auto)${SEP}%d${SEP}%Creset${SEP}%s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset${SEP}%H" \
  "${log_args[@]}" \
| awk -v FS="$SEP" -v TAG_COLOR="$TAG_COLOR" -v ANNO_COLOR="$ANNO_COLOR" -v NOTE_COLOR="$NOTE_COLOR" -v NOTE_META_COLOR="$NOTE_META_COLOR" -v NOTE_META_LINES_COLOR="$NOTE_META_LINES_COLOR" -v NOTE_META_LINES_WARN_COLOR="$NOTE_META_LINES_WARN_COLOR" -v NOTE_META_LINES_HOT_COLOR="$NOTE_META_LINES_HOT_COLOR" -v NOTE_META_BYTES_COLOR="$NOTE_META_BYTES_COLOR" -v NOTE_META_BYTES_WARN_COLOR="$NOTE_META_BYTES_WARN_COLOR" -v NOTE_META_BYTES_HOT_COLOR="$NOTE_META_BYTES_HOT_COLOR" -v NOTES_COMMIT_COLOR="$NOTES_COMMIT_COLOR" -v UNPUSHED_COLOR="$UNPUSHED_COLOR" -v UNPUSHED_LABEL="$UNPUSHED_LABEL" -v REMOTE_TAG_STATUS="$REMOTE_TAG_STATUS" -v LGTN_REMOTE="$LGTN_REMOTE" -v NOTES_MAP_FILE="$notes_map_file" '
  BEGIN {
    RESET = "\033[0m"
    PAIR_SEP = "\034"
    FIELD_SEP = "\035"

    remote_enabled = (REMOTE_TAG_STATUS == "true")
    if (remote_enabled) {
      cmd = "git ls-remote --tags --refs " LGTN_REMOTE " 2>/dev/null"
      while ((cmd | getline line) > 0) {
        split(line, a, "\t")
        ref = a[2]
        sub(/^refs\/tags\//, "", ref)
        if (ref != "") remote_tags[ref] = 1
      }
      remote_ok = (close(cmd) == 0)
    } else {
      remote_ok = 0
    }

    if (NOTES_MAP_FILE != "") {
      while ((getline line < NOTES_MAP_FILE) > 0) {
        split(line, a, "\t")
        sha = a[1]
        ref = a[2]
        txt = a[3]
        lns = a[4]
        byt = a[5]
        if (sha == "" || txt == "") continue
        notes_raw[sha] = notes_raw[sha] PAIR_SEP ref FIELD_SEP txt FIELD_SEP lns FIELD_SEP byt
      }
      close(NOTES_MAP_FILE)
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

  function truncate(s, max,    out) {
    out = s
    if (max > 0 && length(out) > max) out = substr(out, 1, max - 1) "…"
    return out
  }

  function heat_color(n, small, warn, hot, warn_at, hot_at,    c) {
    c = small
    if (n >= hot_at) c = hot
    else if (n >= warn_at) c = warn
    return c
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

    # Make the notes-ref history commits stand out when using `--all`.
    # These commits are created by git itself and have subjects like:
    #   Notes added by git notes add
    if (right ~ /^Notes /) {
      right = NOTES_COMMIT_COLOR right
    }

    delete subjects
    delete order
    n = load_tag_subjects(sha, subjects, order)

    if (n > 0) {
      anno_color = ANNO_COLOR
      tag_color = TAG_COLOR
      unpushed_color = UNPUSHED_COLOR
      unpushed_label = UNPUSHED_LABEL
      tag_block = ""

      for (i = 1; i <= n; i++) {
        tag = order[i]
        subj = subjects[tag]
        if (tag == "") continue

        if (tag_block != "") tag_block = tag_block ", "
        tag_block = tag_block "tag: " tag
        if (remote_enabled && remote_ok && !(tag in remote_tags)) {
          tag_block = tag_block " " unpushed_color unpushed_label color_reset tag_color
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

    if (sha in notes_raw) {
      note_block = ""
      np = split(notes_raw[sha], pairs, PAIR_SEP)
      for (i = 1; i <= np; i++) {
        if (pairs[i] == "") continue
        split(pairs[i], f, FIELD_SEP)
        nref = f[1]
        ntxt = truncate(f[2], 80)
        nlns = f[3] + 0
        nbyt = f[4] + 0
        if (nref == "" || ntxt == "") continue
        if (note_block != "") note_block = note_block " | "

        note_label = "note:" nref
        if (nref == "commits") note_label = "note"

        note_meta = ""
        # For single-line notes, keep output compact: no size indicator.
        if (nlns > 1) {
          lc = heat_color(nlns, NOTE_META_LINES_COLOR, NOTE_META_LINES_WARN_COLOR, NOTE_META_LINES_HOT_COLOR, 5, 20)
          bc = heat_color(nbyt, NOTE_META_BYTES_COLOR, NOTE_META_BYTES_WARN_COLOR, NOTE_META_BYTES_HOT_COLOR, 200, 2000)
          note_meta = NOTE_META_COLOR "[" lc nlns "L" NOTE_META_COLOR "/" bc nbyt "B" NOTE_META_COLOR "]" RESET " "
        }
        note_block = note_block note_label " " note_meta NOTE_COLOR ntxt RESET TAG_COLOR
      }

      if (note_block != "") {
        if (deco_text != "") {
          deco_text = insert_before_last_paren(deco_text, ", " TAG_COLOR note_block)
        } else {
          deco_text = TAG_COLOR " (" note_block ")"
        }
      }
    }

    print left deco_color_start deco_text color_reset " " right
  }
' 2>/dev/null \
| {
    if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then
      LESS='-FRS' less -R
    else
      cat
    fi
  }
