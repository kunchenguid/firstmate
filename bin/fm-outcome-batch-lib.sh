#!/usr/bin/env bash
# fm-outcome-batch-lib.sh - hold non-urgent captain outcomes so they reach the
# main session together, never delaying anything urgent.
#
# Sourced, never executed. The supervision host (bin/fm-supervision-host.sh)
# asks fm_outcome_batch_verdict after an attended engine turn recorded captain
# outcomes, instead of always waking main for them. This file is the single
# owner of the setting, the urgency rule, and the hold record.
# docs/configuration.md "Outcome batching" is the operator reference.
#
# WHY. Each wake of the main session re-reads its whole conversation, so ten
# routine notes delivered in one turn cost one re-read instead of ten.
#
# THE SETTING (config/outcome-batch). Absent means off: every captain outcome
# wakes main at once, as before. A present file, even an empty one, turns the
# hold on; its optional line is
#   window-seconds=<60-3600>   longest a routine outcome waits (default 600)
# Blank lines, lines starting with #, and unusable values keep the default.
#
# THE RULE. An outcome is urgent unless it is positively routine. It is urgent
# when its summary or its wake text names a blocker, failure, error, sign-in,
# credential, login, token, password, review, merge, pull request, URL,
# decision, approval, deletion, security, secret, production, incident, or
# alert, or when the newest line of its task's status log is anything but
# working, paused, note, or resolved. One urgent outcome in a turn makes the
# whole turn urgent. A routine turn is held while the oldest held outcome is
# younger than the window; once the window passes, the next turn that records
# a captain outcome or the next handled wake releases them all.
#
# Nothing is lost by holding: every held outcome stays an unprocessed row in
# the outcome store, and main's next drain presents all of them, whatever wakes
# it - a captain message, another event, or the release. The hold record
# state/.outcome-batch holds only first=<epoch>, the time the oldest held
# outcome was recorded; it is removed when no captain outcome is unprocessed.

FM_OUTCOME_BATCH_WINDOW_DEFAULT=600
FM_OUTCOME_BATCH_URGENT_RE='block|fail|error|broke|crash|sign[ -]?in|credential|log[ -]?in|auth|token|password|review|merge|pull request|(^|[^a-z])pr([^a-z]|$)|https?://|decision|decide|approv|delet|destroy|security|secret|prod|incident|alert|outage|down'

# fm_outcome_batch_config <config-dir>: succeed and set FM_OUTCOME_BATCH_WINDOW
# when the home opted in.
fm_outcome_batch_config() {
  local file=$1/outcome-batch line value
  [ -f "$file" ] || return 1
  FM_OUTCOME_BATCH_WINDOW=$FM_OUTCOME_BATCH_WINDOW_DEFAULT
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in window-seconds=*) value=${line#window-seconds=} ;; *) continue ;; esac
    case "$value" in '' | *[!0-9]*) continue ;; esac
    [ "${#value}" -le 4 ] || continue
    value=$((10#$value))
    [ "$value" -ge 60 ] && [ "$value" -le 3600 ] && FM_OUTCOME_BATCH_WINDOW=$value
  done <"$file"
  return 0
}

# fm_outcome_batch_routine <state-dir> <outcome-json-line>: true only for an
# outcome THE RULE proves routine.
fm_outcome_batch_routine() {
  local state=$1 row=$2 text task verb
  text=$(printf '%s\n' "$row" | jq -r '"\(.summary // "") \(.wake // "")"' 2>/dev/null) || return 1
  [ -n "$text" ] || return 1
  if printf '%s\n' "$text" | LC_ALL=C grep -Eiq "$FM_OUTCOME_BATCH_URGENT_RE"; then return 1; fi
  task=$(printf '%s\n' "$row" | jq -r '.task // empty' 2>/dev/null)
  case "$task" in '' | */* | *..*) return 1 ;; esac
  verb=$(grep -v '^[[:space:]]*$' "$state/$task.status" 2>/dev/null | tail -n 1 | sed -n 's/^\([a-z-]*\).*/\1/p')
  case "$verb" in working | paused | note | resolved) return 0 ;; esac
  return 1
}

# fm_outcome_batch_unprocessed_first <state-dir>: print the epoch of the oldest
# unprocessed captain outcome, or nothing.
fm_outcome_batch_unprocessed_first() {
  local state=$1 processed
  processed=$(cat "$state/.branch-outcomes-processed" 2>/dev/null || true)
  case "$processed" in '' | *[!0-9]*) processed=0 ;; esac
  jq -r -n --argjson p "$processed" '[inputs | select(.verdict == "captain" and (.seq // 0) > $p) | .epoch // 0] | min // empty' \
    "$state/branch-outcomes.jsonl" 2>/dev/null
}

# fm_outcome_batch_verdict <config-dir> <state-dir> <seq>...
# Prints now or hold for a turn that recorded captain outcome rows <seq>...,
# and keeps the hold record in step. Any unreadable input prints now.
fm_outcome_batch_verdict() {
  local config=$1 state=$2 seq row first now
  shift 2
  fm_outcome_batch_config "$config" || { printf 'now\n'; return 0; }
  [ "$#" -gt 0 ] || { printf 'now\n'; return 0; }
  for seq in "$@"; do
    case "$seq" in '' | *[!0-9]*) printf 'now\n'; return 0 ;; esac
    row=$(jq -c --argjson s "$seq" 'select(.seq == $s)' "$state/branch-outcomes.jsonl" 2>/dev/null | head -n 1)
    if [ -z "$row" ] || ! fm_outcome_batch_routine "$state" "$row"; then
      rm -f "$state/.outcome-batch"
      printf 'now\n'
      return 0
    fi
  done
  first=$(fm_outcome_batch_unprocessed_first "$state")
  now=$(date +%s)
  case "$first" in '' | *[!0-9]*) first=$now ;; esac
  if [ $((now - first)) -ge "$FM_OUTCOME_BATCH_WINDOW" ]; then
    rm -f "$state/.outcome-batch"
    printf 'now\n'
    return 0
  fi
  printf 'first=%s\n' "$first" >"$state/.outcome-batch.tmp.$$" && mv -f "$state/.outcome-batch.tmp.$$" "$state/.outcome-batch"
  printf 'hold\n'
}

# fm_outcome_batch_due <config-dir> <state-dir>: true when held outcomes have
# waited the whole window and should be released now; clears a stale record.
fm_outcome_batch_due() {
  local config=$1 state=$2 first
  [ -f "$state/.outcome-batch" ] || return 1
  first=$(fm_outcome_batch_unprocessed_first "$state")
  case "$first" in '' | *[!0-9]*) rm -f "$state/.outcome-batch"; return 1 ;; esac
  fm_outcome_batch_config "$config" || { rm -f "$state/.outcome-batch"; return 0; }
  [ $(($(date +%s) - first)) -ge "$FM_OUTCOME_BATCH_WINDOW" ]
}
