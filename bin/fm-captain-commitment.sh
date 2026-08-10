#!/usr/bin/env bash
# fm-captain-commitment.sh - durable follow-through for an explicit captain request.
#
# Usage:
#   fm-captain-commitment.sh open           Record that a captain turn began.
#   fm-captain-commitment.sh defer [<kind>] Mark the open record as left behind.
#   fm-captain-commitment.sh done           Clear the open record; nothing outstanding.
#   fm-captain-commitment.sh track <id>...  Clear it by pointing at backlog work.
#   fm-captain-commitment.sh untrack <id>... Remove links to confirmed-absent work.
#   fm-captain-commitment.sh reconcile      Drop links whose work is verified Done.
#   fm-captain-commitment.sh pending        Print the bounded informational surface.
#   fm-captain-commitment.sh check          Exit 2 with a reminder while outstanding.
#   fm-captain-commitment.sh --help
#
# WHY THIS EXISTS
#
# Two real losses: a captain request interrupted by operational work was never
# finished, and a captain request whose blocker had cleared was never resumed.
# Both needed the captain to ask again. This is the smallest durable record that
# makes an unfinished explicit captain request survive a watcher interruption,
# a compaction, and a restart until it has a concrete completion or points at
# tracked work carrying its own next action.
#
# PRIVACY: NO CAPTAIN TEXT IS EVER STORED
#
# The record holds a schema tag, an open timestamp, and a deferred flag. It never
# holds the captain's words, a hash of them, a transcript, or a secret. Content is
# recovered from the visible session, and the surfaced reminder says so plainly
# rather than reading like a reminder that lost its subject.
#
# `tasks-axi` REMAINS THE SOLE OWNER OF ACTUAL WORK
#
# This is not a second work queue. It holds at most one open record plus a set of
# `linked/<task-id>` markers, and every question about what the work is, whether it
# is under way, held, blocked, or finished is answered by reading `tasks-axi`.
#
# LIFECYCLE
#
#   open      Idempotent. A record that already exists is never replaced, so the
#             OLDEST unacknowledged captain turn is the one preserved, and a
#             restart or a repeated session start cannot duplicate it.
#   defer     Marks the open record deferred. With no argument the caller has
#             already established the interruption: session start calls it that
#             way, because a session that ended without dispositioning its record
#             IS the interruption. With an operational kind, only work that
#             genuinely displaces the captain's request counts, so a session-start
#             nudge and this mechanism's own turn-end follow-up are ignored.
#             Anything else displaces, including an unrecognized kind, because
#             failing toward remembering the request is the safe direction.
#   done      Removes the record. A request finished in the same response takes
#             this path, so it creates no backlog item and no reminder.
#   track     Refuses unless every named item exists, is not Done, and carries a
#             non-empty body. The body is where the next action and completion
#             criterion live, so an item without one cannot discharge the
#             commitment. On success the record is removed and each id is linked.
#   untrack   Refuses unless every named link exists and tasks-axi confirms its
#             item is absent. Read failures preserve every link without mutation.
#   reconcile Removes a link only when its item is verified Done. An unreadable or
#             absent item remains linked and surfaces as broken until repaired.
#
# OUTSTANDING PREDICATE (`check`)
#
# Outstanding means an open record marked deferred, or a linked item that is
# dispatchable right now and not under way. A linked item that is in flight, held,
# or blocked is deliberately quiet: a declared external wait is a normal paused
# work item, and demanding progress against it would loop forever.
#
# `check` is also silent while away mode is active. The captain is absent by
# definition, so nothing new can open, and the away-mode return path drains the
# same informational surface through `fm-wake-drain.sh`. `pending` stays visible
# in every mode because it informs rather than blocks.
#
# SCOPE
#
# Every subcommand except `--help` is completely inert outside a genuine primary
# home, using the same `bin/fm-primary-scope-lib.sh` predicate the turn-end guard
# uses, because a crewmate or scout worktree loads the same tracked integration and
# has no captain.
#
# HARNESS BOUNDARY
#
# Every subcommand here is harness-neutral, and the session-start digest and wake
# drain surface `pending` on every primary. Automatic `open`/`defer`/`check` at the
# turn boundary is a per-harness integration; [`docs/turnend-guard.md`](../docs/turnend-guard.md)
# owns which primaries have it and what the others still get.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

DIR="$STATE/captain-commitment"
OPEN="$DIR/open"
LINKS="$DIR/linked"
AFK="$STATE/.afk"

SCHEMA=fm-captain-commitment.v1
ITEM_BYTES=220
GLOBAL_BYTES=4000

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-commitment: %s\n' "$1" >&2
  exit 1
}

