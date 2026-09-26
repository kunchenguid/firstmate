#!/usr/bin/env bash
# fm-supervision-host.sh - the supervision host: watcher-cycle ownership plus a
# headless engine session that runs the supervision branch's contract beside a
# non-Pi primary (docs/supervision-host.md owns the design).
#
# Usage:
#   fm-supervision-host.sh park [--restart]
#
# A primary's arm owner runs this in place of bin/fm-watch-arm.sh when the home
# opted in (config/supervision-host): the Claude Stop auto-arm
# (bin/fm-claude-stop-autoarm.sh), the Cursor stop-hook park
# (bin/fm-turnend-guard-cursor.sh), the OpenCode TUI plugin
# (.opencode/plugins/fm-primary-watch-arm.js), the omp watch extension
# (.omp/extensions/fm-primary-omp-watch.ts), Grok's model-owned background arm
# (docs/supervision-protocols/grok.md), and Codex's foreground checkpoint
# (bin/fm-watch-checkpoint.sh). To that owner it IS an arm: it prints the
# arm's own lines and exits only when main is needed, and stays parked across
# every close it handled itself. Each owner passes its harness as
# FM_SUPERVISION_HOST_PRIMARY, which the engine carries as the primary pin.
#
# OUTPUT, the contract every owner reads. The first cycle's status line
# ("watcher: started ..." or "watcher: attached ...") is printed as soon as the
# arm prints it, so an owner that waits for arm readiness sees it at once;
# everything else is printed in one write when the host exits: the close as
# the arm printed it (without that status line), then any "supervision-host:"
# lines. A "supervision-host:" line is a wake in its own right (the park
# boundary prints nothing else); "supervision-host stood down: ..." means this
# session or generation no longer owns supervision and the owner stands down
# silently; an exit status above 128, or no output at all, means the host
# itself died and the owner retries it. Any other close is judged exactly as
# the arm's. --restart starts the first cycle with fm-watch-arm.sh --restart,
# and an FM_WATCH_PREDECESSOR_ARM_PID the owner passes reaches that first
# cycle only, for owners that start their own successor after every close
# (OpenCode, omp).
#
# THE LOOP. It owns watcher cycles through bin/fm-watch-arm.sh. On each
# actionable close:
#   - attended (no away-posture record state/.afk-contract): it exits with the
#     close exactly as the arm printed it, so main is woken for every wake as
#     it is without the host (the attended posture moves onto the host in a
#     later step, docs/supervision-host.md "Scope");
#   - away (the record exists): it starts and verifies the successor watcher
#     cycle and confirms the handling handoff (the order docs/watcher-
#     continuity.md owns), computes the rows the branch may claim with the
#     dispatch owner (bin/fm-branch-dispatch.mjs), publishes that grant
#     (bin/fm-wake-grant.sh), runs one bounded headless engine turn
#     (bin/fm-supervision-engine-lib.sh) with the generated branch prompt
#     (bin/fm-branch-prompt.sh) and the away tail, releases the branch's
#     leases and grant, and counts the wake handled only when that turn
#     exited cleanly, recorded a durable report (bin/fm-branch-report.sh), and
#     left none of its granted rows in the wake queue. A handled wake - a
#     routine or a captain outcome alike - never wakes main: captain outcomes
#     wait in the outcome store for the return brief. It then parks on the
#     successor.
# Every other outcome exits with the close's own reason line plus one
# "supervision-host:" line saying why main has this wake, after stopping the
# successor cycle so main's next turn end starts from the same state as
# without the host. Whenever the captain returned during an engine turn that
# recorded outcomes, handled or not, the return brief was rendered before they
# existed, so the host exits with the close, one "supervision-host:" line
# naming them, and one line per outcome, for main to relay. The host injects
# nothing and has no delivery path of its own; the owner's existing wake path
# is the only way main hears from it. That handoff is only a prompt: each
# outcome recorded after the return is already a durable queued wake
# (bin/fm-branch-report.sh), so it still reaches main when the host dies at the
# turn's end or its owner drops the handoff, as a superseded Cursor park does.
#
# THE LATCH. An opted-in away host persists engine health across short-lived
# parks; docs/supervision-host.md "The broken-session latch" owns the policy.
#
# THE PARK BOUNDARY. Claude drops the exit 2 of a Stop hook it terminated at
# the hook's configured timeout (docs/verification/supervision.md), Cursor's
# stop hook carries the same tracked 28800-second registration, and a host
# that handles its own wakes is not shortened by them, so the host ends its
# own park before that timeout: after FM_SUPERVISION_HOST_PARK_SECONDS (default
# 27000, under the tracked 28800-second registration) it stops this home's
# watcher and exits with one "supervision-host: cycle boundary" line, which the
# owner delivers as an ordinary wake; main drains, acknowledges, and ends its
# turn, and that turn end starts the next park. The boundary is checked on
# every loop pass, however many closes are already waiting, and an away close
# whose engine turn could still be running at the turn limit (the turn bound
# plus the engine grace), judged when the close arrives and again just before
# the turn starts, is not handled: the host exits through the same boundary
# with that close printed ahead of the line. The turn limit is the boundary
# itself unless the owner sets FM_SUPERVISION_HOST_PARK_LIMIT later: Codex's
# checkpoint, whose bound is the park itself rather than a harness timeout,
# lets a turn that starts before the boundary finish after it.
#
# OWNERSHIP. Before activation, every successor cycle, and every engine turn
# the host proves this session still holds the fleet lock
# (bin/fm-session-lock-lib.sh) and, when launched by the auto-arm, that the
# auto-arm generation it serves (FM_SUPERVISION_HOST_AUTOARM_GEN owned by
# FM_SUPERVISION_HOST_OWNER_PID) is still current; otherwise it stands down
# with a "supervision-host:" line and leaves the decision to its owner; a
# host that stands down before activation leaves the owner's host record,
# processes, arms, and leases alone. The engine runs with
# FM_SUPERVISION_ACTOR=branch, the session-lock holder as FM_LEASE_HOLDER_PID,
# the primary's harness pin, and this turn's report id, so every guarded
# script applies the same partition, leases, and away relocation it applies to
# the Pi branch. At activation the host stops anything a crashed predecessor
# left running (recorded with identities, never by name), including the
# engine descendants its turn recorded, removes that turn's files, and
# releases the branch actor's leases; it releases them again after every
# engine turn.
#
# STATE (all under state/, owned here): .supervision-host (this host's pid and
# the processes it runs), .supervision-host-engine (the engine conversation:
# engine, model, session id, main-session key, turn count, running cost),
# .supervision-host-turn and .supervision-host-receipts (the current turn's
# report scope and the reports it recorded), .supervision-host-prompt and
# .supervision-host-wake (the prompt and wake text of the current turn),
# .supervision-host-health (the latch: errors, cooldown, and probe time, keyed
# to the main session, engine, and model), and .supervision-host.log (a bounded
# ledger of where every close went, with each engine turn's usage and
# outcome).
#
# Tunables (environment): FM_SUPERVISION_HOST_PARK_SECONDS (27000; a positive
# integer below the 28800-second registration, any other value is the default),
# FM_SUPERVISION_HOST_PARK_LIMIT (the park boundary; a later value below the
# registration lets turns run past the boundary up to it, any other value is
# the boundary), FM_SUPERVISION_HOST_TURN_TIMEOUT (1200), FM_SUPERVISION_HOST_ROTATE_TURNS (20:
# a new engine conversation after this many turns; every main session start
# also opens a new one), FM_SUPERVISION_HOST_READY_TIMEOUT (25: how long a
# successor cycle may take to verify), FM_SUPERVISION_HOST_POLL (1).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

