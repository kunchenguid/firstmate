#!/usr/bin/env bash
# fm-outcome-batch-lib.sh - hold non-urgent captain outcomes so they reach the
# main session together, never delaying anything urgent.
#
# Sourced, never executed. The supervision host (bin/fm-supervision-host.sh)
# asks fm_outcome_batch_verdict after an attended engine turn recorded captain
# outcomes, instead of always waking main for them, and fm_outcome_batch_due
# while parked. This file is the single
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
# THE RULE. An outcome is urgent unless the records prove it routine. It is
# routine only when all of these hold:
#   - it is one of the turn's captain rows, read back through the outcome
#     store's own validating reader (bin/fm-branch-outcome.sh lookup), so a
#     malformed or partly written store is never trusted;
#   - the supervision engine marked it batchable when it reported it
#     (bin/fm-branch-report.sh --batchable true, recorded in the row), its
#     explicit claim that the outcome asks nothing of anyone; a row without
#     that mark always goes at once, whatever its wording;
#   - its task has a status log that is a readable regular file, whose newest
#     line is working, paused, note, or resolved, and whose folded open set
#     (status_open_decisions, the authoritative fold) is empty, so an earlier
#     question an unrelated progress line did not close still counts;
#   - neither its summary nor its wake text names a blocker, failure, error,
#     sign-in, credential, login, token, password, review, merge, pull request,
#     link, decision, approval, deletion, security, secret, production,
#     incident, or alert, or asks anything (a question mark, or words such as
#     choose, pick, which, option, prefer, confirm, should, answer).
# The last two tests are extra protection against a wrong mark, never a
# reason to hold on their own. One urgent outcome in a turn makes the whole
# turn urgent. A turn with more
# than FM_OUTCOME_BATCH_TURN_MAX (20) captain outcomes is already a batch and
# goes at once, which also bounds the work the rule does per turn. A routine
# turn is held while the oldest held outcome is younger than the window.
#
# RELEASE. Held outcomes are captain rows still unread in the store. The
# supervision host asks fm_outcome_batch_due while it is parked and after each
# handled wake, and hands them to main once the oldest has waited the window,
# when the setting was removed, or whenever the store cannot be read, so an
# uncertainty reaches main rather than waiting. Main's next drain presents all
# of them, whatever wakes it.
#
# The hold record state/.outcome-batch holds only first=<epoch>, the time the
# oldest held outcome was recorded; it is removed only once the store proves no
# captain row is unread. A turn is held only once that record is read back as
# a regular file naming its time, so a release can never be lost; anything
# else at that path sends the turn at once and, while captain rows are unread,
# releases them at the next check.

FM_OUTCOME_BATCH_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_OUTCOME_BATCH_WINDOW_DEFAULT=600
FM_OUTCOME_BATCH_TURN_MAX=20
FM_OUTCOME_BATCH_URGENT_RE='block|fail|error|broke|crash|sign[ -]?in|credential|log[ -]?in|auth|token|password|review|merge|pull request|(^|[^a-z])pr([^a-z]|$)|https?://|decision|decide|approv|delet|destroy|security|secret|prod|incident|alert|outage|down|\?|choose|choice|pick|which|option|prefer|confirm|should|answer|question|(^|[^a-z])ask|let me know|wait'

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

# _fm_outcome_batch_store <state-dir> <subcommand> [args...]: the store's own
# validating reader for this home.
_fm_outcome_batch_store() {
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" "$FM_OUTCOME_BATCH_LIB_DIR/fm-branch-outcome.sh" "$@" 2>/dev/null </dev/null
}

# _fm_outcome_batch_first_unread <state-dir>: print the epoch of the oldest
# unread captain row, or nothing when none; fails when the store cannot be read.
_fm_outcome_batch_first_unread() {
  local rows
  rows=$(_fm_outcome_batch_store "$1" unread) || return 1
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | jq -r -n '[inputs | select(.verdict == "captain") | .epoch] | min // empty' 2>/dev/null
}

