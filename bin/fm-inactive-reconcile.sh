#!/usr/bin/env bash
# fm-inactive-reconcile.sh - bounded reconciliation of suspicious inactive terminal outcomes.
#
# Usage:
#   fm-inactive-reconcile.sh scan [--startup]
#   fm-inactive-reconcile.sh report <task-id>
#   fm-inactive-reconcile.sh acknowledge <fingerprint>
#
# This is an adjunct to the existing watcher poll loop and session-start path,
# not a watcher, daemon, or PR poll of its own.
# In a secondmate home every `scan` invocation, which is every watcher poll,
# first runs the LEDGER-FIRST parent delivery: a direct child whose status
# ledger ends in a whole `done:` or `failed:` line has stated its own outcome,
# so that line is eligible for publication on the parent channel through
# bin/fm-parent-channel-lib.sh from this unstamped payload:
#   <state> [key=child-outcome-<child>-<state>-<fp8>]: child <child> <state>: <note> [pr=<url>] [mode=<mode>] [yolo=<posture>] [report=data/<child>/report.md]
# carrying the child's recorded PR, delivery mode, merge posture, and scout
# report pointer, without consulting fm-crew-state.sh. A ship `done:` is
# published only when bin/fm-dod-lib.sh accepts its readiness proof, so an
# unpushed copy is not reported upstream as ready. The cadence path uses
# fm-crew-state.sh, which applies the same gate: a no-mistakes
# pre-validation `done: {summary}` still reads done (the pipeline handoff),
# while a CI-ready or direct-PR/local-only done whose head lives only in the
# disposable copy reads blocked and is not a terminal inactive outcome.
# A line still being appended (no trailing newline yet)
# is left for the next poll. This is what keeps a mate's PR-ready, finding,
# and failure outcomes from depending on the mate model appending them
# (docs/secondmate-parent-channel.md). A main home has no parent channel and
# skips this path: its watcher already signals every child status line.
# `report <task-id>` runs that same delivery for one child on behalf of a
# caller that already holds the child's meta lock, which bin/fm-teardown.sh
# does before it removes the child's record; it exits 0 when the line is
# delivered or nothing is owed, and non-zero when the parent channel could not
# be written, so teardown refuses instead of discarding an undelivered outcome.
# Ledger delivery keeps its own durable cursor, independent of the cadence
# marker, so a scan interrupted by several stalled readiness reads resumes
# after its last visited child on the next poll.
# The cadence-gated scan below then evaluates at most once per
# FM_INACTIVE_RECONCILE_SECS (default 900, valid 60..1800) per home, except
# that --startup performs the same scan immediately in the locked session
# start's deferred worker. Ledger delivery and the cadence scan share one
# FM_INACTIVE_RECONCILE_BUDGET_SECS deadline (default 10, valid 1..30).
# When the cadence scan is due, ledger delivery stops one second
# before that deadline to leave room for the cadence scan's first visit.
# Each pass resumes after its own last visited child on its next invocation.
# The scan enforces that budget itself through a millisecond deadline, and the
# first due child of every scan gets at least one full second for its reads.
# Later visits retain the shared scan deadline. A process-group
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
# A terminal outcome is a CAPTAIN-FACING claim, so two rules bound what may be
# built from that read, owned by terminal_outcome_corroborated and
# terminal_outcome_pr below. A state the reader sourced from the STATUS LOG is
# manufactured only when the crew's own last self-declared word (done, failed,
# or the configured paused verb) does not contradict it; a state sourced from
# the pipeline's own RUN STEP outranks that word outright, so the routine ship
# shape (`done:` written, the run then fails, the crew goes silent) still
# reaches the captain. Its PR identity comes from the same record as its state -
# the run's own published PR for a run-step state, that line's own ready-signal
# PR for a status-log state, and never a separately recorded task PR; a scout
# delivers no PR on either path, so it carries none. Together they
# prevent one captain-facing record from combining claims from different runs.
# A live agent withholds that verdict only while it is busy, or while its
# incarnation postdates the terminal evidence (the spawn epoch in spawn_gen is
# later than the last status line's [at=] epoch). An idle agent on the same
# incarnation is a finished worker and keeps its record. The endpoint must read
# `alive` through fm_backend_agent_state (bin/fm-backend.sh) and then `busy`
# through fm_busy_classify_meta (bin/fm-busy-lib.sh); an unreadable or unknown
# answer is never read as proof the agent is gone or idle and leaves the
# verdict unchanged. Both reads share the scan budget left after the state
# read, and hitting that
# bound ends the visit like a state-read timeout.
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
# inactive-path fingerprint binds only the spawn incarnation, task id, terminal
# state, and PR text, never the child's last status line, so a child that keeps
# appending routine prose after one terminal outcome yields at most one parent
# event across scans and restarts; the last line is retained in status_head as
# evidence. The ledger-path fingerprint instead binds the incarnation, task id,
# terminal state, literal `ledger` origin, and complete terminal ledger line.
# When a terminal ledger append races just after the inactive path's final read,
# ledger_claim binds that one ledger fingerprint to the already-delivered
# inactive receipt so the two publishers cannot report one completion twice.
# Pending atomically becomes reported after parent append or presented after
# main-home acknowledgement. The atomic epoch/cursor marker's mtime gates scans,
# and its cursor records the last child visited within the aggregate budget.
#
# A terminal verdict is withheld while the endpoint carries a live agent that is
# busy, or whose spawn_gen epoch is later than the last status line's [at=]
# epoch (a newer incarnation; an unknown epoch counts as not newer).
#
# The cadence path reads durable local state, fm-crew-state.sh, and one endpoint
# liveness and busy read per terminal candidate, bounded by the scan budget left
# after the crew-state read. Both paths can make live forge reads through
# bin/fm-dod-lib.sh's shared ship readiness gate.
# Neither path runs fm-pr-check.sh, a forge poll, or a state *.check.sh.
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
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
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

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
  file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
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

