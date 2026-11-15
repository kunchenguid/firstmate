#!/usr/bin/env bash
# fm-fleet-digest.sh - the whole fleet in one bounded, LLM-free read.
#
# Why this exists: a supervisor turn that reads every state/<id>.meta plus a
# status tail per task costs about 2.9k tokens per task - roughly 750k tokens
# for a 260-task fleet - which exceeds any compaction trigger, so the chair
# compacted on every sweep and never finished a turn. No compaction setting
# fixes that; the workflow does. This script is the workflow: one line per
# task, derived only from the recorded metadata and the newest status line.
#
# It never performs a per-task current-state read. bin/fm-crew-state.sh costs a
# no-mistakes status call and a pane read per task, which is exactly the cost
# this sweep exists to avoid; it belongs in --drill, for the one task a turn
# actually acts on.
#
# Output contract (stdout, one line per task, byte-capped):
#
#   fleet digest: <n> task(s), <e> exception(s), generated <UTC>
#   <id> | <state> | <kind> | <age> | <newest status line, capped>
#   ...
#   (<n> more task(s) omitted by the <bytes>-byte cap - ...)
#
# Exceptions print first and always: failed, needs-decision, blocked, paused,
# stalled (a working task whose status log has not moved within
# FM_FLEET_DIGEST_STALL_SECONDS), and awaiting-gate (a done task with a recorded
# PR, so the merge authority is the only thing left). Everything else is
# routine and is what a byte cap may omit.
#
# state is the newest status EVENT's verb mapped to a current word, never a
# claim about the live pane: done, landed (done with a recorded PR whose merge
# outcome was already delivered, so only cleanup is left), failed,
# needs-decision, blocked, paused, held, working, spawned (no status line yet),
# unknown. A status line is a wake event, not current state (AGENTS.md section
# 8) - use --drill, which runs the authoritative bin/fm-crew-state.sh read,
# before acting on one task.
#
# Usage:
#   fm-fleet-digest.sh                     the whole fleet, and rewrite the ledger
#   fm-fleet-digest.sh --since [<cursor>]  only records changed since the cursor,
#                                          plus every exception; advances the cursor
#   fm-fleet-digest.sh --drill <id>        one task: the authoritative state read
#                                          (probe written under state/digest/) and
#                                          a byte-capped status tail
#   fm-fleet-digest.sh --ledger-only       rewrite state/fleet-ledger.md, print nothing
#
# Options:
#   --since [<cursor>]   Delta mode. <cursor> defaults to state/.fleet-digest-cursor;
#                        a missing or unreadable cursor means "everything is new".
#                        The cursor advances to this run's observation time unless
#                        --no-advance is given.
#   --no-advance         Print the delta without moving the cursor.
#   --drill <id>         Drill into one task (see above). Ignores --since.
#   --bytes <n>          Status-tail bytes for --drill (default 2048).
#   --max-bytes <n>      Cap on printed digest bytes (default 60000, about 15k
#                        tokens at 4 bytes per token).
#   --ledger / --no-ledger
#                        Write state/fleet-ledger.md (default: write it on every
#                        run except --drill).
#   --ledger-only        Write the ledger and print nothing.
#   --now <epoch>        Observation time override, for tests.
#   -h, --help           This help.
#
# The ledger (state/fleet-ledger.md) is the one-file recovery view: the same
# one-line-per-task table plus the open exceptions, rewritten atomically each
# cycle. bin/fm-session-start.sh --compact reads it instead of re-inlining every
# metadata record and status tail.
#
# Read-only apart from its own artifacts: the ledger, the cursor, and the
# --drill probe under state/digest/. It never touches the watcher, the wake
# queue, the supervision branch, or any task record.
set -u

LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

