#!/usr/bin/env bash
# fm-unattended-session.sh - the execution path from a queued trigger to a
# firstmate session start, and the durable record that makes such a session
# identifiable as unattended afterwards.
#
# THE GAP THIS CLOSES. The fleet can already enqueue a trigger with no session
# live: state/.wake-queue is a durable, lock-serialised, session-independent
# inbox and bin/fm-loop-actuate.sh's `arm` (like every other producer) appends to
# it from any process. Nothing then EXECUTES, because neither the watcher nor the
# away-mode daemon performs a fleet action, by design, and that design stays.
# This script is the missing arrow and nothing more: an OS timer runs `start`, it
# proves an unattended session is warranted, records that fact durably, and hands
# off to the existing launcher. It adds no watcher, no scheduler and no queue.
#
# AUTHORITY, under the captain's 2026-08-03 ruling. This grants EXECUTION without
# a live human-started session. It widens NOTHING about what may be approved once
# running: an unattended session inherits exactly the authority a captain-started
# session has, so hard rule 2 (no merge without the captain's explicit word),
# hard rule 3 (no teardown of unlanded work, no force, no discard), the ask-user
# authority contract and the destructive/irreversible/security-sensitive
# boundaries all stand unchanged. A session that cannot proceed under those rules
# PARKS; it never resolves a block by widening its own permission. Nothing here
# spawns, merges, tears down, pushes or edits a project.
#
# THE FOUR CONSTRAINTS THE RULING BINDS ON THIS IMPLEMENTATION, and where each
# one is enforced:
#   a. identifiable as unattended in its own records - `start` writes the pending
#      origin record and the append-only log below; `claim` binds it to the
#      session that actually started, so every later action is attributable.
#   b. respects the per-home session lock, read-only when refused - `claim` is
#      the ONLY write a started session makes here, and it refuses unless this
#      process runs inside the session that owns state/.lock. A lock-refused
#      unattended session therefore writes nothing at all; `session` still
#      REPORTS it as unattended, because reporting is a read.
#   c. never a second supervision cycle alongside a live one - `start` refuses on
#      a live lock holder, on a healthy watcher, on a live away supervisor, and
#      on a launch already in flight. Every one of those gates verifies a LIVE
#      PROCESS, away mode included: it reads the away daemon's own single-instance
#      lock and answers alive, dead, or could-not-observe, refusing on the first
#      and the third (see the away gate below for the captain's 2026-08-10
#      ruling). The launcher's own launch lock and already-running refusal remain
#      the second, independent owner of that boundary.
#   d. starting itself is not licence to invent work - `start` refuses outright
#      unless the durable queue already holds a record. It surveys nothing,
#      reads no backlog and chooses no task; the drained queue and work already
#      registered in this home are the whole of what the session it starts may
#      act on.
#
# Usage:
#   fm-unattended-session.sh start [--trigger <key>] [--entry <id>] [--dry-run]
#       Prove an unattended session is warranted, record it, and start it.
#       --trigger records which trigger is being answered (display only; the
#       queue itself remains the authority on what is due). --entry overrides
#       the configured launch entry. --dry-run runs every gate and writes and
#       launches nothing.
#
#   fm-unattended-session.sh claim
#       Bind the pending origin record to this session. Called by
#       bin/fm-session-start.sh on the locked path only. Requires
#       FM_SESSION_ORIGIN_ID in the environment and refuses unless this process
#       runs inside the session holding state/.lock.
#
#   fm-unattended-session.sh session
#       This session's origin verdict, for the session-start digest:
#       "session_origin=unattended claimed=yes|no origin_id=<id>", or
#       "session_origin=attended". Read-only, and safe on the read-only path.
#
#   fm-unattended-session.sh status
#       The origin record itself, or "origin=none".
#
#   fm-unattended-session.sh log
#       The append-only attribution log, oldest first.
#
# Exit status: 0 the command completed, 1 refused (one refuse_<token> line on
# stderr), 2 usage error. refuse_away_mode means an away supervisor was observed
# ALIVE; refuse_away_liveness_unknown means its liveness could not be determined
# and names what could not be read. A start that steps past an away supervisor
# observed DEAD prints one UNATTENDED_AWAY_SUPERVISOR_DEAD line and records an
# away-supervisor-dead line in the attribution log.
#
# Which entry the launcher starts: config/unattended-session (one line, a launch
# entry id), else state/.launch-last, else refuse. A harness is never guessed.
#
# Test seams, documented so the suite does not reach into internals:
#   FM_UNATTENDED_LAUNCH_CMD    the launcher path (default bin/fm-launch.sh)
#   FM_UNATTENDED_CLAIM_WINDOW  seconds a pending record stays claimable (900)
#   FM_SESSION_ORIGIN_ID        the origin id carried into the started session
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

