#!/usr/bin/env bash
# fm-warm-compact-lib.sh - warm-cache compaction for a Claude primary and the
# supervision host's engine conversation (one owner of both).
#
# Sourced, never executed. The supervision host (bin/fm-supervision-host.sh)
# calls it while it is parked, so the trigger lives on the Claude adapter path.
# docs/configuration.md "Warm-cache compaction" owns the home gate and its
# tunables.
#
# WHY. A session that sits idle past its prompt-cache lifetime re-writes its
# whole context at the cache-write price on the next turn. Compacting while the
# cache is still warm reads the old context at the read price, so the next turn
# writes only the summary.
#
# THE GATE (config/warm-compact). Absent means off. A present file enables it;
# its optional lines are
#   idle-seconds=<n>          idle time before a session is due (default 2700)
#   min-context-tokens=<n>    context size below which no session is due (80000)
# Blank lines and lines starting with # are ignored; an unusable value keeps
# its default.
#
# A DUE SESSION is idle for at least idle-seconds, holds at least
# min-context-tokens of context (the last request's input + cache_read +
# cache_creation usage in its transcript), and has not been compacted in this
# idle episode. fm_warm_compact_verdict names the first guard that holds a
# session back; the actions below act only on "due".
#
# THE PRIMARY. fm_warm_compact_primary types /compact through the backend's
# verified submit primitive (fm_backend_send_text_submit, the one the away-mode
# daemon injects through), only when the backend reports the agent not busy and
# the composer provably empty. It never uses raw pane send-text or send-keys.
#
# THE ENGINE. fm_warm_compact_engine resumes the engine conversation with
# /compact as a bounded headless turn (fm_supervision_engine_turn).
#
# A compaction is internal housekeeping: these functions print one verdict word
# and write nothing the captain sees.

FM_WARM_COMPACT_IDLE_DEFAULT=2700
FM_WARM_COMPACT_MIN_DEFAULT=80000
FM_WARM_COMPACT_ENGINE_TIMEOUT_DEFAULT=300

# fm_warm_compact_config <config-dir>: succeed and set FM_WARM_COMPACT_IDLE and
# FM_WARM_COMPACT_MIN when the home opted in; fail when it did not.
fm_warm_compact_config() {
  local file=$1/warm-compact line key value
  [ -f "$file" ] || return 1
  FM_WARM_COMPACT_IDLE=$FM_WARM_COMPACT_IDLE_DEFAULT
  FM_WARM_COMPACT_MIN=$FM_WARM_COMPACT_MIN_DEFAULT
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$value" in '' | 0* | *[!0-9]*) continue ;; esac
    case "$key" in
      idle-seconds) FM_WARM_COMPACT_IDLE=$value ;;
      min-context-tokens) FM_WARM_COMPACT_MIN=$value ;;
    esac
  done < "$file"
  return 0
}

# fm_warm_compact_context_tokens <transcript>: print the context size of the
# transcript's last request, or nothing when it cannot be read.
fm_warm_compact_context_tokens() {
  local transcript=$1
  [ -r "$transcript" ] || return 1
  tail -n 400 "$transcript" 2>/dev/null | jq -R -r '
      fromjson? | select(.type == "assistant") | .message.usage // empty
      | select(type == "object")
      | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
    ' 2>/dev/null | tail -n 1
}

# fm_warm_compact_verdict <config-dir> <idle-seconds> <context-tokens> <compacted 0|1>
# prints off|episode|young|small|due.
fm_warm_compact_verdict() {
  local config=$1 idle=$2 tokens=$3 compacted=$4
  fm_warm_compact_config "$config" || { printf 'off\n'; return 0; }
  if [ "$compacted" = 1 ]; then printf 'episode\n'; return 0; fi
  case "$idle" in '' | *[!0-9]*) printf 'young\n'; return 0 ;; esac
  if [ "$idle" -lt "$FM_WARM_COMPACT_IDLE" ]; then printf 'young\n'; return 0; fi
  case "$tokens" in '' | *[!0-9]*) printf 'small\n'; return 0 ;; esac
  if [ "$tokens" -lt "$FM_WARM_COMPACT_MIN" ]; then printf 'small\n'; return 0; fi
  printf 'due\n'
}

