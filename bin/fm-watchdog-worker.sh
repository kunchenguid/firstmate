#!/usr/bin/env bash
# fm-watchdog-worker.sh - the fleet's independent watchdog: one bounded pass
# that relaunches dead workers, recovers stalled ones, restarts failed units,
# and rebuilds the fleet after a reboot, with no firstmate turn and no model in
# the loop.
#
# Usage:
#   fm-watchdog-worker.sh             one watchdog pass (silent unless it acted)
#   fm-watchdog-worker.sh --dry-run   one read-only pass: print every lane's
#                                     state and what this pass WOULD do, act
#                                     nothing, record nothing, wake nothing
#   fm-watchdog-worker.sh status      print the durable record summary, act nothing
#   fm-watchdog-worker.sh --help      print this help
#
# WHY THIS EXISTS. Everything in the fleet that notices a broken worker today
# ends in a firstmate turn: the watcher raises a `stale:` wake, firstmate loads
# stuck-crewmate-recovery, reads the pane, and relaunches by hand. That is why
# the 2026-11-03 measurements hold (data/factory-autonomy-fable-a1/report.md
# sections 1d and 2): rows that already had an owner still stalled 50-70 min on
# a pool-swap connection reset and were only nudged by hand, the 17:36Z power
# loss was recovered entirely by hand because fm-fleet-revive waited on a chair
# that itself needed a hand relaunch, and fleet systemd units sat `failed`
# unnoticed. The watchdog is the DeepSeek Super-agent design's watchdog rung
# made mechanical (data/factory-autonomy-fable-a1/bob-architecture.md sections 5
# and 8, step 7): a timer-driven actor OUTSIDE the firstmate session that keeps
# the fleet alive while firstmate is asleep, busy, or itself dead. It needs no
# cheap model session to do that, because every judgement below is
# deterministic.
#
# ONE PASS, IN ORDER.
#   1. Boot pass, only on the first pass after a reboot: relaunch every
#      ordinary task whose recorded endpoint is gone, then start the chair unit
#      LAST, then queue one check wake saying what happened. Nothing here waits
#      on the chair, which is the boot-order fix: the old
#      fm-fleet-revive.service declared `After=fm-chair.service` and slept 90
#      seconds for a chair that could fail to exist, so a reboot needed a hand.
#   2. Failed-unit pass: restart fleet-owned `fm-*` systemd --user services that
#      report `failed`, capped per unit per hour.
#   3. Task pass: relaunch every task whose endpoint is dead or missing, and
#      walk a bounded recovery ladder over every live task that has stopped
#      moving.
# Each phase prints one line per action and nothing else, so a quiet pass is
# silent and the journal is the record of what it did.
#
# LIVENESS. Liveness uses the single recovery-grade classifier,
# bin/fm-backend.sh's fm_backend_agent_state, so only `dead` and `missing`
# license a relaunch. An `ambiguous`, `unreadable`, or `unverified` endpoint is
# left alone: a duplicate agent in one worktree is worse than a worker waiting
# another minute. The relaunch itself is `bin/fm-control.sh <id> relaunch
# --note <text>` - the transaction the captain would run by hand - so the
# endpoint, worktree, harness, model, and uncommitted work are preserved and the
# note is the replacement agent's only carry-over context.
#
# THE STALL LADDER. A live worker whose pane keeps one SHAPE for
# no_progress_secs while it reads busy is stalled. Shape means printable ASCII
# with digits folded and non-ASCII dropped, so a ticking timer, a spinner glyph,
# a token counter, or a redrawn gutter is not progress while a new line of
# output is. A stalled worker climbs a ladder that costs progressively more,
# one rung per pass:
#   1. re-ring   - one durable steer through fm-send carrying the bounded
#                  continue, marked fire-and-forget so the steering inbox does
#                  not escalate the watchdog's own message back to firstmate;
#   2. relaunch  - the same terminal transaction as the liveness rung, with a
#                  stall note naming how long the pane had been frozen;
#   3. reassign  - a second relaunch whose note tells the fresh agent to treat
#                  the task as a new assignment and re-read the brief, which is
#                  what a relaunch already is for every verified harness: the
#                  brief on disk, not a harness-private session, is the durable
#                  instruction;
#   4. escalate  - one check wake for the task, then the watchdog stops
#                  touching it.
# A rung is a request, not a verdict: the ladder never climbs until the rung
# that set the stage is rung_grace_secs old, so a worker that answers a re-ring
# has real time to act before anything costs it a relaunch. The ladder resets
# whenever the worker writes a new status-log line after the last rung, or when
# the rung that set the stage is over an hour old, so an agent that comes back
# to life is never walked up a stale ladder.
#
# THE IDLE RUNG. A live worker that is idle and quiet is not necessarily
# stalled - it may be waiting on its own pipeline or on a merge - so idleness
# is a separate, gentler action: with its status log quiet for idle_secs,
# bin/fm-crew-state.sh reading `working` from a source the worker itself owns
# (never a pipeline run-step), no gateway-stall ladder already re-ringing it,
# and no ladder rung already spent, it gets one bounded continue steer per
# hour. `done`, `failed`, `parked`, `paused`, `blocked`, and unknown all keep
# it out of this rung entirely.
#
# THE STEERING-INBOX LADDER. A durable steer the worker never acknowledged is
# a message the fleet already paid to write, so it is walked up its own ladder
# by ABSOLUTE age of the oldest unhandled record - re-ring at 20 minutes,
# interrupt and continue at 45, relaunch at 90 - one rung per message, never
# repeated. The age ladder is the watchdog's own and does not replace the
# watcher's per-attempt re-ring ladder, which keeps working on its own cadence
# because a duplicated doorbell is free. A lane whose endpoint is not alive is
# left to the relaunch rung above, which is what actually restores it.
#
# THE CONNECTION LADDER. A live lane whose pane is showing a connection error
# or a connection reset and has produced nothing new for
# fm_watchdog_connection_secs is not stalled on its own work: the transport
# died under it and nothing will restart it. It gets one bounded continue per
# pass, and after fm_watchdog_connection_strikes of them the lane is relaunched
# onto the fallback worker model - a worker lane only, because an Opus or Fable
# seat doing review or planning keeps the model the captain chose for it. A
# gateway-owned transient failure is left to the gateway ladder that already
# owns it, and the permanent failures (a spent usage limit, an expired login, a
# prompt too long) are never retried at all.
#
# BACKLOG RECONCILE. An in-flight backlog item with no task record is a lane
# nobody can steer: fm-send cannot resolve it, no pass above sees it, and it
# silently never finishes. Every pass compares the two records and reports the
# difference once per change, naming the ids, so firstmate adopts or closes
# each one instead of never hearing about it. A live endpoint whose task record
# is missing is reported the same way. The watchdog never invents a task
# record: a wrong endpoint binding is worse than a lane that is visibly
# unowned.
#
# CAPS. Relaunches, unit restarts, rings, and idle steers are each counted per
# object per rolling hour and capped (3, 3, 2, and 1 by default), so a crash
# loop or a genuinely broken object cannot burn the fleet; spending a relaunch,
# restart, or idle-steer cap escalates to firstmate as one check wake per hour
# instead of retrying forever.
#
# THE CHAIR. Only the boot pass and the failed-unit pass touch the chair, and
# both go through the chair's own systemd unit, which refuses a second chair by
# construction. Mid-session chair supervision is deliberately out: a chair
# restart discards a live conversation, so that decision stays with firstmate
# and the deadman alarm. Secondmates are out for the same reason of ownership -
# their own homes and the locked session start's liveness sweep reconcile them -
# and a reboot still needs zero hand relaunches, because the boot pass starts
# the chair, whose session start then reconciles its second mates.
#
# DRIFT. The architecture's remaining rung, a model judgement over each
# worker's recent status lines ("is this still the task?"), is deliberately not
# here: this repo has no one-shot model client to reuse, and a wrong steer to a
# working agent is more expensive than a missing one. The idle rung above is
# the model-free half of that intent - a worker that has stopped moving without
# saying why is nudged, never killed.
#
# UNITS. The allow list is a glob list of systemd --user services the watchdog
# may restart (default `fm-*`), minus a deny list (default this watchdog's own
# two units) so it can never restart itself in a loop. A host without
# `systemctl --user` - macOS, a container - skips the pass silently.
#
# RECORD. state/.watchdog-worker.json is schema-stamped JSON holding the boot
# identity, each task's last pane shape with when it last changed, its ladder
# stage and stage age, its capped action history, and each unit's restart
# history, with the epoch of the one escalation that spent a unit's budget. It
# is written atomically at the end of a pass; a record carrying
# another schema stamp is treated as no record at all. `status` prints it
# without acting.
#
# CONFIGURATION. config/watchdog.env is gitignored and per-home; it holds
# KEY=value lines and is parsed, never sourced. A set environment variable of
# the same name wins. Keys (defaults in parentheses):
#   FM_WATCHDOG_RELAUNCH_PER_HOUR (3)      FM_WATCHDOG_UNIT_RESTARTS_PER_HOUR (3)
#   FM_WATCHDOG_RINGS_PER_HOUR (2)         FM_WATCHDOG_IDLE_STEERS_PER_HOUR (1)
#   FM_WATCHDOG_NO_PROGRESS_SECS (1800)    FM_WATCHDOG_IDLE_SECS (1800)
#   FM_WATCHDOG_RUNG_GRACE_SECS (600)
#   FM_WATCHDOG_UNITS (on)                 FM_WATCHDOG_UNIT_ALLOW (fm-*)
#   FM_WATCHDOG_UNIT_DENY (fm-watchdog-worker.service fm-watchdog-worker.timer)
#   FM_WATCHDOG_CHAIR_UNIT (fm-chair.service)
#   FM_WATCHDOG_CHAIR_SESSION (chair)       FM_WATCHDOG_CHAIR_TARGET (auto)
#   FM_WATCHDOG_CAPTURE_LINES (24)         FM_WATCHDOG_READ_TIMEOUT_SECS (10)
#   FM_WATCHDOG_RELAUNCH_TIMEOUT_SECS (240)
#   FM_WATCHDOG_BOOT_BUDGET_SECS (1500)
#   FM_WATCHDOG_INBOX_RING_SECS (1200)     FM_WATCHDOG_INBOX_INTERRUPT_SECS (2700)
#   FM_WATCHDOG_INBOX_RELAUNCH_SECS (5400)
#   FM_WATCHDOG_CONNECTION_SECS (600)      FM_WATCHDOG_CONNECTION_STRIKES (3)
#   FM_WATCHDOG_FALLBACK_MODEL (deepseek-v4.1-flash)
#   FM_WATCHDOG_FALLBACK_KINDS (ship scout)
#   FM_WATCHDOG_BACKLOG (on)               FM_WATCHDOG_BACKLOG_BIN (tasks-axi)
# The systemd user timer that drives this script, and the one-time removal of
# the old fm-fleet-revive.service it replaces, are documented in
# docs/configuration.md "Fleet watchdog (config/watchdog.env)".
#
# TEST SEAMS: FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_WATCHDOG_NOW (frozen
# clock), FM_WATCHDOG_BOOT_ID (a literal `off` disables the boot pass),
# FM_WATCHDOG_CONTROL_BIN, FM_WATCHDOG_SEND_BIN,
# FM_WATCHDOG_CREW_STATE_BIN, FM_WATCHDOG_SYSTEMCTL_BIN, FM_WATCHDOG_AGENT_STATE_DIR
# (<dir>/<id>.state instead of a live endpoint read), and FM_WATCHDOG_CAPTURE_DIR
# (<dir>/<id>.cap pane text and <dir>/<id>.busy verdict instead of a live
# capture).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ENV_FILE="$CONFIG_DIR/watchdog.env"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-gateway-retry-lib.sh
. "$SCRIPT_DIR/fm-gateway-retry-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

