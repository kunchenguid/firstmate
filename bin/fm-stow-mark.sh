#!/usr/bin/env bash
# Durable last-/stow record and the automatic stow nudge that reads it.
# Usage:
#   fm-stow-mark.sh mark [--transcript <path>] [--session <id>]
#   fm-stow-mark.sh check --transcript <path> [--session <id>]
#   fm-stow-mark.sh read
#   fm-stow-mark.sh summary
#
# The internal /stow skill owns curation judgement; this command owns two
# private records under the effective FM_HOME's state/ and the one decision
# built on them, so the primary runs its memory pass on time instead of relying
# on the captain to remember it.
#
#   state/.stow-mark    key=value lines, written atomically:
#     stowed=<epoch>      when the last /stow pass completed; absent until the
#                         first `mark`
#     bound=<epoch>       when the transcript binding below was last taken
#     session=<id>        the Claude session the binding belongs to, when known
#     transcript=<path>   that session's transcript file
#     offset=<bytes>      the transcript's size at binding time
#     context=<tokens>    the context size at binding time, read from the
#                         newest assistant usage in the transcript; absent when
#                         no usage could be read
#   state/.stow-nudged  one line, the cycle key of the nudge already delivered:
#                       "<stowed epoch or none>:<session id or transcript path>"
#
# `mark` records a completed pass: stowed=now, plus a fresh binding when a
# transcript is named on the command line or already recorded and still
# readable. Without a usable transcript it records only stowed=now and leaves
# the binding to the next `check`.
#
# `check` is the turn-end growth measure. bin/fm-turnend-guard.sh --claude runs
# it at every Stop the guard would otherwise allow, with the Stop payload's
# transcript_path and session_id, and turns exit 3 into its one exit-2
# continuation. It exits 0 silently unless every gate holds: a transcript path
# was given and is a readable regular file; config/stow-nudge (below) does not
# disable the nudge; FM_ROOT is a genuine primary checkout
# (bin/fm-primary-scope-lib.sh); and this process descends from the harness
# session that holds state/.lock (bin/fm-session-lock-lib.sh), so a crewmate,
# scout, or lock-refused session never writes a record or receives a nudge.
# It then binds an absent record, or one bound to another transcript, to the
# current transcript with no nudge on that Stop; likewise, when the record
# holds no context yet and one can now be read, it adopts that reading as the
# cycle's baseline (offset rebound, bound unchanged) with no nudge on that
# Stop. Otherwise it measures, and exits 3 with the nudge text on stdout when
# the cycle key is not already in .stow-nudged and one of these holds:
#   - growth: context now minus context at binding is at least percent% of
#     (window minus context at binding), and greater than zero; when the
#     window is not above the context at binding the growth measure is skipped
#     for that cycle, so a window set below the live context cannot re-nudge
#     on every turn;
#   - compaction: context now is smaller than context at binding, so the
#     conversation was compacted since the binding; the record's context and
#     offset are rebound to the smaller values in the same pass;
#   - horizon: now minus bound is at least hours.
# Delivery is recorded in .stow-nudged before the text is printed, so one cycle
# yields exactly one nudge; `mark` removes that marker as it advances the key.
#
# Context now is the newest non-sidechain `type=assistant` line's usage
# (input + cache_creation + cache_read tokens), read with jq from the last
# FM_STOW_TAIL_BYTES (default 262144) bytes of the transcript; a partial first
# line in that tail is ignored, and so is a line whose model is `<synthetic>`
# (Claude Code's API-error and interruption messages) or whose usage sums to
# zero, so the reading is the newest real usage and is never 0. When no usage
# can be read - unreadable tail, missing jq, only synthetic lines, or a
# transcript format this parser does not recognise - the growth and compaction
# measures are skipped and only the horizon applies.
#
# config/stow-nudge (optional; LOCAL, gitignored, not inherited) is either the
# single word `off` or key=value lines with any of:
#   window=<tokens>   the auto-compact window the measure targets, at least
#                     100000 (Claude Code's own floor); default
#                     CLAUDE_CODE_AUTO_COMPACT_WINDOW when that is a plain token
#                     count of at least 100000 in this process's environment
#                     (a smaller one is ignored), else 200000 when
#                     CLAUDE_CODE_DISABLE_1M_CONTEXT=1, else 1000000
#   percent=<1..99>   how far toward the window the context may grow since the
#                     binding before the nudge fires; default 60
#   hours=<n>         wall-clock horizon since the binding; default 3
# Every number is plain decimal digits with no sign or leading zero. Blank
# lines and #-comments are ignored and the last value of a repeated key
# wins. Any other content, a symlink, or a non-regular file makes the file
# malformed: `check` then treats the nudge as disabled, and `summary` exits 1
# with the reason so bootstrap can surface it as a STOW_NUDGE line.
# docs/configuration.md "Stow nudge" owns the operator-facing description and
# docs/turnend-guard.md "Stow nudge" owns the hook mechanics.
#
# `read` prints the record's lines and exits 1 when there is none. `summary`
# prints one line for the session-start digest - "last /stow pass recorded
# <age> ago" or "no /stow pass recorded yet" - and exits 3 when a recorded pass
# is older than the horizon and the nudge is not off, 0 otherwise.
#
# Exit status: 0 nothing to do or done; 3 nudge due (check) or pass overdue
# (summary); 1 malformed config (summary) or a record that could not be
# written (mark); 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/.stow-mark"
NUDGED="$STATE/.stow-nudged"
TAIL_BYTES=${FM_STOW_TAIL_BYTES:-262144}
case "$TAIL_BYTES" in ''|*[!0-9]*|0) TAIL_BYTES=262144 ;; esac
WINDOW_FLOOR=100000