# A task id becomes a filename under linked/, so anything that could escape the
# directory or collide with the record file is refused before it is used.
validate_id() {  # <id>
  case "$1" in
    '' | . | .. | */* | -*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

now_epoch() { date -u +%s; }

iso_at() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf 'unknown time\n'
}

record_field() {  # <field>
  [ -r "$OPEN" ] || return 1
  awk -F'\t' -v key="$1" '$1 == key { print $2; exit }' "$OPEN"
}

# Build the whole record in memory, write it with one checked redirection, and
# promote it only after that write succeeded, so a truncated record can never
# become the live one.
write_record() {  # <opened-epoch> <deferred>
  local tmp body
  mkdir -p "$DIR" || return 1
  body=$(printf 'schema\t%s\nopened\t%s\ndeferred\t%s\n' "$SCHEMA" "$1" "$2") || return 1
  tmp="$DIR/.open.$$"
  printf '%s\n' "$body" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$OPEN" || { rm -f "$tmp"; return 1; }
  return 0
}

# `ln` fails when the target exists, which is the atomic create-if-absent this
# needs: two concurrent opens cannot both win, and the loser leaves the earlier
# record's timestamp intact rather than resetting the clock on a request that has
# already been waiting.
cmd_open() {
  local tmp body
  [ -e "$OPEN" ] && return 0
  mkdir -p "$DIR" || fail "cannot create $DIR"
  body=$(printf 'schema\t%s\nopened\t%s\ndeferred\tno\n' "$SCHEMA" "$(now_epoch)") || return 0
  tmp="$DIR/.open.new.$$"
  rm -f "$tmp"
  printf '%s\n' "$body" > "$tmp" || { rm -f "$tmp"; return 0; }
  ln "$tmp" "$OPEN" 2>/dev/null || true
  rm -f "$tmp"
  return 0
}

# A wake lands within seconds of most captain turns in a busy fleet, so deferring
# on every operational kind would refuse at the end of nearly every turn and train
# a reflexive `done`. These two kinds are structurally not displacement: a
# session-start nudge asks for startup, and turn-end-guard is this mechanism's own
# follow-up, which would otherwise re-arm the record against its own reminder.
displacing_kind() {  # <kind>
  case "$1" in
    session-start | turn-end-guard) return 1 ;;
  esac
  return 0
}

cmd_defer() {  # [<operational-kind>]
  local opened
  [ -n "${1-}" ] && { displacing_kind "$1" || return 0; }
  [ -e "$OPEN" ] || return 0
  [ "$(record_field deferred)" = yes ] && return 0
  opened=$(record_field opened)
  case "$opened" in
    '' | *[!0-9]*) opened=$(now_epoch) ;;
  esac
  write_record "$opened" yes || fail "cannot update $OPEN"
  return 0
}

cmd_done() {
  rm -f "$OPEN" || fail "cannot clear $OPEN"
  return 0
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

# tasks-axi renders a body as a quoted string, an empty body as `""`, and an absent
# value as `-` or `"-"`. What matters here is only whether the item carries a body
# at all, because that is where the next action and completion criterion live.
show_has_body() {  # <show-output>
  local raw
  raw=$(show_field "$1" body)
  case "$raw" in
    '' | '-' | '""' | '"-"') return 1 ;;
  esac
  return 0
}

cmd_track() {
  local id show state
  [ "$#" -gt 0 ] || fail "track needs at least one backlog item id"
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required to link a captain request to tracked work"

  # Validate every id before linking any, so a refusal never leaves a half-linked
  # commitment behind.
  for id in "$@"; do
    validate_id "$id" || fail "invalid backlog item id: $id"
    show=$(task_show "$id") || show=''
    [ -n "$show" ] || fail "backlog item $id does not exist; file the work first"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || fail "backlog item $id is already Done and cannot carry an unfinished captain request"
    show_has_body "$show" \
      || fail "backlog item $id has no body; record the next action and completion criterion with tasks-axi update $id --body-file <path>"
  done

  mkdir -p "$LINKS" || fail "cannot create $LINKS"
  for id in "$@"; do
    : > "$LINKS/$id" || fail "cannot link $id"
  done
  rm -f "$OPEN" || fail "cannot clear $OPEN"
  return 0
}

task_is_confirmed_absent() {  # <id>
  local result rc
  result=$(tasks_axi show "$1" --full 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || return 1
  printf '%s\n' "$result" | grep -Fqx 'code: NOT_FOUND'
}

cmd_untrack() {
  local id
  [ "$#" -gt 0 ] || fail "untrack needs at least one backlog item id"
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required to confirm linked work is absent"

  for id in "$@"; do
    validate_id "$id" || fail "invalid backlog item id: $id"
    [ -f "$LINKS/$id" ] || fail "backlog item $id is not linked to a captain request"
    task_is_confirmed_absent "$id" \
      || fail "cannot confirm backlog item $id is absent; link preserved"
  done

  for id in "$@"; do
    rm -f "$LINKS/$id" || fail "cannot unlink $id"
  done
  return 0
}

link_ids() {
  local path
  [ -d "$LINKS" ] || return 0
  for path in "$LINKS"/*; do
    [ -e "$path" ] || continue
    printf '%s\n' "${path##*/}"
  done
}