RECORD="$STATE/.watchdog-worker.json"
LOCK="$STATE/.watchdog-worker.lock"
SCHEMA=1
HOUR=3600

DRY_RUN=0
BACKLOG_JSON='{}'
INBOX_RING_SECS=1200
INBOX_INTERRUPT_SECS=2700
INBOX_RELAUNCH_SECS=5400
CONNECTION_SECS=600
CONNECTION_STRIKES=3
FALLBACK_MODEL=''
FALLBACK_KINDS=''
BACKLOG_ENABLED=on
BACKLOG_BIN=''
BACKLOG_LIST_MAX=25
CONTROL_BIN=${FM_WATCHDOG_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}
LANE_SWITCH_BIN=${FM_WATCHDOG_LANE_SWITCH_BIN:-$SCRIPT_DIR/fm-lane-model-switch.sh}
SEND_BIN=${FM_WATCHDOG_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
CREW_STATE_BIN=${FM_WATCHDOG_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
SYSTEMCTL_BIN=${FM_WATCHDOG_SYSTEMCTL_BIN:-systemctl}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

# first_line: a captured child's noise folded to one bounded line, so one
# action is always one journal line.
first_line() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | head -1 | cut -c1-300
}

now_epoch() {
  case "${FM_WATCHDOG_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_WATCHDOG_NOW" ;;
  esac
}

# path_age_now <path>: seconds since the file last changed, on the pass's own
# clock, so a frozen test clock ages files exactly as a live one does.
path_age_now() {  # <path>
  local m
  m=$(fm_path_mtime "$1" 2>/dev/null) || { printf '999999\n'; return 0; }
  case "$m" in ''|*[!0-9]*) printf '999999\n'; return 0 ;; esac
  printf '%s\n' "$(( $(now_epoch) - m ))"
}

