#!/usr/bin/env bash
#
# git-lg-notes.sh
#
# Fast “subway graph” log like `git lg`, but also injects *git notes first lines*
# inline into the normal decoration parens area.
#
# Why:
#   - `log.showNotes=true` is great for `git log`, but it makes one-line views
#     noisy by printing a multi-line "Notes:" block.
#   - Git doesn’t have a built-in “notes subject only” placeholder.
#   - This script precomputes a notes map once, then does a cheap per-line
#     injection in awk.
#
# Notes:
#   - Notes are still stored normally under `refs/notes/*`.
#   - We run `git log --no-notes` to avoid the built-in "Notes:" block and avoid
#     interfering with the one-line-per-commit layout.

set -euo pipefail

SEP=$'\x1f' # safe field separator for awk

NOTE_COLOR=$(
  git config --get-color color.lgt.note "green" 2>/dev/null \
    || printf '\033[32m'
)
NOTE_META_COLOR=$(
  git config --get-color color.lgt.noteMeta "cyan" 2>/dev/null \
    || printf '\033[36m'
)
NOTE_META_LINES_COLOR=$(
  git config --get-color color.lgt.noteMetaLines "green" 2>/dev/null \
    || printf '\033[32m'
)
NOTE_META_LINES_WARN_COLOR=$(
  git config --get-color color.lgt.noteMetaLinesWarn "yellow" 2>/dev/null \
    || printf '\033[33m'
)
NOTE_META_LINES_HOT_COLOR=$(
  git config --get-color color.lgt.noteMetaLinesHot "red bold" 2>/dev/null \
    || printf '\033[1;31m'
)
NOTE_META_BYTES_COLOR=$(
  git config --get-color color.lgt.noteMetaBytes "magenta" 2>/dev/null \
    || printf '\033[35m'
)
NOTE_META_BYTES_WARN_COLOR=$(
  git config --get-color color.lgt.noteMetaBytesWarn "yellow" 2>/dev/null \
    || printf '\033[33m'
)
NOTE_META_BYTES_HOT_COLOR=$(
  git config --get-color color.lgt.noteMetaBytesHot "red bold" 2>/dev/null \
    || printf '\033[1;31m'
)

expand_notes_ref() {
  if [[ "$1" == refs/notes/* ]]; then
    printf '%s' "$1"
  else
    printf 'refs/notes/%s' "$1"
  fi
}

notes_map_file=""
mapfile -t notes_refs < <(git for-each-ref refs/notes --format='%(refname)' 2>/dev/null || true)
if [[ ${#notes_refs[@]} -eq 0 ]]; then
  notes_refs=(refs/notes/commits)
fi

notes_map_file="$(mktemp "${TMPDIR:-/tmp}/lg-notes.XXXXXXXX" 2>/dev/null || true)"
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

    out.read(1)  # trailing newline

    first_line = first.decode("utf-8", "replace").replace("\t", " ").rstrip("\r")
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

###############################################################################
# Width passthrough for `--stat` when piped (git assumes 80 cols otherwise)
###############################################################################

stat_width_args=()
if [[ -t 1 ]]; then
  term_cols=""

  if command -v tput >/dev/null 2>&1 && [[ -r /dev/tty ]]; then
    term_cols="$(tput cols </dev/tty 2>/dev/null || true)"
  fi

  if [[ -z "$term_cols" ]]; then
    term_cols="${COLUMNS:-}"
  fi

  if [[ "$term_cols" =~ ^[0-9]+$ ]] && [[ "$term_cols" -gt 0 ]]; then
    stat_cols="$term_cols"
    if (( stat_cols > 5 )); then
      stat_cols=$((stat_cols - 5))
    fi

    for arg in "$@"; do
      case "$arg" in
        --stat|--stat=*|--patch-with-stat|--patch-with-stat=*|--numstat|--shortstat)
          stat_width_args=(--stat-width="$stat_cols" --stat-name-width="$stat_cols")
          break
          ;;
      esac
    done
  fi
fi

git -c color.ui=always log \
  --no-notes \
  --graph \
  --date-order \
  --abbrev-commit \
  --decorate \
  --pretty=format:"%C(bold magenta)%h%Creset -${SEP}%C(auto)${SEP}%d${SEP}%Creset${SEP}%s %Cgreen%ci %C(yellow)(%cr) %C(bold blue)<%an>%Creset${SEP}%H" \
  "${stat_width_args[@]}" \
  "$@" \
| awk -v FS="$SEP" \
  -v NOTE_COLOR="$NOTE_COLOR" \
  -v NOTE_META_COLOR="$NOTE_META_COLOR" \
  -v NOTE_META_LINES_COLOR="$NOTE_META_LINES_COLOR" \
  -v NOTE_META_LINES_WARN_COLOR="$NOTE_META_LINES_WARN_COLOR" \
  -v NOTE_META_LINES_HOT_COLOR="$NOTE_META_LINES_HOT_COLOR" \
  -v NOTE_META_BYTES_COLOR="$NOTE_META_BYTES_COLOR" \
  -v NOTE_META_BYTES_WARN_COLOR="$NOTE_META_BYTES_WARN_COLOR" \
  -v NOTE_META_BYTES_HOT_COLOR="$NOTE_META_BYTES_HOT_COLOR" \
  -v NOTES_MAP_FILE="$notes_map_file" '
  BEGIN {
    RESET = "\033[0m"
    PAIR_SEP = "\034"
    FIELD_SEP = "\035"

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

  {
    left             = $1
    deco_color_start = $2
    deco_text        = $3
    color_reset      = $4
    right            = $5
    sha_raw          = $6

    sha = ""
    if (sha_raw ~ /^[0-9a-f]{40}/) sha = substr(sha_raw, 1, 40)

    if (sha != "" && (sha in notes_raw)) {
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
        if (nlns > 1) {
          lc = heat_color(nlns, NOTE_META_LINES_COLOR, NOTE_META_LINES_WARN_COLOR, NOTE_META_LINES_HOT_COLOR, 5, 20)
          bc = heat_color(nbyt, NOTE_META_BYTES_COLOR, NOTE_META_BYTES_WARN_COLOR, NOTE_META_BYTES_HOT_COLOR, 200, 2000)
          note_meta = NOTE_META_COLOR "[" lc nlns "L" NOTE_META_COLOR "/" bc nbyt "B" NOTE_META_COLOR "]" RESET " "
        }

        note_block = note_block note_label " " note_meta NOTE_COLOR ntxt RESET
      }

      if (note_block != "") {
        if (deco_text != "") {
          deco_text = insert_before_last_paren(deco_text, ", " note_block)
        } else {
          deco_text = " (" note_block ")"
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
