# shellcheck shell=bash
# shellcheck disable=SC2034 # Public result variables are consumed by scripts after sourcing.
# Context-restart primitives.
# Usage: . bin/fm-context-restart-lib.sh
#
# This library owns the exact config/context-restart-budget format, safe default
# publication, Claude transcript accounting, and the durable crossing record
# shared by the Stop hook, handoff command, and primary relaunch wrapper.
# It is source-only and has no side effects.

FM_CONTEXT_RESTART_BUDGET_FILE="context-restart-budget"
FM_CONTEXT_RESTART_BUDGET_DEFAULT=400000
FM_CONTEXT_RESTART_BUDGET_ERROR=
FM_CONTEXT_RESTART_BUDGET_VALUE=
FM_CONTEXT_RESTART_TRANSCRIPT_ERROR=
FM_CONTEXT_RESTART_CONTEXT_TOKENS=
FM_CONTEXT_RESTART_RECORD_ERROR=
FM_CONTEXT_RESTART_RECORD_SESSION=
FM_CONTEXT_RESTART_RECORD_PHASE=
FM_CONTEXT_RESTART_RECORD_CONTEXT=
FM_CONTEXT_RESTART_RECORD_BUDGET=
FM_CONTEXT_RESTART_RECORD_DETECTED_AT=
FM_CONTEXT_RESTART_RECORD_MODE=
FM_CONTEXT_RESTART_RECORD_TOKEN=
FM_CONTEXT_RESTART_RECORD_LOCK_PID=

fm_context_restart_budget_fail() {
  FM_CONTEXT_RESTART_BUDGET_ERROR=$1
  return 1
}

fm_context_restart_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_context_restart_config_dir_safe() {
  local dir=$1
  if [ -L "$dir" ]; then
    fm_context_restart_budget_fail "config directory is symlinked"
    return 1
  fi
  if [ ! -d "$dir" ]; then
    fm_context_restart_budget_fail "config directory is not a directory"
    return 1
  fi
}

# Set FM_CONTEXT_RESTART_BUDGET_VALUE only for one positive decimal integer,
# with no leading zero, followed by exactly one newline in a single-linked file.
fm_context_restart_budget_file_valid() {  # <path>
  local path=$1 links value
  FM_CONTEXT_RESTART_BUDGET_VALUE=
  if [ -L "$path" ]; then
    fm_context_restart_budget_fail "file is symlinked"
    return 1
  fi
  if [ ! -e "$path" ]; then
    fm_context_restart_budget_fail "file is absent"
    return 1
  fi
  if [ ! -f "$path" ]; then
    fm_context_restart_budget_fail "file is not a regular file"
    return 1
  fi
  links=$(fm_context_restart_link_count "$path") || {
    fm_context_restart_budget_fail "could not inspect file link count"
    return 1
  }
  if [ "$links" != 1 ]; then
    fm_context_restart_budget_fail "file is hardlinked"
    return 1
  fi
  value=$(<"$path") || {
    fm_context_restart_budget_fail "could not read file"
    return 1
  }
  case "$value" in
    ''|0|*[!0-9]*|0*)
      fm_context_restart_budget_fail "value must be one positive decimal integer"
      return 1
      ;;
  esac
  if ! printf '%s\n' "$value" | cmp -s "$path" -; then
    fm_context_restart_budget_fail "file must contain exactly one value followed by one newline"
    return 1
  fi
  FM_CONTEXT_RESTART_BUDGET_VALUE=$value
}

fm_context_restart_budget_read() {  # <config-dir>
  local config_dir=$1
  fm_context_restart_config_dir_safe "$config_dir" || return 1
  fm_context_restart_budget_file_valid "$config_dir/$FM_CONTEXT_RESTART_BUDGET_FILE" || return 1
  printf '%s\n' "$FM_CONTEXT_RESTART_BUDGET_VALUE"
}

# Atomically publish the visible default only when the file is absent.
# A concurrent valid creator is accepted; unsafe or malformed state is retained
# and rejected instead of being replaced.
fm_context_restart_budget_materialize() {  # <config-dir>
  local config_dir=$1 path tmp
  if [ -e "$config_dir" ] || [ -L "$config_dir" ]; then
    fm_context_restart_config_dir_safe "$config_dir" || return 1
  else
    mkdir -p "$config_dir" 2>/dev/null || {
      fm_context_restart_budget_fail "could not create config directory"
      return 1
    }
    fm_context_restart_config_dir_safe "$config_dir" || return 1
  fi

  path="$config_dir/$FM_CONTEXT_RESTART_BUDGET_FILE"
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_context_restart_budget_read "$config_dir" >/dev/null
    return
  fi

  tmp=$(umask 077; mktemp "$config_dir/.context-restart-budget.XXXXXX" 2>/dev/null) || {
    fm_context_restart_budget_fail "could not create default temporary file"
    return 1
  }
  if ! printf '%s\n' "$FM_CONTEXT_RESTART_BUDGET_DEFAULT" > "$tmp" \
    || ! fm_context_restart_budget_file_valid "$tmp"; then
    rm -f "$tmp"
    [ -n "$FM_CONTEXT_RESTART_BUDGET_ERROR" ] \
      || fm_context_restart_budget_fail "could not write default value"
    return 1
  fi
  if ln "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    fm_context_restart_budget_read "$config_dir" >/dev/null
    return
  fi
  rm -f "$tmp"
  fm_context_restart_budget_read "$config_dir" >/dev/null
}