# conf <KEY> <default>: a set environment variable, else the env file's value,
# else the default. The file is parsed line by line and never sourced.
conf() {
  local key=$1 default=$2 line value='' found=0
  eval "value=\${$key:-}"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  if [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*)
          value=${line#*=}
          case "$value" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
          esac
          found=1
          ;;
      esac
    done < "$ENV_FILE"
  fi
  if [ "$found" = 1 ] && [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

conf_int() {  # <KEY> <default>
  local v
  v=$(conf "$1" "$2")
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  printf '%s\n' "$v"
}

# csv_recent <csv> <now> <window-secs>: how many entries fall inside the window.
csv_recent() {
  local csv=$1 now=$2 window=$3 e n=0
  for e in ${csv//,/ }; do
    case "$e" in ''|*[!0-9]*) continue ;; esac
    [ $((now - e)) -lt "$window" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# csv_prune <csv> <now> <window-secs>: <csv> minus the entries outside the
# window, so a long-lived record stays bounded.
csv_prune() {
  local csv=$1 now=$2 window=$3 out='' e
  for e in ${csv//,/ }; do
    case "$e" in ''|*[!0-9]*) continue ;; esac
    [ $((now - e)) -lt "$window" ] || continue
    out="$out${out:+,}$e"
  done
  printf '%s\n' "$out"
}

# csv_to_json <csv>: the digit-only csv as a JSON array of strings.
csv_to_json() {
  local csv=$1 out='' e
  for e in ${csv//,/ }; do
    case "$e" in ''|*[!0-9]*) continue ;; esac
    out="$out${out:+,}\"$e\""
  done
  printf '[%s]' "$out"
}

csv_append() {  # <csv> <value>
  if [ -n "$1" ]; then printf '%s,%s\n' "$1" "$2"; else printf '%s\n' "$2"; fi
}

# csv_last <csv>: the newest entry, or 0.
csv_last() {
  local csv=$1 e last=0
  for e in ${csv//,/ }; do
    case "$e" in ''|*[!0-9]*) continue ;; esac
    last=$e
  done
  printf '%s\n' "$last"
}

# boot_identity: a stable string for the current boot, empty when the host
# exposes none (the boot pass is then disabled rather than guessed).
boot_identity() {
  case "${FM_WATCHDOG_BOOT_ID:-}" in
    off) return 0 ;;
    '') : ;;
    *) printf '%s\n' "$FM_WATCHDOG_BOOT_ID"; return 0 ;;
  esac
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    cat /proc/sys/kernel/random/boot_id 2>/dev/null
    return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n kern.boottime 2>/dev/null
    return 0
  fi
  return 0
}

# pane_signature <text>: the pane's SHAPE (see the header's stall rule).
pane_signature() {
  printf '%s\n' "$1" \
    | LC_ALL=C sed -e 's/[^ -~]//g' -e 's/[0-9][0-9]*/#/g' -e 's/[[:space:]]*$//' \
    | tail -n "$CAPTURE_LINES" \
    | cksum | awk '{ print $1 "-" $2 }'
}

# --- durable record ---------------------------------------------------------

record_load() {
  RECORD_BOOT=''
  RECORD_UNITS='{}'
  PRIOR_TASKS='{}'
  if [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
    [ "$(jq -r '.schema // 0' "$RECORD" 2>/dev/null)" = "$SCHEMA" ] || return 0
    RECORD_BOOT=$(jq -r '.boot_identity // ""' "$RECORD" 2>/dev/null)
    RECORD_UNITS=$(jq -c '.units // {}' "$RECORD" 2>/dev/null) || RECORD_UNITS='{}'
    PRIOR_TASKS=$(jq -c '.tasks // {}' "$RECORD" 2>/dev/null) || PRIOR_TASKS='{}'
  fi
  return 0
}

# task_entry <id>: one recorded task as a US-separated row. A unit separator
# keeps empty fields intact; a tab would not, because IFS whitespace collapses.
# Field order is the one task_load reads and the one the header documents:
#   sig since stage stage_at rings relaunches steers woke
#   istage istage_at ibase strikes
task_entry() {  # <id>
  jq -r --arg id "$1" '.[$id] // {} |
    [ (.sig // ""), (.since // 0), (.stage // 0), (.stage_at // 0),
      ((.rings // []) | join(",")), ((.relaunches // []) | join(",")),
      ((.steers // []) | join(",")),
      (if (.woke // false) then "true" else "false" end),
      (.istage // 0), (.istage_at // 0), (.ibase // ""),
      ((.strikes // []) | join(",")) ]
    | map(tostring) | join("\u001f")' "$WORK/tasks.json" 2>/dev/null
}

# task_load <id>: read one task's row into the CALLER's locals. Bash's dynamic
# scoping is what makes this legal: the caller declares the thirteen variables,
# this assigns them, and both passes that touch a lane (the inbox ladder and
# the task pass) therefore preserve every field they do not own instead of
# clobbering each other's.
task_load() {  # <id>
  IFS=$'\x1f' read -r sig since stage stage_at rings relaunches steers woke \
    istage istage_at ibase strikes <<EOF
$(task_entry "$1")
EOF
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  case "$stage" in ''|*[!0-9]*) stage=0 ;; esac
  case "$stage_at" in ''|*[!0-9]*) stage_at=0 ;; esac
  case "$istage" in ''|*[!0-9]*) istage=0 ;; esac
  case "$istage_at" in ''|*[!0-9]*) istage_at=0 ;; esac
  case "$woke" in true) ;; *) woke=false ;; esac
}

# task_store <id>: persist the caller's current loop values. One write path for
# every rung, so adding a field can never leave one branch storing the old
# shape. Reads the same thirteen locals task_load fills.
task_store() {  # <id>
  [ "$DRY_RUN" = 1 ] && return 0
  jq -n \
    --arg id "$1" --arg sig "${sig-}" --argjson since "${since:-0}" \
    --argjson stage "${stage:-0}" --argjson stage_at "${stage_at:-0}" \
    --argjson rings "$(csv_to_json "${rings-}")" \
    --argjson relaunches "$(csv_to_json "${relaunches-}")" \
    --argjson steers "$(csv_to_json "${steers-}")" \
    --argjson woke "$([ "${woke-false}" = true ] && printf true || printf false)" \
    --argjson istage "${istage:-0}" --argjson istage_at "${istage_at:-0}" \
    --arg ibase "${ibase-}" \
    --argjson strikes "$(csv_to_json "${strikes-}")" \
    '{ key: $id, value: { sig: $sig, since: $since, stage: $stage, stage_at: $stage_at,
       rings: $rings, relaunches: $relaunches, steers: $steers, woke: $woke,
       istage: $istage, istage_at: $istage_at, ibase: $ibase, strikes: $strikes } }' \
    > "$WORK/entry.$1.json" 2>/dev/null || true
}

# task_reset <id> <relaunches-csv>: the entry a relaunch leaves behind - every
# judgement wiped because the new agent is a different agent, only the relaunch
# budget kept so the hourly cap still spans the relaunch.
task_reset() {  # <id> <relaunches>
  [ "$DRY_RUN" = 1 ] && return 0
  jq -n --arg id "$1" --argjson relaunches "$(csv_to_json "$2")" \
    '{ key: $id, value: { sig: "", since: 0, stage: 0, stage_at: 0, rings: [],
       relaunches: $relaunches, steers: [], woke: false, istage: 0, istage_at: 0,
       ibase: "", strikes: [] } }' \
    > "$WORK/entry.$1.json" 2>/dev/null || true
}

record_store() {  # <boot> <units-json> <backlog-json>
  local tasks='{}' tmp
  [ "$DRY_RUN" = 1 ] && return 0
  if compgen -G "$WORK/entry.*.json" >/dev/null 2>&1; then
    tasks=$(jq -s 'map({ key: .key, value: .value }) | from_entries' "$WORK"/entry.*.json 2>/dev/null) || tasks='{}'
  fi
  tmp="$RECORD.tmp.$$"
  if jq -n --argjson schema "$SCHEMA" --arg boot "$1" \
      --argjson units "$2" --argjson tasks "$tasks" --argjson backlog "${3:-{\}}" \
      '{ schema: $schema, boot_identity: $boot, units: $units, tasks: $tasks,
         backlog: $backlog }' > "$tmp" 2>/dev/null; then
    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$RECORD" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# --- actions ----------------------------------------------------------------

# wake_firstmate <key> <payload>: one durable check wake, the watchdog's only
# way of asking for a turn.
wake_firstmate() {  # <key> <payload>
  if [ "$DRY_RUN" = 1 ]; then
    printf 'watchdog: would wake firstmate: %s %s\n' "$1" "$2"
    return 0
  fi
  fm_wake_append check "$1" "$2" 2>/dev/null || true
}

# task_agent_state <id> <meta>: the recovery-grade endpoint state, bounded.
# FM_WATCHDOG_AGENT_STATE_DIR replaces the live read with <dir>/<id>.state.
task_agent_state() {  # <id> <meta>
  local id=$1 meta=$2 backend target state
  if [ -n "$AGENT_STATE_DIR" ]; then
    if [ -f "$AGENT_STATE_DIR/$id.state" ] && [ ! -L "$AGENT_STATE_DIR/$id.state" ]; then
      state=$(head -1 "$AGENT_STATE_DIR/$id.state" 2>/dev/null)
      case "$state" in
        alive|dead|missing|ambiguous|unreadable|unverified) printf '%s' "$state" ;;
        *) printf 'unreadable' ;;
      esac
    else
      printf 'missing'
    fi
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  if [ -z "$target" ]; then
    printf 'unverified'
    return 0
  fi
  if state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null); then
    case "$state" in
      alive|dead|missing|ambiguous|unreadable|unverified) printf '%s' "$state" ;;
      *) printf 'unreadable' ;;
    esac
    return 0
  fi
  printf 'unreadable'
}

