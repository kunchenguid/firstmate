#!/usr/bin/env bash
# fm-fresh-start-lib.sh - a daily fresh conversation for a Claude primary, at a
# quiet hour, after saving, and only when nothing waits on the captain.
#
# Sourced, never executed. The supervision host (bin/fm-supervision-host.sh)
# calls fm_fresh_start_step while it is parked, beside warm-cache compaction
# (bin/fm-warm-compact-lib.sh), so the trigger lives on the Claude adapter path.
# This file is the single owner of the home setting, the waiting gate, and the
# step order. docs/configuration.md "Daily fresh start" is the operator
# reference.
#
# WHY. A primary that is never restarted re-reads a conversation of hundreds of
# thousands of tokens on every call, while durable records, not conversation
# memory, are authoritative (AGENTS.md section 5). A fresh conversation reads
# only the startup digest.
#
# THE SETTING (config/daily-fresh-start). Absent means off. A present file,
# even an empty one, turns it on; its optional lines are
#   hour=<0-23>              local hour the quiet window opens (default 4)
#   window-hours=<1-12>      how long the window stays open (default 3)
#   min-context-tokens=<n>   context below which no fresh start is due (100000)
# Blank lines and lines starting with # are ignored; an unusable value keeps its
# default, like the warm-compact setting beside it.
#
# THE STEPS, at most one per day (the local date), each on its own park so a
# turn always ends between them, recorded in state/.daily-fresh-start as
#   date=<YYYY-MM-DD>  step=<saving|cleared|skipped|cancelled>  at=<epoch>
#   nonce=<random>     transcript=<the primary's session transcript>
#   1. save   submit `/stow daily-fresh-start <nonce>`. The stow skill runs
#             `bin/fm-fresh-start.sh attest <nonce>` as its last action only
#             when its own completion receipt declares the session safe to
#             reset (.agents/skills/stow/SKILL.md "Completion receipt"), which
#             writes state/.daily-fresh-start-attest. Submitting the command
#             proves nothing about the save.
#   2. clear  once that save turn has ended, and only when all of these hold:
#             the attestation names this attempt's nonce; the primary is still
#             the session the save was submitted to (same transcript path); and
#             that session's newest human prompt is still the /stow carrying
#             the nonce, so nothing was said after the save. These and the gate
#             are checked again after the idle and composer probes, right
#             before /clear is typed. Then submit /clear and a one-line resume
#             prompt. Claude
#             Code's SessionStart hook re-emits the startup digest into the
#             new conversation (docs/sessionstart-nudge.md, source clear), and
#             the resume turn's own Stop hook arms supervision again.
# THE PRIMARY'S OWN TURN BOUNDARIES. The primary's prompt-submit and Stop
# hooks call fm_fresh_start_hook (through bin/fm-host-mirror.sh hook claude).
# Any prompt submitted while a save waits, other than that save's own /stow and
# the clear itself, skips the day at once, so a new captain message after the
# save always cancels that day's clear. The Stop that ends the save turn, in
# the session the save was submitted to with the /stow still its newest prompt,
# writes state/.daily-fresh-start-ended naming the nonce: that marker, not a
# later park, is what tells the clear step the save turn is over. Every Stop
# also records the primary's current session transcript in
# state/.daily-fresh-start-session (transcript=<path>), because the host keeps
# running across turns and a fresh start changes the session: the host reads
# that record (fm_fresh_start_transcript) rather than the path it started with.
#
# A save that never attests (failed, interrupted, not reset-safe) never clears:
# the day records skipped when its window closes. A save the session moved past
# (another session, or a later prompt) records skipped at once.
#
# THE GATE. Every step re-checks, and a step is held back while something lives
# only in the current conversation and would be lost with it, and whenever one
# of these inputs cannot be read (fm_fresh_start_waiting prints the first).
# A path that exists only as a link, dangling or not, or as the wrong kind of
# file counts as unreadable, and a wake queue holding anything but whole,
# well-formed rows counts as unreadable rather than empty:
#   - an away or quiet record exists (state/.afk);
#   - a wake is queued and unacknowledged (state/.wake-queue);
#   - a supervision handoff is pending (state/.supervision-handoff-pending);
#   - a request to a secondmate still waits for its reply (state/pending-replies);
#   - a captain outcome is unread, read through the outcome store's own
#     validating reader (bin/fm-branch-outcome.sh);
#   - a captain inbox note waits for firstmate (state/inbox/*.note);
#   - a question firstmate asked the captain in chat is still unanswered: the
#     record bin/fm-chat-question.sh writes when the question is asked and
#     removes when it is answered (state/chat-questions/).
# Durable records that survive a restart and are reprinted at session start do
# not hold it: backlog items held for the captain, open decisions and blockers
# in worker status logs, and captain outcomes already presented but not yet
# acknowledged, which every drain presents again.
# THE SAFETY NET. state/.daily-fresh-start-history holds
#   last=<epoch>    when a fresh start last ran or was not due (the conversation
#                   was below min-context-tokens), or when this home first ran
#                   a step with the setting on; removed while the setting is off
#   reason=<word>   the newest reason a step inside the window did not run; a
#                   conversation whose size cannot be read is a reason, never
#                   a run
#   noted=<epoch>   the `last` a stall note was already sent for
# Once two days and one window have passed since `last` with no run, one check
# wake keyed daily-fresh-start-stalled:<last> asks main to tell the captain,
# naming that reason; `noted` then equals `last`, so nothing more is sent until
# a fresh start runs again and moves `last`.
#
# Each step also needs the agent idle and the composer provably empty, through
# the same backend primitives warm-cache compaction uses; nothing is typed
# otherwise. A held step is retried on the next tick inside the window.