FIRST_ARM_RESTART=0
case "${1:-}" in
  park)
    case "$#:${2:-}" in
      1:) ;;
      2:--restart) FIRST_ARM_RESTART=1 ;;
      *) echo "usage: fm-supervision-host.sh park [--restart]" >&2; exit 2 ;;
    esac
    ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: fm-supervision-host.sh park [--restart]" >&2; exit 2 ;;
esac

numeric_or() {  # <value> <default>
  case "$1" in ''|0*|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
ENGINE_GRACE=$(numeric_or "${FM_SUPERVISION_ENGINE_GRACE:-}" 30)
PARK_SECONDS=$(numeric_or "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" 27000)
[ "$PARK_SECONDS" -lt 28800 ] 2>/dev/null || PARK_SECONDS=27000
PARK_LIMIT=$(numeric_or "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" "$PARK_SECONDS")
{ [ "$PARK_LIMIT" -lt 28800 ] && [ "$PARK_LIMIT" -ge "$PARK_SECONDS" ]; } 2>/dev/null || PARK_LIMIT=$PARK_SECONDS
TURN_TIMEOUT=$(numeric_or "${FM_SUPERVISION_HOST_TURN_TIMEOUT:-}" 1200)
ROTATE_TURNS=$(numeric_or "${FM_SUPERVISION_HOST_ROTATE_TURNS:-}" 20)
READY_TIMEOUT=$(numeric_or "${FM_SUPERVISION_HOST_READY_TIMEOUT:-}" 25)
POLL=$(numeric_or "${FM_SUPERVISION_HOST_POLL:-}" 1)
COOLDOWN=300
COOLDOWN_MAX=3600
AUTOARM_GEN=${FM_SUPERVISION_HOST_AUTOARM_GEN:-}
AUTOARM_OWNER=${FM_SUPERVISION_HOST_OWNER_PID:-}
PRIMARY=${FM_SUPERVISION_HOST_PRIMARY:-}
[ -n "$PRIMARY" ] || PRIMARY=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
# The owner's predecessor arm belongs to the first cycle only.
OWNER_PREDECESSOR=${FM_WATCH_PREDECESSOR_ARM_PID:-}
case "$OWNER_PREDECESSOR" in *[!0-9]*) OWNER_PREDECESSOR= ;; esac
unset FM_WATCH_PREDECESSOR_ARM_PID FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN

HOST_RECORD="$STATE/.supervision-host"
ENGINE_RECORD="$STATE/.supervision-host-engine"
TURN_FILE="$STATE/.supervision-host-turn"
RECEIPTS="$STATE/.supervision-host-receipts"
PROMPT_FILE="$STATE/.supervision-host-prompt"
WAKE_FILE="$STATE/.supervision-host-wake"
HOST_LOG="$STATE/.supervision-host.log"
ENGINE_PID_FILE="$STATE/.supervision-host.engine-pid"
HEALTH_FILE="$STATE/.supervision-host-health"

HOST_PID=$$
HOST_STARTED=$(date +%s)
GEN="host-$HOST_PID-$HOST_STARTED"
TURN_SEQ=0
LAST_TURN=
ENGINE_ERROR=0
HEALTH_NOTE=
GRANT_ACTIVE=0
ARM_PID=
ARM_OUT=
ARM_TEXT=
CLOSED_ARM_PID=
HANDLE_WHY=
ENGINE_SUBSHELL=
SUCCESSOR_PID=
SUCCESSOR_OUT=
ENGINE_RUNNING=0
# The running turn's result and diagnostics files, removed by the cleanup when
# the host is stopped mid-turn.
TURN_RESULT=
TURN_ERRORS=
# The first cycle's status line, printed as soon as the arm prints it
# (header, OUTPUT) and left out of that cycle's close.
READY_PENDING=1
READY_LINE=

