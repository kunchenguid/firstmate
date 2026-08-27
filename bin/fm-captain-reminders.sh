#!/usr/bin/env bash
# fm-captain-reminders.sh - project what is waiting on the captain into the
# macOS Reminders app, one way.
#
# WHY. A captain call lives durably in the backlog, but the backlog is something
# firstmate reads and the captain does not. A question raised on one day sinks
# out of the conversation on the next with nothing to push it back into view.
# This projects those calls onto a surface the captain already carries: a
# Reminders list, which syncs to the phone on its own and can raise an alert.
#
# ONE WAY, ALWAYS. Firstmate's backlog is the authority and Reminders is a
# window onto it. Nothing is ever read back: a reminder the captain edits,
# reorders, flags, or completes changes no task here, and the next sync simply
# restates the backlog. The one thing that survives him ticking an entry off is
# the memory that he was already alerted for that call, so restating it does not
# ring him a second time - see ALERTING, ONCE PER CALL below.
#
# Usage:
#   fm-captain-reminders.sh sync [--fresh <task-id>]...
#   fm-captain-reminders.sh status
#
# `sync` is an idempotent FULL projection, not an incremental one: it may be run
# at any moment, from any path, as often as wanted. There is no hook to miss and
# no event to lose, because a skipped run is repaired by the next one.
# `status` is the same computation printed as a plan, touching nothing.
#
# WHAT IT PROJECTS. Every unresolved task in the active FM_HOME carrying
# `hold_kind=captain` whose hold_until date is absent or due - the calls the
# captain must rule on and the ones he must carry out himself, which are the same
# thing in the data. Progress and future deferrals never appear here. Work that
# is simply finished never appears here either: this list is the captain's own
# to-do, not a log of what the fleet did, so an item exists only while it is
# waiting on him and one call is always one entry, never merged with another.
#
#   reminder title -> the task title
#   reminder note  -> `<hold reason>（项目：<repo>） [fm:<task-id>]`
#
# WRITTEN FOR THE CAPTAIN. The note leads with the sentence he has to read and
# ends with the marker, because the note is what a phone shows under the title.
# What makes that sentence readable is upstream of here: the hold reason and the
# task title are captain-facing text by the contract in
# bin/fm-captain-hold.sh's header, and this script projects them as written
# rather than trying to rewrite internal wording into plain speech.
#
# THE MARKER IS THE SAFETY BOUNDARY. `[fm:<task-id>]` at the tail of the note is
# how a rerun recognizes what it already created, so a rerun never duplicates.
# It is also the hard limit on what this script may touch: an entry without the
# marker at either the tail or the head is never read, matched, renamed,
# rewritten, or completed. The head placement is read-only, kept so an entry a
# previous version of this script created there still matches and gets rewritten
# to the tail form on its next sync instead of being orphaned; only the tail
# form is ever written. The list is the captain's own, and quietly editing
# something he wrote there is worse than missing a projection entirely.
#
# COMPLETION, NEVER DELETION. A marked entry whose task is no longer held for
# the captain is marked COMPLETED. Nothing here deletes a reminder. Recording
# the captain's answer is what ends a call, so his entry disappears when he
# rules on it rather than when the work it gated finally lands.
#
# ALERTING, ONCE PER CALL. Every entry this projection CREATES is given a due
# time of now, so Reminders raises it - on the phone too, which a desktop banner
# never reaches. Nothing reaches this list unless it needs the captain, so there
# is nothing here worth adding silently.
#
# The bound on that is state/.captain-reminders-alerted, a durable record of the
# calls he has already been rung for, pruned on every pass to the calls still
# waiting on him. It exists because ticking an entry off hides it from every
# query here, so without a memory outside the list the next pass would recreate
# the entry and ring him again for something he has already read. An entry that
# is merely refreshed never rings at all, because the Reminders side sets a due
# time only on the entry it creates.
#
# `--fresh <id>` is not about alerting: it tells this run that it carries a call
# the lock holder's snapshot predates, so it must not stand down on contention.
#
# SWITCH. Entirely inert until this home opts in with `config/captain-reminders`
# (local, gitignored). Absent: every command is a silent no-op that exits 0.
# Present: its first line, trimmed, is the target list name, and an empty file
# means `Firstmate`. The list is created on first use. Present but unreadable is
# neither of those and is reported rather than defaulted, because filing the
# captain's calls into a list he did not choose hides them on a synced account.
#
# CONCURRENCY, AND WHAT IS ACTUALLY GUARANTEED. One projection lock under
# `state/` serializes callers. An ordinary projection that loses the lock stands
# down and exits 0 - the holder is deriving the same full set and will write the
# same entries. A projection carrying `--fresh` does NOT stand down: the
# holder's snapshot predates that call, so nobody else will ever raise it. It
# waits inside its own deadline and, if that runs out, says the call did not
# reach the list rather than exiting as though it had.
#
# The lock cannot make duplication impossible, and this script does not claim it
# does. Checking for an entry and creating one are not atomic at the Reminders
# boundary, and the ways to close that last window all cost more than the window
# does: they either weaken bin/fm-timeout-lib.sh's group-kill guarantee for the
# whole repository, or push job control into session start (see the nesting note
# in that library's header for why an outer bound cannot reach an inner one).
# So the guarantee here is CONVERGENCE, not prevention: every projection ticks
# off any extra entry sharing a marker, leaving exactly one open. A duplicate can
# therefore exist briefly, and it is settled by the next pass - which is the same
# property this whole capability already rests on. A transient second copy of a
# call cannot make the captain miss it; losing his one alert can, which is why
# the surviving entry is chosen as the one that will actually fire.
#
# DEGRADING. Never a hard failure for the caller, which is always some other
# piece of work that must not be held up by a reminder.
#   - Not macOS, or no `osascript`: one diagnostic line, exit 0.
#   - The backlog snapshot, the whole projection, and every individual Reminders
#     call share the FM_REMINDERS_TIMEOUT_SECS deadline (default 10) through
#     bin/fm-timeout-lib.sh, which kills the whole process group. A first-run
#     automation prompt only the captain can answer would otherwise hang this
#     indefinitely, and this runs on the supervision path.
#   - A bound hit or a refused authorization prints what to do about it, in
#     words, rather than an AppleScript error number.
#
# SEAM. bin/fm-captain-reminders-osa-lib.sh is the only place that talks to the
# Reminders app. FM_REMINDERS_EXEC replaces osascript for tests: it is called as
# `<cmd> <verb> <args...>` with the same arguments and the same stdout contract,
# so the projection logic is exercised on a host with no Reminders app.
# Verbs: `list <listname>`, `upsert <listname> <id> <title> <note> <due0|1>`,
# `complete <listname> <id>`, `complete-one <listname> <id> <reminder-id>`.
# Which of several entries sharing a marker survives is decided in THIS file
# rather than in AppleScript, so that rule is covered by the regression suite.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-tasks-show-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-show-lib.sh"
# shellcheck source=bin/fm-captain-reminders-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-captain-reminders-lib.sh"