FM_FRESH_START_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_FRESH_START_HOUR_DEFAULT=4
FM_FRESH_START_WINDOW_DEFAULT=3
FM_FRESH_START_MIN_DEFAULT=100000
FM_FRESH_START_RESUME_PROMPT='Daily fresh start: this conversation was cleared after /stow saved it and declared it safe to reset. The startup digest above is your current state; resume supervision exactly as after any session start.'

# fm_fresh_start_config <config-dir>: succeed and set FM_FRESH_START_HOUR,
# FM_FRESH_START_WINDOW and FM_FRESH_START_MIN when the home opted in.
fm_fresh_start_config() {
  local file=$1/daily-fresh-start line key value
  [ -f "$file" ] || return 1
  FM_FRESH_START_HOUR=$FM_FRESH_START_HOUR_DEFAULT
  FM_FRESH_START_WINDOW=$FM_FRESH_START_WINDOW_DEFAULT
  FM_FRESH_START_MIN=$FM_FRESH_START_MIN_DEFAULT
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$value" in '' | *[!0-9]*) continue ;; esac
    [ "${#value}" -le 9 ] || continue
    value=$((10#$value))
    case "$key" in
    hour) [ "$value" -le 23 ] && FM_FRESH_START_HOUR=$value ;;
    window-hours) [ "$value" -ge 1 ] && [ "$value" -le 12 ] && FM_FRESH_START_WINDOW=$value ;;
    min-context-tokens) FM_FRESH_START_MIN=$value ;;
    esac
  done <"$file"
  return 0
}