usage() {
  sed -n '2,95{s/^# \{0,1\}//;p;}' "$0"
}

is_positive_int() {
  case "${1-}" in
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# --- configuration -----------------------------------------------------------
NUDGE_WINDOW=
NUDGE_PERCENT=
NUDGE_HOURS=
NUDGE_OFF=0
CONFIG_ERROR=

default_window() {
  local env_window=${CLAUDE_CODE_AUTO_COMPACT_WINDOW-}
  if is_positive_int "$env_window" && [ "$env_window" -ge "$WINDOW_FLOOR" ]; then
    printf '%s\n' "$env_window"
  elif [ "${CLAUDE_CODE_DISABLE_1M_CONTEXT-}" = 1 ]; then
    printf '200000\n'
  else
    printf '1000000\n'
  fi
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# Sets NUDGE_* from config/stow-nudge, or CONFIG_ERROR and return 1.
load_config() {
  local file="$CONFIG/stow-nudge" line key value
  NUDGE_WINDOW=$(default_window)
  NUDGE_PERCENT=60
  NUDGE_HOURS=3
  NUDGE_OFF=0
  CONFIG_ERROR=
  if [ -L "$file" ]; then
    CONFIG_ERROR="must not be a symlink"
    return 1
  fi
  [ -e "$file" ] || return 0
  if [ ! -f "$file" ]; then
    CONFIG_ERROR="must be a regular file"
    return 1
  fi
  if [ ! -r "$file" ]; then
    CONFIG_ERROR="is not readable"
    return 1
  fi
  if [ "$(tr -d '[:space:]' < "$file")" = off ]; then
    NUDGE_OFF=1
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(trim "$line")
    [ -n "$line" ] || continue
    case "$line" in
      *=*) ;;
      *)
        CONFIG_ERROR="line '$line' is not key=value"
        return 1
        ;;
    esac
    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")
    case "$key" in
      window)
        if ! is_positive_int "$value"; then
          CONFIG_ERROR="window must be a positive token count, got '$value'"
          return 1
        fi
        if [ "$value" -lt "$WINDOW_FLOOR" ]; then
          CONFIG_ERROR="window must be at least $WINDOW_FLOOR tokens, got '$value'"
          return 1
        fi
        NUDGE_WINDOW=$value
        ;;
      percent)
        if ! is_positive_int "$value" || [ "$value" -gt 99 ]; then
          CONFIG_ERROR="percent must be 1..99, got '$value'"
          return 1
        fi
        NUDGE_PERCENT=$value
        ;;
      hours)
        if ! is_positive_int "$value"; then
          CONFIG_ERROR="hours must be a positive integer, got '$value'"
          return 1
        fi
        NUDGE_HOURS=$value
        ;;
      *)
        CONFIG_ERROR="unknown key '$key' (known: window, percent, hours, or the single word off)"
        return 1
        ;;
    esac
  done < "$file"
  return 0
}

# --- record ------------------------------------------------------------------
REC_STOWED=
REC_BOUND=
REC_SESSION=
REC_TRANSCRIPT=
REC_OFFSET=
REC_CONTEXT=

# Loads the record into REC_*; return 1 when there is no record. Numeric
# fields that fail validation read as absent.
record_read() {
  local line
  REC_STOWED='' REC_BOUND='' REC_SESSION='' REC_TRANSCRIPT='' REC_OFFSET='' REC_CONTEXT=''
  [ -f "$RECORD" ] && [ -r "$RECORD" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      stowed=*) REC_STOWED=${line#stowed=} ;;
      bound=*) REC_BOUND=${line#bound=} ;;
      session=*) REC_SESSION=${line#session=} ;;
      transcript=*) REC_TRANSCRIPT=${line#transcript=} ;;
      offset=*) REC_OFFSET=${line#offset=} ;;
      context=*) REC_CONTEXT=${line#context=} ;;
    esac
  done < "$RECORD"
  is_positive_int "$REC_STOWED" || REC_STOWED=
  is_positive_int "$REC_BOUND" || REC_BOUND=
  case "$REC_OFFSET" in ''|*[!0-9]*) REC_OFFSET= ;; esac
  is_positive_int "$REC_CONTEXT" || REC_CONTEXT=
  return 0
}

