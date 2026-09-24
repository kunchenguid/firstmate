#!/usr/bin/env bash
# fm-lavish-board-guard.sh - detect a crew-hosted Lavish review board that was
# opened but never armed.
#
# Usage:
#   fm-lavish-board-guard.sh scan
#
# THE DEFECT THIS EXISTS FOR. A worker opens a Lavish board, posts its URL in a
# status line, and never arms it. The board stays open, the captain annotates
# it, the browser shows "Your agent is not listening", and every comment sits
# queued on the server. Nothing errors and nothing is lost - the feedback simply
# never reaches anyone, so the only way the captain found out was by saying so
# in chat.
#
# WHY THE ARM-AND-ACKNOWLEDGE CONTRACT DOES NOT ALREADY COVER IT. Once a board
# IS armed, the process-event runner owns its listener: it captures each round,
# delivers it to the owner's steering inbox, redelivers an open round on every
# reconcile, restarts a source whose owner is gone, and refuses to retire a
# board with an unacknowledged round. An armed board is therefore attended in
# every state `bin/fm-procevent.sh list` reports - `listening`, `round-open`,
# and `dead` alike - and this scan must stay silent for all three.
# None of that machinery exists until the arm happens. A board that was never
# armed has no registration to reconcile, no owner to redeliver to, and no
# claim to restart. docs/configuration.md "Crew-hosted Lavish review boards"
# owns the contract; bin/fm-brief.sh instructs workers to arm before writing any
# status line about the board. This scan is what notices when one did not,
# because an instruction is not enforcement.
#
# WHAT IT DOES NOT DO. It never arms, polls, opens, resumes, or ends a board.
# The hosting task owns its listener, so the only correct response is to steer
# that worker to arm its board. This scan detects and reports; firstmate
# decides.
#
# THE GATES, all of which must hold before one wake is published.
#   1. A board URL (http://<host>:<port>/session/<id>) appears in any line of
#      this home's state/<id>.status log. Which mention it is does not matter:
#      whether the board still needs attending is decided by gates 2 and 3, not
#      by where the log has moved on to.
#   2. The task is live: its recorded endpoint still exists, read through
#      bin/fm-backend.sh's cheap read-only fm_backend_target_exists. A torn-down
#      or dead task has no worker to steer, and a live listener writing into a
#      dead worker's inbox is the existing recovery path's business, not this
#      one's.
#   3. The Lavish server still lists that URL with status `open`, resolved to
#      its artifact file by bin/fm-procevent-lavish.sh's read-only `sessions`
#      command, which owns every lavish-axi invocation here.
#   4. This home holds NO registered process-event source for that artifact, and
#      that has been observably true for longer than the grace period below.
#      Registration is read from `bin/fm-procevent.sh list`, the published
#      surface, and any registration at all counts as armed - a task-owned board
#      in any of its states, and a firstmate-owned source alike.
#
# GRACE AND DEDUPLICATION. Opening a board and arming it are two commands, so a
# worker is briefly unarmed in the ordinary case and that is not a defect. The
# grace period is measured from the first cycle that OBSERVED the board unarmed,
# recorded in state/.lavish-board-unarmed-<hash>, and the same record carries
# the once-per-episode notified flag, so a board that stays unarmed produces
# exactly one wake rather than one per watcher poll. The record is removed the
# moment the board is armed, closes, or its task goes away, so a later lapse
# rings again. FM_LAVISH_BOARD_GRACE_SECS overrides the default (300); it must
# be a whole number from 60 to 3600, and any other value is refused with exit 2
# rather than clamped, so a typo cannot silently shorten or stretch the grace.
#
# OUTPUT AND EXIT. One `actionable: <payload>` line per newly reported board on
# stdout, nothing on a quiet scan. Exit 0 when the scan completed, 1 when it
# could not (the caller reports that and changes nothing). A home whose status
# logs mention no board URL never invokes lavish-axi and never reads the source
# list at all, so a fleet with no boards pays one directory read per call. The
# CALLER owns how often to call: bin/fm-watch.sh runs this on its own interval
# rather than every poll cycle, and the grace period is wall-clock from the
# first observation, so a slower cadence cannot delay the report.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

