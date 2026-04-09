#!/usr/bin/env zsh
set -euo pipefail

ROOT="/Users/slu/.vim/.codex-debug/vendor/tree-sitter-markdown-split_parser"
FIXTURE="${1:-simple}"
MODE="${2:-block-range}"

case "$FIXTURE" in
  simple)
    TARGET="/tmp/codex-raw-simple.md"
    printf '# hi\n\ntext\n' > "$TARGET"
    ;;
  readme)
    TARGET="/Users/slu/.vim/README.md"
    ;;
  *)
    TARGET="$FIXTURE"
    ;;
esac

(
  cd "$ROOT"
  cargo run --quiet --offline --release --features parser --bin range-parse "$TARGET" "$MODE"
)
RC=$?

printf 'fixture=%s mode=%s rc=%s\n' "$FIXTURE" "$MODE" "$RC"
