#!/usr/bin/env bash
# fm-inactive-reconcile.sh - bounded reconciliation of suspicious inactive terminal outcomes.
#
# Usage:
#   fm-inactive-reconcile.sh scan [--startup]
#   fm-inactive-reconcile.sh report <task-id>
#   fm-inactive-reconcile.sh acknowledge <fingerprint>
#
# This is an adjunct to the existing watcher poll loop and session-start path,
# not a watcher, daemon, PR poll, or forge client of its own.
# In a secondmate home every `scan` invocation, which is every watcher poll,
# first runs the LEDGER-FIRST parent delivery: a direct child whose status
# ledger ends in a whole `done:` or `failed:` line has stated its own outcome,
# so that line is published on the parent channel at once through
# bin/fm-parent-channel-lib.sh as
#   <state> [key=child-outcome-<child>-<state>-<fp8>]: child <child> <state>: <note> [pr=<url>] [mode=<mode>] [yolo=<posture>] [report=data/<child>/report.md]
# carrying the child's recorded PR, delivery mode, merge posture, and scout
# report pointer, without consulting fm-crew-state.sh and without waiting for
# the inactive cadence. A line still being appended (no trailing newline yet)
# is left for the next poll. This is what keeps a mate's PR-ready, finding,
# and failure outcomes from depending on the mate model appending them
# (docs/secondmate-parent-channel.md). A main home has no parent channel and
# skips this path: its watcher already signals every child status line.
# `report <task-id>` runs that same delivery for one child on behalf of a
# caller that already holds the child's meta lock, which bin/fm-teardown.sh
# does before it removes the child's record; it exits 0 when the line is
# delivered or nothing is owed, and non-zero when the parent channel could not
# be written, so teardown refuses instead of discarding an undelivered outcome.
# The cadence-gated scan below then evaluates at most once per
# FM_INACTIVE_RECONCILE_SECS (default 900, valid 60..1800) per home, except
# that --startup performs the same scan immediately in the locked session
# start's deferred worker. Each scan uses an aggregate
# FM_INACTIVE_RECONCILE_BUDGET_SECS deadline (default 10, valid 1..30) and
# resumes after its last visited child on the next scan.
# The scan enforces that budget itself through a whole-second deadline, and the
# first due child of every scan is always visited with at least a one-second
# state-read bound: whole-second arithmetic can otherwise round a small budget
# to zero mid-scan, and an invocation that exits having visited nothing would
# advance the durable cursor past a child it never examined. A process-group
# kill one second after the budget remains as a backstop for a scan wedged in
# an unbounded wait (for example a live-held wake-queue lock), so the clean
# deadline path is not racing its own backstop.
#
# It considers only a direct ordinary crewmate whose newest meta, status, or
# turn-ended mtime is older than that interval and whose last status is not
# captain-held. In a secondmate home a child whose ledger already ends in a
# terminal done or failed line belongs to the ledger-first path above and is
# skipped here, so one outcome is never reported twice. It then uses
# fm-crew-state.sh as the sole current-state source.
# Only a done or failed state is suspicious enough to create a durable terminal
# outcome record or wake the supervisor.
# Working, paused, parked, blocked, unknown, persistent secondmates, and
# captain-held work retain their existing supervision semantics.
#
# A terminal-outcomes/<fingerprint>.pending record remains until its upstream
# receipt is durable.
# In a secondmate home, that receipt is an idempotent parent-channel append
# through bin/fm-parent-channel-lib.sh; the ledger-first path and the inactive
# path share the same receipt store.
# In a main home, a presentation-stage record is acknowledged by fm-wake-drain
# only after its corresponding inactive-outcome wake is handled.
# A receipt is intentionally independent of .hb-surfaced-* bookkeeping.
#
# New fm-terminal-outcome.v1 receipts contain schema, fingerprint, task_id,
# incarnation, state, outcome_key, origin, phase, pr, created_epoch, and
# notice_emitted, plus optional status_head and ledger_claim fields. The
# inactive-path fingerprint binds the spawn incarnation, task id, terminal
# state, PR text, and sanitized last status; the ledger-path fingerprint instead
# binds the incarnation, task id, terminal state, literal `ledger` origin, and
# complete terminal ledger line.
# When a terminal ledger append races just after the inactive path's final read,
# ledger_claim binds that one ledger fingerprint to the already-delivered
# inactive receipt so the two publishers cannot report one completion twice.
# Pending atomically becomes reported after parent append or presented after
# main-home acknowledgement. The atomic epoch/cursor marker's mtime gates scans,
# and its cursor records the last child visited within the aggregate budget.
#
# The scan reads only durable local state and fm-crew-state.sh; it never invokes
# gh, gh-axi, curl, fm-pr-check.sh, fm-pr-poll.sh, or a state *.check.sh.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OUTCOME_DIR="$STATE/terminal-outcomes"
SCAN_MARKER="$STATE/.inactive-outcome-reconcile"
SCAN_LOCK="$STATE/.inactive-outcome-reconcile.lock"
CREW_STATE_BIN="${FM_INACTIVE_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_INACTIVE_RECONCILE_SECS=${FM_INACTIVE_RECONCILE_SECS:-900}
case "$FM_INACTIVE_RECONCILE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_SECS must be a whole number from 60 to 1800\n' >&2
    exit 2
    ;;