REMINDERS_EXEC=${FM_REMINDERS_EXEC:-}
TIMEOUT_SECS=${FM_REMINDERS_TIMEOUT_SECS:-10}
case "$TIMEOUT_SECS" in ''|*[!0-9]*|0) TIMEOUT_SECS=10 ;; esac

WORK_DIR=
PROJECTION_LOCK=
PROJECTION_LOCK_HELD=0
cleanup() {
  [ -z "$WORK_DIR" ] || rm -rf -- "$WORK_DIR"
  [ "$PROJECTION_LOCK_HELD" -eq 0 ] || fm_lock_release "$PROJECTION_LOCK"
}
trap cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

note() { printf 'captain-reminders: %s\n' "$*"; }

# Sourced after `note` because the Reminders side reports through it.
# shellcheck source=bin/fm-captain-reminders-osa-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-captain-reminders-osa-lib.sh"

# --- the projection -----------------------------------------------------------

list_contains() {  # <newline-separated-list> <value>
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Which of several entries sharing one marker survives, decided here rather than
# in AppleScript so the rule is exercised by the regression suite on a host with
# no Reminders app.
#
# The rule, in order:
#   1. an entry that carries a due time beats one that does not, because that is
#      the entry that will actually alert - ticking it off in favour of a silent
#      twin would lose this call its one alert;
#   2. otherwise the older entry survives, so the accidental copy is the one that
#      goes and anything the captain added to the original is kept.
# Both keys come from the list read itself, so the outcome does not depend on
# which entry happened to be scanned first.
keeper_reminder_id() {  # <rows> <task-id>
  printf '%s\n' "$1" | awk -F'\t' -v want="$2" '
    NF >= 4 && $1 == want {
      due = $3 + 0
      age = $4 + 0
      if (best == "" || due > best_due || (due == best_due && age < best_age)) {
        best = $2
        best_due = due
        best_age = age
      }
    }
    END { print best }
  '
}

# Tick off every extra entry sharing a marker, keeping exactly one.
#
# This is convergence rather than prevention. Creating an entry cannot be made
# atomic with checking for one at the Reminders boundary, and the alternatives
# for closing that window all cost more than the window does: they either weaken
# the repository's single owner of bounded execution or push job control into
# session start. A transient duplicate cannot make the captain miss anything,
# and every projection is a full idempotent pass, so applying that same property
# one level down settles the list back to one open entry per call.
CONVERGED_COUNT=0
converge_duplicates() {  # <list-name> <rows> <dry-run 0|1>
  local list_name=$1 rows=$2 dry=$3 dup_ids id keeper row_id row_rid _rest rc=0
  CONVERGED_COUNT=0
  dup_ids=$(printf '%s\n' "$rows" | awk -F'\t' '
    NF >= 4 { seen[$1]++ }
    END { for (k in seen) if (seen[k] > 1) print k }
  ' | LC_ALL=C sort)
  [ -n "$dup_ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    keeper=$(keeper_reminder_id "$rows" "$id")
    [ -n "$keeper" ] || continue
    while IFS=$'\t' read -r row_id row_rid _rest; do
      [ "$row_id" = "$id" ] || continue
      [ "$row_rid" != "$keeper" ] || continue
      if [ "$dry" -eq 1 ]; then
        printf 'would tick off a duplicate entry for %s\n' "$id"
        CONVERGED_COUNT=$((CONVERGED_COUNT + 1))
        continue
      fi
      if projection_osa complete-one "$list_name" "$id" "$row_rid"; then
        note "ticked off a duplicate entry for $id"
        CONVERGED_COUNT=$((CONVERGED_COUNT + 1))
      else
        rc=1
        [ "$PROJECTION_TIMED_OUT" -eq 0 ] || return 1
      fi
    done <<INNER
$rows
INNER
  done <<EOF
$dup_ids
EOF
  return "$rc"
}

# --- the already-rung record --------------------------------------------------
#
# Every entry this projection CREATES carries an alert, because by the captain's
# own rule nothing reaches this list unless it needs him. That default is only
# safe with a durable memory of which calls have already been put in front of
# him, because an entry he ticks off while the call is still open is simply gone
# from a projection's view - every query here filters on `completed is false` -
# so the next pass would recreate it and ring him a second time for something he
# has already read. Reading the list cannot answer this: a ticked-off entry is
# invisible and a deleted one never existed.
#
# The record is therefore this file, in the same shape as the repo's other
# "reported once" records (state/.tool-updates, state/<id>.pr-poll-merge-notified):
# a schema line, then one task id per line.
#
# It is pruned to the calls that are still waiting on the captain on every pass,
# so the memory lives exactly as long as the call does. A call he answers leaves
# the backlog, leaves this record, and leaves his list; if the same work is
# raised for him again later it is a new call and rings again, which is right.
ALERTED_SCHEMA=fm-captain-reminders-alerted-v1
ALERTED_RECORD=

alerted_read() {
  local first=1 line
  [ -n "$ALERTED_RECORD" ] || return 0
  [ -f "$ALERTED_RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      # An unrecognized record is treated as no memory at all, which costs one
      # extra alert rather than silently trusting a file this script did not write.
      [ "$line" = "$ALERTED_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    printf '%s\n' "$line"
  done < "$ALERTED_RECORD"
}

alerted_write() {  # <newline-separated task ids>
  local tmp
  [ -n "$ALERTED_RECORD" ] || return 1
  [ ! -L "$ALERTED_RECORD" ] || return 1
  tmp=$(umask 077; mktemp "$ALERTED_RECORD.XXXXXX" 2>/dev/null) || return 1
  {
    printf '%s\n' "$ALERTED_SCHEMA"
    printf '%s\n' "$1" | awk 'NF'
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$ALERTED_RECORD" || { rm -f -- "$tmp"; return 1; }
}


PROJECTION_DEADLINE=0
PROJECTION_REMAINING=0
PROJECTION_TIMED_OUT=0

projection_budget() {
  local now
  now=$(date +%s) || { PROJECTION_TIMED_OUT=1; return 1; }
  case "$now" in ''|*[!0-9]*) PROJECTION_TIMED_OUT=1; return 1 ;; esac
  PROJECTION_REMAINING=$((PROJECTION_DEADLINE - now))
  if [ "$PROJECTION_REMAINING" -le 0 ]; then
    PROJECTION_TIMED_OUT=1
    return 1
  fi
}

projection_osa() {  # <verb> <args...>
  projection_budget || return 1
  OSA_TIMEOUT_SECS=$TIMEOUT_SECS
  [ "$PROJECTION_REMAINING" -ge "$OSA_TIMEOUT_SECS" ] || OSA_TIMEOUT_SECS=$PROJECTION_REMAINING
  if osa "$@"; then
    return 0
  fi
  [ "$OSA_TIMED_OUT" -eq 0 ] || PROJECTION_TIMED_OUT=1
  return 1
}

run_projection() {  # <dry-run 0|1> <fresh-ids newline-separated>
  local dry=$1 fresh=$2 list_name desired desired_ids projected projected_rows stale_ids=''
  local id title body due outcome now rc desired_count stale_count total remaining
  local alerted='' to_alert='' alerted_next=''
  local failures=0 acted=0 processed=0

  list_name=$(fm_reminders_list_name "$CONFIG")
  rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *)
      note "config/captain-reminders exists but could not be read; nothing was projected."
      note "fix its permissions, or remove it to turn the projection off - defaulting the list name here would file the captain's calls somewhere he is not looking."
      return 1
      ;;
  esac
  if [ -z "$REMINDERS_EXEC" ]; then
    if [ "$(uname)" != Darwin ] || ! command -v osascript >/dev/null 2>&1; then
      note "skipped - the Reminders projection needs macOS with osascript."
      return 0
    fi
  fi

  now=$(date +%s) || { note "could not start the Reminders deadline; nothing was projected."; return 1; }
  case "$now" in ''|*[!0-9]*) note "could not start the Reminders deadline; nothing was projected."; return 1 ;; esac
  PROJECTION_DEADLINE=$((now + TIMEOUT_SECS))
  PROJECTION_TIMED_OUT=0
  FM_TASKS_AXI_DEADLINE=$PROJECTION_DEADLINE

  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  PROJECTION_LOCK="$STATE/.captain-reminders.lock"
  ALERTED_RECORD="$STATE/.captain-reminders-alerted"
  # Lock contention means one thing for an ordinary projection and the opposite
  # for a run carrying a call that was only just registered.
  #
  # An ordinary projection has an exact peer: the holder is deriving the same
  # full set from the same backlog and will write the same entries, so standing
  # down is the correct result rather than a failure, and it keeps a projection
  # from ever waiting on the deadline.
  #
  # A run named with --fresh has no such peer. The holder's snapshot was taken
  # before this call existed, so it cannot create this entry and will never ring
  # it. Standing down would leave the captain's newest call sitting silently in
  # the backlog until something else happened to sync, which is exactly the
  # failure this whole capability exists to prevent. So such a run waits, inside
  # the deadline it already has, and says so plainly if it runs out.
  if ! fm_lock_try_acquire "$PROJECTION_LOCK"; then
    [ -n "$fresh" ] || return 0
    until fm_lock_try_acquire "$PROJECTION_LOCK"; do
      if ! projection_budget; then
        note "another projection held the list for the whole ${TIMEOUT_SECS}s deadline; $(printf '%s' "$fresh" | tr '\n' ' ') did NOT reach the captain's list."
        return 1
      fi
      sleep 0.1
    done
  fi
  PROJECTION_LOCK_HELD=1

  WORK_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-captain-reminders.XXXXXX") || {
    note "could not stage a working directory; nothing was projected."
    return 1
  }

  if desired=$(fm_reminders_desired); then
    :
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then
      PROJECTION_TIMED_OUT=1
      note "projection did not finish before the ${TIMEOUT_SECS}s deadline; the captain backlog snapshot was left incomplete and no reminders were touched."
    else
      note "could not read or parse the captain backlog snapshot; nothing was projected."
    fi
    return 1
  fi
  if ! projection_budget; then
    note "projection did not finish before the ${TIMEOUT_SECS}s deadline; the captain backlog snapshot was read but no reminders were touched."
    return 1
  fi
  desired_ids=$(printf '%s\n' "$desired" | cut -f1)
  desired_count=$(printf '%s\n' "$desired" | awk 'NF { n++ } END { print n + 0 }')
  # Which of these calls the captain has already been rung for, and which are
  # new to him. Pruning to the calls still waiting on him happens here, in one
  # place, so the memory can never outlive the call it belongs to.
  alerted=$(alerted_read)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if list_contains "$alerted" "$id"; then
      alerted_next=${alerted_next:+$alerted_next$'\n'}$id
    else
      to_alert=${to_alert:+$to_alert$'\n'}$id
    fi
  done <<EOF
$desired_ids
EOF
  if ! projection_osa list "$list_name"; then
    if [ "$PROJECTION_TIMED_OUT" -eq 1 ]; then
      note "projection did not finish before the ${TIMEOUT_SECS}s deadline; $desired_count backlog entries were left unprocessed and existing list entries were not inspected."
    fi
    return 1
  fi
  projected_rows=$OSA_OUT
  projected=$(printf '%s\n' "$projected_rows" | cut -f1 | awk 'NF' | LC_ALL=C sort -u)
  if ! converge_duplicates "$list_name" "$projected_rows" "$dry"; then
    [ "$PROJECTION_TIMED_OUT" -eq 0 ] || {
      note "projection did not finish before the ${TIMEOUT_SECS}s deadline while reconciling duplicate entries."
      return 1
    }
    failures=$((failures + 1))
  fi
  acted=$((acted + CONVERGED_COUNT))


  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
    list_contains "$desired_ids" "$id" && continue
    list_contains "$stale_ids" "$id" && continue
    if [ -n "$stale_ids" ]; then stale_ids="$stale_ids"$'\n'"$id"; else stale_ids=$id; fi
  done <<EOF
$projected
EOF
  stale_count=$(printf '%s\n' "$stale_ids" | awk 'NF { n++ } END { print n + 0 }')
  total=$((desired_count + stale_count))

  while IFS=$'\t' read -r id title body; do
    [ -n "$id" ] || continue
    # A created entry rings unless the captain has already been rung for this
    # call. The Reminders side only ever sets a due time on the entry it
    # creates, so an entry that is merely refreshed cannot ring either way.
    due=0
    list_contains "$to_alert" "$id" && due=1
    if list_contains "$projected" "$id"; then
      if [ "$dry" -eq 1 ]; then
        printf 'would check %s (%s) and refresh it only if its title or reason changed\n' "$id" "$title"
        acted=$((acted + 1))
        continue
      fi
    else
      if [ "$dry" -eq 1 ]; then
        if [ "$due" -eq 1 ]; then
          printf 'would add %s (%s) and alert the captain\n' "$id" "$title"
        else
          printf 'would add %s (%s) without alerting him again\n' "$id" "$title"
        fi
        acted=$((acted + 1))
        continue
      fi
    fi
    if projection_osa upsert "$list_name" "$id" "$title" "$body" "$due"; then
      outcome=$OSA_OUT
      # Reached his list under any outcome, so he has seen this call and must
      # not be rung for it again. Recorded AFTER the entry exists, the same way
      # this repo's other report-once records commit: a record that cannot be
      # written costs at worst one repeated alert, while recording first would
      # cost a call its only alert.
      list_contains "$alerted_next" "$id" \
        || alerted_next=${alerted_next:+$alerted_next$'\n'}$id
      case "$outcome" in
        created)
          if [ "$due" -eq 1 ]; then
            note "added $id ($title) and alerted the captain"
          else
            note "added $id ($title) without a fresh alert"
          fi
          acted=$((acted + 1))
          ;;
        updated) note "refreshed $id ($title)"; acted=$((acted + 1)) ;;
      esac
    else
      [ "$PROJECTION_TIMED_OUT" -eq 0 ] || break
      failures=$((failures + 1))
    fi
    processed=$((processed + 1))
  done <<EOF
$desired
EOF

  # One write per pass, placed here so a run cut short by the deadline still
  # remembers the calls it did ring, instead of ringing them again next time.
  if [ "$dry" -eq 0 ] && ! alerted_write "$alerted_next"; then
    note "could not record which calls have already been alerted; a later sync may alert one of them a second time."
    failures=$((failures + 1))
  fi

  if [ "$PROJECTION_TIMED_OUT" -eq 0 ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if [ "$dry" -eq 1 ]; then
        printf 'would tick off %s (no longer waiting on the captain)\n' "$id"
        acted=$((acted + 1))
        continue
      fi
      if projection_osa complete "$list_name" "$id"; then
        note "ticked off $id (no longer waiting on the captain)"
        acted=$((acted + 1))
      else
        [ "$PROJECTION_TIMED_OUT" -eq 0 ] || break
        failures=$((failures + 1))
      fi
      processed=$((processed + 1))
    done <<EOF
$stale_ids
EOF
  fi

  if [ "$PROJECTION_TIMED_OUT" -eq 1 ]; then
    remaining=$((total - processed))
    note "projection did not finish before the ${TIMEOUT_SECS}s deadline; $remaining entries were left unprocessed."
    return 1
  fi

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    list_contains "$desired_ids" "$id" && continue
    note "nothing to project for $id - it is not held for the captain in this home."
  done <<EOF
$fresh
EOF

  if [ "$dry" -eq 1 ] && [ "$acted" -eq 0 ]; then
    printf 'list "%s" already matches the backlog; nothing to do.\n' "$list_name"
  fi
  [ "$failures" -eq 0 ]
}

parse_and_run() {  # <dry-run 0|1> <args...>
  local dry=$1 fresh=''
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fresh)
        shift
        case "${1:-}" in
          ''|*[!A-Za-z0-9._-]*) note "--fresh needs a task id"; return 2 ;;
        esac
        if [ -n "$fresh" ]; then fresh="$fresh"$'\n'"$1"; else fresh=$1; fi
        ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
  run_projection "$dry" "$fresh"
}

case "${1:-}" in
  sync) shift; parse_and_run 0 "$@" ;;
  status) shift; parse_and_run 1 "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
