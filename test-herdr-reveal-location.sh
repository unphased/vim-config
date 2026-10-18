#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" > "$REVEAL_TEST_LOG"' \
  'printf "%s" "${TERMPLEX_RECORDING_ID-missing}" > "$REVEAL_TEST_PARENT"' > "$tmp/handler"
printf '%s\n' '#!/bin/sh' 'if [ "$1 $2" = "pane process-info" ]; then printf "{}"; exit 0; fi' \
  'printf "%s\n" "$@" > "$REVEAL_TEST_NOTIFY"' > "$tmp/herdr"
chmod +x "$tmp/handler" "$tmp/herdr"
export REVEAL_TEST_LOG="$tmp/args" REVEAL_TEST_NOTIFY="$tmp/notice" REVEAL_TEST_PARENT="$tmp/parent"
export HERDR_PANE_ID=clicked:pane TERMPLEX_RECORDING_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
export REVEAL_LOCATION="$tmp/handler" HERDR_BIN_PATH="$tmp/herdr"
export HERDR_PLUGIN_CLICKED_URL='file:///tmp/name%20with%20spaces%27%3B%24%28x%29.md#L7C3'
sh "$root/herdr-plugins/reveal-location/reveal-location.sh"
printf '%s\n' -- "$HERDR_PLUGIN_CLICKED_URL" > "$tmp/expected"
cmp "$tmp/args" "$tmp/expected"
test ! -e "$tmp/notice"
test ! -s "$tmp/parent" # Unknown source must clear the stale server ID.
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" > "$REVEAL_TEST_CAPTURE"' \
  'shift 3' 'exec "$@"' > "$tmp/term-capture"
chmod +x "$tmp/term-capture"
export TERMPLEX_CAPTURE=1 TERMPLEX_CAPTURE_BIN="$tmp/term-capture"
export TERMPLEX_CAPTURE_DIR="$tmp/captures with spaces" REVEAL_TEST_CAPTURE="$tmp/capture-args"
REVEAL_LOCATION_TARGET="$HERDR_PLUGIN_CLICKED_URL" sh "$root/herdr-plugins/reveal-location/open-editor.sh"
printf '%s\n' --editor -- "$HERDR_PLUGIN_CLICKED_URL" > "$tmp/editor-expected"
cmp "$tmp/args" "$tmp/editor-expected"
printf '%s\n' --pid-prefix-dir "$TERMPLEX_CAPTURE_DIR" -- "$REVEAL_LOCATION" \
  --editor -- "$HERDR_PLUGIN_CLICKED_URL" > "$tmp/capture-expected"
cmp "$tmp/capture-args" "$tmp/capture-expected"
if env -u REVEAL_LOCATION_TARGET sh "$root/herdr-plugins/reveal-location/open-editor.sh" 2>/dev/null; then
  echo 'editor pane without target must fail' >&2; exit 1
fi
printf '%s\n' '#!/bin/sh' 'echo "foreign host rejected" >&2' 'exit 2' > "$tmp/handler"
if sh "$root/herdr-plugins/reveal-location/reveal-location.sh" 2>"$tmp/errors"; then
  echo 'expected failure to propagate' >&2; exit 1
fi
grep -q 'foreign host rejected' "$tmp/errors"
grep -q 'Could not reveal file' "$tmp/notice"
if env -u HERDR_PLUGIN_CLICKED_URL sh "$root/herdr-plugins/reveal-location/reveal-location.sh" 2>/dev/null; then
  echo 'missing link context must fail' >&2; exit 1
fi
printf 'PASS: Herdr reveal argv and failure notification\n'