# fm_fresh_start_in_window <hour-now>: true inside [hour, hour+window), wrapping
# past midnight.
fm_fresh_start_in_window() {
  local now=$((10#$1)) offset
  offset=$(((now - FM_FRESH_START_HOUR + 24) % 24))
  [ "$offset" -lt "$FM_FRESH_START_WINDOW" ]
}

# _fm_fresh_start_dir_has <dir> <find-predicate...>: 0 when the readable
# directory holds a match, 1 when it holds none, 2 when it cannot be read.
_fm_fresh_start_dir_has() {
  local dir=$1 out
  shift
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 2
  out=$(find "$dir" -mindepth 1 -maxdepth 1 "$@" 2>/dev/null) || return 2
  [ -n "$out" ]
}

# fm_fresh_start_waiting <state-dir>: print the first reason clearing the
# conversation now could drop something or cannot be proven safe (THE GATE), or
# nothing.
fm_fresh_start_waiting() {
  local state=$1 rc f out
  if [ -e "$state/.afk" ] || [ -L "$state/.afk" ]; then printf 'away or quiet mode\n'; return 0; fi
  f=$state/.wake-queue
  if [ -e "$f" ] || [ -L "$f" ]; then
    if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
      printf 'an unreadable wake queue\n'
      return 0
    fi
    # Blank lines alone are an empty queue; a row is whole when it has the
    # five tab-separated fields the queue writer appends, a numeric sequence,
    # and its newline. A torn append or any other content is not proof of
    # an empty queue.
    rc=0
    awk -F '\t' '
      /^[[:space:]]*$/ { next }
      NF >= 5 && $2 ~ /^[0-9]+$/ { found = 1; next }
      { bad = 1 }
      END { exit bad ? 3 : (found ? 0 : 1) }
    ' "$f" 2>/dev/null || rc=$?
    if [ "$rc" -ne 3 ] && [ -s "$f" ] && [ "$(tail -c 1 "$f" 2>/dev/null | wc -l | tr -d ' ')" != 1 ]; then
      rc=3
    fi
    case "$rc" in
    0) printf 'a queued wake\n'; return 0 ;;
    1) ;;
    *) printf 'an unreadable wake queue\n'; return 0 ;;
    esac
  fi
  if [ -e "$state/.supervision-handoff-pending" ] || [ -L "$state/.supervision-handoff-pending" ]; then
    printf 'a supervision handoff\n'
    return 0
  fi
  if [ -e "$state/pending-replies" ] || [ -L "$state/pending-replies" ]; then
    rc=0
    _fm_fresh_start_dir_has "$state/pending-replies" ! -name '.*' || rc=$?
    case "$rc" in
    0) printf 'a secondmate reply\n'; return 0 ;;
    2) printf 'an unreadable pending-reply record\n'; return 0 ;;
    esac
  fi
  f=$state/branch-outcomes.jsonl
  if [ -e "$f" ] || [ -L "$f" ]; then
    # The store's reader reads a missing file as empty, so a link or an
    # irregular file is refused here before it is asked.
    if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
      printf 'an unreadable outcome store\n'
      return 0
    fi
    if ! out=$(FM_STATE_OVERRIDE="$state" "$FM_FRESH_START_LIB_DIR/fm-branch-outcome.sh" unread 2>/dev/null); then
      printf 'an unreadable outcome store\n'
      return 0
    fi
    if [ -n "$out" ] && printf '%s\n' "$out" | grep -q '"verdict":"captain"'; then
      printf 'an unread captain outcome\n'
      return 0
    fi
  fi
  if [ -e "$state/inbox" ] || [ -L "$state/inbox" ]; then
    rc=0
    _fm_fresh_start_dir_has "$state/inbox" -name '*.note' || rc=$?
    case "$rc" in
    0) printf 'a captain inbox note\n'; return 0 ;;
    2) printf 'an unreadable captain inbox\n'; return 0 ;;
    esac
  fi
  f=$state/chat-questions
  if [ -e "$f" ] || [ -L "$f" ]; then
    rc=0
    _fm_fresh_start_dir_has "$f" ! -name '.*' || rc=$?
    case "$rc" in
    0)
      out=$(find "$f" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | sort | head -n 1)
      out=${out##*/}
      printf 'an unanswered chat question (%s)\n' "${out%.question}"
      return 0 ;;
    2) printf 'an unreadable chat-question record\n'; return 0 ;;
    esac
  fi
  return 0
}

# fm_fresh_start_record_get <state-dir> <field> [file]
fm_fresh_start_record_get() {
  sed -n "s/^$2=//p" "$1/${3:-.daily-fresh-start}" 2>/dev/null | head -n 1
}