fm_context_restart_transcript_fail() {
  FM_CONTEXT_RESTART_TRANSCRIPT_ERROR=$1
  return 1
}

# Read Claude's JSONL transcript as a stream and set the current context size
# from the latest assistant message. The context is the prompt input carried by
# input/cache usage plus that response's output, which becomes input on the next
# turn. Any malformed row or malformed latest usage rejects the observation.
fm_context_restart_transcript_tokens() {  # <transcript-path>
  local path=$1 links value
  FM_CONTEXT_RESTART_CONTEXT_TOKENS=
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    fm_context_restart_transcript_fail "transcript is not an ordinary regular file"
    return 1
  fi
  links=$(fm_context_restart_link_count "$path") || {
    fm_context_restart_transcript_fail "could not inspect transcript link count"
    return 1
  }
  if [ "$links" != 1 ]; then
    fm_context_restart_transcript_fail "transcript is hardlinked"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    fm_context_restart_transcript_fail "jq is unavailable"
    return 1
  }
  value=$(jq -nr '
    def non_negative_integer:
      type == "number" and . >= 0 and floor == .;
    reduce inputs as $row
      (null;
       if (($row | type) == "object"
           and $row.type == "assistant"
           and (($row.message | type) == "object")
           and $row.message.role == "assistant")
       then $row.message.usage
       else .
       end)
    | if type != "object" then error("missing latest assistant usage") else . end
    | .input_tokens as $input
    | (.cache_creation_input_tokens // 0) as $created
    | (.cache_read_input_tokens // 0) as $read
    | (.output_tokens // 0) as $output
    | if (($input | non_negative_integer)
          and ($created | non_negative_integer)
          and ($read | non_negative_integer)
          and ($output | non_negative_integer))
      then ($input + $created + $read + $output | tostring)
      else error("malformed latest assistant usage")
      end
  ' "$path" 2>/dev/null) || {
    fm_context_restart_transcript_fail "transcript or latest assistant usage is malformed"
    return 1
  }
  case "$value" in
    ''|*[!0-9]*)
      fm_context_restart_transcript_fail "computed context size is invalid"
      return 1
      ;;
  esac
  FM_CONTEXT_RESTART_CONTEXT_TOKENS=$value
  printf '%s\n' "$value"
}

# Decimal comparison without shell arithmetic overflow.
fm_context_restart_decimal_ge() {  # <left> <right>
  local left=$1 right=$2
  case "$left:$right" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  if [ "${#left}" -gt "${#right}" ]; then
    return 0
  fi
  if [ "${#left}" -lt "${#right}" ]; then
    return 1
  fi
  [ "$left" = "$right" ] && return 0
  [ "$(printf '%s\n%s\n' "$left" "$right" | LC_ALL=C sort -n | tail -1)" = "$left" ]
}

fm_context_restart_safe_atom() {  # <value>
  local value=$1
  [ -n "$value" ] && [ "${#value}" -le 200 ] || return 1
  case "$value" in *[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_context_restart_record_fail() {
  FM_CONTEXT_RESTART_RECORD_ERROR=$1
  return 1
}

fm_context_restart_record_reset() {
  FM_CONTEXT_RESTART_RECORD_SESSION=
  FM_CONTEXT_RESTART_RECORD_PHASE=
  FM_CONTEXT_RESTART_RECORD_CONTEXT=
  FM_CONTEXT_RESTART_RECORD_BUDGET=
  FM_CONTEXT_RESTART_RECORD_DETECTED_AT=
  FM_CONTEXT_RESTART_RECORD_MODE=
  FM_CONTEXT_RESTART_RECORD_TOKEN=
  FM_CONTEXT_RESTART_RECORD_LOCK_PID=
}

# Parse the exact version-1 crossing record and reject duplicate or unknown keys.
fm_context_restart_record_read() {  # <path>
  local path=$1 links key value seen_version='' seen_session='' seen_phase=''
  local seen_context='' seen_budget='' seen_at='' seen_mode='' seen_token='' seen_lock=''
  fm_context_restart_record_reset
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    fm_context_restart_record_fail "crossing record is not an ordinary regular file"
    return 1
  fi
  links=$(fm_context_restart_link_count "$path") || {
    fm_context_restart_record_fail "could not inspect crossing record link count"
    return 1
  }
  [ "$links" = 1 ] || {
    fm_context_restart_record_fail "crossing record is hardlinked"
    return 1
  }
  while IFS='=' read -r key value || [ -n "$key$value" ]; do
    case "$key" in
      version)
        [ -z "$seen_version" ] && [ "$value" = 1 ] || return 1
        seen_version=1
        ;;
      session_id)
        [ -z "$seen_session" ] && fm_context_restart_safe_atom "$value" || return 1
        seen_session=1
        FM_CONTEXT_RESTART_RECORD_SESSION=$value
        ;;
      phase)
        [ -z "$seen_phase" ] || return 1
        case "$value" in detected|ready) ;; *) return 1 ;; esac
        seen_phase=1
        FM_CONTEXT_RESTART_RECORD_PHASE=$value
        ;;
      context_tokens)
        [ -z "$seen_context" ] || return 1
        case "$value" in ''|*[!0-9]*) return 1 ;; esac
        seen_context=1
        FM_CONTEXT_RESTART_RECORD_CONTEXT=$value
        ;;
      budget_tokens)
        [ -z "$seen_budget" ] || return 1
        case "$value" in ''|0|*[!0-9]*|0*) return 1 ;; esac
        seen_budget=1
        FM_CONTEXT_RESTART_RECORD_BUDGET=$value
        ;;
      detected_at)
        [ -z "$seen_at" ] || return 1
        case "$value" in ''|*[!0-9]*) return 1 ;; esac
        seen_at=1
        FM_CONTEXT_RESTART_RECORD_DETECTED_AT=$value
        ;;
      mode)
        [ -z "$seen_mode" ] || return 1
        case "$value" in automatic|manual) ;; *) return 1 ;; esac
        seen_mode=1
        FM_CONTEXT_RESTART_RECORD_MODE=$value
        ;;
      wrapper_token)
        [ -z "$seen_token" ] || return 1
        case "$value" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
        [ "${#value}" -ge 16 ] && [ "${#value}" -le 128 ] || return 1
        seen_token=1
        FM_CONTEXT_RESTART_RECORD_TOKEN=$value
        ;;
      lock_pid)
        [ -z "$seen_lock" ] || return 1
        case "$value" in ''|*[!0-9]*) return 1 ;; esac
        seen_lock=1
        FM_CONTEXT_RESTART_RECORD_LOCK_PID=$value
        ;;
      *) return 1 ;;
    esac
  done < "$path" || {
    fm_context_restart_record_fail "could not read crossing record"
    return 1
  }
  [ -n "$seen_version$seen_session$seen_phase$seen_context$seen_budget$seen_at" ] \
    && [ -n "$seen_version" ] && [ -n "$seen_session" ] && [ -n "$seen_phase" ] \
    && [ -n "$seen_context" ] && [ -n "$seen_budget" ] && [ -n "$seen_at" ] || {
      fm_context_restart_record_fail "crossing record is incomplete"
      return 1
    }
  if [ "$FM_CONTEXT_RESTART_RECORD_PHASE" = detected ]; then
    [ -z "$seen_mode$seen_token$seen_lock" ] || return 1
  else
    [ -n "$seen_mode" ] && [ -n "$seen_lock" ] || return 1
    if [ "$FM_CONTEXT_RESTART_RECORD_MODE" = automatic ]; then
      [ -n "$seen_token" ] || return 1
    else
      [ -z "$seen_token" ] || return 1
    fi
  fi
}

fm_context_restart_record_publish() {  # <state> <session> <context> <budget> <detected-at> <phase> [mode] [token] [lock-pid]
  local state=$1 session=$2 context=$3 budget=$4 detected_at=$5 phase=$6
  local mode=${7:-} token=${8:-} lock_pid=${9:-} path tmp
  fm_context_restart_safe_atom "$session" || return 1
  case "$context:$budget:$detected_at" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ "$budget" != 0 ] || return 1
  path="$state/.context-restart-crossing"
  tmp=$(umask 077; mktemp "$state/.context-restart-crossing.XXXXXX" 2>/dev/null) || return 1
  {
    printf 'version=1\n'
    printf 'session_id=%s\n' "$session"
    printf 'phase=%s\n' "$phase"
    printf 'context_tokens=%s\n' "$context"
    printf 'budget_tokens=%s\n' "$budget"
    printf 'detected_at=%s\n' "$detected_at"
    if [ "$phase" = ready ]; then
      printf 'mode=%s\n' "$mode"
      [ -z "$token" ] || printf 'wrapper_token=%s\n' "$token"
      printf 'lock_pid=%s\n' "$lock_pid"
    fi
  } > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  if ! fm_context_restart_record_read "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
}