ORIGIN_RECORD="$STATE/.session-origin"
ORIGIN_LOG="$STATE/unattended-sessions.log"
START_LOCK="$STATE/.unattended-start.lock"
CLAIM_WINDOW=${FM_UNATTENDED_CLAIM_WINDOW:-900}
case "$CLAIM_WINDOW" in ''|*[!0-9]*) CLAIM_WINDOW=900 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# The away supervisor's own lock helpers, so the away-mode gate below reads the
# daemon's liveness through the code that owns that lock's shape rather than a
# second copy of it. Sourcing this file enables errexit and nounset (its header
# says so); this script is written for `set -u` alone, so errexit is restored
# immediately, and FM_AFK_LOCK is repointed at this home's lock explicitly.
# shellcheck source=bin/fm-afk-start.sh
. "$SCRIPT_DIR/fm-afk-start.sh"
set +e
FM_AFK_LOCK="$STATE/.supervise-daemon.lock"

die_usage() { printf 'error: %s\n' "$1" >&2; exit 2; }
refuse() { printf '%s %s\n' "$1" "$2" >&2; exit 1; }

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# One field of the origin record, or empty. The record is a flat key=value file
# written only by this script, and every write below REPLACES it whole rather
# than appending: a second `state=` line would leave the record's meaning
# dependent on which one a reader happened to take.
origin_field() {  # <key>
  [ -f "$ORIGIN_RECORD" ] || return 0
  sed -n "s/^$1=//p" "$ORIGIN_RECORD" 2>/dev/null | head -1
}