# task_relaunch <id> <reason> <note>: the one relaunch transaction.
task_relaunch() {  # <id> <reason> <note> [model]
  local id=$1 reason=$2 note=$3 model=${4-} out rc
  if [ "$DRY_RUN" = 1 ]; then
    printf 'watchdog: would relaunch %s after %s%s\n' "$id" "$reason" \
      "$([ -n "$model" ] && printf ' on %s' "$model")"
    return 0
  fi
  local -a model_args=()
  [ -z "$model" ] || model_args=(--model "$model")
  out=$(fm_run_timed "$RELAUNCH_TIMEOUT_SECS" "$CONTROL_BIN" "$id" relaunch \
    ${model_args[@]+"${model_args[@]}"} --note "$note" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^relaunched '; then
    printf 'watchdog: relaunched %s after %s\n' "$id" "$reason"
    return 0
  fi
  printf 'watchdog: relaunch failed %s after %s: %s\n' "$id" "$reason" "$(first_line "$out")"
  return 1
}

liveness_note() {  # <id> <endpoint-state>
  printf '%s' "The watchdog found your endpoint $2 while the host stayed up, and relaunched your agent. Your worktree and commits are intact. Re-orient from your status log, your steering inbox (state/$1.inbox/), and your worktree, then resume exactly where you left off. Do not repeat any send, merge, or prod write your status log shows already done."
}

stall_note() {  # <minutes>
  printf '%s' "The watchdog saw this task's pane stop producing anything new for about $1 minutes while it read as working, and relaunched your agent. Your worktree and commits are intact, including anything you had already changed. Read your status log and your brief, check from the worktree what you actually finished, and continue from there."
}

reassign_note() {
  printf '%s' "Your predecessor on this task ran without progress and was replaced. Treat this as a fresh assignment of the same task: read the task's brief and status log, verify from the worktree what is already done, then finish the task yourself. Do not repeat completed sends, merges, or prod writes."
}

# task_ring <id> <why>: one bounded continue, fire-and-forget so the steering
# ladder does not escalate the watchdog's own message back to firstmate.
task_ring() {  # <id> <why>
  local id=$1 why=$2 out rc
  out=$("$SEND_BIN" "$id" --fire-and-forget "watchdog-$id-$(now_epoch)" \
    "The watchdog sees this task's pane stopped producing anything new while it read as working ($why). Continue the task from where you left off. If you are waiting on something external, say so on one status line so the fleet stops treating this as a stall. If the task is finished, append your done: line." 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'watchdog: re-rang %s (%s)\n' "$id" "$why"
    return 0
  fi
  printf 'watchdog: re-ring failed %s: %s\n' "$id" "$(first_line "$out")"
  return 1
}

# task_steer_idle <id>: one bounded continue for a live, idle, quiet worker
# whose own current state still reads working.
task_steer_idle() {  # <id>
  local id=$1 out rc
  out=$("$SEND_BIN" "$id" --fire-and-forget "watchdog-idle-$id-$(now_epoch)" \
    "The watchdog sees this task idle with no new status event and no finished outcome. Continue from where you left off. If you are blocked or waiting on someone, say so on one status line; if the task is finished, append your done: line." 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'watchdog: nudged idle %s\n' "$id"
    return 0
  fi
  printf 'watchdog: idle nudge failed %s: %s\n' "$id" "$(first_line "$out")"
  return 1
}

# --- connection ladder ------------------------------------------------------

# task_conn_continue <id> <minutes>: one bounded continue for a lane frozen on a
# transport error. Fire-and-forget, so the steering ladder never escalates the
# watchdog's own message back to firstmate.
task_conn_continue() {  # <id> <minutes>
  local id=$1 minutes=$2 out rc
  if [ "$DRY_RUN" = 1 ]; then
    printf 'watchdog: would continue %s after a connection error (%s minutes)\n' "$id" "$minutes"
    return 0
  fi
  out=$("$SEND_BIN" "$id" --fire-and-forget "watchdog-conn-$id-$(now_epoch)" \
    "The watchdog sees a connection error on your pane and nothing new for $minutes minutes. The interrupted step was not completed; pick the task up from where it stopped and continue. Do not restart finished work." 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'watchdog: continued %s after a connection error (%s minutes)\n' "$id" "$minutes"
    return 0
  fi
  printf 'watchdog: continue after connection error failed %s: %s\n' "$id" "$(first_line "$out")"
  return 1
}

# task_conn_relaunch <id> <kind> <minutes> <strikes>: the last connection rung.
# A worker lane is replaced onto the fallback worker model, because a lane that
# died on transport three times running is not converging where it is. A review
# or planning seat keeps the model the captain chose for it: only a lane whose
# kind is in FM_WATCHDOG_FALLBACK_KINDS is moved. Reaching the fallback model
# needs the second gateway's endpoint, so a lane without one gets the repoint
# recorded first - by the script that owns that move, never by typing /model
# here - and a refused repoint still gets the plain relaunch, because restoring
# the lane matters more than the model it comes back on.
task_conn_relaunch() {  # <id> <kind> <minutes> <strikes>
  local id=$1 kind=$2 minutes=$3 strikes=$4 model='' note out rc
  note="The watchdog replaced your agent after $strikes connection errors, each with no new output for $minutes minutes. Your worktree, commits, and status log are intact. Re-orient from them and continue the task from where the transport failed; do not repeat completed steps."
  if [ -n "$FALLBACK_MODEL" ]; then
    case " $FALLBACK_KINDS " in
      *" $kind "*) model=$FALLBACK_MODEL ;;
    esac
  fi
  if [ -n "$model" ] && [ "$DRY_RUN" != 1 ] && [ ! -f "$STATE/$id.gateway.env" ]; then
    out=$(fm_run_timed "$READ_TIMEOUT_SECS" "$LANE_SWITCH_BIN" "$id" gateway 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'watchdog: could not repoint %s at the fallback gateway (%s); relaunching it on its own model\n' \
        "$id" "$(first_line "$out")"
      wake_firstmate "watchdog-model-$id" \
        "check: watchdog could not move $id to $model ($(first_line "$out")); if the transport keeps failing, move it by hand with bin/fm-lane-model-switch.sh $id gateway"
      model=''
    fi
  fi
  if task_relaunch "$id" "$strikes connection errors with no new output for $minutes minutes" "$note" "$model"; then
    wake_firstmate "watchdog-conn-$id" \
      "check: watchdog relaunched $id on ${model:-its own model} after $strikes connection errors with no progress for $minutes minutes; if it stalls again the lane needs a hand"
    return 0
  fi
  return 1
}

# --- boot pass --------------------------------------------------------------

# chair_ensure: make sure the chair's own unit runs, without ever starting a
# second chair (the unit refuses that itself). Prints one word.
chair_ensure() {
  local target='' session window state out
  [ "$UNITS_ENABLED" = on ] || { printf 'not managed'; return 0; }
  target=$CHAIR_TARGET
  if [ -z "$target" ]; then
    session=$CHAIR_SESSION
    if command -v tmux >/dev/null 2>&1; then
      window=$(tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | head -1)
      [ -n "$window" ] && target="$session:$window"
    fi
  fi
  if [ -n "$target" ] || [ -n "$AGENT_STATE_DIR" ]; then
    if [ -n "$AGENT_STATE_DIR" ]; then
      state=$(head -1 "$AGENT_STATE_DIR/chair.state" 2>/dev/null) || state='missing'
    else
      state=$(fm_backend_agent_state tmux "$target" 2>/dev/null)
    fi
    [ "$state" = alive ] && { printf 'already live'; return 0; }
  fi
  # restart, not start: the chair unit is a RemainAfterExit oneshot, so after its
  # session dies it still reads active and `start` would be a no-op. A restart
  # re-runs the unit's own guard, which is what refuses to start a second chair.
  if [ "$DRY_RUN" = 1 ]; then
    printf 'would restart'
    return 0
  fi
  if out=$(fm_run_timed "$READ_TIMEOUT_SECS" "$SYSTEMCTL_BIN" --user restart "$CHAIR_UNIT" 2>&1); then
    printf 'started'
  else
    printf 'could not be started: %s' "$(first_line "$out")"
  fi
  return 0
}

# boot_pass <boot>: relaunch every ordinary task whose endpoint is gone, start
# the chair LAST, and queue one check wake describing the result.
boot_pass() {  # <boot>
  local boot=$1 id meta kind state ok=0 tried=0 deadline chair result
  deadline=$(( $(now_epoch) + BOOT_BUDGET_SECS ))
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    [ -n "$(fm_meta_get "$meta" window)" ] || continue
    if [ "$(now_epoch)" -ge "$deadline" ]; then
      printf 'watchdog: boot pass ran out of budget before it reached every task; the task pass continues from here\n'
      break
    fi
    tried=$((tried + 1))
    state=$(task_agent_state "$id" "$meta")
    case "$state" in
      dead|missing) ;;
      *) continue ;;
    esac
    if task_relaunch "$id" "host reboot (endpoint $state)" \
      "The host rebooted and every worker process and terminal session died; your worktree and commits are intact. Re-orient from your status log, your steering inbox (state/$id.inbox/), and your worktree, then resume exactly where you left off. Anything you had under /tmp is gone; re-create it if needed. Do not repeat any send, merge, or prod write your status log shows already done."; then
      ok=$((ok + 1))
    fi
    # A fresh agent takes a moment to make its endpoint answer, so this pass
    # must not read the endpoint it just relaunched and relaunch it again.
    : > "$WORK/touched.$id"
    task_reset "$id" "$(now_epoch)"
  done
  chair=$(chair_ensure)
  result="relaunched $ok of $tried task(s), chair $chair"
  printf 'watchdog: boot recovery: %s (boot %s)\n' "$result" "${boot:0:8}"
  wake_firstmate watchdog-boot "check: watchdog boot recovery: $result"
  return 0
}

# --- failed-unit pass -------------------------------------------------------

unit_matches() {  # <pattern-list> <unit>
  local pat
  for pat in $1; do
    # shellcheck disable=SC2254 # The allow/deny lists are deliberately globs.
    case "$2" in $pat) return 0 ;; esac
  done
  return 1
}

# unit_pass: restart fleet-owned units systemd reports as failed, capped per
# unit per hour, and escalate the ones that spend the cap. Prints the new unit
# record as JSON.
unit_pass() {
  local now out unit csv count restarts woke_at
  restarts=$RECORD_UNITS
  printf '%s\n' "$restarts" > "$WORK/units.json"
  [ "$UNITS_ENABLED" = on ] || return 0
  command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 || return 0
  now=$(now_epoch)
  out=$(fm_run_timed "$READ_TIMEOUT_SECS" "$SYSTEMCTL_BIN" --user list-units \
    --state=failed --type=service --plain --no-legend --no-pager 2>/dev/null) || out=''
  [ -n "$out" ] || return 0
  while read -r unit _; do
    [ -n "$unit" ] || continue
    unit=${unit#●}
    case "$unit" in ''|*[!A-Za-z0-9@._-]*) continue ;; esac
    unit_matches "$UNIT_ALLOW" "$unit" || continue
    unit_matches "$UNIT_DENY" "$unit" && continue
    csv=$(printf '%s' "$restarts" \
      | jq -r --arg u "$unit" '.[$u].restarts // [] | join(",")' 2>/dev/null)
    woke_at=$(printf '%s' "$restarts" \
      | jq -r --arg u "$unit" '.[$u].woke_at // 0' 2>/dev/null)
    case "$woke_at" in ''|*[!0-9]*) woke_at=0 ;; esac
    csv=$(csv_prune "$csv" "$now" "$HOUR")
    count=$(csv_recent "$csv" "$now" "$HOUR")
    if [ "$count" -ge "$UNIT_RESTARTS_PER_HOUR" ]; then
      if [ $((now - woke_at)) -ge "$HOUR" ]; then
        printf 'watchdog: unit %s is failed and has spent its hourly restart budget; asking firstmate\n' "$unit"
        wake_firstmate "watchdog-unit-$unit" \
          "check: watchdog unit $unit is failed and has spent its hourly restart budget ($UNIT_RESTARTS_PER_HOUR); it needs a hand"
        woke_at=$now
      fi
      restarts=$(printf '%s' "$restarts" \
        | jq -c --arg u "$unit" --argjson c "$(csv_to_json "$csv")" --argjson w "$woke_at" \
            '.[$u] = { restarts: $c, woke_at: $w }' 2>/dev/null)
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
      printf 'watchdog: would restart failed unit %s\n' "$unit"
      continue
    fi
    csv=$(csv_append "$csv" "$now")
    fm_run_timed "$READ_TIMEOUT_SECS" "$SYSTEMCTL_BIN" --user reset-failed "$unit" >/dev/null 2>&1 || true
    if fm_run_timed "$READ_TIMEOUT_SECS" "$SYSTEMCTL_BIN" --user start "$unit" >/dev/null 2>&1; then
      printf 'watchdog: restarted failed unit %s\n' "$unit"
    else
      printf 'watchdog: could not restart failed unit %s\n' "$unit"
    fi
    restarts=$(printf '%s' "$restarts" \
      | jq -c --arg u "$unit" --argjson c "$(csv_to_json "$csv")" --argjson w "$woke_at" \
          '.[$u] = { restarts: $c, woke_at: $w }' 2>/dev/null)
  done <<EOF
$out
EOF
  printf '%s\n' "$restarts" > "$WORK/units.json"
  return 0
}