log_line() {  # <text>
  local tmp
  printf '%s\t%s\n' "$(date +%s)" "$1" >> "$HOST_LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$HOST_LOG" 2>/dev/null | tr -d ' ')" -gt 600 ] 2>/dev/null; then
    tmp=$(mktemp "$HOST_LOG.tmp.XXXXXX" 2>/dev/null) || return 0
    tail -n 400 "$HOST_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$HOST_LOG" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
  fi
}

identity_of() {  # <pid>
  _fm_engine_identity "$1" || true
}

# Record one process this host runs, so a successor host can stop exactly it.
record_process() {  # <role> <pid>
  printf '%s\t%s\t%s\n' "$1" "$2" "$(identity_of "$2")" >> "$HOST_RECORD" 2>/dev/null || true
}

# Re-record a process under its current identity. Safe only for this host's
# own unreaped child, whose pid cannot be recycled: its first identity may have
# been read between its fork and its exec.
refresh_process() {  # <pid>
  local pid=$1 identity tmp
  [ -n "$pid" ] && [ -f "$HOST_RECORD" ] || return 0
  identity=$(identity_of "$pid")
  [ -n "$identity" ] || return 0
  awk -F '\t' -v pid="$pid" -v id="$identity" '$2 == pid && $3 != id { found = 1 } END { exit !found }' "$HOST_RECORD" 2>/dev/null || return 0
  tmp=$(mktemp "$HOST_RECORD.tmp.XXXXXX" 2>/dev/null) || return 0
  awk -F '\t' -v OFS='\t' -v pid="$pid" -v id="$identity" '$2 == pid { $3 = id } { print }' "$HOST_RECORD" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$HOST_RECORD" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

forget_process() {  # <pid>
  local tmp
  [ -f "$HOST_RECORD" ] || return 0
  tmp=$(mktemp "$HOST_RECORD.tmp.XXXXXX" 2>/dev/null) || return 0
  awk -F '\t' -v pid="$1" '$2 != pid' "$HOST_RECORD" > "$tmp" 2>/dev/null && mv -f "$tmp" "$HOST_RECORD" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# Stop a recorded process only while it still answers to its recorded
# identity: TERM, then KILL once <seconds> pass.
stop_recorded() {  # <pid> <identity> <seconds>
  local pid=$1 identity=$2 limit=$(( ${3:-10} * 10 )) i
  fm_pid_alive "$pid" || return 0
  [ -n "$identity" ] && [ "$(identity_of "$pid")" = "$identity" ] || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  i=0
  while [ "$i" -lt "$limit" ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if fm_pid_alive "$pid" && [ "$(identity_of "$pid")" = "$identity" ]; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

branch_env() {  # <command...>: run with the branch actor identity
  FM_SUPERVISION_ACTOR=branch "$@"
}

release_branch_leases() {
  branch_env "$SCRIPT_DIR/fm-lease.sh" release-actor --actor branch >/dev/null 2>&1 || true
}

# Stop whatever a predecessor host left running, then take the record. The
# auto-arm admits one generation at a time, so a predecessor still alive here
# was superseded (its owner died or went stale) or crashed mid-cleanup.
activate() {
  local role pid identity
  mkdir -p "$STATE" || return 1
  if [ -f "$HOST_RECORD" ]; then
    # The predecessor host first, with room for its own cleanup (which stops
    # its engine and arms), before anything it left is stopped individually.
    while IFS="$(printf '\t')" read -r role pid identity; do
      [ "$role" = host ] || continue
      [ "$pid" != "$HOST_PID" ] || continue
      stop_recorded "$pid" "$identity" $((ENGINE_GRACE + 20))
    done < "$HOST_RECORD"
  fi
  if [ -f "$ENGINE_PID_FILE" ]; then
    IFS="$(printf '\t')" read -r pid identity < "$ENGINE_PID_FILE" || true
    stop_recorded "${pid:-}" "${identity:-}" $((ENGINE_GRACE + 5))
    rm -f "$ENGINE_PID_FILE"
  fi
  if [ -f "$HOST_RECORD" ]; then
    while IFS="$(printf '\t')" read -r role pid identity; do
      [ "$role" = arm ] && stop_recorded "$pid" "$identity" 10
    done < "$HOST_RECORD"
  fi
  # A predecessor killed outright ran no cleanup: reap the engine descendants
  # its turn recorded, then drop that turn's files.
  local ledger
  for ledger in "$STATE"/.supervision-host-descendants.*; do
    case "$ledger" in *.pids|*.next) continue ;; esac
    [ -f "$ledger" ] && _fm_engine_reap "$ledger"
  done
  rm -f "$STATE"/.supervision-host-arm.* "$STATE"/.supervision-host-descendants.* "$STATE"/.supervision-host-result.* \
    "$STATE"/.supervision-host-errors.* "$STATE"/.supervision-host-readback.* "$TURN_FILE" 2>/dev/null || true
  printf 'host\t%s\t%s\n' "$HOST_PID" "$(identity_of "$HOST_PID")" > "$HOST_RECORD" || return 1
  release_branch_leases
}

# Stop a running engine turn: TERM the bounded process, whose watchdog passes
# it on and KILLs after its grace, then let the turn's own poller reap the
# engine's descendants before giving up on it.
stop_engine_turn() {
  local pid='' identity='' i limit
  [ -f "$ENGINE_PID_FILE" ] && IFS="$(printf '\t')" read -r pid identity < "$ENGINE_PID_FILE"
  if [ -n "$pid" ] && fm_pid_alive "$pid" && [ "$(identity_of "$pid")" = "$identity" ]; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  limit=$(( (ENGINE_GRACE + 10) * 10 ))
  i=0
  while [ -n "$ENGINE_SUBSHELL" ] && fm_pid_alive "$ENGINE_SUBSHELL" && [ "$i" -lt "$limit" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -z "$ENGINE_SUBSHELL" ] || kill -KILL "$ENGINE_SUBSHELL" 2>/dev/null || true
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  local rc=$? f
  trap - EXIT HUP TERM INT
  if [ "$ENGINE_RUNNING" -eq 1 ]; then
    stop_engine_turn
  fi
  retire_arm "$SUCCESSOR_PID" "$SUCCESSOR_OUT"
  retire_arm "$ARM_PID" "$ARM_OUT"
  if [ "$GRANT_ACTIVE" -eq 1 ]; then
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    "$SCRIPT_DIR/fm-wake-grant.sh" deactivate "$HOST_PID" "$GEN" >/dev/null 2>&1 || true
  fi
  release_branch_leases
  rm -f "$TURN_FILE" "$ENGINE_PID_FILE" 2>/dev/null || true
  for f in "$TURN_RESULT" "$TURN_ERRORS"; do
    case "$f" in "$STATE"/.supervision-host-*) rm -f "$f" 2>/dev/null || true ;; esac
  done
  if [ -f "$HOST_RECORD" ] && [ "$(awk -F '\t' '$1 == "host" { print $2; exit }' "$HOST_RECORD" 2>/dev/null)" = "$HOST_PID" ]; then
    rm -f "$HOST_RECORD" 2>/dev/null || true
  fi
  exit "$rc"
}
# Stop one arm this host started (its TERM handler stops the watcher it owns)
# and drop its output file.
retire_arm() {  # <pid> <output-file>
  local pid=${1:-} out=${2:-} i
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 100 ] && fm_pid_alive "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
    fm_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
  fi
  [ -z "$pid" ] || forget_process "$pid"
  [ -z "$out" ] || rm -f "$out" 2>/dev/null || true
}

host_still_owner() {
  fm_session_lock_owned_by_self "$STATE" || return 1
  [ -n "$AUTOARM_GEN" ] || return 0
  fm_autoarm_ledger_read "$STATE" || return 1
  [ "$FM_AUTOARM_GEN" = "$AUTOARM_GEN" ] && [ "$FM_AUTOARM_OWNER" = "$AUTOARM_OWNER" ] \
    && [ "$FM_AUTOARM_OUTCOME" = arming ]
}

start_arm() {  # <predecessor-arm-pid or empty> [--restart]; sets the started pid/output
  local predecessor=$1 out pid
  shift
  out=$(mktemp "$STATE/.supervision-host-arm.XXXXXX") || return 1
  if [ -n "$predecessor" ]; then
    FM_WATCH_PREDECESSOR_ARM_PID=$predecessor FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" "$@" >"$out" 2>&1 &
  else
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" "$@" >"$out" 2>&1 &
  fi
  pid=$!
  record_process arm "$pid"
  STARTED_ARM_PID=$pid
  STARTED_ARM_OUT=$out
}

boundary_reached() {
  [ $(( $(date +%s) - HOST_STARTED )) -ge "$PARK_SECONDS" ]
}

# True when an engine turn started now could still be running at the turn
# limit (the boundary unless the owner set a later one).
turn_crosses_boundary() {
  [ $(( $(date +%s) - HOST_STARTED + TURN_TIMEOUT + ENGINE_GRACE )) -ge "$PARK_LIMIT" ]
}

# End the park at the boundary: stop the current and successor arms and this
# home's watcher, print any close already read so main drains it, then the
# boundary line.
boundary_exit() {
  retire_arm "$ARM_PID" "$ARM_OUT"
  retire_arm "$SUCCESSOR_PID" "$SUCCESSOR_OUT"
  ARM_PID=
  ARM_OUT=
  SUCCESSOR_PID=
  SUCCESSOR_OUT=
  "$SCRIPT_DIR/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  log_line "boundary	after $(( $(date +%s) - HOST_STARTED ))s"
  emit 'supervision-host: cycle boundary - the host ended its park at its bound; drain, acknowledge, and end the turn, and the next park starts on its own'
  exit 0
}

# Print the first cycle's status line once the arm has written it in full.
stream_ready_line() {
  local complete line
  complete=$(wc -l < "$ARM_OUT" 2>/dev/null | tr -d ' ')
  case "$complete" in ''|0|*[!0-9]*) return 0 ;; esac
  line=$(head -n "$complete" "$ARM_OUT" 2>/dev/null | grep -E -m 1 '^watcher: (started|attached) ' || true)
  [ -n "$line" ] || return 0
  printf '%s\n' "$line"
  READY_LINE=$line
  READY_PENDING=0
}