scan_marker_cursor() { # [<marker>]
  local marker=${1:-$SCAN_MARKER}
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  grep '^cursor=' "$marker" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

write_scan_marker() { # <cursor> [<marker>]
  local cursor=$1 marker=${2:-$SCAN_MARKER} marker_tmp
  marker_tmp=$(mktemp "$STATE/.inactive-outcome-reconcile.XXXXXX") || return 1
  {
    printf 'epoch=%s\n' "$(reconcile_now)"
    printf 'cursor=%s\n' "$cursor"
  } > "$marker_tmp" || { rm -f "$marker_tmp"; return 1; }
  chmod 600 "$marker_tmp" 2>/dev/null || true
  mv -f "$marker_tmp" "$marker" || { rm -f "$marker_tmp"; return 1; }
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

# Parse the canonical state line described by this script's header.
STATE_LINE_SEP=' · '

state_line_source() { # <state-line>
  local rest=${1#*"$STATE_LINE_SEP"source: }
  [ "$rest" != "$1" ] || return 0
  case "$rest" in *"$STATE_LINE_SEP"*) rest=${rest%%"$STATE_LINE_SEP"*} ;; esac
  printf '%s' "$rest"
}

# Read the optional pull request published in the canonical state line.
state_line_pr() { # <state-line>
  local rest=${1##*"$STATE_LINE_SEP"pr=}
  [ "$rest" != "$1" ] || return 0
  printf '%s' "$rest"
}

# Read the status-log note the reader published as the line's first detail.
state_line_note() { # <state-line>
  local rest=${1#*"$STATE_LINE_SEP"source: }
  [ "$rest" != "$1" ] || return 0
  case "$rest" in *"$STATE_LINE_SEP"*) ;; *) return 0 ;; esac
  rest=${rest#*"$STATE_LINE_SEP"}
  case "$rest" in *"$STATE_LINE_SEP"*) rest=${rest%%"$STATE_LINE_SEP"*} ;; esac
  printf '%s' "$rest"
}

# Enforce the header's same-record pull-request contract. A scout never delivers
# a PR, so it never carries one, exactly as pr_for_task rules for the
# ledger-first path. Otherwise a status-log state carries a PR only in a mode's
# ready-signal shape (`PR <url>`, `PR <url> checks green`, or Gerrit's
# `PR <url> published for review`) naming a review URL bin/fm-pr-lib.sh parses,
# so a PR a worker merely mentioned in prose is never the delivery.
terminal_outcome_pr() { # <state-line> <kind>
  local line=$1 kind=${2:-} value
  [ "$kind" != scout ] || return 0
  if [ "$(state_line_source "$line")" = run-step ]; then
    clean_field "$(state_line_pr "$line")"
    return 0
  fi
  value=$(state_line_note "$line")
  case "$value" in 'PR '*) value=${value#PR } ;; *) return 0 ;; esac
  case "$value" in
    *' checks green') value=${value% checks green} ;;
    *' published for review') value=${value% published for review} ;;
  esac
  fm_pr_url_parse "$value" || return 0
  clean_field "$FM_PR_URL"
}