esac
if [ "$FM_INACTIVE_RECONCILE_SECS" -lt 60 ] || [ "$FM_INACTIVE_RECONCILE_SECS" -gt 1800 ]; then
  printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_SECS must be a whole number from 60 to 1800\n' >&2
  exit 2
fi
FM_INACTIVE_RECONCILE_BUDGET_SECS=${FM_INACTIVE_RECONCILE_BUDGET_SECS:-10}
case "$FM_INACTIVE_RECONCILE_BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$FM_INACTIVE_RECONCILE_BUDGET_SECS" -gt 30 ]; then
  printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

if [ "$(uname)" = Darwin ]; then
  file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

reconcile_now() {
  case "${FM_INACTIVE_RECONCILE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_INACTIVE_RECONCILE_NOW" ;;
  esac
}

clean_field() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 32)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 32)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x%08x", $1, $2}'
  fi
}

record_path() { printf '%s/%s.%s\n' "$OUTCOME_DIR" "$1" "$2"; }

record_value() {
  local record=$1 key=$2
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  grep "^${key}=" "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

record_phase_set() {
  local record=$1 phase=$2 tmp line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.record.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in phase=*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < "$record"
  printf 'phase=%s\n' "$phase" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record"
}

record_field_set() {
  local record=$1 key=$2 value=$3 tmp line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.record.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < "$record"
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record"
}

ensure_record() { # <fingerprint> <task> <incarnation> <state> <outcome-key> <origin> <phase> <pr> [status-head]
  local fingerprint=$1 task=$2 incarnation=$3 state=$4 outcome_key=$5 origin=$6 phase=$7 pr=$8 status_head=${9:-} tmp
  RECORD_PENDING=$(record_path "$fingerprint" pending)
  RECORD_PRESENTED=$(record_path "$fingerprint" presented)
  RECORD_REPORTED=$(record_path "$fingerprint" reported)
  if [ -f "$RECORD_PRESENTED" ] || [ -f "$RECORD_REPORTED" ]; then
    RECORD_PENDING=
    return 0
  fi
  if [ -f "$RECORD_PENDING" ] && [ ! -L "$RECORD_PENDING" ]; then
    return 0
  fi
  mkdir -p "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.pending.XXXXXX") || return 1
  {
    printf 'schema=fm-terminal-outcome.v1\n'
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'task_id=%s\n' "$task"
    printf 'incarnation=%s\n' "$incarnation"
    printf 'state=%s\n' "$state"
    printf 'outcome_key=%s\n' "$outcome_key"
    printf 'origin=%s\n' "$origin"
    printf 'phase=%s\n' "$phase"
    printf 'pr=%s\n' "$pr"
    printf 'created_epoch=%s\n' "$(reconcile_now)"
    printf 'notice_emitted=0\n'
    [ -z "$status_head" ] || printf 'status_head=%s\n' "$status_head"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$RECORD_PENDING" || { rm -f "$tmp"; return 1; }
}

mark_reported() { # <record>
  local record=$1 reported
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  reported=${record%.pending}.reported
  mv -f "$record" "$reported"
}

queue_key_exists() { # <key>
  local key=$1 queued
  queued=$(fm_wake_queued_keys check 2>/dev/null || true)
  printf '%s\n' "$queued" | grep -Fx -- "$key" >/dev/null 2>&1
}

publish_actionable() { # <key> <payload>
  local key=$1 payload=$2
  queue_key_exists "$key" && return 1
  fm_wake_append check "$key" "$payload" || return 2
  printf 'actionable: %s\n' "$payload"
}

queue_notice_once() { # <record> <key> <payload>
  local record=$1 key=$2 payload=$3 notified rc=0
  notified=$(record_value "$record" notice_emitted)
  [ "$notified" = 1 ] && return 1
  publish_actionable "$key" "$payload" || rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    record_field_set "$record" notice_emitted 1 || return 2
  fi
  return "$rc"
}

queue_presentation() { # <record> <fingerprint> <payload>
  local record=$1 fingerprint=$2 payload=$3
  publish_actionable "inactive-outcome:$fingerprint" "$payload"
}

last_activity_age() { # <meta> <status> <turn-ended>
  local meta=$1 status=$2 turn=$3 now m newest=0 file
  now=$(reconcile_now)
  for file in "$meta" "$status" "$turn"; do
    [ -e "$file" ] || continue
    m=$(file_mtime "$file" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -le "$newest" ] || newest=$m
  done
  [ "$newest" -gt 0 ] || { printf '0\n'; return; }
  if [ "$now" -lt "$newest" ]; then printf '0\n'; else printf '%s\n' $((now - newest)); fi
}

scan_marker_age() {
  local now m
  [ -e "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || { printf '999999\n'; return; }
  now=$(reconcile_now)
  m=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) printf '999999\n'; return ;; esac
  if [ "$now" -lt "$m" ]; then printf '0\n'; else printf '%s\n' $((now - m)); fi
}

scan_marker_cursor() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  grep '^cursor=' "$SCAN_MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

write_scan_marker() { # <cursor>
  local cursor=$1 marker_tmp
  marker_tmp=$(mktemp "$STATE/.inactive-outcome-reconcile.XXXXXX") || return 1
  {
    printf 'epoch=%s\n' "$(reconcile_now)"
    printf 'cursor=%s\n' "$cursor"
  } > "$marker_tmp" || { rm -f "$marker_tmp"; return 1; }
  chmod 600 "$marker_tmp" 2>/dev/null || true
  mv -f "$marker_tmp" "$SCAN_MARKER" || { rm -f "$marker_tmp"; return 1; }
}

meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

meta_incarnation() { # <meta>
  local meta=$1 incarnation identity
  incarnation=$(meta_field "$meta" spawn_gen)
  if valid_id "$incarnation"; then
    printf '%s\n' "$incarnation"
    return
  fi
  identity=$(meta_field "$meta" tasktmp)
  if [ -z "$identity" ]; then
    identity="$(meta_field "$meta" window)|$(meta_field "$meta" worktree)"
  fi
  printf 'legacy-%s\n' "$(sha256_text "$identity")"
}

pr_for_task() { # <meta> <status> [preferred-line]
  local meta=$1 status=$2 preferred=${3:-} value
  value=$(meta_field "$meta" pr)
  if [ -z "$value" ] && [ -n "$preferred" ]; then
    value=$(printf '%s\n' "$preferred" \
      | grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' | head -1 || true)
  fi
  if [ -z "$value" ] && [ -f "$status" ]; then
    value=$(grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$status" 2>/dev/null | tail -1 || true)
  fi
  clean_field "$value"
}

home_secondmate_id() {
  fm_parent_channel_home_id "$FM_HOME"
}

report_to_parent() { # <task> <state> <outcome-key> <fingerprint> <pr>
  local task=$1 state=$2 outcome_key=$3 fingerprint=$4 pr=$5 line
  line="$state [key=$outcome_key]: inactive terminal child=$task fingerprint=$fingerprint"
  [ -z "$pr" ] || line="$line pr=$pr"
  fm_parent_channel_report "$FM_HOME" "$STATE" "$line"
}

# Queue the once-per-record notice that a parent report could not be written.
# A home seeded without its parent binding cannot report upward at all, and
# every later terminal outcome fails the same way for the same reason, so the
# binding is named when it is the cause.
notice_parent_report_failed() { # <record> <fingerprint> <payload>
  local record=$1 fingerprint=$2 payload=$3
  if ! fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent"; then
    payload="$payload (missing or unreadable parent binding .fm-secondmate-parent)"
  fi
  queue_notice_once "$record" "inactive-reconcile:$fingerprint" "$payload" || true
}

# The whole terminal line a child's ledger ends in, or non-zero when the ledger
# is absent, unusable, still being appended (no trailing newline yet), or does
# not end in a done or failed line optionally followed by a run of declared
# pauses. A worker that finishes correctly into a known external wait (merge
# authority, a halted build service, an upstream branch landing) appends
# `paused: <why>` right after its `done:`/`failed:` line per bin/fm-brief.sh's
# status protocol, and that terminal result must still reach a secondmate's
# parent channel rather than being read as merely paused. More than one
# trailing pause is routine, not exotic: a worker rechecking the same wait
# appends another `paused:` line, and so does firstmate steering that worker
# (fm-classify-lib.sh documents both), so a single-line lookback would
# silently drop an already-landed PR from parent-channel delivery. Scans
# backward across any run of consecutive trailing declared-pause lines,
# bounded by FM_TERMINAL_PAUSE_SCAN_MAX (default 20 lines) so a pathological
# ledger cannot make this expensive; exhausting the budget without finding a
# done/failed line is "no terminal report", never a guess.
# Prints the terminal line, then a second line holding whatever non-blank line
# immediately precedes it (empty when there is none): a caller run through
# command substitution cannot receive a side-channel global (it executes in a
# subshell), so both facts travel out as the one stdout stream, split on the
# first newline. A caller reading only the terminal line may pipe to
# `head -1`, or check truthiness alone as one caller here already does.
child_terminal_ledger_line() { # <status>
  local status=$1 snapshot lines n budget i idx line predecessor marker='__FM_LEDGER_SNAPSHOT_END__'
  [ -f "$status" ] && [ ! -L "$status" ] && [ -s "$status" ] || return 1
  snapshot=$(cat "$status"; printf '%s' "$marker") || return 1
  case "$snapshot" in *$'\n'"$marker") ;; *) return 1 ;; esac
  snapshot=${snapshot%"$marker"}
  lines=$(printf '%s' "$snapshot" | grep -v '^[[:space:]]*$') || true
  n=$(printf '%s\n' "$lines" | grep -c .)
  [ "$n" -ge 1 ] || return 1
  budget=${FM_TERMINAL_PAUSE_SCAN_MAX:-20}
  [ "$n" -lt "$budget" ] && budget=$n
  i=1
  while [ "$i" -le "$budget" ]; do
    idx=$(( n - i + 1 ))
    line=$(printf '%s\n' "$lines" | sed -n "${idx}p")
    case "$(status_line_verb "$line")" in
      done|failed)
        predecessor=''
        [ "$idx" -ge 2 ] && predecessor=$(printf '%s\n' "$lines" | sed -n "$((idx - 1))p")
        printf '%s\n%s\n' "$line" "$predecessor"
        return 0
        ;;
    esac
    status_is_paused "$line" || return 1
    i=$((i + 1))
  done
  return 1
}