# Wait for the current arm to close. Returns 0 with ARM_TEXT set,
# or 1 when the park boundary arrives first.
await_close() {
  while fm_pid_alive "$ARM_PID"; do
    refresh_process "$ARM_PID"
    [ "$READY_PENDING" -eq 0 ] || stream_ready_line
    boundary_reached && return 1
    sleep "$POLL"
  done
  wait "$ARM_PID" 2>/dev/null || true
  ARM_TEXT=$(cat "$ARM_OUT" 2>/dev/null || true)
  if [ -n "$READY_LINE" ]; then
    # Already printed: drop its first occurrence from this first close.
    ARM_TEXT=$(printf '%s\n' "$ARM_TEXT" | awk -v line="$READY_LINE" '!dropped && $0 == line { dropped = 1; next } { print }')
    READY_LINE=
  fi
  READY_PENDING=0
  forget_process "$ARM_PID"
  rm -f "$ARM_OUT" 2>/dev/null || true
  CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
  ARM_OUT=
  return 0
}

# Print the close read so far, then the given lines, in one write (header,
# OUTPUT), so an owner reading a stream sees the whole exit at once.
emit() {  # [line...]
  local text=$ARM_TEXT line
  for line in "$@"; do
    [ -n "$line" ] || continue
    text=${text:+$text$'\n'}$line
  done
  [ -z "$text" ] || printf '%s\n' "$text"
}