RECORD_PREFIX=".lavish-board-unarmed-"
LAVISH_BIN="${FM_LAVISH_ADAPTER_BIN:-$SCRIPT_DIR/fm-procevent-lavish.sh}"
PROCEVENT_BIN="${FM_LAVISH_PROCEVENT_BIN:-$SCRIPT_DIR/fm-procevent.sh}"
# Bounds on the two external reads. Neither is expected to block; the bound is
# there so a wedged server or runner cannot stall a watcher cycle.
SESSIONS_TIMEOUT=${FM_LAVISH_SESSIONS_TIMEOUT:-15}
SOURCES_TIMEOUT=${FM_LAVISH_SOURCES_TIMEOUT:-15}

GRACE_SECS=${FM_LAVISH_BOARD_GRACE_SECS:-300}
case "$GRACE_SECS" in
  ''|*[!0-9]*)
    printf 'fm-lavish-board-guard: FM_LAVISH_BOARD_GRACE_SECS must be a whole number from 60 to 3600\n' >&2
    exit 2
    ;;
esac
if [ "$GRACE_SECS" -lt 60 ] || [ "$GRACE_SECS" -gt 3600 ]; then
  printf 'fm-lavish-board-guard: FM_LAVISH_BOARD_GRACE_SECS must be a whole number from 60 to 3600\n' >&2
  exit 2
fi

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

valid_id() {  # <task-id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .|..) return 1 ;;
  esac
  return 0
}

board_hash() {  # <task-id> <artifact-file>
  local payload
  payload=$(printf '%s\t%s' "$1" "$2")
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$payload" | shasum -a 256 | awk '{print substr($1,1,32)}'
  else
    printf '%s' "$payload" | sha256sum | awk '{print substr($1,1,32)}'
  fi
}

record_value() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# Board URLs named anywhere in a task's status log. Gate 1 above owns the
# rule; this is its only implementation.
status_board_urls() {  # <status-file>
  local status=$1
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  grep -Eo 'https?://[A-Za-z0-9.:_-]+/session/[A-Za-z0-9_-]+' "$status" || true
}

# Gate 2: the recorded endpoint still exists. An unreadable or absent endpoint
# reads as not live, which is the conservative answer here.
task_endpoint_live() {  # <meta-file>
  local meta=$1 backend target window
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  fm_backend_target_exists "$backend" "${target:-$window}" "fm-$(basename "$meta" .meta)"
}

queue_key_exists() {  # <key>
  fm_wake_queued_keys check 2>/dev/null | grep -Fx -- "$1" >/dev/null 2>&1
}

# One durable check wake, published through the ordinary queue so it survives a
# watcher restart and is drained like every other wake.
publish_board_wake() {  # <task> <url> <file> <unarmed-secs> <hash>
  local task=$1 url=$2 file=$3 age=$4 hash=$5 key payload
  key="lavish-board-unarmed:$task:$hash"
  payload="lavish board unarmed: task=$task url=$url file=$file unarmed_for=${age}s"
  if ! queue_key_exists "$key"; then
    fm_wake_append check "$key" "$payload" || return 1
  fi
  printf 'actionable: %s\n' "$payload"
}