# Replace the whole origin record atomically, so a killed writer leaves the
# previous record intact rather than a half-written one.
origin_write() {  # <state> <origin-id> <trigger> <declared> <entry> [<claimed>] [<harness-pid>]
  local tmp
  fm_state_ensure || return 1
  tmp="$ORIGIN_RECORD.tmp.$$"
  {
    printf 'origin=unattended\n'
    printf 'state=%s\n' "$1"
    printf 'origin_id=%s\n' "$2"
    printf 'trigger=%s\n' "$3"
    printf 'declared=%s\n' "$4"
    printf 'entry=%s\n' "$5"
    [ -z "${6:-}" ] || printf 'claimed=%s\n' "$6"
    [ -z "${7:-}" ] || printf 'harness_pid=%s\n' "$7"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$ORIGIN_RECORD" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Append one attribution line. Failing to record is a hard refusal on the start
# path: an unattended session whose start left no trace is exactly the
# unattributable action the ruling forbids.
append_log() {  # <event> <origin-id> <trigger> <detail> [<harness-pid>]
  fm_state_ensure || return 1
  printf '%s\t%s\torigin_id=%s\ttrigger=%s\tharness_pid=%s\tdetail=%s\n' \
    "$(now_iso)" "$1" "$2" "$3" "${5:--}" "$4" >> "$ORIGIN_LOG"
}

# --- gates -------------------------------------------------------------------

# Constraint (d). The durable queue is the ONLY thing that may start an
# unattended session. No backlog read, no project scan, no survey: with an empty
# queue there is nothing this session was woken for, and it must not go looking.
queue_record_count() {
  local count
  count=$(grep -c . "$STATE/.wake-queue" 2>/dev/null)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  printf '%s\n' "$count"
}

# Constraint (c), first owner: a live session in this home already owns
# supervision, so a second one must never be started beside it. The lock's holder
# must be a live VERIFIED HARNESS process - a stale lock naming a dead pid, or one
# naming a live process that is not a harness, is not a live session.
live_session_pid() {
  local pid
  pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_harness_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

# Constraint (c), second owner: a healthy watcher means a supervision cycle is
# already running for this home even if its session's lock has not been observed
# yet. fm_watcher_healthy is the PID-STRICT primitive - a live identity-matched
# watcher process with a fresh beacon - which is the right question here: this is
# the arm-layer question of whether to start another cycle, not the mid-turn
# model-aware one.
supervision_cycle_live() {
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME"
}

# Constraint (c), third owner: away mode. The captain ruled on 2026-08-10 that
# this gate reads the away supervisor's LIVENESS with three answers rather than
# the durable flag's presence with two. state/.afk is cleared only on the
# captain's return, so a supervisor that died days ago would otherwise refuse
# every later timer fire for as long as the flag persisted - disabling unattended
# execution in precisely the away scenario the feature exists for. The presence
# of the flag is never proof that anything is supervising.
#
# The three values are alive, dead and unknown, and unknown is never narrowed
# into either of the others (AGENTS.md section 1 rule 5). The concrete cost of
# collapsing unknown into dead is starting an unattended session beside a live
# away supervisor, which is the two-supervisor failure this gate exists to
# prevent; the cost of collapsing it into alive is the wedge above.
#
# Sets AWAY_VERDICT to alive|dead|unknown, AWAY_PID to the recorded pid (or
# "none"), and AWAY_REASON to what could not be determined when unknown.
AWAY_VERDICT=
AWAY_PID=
AWAY_REASON=
away_observe_supervisor() {
  local owner pid identity current
  AWAY_VERDICT=
  AWAY_PID=none
  AWAY_REASON=

  # Nothing holds the daemon's single-instance lock. That lock IS the daemon's
  # liveness record, so its absence is an observation, not a gap: no away
  # supervisor is running here.
  owner=$(daemon_lock_owner 2>/dev/null) || owner=""
  if [ -z "$owner" ]; then
    AWAY_VERDICT=dead
    return 0
  fi

  pid=$(cat "$owner/pid" 2>/dev/null || true)
  # A lock owner naming no readable numeric pid names no process to ask about.
  # Nothing here says alive and nothing says dead: could-not-observe.
  case "$pid" in
    ''|*[!0-9]*)
      AWAY_VERDICT=unknown
      AWAY_REASON="the away daemon lock $owner records no readable pid"
      return 0
      ;;
  esac
  AWAY_PID=$pid

  # The recorded pid is not running, so the daemon that took the lock is gone.
  if ! fm_pid_alive "$pid"; then
    AWAY_VERDICT=dead
    return 0
  fi

  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  # bin/fm-supervise-daemon.sh writes the identity immediately after acquiring
  # the lock, so an absent one means a daemon killed inside that window - a live
  # pid this gate cannot tie to the daemon. daemon_pid_matches would fall back to
  # a `ps -o command=` PATTERN MATCH here; that fallback is deliberately not used,
  # because a pattern occurring in a brief or in this caller's own command line
  # matches the wrong process. An absent identity is could-not-observe.
  if [ -z "$identity" ]; then
    AWAY_VERDICT=unknown
    AWAY_REASON="the away daemon lock $owner records no process identity for live pid $pid"
    return 0
  fi
  current=$(fm_pid_identity "$pid" 2>/dev/null) || current=""
  if [ -z "$current" ]; then
    AWAY_VERDICT=unknown
    AWAY_REASON="the process identity of live pid $pid could not be read"
    return 0
  fi
  if [ "$current" = "$identity" ]; then
    AWAY_VERDICT=alive
    return 0
  fi
  # The pid is alive but is a DIFFERENT process: fm_pid_identity combines the
  # boot-relative start time with the full command line, so a reused pid reads as
  # a mismatch and the daemon that took the lock is gone.
  AWAY_VERDICT=dead
}

# What a dead away supervisor is surfaced as, on stdout and in the attribution
# log. A silent allow would hide a crashed supervisor, so the daemon, its
# recorded pid, and the best available last-activity time all appear. When that
# time cannot be read, the line says so rather than omitting or inventing it.
away_dead_detail() {
  local owner mtime
  owner=$(daemon_lock_owner 2>/dev/null) || owner=""
  mtime=""
  [ -z "$owner" ] || mtime=$(fm_path_mtime "$owner" 2>/dev/null || true)
  case "$mtime" in
    ''|*[!0-9]*)
      printf 'daemon=bin/fm-supervise-daemon.sh pid=%s last_activity=unreadable\n' "$AWAY_PID"
      ;;
    *)
      printf 'daemon=bin/fm-supervise-daemon.sh pid=%s last_activity=%s (%ss ago)\n' \
        "$AWAY_PID" "$mtime" "$(( $(now_epoch) - mtime ))"
      ;;
  esac
}

