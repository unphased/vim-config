#!/usr/bin/env bash
# Publish Claude Code statusline metrics to Herdr, then preserve the user's renderer.
set -uo pipefail

format_tokens() {
  local tokens=${1:-0}
  if ((tokens < 1000)); then
    printf '%d' "$tokens"
  elif ((tokens < 100000)); then
    awk -v n="$tokens" 'BEGIN { printf "%.1fk", n / 1000 }' | sed 's/\.0k$/k/'
  elif ((tokens < 1000000)); then
    awk -v n="$tokens" 'BEGIN { printf "%.0fk", n / 1000 }'
  else
    awk -v n="$tokens" 'BEGIN { printf "%.1fM", n / 1000000 }' | sed 's/\.0M$/M/'
  fi
}

report_metadata() {
  local input=$1 parsed model effort context_percent context_window transcript session_id
  local context_value context_level session_tokens session_value session_level=
  local transcript_signature cache_key cache_dir cache_file cached_signature cache_tmp
  local -a args

  [[ ${HERDR_ENV:-} == 1 && -n ${HERDR_PANE_ID:-} && -n ${HERDR_SOCKET_PATH:-} ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v herdr >/dev/null 2>&1 || return 0

  parsed=$(jq -r '[
    (.model.display_name // .model.id // "Claude"),
    (.effort.level // "-"),
    (if .context_window.used_percentage == null then "?" else (.context_window.used_percentage | round | tostring) end),
    (.context_window.context_window_size // 0 | floor | tostring),
    (.transcript_path // "-"),
    (.session_id // "-")
  ] | @tsv' <<<"$input" 2>/dev/null) || return 0
  IFS=$'\t' read -r model effort context_percent context_window transcript session_id <<<"$parsed"

  [[ $effort != - ]] && model="$model:$effort"
  [[ $transcript == - ]] && transcript=
  [[ $session_id == - ]] && session_id=
  if [[ $context_percent =~ ^[0-9]+$ ]]; then
    context_value="${context_percent}%"
  else
    context_value='?'
  fi
  if [[ $context_window =~ ^[0-9]+$ ]] && ((context_window > 0)); then
    context_value+="/$(format_tokens "$context_window")"
  else
    context_value+='/?'
  fi
  if [[ $context_percent =~ ^[0-9]+$ ]] && ((context_percent > 90)); then
    context_level=error
  elif [[ $context_percent =~ ^[0-9]+$ ]] && ((context_percent > 70)); then
    context_level=warn
  else
    context_level=ok
  fi

  session_tokens=
  if [[ -n $transcript && -r $transcript ]]; then
    transcript_signature=$(stat -f '%m:%z' "$transcript" 2>/dev/null || stat -c '%Y:%s' "$transcript" 2>/dev/null || true)
    cache_key=$session_id
    if [[ -z $cache_key ]]; then
      cache_key=$(printf '%s' "$transcript" | cksum | awk '{print $1}')
    fi
    cache_key=${cache_key//[^A-Za-z0-9_.-]/_}
    cache_dir=${HERDR_CLAUDE_CACHE_DIR:-"${XDG_CACHE_HOME:-$HOME/.cache}/herdr/claude-statusline"}
    (umask 077 && mkdir -p "$cache_dir") || cache_dir=
    [[ -z $cache_dir ]] || chmod 700 "$cache_dir" 2>/dev/null || true
    cache_file=${cache_dir:+"$cache_dir/$cache_key"}
    if [[ -n $transcript_signature && -n $cache_file && -r $cache_file ]]; then
      IFS=$'\t' read -r cached_signature session_tokens <"$cache_file" || session_tokens=
      [[ $cached_signature == "$transcript_signature" ]] || session_tokens=
    fi
    if [[ ! $session_tokens =~ ^[0-9]+$ ]]; then
      session_tokens=$(jq -s '
        [ .[]
          | select(.type == "assistant" and .isSidechain != true and (.message.usage | type) == "object")
        ]
        | to_entries
        | unique_by(.value.message.id // .value.requestId // .value.uuid // ("entry:" + (.key | tostring)))
        | map(.value)
        | reduce .[] as $entry (0;
            . + ($entry.message.usage.input_tokens // 0)
              + ($entry.message.usage.output_tokens // 0)
              + ($entry.message.usage.cache_creation_input_tokens // 0)
              + ($entry.message.usage.cache_read_input_tokens // 0)
          )
      ' "$transcript" 2>/dev/null) || session_tokens=
      if [[ $session_tokens =~ ^[0-9]+$ && -n $transcript_signature && -n $cache_file ]]; then
        cache_tmp=$(mktemp "${cache_file}.XXXXXX") || cache_tmp=
        if [[ -n $cache_tmp ]]; then
          printf '%s\t%s\n' "$transcript_signature" "$session_tokens" >"$cache_tmp" && mv -f "$cache_tmp" "$cache_file"
        fi
      fi
    fi
  fi

  args=(
    pane report-metadata "$HERDR_PANE_ID"
    --source user:claude-statusline
    --applies-to-source herdr:claude
    --token 'claude=✳'
    --token "model=$model"
  )

  local level
  for level in ok warn error; do
    if [[ $level == "$context_level" ]]; then
      args+=(--token "context_${level}=$context_value")
    else
      args+=(--clear-token "context_${level}")
    fi
  done

  if [[ $session_tokens =~ ^[0-9]+$ ]]; then
    session_value="$(format_tokens "$session_tokens")t"
    if ((session_tokens >= 100000000)); then
      session_level=extreme
    elif ((session_tokens >= 20000000)); then
      session_level=long
    elif ((session_tokens >= 10000000)); then
      session_level=warn
    elif ((session_tokens >= 5000000)); then
      session_level=active
    else
      session_level=healthy
    fi
  fi
  for level in healthy active warn long extreme; do
    if [[ -n $session_level && $level == "$session_level" ]]; then
      args+=(--token "session_tokens_${level}=$session_value")
    else
      args+=(--clear-token "session_tokens_${level}")
    fi
  done

  herdr "${args[@]}" >/dev/null 2>&1 || true
}

input=$(cat; printf x)
input=${input%x}
if [[ ${1:-} == --report-only ]]; then
  report_metadata "$input"
  exit 0
fi

# Keep reports ordered; the transcript cache makes unchanged redraws cheap.
report_metadata "$input" >/dev/null 2>&1

if [[ -n ${CLAUDE_STATUSLINE_DELEGATE:-} ]]; then
  printf '%s' "$input" | bash -c "$CLAUDE_STATUSLINE_DELEGATE"
else
  printf '%s' "$input" | bash "$HOME/.claude/statusline-command.sh"
fi