# Enforce the header's independent captain-facing corroboration contract. A
# RUN-STEP state is the pipeline's own record of the run that just ended, and
# rule 2b in bin/fm-crew-state.sh guarantees any terminal reading published this
# way - done as well as failed - is either the attributed current run or an
# honest unknown, so a crew's own earlier prose is the weaker witness and never
# vetoes it - otherwise the routine ship shape
# (`done:` written, the run then fails, the crew goes silent) would reach nobody.
# The run-step emitter proves destination before publishing success.
# The two sources are genuinely comparable only when the state itself came from
# the status log, and there the crew's latest word still decides.
terminal_outcome_corroborated() { # <state> <last-status-line> <state-line>
  local state=$1 last=$2 line=${3:-} declared
  if [ "$(state_line_source "$line")" = run-step ]; then
    return 0
  fi
  if status_is_paused "$last"; then
    declared=paused
  else
    case "$(status_line_verb "$last")" in
      done) declared='done' ;;
      failed) declared=failed ;;
      *) return 0 ;;
    esac
  fi
  [ "$declared" = "$state" ]
}

# The task's delivered PR. Recorded meta pr= is the only authoritative source;
# the fallback scrape accepts only a preferred terminal line in a mode's
# ready-signal shape (`done: PR <url>` or `done: PR <url> checks green`,
# optionally carrying an emission-time tag this scrape steps over without
# reading), so a PR a worker merely mentioned in prose is never claimed as the
# delivery.
# A scout never delivers a PR, so it never carries one.
pr_for_task() { # <meta> [preferred-line]
  local meta=$1 preferred=${2:-} value
  [ "$(meta_field "$meta" kind)" != scout ] || return 0
  value=$(meta_field "$meta" pr)
  if [ -z "$value" ] && [ -n "$preferred" ]; then
    value=$(printf '%s\n' "$preferred" \
      | sed -nE 's|^done( \[at=[^]]*\])?: PR (https?://[^[:space:])"]+/pull/[0-9]+)( checks green)?$|\2|p' \
      | head -1 || true)
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

# The whole terminal event a child's ledger states, or non-zero when the ledger
# is absent, unusable, or states no done or failed event (1), or when that event
# is the line still being appended (2, no trailing newline yet). The event is
# selected through the shared latest-event reader, so the ledger path owns a
# terminal record whose continuation prose trails it, and an unfinished line of
# ordinary prose withholds nothing.
child_terminal_ledger_line() { # <status>
  local status=$1 snapshot last marker='__FM_LEDGER_SNAPSHOT_END__'
  [ -f "$status" ] && [ ! -L "$status" ] && [ -s "$status" ] || return 1
  last=$(last_status_line "$status")
  case "$(status_line_verb "$last")" in done|failed) ;; *) return 1 ;; esac
  snapshot=$(cat "$status"; printf '%s' "$marker") || return 1
  case "$snapshot" in
    *$'\n'"$marker") ;;
    "$last$marker"|*$'\n'"$last$marker") return 2 ;;
  esac
  printf '%s\n' "$last"
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
  local id=$1 meta=$2 status last previous state note pr mode yolo data incarnation fingerprint predecessor_head outcome_key line notice_token
  status="$STATE/$id.status"
  last=$(child_terminal_ledger_line "$status") || return 0
  state=$(status_line_verb "$last")
  pr=$(pr_for_task "$meta" "$last")
  incarnation=$(meta_incarnation "$meta")
  fingerprint=$(sha256_text "$incarnation|$id|$state|ledger|$last")
  if [ "$state" = "done" ] && [ ! -f "$(record_path "$fingerprint" reported)" ] \
    && [ ! -f "$(record_path "$fingerprint" pending)" ] \
    && ! fm_dod_accept_ship_done "$(meta_field "$meta" kind)" "$(meta_field "$meta" mode)" \
      "$(meta_field "$meta" worktree)" "$(meta_field "$meta" project)" "$last" \
      "$STATE" "$id" "$meta" meta-locked >/dev/null; then
    if [ "$(meta_field "$meta" mode)" != local-only ] \
      && [ "$(meta_field "$meta" forge)" != external ] \
      && ! fm_pr_expected_base "$meta" >/dev/null 2>&1; then
      note=$("$SCRIPT_DIR/fm-pr-poll.sh" --base-unavailable "$meta") || return 1
      if [ -n "$note" ]; then
        # Parent delivery can succeed before the local receipt is written.
        # Bind retries to this ledger event so the parent deduplicates them.
        notice_token=$fingerprint
        outcome_key="child-pr-base-$id-$notice_token"
        fm_parent_channel_report "$FM_HOME" "$STATE" "blocked [key=$outcome_key]: $note" || return 1
        (umask 077; set -C; printf '%s\n' "$notice_token" \
          > "${meta%.meta}.pr-base-parent-notified") || return 1
      fi
    fi
    return 0
  fi
  outcome_key="child-outcome-$id-$state-${fingerprint:0:8}"
  ensure_record "$fingerprint" "$id" "$incarnation" "$state" "$outcome_key" direct upstream "$pr" || return 1
  [ -n "$RECORD_PENDING" ] || return 0
  last_status_line "$status" previous >/dev/null
  predecessor_head=$(sha256_text "$previous")
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