# A pending record younger than the claim window means a launch is already in
# flight; starting a second one races it. An expired pending record is not a live
# launch and never blocks a later start.
pending_launch_in_flight() {
  local state declared age
  state=$(origin_field state)
  [ "$state" = pending ] || return 1
  declared=$(origin_field declared)
  case "$declared" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(now_epoch) - declared ))
  [ "$age" -lt "$CLAIM_WINDOW" ]
}

# A launch entry id is a single safe token: it is written into the flat
# key=value origin record and the tab-separated attribution log, so anything
# outside this charset would corrupt the records that make a session
# attributable.
entry_id_ok() {  # <candidate>
  [ -n "$1" ] || return 1
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The first field of a one-line entry file. Carriage returns are stripped: an
# operator file saved with CRLF line endings otherwise yields "claude\r", which
# the charset check above rejects while still counting as a populated value - so
# the operator would be told to name an entry in a file they already populated.
# This repo ships firstmate.bat and docs/windows-launcher.md, so a CRLF-authored
# config is a realistic input rather than a hypothetical one.
read_entry_file() {  # <path>
  local value=""
  [ -r "$1" ] || return 1
  IFS=$' \t\n' read -r value < "$1" || value=""
  printf '%s\n' "${value//$'\r'/}"
}

# The launch entry, never guessed. config/unattended-session first, then the
# launcher's own last-used entry, then refuse.
resolve_entry() {
  local entry=""
  entry=$(read_entry_file "$CONFIG/unattended-session") || entry=""
  [ -n "$entry" ] || entry=$(read_entry_file "$STATE/.launch-last") || entry=""
  entry_id_ok "$entry" || return 1
  printf '%s\n' "$entry"
}

# --- start -------------------------------------------------------------------

cmd_start() {
  local trigger="-" entry="" dry_run=false queued origin_id live_pid launcher out rc
  local away_dead_note=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trigger) [ "$#" -gt 1 ] || die_usage "--trigger requires a value"; trigger=$2; shift 2 ;;
      --entry) [ "$#" -gt 1 ] || die_usage "--entry requires a value"; entry=$2; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) die_usage "unknown option for start: $1" ;;
    esac
  done
  trigger=$(printf '%s' "$trigger" | tr '\t\r\n' '   ')
  [ -n "$trigger" ] || trigger="-"
  if [ -n "$entry" ]; then
    entry_id_ok "$entry" \
      || die_usage "--entry must be a launch entry id using only [A-Za-z0-9._-] characters"
  fi

  # (d) Work first: the cheapest gate, and the one that keeps a timer firing over
  # an idle home from ever starting anything.
  queued=$(queue_record_count)
  [ "$queued" -gt 0 ] \
    || refuse refuse_no_queued_work "the durable wake queue is empty; an unattended session starts only for work already queued, never to look for some"

  # (c) Away mode owns supervision through its own daemon while that daemon is
  # ALIVE. Observed alive refuses; observed dead allows and says so; could not
  # observe refuses under its own token, so the two refusals never read alike.
  if [ -e "$STATE/.afk" ]; then
    away_observe_supervisor
    case "$AWAY_VERDICT" in
      alive)
        refuse refuse_away_mode "away mode is active and its daemon owns supervision here (pid $AWAY_PID)"
        ;;
      unknown)
        refuse refuse_away_liveness_unknown "away mode is active and its daemon's liveness could not be determined: $AWAY_REASON"
        ;;
      *)
        away_dead_note=$(away_dead_detail)
        printf 'UNATTENDED_AWAY_SUPERVISOR_DEAD %s\n' "$away_dead_note"
        printf 'away mode is flagged here but its supervisor is not alive, so this start proceeds in its place\n'
        ;;
    esac
  fi

  # (c) A live session already owns this home.
  if live_pid=$(live_session_pid); then
    refuse refuse_session_live "a live firstmate session already holds this home's session lock (pid $live_pid)"
  fi

  # (c) A healthy watcher is a live supervision cycle even without an observed lock.
  if supervision_cycle_live; then
    refuse refuse_supervision_live "a healthy supervision cycle is already running in this home"
  fi

  if pending_launch_in_flight; then
    refuse refuse_launch_in_flight "an unattended session start is already in flight (origin $(origin_field origin_id))"
  fi

  if [ -z "$entry" ]; then
    entry=$(resolve_entry) \
      || refuse refuse_no_entry "no launch entry is configured; name one in $CONFIG/unattended-session (a harness is never guessed)"
  fi

  if [ "$dry_run" = true ]; then
    printf 'UNATTENDED_START dry-run=true entry=%s trigger=%s queued=%s\n' "$entry" "$trigger" "$queued"
    return 0
  fi

  fm_state_ensure \
    || refuse refuse_state_unwritable "cannot create the state directory $STATE"

  # The in-flight gate, the record write and the launch happen under one start
  # lock, so two timers firing together cannot both pass the gate and have the
  # loser's failed-launch record clobber the winner's pending one.
  fm_lock_try_acquire "$START_LOCK" \
    || refuse refuse_launch_in_flight "an unattended session start is already in flight (start lock held by pid ${FM_LOCK_HELD_PID:-unknown})"
  trap 'fm_lock_release "$START_LOCK"' EXIT

  if pending_launch_in_flight; then
    refuse refuse_launch_in_flight "an unattended session start is already in flight (origin $(origin_field origin_id))"
  fi

  # (a) The record is written BEFORE the launch, so a launch that dies mid-flight
  # is still attributable to an unattended start rather than vanishing.
  origin_id="u$(now_epoch)-$$"
  origin_write pending "$origin_id" "$trigger" "$(now_epoch)" "$entry" \
    || refuse refuse_state_unwritable "cannot write the session origin record $ORIGIN_RECORD"
  append_log declared "$origin_id" "$trigger" "entry=$entry queued=$queued" \
    || refuse refuse_state_unwritable "cannot append to the attribution log $ORIGIN_LOG"
  # A start that stepped past a dead away supervisor records that fact here, so
  # the crashed supervisor stays attributable after the session it allowed.
  [ -z "$away_dead_note" ] \
    || append_log away-supervisor-dead "$origin_id" "$trigger" "$away_dead_note" \
    || refuse refuse_state_unwritable "cannot append to the attribution log $ORIGIN_LOG"

  launcher=${FM_UNATTENDED_LAUNCH_CMD:-$SCRIPT_DIR/fm-launch.sh}
  [ -x "$launcher" ] \
    || refuse refuse_launcher_missing "the launcher $launcher is not executable"

  # The launcher owns every launch mechanic, including its own launch lock and
  # its refusal when a primary is already running here. FM_SESSION_ORIGIN_ID is
  # what lets the started session prove which record is its own.
  out=$(env FM_SESSION_ORIGIN_ID="$origin_id" FM_HOME="$FM_HOME" \
        "$launcher" --entry "$entry" --detach 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    origin_write failed "$origin_id" "$trigger" "$(origin_field declared)" "$entry" || true
    append_log launch-failed "$origin_id" "$trigger" "exit=$rc" || true
    printf '%s\n' "$out" >&2
    refuse refuse_launch_failed "the launcher refused to start a session (exit $rc)"
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  append_log launched "$origin_id" "$trigger" "entry=$entry" || true
  printf 'UNATTENDED_START origin_id=%s entry=%s trigger=%s queued=%s\n' \
    "$origin_id" "$entry" "$trigger" "$queued"
}