# Hand the close to main: stop the successor cycle (the state main's own turn
# end starts from without the host), print the close, why, and any further
# "supervision-host:" lines, and exit.
exit_to_main() {  # <why> [further lines]
  if [ -n "$SUCCESSOR_PID" ]; then
    retire_arm "$SUCCESSOR_PID" "$SUCCESSOR_OUT"
    SUCCESSOR_PID=
    SUCCESSOR_OUT=
    "$SCRIPT_DIR/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  fi
  log_line "to-main	$1"
  emit "supervision-host: $1" "${2:-}"
  exit 0
}

# True when the captain returned during this close's engine turn and that turn
# recorded outcomes; sets RETURNED_SEQS to their store rows.
returned_during_turn() {
  RETURNED_SEQS=
  [ -n "$LAST_TURN" ] && [ ! -f "$STATE/.afk-contract" ] || return 1
  RETURNED_SEQS=$(awk -F '\t' -v turn="$LAST_TURN" '$1 == turn { printf "%s%s", sep, $2; sep = ", " }' "$RECEIPTS" 2>/dev/null)
  [ -n "$RETURNED_SEQS" ]
}

# The outcomes one turn recorded, one "supervision-host:" line each, from its
# receipts and the store (bin/fm-branch-outcome.sh owns the rows).
turn_outcome_lines() {  # <turn>
  local seqs
  seqs=$(awk -F '\t' -v turn="$1" '$1 == turn { printf "%s%s", sep, $2; sep = "," }' "$RECEIPTS" 2>/dev/null)
  [ -n "$seqs" ] || return 0
  "$SCRIPT_DIR/fm-branch-outcome.sh" list --recent 1000 2>/dev/null \
    | jq -r --arg seqs "$seqs" '($seqs | split(",") | map(tonumber)) as $want
        | select(.seq as $q | $want | index($q))
        | "supervision-host: outcome \(.seq) for \(.task) [\(.verdict)]: \(.summary)"' 2>/dev/null \
    | tr -d '\r'
}

stand_down() {  # <why>
  log_line "stand-down	$1"
  emit "supervision-host stood down: $1"
  exit 0
}