fm_fresh_start_record_put() {  # <state-dir> <date> <step> [nonce] [transcript]
  local tmp
  tmp=$(mktemp "$1/.daily-fresh-start.tmp.XXXXXX") || return 1
  printf 'date=%s\nstep=%s\nat=%s\nnonce=%s\ntranscript=%s\n' "$2" "$3" "$(date +%s)" "${4:-}" "${5:-}" >"$tmp" \
    && mv -f "$tmp" "$1/.daily-fresh-start"
}

# fm_fresh_start_attest <state-dir> <nonce>: record that the stow skill declared
# the session safe to reset for this save attempt. Refuses (1) unless today's
# record is a save waiting on exactly this nonce, so a stale or guessed nonce
# can never license a clear.
fm_fresh_start_attest() {
  local state=$1 nonce=$2 tmp
  case "$nonce" in '' | *[!0-9a-f]*) return 1 ;; esac
  [ "$(fm_fresh_start_record_get "$state" step)" = saving ] || return 1
  [ "$(fm_fresh_start_record_get "$state" date)" = "$(date +%Y-%m-%d)" ] || return 1
  [ "$(fm_fresh_start_record_get "$state" nonce)" = "$nonce" ] || return 1
  tmp=$(mktemp "$state/.daily-fresh-start-attest.tmp.XXXXXX") || return 1
  printf 'nonce=%s\nat=%s\n' "$nonce" "$(date +%s)" >"$tmp" && mv -f "$tmp" "$state/.daily-fresh-start-attest"
}

# fm_fresh_start_last_prompt <transcript>: print, as one JSON string, the newest
# human prompt of a Claude Code session transcript (a user line that is not a
# tool result or injected skill text), or nothing. Fails when a candidate line
# cannot be parsed, so an unreadable transcript never verifies.
fm_fresh_start_last_prompt() {
  local out
  out=$(grep -F '"type":"user"' "$1" 2>/dev/null | jq -c 'select(.type == "user" and (.isMeta // false) != true)
      | .message.content
      | if type == "string" then .
        elif type == "array" then ([.[] | select(.type == "text") | .text] | if length > 0 then join("\n") else empty end)
        else empty end') || return 1
  printf '%s\n' "$out" | tail -n 1
}

_fm_fresh_start_nonce() {
  od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

# fm_fresh_start_step <config-dir> <state-dir> <backend> <target> <transcript>
# Takes at most one step and prints its verdict word:
#   off | done | window | small | unknown | waiting:<reason> | busy | composer |
#   saving | unsaved | cancelled | cleared | skipped | failed
# then keeps the safety net's history (THE SAFETY NET). Needs fm-backend.sh and
# fm-warm-compact-lib.sh sourced.
fm_fresh_start_step() {
  local verdict
  verdict=$(_fm_fresh_start_step_once "$@")
  # Turning the setting off forgets the history, so turning it on again starts
  # a new two-day count rather than reporting the time it was off.
  if [ "$verdict" = off ]; then rm -f "$2/.daily-fresh-start-history"; else _fm_fresh_start_history "$1" "$2" "$verdict"; fi
  printf '%s\n' "$verdict"
}

# _fm_fresh_start_reason_words <verdict>: the plain reason a stall note names.
_fm_fresh_start_reason_words() {
  case "$1" in
  waiting:*) printf 'it was waiting on %s' "${1#waiting:}" ;;
  busy) printf 'the session was busy whenever it looked' ;;
  composer) printf 'the message box held unsent text' ;;
  saving) printf 'it was still waiting for /stow to finish' ;;
  unknown) printf 'the conversation size could not be read' ;;
  cancelled) printf 'a new message arrived after /stow saved the conversation' ;;
  unsaved) printf '/stow never confirmed the session safe to reset' ;;
  skipped) printf '/stow was not confirmed in time, or the conversation moved on after it' ;;
  failed) printf 'typing into the session failed' ;;
  *) printf 'the session was never idle in the quiet window' ;;
  esac
}