# --- claim -------------------------------------------------------------------

cmd_claim() {
  local env_id record_id state lock_pid declared age trigger entry
  env_id=${FM_SESSION_ORIGIN_ID:-}
  [ -n "$env_id" ] \
    || refuse refuse_not_unattended "this session carries no unattended origin id"

  record_id=$(origin_field origin_id)
  [ -n "$record_id" ] \
    || refuse refuse_no_record "no session origin record exists to claim"
  [ "$record_id" = "$env_id" ] \
    || refuse refuse_origin_mismatch "the origin record names $record_id, not this session's $env_id"

  state=$(origin_field state)
  case "$state" in
    claimed) printf 'UNATTENDED_CLAIM origin_id=%s state=claimed already=true\n' "$record_id"; return 0 ;;
    pending) : ;;
    *) refuse refuse_not_pending "the origin record is in state '$state', not pending" ;;
  esac

  declared=$(origin_field declared)
  case "$declared" in ''|*[!0-9]*) refuse refuse_no_record "the origin record has no readable declaration time" ;; esac
  age=$(( $(now_epoch) - declared ))
  [ "$age" -lt "$CLAIM_WINDOW" ] \
    || refuse refuse_claim_expired "the origin record is ${age}s old, past the ${CLAIM_WINDOW}s claim window"

  # (b) The whole of the read-only contract lives on this line. Claiming is a
  # write, so it happens only inside the session that verifiably owns this home's
  # lock. A lock-refused unattended session reaches here, is refused, and writes
  # nothing - while `session` below still reports it as unattended.
  fm_session_lock_owned_by_self "$STATE" \
    || refuse refuse_lock_not_owned "this session does not own the home's session lock; an unattended session that cannot verify lock ownership stays read-only"

  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  trigger=$(origin_field trigger)
  entry=$(origin_field entry)
  origin_write claimed "$record_id" "$trigger" "$declared" "$entry" "$(now_epoch)" "$lock_pid" \
    || refuse refuse_state_unwritable "cannot update the session origin record $ORIGIN_RECORD"
  append_log claimed "$record_id" "$trigger" "lock verified" "$lock_pid" || true
  printf 'UNATTENDED_CLAIM origin_id=%s state=claimed harness_pid=%s\n' "$record_id" "$lock_pid"
}