# --- task pass --------------------------------------------------------------

# crew_reads_working <id>: true when the worker's OWN current state reads
# working - not a pipeline run-step, which is the pipeline working, not the
# agent - and no gateway-stall ladder is already re-ringing it.
crew_reads_working() {  # <id>
  local id=$1 crew state source
  fm_gateway_stall_open "$STATE" "$id" 2>/dev/null && return 1
  crew=$(fm_run_timed "$READ_TIMEOUT_SECS" "$CREW_STATE_BIN" "$id" 2>/dev/null) || return 1
  state=$(printf '%s\n' "$crew" | sed -n 's/^state: \([a-z-]*\).*/\1/p' | head -1)
  source=$(printf '%s\n' "$crew" | sed -n 's/.*source: \([a-z-]*\).*/\1/p' | head -1)
  [ "$state" = working ] || return 1
  case "$source" in
    run-step|remote-endpoint) return 1 ;;
  esac
  return 0
}

# conn_error_shape <text>: 0 when the rendered pane shows a connection-level
# failure. The permanent list is consulted first and beats every match, because
# those sentences are never fixed by re-ringing, and only the last twelve
# non-blank lines are read, which is where a turn-ending transport error
# renders above the prompt.
conn_error_shape() {  # <text>
  local text=${1-} t
  [ -n "$text" ] || return 1
  fm_gateway_text_is_permanent "$text" && return 1
  t=$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n 12)
  printf '%s' "$t" | grep -qiE \
    'connection (error|reset|aborted|refused|closed)|econnreset|econnaborted|socket hang up|stream (error|disconnected)|network error|tls handshake'
}