# _fm_fresh_start_history <config-dir> <state-dir> <verdict>
_fm_fresh_start_history() {
  local config=$1 state=$2 verdict=$3 file=$2/.daily-fresh-start-history
  local now last reason noted tmp
  fm_fresh_start_config "$config" || return 0
  now=$(date +%s)
  last=$(sed -n 's/^last=//p' "$file" 2>/dev/null | head -n 1)
  reason=$(sed -n 's/^reason=//p' "$file" 2>/dev/null | head -n 1)
  noted=$(sed -n 's/^noted=//p' "$file" 2>/dev/null | head -n 1)
  case "$last" in '' | *[!0-9]*) last=$now ;; esac
  case "$verdict" in
  cleared | small) last=$now reason= ;;
  done | window) ;;
  *) reason=$verdict ;;
  esac
  if [ $((now - last)) -ge $((2 * 86400 + FM_FRESH_START_WINDOW * 3600)) ] && [ "$noted" != "$last" ] \
    && FM_STATE_OVERRIDE="$state" FM_WAKE_QUEUE="$state/.wake-queue" FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock" \
      bash -c '. "$1/fm-wake-lib.sh" && fm_wake_append check "$2" "$3"' _ "$FM_FRESH_START_LIB_DIR" \
      "daily-fresh-start-stalled:$last" \
      "check: the daily fresh start has not run for two days because $(_fm_fresh_start_reason_words "$reason"); tell the captain once, in plain words, and nothing else is needed unless they want that reason cleared" \
      >/dev/null 2>&1 </dev/null; then
    noted=$last
  fi
  tmp=$(mktemp "$state/.daily-fresh-start-history.tmp.XXXXXX") || return 0
  if ! { printf 'last=%s\nreason=%s\nnoted=%s\n' "$last" "$reason" "$noted" >"$tmp" && mv -f "$tmp" "$file"; }; then
    rm -f "$tmp"
  fi
}

# _fm_fresh_start_forget_save <state-dir>: remove the save attempt's markers.
_fm_fresh_start_forget_save() {
  rm -f "$1/.daily-fresh-start-attest" "$1/.daily-fresh-start-ended"
}

# _fm_fresh_start_prompt_is_save <transcript> <nonce>: true when the session's
# newest human prompt is still that save's /stow.
_fm_fresh_start_prompt_is_save() {
  local prompt
  prompt=$(fm_fresh_start_last_prompt "$1") || return 1
  printf '%s\n' "$prompt" | jq -e --arg n "daily-fresh-start $2" 'type == "string" and contains("<command-name>/stow</command-name>") and contains("<command-args>" + $n + "</command-args>")' >/dev/null 2>&1
}