# --- session verdict ---------------------------------------------------------

# Read-only, and deliberately usable on the lock-refused path: a session that may
# write nothing must still be able to say what it is.
cmd_session() {
  local env_id record_id state harness_pid lock_pid
  env_id=${FM_SESSION_ORIGIN_ID:-}
  record_id=$(origin_field origin_id)
  state=$(origin_field state)

  if [ -n "$env_id" ]; then
    if [ "$record_id" = "$env_id" ] && [ "$state" = claimed ]; then
      printf 'session_origin=unattended claimed=yes origin_id=%s\n' "$env_id"
    else
      printf 'session_origin=unattended claimed=no origin_id=%s\n' "$env_id"
    fi
    return 0
  fi

  # No env id: an unattended session can still identify itself from the record it
  # already claimed, which is what keeps its later actions attributable after the
  # environment that started it is out of reach. The record must name THIS
  # session's lock, so a stale claimed record can never relabel a later
  # captain-started session.
  if [ "$state" = claimed ]; then
    harness_pid=$(origin_field harness_pid)
    lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
    if [ -n "$harness_pid" ] && [ "$harness_pid" = "$lock_pid" ] \
      && fm_session_lock_owned_by_self "$STATE"; then
      printf 'session_origin=unattended claimed=yes origin_id=%s\n' "$record_id"
      return 0
    fi
  fi
  printf 'session_origin=attended\n'
}

cmd_status() {
  if [ -f "$ORIGIN_RECORD" ]; then
    cat "$ORIGIN_RECORD"
  else
    printf 'origin=none\n'
  fi
}

cmd_log() {
  if [ -f "$ORIGIN_LOG" ]; then
    cat "$ORIGIN_LOG"
  else
    printf 'no unattended sessions recorded\n'
  fi
}

print_help() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-unattended-session.sh" | sed 's/^# \{0,1\}//; $d'
}

[ "$#" -ge 1 ] || { print_help >&2; exit 2; }
COMMAND=$1
shift
case "$COMMAND" in
  start) cmd_start "$@" ;;
  claim) cmd_claim "$@" ;;
  session) cmd_session "$@" ;;
  status) cmd_status "$@" ;;
  log) cmd_log "$@" ;;
  -h|--help|help) print_help ;;
  *) die_usage "unknown command: $COMMAND" ;;
esac