# fm_warm_compact_primary <config-dir> <backend> <target> <idle-seconds> <transcript> <compacted 0|1>
# prints off|episode|young|small|busy|composer|sent|failed. "sent" and "failed"
# both mean a /compact was attempted, so the caller marks the episode.
fm_warm_compact_primary() {
  local config=$1 backend=$2 target=$3 idle=$4 transcript=$5 compacted=$6
  local tokens verdict state
  tokens=$(fm_warm_compact_context_tokens "$transcript")
  verdict=$(fm_warm_compact_verdict "$config" "$idle" "$tokens" "$compacted")
  if [ "$verdict" != due ]; then printf '%s\n' "$verdict"; return 0; fi
  if [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" != idle ]; then
    printf 'busy\n'
    return 0
  fi
  state=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$state" != empty ]; then printf 'composer\n'; return 0; fi
  if [ "$(fm_backend_send_text_submit "$backend" "$target" /compact 3 0.4 0.4 2>/dev/null)" = empty ]; then
    printf 'sent\n'
  else
    printf 'failed\n'
  fi
}

# fm_warm_compact_engine_transcript <session-id>: print the engine
# conversation's transcript path, or fail when none exists.
fm_warm_compact_engine_transcript() {
  local session=$1 root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects dir
  case "$session" in '' | */* | *..*) return 1 ;; esac
  for dir in "$root"/*/; do
    [ -f "$dir$session.jsonl" ] || continue
    printf '%s\n' "$dir$session.jsonl"
    return 0
  done
  return 1
}

# fm_warm_compact_engine <config-dir> <idle-seconds> <session> <engine> <model> <prompt-file> <compacted 0|1> [pid-file]
# prints off|episode|young|small|compacted|failed. Needs
# fm-supervision-engine-lib.sh sourced and STATE set.
fm_warm_compact_engine() {
  local config=$1 idle=$2 session=$3 engine=$4 model=$5 prompt=$6 compacted=$7 pid_file=${8:-}
  local transcript tokens verdict msg result errors rc
  transcript=$(fm_warm_compact_engine_transcript "$session") || transcript=
  tokens=$(fm_warm_compact_context_tokens "$transcript")
  verdict=$(fm_warm_compact_verdict "$config" "$idle" "$tokens" "$compacted")
  if [ "$verdict" != due ]; then printf '%s\n' "$verdict"; return 0; fi
  # shellcheck disable=SC2153 # STATE is the sourcing host's state directory.
  msg=$(mktemp "$STATE/.supervision-host-warm.msg.XXXXXX") || { printf 'failed\n'; return 0; }
  result=$(mktemp "$STATE/.supervision-host-warm.result.XXXXXX") || { rm -f "$msg"; printf 'failed\n'; return 0; }
  errors=$(mktemp "$STATE/.supervision-host-warm.err.XXXXXX") || { rm -f "$msg" "$result"; printf 'failed\n'; return 0; }
  printf '/compact' > "$msg"
  rc=0
  fm_supervision_engine_turn "$engine" "$model" "$prompt" "$msg" "$session" resume \
    "${FM_WARM_COMPACT_ENGINE_TIMEOUT:-$FM_WARM_COMPACT_ENGINE_TIMEOUT_DEFAULT}" "$result" "$errors" "$pid_file" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(fm_supervision_engine_result "$engine" "$result" | sed -n 's/^error=\([01]\).*/\1/p')" = 0 ]; then
    printf 'compacted\n'
  else
    printf 'failed\n'
  fi
  rm -f "$msg" "$result" "$errors"
}