# _fm_outcome_batch_tasks_routine <state-dir> <task>...: true only when every
# task's status log is readable and proves it is not waiting on anyone. One
# shell for the whole turn, so the classify library's names stay out of the
# host and its cost does not grow per outcome.
_fm_outcome_batch_tasks_routine() {
  local state=$1
  shift
  bash -c '
    . "$1/fm-classify-lib.sh" || exit 1
    state=$2
    shift 2
    for task in "$@"; do
      case "$task" in "" | */* | *..* | .*) exit 1 ;; esac
      f="$state/$task.status"
      [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || exit 1
      verb=$(grep -v "^[[:space:]]*$" "$f" | tail -n 1 | sed -n "s/^\([a-z-]*\).*/\1/p")
      case "$verb" in working | paused | note | resolved) ;; *) exit 1 ;; esac
      open=$(status_open_decisions "$f") || exit 1
      [ -z "$open" ] || exit 1
    done
  ' _ "$FM_OUTCOME_BATCH_LIB_DIR" "$state" "$@"
}

# fm_outcome_batch_verdict <config-dir> <state-dir> <seq>...
# Prints now or hold for a turn that recorded captain outcome rows <seq>...,
# and keeps the hold record in step. Any unreadable input prints now.
fm_outcome_batch_verdict() {
  local config=$1 state=$2 seq csv='' rows count tasks first now marker
  shift 2
  fm_outcome_batch_config "$config" || { printf 'now\n'; return 0; }
  [ "$#" -gt 0 ] && [ "$#" -le "$FM_OUTCOME_BATCH_TURN_MAX" ] || { printf 'now\n'; return 0; }
  for seq in "$@"; do
    case "$seq" in '' | *[!0-9]*) printf 'now\n'; return 0 ;; esac
    csv=${csv:+$csv,}$seq
  done
  # One validated read for the whole turn.
  rows=$(_fm_outcome_batch_store "$state" lookup --seqs "$csv") || { printf 'now\n'; return 0; }
  count=$(printf '%s\n' "$rows" | jq -s -r --argjson n "$#" '
      if length == $n and all(.[]; .verdict == "captain" and .batchable == true and (.task | type) == "string")
      then length else "bad" end' 2>/dev/null)
  [ "$count" = "$#" ] || { printf 'now\n'; return 0; }
  if printf '%s\n' "$rows" | jq -r '"\(.summary // "") \(.wake // "")"' 2>/dev/null \
    | LC_ALL=C grep -Eiq "$FM_OUTCOME_BATCH_URGENT_RE"; then
    printf 'now\n'
    return 0
  fi
  tasks=$(printf '%s\n' "$rows" | jq -r '.task' | sort -u)
  # shellcheck disable=SC2086 # task ids are validated single words
  _fm_outcome_batch_tasks_routine "$state" $tasks || { printf 'now\n'; return 0; }
  first=$(_fm_outcome_batch_first_unread "$state") || { printf 'now\n'; return 0; }
  now=$(date +%s)
  case "$first" in '' | *[!0-9]*) first=$now ;; esac
  if [ $((now - first)) -ge "$FM_OUTCOME_BATCH_WINDOW" ]; then
    printf 'now\n'
    return 0
  fi
  # Hold only once the release record is published and read back.
  marker=$state/.outcome-batch
  if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    printf 'now\n'
    return 0
  fi
  if printf 'first=%s\n' "$first" >"$marker.tmp.$$" 2>/dev/null \
    && mv -f "$marker.tmp.$$" "$marker" 2>/dev/null \
    && [ -f "$marker" ] && [ ! -L "$marker" ] \
    && [ "$(cat "$marker" 2>/dev/null)" = "first=$first" ]; then
    printf 'hold\n'
    return 0
  fi
  rm -f "$marker.tmp.$$" 2>/dev/null
  printf 'now\n'
}

# fm_outcome_batch_due <config-dir> <state-dir>: true when held outcomes should
# reach main now: their window passed, the setting was removed, the store
# cannot be read, or the hold record is not a regular file. Removes the hold
# record only once no captain row is unread.
fm_outcome_batch_due() {
  local config=$1 state=$2 first marker=$2/.outcome-batch
  [ -e "$marker" ] || [ -L "$marker" ] || return 1
  first=$(_fm_outcome_batch_first_unread "$state") || return 0
  case "$first" in
  '') rm -f "$marker" 2>/dev/null; return 1 ;;
  *[!0-9]*) return 0 ;;
  esac
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  fm_outcome_batch_config "$config" || return 0
  [ $(($(date +%s) - first)) -ge "$FM_OUTCOME_BATCH_WINDOW" ]
}