MAX_BYTES=${FM_FLEET_DIGEST_MAX_BYTES:-60000}
case "$MAX_BYTES" in ''|*[!0-9]*|0) MAX_BYTES=60000 ;; esac
LEDGER_MAX_BYTES=${FM_FLEET_DIGEST_LEDGER_MAX_BYTES:-262144}
case "$LEDGER_MAX_BYTES" in ''|*[!0-9]*|0) LEDGER_MAX_BYTES=262144 ;; esac
STALL_SECONDS=${FM_FLEET_DIGEST_STALL_SECONDS:-3600}
case "$STALL_SECONDS" in ''|*[!0-9]*|0) STALL_SECONDS=3600 ;; esac
DRILL_BYTES=${FM_FLEET_DIGEST_DRILL_BYTES:-2048}
case "$DRILL_BYTES" in ''|*[!0-9]*|0) DRILL_BYTES=2048 ;; esac
HEAD_CAP=${FM_FLEET_DIGEST_HEAD_CAP:-120}
case "$HEAD_CAP" in ''|*[!0-9]*|0) HEAD_CAP=120 ;; esac

CURSOR_FILE="$STATE/.fleet-digest-cursor"
LEDGER_FILE="$STATE/fleet-ledger.md"
DIGEST_DIR="$STATE/digest"

usage() {
  sed -n '/^# Usage:/,/^# Read-only apart/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE=full
SINCE_CURSOR=
ADVANCE=1
DRILL_ID=
LEDGER=1
NOW=${FM_FLEET_DIGEST_NOW:-}

while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      MODE=since
      if [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#--}" = "$2" ]; then
        SINCE_CURSOR=$2
        shift
      fi
      ;;
    --no-advance) ADVANCE=0 ;;
    --drill)
      [ $# -ge 2 ] || { printf 'fm-fleet-digest.sh: --drill needs a task id\n' >&2; exit 2; }
      MODE=drill
      DRILL_ID=$2
      shift
      ;;
    --bytes)
      [ $# -ge 2 ] || { printf 'fm-fleet-digest.sh: --bytes needs a number\n' >&2; exit 2; }
      DRILL_BYTES=$2
      case "$DRILL_BYTES" in ''|*[!0-9]*|0) DRILL_BYTES=2048 ;; esac
      shift
      ;;
    --max-bytes)
      [ $# -ge 2 ] || { printf 'fm-fleet-digest.sh: --max-bytes needs a number\n' >&2; exit 2; }
      MAX_BYTES=$2
      case "$MAX_BYTES" in ''|*[!0-9]*|0) MAX_BYTES=60000 ;; esac
      shift
      ;;
    --ledger) LEDGER=1 ;;
    --no-ledger) LEDGER=0 ;;
    --ledger-only) MODE=ledger-only ;;
    --now)
      [ $# -ge 2 ] || { printf 'fm-fleet-digest.sh: --now needs an epoch\n' >&2; exit 2; }
      NOW=$2
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-fleet-digest.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

case "$NOW" in
  ''|*[!0-9]*) NOW=$(date +%s) ;;
esac

# --- small deterministic helpers -------------------------------------------

# file_mtime <path>: epoch seconds of the file's mtime, or empty.
file_mtime() {
  local m
  m=$(stat -c %Y -- "$1" 2>/dev/null) || m=$(stat -f %m -- "$1" 2>/dev/null) || m=
  case "$m" in ''|*[!0-9]*) m= ;; esac
  printf '%s' "$m"
}

# human_age <seconds>: sets HUMAN_AGE to 42s, 17m, 6h, or 3d - one short token,
# never a sentence. A variable rather than a command substitution because this
# runs once per task and a fork per task is the cost this script exists to avoid.
human_age() {
  local s=$1
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 60 ]; then
    HUMAN_AGE="${s}s"
  elif [ "$s" -lt 3600 ]; then
    HUMAN_AGE="$((s / 60))m"
  elif [ "$s" -lt 86400 ]; then
    HUMAN_AGE="$((s / 3600))h"
  else
    HUMAN_AGE="$((s / 86400))d"
  fi
}