# task_pass: the per-task sweep.
task_pass() {
  local meta id kind window now backend target harness state text busy prev_sig
  local since stage stage_at rings relaunches steers woke status_mtime changed stage_age
  local sig='' istage istage_at ibase strikes
  local ring_count relaunch_count steer_count minutes conn_err strike_count
  now=$(now_epoch)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    # The boot pass already acted on this task in this pass.
    [ -e "$WORK/touched.$id" ] && continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || target="$window"
    harness=$(fm_meta_get "$meta" harness)

    task_load "$id"
    prev_sig=$sig
    sig=''
    rings=$(csv_prune "$rings" "$now" "$HOUR")
    relaunches=$(csv_prune "$relaunches" "$now" "$HOUR")
    steers=$(csv_prune "$steers" "$now" "$HOUR")
    strikes=$(csv_prune "$strikes" "$now" "$HOUR")

    # The ladder belongs to one episode: a worker that wrote a status line after
    # the last rung, or whose stage is over an hour old, starts again at the
    # first rung.
    status_mtime=$(fm_path_mtime "$STATE/$id.status" 2>/dev/null) || status_mtime=0
    case "$status_mtime" in ''|*[!0-9]*) status_mtime=0 ;; esac
    if [ "$stage" -gt 0 ] \
      && { [ "$status_mtime" -gt "$stage_at" ] || [ $((now - stage_at)) -ge "$HOUR" ]; }; then
      stage=0
      rings=''
      woke=false
    fi

    state=$(task_agent_state "$id" "$meta")
    case "$state" in
      alive) ;;
      dead|missing)
        if [ "$DRY_RUN" = 1 ]; then
          printf '%s\t%s\tn/a\t-\t%d\t%d\twould relaunch (endpoint %s)\n' \
            "$id" "$state" "$(quiet_minutes_of "$id" "$now")" "$(inbox_minutes_of "$id")" "$state"
        fi
        relaunch_count=$(csv_recent "$relaunches" "$now" "$HOUR")
        if [ "$relaunch_count" -lt "$RELAUNCH_PER_HOUR" ]; then
          task_relaunch "$id" "endpoint $state" "$(liveness_note "$id" "$state")" || true
          relaunches=$(csv_append "$relaunches" "$now")
          task_reset "$id" "$relaunches"
          continue
        fi
        if [ "$woke" != true ]; then
          printf 'watchdog: %s endpoint %s and out of relaunches; asking firstmate\n' "$id" "$state"
          wake_firstmate "watchdog-$id" \
            "check: watchdog $id endpoint $state and its hourly relaunch budget ($RELAUNCH_PER_HOUR) is spent; it needs a hand"
          woke=true
        fi
        task_store "$id"
        continue
        ;;
      *)
        # An unclassifiable endpoint licenses nothing and proves no progress.
        task_store "$id"
        continue
        ;;
    esac

    if [ -n "$CAPTURE_DIR" ]; then
      text=$(cat "$CAPTURE_DIR/$id.cap" 2>/dev/null) || text=''
      busy=$(head -1 "$CAPTURE_DIR/$id.busy" 2>/dev/null) || busy='unknown'
      busy=${busy%% *}
    else
      # fm_run_timed wraps an EXTERNAL command, so a backend shell function is
      # called directly; each backend's own capture is already bounded.
      text=$(fm_backend_capture "$backend" "$target" "$CAPTURE_LINES" 2>/dev/null) || text=''
      busy=$(fm_busy_classify "$backend" "$target" "$harness" "$id" "$STATE" "$text" 2>/dev/null) \
        || busy='unknown'
      busy=${busy%% *}
    fi
    if [ -z "$text" ]; then
      task_store "$id"
      continue
    fi
    sig=$(pane_signature "$text")
    if [ -z "$sig" ]; then
      task_store "$id"
      continue
    fi

    # A changed pane shape, a new status line, or a first sighting all restart
    # the freeze clock; a changed shape also ends the stall episode and the
    # connection episode, because both are judgements about one frozen screen.
    if [ "$sig" != "$prev_sig" ] || [ "$since" -eq 0 ] || [ "$status_mtime" -gt "$since" ]; then
      since=$now
      if [ "$sig" != "$prev_sig" ]; then
        rings=''
        strikes=''
      fi
    fi
    changed=$((now - since))
    conn_err=0
    conn_error_shape "$text" && conn_err=1
    # A gateway-owned transient failure already has its own re-ring ladder, and
    # two ladders on one lane would fight; that owner keeps it.
    [ "$conn_err" = 1 ] && fm_gateway_stall_open "$STATE" "$id" 2>/dev/null && conn_err=0

    if [ "$DRY_RUN" = 1 ]; then
      printf '%s\t%s\t%s\t%s\t%d\t%d\t%s\n' "$id" "$state" "$busy" \
        "$([ "$conn_err" = 1 ] && printf conn-error || printf ok)" \
        "$((changed / 60))" "$(inbox_minutes_of "$id")" \
        "$(dry_plan "$id" "$busy" "$changed" "$conn_err" "$stage" "$strikes" "$(inbox_minutes_of "$id")")"
    fi

    # THE CONNECTION LADDER. A live lane frozen on a transport error is not
    # working on anything: nothing in the pane will move until something rings
    # it, so it gets one bounded continue per pass and a relaunch after the
    # configured strikes. It owns the lane while the error is on screen, so the
    # generic stall ladder does not also fire at it.
    if [ "$conn_err" = 1 ] && [ "$changed" -ge "$CONNECTION_SECS" ]; then
      strike_count=$(csv_recent "$strikes" "$now" "$HOUR")
      if [ "$strike_count" -lt "$CONNECTION_STRIKES" ]; then
        task_conn_continue "$id" "$((changed / 60))" || true
        strikes=$(csv_append "$strikes" "$now")
      else
        task_conn_relaunch "$id" "$kind" "$((changed / 60))" "$strike_count" || true
        strikes=$(csv_append "$strikes" "$now")
        relaunches=$(csv_append "$relaunches" "$now")
      fi
      task_store "$id"
      continue
    fi

    if [ "$busy" = busy ]; then
      if [ "$changed" -lt "$NO_PROGRESS_SECS" ]; then
        task_store "$id"
        continue
      fi
      # A rung is a request, not a verdict: the worker gets rung_grace_secs to
      # answer it before the ladder climbs.
      stage_age=$((now - stage_at))
      if [ "$stage" -gt 0 ] && [ "$stage_age" -lt "$RUNG_GRACE_SECS" ]; then
        task_store "$id"
        continue
      fi
      minutes=$((changed / 60))
      case "$stage" in
        0)
          ring_count=$(csv_recent "$rings" "$now" "$HOUR")
          if [ "$ring_count" -lt "$RINGS_PER_HOUR" ]; then
            task_ring "$id" "$minutes minutes with nothing new on the pane" || true
            rings=$(csv_append "$rings" "$now")
          fi
          stage=1
          stage_at=$now
          ;;
        1)
          relaunch_count=$(csv_recent "$relaunches" "$now" "$HOUR")
          if [ "$relaunch_count" -lt "$RELAUNCH_PER_HOUR" ]; then
            task_relaunch "$id" "no pane progress for $minutes minutes" "$(stall_note "$minutes")" || true
            relaunches=$(csv_append "$relaunches" "$now")
            stage=2
            stage_at=$now
          fi
          ;;
        2)
          relaunch_count=$(csv_recent "$relaunches" "$now" "$HOUR")
          if [ "$relaunch_count" -lt "$RELAUNCH_PER_HOUR" ]; then
            task_relaunch "$id" "still no progress after a stall relaunch; reassigning" "$(reassign_note)" || true
            relaunches=$(csv_append "$relaunches" "$now")
            stage=3
            stage_at=$now
          fi
          ;;
        *)
          if [ "$woke" != true ]; then
            printf 'watchdog: %s still stalled after every rung; asking firstmate\n' "$id"
            wake_firstmate "watchdog-$id" \
              "check: watchdog $id is still stalled after a re-ring and two relaunches; it needs a hand or a reassignment"
            woke=true
          fi
          ;;
      esac
      task_store "$id"
      continue
    fi

    # Idle: not stalled, but a worker that has gone quiet without saying why
    # gets one gentle nudge per hour, never a kill.
    if [ "$changed" -lt "$IDLE_SECS" ] || [ "$stage" -ne 0 ]; then
      task_store "$id"
      continue
    fi
    if ! crew_reads_working "$id"; then
      task_store "$id"
      continue
    fi
    if [ -n "$steers" ] && [ $((now - $(csv_last "$steers"))) -lt "$RUNG_GRACE_SECS" ]; then
      task_store "$id"
      continue
    fi
    minutes=$((changed / 60))
    steer_count=$(csv_recent "$steers" "$now" "$HOUR")
    if [ "$steer_count" -lt "$IDLE_STEERS_PER_HOUR" ]; then
      task_steer_idle "$id" || true
      steers=$(csv_append "$steers" "$now")
    elif [ "$woke" != true ]; then
      printf 'watchdog: %s idle for %s minutes and still not moving; asking firstmate\n' "$id" "$minutes"
      wake_firstmate "watchdog-$id" \
        "check: watchdog $id has been idle with no status event for $minutes minutes and did not move after a nudge; it needs a hand"
      woke=true
    fi
    task_store "$id"
  done
  return 0
}

# --- steering-inbox pass ----------------------------------------------------

# inbox_oldest <id>: the oldest unhandled, escalation-tracked steer record.
inbox_oldest() {  # <id>
  fm_task_inbox_oldest_unhandled "$STATE" "$1" 2>/dev/null
}

# inbox_minutes_of <id>: how long the oldest unhandled steer has waited, in
# minutes, for reporting; 0 when the inbox is clear.
inbox_minutes_of() {  # <id>
  local oldest
  oldest=$(inbox_oldest "$1") || { printf '0'; return 0; }
  printf '%s' "$(( $(path_age_now "$oldest") / 60 ))"
}

# quiet_minutes_of <id> <now>: minutes since the recorded freeze began, for the
# dry-run table only.
quiet_minutes_of() {  # <id> <now>
  local since
  since=$(jq -r --arg id "$1" '.[$id].since // 0' "$WORK/tasks.json" 2>/dev/null)
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  printf '%s' "$(( ($2 - since) / 60 ))"
}

# dry_plan <id> <busy> <changed> <conn_err> <stage> <strikes> <inbox-minutes>:
# what this pass would do to one lane, computed from the same inputs the live
# ladders use and never acting. Only the dry-run table reads it, and the inbox
# ladder comes first because that is the order the real pass runs in.
dry_plan() {  # <id> <busy> <changed> <conn_err> <stage> <strikes> <inbox-min>
  local busy=$2 changed=$3 conn_err=$4 stage=$5 strikes=$6
  local inbox_secs=$(( ${7:-0} * 60 ))
  if [ "$inbox_secs" -ge "$INBOX_RING_SECS" ]; then
    if [ "$inbox_secs" -ge "$INBOX_RELAUNCH_SECS" ]; then
      printf 'inbox: would relaunch'
    elif [ "$inbox_secs" -ge "$INBOX_INTERRUPT_SECS" ]; then
      printf 'inbox: would interrupt and continue'
    else
      printf 'inbox: would re-ring'
    fi
    return 0
  fi
  if [ "$conn_err" = 1 ] && [ "$changed" -ge "$CONNECTION_SECS" ]; then
    if [ "$(csv_recent "$strikes" "$(now_epoch)" "$HOUR")" -lt "$CONNECTION_STRIKES" ]; then
      printf 'would continue'
    else
      printf 'would relaunch on fallback model'
    fi
    return 0
  fi
  if [ "$busy" = busy ]; then
    if [ "$changed" -lt "$NO_PROGRESS_SECS" ]; then
      printf 'working'
    else
      case "$stage" in
        0) printf 'would re-ring' ;;
        1|2) printf 'would relaunch' ;;
        *) printf 'would escalate' ;;
      esac
    fi
    return 0
  fi
  if [ "$changed" -ge "$IDLE_SECS" ] && [ "$stage" -eq 0 ]; then
    printf 'would check idle'
    return 0
  fi
  printf 'ok'
}

