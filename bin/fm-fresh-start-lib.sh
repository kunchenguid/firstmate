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
#   date=<YYYY-MM-DD>  step=<saving|cleared|skipped>  at=<epoch>
#   1. save   submit /stow, so the session files every durable fact first;
#   2. clear  on a later park after that save turn ended, submit /clear, then a
#             one-line resume prompt. Claude Code's SessionStart hook re-emits
#             the startup digest into the new conversation (docs/
#             sessionstart-nudge.md, source clear), and the resume turn's own
#             Stop hook arms supervision again, so monitoring never depends on
#             the old conversation's park.
# A day whose window closes before step 2 records skipped and never clears an
# unsaved conversation: clear runs only after a save of the same day.
#
# THE GATE. Every step re-checks, and a step is held back while anything the
# current conversation is in the middle of could be dropped by clearing it
# (fm_fresh_start_waiting prints the first one):
#   - an away or quiet record exists (state/.afk);
#   - a wake is queued and unacknowledged (state/.wake-queue);
#   - a needs-decision or blocked line is still open in any status log;
#   - a captain outcome from the supervision session is unprocessed;
#   - a supervision handoff is pending (state/.supervision-handoff-pending);
#   - a request to a secondmate still waits for its reply (state/pending-replies);
#   - a captain inbox note waits for firstmate (state/inbox/*.note).
# A standing captain-held backlog item does not hold a step back: it is a
# durable record the new conversation's startup digest presents again, and a
# home with long-lived holds would otherwise never start fresh.
# Each step also needs the agent idle and the composer provably empty, through
# the same backend primitives warm-cache compaction uses; nothing is typed
# otherwise. A held step is retried on the next tick inside the window.

FM_FRESH_START_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_FRESH_START_HOUR_DEFAULT=4
FM_FRESH_START_WINDOW_DEFAULT=3
FM_FRESH_START_MIN_DEFAULT=100000
FM_FRESH_START_RESUME_PROMPT='Daily fresh start: this conversation was cleared after /stow saved it. The startup digest above is your current state; resume supervision exactly as after any session start.'

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

# fm_fresh_start_waiting <state-dir>: print the first reason clearing the
# conversation now could drop something (THE GATE), or nothing.
fm_fresh_start_waiting() {
  local state=$1 processed open
  if [ -e "$state/.afk" ]; then printf 'away or quiet mode\n'; return 0; fi
  if awk -F '\t' 'NF >= 5 { found = 1; exit } END { exit !found }' "$state/.wake-queue" 2>/dev/null; then
    printf 'a queued wake\n'
    return 0
  fi
  if [ -e "$state/.supervision-handoff-pending" ]; then printf 'a supervision handoff\n'; return 0; fi
  if [ -d "$state/pending-replies" ] && [ -n "$(find "$state/pending-replies" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | head -n 1)" ]; then
    printf 'a secondmate reply\n'
    return 0
  fi
  if [ -f "$state/branch-outcomes.jsonl" ]; then
    processed=$(cat "$state/.branch-outcomes-processed" 2>/dev/null || true)
    case "$processed" in '' | *[!0-9]*) processed=0 ;; esac
    if jq -e -n --argjson p "$processed" '[inputs | select(.verdict == "captain" and (.seq // 0) > $p)] | length > 0' \
      "$state/branch-outcomes.jsonl" >/dev/null 2>&1; then
      printf 'an unprocessed captain outcome\n'
      return 0
    fi
  fi
  if [ -d "$state/inbox" ] && [ -n "$(find "$state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | head -n 1)" ]; then
    printf 'a captain inbox note\n'
    return 0
  fi
  # The status fold runs in its own shell so the host never loads the classify
  # library's names; a failed read counts as open, so the step waits.
  if ! open=$(bash -c '. "$1/fm-classify-lib.sh" && scan_open_decisions "$2"' _ "$FM_FRESH_START_LIB_DIR" "$state" 2>/dev/null); then
    printf 'unreadable status logs\n'
    return 0
  fi
  open=$(printf '%s\n' "$open" | head -n 1)
  if [ -n "$open" ]; then printf 'an open decision (%s)\n' "${open%%$'\t'*}"; return 0; fi
  return 0
}