# read_meta_fields <meta>: the handful of recorded fields this digest needs, in
# one pass and no subprocess. Sets M_KIND M_PROJECT M_MODEL M_PR M_BACKEND.
read_meta_fields() {
  local line key val
  M_KIND='' M_PROJECT='' M_MODEL='' M_PR='' M_BACKEND=''
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      kind) M_KIND=$val ;;
      project) M_PROJECT=$val ;;
      model) M_MODEL=$val ;;
      pr) M_PR=$val ;;
      backend) M_BACKEND=$val ;;
    esac
  done < "$1" 2>/dev/null || true
}

# last_status_line <status-file>: sets LAST_STATUS_LINE to the newest status
# EVENT, or empty. A read loop rather than `tail` for the same reason as
# human_age: one fork per task is the cost being avoided.
last_status_line() {
  local line
  LAST_STATUS_LINE=
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    LAST_STATUS_LINE=$line
  done < "$1" 2>/dev/null || true
}

# status_verb <line>: the leading state word of a status line.
status_verb() {
  local w=${1%%:*}
  w=${w%% *}
  case "$w" in
    ''|*[!a-z-]*) printf 'other' ;;
    *) printf '%s' "$w" ;;
  esac
}

# state_of <verb>: the current word this digest reports for a status verb.
# `resolved`, `note`, and `ruling` are decision-plane events on a task that is
# still running, so they read working; `captain-held` is a hold, not progress.
state_of() {
  case "$1" in
    done) printf 'done' ;;
    failed) printf 'failed' ;;
    needs-decision) printf 'needs-decision' ;;
    blocked) printf 'blocked' ;;
    paused) printf 'paused' ;;
    captain-held) printf 'held' ;;
    working|resolved|note|ruling) printf 'working' ;;
    other) printf 'unknown' ;;
    *) printf 'spawned' ;;
  esac
}

# exception_of <state> <age-seconds> <pr>: sets EXC_TAG to the exception tag, or
# empty for a routine task. This is the whole "what needs a supervisor" rule.
exception_of() {
  local state=$1 age=$2 pr=$3
  EXC_TAG=
  case "$state" in
    failed|needs-decision|blocked|paused) EXC_TAG=$state ;;
    done)
      [ -z "$pr" ] || EXC_TAG=awaiting-gate
      ;;
    working)
      [ "$age" -lt "$STALL_SECONDS" ] || EXC_TAG=stalled
      ;;
  esac
}

# utc_stamp <epoch>: one ISO-8601 UTC stamp, GNU or BSD date.
utc_stamp() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf '%s' "$1"
}

# --- one row per task -------------------------------------------------------

# Rows are accumulated in two newline-terminated strings so exceptions can be
# printed first and the byte cap can only ever omit routine work.
EXC_ROWS=
ROU_ROWS=
DELTA_ROU_ROWS=
ORPHAN_ROWS=
EXC_COUNT=0
ROU_COUNT=0
ORPHAN_COUNT=0
TASK_COUNT=0
STATE_TALLY=

tally_state() {  # <state>
  case " $STATE_TALLY " in
    *" $1 "*) : ;;
    *) STATE_TALLY="$STATE_TALLY $1" ;;
  esac
}

