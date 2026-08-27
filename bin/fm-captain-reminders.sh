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
# reorders, flags, or completes changes nothing here, and the next sync simply
# restates the backlog.
#
# Usage:
#   fm-captain-reminders.sh sync [--notify <task-id>]...
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
# thing in the data. Progress and future deferrals never appear here.
#
#   reminder title -> the task title
#   reminder note  -> `[fm:<task-id>] <hold reason>`
#
# THE MARKER IS THE SAFETY BOUNDARY. `[fm:<task-id>]` at the head of the note is
# how a rerun recognizes what it already created, so nothing is ever duplicated.
# It is also the hard limit on what this script may touch: an entry without that
# marker is never read, matched, renamed, rewritten, or completed. The list is
# the captain's own, and quietly editing something he wrote there is worse than
# missing a projection entirely.
#
# COMPLETION, NEVER DELETION. A marked entry whose task is no longer held for
# the captain is marked COMPLETED. Nothing here deletes a reminder.
#
# PUSHING. A captain call only pushes when the caller says so: `--notify <id>`
# sets a due time of now on that entry, so Reminders raises it - on the phone
# too, which a desktop banner never reaches. It applies only to an entry created
# by this run, so a rerun cannot re-alert a call the captain has already seen.
# Whether a call is worth interrupting for is the caller's judgment, deliberately
# not this script's: it never infers urgency.
#
# SWITCH. Entirely inert until this home opts in with `config/captain-reminders`
# (local, gitignored). Absent: every command is a silent no-op that exits 0.
# Present: its first line, trimmed, is the target list name, and an empty file
# means `Firstmate`. The list is created on first use. Present but unreadable is
# neither of those and is reported rather than defaulted, because filing the
# captain's calls into a list he did not choose hides them on a synced account.
#
# CONCURRENCY. One projection lock under `state/` makes "never creates a
# duplicate" hold when several callers fire at once. An ordinary projection that
# loses the lock stands down and exits 0 - the holder is deriving the same full
# set and will write the same entries. A projection carrying `--notify` does NOT
# stand down: the holder's snapshot predates that call, so nobody else will ever
# raise it. It waits inside its own deadline and, if that runs out, says the
# alert was not delivered rather than exiting as though it had been.
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
# `complete <listname> <id>`.
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

run_projection() {  # <dry-run 0|1> <notify-ids newline-separated>
  local dry=$1 notify=$2 list_name desired desired_ids projected stale_ids=''
  local id title body due outcome now rc desired_count stale_count total remaining
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
  # Lock contention means one thing for an ordinary projection and the opposite
  # for a named push.
  #
  # An ordinary projection has an exact peer: the holder is deriving the same
  # full set from the same backlog and will write the same entries, so standing
  # down is the correct result rather than a failure, and it keeps a projection
  # from ever waiting on the deadline.
  #
  # A named push has no such peer. The holder's snapshot was taken before this
  # call existed, so it cannot create this entry and will never set its due time
  # - and a later ordinary sync would then create it with no alert at all. The
  # one push the caller explicitly authorized would be lost silently, which is
  # exactly the failure this whole capability exists to prevent. So a named push
  # waits, inside the deadline it already has, and says so plainly if it runs out.
  if ! fm_lock_try_acquire "$PROJECTION_LOCK"; then
    [ -n "$notify" ] || return 0
    until fm_lock_try_acquire "$PROJECTION_LOCK"; do
      if ! projection_budget; then
        note "another projection held the list for the whole ${TIMEOUT_SECS}s deadline; the alert for $(printf '%s' "$notify" | tr '\n' ' ') was NOT delivered."
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
  if ! projection_osa list "$list_name"; then
    if [ "$PROJECTION_TIMED_OUT" -eq 1 ]; then
      note "projection did not finish before the ${TIMEOUT_SECS}s deadline; $desired_count backlog entries were left unprocessed and existing list entries were not inspected."
    fi
    return 1
  fi
  projected=$OSA_OUT

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
    due=0
    list_contains "$notify" "$id" && due=1
    if list_contains "$projected" "$id"; then
      if [ "$dry" -eq 1 ]; then
        printf 'would check %s (%s) and refresh it only if its title or reason changed\n' "$id" "$title"
        acted=$((acted + 1))
        continue
      fi
    else
      if [ "$dry" -eq 1 ]; then
        if [ "$due" -eq 1 ]; then
          printf 'would add %s (%s), alerting the captain now\n' "$id" "$title"
        else
          printf 'would add %s (%s)\n' "$id" "$title"
        fi
        acted=$((acted + 1))
        continue
      fi
    fi
    if projection_osa upsert "$list_name" "$id" "$title" "$body" "$due"; then
      outcome=$OSA_OUT
      case "$outcome" in
        created)
          if [ "$due" -eq 1 ]; then
            note "added $id ($title) and alerted the captain"
          else
            note "added $id ($title)"
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
    note "nothing to alert for $id - it is not held for the captain in this home."
  done <<EOF
$notify
EOF

  if [ "$dry" -eq 1 ] && [ "$acted" -eq 0 ]; then
    printf 'list "%s" already matches the backlog; nothing to do.\n' "$list_name"
  fi
  [ "$failures" -eq 0 ]
}

parse_and_run() {  # <dry-run 0|1> <args...>
  local dry=$1 notify=''
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --notify)
        shift
        case "${1:-}" in
          ''|*[!A-Za-z0-9._-]*) note "--notify needs a task id"; return 2 ;;
        esac
        if [ -n "$notify" ]; then notify="$notify"$'\n'"$1"; else notify=$1; fi
        ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
  run_projection "$dry" "$notify"
}

case "${1:-}" in
  sync) shift; parse_and_run 0 "$@" ;;
  status) shift; parse_and_run 1 "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