# fm_fresh_start_hook <state-dir> <event> <hook-payload>: the primary's own
# turn boundaries (THE PRIMARY'S OWN TURN BOUNDARIES). Acts only while today's
# save waits; never types anything.
fm_fresh_start_hook() {
  local state=$1 event=$2 payload=$3 rec_date rec_nonce rec_transcript prompt tp tmp
  if [ "$event" = Stop ]; then
    tp=$(printf '%s' "$payload" | jq -r '(.transcript_path // "") | tostring' 2>/dev/null) || tp=
    case "$tp" in
    /*)
      if [ "$(fm_fresh_start_record_get "$state" transcript .daily-fresh-start-session)" != "$tp" ] \
        && tmp=$(mktemp "$state/.daily-fresh-start-session.tmp.XXXXXX"); then
        if ! { printf 'transcript=%s\n' "$tp" >"$tmp" && mv -f "$tmp" "$state/.daily-fresh-start-session"; }; then
          rm -f "$tmp"
        fi
      fi ;;
    esac
  fi
  [ "$(fm_fresh_start_record_get "$state" step)" = saving ] || return 0
  rec_date=$(fm_fresh_start_record_get "$state" date)
  rec_nonce=$(fm_fresh_start_record_get "$state" nonce)
  rec_transcript=$(fm_fresh_start_record_get "$state" transcript)
  case "$event" in
  UserPromptSubmit)
    prompt=$(printf '%s' "$payload" | jq -r '(.prompt // "") | tostring | sub("^\\s+"; "") | sub("\\s+$"; "")' 2>/dev/null) || prompt=
    case "$prompt" in "/stow daily-fresh-start $rec_nonce" | /clear) return 0 ;; esac
    fm_fresh_start_record_put "$state" "$rec_date" cancelled || true
    _fm_fresh_start_forget_save "$state"
    ;;
  Stop)
    tp=$(printf '%s' "$payload" | jq -r '(.transcript_path // "") | tostring' 2>/dev/null) || return 0
    [ -n "$rec_transcript" ] && [ "$tp" = "$rec_transcript" ] || return 0
    _fm_fresh_start_prompt_is_save "$rec_transcript" "$rec_nonce" || return 0
    tmp=$(mktemp "$state/.daily-fresh-start-ended.tmp.XXXXXX") || return 0
    if ! { printf 'nonce=%s\nat=%s\n' "$rec_nonce" "$(date +%s)" >"$tmp" && mv -f "$tmp" "$state/.daily-fresh-start-ended"; }; then
      rm -f "$tmp"
    fi
    ;;
  esac
  return 0
}

# fm_fresh_start_transcript <state-dir> [fallback]: the primary's current
# session transcript as its latest Stop recorded it, else <fallback>.
fm_fresh_start_transcript() {
  local recorded
  if [ -f "$1/.daily-fresh-start-session" ] && [ ! -L "$1/.daily-fresh-start-session" ]; then
    recorded=$(fm_fresh_start_record_get "$1" transcript .daily-fresh-start-session)
    case "$recorded" in /*) printf '%s\n' "$recorded"; return 0 ;; esac
  fi
  [ -z "${2:-}" ] || printf '%s\n' "$2"
}

# _fm_fresh_start_clear_check <state-dir> <transcript> <nonce>: print the
# verdict that stops a clear now, or nothing when the clear may proceed.
_fm_fresh_start_clear_check() {
  local state=$1 transcript=$2 nonce=$3 why
  if [ "$(fm_fresh_start_record_get "$state" step)" != saving ] || [ "$(fm_fresh_start_record_get "$state" nonce)" != "$nonce" ]; then
    printf 'cancelled\n'
    return 0
  fi
  why=$(fm_fresh_start_waiting "$state")
  if [ -n "$why" ]; then printf 'waiting:%s\n' "$why"; return 0; fi
  [ "$(fm_fresh_start_record_get "$state" nonce .daily-fresh-start-attest)" = "$nonce" ] || { printf 'unsaved\n'; return 0; }
  if [ "$(fm_fresh_start_record_get "$state" transcript)" != "$transcript" ] || ! _fm_fresh_start_prompt_is_save "$transcript" "$nonce"; then
    printf 'skipped\n'
  fi
}

_fm_fresh_start_step_once() {
  local config=$1 state=$2 backend=$3 target=$4 transcript=$5
  local today hour rec_date rec_step rec_nonce rec_transcript tokens why state_now nonce
  fm_fresh_start_config "$config" || { printf 'off\n'; return 0; }
  today=$(date +%Y-%m-%d)
  hour=$(date +%H)
  rec_date=$(fm_fresh_start_record_get "$state" date)
  rec_step=$(fm_fresh_start_record_get "$state" step)
  rec_nonce=$(fm_fresh_start_record_get "$state" nonce)
  rec_transcript=$(fm_fresh_start_record_get "$state" transcript)
  if [ "$rec_date" = "$today" ] && [ "$rec_step" = cancelled ]; then printf 'cancelled\n'; return 0; fi
  if [ "$rec_date" = "$today" ] && [ "$rec_step" != saving ]; then printf 'done\n'; return 0; fi
  if ! fm_fresh_start_in_window "$hour"; then
    if [ "$rec_date" = "$today" ] && [ "$rec_step" = saving ]; then
      fm_fresh_start_record_put "$state" "$today" skipped || true
      printf 'skipped\n'
      return 0
    fi
    printf 'window\n'
    return 0
  fi
  if [ "$rec_date" != "$today" ] || [ "$rec_step" != saving ]; then
    tokens=$(fm_warm_compact_context_tokens "$transcript")
    case "$tokens" in '' | *[!0-9]*) printf 'unknown\n'; return 0 ;; esac
    if [ "$tokens" -lt "$FM_FRESH_START_MIN" ]; then printf 'small\n'; return 0; fi
  fi
  why=$(fm_fresh_start_waiting "$state")
  if [ -n "$why" ]; then printf 'waiting:%s\n' "$why"; return 0; fi
  if [ "$rec_date" = "$today" ] && [ "$rec_step" = saving ]; then
    # The save turn must have ended: its own Stop hook names this nonce.
    if [ -z "$rec_nonce" ] || [ "$(fm_fresh_start_record_get "$state" nonce .daily-fresh-start-ended)" != "$rec_nonce" ]; then
      printf 'saving\n'
      return 0
    fi
    why=$(_fm_fresh_start_clear_check "$state" "$transcript" "$rec_nonce")
    case "$why" in
    unsaved) printf 'unsaved\n'; return 0 ;;
    skipped)
      # The save belongs to the session it was submitted to, and nothing may
      # have been said after it; otherwise its receipt no longer covers what
      # the conversation holds, and today is skipped rather than cleared.
      fm_fresh_start_record_put "$state" "$today" skipped || true
      _fm_fresh_start_forget_save "$state"
      printf 'skipped\n'
      return 0 ;;
    ?*) printf '%s\n' "$why"; return 0 ;;
    esac
  fi
  if [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" != idle ]; then printf 'busy\n'; return 0; fi
  state_now=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$state_now" != empty ]; then printf 'composer\n'; return 0; fi
  if [ "$rec_date" != "$today" ] || [ "$rec_step" != saving ]; then
    nonce=$(_fm_fresh_start_nonce)
    case "$nonce" in '' | *[!0-9a-f]*) printf 'failed\n'; return 0 ;; esac
    _fm_fresh_start_forget_save "$state"
    # Recorded before the submit, so an attestation from the save turn always
    # finds the nonce it names.
    fm_fresh_start_record_put "$state" "$today" saving "$nonce" "$transcript" || { printf 'failed\n'; return 0; }
    if [ "$(fm_backend_send_text_submit "$backend" "$target" "/stow daily-fresh-start $nonce" 3 0.4 0.4 2>/dev/null)" = empty ]; then
      printf 'saving\n'
    else
      fm_fresh_start_record_put "$state" "$today" skipped || true
      printf 'failed\n'
    fi
    return 0
  fi
  # Anything that arrived during the probes above stops the clear: the save,
  # the gate, the attestation, and the newest prompt are read once more at the
  # last moment before the one destructive keystroke.
  why=$(_fm_fresh_start_clear_check "$state" "$transcript" "$rec_nonce")
  case "$why" in
  skipped)
    fm_fresh_start_record_put "$state" "$today" skipped || true
    _fm_fresh_start_forget_save "$state"
    printf 'skipped\n'
    return 0 ;;
  ?*) printf '%s\n' "$why"; return 0 ;;
  esac
  if [ "$(fm_backend_send_text_submit "$backend" "$target" /clear 3 0.4 0.4 2>/dev/null)" != empty ]; then
    printf 'failed\n'
    return 0
  fi
  fm_fresh_start_record_put "$state" "$today" cleared || true
  _fm_fresh_start_forget_save "$state"
  # The resume prompt starts the new conversation's first turn, whose Stop
  # hook re-arms supervision. A failed submit still leaves the cleared session
  # with its digest; the next wake or captain message starts that turn.
  sleep "${FM_FRESH_START_SETTLE:-3}"
  fm_backend_send_text_submit "$backend" "$target" "$FM_FRESH_START_RESUME_PROMPT" 3 0.4 0.4 >/dev/null 2>&1 || true
  printf 'cleared\n'
}