# Claim one already-delivered inactive fallback as the delivery of this ledger
# event. Both reconciliation paths hold the child's meta lock, so this receipt
# update serializes their decision even though the child appends its ledger
# without that lock. The claim stores the exact ledger fingerprint: a retry of
# this event stays suppressed, while a later terminal line remains a new event.
claim_inactive_report_for_ledger() { # <task> <incarnation> <state> <ledger-fingerprint> <predecessor-head>
  local task=$1 incarnation=$2 state=$3 ledger_fingerprint=$4 predecessor_head=$5 record key claim
  for record in "$OUTCOME_DIR"/*.reported; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    [ "$(record_value "$record" task_id)" = "$task" ] || continue
    [ "$(record_value "$record" incarnation)" = "$incarnation" ] || continue
    [ "$(record_value "$record" state)" = "$state" ] || continue
    key=$(record_value "$record" outcome_key)
    case "$key" in inactive-outcome-*) ;; *) continue ;; esac
    [ "$(record_value "$record" status_head)" = "$predecessor_head" ] || continue
    claim=$(record_value "$record" ledger_claim)
    if [ "$claim" = "$ledger_fingerprint" ]; then
      return 0
    fi
    [ -z "$claim" ] || continue
    record_field_set "$record" ledger_claim "$ledger_fingerprint" || return 2
    return 0
  done
  return 1
}

# The ledger-first parent delivery for one direct child, for a caller holding
# the child's meta lock. Returns 0 when the line is delivered, already
# delivered, or nothing is owed, and 1 when it is owed but the parent channel
# could not be written (the notice is queued once per record).
report_child_ledger_locked() { # <id> <meta>
  local id=$1 meta=$2 status ledger_output last previous state note pr mode yolo data incarnation fingerprint predecessor_head outcome_key line
  status="$STATE/$id.status"
  ledger_output=$(child_terminal_ledger_line "$status") || return 0
  last=${ledger_output%%$'\n'*}
  previous=${ledger_output#*$'\n'}
  [ "$previous" != "$ledger_output" ] || previous=''
  state=$(status_line_verb "$last")
  pr=$(pr_for_task "$meta" "$status" "$last")
  incarnation=$(meta_incarnation "$meta")
  fingerprint=$(sha256_text "$incarnation|$id|$state|ledger|$last")
  predecessor_head=$(sha256_text "$previous")
  outcome_key="child-outcome-$id-$state-${fingerprint:0:8}"
  ensure_record "$fingerprint" "$id" "$incarnation" "$state" "$outcome_key" direct upstream "$pr" || return 1
  [ -n "$RECORD_PENDING" ] || return 0
  if claim_inactive_report_for_ledger "$id" "$incarnation" "$state" "$fingerprint" "$predecessor_head"; then
    # The fallback line is already on the parent channel. This reported ledger
    # receipt records that its richer rendering owes no second publication.
    mark_reported "$RECORD_PENDING" || return 1
    return 0
  elif [ "$?" -eq 2 ]; then
    return 1
  fi
  note=$(clean_field "$(status_line_note "$last")")
  mode=$(clean_field "$(meta_field "$meta" mode)")
  yolo=$(clean_field "$(meta_field "$meta" yolo)")
  data="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  line="$state [key=$outcome_key]: child $id $state: $note"
  [ -z "$pr" ] || line="$line pr=$pr"
  [ -z "$mode" ] || line="$line mode=$mode"
  [ -z "$yolo" ] || line="$line yolo=$yolo"
  if [ -f "$data/$id/report.md" ] && [ ! -L "$data/$id/report.md" ]; then
    line="$line report=data/$id/report.md"
  fi
  if fm_parent_channel_report "$FM_HOME" "$STATE" "$line"; then
    mark_reported "$RECORD_PENDING" || return 1
    return 0
  fi
  notice_parent_report_failed "$RECORD_PENDING" "$fingerprint" \
    "child outcome needs parent report: child=$id state=$state"
  return 1
}

# Every direct child's ledger, under its meta lock. Cheap file reads only, so
# it runs on every poll in a secondmate home; a delivery failure is already
# queued as a notice and never fails the scan.
ledger_pass() {
  local meta id lock
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    [ "$(meta_field "$meta" kind)" != secondmate ] || continue
    lock=$(fm_meta_lock_path "$meta") || continue
    fm_lock_try_acquire "$lock" || continue
    if [ ! -f "$meta" ] || [ -L "$meta" ] \
      || [ "$(meta_field "$meta" kind)" = secondmate ]; then
      fm_lock_release "$lock"
      continue
    fi
    report_child_ledger_locked "$id" "$meta" || true
    fm_lock_release "$lock"
  done
}

# The `report <task-id>` entry point: the caller holds the child's meta lock.
report_child() { # <id>
  local id=$1 meta rc=0
  mkdir -p "$STATE" "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  home_secondmate_id >/dev/null || { rc=$?; [ "$rc" -eq 1 ] && return 0; return 1; }
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ "$(meta_field "$meta" kind)" != secondmate ] || return 0
  report_child_ledger_locked "$id" "$meta"
}

reconcile_direct_child_locked() { # <id> <meta> <secondmate-id-or-empty> <timeout>
  local id=$1 meta=$2 self=${3:-} timeout=$4 status turn last age state_line state pr incarnation fingerprint outcome_key payload kind state_rc=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_field "$meta" kind)
  [ "$kind" = secondmate ] && return 0
  status="$STATE/$id.status"
  turn="$STATE/$id.turn-ended"
  last=$(last_status_line "$status")
  status_line_verb "$last" | grep -Fx captain-held >/dev/null 2>&1 && return 0
  # A ledger that states its own outcome is the ledger-first path's to deliver.
  if [ -n "$self" ] && child_terminal_ledger_line "$status" >/dev/null; then
    return 0
  fi
  age=$(last_activity_age "$meta" "$status" "$turn")
  [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ] || return 0
  state_line=$(fm_run_timed "$timeout" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$CREW_STATE_BIN" "$id" 2>/dev/null) || state_rc=$?
  [ "$state_rc" -ne 124 ] || return 3
  last=$(last_status_line "$status")
  if [ -n "$self" ]; then
    case "$(status_line_verb "$last")" in done|failed) return 0 ;; esac
  fi
  case "$state_line" in
    'state: done '*) state='done' ;;
    'state: failed '*) state='failed' ;;
    *) return 0 ;;
  esac
  pr=$(pr_for_task "$meta" "$status")
  incarnation=$(meta_incarnation "$meta")
  fingerprint=$(sha256_text "$incarnation|$id|$state|$pr|$(clean_field "$last")")
  if [ -n "$self" ]; then
    outcome_key="inactive-outcome-$self-$id-$state"
  else
    outcome_key="inactive-outcome-main-$id-$state"
  fi
  ensure_record "$fingerprint" "$id" "$incarnation" "$state" "$outcome_key" direct "upstream" "$pr" "$(sha256_text "$last")" || return 1
  [ -n "$RECORD_PENDING" ] || return 0
  if [ -n "$self" ]; then
    if report_to_parent "$id" "$state" "$outcome_key" "$fingerprint" "$pr"; then
      mark_reported "$RECORD_PENDING" || return 1
    else
      notice_parent_report_failed "$RECORD_PENDING" "$fingerprint" \
        "inactive terminal outcome needs parent report: child=$id state=$state"
    fi
    return 0
  fi
  record_phase_set "$RECORD_PENDING" presentation || return 1
  payload="inactive terminal outcome awaiting captain presentation: child=$id state=$state"
  [ -z "$pr" ] || payload="$payload pr=$pr"
  queue_presentation "$RECORD_PENDING" "$fingerprint" "$payload" || true
}

reconcile_direct_child() { # <id> <meta> <secondmate-id-or-empty> <timeout>
  local id=$1 meta=$2 self=${3:-} timeout=$4 lock rc=0
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  reconcile_direct_child_locked "$id" "$meta" "$self" "$timeout" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# SCAN_FIRST_VISIT_PENDING is armed by scan() before its passes. The deadline
# below is whole-second arithmetic, so a small budget can quantize to zero
# between the deadline computation and these checks; without the guaranteed
# first visit, such a scan would return 3 having examined no child at all while
# write_scan_marker had already advanced the cursor past the skipped child.
scan_pass() { # <cursor> <after|through> <deadline> <secondmate-id-or-empty>
  local cursor=$1 range=$2 deadline=$3 self=${4:-} meta id remaining rc first
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    case "$range" in
      after) [ -z "$cursor" ] || [[ "$id" > "$cursor" ]] || continue ;;
      through) [ -n "$cursor" ] && [[ "$id" > "$cursor" ]] && continue ;;
    esac
    first=0
    if [ "${SCAN_FIRST_VISIT_PENDING:-0}" -eq 1 ]; then
      first=1
      SCAN_FIRST_VISIT_PENDING=0
    fi
    if [ "$first" -eq 0 ]; then
      [ "$(date +%s)" -lt "$deadline" ] || return 3
    fi
    write_scan_marker "$id" || return 1
    remaining=$((deadline - $(date +%s)))
    if [ "$first" -eq 1 ] && [ "$remaining" -lt 1 ]; then
      remaining=1
    fi
    [ "$remaining" -gt 0 ] || return 3
    reconcile_direct_child "$id" "$meta" "$self" "$remaining" || {
      rc=$?
      [ "$rc" -eq 3 ] && return 3
      return "$rc"
    }
  done
}

scan() {
  local startup=${1:-0} self='' cursor deadline rc=0 marker_rc=0
  mkdir -p "$STATE" "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  if self=$(home_secondmate_id); then
    # The ledger-first delivery is per poll, not per cadence.
    ledger_pass
  else
    marker_rc=$?
    self=''
  fi
  if [ "$startup" != 1 ] && [ "$(scan_marker_age)" -lt "$FM_INACTIVE_RECONCILE_SECS" ]; then
    return 0
  fi
  cursor=$(scan_marker_cursor)
  valid_id "$cursor" || cursor=''
  write_scan_marker "$cursor" || return 1
  if [ -z "$self" ] && [ "$marker_rc" -ne 1 ]; then
    publish_actionable "inactive-reconcile-diagnostic:invalid-secondmate-home" \
      "inactive terminal outcomes remain unreconciled: invalid .fm-secondmate-home marker" || true
    return 0
  fi
  deadline=$(( $(date +%s) + FM_INACTIVE_RECONCILE_BUDGET_SECS ))
  SCAN_FIRST_VISIT_PENDING=1
  scan_pass "$cursor" after "$deadline" "$self" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$cursor" ]; then
    scan_pass "$cursor" through "$deadline" "$self" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    write_scan_marker '' || return 1
  elif [ "$rc" -ne 3 ]; then
    return "$rc"
  fi
}

acknowledge() { # <fingerprint>
  local fingerprint=$1 pending presented phase
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 1
  pending=$(record_path "$fingerprint" pending)
  presented=$(record_path "$fingerprint" presented)
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 0
  phase=$(record_value "$pending" phase)
  [ "$phase" = presentation ] || return 0
  mv -f "$pending" "$presented"
}

acknowledge_notice() { # <fingerprint>
  local fingerprint=$1 pending
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 1
  pending=$(record_path "$fingerprint" pending)
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 0
  record_field_set "$pending" notice_emitted 1
}

mode=${1:-scan}
case "$mode" in
  scan)
    startup=0
    case "${2:-}" in
      '') ;;
      --startup) startup=1 ;;
      *) printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2; exit 2 ;;
    esac
    # The scan's own whole-second deadline enforces the budget; this outer
    # process-group kill is only the backstop for a scan wedged outside every
    # bounded section (an unbounded lock wait), so it fires one second after
    # the deadline instead of racing the clean bounded exit it exists to guard.
    if fm_run_timed $((FM_INACTIVE_RECONCILE_BUDGET_SECS + 1)) "$0" _scan-locked "$startup"; then
      :
    elif [ "$?" -ne 124 ]; then
      exit 1
    fi
    ;;
  _scan-locked)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    scan "$2"
    ;;
  report)
    if [ "$#" -ne 2 ] || ! valid_id "$2"; then
      printf 'usage: fm-inactive-reconcile.sh report <task-id>\n' >&2
      exit 2
    fi
    report_child "$2"
    ;;
  acknowledge)
    [ "$#" -eq 2 ] || { printf 'usage: fm-inactive-reconcile.sh acknowledge <fingerprint>\n' >&2; exit 2; }
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    acknowledge "$2"
    ;;
  acknowledge-notice)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    acknowledge_notice "$2"
    ;;
  -h|--help)
    sed -n '2,40{s/^# \{0,1\}//;p;}' "$0"
    ;;
  *)
    printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2
    printf '       fm-inactive-reconcile.sh acknowledge <fingerprint>\n' >&2
    exit 2
    ;;
esac