# task_interrupt_continue <id> <why>: cancel the current turn and hand the
# agent a bounded continue, so a lane that is sitting mid-turn never seeing its
# inbox starts a fresh turn that drains it.
task_interrupt_continue() {  # <id> <why>
  local id=$1 why=$2 out rc
  if [ "$DRY_RUN" = 1 ]; then
    printf 'watchdog: would interrupt and continue %s (%s)\n' "$id" "$why"
    return 0
  fi
  out=$(fm_run_timed "$READ_TIMEOUT_SECS" "$CONTROL_BIN" "$id" interrupt 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'watchdog: interrupt of %s was refused: %s\n' "$id" "$(first_line "$out")"
    return 1
  fi
  "$SEND_BIN" "$id" --fire-and-forget "watchdog-interrupt-$id" \
    "The watchdog interrupted your turn: a steering message has been waiting unread for $why. Read state/$id.inbox/ now, act on every message in order, move each handled record into handled/, then continue the task." \
    >/dev/null 2>&1 || true
  printf 'watchdog: interrupted %s and asked it to drain its inbox (%s)\n' "$id" "$why"
  return 0
}

# task_drain_relaunch <id> <why>: the last rung of the inbox ladder. The lane
# is replaced, and the replacement is told what is waiting, because the record
# outlives the agent that never read it.
task_drain_relaunch() {  # <id> <why>
  local id=$1 why=$2 note
  note="A steering message in state/$id.inbox/ has waited $why without being read. Start by reading every record there in numeric order, acting on each, and moving each handled record into handled/, then continue the task. Your brief is unchanged."
  if [ "$DRY_RUN" = 1 ]; then
    printf 'watchdog: would relaunch %s to drain an unread steering inbox (%s)\n' "$id" "$why"
    return 0
  fi
  task_relaunch "$id" "steering inbox unread for $why" "$note"
}

# inbox_pass: walk every planned lane's oldest unread steer up its age ladder.
# Ordered before the task pass so a lane that this pass relaunches is already
# marked touched and the stall ladder does not also act on the old endpoint.
inbox_pass() {
  local meta id kind backend target state oldest base age
  local sig since stage stage_at rings relaunches steers woke istage istage_at ibase strikes
  local mins
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    [ -d "$STATE/$id.inbox" ] || continue
    oldest=$(inbox_oldest "$id") || continue
    base=${oldest##*/}
    age=$(path_age_now "$oldest")
    # A dead or unclassifiable endpoint is the task pass's business: replacing
    # it restores the lane and the record stays durable until it is read.
    state=$(task_agent_state "$id" "$meta")
    [ "$state" = alive ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
    [ -n "$target" ] || continue

    task_load "$id"
    # One ladder episode per message: a new oldest record starts again at the
    # bottom, and a rung already taken is never taken twice.
    if [ "$ibase" != "$base" ]; then
      istage=0
      istage_at=0
      ibase=$base
    fi
    mins=$((age / 60))
    if [ "$age" -ge "$INBOX_RELAUNCH_SECS" ] && [ "$istage" -lt 3 ]; then
      task_drain_relaunch "$id" "$mins minutes" || true
      istage=3
      istage_at=$(now_epoch)
      if [ "$DRY_RUN" != 1 ]; then
        touch "$WORK/touched.$id" 2>/dev/null || true
      fi
      wake_firstmate "watchdog-inbox-$id" \
        "check: watchdog relaunched $id because its steering inbox went unread for $mins minutes; if it still does not drain, the lane needs a hand"
    elif [ "$age" -ge "$INBOX_INTERRUPT_SECS" ] && [ "$istage" -lt 2 ]; then
      task_interrupt_continue "$id" "$mins minutes" || true
      istage=2
      istage_at=$(now_epoch)
      if [ "$DRY_RUN" != 1 ]; then
        touch "$WORK/touched.$id" 2>/dev/null || true
      fi
    elif [ "$age" -ge "$INBOX_RING_SECS" ] && [ "$istage" -lt 1 ]; then
      if [ "$DRY_RUN" = 1 ]; then
        printf 'watchdog: would re-ring %s for an unread steering message (%s minutes)\n' "$id" "$mins"
      else
        fm_task_inbox_ring "$backend" "$target" "$oldest" "fm-$id" >/dev/null 2>&1 \
          || printf 'watchdog: re-ring of %s failed; the record stays durable\n' "$id"
      fi
      istage=1
      istage_at=$(now_epoch)
    fi
    task_store "$id"
  done
  return 0
}

# --- backlog reconcile ------------------------------------------------------

# backlog_pass: report in-flight backlog items that no task record can serve,
# and live lanes whose record went missing, once per change of either set. The
# watchdog never writes a task record: a wrong endpoint binding is worse than a
# lane that is visibly unowned, so this only names what firstmate must adopt or
# close.
backlog_pass() {
  local ids orphans unresolved hash flagged count line
  BACKLOG_JSON='{}'
  [ "$BACKLOG_ENABLED" = on ] || return 0
  [ -n "$BACKLOG_BIN" ] && command -v "$BACKLOG_BIN" >/dev/null 2>&1 || return 0
  # Named explicitly: the pass runs from the code root, while the record it must
  # compare against is this home's own backlog.
  local -a file_args=()
  [ ! -f "$DATA_DIR/backlog.md" ] || file_args=(--file "$DATA_DIR/backlog.md")
  ids=$(fm_run_timed "$READ_TIMEOUT_SECS" "$BACKLOG_BIN" list --state in_flight \
    ${file_args[@]+"${file_args[@]}"} 2>/dev/null \
    | awk 'NR > 1 && /^  / { print $1 }' | cut -d, -f1 \
    | grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' | sort -u) || ids=''
  [ -n "$ids" ] || return 0
  orphans=$(printf '%s\n' "$ids" | while IFS= read -r line; do
      [ -f "$STATE/$line.meta" ] || printf '%s\n' "$line"
    done)
  unresolved=$(live_lanes_without_meta)
  hash=$(printf '%s\n--\n%s\n' "$orphans" "$unresolved" | cksum 2>/dev/null | tr -d ' ')
  count=$(printf '%s\n' "$orphans" | grep -c . || true)
  flagged=$(jq -r '.backlog.hash // ""' "$RECORD" 2>/dev/null) || flagged=''
  BACKLOG_JSON=$(jq -n --arg hash "$hash" --argjson count "${count:-0}" \
    --arg at "$(now_epoch)" \
    '{ hash: $hash, count: $count, flagged_at: (($at | tonumber) // 0) }')
  [ -n "$orphans$unresolved" ] || return 0
  if [ "$hash" != "$flagged" ]; then
    printf 'watchdog: %s in-flight backlog item(s) with no task record:\n' "${count:-0}"
    printf '%s\n' "$orphans" | grep . | head -n "$BACKLOG_LIST_MAX" | sed 's/^/  /'
    if [ -n "$unresolved" ]; then
      printf 'watchdog: live lane(s) with no task record:\n'
      printf '%s\n' "$unresolved" | head -n "$BACKLOG_LIST_MAX" | sed 's/^/  /'
    fi
    wake_firstmate "watchdog-backlog" \
      "check: watchdog found ${count:-0} in-flight backlog item(s) with no task record (fm-send cannot resolve them) plus any live lane with no record; adopt or close each: $(printf '%s' "$orphans" | grep . | head -n "$BACKLOG_LIST_MAX" | tr '\n' ' ')"
  fi
  return 0
}

# live_lanes_without_meta: session windows that carry a lane name but no task
# record. Only fleet-shaped names count - a name that starts with fm- is the
# fleet's own convention - so an ordinary shell window is never reported. The
# sessions come from the records themselves, never from a guessed global name.
live_lanes_without_meta() {
  local meta win name id
  command -v tmux >/dev/null 2>&1 || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    win=$(fm_meta_get "$meta" window)
    case "$win" in *:*) printf '%s\n' "${win%%:*}" ;; esac
  done | sort -u | while IFS= read -r win; do
      [ -n "$win" ] || continue
      tmux list-windows -t "$win" -F '#{window_name}' 2>/dev/null
    done | sort -u | while IFS= read -r name; do
      case "$name" in fm-*) ;; *) continue ;; esac
      id=${name#fm-}
      case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
      [ -f "$STATE/$id.meta" ] || printf '%s\n' "$id"
    done
}

main_status() {
  if [ ! -f "$RECORD" ]; then
    printf 'watchdog: no record yet at %s\n' "$RECORD"
    return 0
  fi
  jq -r '
    "watchdog record schema \(.schema // 0) boot \(.boot_identity // "unknown")",
    ( if ((.tasks // {}) | length) == 0 then "no task history"
      else "tasks:",
        ((.tasks // {}) | to_entries[] |
          "  \(.key): stage=\(.value.stage // 0) since=\(.value.since // 0) relaunches=\(((.value.relaunches // []) | length)) rings=\(((.value.rings // []) | length)) steers=\(((.value.steers // []) | length)) woke=\(.value.woke // false)") end ),
    ( if ((.units // {}) | length) == 0 then "no unit history"
      else "units:",
        ((.units // {}) | to_entries[] |
          "  \(.key): restarts=\((.value.restarts // []) | length) woke_at=\(.value.woke_at // 0)") end )
  ' "$RECORD" 2>/dev/null || printf 'watchdog: record at %s is unreadable\n' "$RECORD"
  return 0
}

main() {
  local action=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h|help) usage ;;
      status) action=status ;;
      tick|sweep) action=tick ;;
      --dry-run) DRY_RUN=1 ;;
      *) printf 'fm-watchdog-worker.sh: unknown action: %s\n' "$1" >&2; usage ;;
    esac
    shift
  done
  if [ "$action" = status ]; then
    main_status
    return 0
  fi

  [ -d "$STATE" ] || { printf 'fm-watchdog-worker.sh: no state directory at %s\n' "$STATE" >&2; return 2; }
  if [ "$DRY_RUN" = 1 ]; then
    # A dry run writes nothing into the live home, not even a scratch directory
    # or the pass lock, so it can never block or disturb a real pass.
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-watchdog-dry.XXXXXX") || return 2
    # shellcheck disable=SC2064 # The path is fixed at trap time by design.
    trap "rm -rf '$WORK'" EXIT
  else
    mkdir -p "$STATE" 2>/dev/null || true
    WORK=$(mktemp -d "$STATE/.watchdog-worker.work.XXXXXX") || return 2
    # shellcheck disable=SC2064 # The path is fixed at trap time by design.
    trap "rm -rf '$WORK'" EXIT
    if ! fm_lock_try_acquire "$LOCK"; then
      printf 'watchdog: another pass is running; skipping this one\n'
      return 0
    fi
  fi

  RELAUNCH_PER_HOUR=$(conf_int FM_WATCHDOG_RELAUNCH_PER_HOUR 3)
  UNIT_RESTARTS_PER_HOUR=$(conf_int FM_WATCHDOG_UNIT_RESTARTS_PER_HOUR 3)
  RINGS_PER_HOUR=$(conf_int FM_WATCHDOG_RINGS_PER_HOUR 2)
  IDLE_STEERS_PER_HOUR=$(conf_int FM_WATCHDOG_IDLE_STEERS_PER_HOUR 1)
  NO_PROGRESS_SECS=$(conf_int FM_WATCHDOG_NO_PROGRESS_SECS 1800)
  IDLE_SECS=$(conf_int FM_WATCHDOG_IDLE_SECS 1800)
  RUNG_GRACE_SECS=$(conf_int FM_WATCHDOG_RUNG_GRACE_SECS 600)
  UNITS_ENABLED=$(conf FM_WATCHDOG_UNITS on)
  UNIT_ALLOW=$(conf FM_WATCHDOG_UNIT_ALLOW 'fm-*')
  UNIT_DENY=$(conf FM_WATCHDOG_UNIT_DENY 'fm-watchdog-worker.service fm-watchdog-worker.timer')
  CHAIR_UNIT=$(conf FM_WATCHDOG_CHAIR_UNIT 'fm-chair.service')
  CHAIR_SESSION=$(conf FM_WATCHDOG_CHAIR_SESSION 'chair')
  CHAIR_TARGET=$(conf FM_WATCHDOG_CHAIR_TARGET '')
  CAPTURE_LINES=$(conf_int FM_WATCHDOG_CAPTURE_LINES 24)
  READ_TIMEOUT_SECS=$(conf_int FM_WATCHDOG_READ_TIMEOUT_SECS 10)
  RELAUNCH_TIMEOUT_SECS=$(conf_int FM_WATCHDOG_RELAUNCH_TIMEOUT_SECS 240)
  BOOT_BUDGET_SECS=$(conf_int FM_WATCHDOG_BOOT_BUDGET_SECS 1500)
  INBOX_RING_SECS=$(conf_int FM_WATCHDOG_INBOX_RING_SECS 1200)
  INBOX_INTERRUPT_SECS=$(conf_int FM_WATCHDOG_INBOX_INTERRUPT_SECS 2700)
  INBOX_RELAUNCH_SECS=$(conf_int FM_WATCHDOG_INBOX_RELAUNCH_SECS 5400)
  CONNECTION_SECS=$(conf_int FM_WATCHDOG_CONNECTION_SECS 600)
  CONNECTION_STRIKES=$(conf_int FM_WATCHDOG_CONNECTION_STRIKES 3)
  # The advertised worker model for DeepSeek V4.1 Flash, exactly as the fleet
  # records it in state/<id>.meta. Empty disables the fallback model entirely,
  # which is what a home with no second gateway wants.
  FALLBACK_MODEL=$(conf FM_WATCHDOG_FALLBACK_MODEL 'openrouter-named/deepseek/deepseek-v4.1-flash-1017')
  FALLBACK_KINDS=$(conf FM_WATCHDOG_FALLBACK_KINDS 'ship scout')
  BACKLOG_ENABLED=$(conf FM_WATCHDOG_BACKLOG on)
  BACKLOG_BIN=$(conf FM_WATCHDOG_BACKLOG_BIN 'tasks-axi')
  BACKLOG_LIST_MAX=$(conf_int FM_WATCHDOG_BACKLOG_LIST_MAX 25)
  AGENT_STATE_DIR=${FM_WATCHDOG_AGENT_STATE_DIR:-}
  CAPTURE_DIR=${FM_WATCHDOG_CAPTURE_DIR:-}

  record_load
  printf '%s' "$PRIOR_TASKS" > "$WORK/tasks.json" 2>/dev/null || printf '{}' > "$WORK/tasks.json"

  local boot units
  boot=$(boot_identity)
  # A host that exposes no boot identity never guesses one: it simply runs the
  # unit and task passes, which is the safe subset of the boot pass.
  if [ -n "$boot" ] && [ "$boot" != "$RECORD_BOOT" ]; then
    boot_pass "$boot"
  fi
  unit_pass
  # The unit pass hands its result back through a file. A missing or malformed
  # result must not cost the task history, so it degrades to an empty map.
  units=$(cat "$WORK/units.json" 2>/dev/null) || units='{}'
  printf '%s' "$units" | jq -e 'type == "object"' >/dev/null 2>&1 || units='{}'
  if [ "$DRY_RUN" = 1 ]; then
    printf 'watchdog: dry run - no lane, unit, record, or wake is touched\n'
    printf 'lane\tendpoint\tstate\tbusy\tconn\tquiet_min\tinbox_min\taction\n'
  fi
  inbox_pass
  task_pass
  backlog_pass
  record_store "$boot" "$units" "$BACKLOG_JSON"
  [ "$DRY_RUN" = 1 ] || fm_lock_release "$LOCK"
  return 0
}

main "$@"