cmd_reconcile() {
  local id show state
  command -v tasks-axi >/dev/null 2>&1 || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    show=$(task_show "$id") || continue
    [ -n "$show" ] || continue
    state=$(show_field "$show" state)
    [ "$state" = "done" ] && rm -f "$LINKS/$id"
  done <<EOF
$(link_ids)
EOF
  return 0
}

# A linked item is actionable when it is queued, unheld, and unblocked. Anything
# else is either already moving or waiting on something this mechanism must not
# push against.
link_outstanding_line() {  # <id>
  local show state held blocked
  show=$(task_show "$1") || {
    printf 'Backlog item %s carries a captain request but cannot be read or no longer exists; repair it, or if absent run bin/fm-captain-commitment.sh untrack %s.\n' "$1" "$1"
    return 0
  }
  if [ -z "$show" ]; then
    printf 'Backlog item %s carries a captain request but cannot be read or no longer exists; repair it, or if absent run bin/fm-captain-commitment.sh untrack %s.\n' "$1" "$1"
    return 0
  fi
  state=$(show_field "$show" state)
  [ "$state" = queued ] || return 1
  held=$(show_field "$show" held)
  [ "$held" != yes ] || return 1
  blocked=$(show_field "$show" blocked)
  [ "$blocked" != yes ] || return 1
  printf 'Backlog item %s carries a captain request and is dispatchable now, not under way; complete it with tasks-axi done %s.\n' "$1" "$1"
  return 0
}

open_is_deferred() {
  [ -e "$OPEN" ] || return 1
  [ "$(record_field deferred)" = yes ]
}

# Both surfaces print the same lines. `pending` is informational and always runs;
# `check` turns the same content into a turn-boundary refusal.
outstanding_lines() {
  local opened id count=0 used=0 line bytes
  if open_is_deferred; then
    opened=$(record_field opened)
    case "$opened" in
      '' | *[!0-9]*) opened=0 ;;
    esac
    line="A captain request from $(iso_at "$opened") has no recorded completion."
    printf '%s\n' "$line"
    used=$(( ${#line} + 1 ))
    count=1
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    line=$(link_outstanding_line "$id") || continue
    if [ "${#line}" -gt "$ITEM_BYTES" ]; then
      line="${line:0:$((ITEM_BYTES - 13))} [truncated]"
    fi
    bytes=$(( ${#line} + 1 ))
    [ $((used + bytes)) -le "$GLOBAL_BYTES" ] || continue
    printf '%s\n' "$line"
    used=$((used + bytes))
    count=$((count + 1))
  done <<EOF
$(link_ids)
EOF
  [ "$count" -gt 0 ]
}

recovery_lines() {
  printf 'The request text is not stored anywhere; recover it from the visible session.\n'
  if open_is_deferred; then
    printf 'Finish it and run bin/fm-captain-commitment.sh done, or file it as backlog work with a next action and completion criterion and run bin/fm-captain-commitment.sh track <id>.\n'
  fi
}

cmd_pending() {
  local lines
  cmd_reconcile
  lines=$(outstanding_lines) || return 0
  printf 'OUTSTANDING CAPTAIN REQUEST:\n'
  printf '%s\n' "$lines"
  recovery_lines
  return 0
}

cmd_check() {
  local lines
  [ -e "$AFK" ] && return 0
  cmd_reconcile
  lines=$(outstanding_lines) || return 0
  {
    printf 'OUTSTANDING CAPTAIN REQUEST - this turn would leave an explicit captain request unfinished.\n'
    printf '%s\n' "$lines"
    recovery_lines
  } >&2
  return 2
}

main() {
  local command=${1---help}
  [ "$#" -gt 0 ] && shift
  case "$command" in
    -h | --help | help) usage; return 0 ;;
  esac
  # Crewmate and scout linked worktrees load the same tracked harness integration
  # as the primary. Only a genuine primary home has a captain, so everything else
  # is completely inert rather than accumulating records nobody reads.
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  case "$command" in
    open) cmd_open ;;
    defer) cmd_defer "$@" ;;
    done) cmd_done ;;
    track) cmd_track "$@" ;;
    untrack) cmd_untrack "$@" ;;
    reconcile) cmd_reconcile ;;
    pending) cmd_pending ;;
    check) cmd_check ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