# build_row <id> <meta> <status>: sets ROW_LINE, ROW_EXC, ROW_CHANGED.
build_row() {
  local id=$1 meta=$2 status=$3 last verb state age mtime meta_mtime pr kind head
  read_meta_fields "$meta"
  kind=${M_KIND:-unknown}
  pr=$M_PR
  last_status_line "$status"
  last=$LAST_STATUS_LINE
  verb=$(status_verb "$last")
  state=$(state_of "$verb")
  # A done task whose recorded PR already delivered its merge outcome is
  # landed: the only work left is cleanup, so it is routine, not a gate.
  if [ "$state" = "done" ] && [ -n "$pr" ] \
    && fm_pr_url_parse "$pr" \
    && fm_pr_poll_merge_already_notified "$STATE" "$id" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
    state=landed
  fi
  mtime=$(file_mtime "$status")
  meta_mtime=
  [ -n "$SINCE_EPOCH" ] && meta_mtime=$(file_mtime "$meta")
  [ -n "$mtime" ] || mtime=$meta_mtime
  [ -n "$mtime" ] || mtime=$NOW
  age=$((NOW - mtime))
  [ "$age" -ge 0 ] || age=0
  if [ -z "$last" ]; then
    head='(no status line yet)'
  else
    fm_cap_line_var "$last" "$HEAD_CAP"
    head=$FM_LINE_CAP_LINE
  fi
  human_age "$age"
  ROW_LINE="$id | $state | $kind | $HUMAN_AGE | $head"
  ROW_STATE=$state
  exception_of "$state" "$age" "$pr"
  ROW_EXC=$EXC_TAG
  ROW_CHANGED=0
  if [ -n "$SINCE_EPOCH" ]; then
    if { [ -n "$mtime" ] && [ "$mtime" -gt "$SINCE_EPOCH" ]; } \
      || { [ -n "$meta_mtime" ] && [ "$meta_mtime" -gt "$SINCE_EPOCH" ]; }; then
      ROW_CHANGED=1
    fi
  else
    # No usable cursor: everything is new, so a first delta is a full read.
    ROW_CHANGED=1
  fi
}

# An orphan status log has no task record: something wrote it and the watcher
# wakes on it, but nothing can be supervised. It is not a task, so it never
# takes a task row: the digest counts them and the ledger lists them.
build_orphan_row() {  # <id> <status>
  local id=$1 status=$2 last verb state age mtime head
  last_status_line "$status"
  last=$LAST_STATUS_LINE
  verb=$(status_verb "$last")
  state=$(state_of "$verb")
  mtime=$(file_mtime "$status")
  [ -n "$mtime" ] || mtime=$NOW
  age=$((NOW - mtime))
  [ "$age" -ge 0 ] || age=0
  if [ -z "$last" ]; then
    head='(no status line yet)'
  else
    fm_cap_line_var "$last" "$HEAD_CAP"
    head=$FM_LINE_CAP_LINE
  fi
  human_age "$age"
  ROW_LINE="$id | unowned | orphan | $HUMAN_AGE | $head"
  ROW_STATE=unowned
  ROW_EXC=unowned
  ROW_CHANGED=1
}

SINCE_EPOCH=
if [ "$MODE" = since ]; then
  cursor=${SINCE_CURSOR:-$CURSOR_FILE}
  if [ -f "$cursor" ] && [ ! -L "$cursor" ]; then
    SINCE_EPOCH=$(sed -n '1p' "$cursor" 2>/dev/null || true)
    case "$SINCE_EPOCH" in ''|*[!0-9]*) SINCE_EPOCH= ;; esac
  fi
fi

