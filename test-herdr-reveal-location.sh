#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" > "$REVEAL_TEST_LOG"' > "$tmp/handler"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" > "$REVEAL_TEST_NOTIFY"' > "$tmp/herdr"
chmod +x "$tmp/handler" "$tmp/herdr"
export REVEAL_TEST_LOG="$tmp/args" REVEAL_TEST_NOTIFY="$tmp/notice"
export REVEAL_LOCATION="$tmp/handler" HERDR_BIN_PATH="$tmp/herdr"
export HERDR_PLUGIN_CLICKED_URL='file:///tmp/name%20with%20spaces%27%3B%24%28x%29.md#L7C3'
sh "$root/herdr-plugins/reveal-location/reveal-location.sh"
printf '%s\n' -- "$HERDR_PLUGIN_CLICKED_URL" > "$tmp/expected"
cmp "$tmp/args" "$tmp/expected"
test ! -e "$tmp/notice"
REVEAL_LOCATION_TARGET="$HERDR_PLUGIN_CLICKED_URL" sh "$root/herdr-plugins/reveal-location/open-editor.sh"
printf '%s\n' --editor -- "$HERDR_PLUGIN_CLICKED_URL" > "$tmp/editor-expected"
cmp "$tmp/args" "$tmp/editor-expected"
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