# fm_fresh_start_record_get <state-dir> <field>
fm_fresh_start_record_get() {
  sed -n "s/^$2=//p" "$1/.daily-fresh-start" 2>/dev/null | head -n 1
}

fm_fresh_start_record_put() {  # <state-dir> <date> <step>
  local tmp
  tmp=$(mktemp "$1/.daily-fresh-start.tmp.XXXXXX") || return 1
  printf 'date=%s\nstep=%s\nat=%s\n' "$2" "$3" "$(date +%s)" >"$tmp" && mv -f "$tmp" "$1/.daily-fresh-start"
}

# fm_fresh_start_step <config-dir> <state-dir> <backend> <target> <transcript> <park-start-epoch>
# Takes at most one step and prints its verdict word:
#   off | done | window | small | waiting:<reason> | busy | composer | saving |
#   cleared | skipped | failed
# Needs fm-backend.sh and fm-warm-compact-lib.sh sourced.
fm_fresh_start_step() {
  local config=$1 state=$2 backend=$3 target=$4 transcript=$5 park_start=$6
  local today hour rec_date rec_step rec_at tokens why state_now
  fm_fresh_start_config "$config" || { printf 'off\n'; return 0; }
  today=$(date +%Y-%m-%d)
  hour=$(date +%H)
  rec_date=$(fm_fresh_start_record_get "$state" date)
  rec_step=$(fm_fresh_start_record_get "$state" step)
  rec_at=$(fm_fresh_start_record_get "$state" at)
  case "$rec_at" in '' | *[!0-9]*) rec_at=0 ;; esac
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
    case "$tokens" in '' | *[!0-9]*) printf 'small\n'; return 0 ;; esac
    if [ "$tokens" -lt "$FM_FRESH_START_MIN" ]; then printf 'small\n'; return 0; fi
  fi
  why=$(fm_fresh_start_waiting "$state")
  if [ -n "$why" ]; then printf 'waiting:%s\n' "$why"; return 0; fi
  # The save turn must have ended before this park began: the park that
  # submitted /stow is not the park that clears.
  if [ "$rec_date" = "$today" ] && [ "$rec_step" = saving ] && [ "$park_start" -le "$rec_at" ]; then
    printf 'saving\n'
    return 0
  fi
  if [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" != idle ]; then printf 'busy\n'; return 0; fi
  state_now=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$state_now" != empty ]; then printf 'composer\n'; return 0; fi
  if [ "$rec_date" != "$today" ] || [ "$rec_step" != saving ]; then
    if [ "$(fm_backend_send_text_submit "$backend" "$target" /stow 3 0.4 0.4 2>/dev/null)" = empty ]; then
      fm_fresh_start_record_put "$state" "$today" saving || true
      printf 'saving\n'
    else
      printf 'failed\n'
    fi
    return 0
  fi
  if [ "$(fm_backend_send_text_submit "$backend" "$target" /clear 3 0.4 0.4 2>/dev/null)" != empty ]; then
    printf 'failed\n'
    return 0
  fi
  fm_fresh_start_record_put "$state" "$today" cleared || true
  # The resume prompt starts the new conversation's first turn, whose Stop
  # hook re-arms supervision. A failed submit still leaves the cleared session
  # with its digest; the next wake or captain message starts that turn.
  sleep "${FM_FRESH_START_SETTLE:-3}"
  fm_backend_send_text_submit "$backend" "$target" "$FM_FRESH_START_RESUME_PROMPT" 3 0.4 0.4 >/dev/null 2>&1 || true
  printf 'cleared\n'
}
