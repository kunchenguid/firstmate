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
# WHAT IT PROJECTS. Every task in the active FM_HOME's backlog that is held with
# `hold_kind=captain` - the calls the captain must rule on and the ones he must
# carry out himself, which are the same thing in the data. Progress is not a
# captain call and never appears here.
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
# means `Firstmate`. The list is created on first use.
#
# DEGRADING. Never a hard failure for the caller, which is always some other
# piece of work that must not be held up by a reminder.
#   - Not macOS, or no `osascript`: one diagnostic line, exit 0.
#   - Every Reminders call is bounded by FM_REMINDERS_TIMEOUT_SECS (default 10)
#     through bin/fm-timeout-lib.sh, which kills the whole process group. A
#     first-run automation prompt only the captain can answer would otherwise
#     hang this indefinitely, and this runs on the supervision path.
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
cleanup() { [ -z "$WORK_DIR" ] || rm -rf -- "$WORK_DIR"; }
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

run_projection() {  # <dry-run 0|1> <notify-ids newline-separated>
  local dry=$1 notify=$2 list_name desired desired_ids projected id title body
  local due outcome failures=0 acted=0

  list_name=$(fm_reminders_list_name "$CONFIG") || return 0
  if [ -z "$REMINDERS_EXEC" ]; then
    if [ "$(uname)" != Darwin ] || ! command -v osascript >/dev/null 2>&1; then
      note "skipped - the Reminders projection needs macOS with osascript."
      return 0
    fi
  fi

  WORK_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-captain-reminders.XXXXXX") || {
    note "could not stage a working directory; nothing was projected."
    return 1
  }

  desired=$(fm_reminders_desired)
  desired_ids=$(printf '%s\n' "$desired" | cut -f1)
  osa list "$list_name" || return 1
  projected=$OSA_OUT

  # Every captain call the backlog holds: added when the list has no entry for
  # it yet, refreshed in place when the title or the reason has moved on.
  while IFS=$'\t' read -r id title body; do
    [ -n "$id" ] || continue
    due=0
    if list_contains "$projected" "$id"; then
      [ "$dry" -eq 0 ] || { printf 'would refresh %s (%s)\n' "$id" "$title"; acted=$((acted + 1)); continue; }
    else
      list_contains "$notify" "$id" && due=1
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
    if osa upsert "$list_name" "$id" "$title" "$body" "$due"; then
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
      failures=$((failures + 1))
    fi
  done <<EOF
$desired
EOF

  # Marked entries the backlog no longer holds for the captain. Completed, never
  # removed, so anything the captain added to the entry survives.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
    list_contains "$desired_ids" "$id" && continue
    if [ "$dry" -eq 1 ]; then
      printf 'would tick off %s (no longer waiting on the captain)\n' "$id"
      acted=$((acted + 1))
      continue
    fi
    if osa complete "$list_name" "$id"; then
      note "ticked off $id (no longer waiting on the captain)"
      acted=$((acted + 1))
    else
      failures=$((failures + 1))
    fi
  done <<EOF
$projected
EOF

  # A named push that matched no captain call is a typo, not a quiet no-op.
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