collect_rows() {
  local meta id status
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    status="$STATE/$id.status"
    build_row "$id" "$meta" "$status"
    TASK_COUNT=$((TASK_COUNT + 1))
    tally_state "$ROW_STATE"
    if [ -n "$ROW_EXC" ]; then
      EXC_ROWS="$EXC_ROWS$ROW_LINE"$'\n'
      EXC_COUNT=$((EXC_COUNT + 1))
    else
      ROU_ROWS="$ROU_ROWS$ROW_LINE"$'\n'
      ROU_COUNT=$((ROU_COUNT + 1))
      if [ "$MODE" != since ] || [ "$ROW_CHANGED" -eq 1 ]; then
        DELTA_ROU_ROWS="$DELTA_ROU_ROWS$ROW_LINE"$'\n'
      fi
    fi
  done
  for status in "$STATE"/*.status; do
    [ -f "$status" ] || continue
    id=$(basename "$status" .status)
    [ -f "$STATE/$id.meta" ] && continue
    build_orphan_row "$id" "$status"
    ORPHAN_ROWS="$ORPHAN_ROWS$ROW_LINE"$'\n'
    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
  done
}

# --- ledger -----------------------------------------------------------------

# write_ledger: the one-file recovery view, rewritten atomically each cycle.
# It always holds every task, whatever --since printed, because recovery must
# not depend on which delta a previous turn happened to see.
write_ledger() {
  local tmp dir rows omitted=0 line used=0
  dir=$(dirname -- "$LEDGER_FILE")
  [ -d "$dir" ] || return 0
  tmp=$(mktemp "$dir/.fleet-ledger.XXXXXX" 2>/dev/null) || return 0
  {
    printf '# Fleet ledger\n\n'
    printf 'generated: %s (epoch %s)\n' "$(utc_stamp "$NOW")" "$NOW"
    printf 'tasks: %s\n' "$TASK_COUNT"
    printf 'exceptions: %s\n' "$EXC_COUNT"
    printf 'orphan_status_logs: %s\n' "$ORPHAN_COUNT"
    printf 'states:%s\n' "$STATE_TALLY"
    printf 'source: bin/fm-fleet-digest.sh (one line per task: id | state | kind | age | newest status line)\n'
    printf 'note: state is the newest status EVENT mapped to a word, not a live pane read; run bin/fm-crew-state.sh <id> before acting on one task.\n'
    printf '\n## Exceptions (%s)\n\n' "$EXC_COUNT"
    if [ "$EXC_COUNT" -eq 0 ]; then
      printf '(none)\n'
    else
      printf '%s' "$EXC_ROWS"
    fi
    printf '\n## Tasks (routine, %s)\n\n' "$ROU_COUNT"
    if [ "$ROU_COUNT" -eq 0 ]; then
      printf '(none - every task is listed as an exception above)\n'
    fi
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  # The table is bounded only to keep a pathological fleet from writing an
  # unbounded file; the bound is far above any real fleet's table. Exception
  # rows are not repeated here: they are already listed above, so the ledger
  # holds every task exactly once.
  rows=$ROU_ROWS
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    used=$((used + ${#line} + 1))
    if [ "$used" -gt "$LEDGER_MAX_BYTES" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    printf '%s\n' "$line" >> "$tmp" 2>/dev/null || true
  done <<< "$rows"
  if [ "$omitted" -gt 0 ]; then
    printf '\n(%s task row(s) omitted by the %s-byte ledger cap - raise FM_FLEET_DIGEST_LEDGER_MAX_BYTES)\n' \
      "$omitted" "$LEDGER_MAX_BYTES" >> "$tmp" 2>/dev/null || true
  fi
  {
    printf '\n## Orphan status logs (%s)\n\n' "$ORPHAN_COUNT"
    if [ "$ORPHAN_COUNT" -eq 0 ]; then
      printf '(none)\n'
    else
      printf 'No task record: something wrote these and the watcher wakes on them, but nothing supervises them.\n\n'
      printf '%s' "$ORPHAN_ROWS"
    fi
  } >> "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$LEDGER_FILE" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
}

# --- drill ------------------------------------------------------------------

drill() {  # <id>
  local id=$1 meta status probe line used=0
  meta="$STATE/$id.meta"
  status="$STATE/$id.status"
  if [ ! -f "$meta" ] && [ ! -f "$status" ]; then
    printf 'drill %s: no task record (state/%s.meta and state/%s.status are both absent)\n' "$id" "$id" "$id"
    return 1
  fi
  mkdir -p -- "$DIGEST_DIR" 2>/dev/null || true
  probe="$DIGEST_DIR/$id.probe"
  # The authoritative current-state read, paid for exactly one task at a time.
  if [ -x "$SCRIPT_DIR/fm-crew-state.sh" ]; then
    "$SCRIPT_DIR/fm-crew-state.sh" "$id" > "$probe" 2>&1 || true
  else
    printf 'state: unknown · source: none · bin/fm-crew-state.sh is not executable\n' > "$probe"
  fi
  printf 'drill %s (probe: %s)\n' "$id" "$probe"
  if [ -f "$meta" ]; then
    read_meta_fields "$meta"
    printf 'meta: kind=%s project=%s model=%s backend=%s pr=%s\n' \
      "${M_KIND:-?}" "${M_PROJECT##*/}" "${M_MODEL:-?}" "${M_BACKEND:-tmux}" "${M_PR:-none}"
  else
    printf 'meta: absent (orphan status log)\n'
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    fm_cap_line_var "$line" 400
    printf '%s\n' "$FM_LINE_CAP_LINE"
    used=$((used + ${#FM_LINE_CAP_LINE} + 1))
    [ "$used" -lt "$DRILL_BYTES" ] || break
  done < "$probe"
  if [ -f "$status" ]; then
    printf 'status tail (last %s bytes of %s):\n' "$DRILL_BYTES" "$status"
    tail -c "$DRILL_BYTES" -- "$status" 2>/dev/null || true
    printf '\n'
  else
    printf 'status: absent (%s)\n' "$status"
  fi
  return 0
}

# --- main -------------------------------------------------------------------

if [ "$MODE" = drill ]; then
  drill "$DRILL_ID"
  exit $?
fi

collect_rows

if [ "$LEDGER" -eq 1 ] || [ "$MODE" = ledger-only ]; then
  write_ledger
fi

if [ "$MODE" = ledger-only ]; then
  exit 0
fi

# Print: header, every exception, then routine rows while they fit the cap.
printed=0
omitted=0
used=0
header="fleet digest: $TASK_COUNT task(s), $EXC_COUNT exception(s), $ORPHAN_COUNT orphan status log(s), generated $(utc_stamp "$NOW")"
if [ "$MODE" = since ]; then
  header="$header, delta since ${SINCE_EPOCH:-the beginning}"
fi
printf '%s\n' "$header"
used=$((used + ${#header} + 1))

while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [ $((used + ${#line} + 1)) -gt "$MAX_BYTES" ]; then
    omitted=$((omitted + 1))
    continue
  fi
  printf '%s\n' "$line"
  used=$((used + ${#line} + 1))
  printed=$((printed + 1))
done <<< "$EXC_ROWS"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [ $((used + ${#line} + 1)) -gt "$MAX_BYTES" ]; then
    omitted=$((omitted + 1))
    continue
  fi
  printf '%s\n' "$line"
  used=$((used + ${#line} + 1))
  printed=$((printed + 1))
done <<< "$DELTA_ROU_ROWS"

if [ "$omitted" -gt 0 ]; then
  printf '(%s more task(s) omitted by the %s-byte cap - bin/fm-fleet-digest.sh --since, or --drill <id> for one task)\n' \
    "$omitted" "$MAX_BYTES"
fi
if [ "$printed" -eq 0 ]; then
  printf '(no task changed since the cursor and no exception is open)\n'
fi
if [ "$ORPHAN_COUNT" -gt 0 ]; then
  printf 'orphan status logs: %s (no task record; listed in the ledger, not actionable here)\n' "$ORPHAN_COUNT"
fi
printf 'ledger: %s\n' "$LEDGER_FILE"

if [ "$MODE" = since ] && [ "$ADVANCE" -eq 1 ]; then
  tmp=$(mktemp "$STATE/.fleet-digest-cursor.XXXXXX" 2>/dev/null) || tmp=
  if [ -n "$tmp" ] && printf '%s\n' "$NOW" > "$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$CURSOR_FILE" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
  else
    [ -z "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
  fi
fi

exit 0