# Every direct child's ledger, under its meta lock. A ship done: with no delivery
# record also needs local head reachability and bounded live destination proof.
# Persist the visit before that read: even the scan's aggregate backstop must
# not make every poll start again at the same stalled children.
ledger_pass() {
  local deadline=$1 meta id lock cursor range remaining marker="$STATE/.terminal-outcome-ledger-scan"
  local FM_READ_DEADLINE=$deadline
  cursor=$(scan_marker_cursor "$marker")
  valid_id "$cursor" || cursor=''
  for range in after through; do
    [ "$range" != through ] || [ -n "$cursor" ] || break
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      valid_id "$id" || continue
      case "$range" in
        after) [ -z "$cursor" ] || [[ "$id" > "$cursor" ]] || continue ;;
        through) [[ "$id" > "$cursor" ]] && continue ;;
      esac
      [ "$(fm_nm_now_ms)" -lt "$deadline" ] || return 0
      [ "$(meta_field "$meta" kind)" != secondmate ] || continue
      lock=$(fm_meta_lock_path "$meta") || continue
      fm_lock_try_acquire "$lock" || continue
      if [ ! -f "$meta" ] || [ -L "$meta" ] \
        || [ "$(meta_field "$meta" kind)" = secondmate ]; then
        fm_lock_release "$lock"
        continue
      fi
      remaining=$((deadline - $(fm_nm_now_ms)))
      if [ "$remaining" -le 0 ]; then
        fm_lock_release "$lock"
        return 0
      fi
      if ! write_scan_marker "$id" "$marker"; then
        fm_lock_release "$lock"
        return 1
      fi
      report_child_ledger_locked "$id" "$meta" || true
      fm_lock_release "$lock"
    done
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

task_holds_live_work() { # <id> <meta> <timeout> <last-status-line>; 0 when the verdict must be withheld, 3 on timeout
  local id=$1 meta=$2 timeout=$3 last=$4 backend target verdict rc=0 spawn_epoch status_epoch
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  # shellcheck disable=SC2016
  verdict=$(fm_run_timed "$timeout" bash -c '
    . "$1"; . "$2"
    [ "$(fm_backend_agent_state "$3" "$4" 2>/dev/null)" = alive ] || exit 0
    printf "alive "
    fm_busy_classify_meta "$5" "$6" "$7" 2>/dev/null' \
    _ "$SCRIPT_DIR/fm-backend.sh" "$SCRIPT_DIR/fm-busy-lib.sh" "$backend" "$target" "$meta" "$id" "$STATE") || rc=$?
  [ "$rc" -ne 124 ] || return 3
  case "$verdict" in
    'alive busy'*) return 0 ;;
    alive*)
      spawn_epoch=$(meta_field "$meta" spawn_gen)
      spawn_epoch=${spawn_epoch#s}
      spawn_epoch=${spawn_epoch%%.*}
      status_epoch=$(status_line_at_epoch "$last") || return 1
      case "$spawn_epoch$status_epoch" in ''|*[!0-9]*) return 1 ;; esac
      [ "$spawn_epoch" -gt "$status_epoch" ]
      ;;
    *) return 1 ;;
  esac
}