write_record() {  # <record> <task> <url> <file> <first-epoch> <notified>
  local record=$1 tmp
  tmp=$(mktemp "$STATE/.lavish-board-unarmed.XXXXXX") || return 1
  {
    printf 'schema=fm-lavish-board-unarmed.v1\n'
    printf 'task=%s\n' "$2"
    printf 'url=%s\n' "$3"
    printf 'file=%s\n' "$4"
    printf 'first_unarmed=%s\n' "$5"
    printf 'notified=%s\n' "$6"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$record" || { rm -f -- "$tmp"; return 1; }
}

# Records for boards this scan no longer considers unarmed. Only this script's
# own namespace is ever touched.
prune_records() {  # <keep-list>
  local keep=$1 record hash
  for record in "$STATE/$RECORD_PREFIX"*; do
    [ -f "$record" ] || continue
    hash=$(basename "$record")
    hash=${hash#"$RECORD_PREFIX"}
    case "$keep" in *"|$hash|"*) continue ;; esac
    rm -f -- "$record"
  done
}

scan() {
  [ -d "$STATE" ] || return 0
  local meta id status url urls candidates="" seen_pair=""
  # Gate 1, over every direct task record in this home.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    status="$STATE/$id.status"
    urls=$(status_board_urls "$status") || continue
    [ -n "$urls" ] || continue
    # Gate 2, paid once, and only for a task that actually named a board.
    task_endpoint_live "$meta" || continue
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      case "$seen_pair" in *"|$id $url|"*) continue ;; esac
      seen_pair="$seen_pair|$id $url|"
      candidates="$candidates$id $url"$'\n'
    done <<EOF
$urls
EOF
  done

  if [ -z "$candidates" ]; then
    prune_records ""
    return 0
  fi

  # Gate 3: one session listing for the whole scan.
  local listing
  listing=$(fm_run_timed "$SESSIONS_TIMEOUT" env FM_HOME="$FM_HOME" \
    "$LAVISH_BIN" sessions 2>/dev/null) || {
    printf 'fm-lavish-board-guard: the Lavish session listing could not be read\n' >&2
    return 1
  }

  # Gate 4's evidence: one source listing for the whole scan. A registration in
  # any state means the runner owns this board's listener.
  local sources
  sources=$(fm_run_timed "$SOURCES_TIMEOUT" env FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" "$PROCEVENT_BIN" list 2>/dev/null) || {
    printf 'fm-lavish-board-guard: the process-event source list could not be read\n' >&2
    return 1
  }

  local pair task file lstatus lurl lfile source_id hash record now first age rc=0 keep=""
  now=$(date +%s)
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    task=${pair%% *}
    url=${pair#* }
    file=""
    while IFS=$(printf '\t') read -r lstatus lurl lfile; do
      [ "$lurl" = "$url" ] || continue
      [ "$lstatus" = open ] || continue
      file=$lfile
      break
    done <<EOF
$listing
EOF
    [ -n "$file" ] || continue
    # The canonical source identity is the adapter's, never derived here. A
    # board whose artifact has since been removed cannot be identified, and an
    # unidentifiable board is never reported.
    source_id=$(fm_run_timed "$SOURCES_TIMEOUT" "$LAVISH_BIN" source-id "$file" 2>/dev/null) || continue
    [ -n "$source_id" ] || continue
    if printf '%s\n' "$sources" | awk -v id="$source_id" '$1 == id { found = 1 } END { exit found ? 0 : 1 }'; then
      continue
    fi
    hash=$(board_hash "$task" "$file") || continue
    record="$STATE/$RECORD_PREFIX$hash"
    keep="$keep|$hash|"
    if [ -f "$record" ] && [ ! -L "$record" ]; then
      first=$(record_value "$record" first_unarmed)
    else
      first=""
    fi
    case "$first" in
      ''|*[!0-9]*)
        first=$now
        write_record "$record" "$task" "$url" "$file" "$first" 0 || rc=1
        ;;
    esac
    [ "$now" -ge "$first" ] || first=$now
    age=$((now - first))
    [ "$age" -ge "$GRACE_SECS" ] || continue
    [ "$(record_value "$record" notified)" != 1 ] || continue
    publish_board_wake "$task" "$url" "$file" "$age" "$hash" || { rc=1; continue; }
    write_record "$record" "$task" "$url" "$file" "$first" 1 || rc=1
  done <<EOF
$candidates
EOF
  prune_records "$keep"
  return "$rc"
}

case "${1-}" in
  scan) shift; [ "$#" -eq 0 ] || usage; scan ;;
  ''|-h|--help|help) usage ;;
  *) printf 'fm-lavish-board-guard: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
