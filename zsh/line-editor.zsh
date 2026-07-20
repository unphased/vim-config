# Move the argument under the cursor left or right using zsh's shell-aware splitter.
autoload -Uz split-shell-arguments

__le_move_arg() {
  emulate -L zsh
  local direction=$1

  split-shell-arguments || { zle beep; return 0 }

  local -a parts
  parts=("${reply[@]}")
  local -i part_count=${#parts}
  if (( part_count < 3 )); then
    zle beep
    return 0
  fi

  local -i segment_index=$REPLY
  local -i cursor_suboffset=$(( REPLY2 - 1 ))
  (( cursor_suboffset < 0 )) && cursor_suboffset=0

  local -i word_index=0
  if (( segment_index % 2 == 0 )); then
    word_index=$segment_index
  else
    if (( part_count == 1 )); then
      zle beep
      return 0
    elif (( segment_index == 1 )); then
      word_index=2
    elif (( segment_index == part_count )); then
      word_index=part_count-1
    else
      word_index=segment_index+1
    fi
    cursor_suboffset=0
  fi

  if (( word_index <= 1 || word_index >= part_count )); then
    zle beep
    return 0
  fi

  local -i target_index
  if [[ $direction == left ]]; then
    if (( word_index <= 2 )); then
      zle beep
      return 0
    fi
    target_index=$(( word_index - 2 ))
  elif [[ $direction == right ]]; then
    if (( word_index >= part_count - 1 )); then
      zle beep
      return 0
    fi
    target_index=$(( word_index + 2 ))
  else
    return 1
  fi

  local tmp=${parts[target_index]}
  parts[target_index]=${parts[word_index]}
  parts[word_index]=$tmp

  local new_buffer="${(j::)parts}"
  local -i new_cursor=0
  local -i i=1
  while (( i < target_index )); do
    (( new_cursor += ${#parts[i]} ))
    (( ++i ))
  done

  local -i segment_length=${#parts[target_index]}
  if (( cursor_suboffset > segment_length )); then
    cursor_suboffset=$segment_length
  fi
  (( new_cursor += cursor_suboffset ))

  BUFFER=$new_buffer
  CURSOR=$new_cursor
  LBUFFER=${BUFFER[1,new_cursor]}
  RBUFFER=${BUFFER[new_cursor+1,-1]}

  zle redisplay
  return 0
}

move-current-arg-left() { __le_move_arg left }
move-current-arg-right() { __le_move_arg right }

zle -N move-current-arg-left
zle -N move-current-arg-right
bindkey "^B" move-current-arg-left
bindkey "^N" move-current-arg-right
# bindkey "\e>" move-current-arg-left
# bindkey "\e<" move-current-arg-right