record_write() {
  local tmp="$RECORD.tmp.$$"
  [ -d "$STATE" ] || return 1
  {
    if [ -n "$REC_STOWED" ]; then printf 'stowed=%s\n' "$REC_STOWED"; fi
    if [ -n "$REC_BOUND" ]; then printf 'bound=%s\n' "$REC_BOUND"; fi
    if [ -n "$REC_SESSION" ]; then printf 'session=%s\n' "$REC_SESSION"; fi
    if [ -n "$REC_TRANSCRIPT" ]; then printf 'transcript=%s\n' "$REC_TRANSCRIPT"; fi
    if [ -n "$REC_OFFSET" ]; then printf 'offset=%s\n' "$REC_OFFSET"; fi
    if [ -n "$REC_CONTEXT" ]; then printf 'context=%s\n' "$REC_CONTEXT"; fi
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  if ! mv -f "$tmp" "$RECORD" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  return 0
}

transcript_usable() {
  [ -n "${1-}" ] && [ -f "$1" ] && [ -r "$1" ]
}

transcript_size() {
  wc -c < "$1" 2>/dev/null | tr -d ' '
}

# Prints the context size recorded by the newest assistant usage in the tail
# of transcript $1, or nothing when it cannot be read.
transcript_context() {
  local file=$1 size out
  command -v jq >/dev/null 2>&1 || return 0
  size=$(transcript_size "$file")
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  out=$(
    if [ "$size" -gt "$TAIL_BYTES" ]; then
      tail -c "$TAIL_BYTES" "$file" 2>/dev/null | sed '1d'
    else
      cat "$file" 2>/dev/null
    fi | jq -R -r '
      fromjson?
      | select(type == "object" and .type == "assistant" and ((.isSidechain // false) | not))
      | .message
      | select(type == "object" and ((.model // "") != "<synthetic>"))
      | .usage
      | select(type == "object")
      | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
      | select(type == "number" and . > 0)
    ' 2>/dev/null | tail -1
  )
  is_positive_int "$out" || return 0
  printf '%s\n' "$out"
}

bind_transcript() {  # <transcript> <session> <now>
  REC_TRANSCRIPT=$1
  REC_SESSION=$2
  REC_BOUND=$3
  REC_OFFSET=$(transcript_size "$1")
  case "$REC_OFFSET" in ''|*[!0-9]*) REC_OFFSET= ;; esac
  REC_CONTEXT=$(transcript_context "$1")
}

# Moves the cycle's baseline to context $2 at transcript $1's current size,
# leaving the binding time alone.
rebind_context() {  # <transcript> <context>
  REC_CONTEXT=$2
  REC_OFFSET=$(transcript_size "$1")
  case "$REC_OFFSET" in ''|*[!0-9]*) REC_OFFSET= ;; esac
  record_write || true
}

# --- formatting --------------------------------------------------------------
fmt_tokens() {
  if [ "$1" -ge 1000 ]; then
    printf '%sk' $(( $1 / 1000 ))
  else
    printf '%s' "$1"
  fi
}

fmt_duration() {
  local secs=$1 days hours mins
  days=$((secs / 86400))
  hours=$((secs % 86400 / 3600))
  mins=$((secs % 3600 / 60))
  if [ "$days" -gt 0 ]; then
    printf '%dd %02dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh %02dm' "$hours" "$mins"
  elif [ "$mins" -gt 0 ]; then
    printf '%dm' "$mins"
  else
    printf 'under 1m'
  fi
}

# --- subcommands -------------------------------------------------------------
parse_binding_args() {  # sets ARG_TRANSCRIPT and ARG_SESSION
  ARG_TRANSCRIPT=
  ARG_SESSION=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --transcript)
        [ "$#" -ge 2 ] || { usage >&2; exit 2; }
        ARG_TRANSCRIPT=$2
        shift 2
        ;;
      --session)
        [ "$#" -ge 2 ] || { usage >&2; exit 2; }
        ARG_SESSION=$2
        shift 2
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
}

cmd_mark() {
  local now transcript session
  parse_binding_args "$@"
  now=$(date +%s)
  record_read || true
  transcript=${ARG_TRANSCRIPT:-$REC_TRANSCRIPT}
  session=${ARG_SESSION:-$REC_SESSION}
  REC_STOWED=$now
  if transcript_usable "$transcript"; then
    bind_transcript "$transcript" "$session" "$now"
  else
    REC_BOUND='' REC_SESSION='' REC_TRANSCRIPT='' REC_OFFSET='' REC_CONTEXT=''
  fi
  if ! record_write; then
    printf 'stow-mark: could not write %s\n' "$RECORD" >&2
    exit 1
  fi
  # A completed pass starts the next cycle: the delivered marker belongs to
  # the cycle that just ended, so drop it rather than rely on the key mismatch.
  rm -f "$NUDGED" 2>/dev/null || true
  if [ -n "$REC_TRANSCRIPT" ]; then
    printf 'stow-mark: recorded the completed /stow pass (context %s tokens at this point)\n' \
      "${REC_CONTEXT:-unknown}"
  else
    printf 'stow-mark: recorded the completed /stow pass; the next turn end binds the transcript\n'
  fi
}

cmd_check() {
  local now transcript session key delivered reason context_now growth room threshold elapsed since
  parse_binding_args "$@"
  transcript=$ARG_TRANSCRIPT
  session=$ARG_SESSION
  transcript_usable "$transcript" || exit 0
  load_config || exit 0
  [ "$NUDGE_OFF" -eq 0 ] || exit 0
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
  now=$(date +%s)
  if ! record_read || [ "$REC_TRANSCRIPT" != "$transcript" ] || [ -z "$REC_BOUND" ]; then
    bind_transcript "$transcript" "$session" "$now"
    record_write || true
    exit 0
  fi
  key="${REC_STOWED:-none}:${session:-$transcript}"
  delivered=$(cat "$NUDGED" 2>/dev/null || true)
  [ "$delivered" != "$key" ] || exit 0
  if [ -n "$REC_STOWED" ]; then
    since='since last /stow'
  else
    since='with no /stow pass recorded'
  fi
  reason=
  context_now=$(transcript_context "$transcript")
  if [ -n "$context_now" ] && [ -z "$REC_CONTEXT" ]; then
    rebind_context "$transcript" "$context_now"
    exit 0
  fi
  if [ -n "$context_now" ]; then
    if [ "$context_now" -lt "$REC_CONTEXT" ]; then
      reason="the context was compacted $since"
      rebind_context "$transcript" "$context_now"
    else
      growth=$((context_now - REC_CONTEXT))
      room=$((NUDGE_WINDOW - REC_CONTEXT))
      if [ "$room" -gt 0 ]; then
        threshold=$((room * NUDGE_PERCENT / 100))
        if [ "$growth" -gt 0 ] && [ "$growth" -ge "$threshold" ]; then
          reason="$(fmt_tokens "$growth") context tokens $since (threshold $(fmt_tokens "$threshold"))"
        fi
      fi
    fi
  fi
  if [ -z "$reason" ]; then
    elapsed=$((now - REC_BOUND))
    if [ "$elapsed" -ge $((NUDGE_HOURS * 3600)) ]; then
      if [ -n "$REC_STOWED" ]; then
        reason="$(fmt_duration "$elapsed") wall clock since the last stow record or this session's first turn end, whichever is later (threshold ${NUDGE_HOURS}h)"
      else
        reason="$(fmt_duration "$elapsed") wall clock since this session's first turn end, with no /stow pass recorded (threshold ${NUDGE_HOURS}h)"
      fi
    fi
  fi
  [ -n "$reason" ] || exit 0
  if ! printf '%s\n' "$key" > "$NUDGED.tmp.$$" 2>/dev/null \
    || ! mv -f "$NUDGED.tmp.$$" "$NUDGED" 2>/dev/null; then
    rm -f "$NUDGED.tmp.$$" 2>/dev/null
    exit 0
  fi
  printf 'firstmate stow nudge: %s; run the /stow pass now\n' "$reason"
  exit 3
}

cmd_read() {
  [ -f "$RECORD" ] || exit 1
  cat "$RECORD"
}

cmd_summary() {
  local now age
  if ! load_config; then
    printf '%s\n' "$CONFIG_ERROR"
    exit 1
  fi
  record_read || true
  if [ -z "$REC_STOWED" ]; then
    printf 'no /stow pass recorded yet\n'
    exit 0
  fi
  now=$(date +%s)
  age=$((now - REC_STOWED))
  [ "$age" -ge 0 ] || age=0
  if [ "$NUDGE_OFF" -eq 0 ] && [ "$age" -ge $((NUDGE_HOURS * 3600)) ]; then
    printf 'last /stow pass recorded %s ago, past the %sh stow-nudge horizon\n' \
      "$(fmt_duration "$age")" "$NUDGE_HOURS"
    exit 3
  fi
  printf 'last /stow pass recorded %s ago\n' "$(fmt_duration "$age")"
  exit 0
}

case "${1:-}" in
  mark) shift; cmd_mark "$@" ;;
  check) shift; cmd_check "$@" ;;
  read) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_read ;;
  summary) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_summary ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