# Start the successor cycle and wait until it proves a live watcher. Sets
# SUCCESSOR_WATCHER and SUCCESSOR_GENERATION (empty when the arm attached).
start_successor() {  # <predecessor-arm-pid>
  local deadline line
  SUCCESSOR_WATCHER=
  SUCCESSOR_GENERATION=
  start_arm "$1" || return 1
  SUCCESSOR_PID=$STARTED_ARM_PID
  SUCCESSOR_OUT=$STARTED_ARM_OUT
  deadline=$(( $(date +%s) + READY_TIMEOUT ))
  while :; do
    line=$(grep -E '^watcher: (started|attached) pid=[0-9]+' "$SUCCESSOR_OUT" 2>/dev/null | head -n 1)
    if [ -n "$line" ]; then
      SUCCESSOR_WATCHER=$(printf '%s\n' "$line" | sed -E 's/^watcher: (started|attached) pid=([0-9]+).*/\2/')
      case "$line" in
        *' recovery-generation='*) SUCCESSOR_GENERATION=${line##* recovery-generation=} ;;
      esac
      refresh_process "$SUCCESSOR_PID"
      return 0
    fi
    fm_pid_alive "$SUCCESSOR_PID" || return 1
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

# The engine conversation for this turn: the recorded one while it belongs to
# this main session and has turns left, otherwise a new one. Sets ENGINE_SESSION
# and ENGINE_MODE (new|resume).
choose_conversation() {
  local key recorded_key recorded_session recorded_engine recorded_model turns
  key=$(fm_supervision_host_main_key "$STATE") || key=
  recorded_key=$(sed -n 's/^key=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  recorded_session=$(sed -n 's/^session=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  recorded_engine=$(sed -n 's/^engine=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  recorded_model=$(sed -n 's/^model=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  turns=$(numeric_or "$(sed -n 's/^turns=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)" 0)
  if [ -n "$key" ] && [ -n "$recorded_session" ] && [ "$recorded_key" = "$key" ] \
    && [ "$recorded_engine" = "$FM_SUPERVISION_ENGINE" ] \
    && [ "$recorded_model" = "$FM_SUPERVISION_ENGINE_MODEL" ] \
    && [ "$turns" -lt "$ROTATE_TURNS" ] && [ -s "$PROMPT_FILE" ]; then
    ENGINE_SESSION=$recorded_session
    ENGINE_MODE=resume
    ENGINE_TURNS=$turns
    ENGINE_COST=$(sed -n 's/^conversation_cost=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
    ENGINE_KEY=$key
    return 0
  fi
  ENGINE_SESSION=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$ENGINE_SESSION" in
    ????????-????-????-????-????????????) ;;
    *) ENGINE_SESSION=$(node -e 'process.stdout.write(require("node:crypto").randomUUID())' 2>/dev/null) || return 1 ;;
  esac
  ENGINE_MODE=new
  ENGINE_TURNS=0
  ENGINE_COST=0
  ENGINE_KEY=$key
  local tmp
  tmp=$(mktemp "$PROMPT_FILE.tmp.XXXXXX") || return 1
  if ! "$SCRIPT_DIR/fm-branch-prompt.sh" > "$tmp" 2>/dev/null \
    || [ "$(wc -c < "$tmp" | tr -d ' ')" -lt 1024 ]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$PROMPT_FILE" || return 1
  return 0
}

write_engine_record() {  # <turns> <conversation-cost>
  local tmp
  tmp=$(mktemp "$ENGINE_RECORD.tmp.XXXXXX") || return 1
  printf 'engine=%s\nmodel=%s\nsession=%s\nkey=%s\nturns=%s\nconversation_cost=%s\n' \
    "$FM_SUPERVISION_ENGINE" "$FM_SUPERVISION_ENGINE_MODEL" "$ENGINE_SESSION" "$ENGINE_KEY" "$1" "$2" > "$tmp" \
    && mv -f "$tmp" "$ENGINE_RECORD"
}

# Persist health between host parks; the main-session key prevents a recycled
# lock pid from inheriting another session's conversation or latch.
# docs/supervision-host.md "The broken-session latch" owns the policy.
health_key() {
  fm_supervision_host_health_key "$STATE"
}

# Sets HEALTH_ERRORS, HEALTH_COOLDOWN, and HEALTH_RETRY for the current key.
health_load() {
  local key
  HEALTH_ERRORS=0
  HEALTH_COOLDOWN=0
  HEALTH_RETRY=0
  key=$(health_key) || return 0
  [ "$(sed -n 's/^key=//p' "$HEALTH_FILE" 2>/dev/null | head -n 1)" = "$key" ] || return 0
  HEALTH_ERRORS=$(numeric_or "$(sed -n 's/^errors=//p' "$HEALTH_FILE" 2>/dev/null | head -n 1)" 0)
  HEALTH_COOLDOWN=$(numeric_or "$(sed -n 's/^cooldown=//p' "$HEALTH_FILE" 2>/dev/null | head -n 1)" 0)
  HEALTH_RETRY=$(numeric_or "$(sed -n 's/^retry_after=//p' "$HEALTH_FILE" 2>/dev/null | head -n 1)" 0)
}

health_save() {
  local key tmp
  key=$(health_key) || return 0
  tmp=$(mktemp "$HEALTH_FILE.tmp.XXXXXX" 2>/dev/null) || return 0
  printf 'key=%s\nerrors=%s\ncooldown=%s\nretry_after=%s\n' \
    "$key" "$HEALTH_ERRORS" "$HEALTH_COOLDOWN" "$HEALTH_RETRY" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$HEALTH_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# True while the latch holds main to every wake. Needs the engine config.
health_cooling() {
  local retry
  health_load
  retry=$(fm_supervision_host_paused_until "$STATE") && [ "$(date +%s)" -lt "$retry" ]
}

# Fold one finished turn into the latch. Sets HEALTH_NOTE to the one line main
# is owed when the latch trips for the first time.
health_record() {  # <engine-error 0|1> <reports>
  local now
  now=$(date +%s)
  HEALTH_NOTE=
  health_load
  if [ "$1" -eq 1 ]; then
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
    if [ "$HEALTH_ERRORS" -ge 2 ] || [ "$HEALTH_COOLDOWN" -gt 0 ]; then
      if [ "$HEALTH_COOLDOWN" -eq 0 ]; then
        HEALTH_COOLDOWN=$COOLDOWN
        HEALTH_NOTE="supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next $((COOLDOWN / 60)) minutes, then one wake probes it again"
      else
        HEALTH_COOLDOWN=$((HEALTH_COOLDOWN * 2))
        [ "$HEALTH_COOLDOWN" -le "$COOLDOWN_MAX" ] || HEALTH_COOLDOWN=$COOLDOWN_MAX
      fi
      HEALTH_RETRY=$((now + HEALTH_COOLDOWN))
      log_line "latch	errors=$HEALTH_ERRORS	cooldown=${HEALTH_COOLDOWN}s"
    fi
  elif [ "$2" -gt 0 ]; then
    [ "$HEALTH_COOLDOWN" -eq 0 ] || log_line "recovered	after a successful probe"
    HEALTH_ERRORS=0
    HEALTH_COOLDOWN=0
    HEALTH_RETRY=0
  elif [ "$HEALTH_COOLDOWN" -gt 0 ] && [ "$HEALTH_RETRY" -le "$now" ]; then
    HEALTH_RETRY=$((now + HEALTH_COOLDOWN))
  fi
  health_save
}

# Handle one away-posture close on the engine. Returns 0 when the wake is
# handled (or held nothing the branch may claim), else sets HANDLE_WHY and
# returns 1; sets ENGINE_ERROR when the turn failed on the engine itself. Runs
# in the host's own shell, never a subshell, because it advances the host's
# grant and turn state.
handle_away() {  # <reason-lines>
  local reason=$1 first scope status corrupted rows tasks unscoped rc turn readback
  local receipts usage result errors unacked
  LAST_TURN=
  ENGINE_ERROR=0
  HEALTH_NOTE=
  first=$(printf '%s\n' "$reason" | head -n 1)
  set --
  case "$first" in heartbeat*) set -- --heartbeat ;; esac
  if ! scope=$(node "$SCRIPT_DIR/fm-branch-dispatch.mjs" scope "$@" --afk 2>/dev/null); then
    HANDLE_WHY="branch eligibility could not be computed"
    return 1
  fi
  status=$(printf '%s\n' "$scope" | sed -n 's/^status=//p')
  corrupted=$(printf '%s\n' "$scope" | sed -n 's/^corrupted=//p')
  rows=$(printf '%s\n' "$scope" | sed -n 's/^rows=//p')
  tasks=$(printf '%s\n' "$scope" | sed -n 's/^tasks=//p')
  unscoped=$(printf '%s\n' "$scope" | sed -n 's/^unscoped=//p')
  if [ "$corrupted" = 1 ]; then
    HANDLE_WHY="a queued wake could not be read or resolved to a task record, so its scope is unknown"
    return 1
  fi
  if [ "$status" = empty ] || [ -z "$rows" ]; then
    log_line "no-op	nothing for the branch to claim	$first"
    return 0
  fi
  if [ "$GRANT_ACTIVE" -eq 0 ]; then
    if ! "$SCRIPT_DIR/fm-wake-grant.sh" activate "$HOST_PID" "$GEN" >/dev/null 2>&1; then
      HANDLE_WHY="the branch grant could not be activated"
      return 1
    fi
    GRANT_ACTIVE=1
  fi
  # shellcheck disable=SC2086 # rows is a space-separated list of sequence numbers.
  "$SCRIPT_DIR/fm-wake-grant.sh" publish "$GEN" $rows >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) ;;
    3) HANDLE_WHY="main already claimed these wake rows"; return 1 ;;
    *) HANDLE_WHY="the branch grant could not be published"; return 1 ;;
  esac
  if ! host_still_owner; then
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    HANDLE_WHY="this session no longer owns supervision"
    return 1
  fi
  if ! choose_conversation; then
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    HANDLE_WHY="the branch prompt or engine conversation could not be prepared"
    return 1
  fi
  TURN_SEQ=$((TURN_SEQ + 1))
  turn="$GEN.$TURN_SEQ"
  LAST_TURN=$turn
  : > "$RECEIPTS"
  printf 'turn=%s\nrows=%s\ntasks=%s\nunscoped=%s\nwake=%s\n' \
    "$turn" "$rows" "$tasks" "${unscoped:-0}" "$first" > "$TURN_FILE"
  readback=$(mktemp "$STATE/.supervision-host-readback.XXXXXX") || readback=
  if [ -n "$readback" ]; then
    FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" readback > "$readback" 2>/dev/null || : > "$readback"
  fi
  if ! printf '%s\n' "$reason" \
    | node "$SCRIPT_DIR/fm-branch-dispatch.mjs" wake-prompt --report "the bin/fm-branch-report.sh command" \
      --away ${readback:+--readback-file "$readback"} > "$WAKE_FILE" 2>/dev/null; then
    [ -z "$readback" ] || rm -f "$readback"
    rm -f "$TURN_FILE"
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    HANDLE_WHY="the wake prompt could not be rendered"
    return 1
  fi
  [ -z "$readback" ] || rm -f "$readback"
  if turn_crosses_boundary; then
    rm -f "$TURN_FILE"
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    boundary_exit
  fi
  result=$(mktemp "$STATE/.supervision-host-result.XXXXXX") || result=/dev/null
  errors=$(mktemp "$STATE/.supervision-host-errors.XXXXXX") || errors=/dev/null
  TURN_RESULT=$result
  TURN_ERRORS=$errors
  ENGINE_RUNNING=1
  # Backgrounded and waited, so a signal to the host is handled at once
  # instead of after the whole turn; the cleanup stops the engine.
  (
    export FM_HOME STATE
    [ -z "${FM_STATE_OVERRIDE:-}" ] || export FM_STATE_OVERRIDE
    [ -z "${FM_CONFIG_OVERRIDE:-}" ] || export FM_CONFIG_OVERRIDE
    export FM_SUPERVISION_ACTOR=branch
    FM_LEASE_HOLDER_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null | tr -cd '0-9')
    export FM_LEASE_HOLDER_PID
    export FM_SUPERVISION_PRIMARY_HARNESS="$PRIMARY"
    export FM_BRANCH_REPORT_TURN="$turn"
    fm_supervision_engine_turn "$FM_SUPERVISION_ENGINE" "$FM_SUPERVISION_ENGINE_MODEL" \
      "$PROMPT_FILE" "$WAKE_FILE" "$ENGINE_SESSION" "$ENGINE_MODE" "$TURN_TIMEOUT" \
      "$result" "$errors" "$ENGINE_PID_FILE"
  ) &
  ENGINE_SUBSHELL=$!
  wait "$ENGINE_SUBSHELL"
  rc=$?
  ENGINE_SUBSHELL=
  ENGINE_RUNNING=0
  release_branch_leases
  # shellcheck disable=SC2086 # rows is a space-separated list of sequence numbers.
  unacked=$(fm_wake_rows_queued $rows) || unacked=$rows
  unacked=$(printf '%s\n' "$unacked" | awk 'NF { printf "%s%s", sep, $1; sep = " " }')
  "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
  rm -f "$TURN_FILE"
  receipts=$(awk -F '\t' -v turn="$turn" '$1 == turn { n++ } END { print n + 0 }' "$RECEIPTS" 2>/dev/null)
  usage=$(fm_supervision_engine_result "$FM_SUPERVISION_ENGINE" "$result" "${ENGINE_COST:-0}" 2>/dev/null || true)
  [ "$result" = /dev/null ] || rm -f "$result"
  TURN_RESULT=
  if [ "$rc" -ne 0 ] || [ -z "$usage" ] || [ "${usage#error=0}" = "$usage" ]; then
    ENGINE_ERROR=1
  fi
  health_record "$ENGINE_ERROR" "${receipts:-0}"
  if [ "$ENGINE_ERROR" -eq 0 ] && [ "${receipts:-0}" -gt 0 ] && [ -z "$unacked" ]; then
    write_engine_record $((ENGINE_TURNS + 1)) "$(printf '%s\n' "$usage" | sed -n 's/.* conversation_cost=\([^ ]*\).*/\1/p')" \
      || rm -f "$ENGINE_RECORD"
    [ "$errors" = /dev/null ] || rm -f "$errors"
    TURN_ERRORS=
    log_line "handled	turn=$turn	rc=$rc	reports=$receipts	$usage	$first"
    return 0
  fi
  # A turn that did not handle its wake starts the next one on a new
  # conversation, so whatever went wrong in this one is not carried forward.
  rm -f "$ENGINE_RECORD"
  log_line "failed	turn=$turn	rc=$rc	reports=${receipts:-0}	unacked=${unacked:-none}	${usage:-no-result}	$(head -c 300 "$errors" 2>/dev/null | tr '\t\n' '  ')	$first"
  [ "$errors" = /dev/null ] || rm -f "$errors"
  TURN_ERRORS=
  if fm_timed_out "$rc"; then
    HANDLE_WHY="the engine turn hit its ${TURN_TIMEOUT}s bound"
  elif [ "$rc" -eq 127 ]; then
    HANDLE_WHY="the $FM_SUPERVISION_ENGINE engine could not run"
  elif [ "$rc" -ne 0 ]; then
    HANDLE_WHY="the engine turn failed (exit $rc)"
  elif [ "${usage#error=0}" = "$usage" ]; then
    HANDLE_WHY="the engine turn ended with an error or an incomplete result"
  elif [ "${receipts:-0}" -eq 0 ]; then
    HANDLE_WHY="the engine turn recorded no outcome for its wake"
  else
    HANDLE_WHY="the engine turn left its granted wake rows $unacked unacknowledged"
  fi
  return 1
}

