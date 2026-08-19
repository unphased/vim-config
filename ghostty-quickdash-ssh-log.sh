#!/bin/sh

set -eu

home_dir=${HOME:-/home/slu}
ssh_log=${1:-${XDG_STATE_HOME:-$home_dir/.local/state}/quickdash/ssh-connections.tsv}

# Keep infrastructure ancestors visible but visually subordinate.
tail -n 20 -F "$ssh_log" | awk '
BEGIN {
  FS = OFS = "\t"
  dim = sprintf("%c[2m", 27)
  normal = sprintf("%c[22m", 27)
}
{
  for (field = 1; field <= NF; field++) {
    if ($field !~ /^process_chain=/)
      continue

    chain = $field
    sub(/^process_chain=/, "", chain)
    gsub(/[[:space:]]*<-[[:space:]]*/, " <- ", chain)
    count = split(chain, nodes, / <- /)
    rendered = ""
    for (node = 1; node <= count; node++) {
      if (nodes[node] ~ /^(bash|zsh|tmux)\[[0-9]+\]$/)
        nodes[node] = dim nodes[node] normal
      rendered = rendered (node == 1 ? "" : " <- ") nodes[node]
    }
    $field = "process_chain=" rendered
  }
  print
  fflush()
}
'
