#!/bin/sh

set -eu

pane_id=${HERDR_ACTIVE_PANE_ID:-}
herdr_bin=${HERDR_BIN_PATH:-herdr}
output=$(mktemp "${TMPDIR:-/tmp}/herdr-session-context.XXXXXX")
trap 'rm -f "$output"' EXIT HUP INT TERM

if [ -z "$pane_id" ]; then
  cat >"$output" <<'EOF'
Herdr pane information

No active pane context was provided.
EOF
elif pane_json=$("$herdr_bin" pane get "$pane_id" 2>&1); then
  if command -v jq >/dev/null 2>&1 && printf '%s\n' "$pane_json" | jq -er '
    if (.result.pane | type) != "object" then error("missing pane object") else
      .result.pane as $pane |
      "Herdr pane information",
      "",
      "Pane            \($pane.pane_id)",
      "Tab             \($pane.tab_id)",
      "Workspace       \($pane.workspace_id)",
      "Working dir     \($pane.foreground_cwd // $pane.cwd // "—")",
      "Terminal title  \($pane.terminal_title_stripped // "—")",
      "",
      "Agent           \($pane.agent // "—")",
      "Status          \($pane.agent_status // "—")",
      if $pane.agent_session then
        "Session source  \($pane.agent_session.source)",
        "Session kind    \($pane.agent_session.kind)",
        "Session value   \($pane.agent_session.value)"
      else
        "Session         No recognized agent session"
      end,
      "",
      "This is the metadata foundation for the session-context summary.",
      "Press q to close."
    end
  ' >"$output" 2>/dev/null; then
    {
      printf '\nRaw pane metadata\n'
      printf '%s\n' '-----------------'
      printf '%s\n' "$pane_json" | jq .

      printf '\nForeground processes\n'
      printf '%s\n' '--------------------'
    } >>"$output"

    if process_json=$("$herdr_bin" pane process-info --pane "$pane_id" 2>&1); then
      if ! printf '%s\n' "$process_json" | jq . >>"$output" 2>/dev/null; then
        printf '%s\n' "$process_json" >>"$output"
      fi
    else
      printf 'Could not inspect foreground processes:\n%s\n' "$process_json" >>"$output"
    fi

    {
      printf '\nRecent terminal output (up to 120 lines)\n'
      printf '%s\n' '----------------------------------------'
    } >>"$output"
    if ! "$herdr_bin" pane read "$pane_id" --source recent-unwrapped --lines 120 >>"$output" 2>&1; then
      printf '\nCould not read recent terminal output.\n' >>"$output"
    fi
  else
    {
      printf 'Herdr pane information\n\n'
      printf 'Could not parse metadata for pane %s. Raw response:\n\n' "$pane_id"
      printf '%s\n' "$pane_json"
    } >"$output"
  fi
else
  {
    printf 'Herdr pane information\n\n'
    printf 'Could not inspect pane %s:\n\n' "$pane_id"
    printf '%s\n' "$pane_json"
  } >"$output"
fi

if [ -t 0 ] && [ -t 1 ] && command -v less >/dev/null 2>&1; then
  less -R "$output"
else
  cat "$output"
fi