# Ownership first: a host that does not own supervision leaves the owner's
# host, processes, arms, and leases alone.
if ! host_still_owner; then
  stand_down "this session does not own supervision"
fi
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
trap 'exit 130' INT
activate || { echo "supervision-host stood down: the host record could not be written"; exit 0; }
log_line "start	gen=$GEN	primary=$PRIMARY"

# The first cycle.
if [ "$FIRST_ARM_RESTART" -eq 1 ]; then
  start_arm "$OWNER_PREDECESSOR" --restart
else
  start_arm "$OWNER_PREDECESSOR"
fi || { echo "watcher: FAILED - the supervision host could not start a watcher cycle"; exit 1; }
ARM_PID=$STARTED_ARM_PID
ARM_OUT=$STARTED_ARM_OUT

while :; do
  boundary_reached && boundary_exit
  await_close || boundary_exit
  REASON=$(printf '%s\n' "$ARM_TEXT" | grep -E '^(signal:|stale:|check:|heartbeat($|:))' || true)

  # The away daemon owns triage while its flag exists; the owner stands down.
  # A close with no wake is the arm's own failure or attach result, which the
  # owner judges exactly as it judges the arm's. Exit status 0 in both: a
  # status above 128 tells the owner the host itself died.
  if [ -z "$REASON" ]; then
    log_line "pass-through	a close without a wake"
    emit
    exit 0
  fi
  if [ -e "$STATE/.afk" ]; then
    log_line "pass-through	the away daemon's flag exists	$(printf '%s\n' "$REASON" | head -n 1)"
    emit
    exit 0
  fi
  # Attended: every wake is main's, as without the host.
  if [ ! -f "$STATE/.afk-contract" ]; then
    log_line "pass-through	attended	$(printf '%s\n' "$REASON" | head -n 1)"
    emit
    exit 0
  fi
  if ! host_still_owner; then
    stand_down "this session no longer owns supervision"
  fi
  if ! fm_supervision_host_config "$CONFIG" "$PRIMARY"; then
    exit_to_main "the home no longer opts into the supervision host"
  fi
  if [ -z "$FM_SUPERVISION_ENGINE" ]; then
    exit_to_main "no supervision engine runs here: $FM_SUPERVISION_ENGINE_PROBLEM; this wake is yours"
  fi
  if ! command -v node >/dev/null 2>&1; then
    exit_to_main "node is required to compute branch eligibility; this wake is yours"
  fi
  if health_cooling; then
    exit_to_main "the away session is paused after repeated engine errors until $(fm_supervision_host_clock "$HEALTH_RETRY"); this wake is yours"
  fi

  # A turn that could outlive the boundary would outlive the hook registration.
  turn_crosses_boundary && boundary_exit
  if ! start_successor "$CLOSED_ARM_PID"; then
    exit_to_main "the successor watcher cycle could not be verified before handling; this wake is yours"
  fi
  if [ -n "$SUCCESSOR_GENERATION" ]; then
    if ! "$SCRIPT_DIR/fm-watch-arm.sh" --handling-delivered "$SUCCESSOR_GENERATION" --watcher-pid "$SUCCESSOR_WATCHER" >/dev/null 2>&1; then
      exit_to_main "the handling handoff to the successor watcher could not be confirmed; this wake is yours"
    fi
  fi

  # The captain returned during that turn: the return brief was rendered
  # before its outcomes existed, so main relays them now, handled or not.
  if ! handle_away "$REASON"; then
    if returned_during_turn; then
      exit_to_main "the away session could not take this wake: $HANDLE_WHY; this wake is yours, and the captain returned during its turn, so relay the outcomes it recorded (store rows $RETURNED_SEQS, listed next and in bin/fm-branch-outcome.sh list) to the captain" \
        "$(turn_outcome_lines "$LAST_TURN")${HEALTH_NOTE:+$'\n'$HEALTH_NOTE}"
    fi
    exit_to_main "the away session could not take this wake: $HANDLE_WHY; this wake is yours" "$HEALTH_NOTE"
  fi
  if returned_during_turn; then
    exit_to_main "the captain returned while the away session was handling this wake, which it finished after the return brief was rendered; relay its outcomes (store rows $RETURNED_SEQS, listed next and in bin/fm-branch-outcome.sh list) to the captain" \
      "$(turn_outcome_lines "$LAST_TURN")"
  fi

  # Handled: park on the successor.
  ARM_PID=$SUCCESSOR_PID
  ARM_OUT=$SUCCESSOR_OUT
  SUCCESSOR_PID=
  SUCCESSOR_OUT=
  ARM_TEXT=
done