reconcile_direct_child_locked() { # <id> <meta> <secondmate-id-or-empty> <deadline> <first>
  local id=$1 meta=$2 self=${3:-} deadline=$4 first=$5 status turn last age state_line state pr incarnation fingerprint outcome_key payload kind state_rc=0 started left
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_field "$meta" kind)
  [ "$kind" = secondmate ] && return 0
  status="$STATE/$id.status"
  turn="$STATE/$id.turn-ended"
  last=$(last_status_line "$status")
  status_line_verb "$last" | grep -Fx captain-held >/dev/null 2>&1 && return 0
  # A ledger that states its own outcome is the ledger-first path's to deliver.
  if [ -n "$self" ]; then
    child_terminal_ledger_line "$status" >/dev/null
    case "$?" in 0|2) return 0 ;; esac
  fi
  age=$(last_activity_age "$meta" "$status" "$turn")
  [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ] || return 0
  started=$(fm_nm_now_ms) || return 3
  if [ "$first" -eq 1 ] && [ "$deadline" -lt "$((started + 1000))" ]; then
    deadline=$((started + 1000))
  fi
  local FM_READ_DEADLINE=$deadline
  # The visit budget includes the scan's guaranteed first-visit floor.
  # Endpoint readers need an outer watchdog as well as the shared deadline.
  left=$(fm_nm_read_timeout 30) || return 3
  state_line=$(fm_run_timed "$left" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
    FM_READ_DEADLINE="$deadline" \
    "$CREW_STATE_BIN" "$id" 2>/dev/null) || state_rc=$?
  [ "$state_rc" -ne 124 ] || return 3
  fm_nm_read_timeout 1 >/dev/null || return 3
  last=$(last_status_line "$status")
  if [ -n "$self" ]; then
    child_terminal_ledger_line "$status" >/dev/null
    case "$?" in 0|2) return 0 ;; esac
  fi
  case "$state_line" in
    'state: done '*) state='done' ;;
    'state: failed '*) state='failed' ;;
    *) return 0 ;;
  esac
  left=$(fm_nm_read_timeout 30) || return 3
  task_holds_live_work "$id" "$meta" "$left" "$last" && return 0
  [ "$?" -ne 3 ] || return 3
  fm_nm_read_timeout 1 >/dev/null || return 3
  terminal_outcome_corroborated "$state" "$last" "$state_line" || return 0
  pr=$(terminal_outcome_pr "$state_line" "$kind")
  incarnation=$(meta_incarnation "$meta")
  # The receipt identity binds structured fields only: a persistent child that
  # keeps appending routine prose after one terminal outcome must not mint a
  # fresh parent event per sentence. The last line stays in the record as
  # status_head evidence.
  fingerprint=$(sha256_text "$incarnation|$id|$state|$pr")
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

reconcile_direct_child() { # <id> <meta> <secondmate-id-or-empty> <deadline> <first>
  local id=$1 meta=$2 self=${3:-} deadline=$4 first=$5 lock rc=0
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  reconcile_direct_child_locked "$id" "$meta" "$self" "$deadline" "$first" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

scan_pass() { # <cursor> <after|through> <deadline> <secondmate-id-or-empty>
  local cursor=$1 range=$2 deadline=$3 self=${4:-} meta id rc first
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
      [ "$(fm_nm_now_ms)" -lt "$deadline" ] || return 3
    fi
    write_scan_marker "$id" || return 1
    reconcile_direct_child "$id" "$meta" "$self" "$deadline" "$first" || {
      rc=$?
      [ "$rc" -eq 3 ] && return 3
      return "$rc"
    }
  done
}

scan() {
  local startup=${1:-0} self='' cursor deadline ledger_deadline due=1 rc=0 marker_rc=0
  local FM_READ_DEADLINE
  mkdir -p "$STATE" "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  deadline=$(( $(fm_nm_now_ms) + FM_INACTIVE_RECONCILE_BUDGET_SECS * 1000 ))
  export FM_READ_DEADLINE=$deadline
  ledger_deadline=$deadline
  if [ "$startup" != 1 ] && [ "$(scan_marker_age)" -lt "$FM_INACTIVE_RECONCILE_SECS" ]; then
    due=0
  else
    ledger_deadline=$((deadline - 1000))
  fi
  if self=$(home_secondmate_id); then
    # The ledger-first delivery is per poll, not per cadence.
    ledger_pass "$ledger_deadline"
  else
    marker_rc=$?
    self=''
  fi
  if [ "$due" -eq 0 ]; then
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
    # The scan's own millisecond deadline enforces the budget; this outer
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
