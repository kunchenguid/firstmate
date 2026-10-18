#!/usr/bin/env bash
# fm-sentinel.sh - recovery that runs OUTSIDE the agent runtime.
#
# Every Firstmate watcher, Stop-hook arm, and away daemon runs inside the Herdr
# server's process tree, so when the server is killed (an out-of-memory kill of
# its service unit, for example) they all die with it. Herdr restarts and
# resumes the agent sessions it recorded, but nothing re-arms supervision: a
# Claude primary whose turn had ended sits at its prompt, leads and workers sit
# idle, and Herdr resumes each agent in its pane's creation folder, which for a
# freshly spawned worker is the PRIMARY checkout rather than its worktree. This
# script is the piece that must live in its own process (a systemd user service
# from `unit`), never inside Herdr.
#
# Usage (FM_HOME is required; the backend session defaults to Herdr's default):
#   FM_HOME=<home> fm-sentinel.sh tick       one pass; what a scheduler runs
#   FM_HOME=<home> fm-sentinel.sh loop       tick every FM_SENTINEL_INTERVAL seconds
#   FM_HOME=<home> fm-sentinel.sh reconcile  nudge or relaunch this home's direct reports, once per episode
#   FM_HOME=<home> fm-sentinel.sh unit       print a systemd user service running `loop`
#
# tick, under the home's state/.sentinel.lock:
#   1. Reads the Herdr server identity for FM_SENTINEL_HERDR_SESSION (default the
#      backend's own HERDR_SESSION, else `default`) as the inode and bind time of its API socket, which the server
#      recreates on every start. A stopped server is left alone: its supervisor
#      restarts it, and this script never starts one.
#   2. On the first identity it records it in state/.sentinel-herdr-identity.
#      On a changed identity it runs `reconcile`, leaves one pending restart
#      wake per identity in state/.sentinel-wake-pending (state/.sentinel-woken-for
#      keeps the identity it was left for), and records the new identity once no
#      lane is unsettled or 30 minutes have passed since the restart, logging any
#      lane still unsettled then; until that, every tick reconciles again.
#   3. Wakes the primary session when a restart wake is pending, or when
#      supervision is needed and the watcher beacon is older than the grace
#      (bin/fm-supervision-lib.sh owns that predicate). A beacon-only wake is
#      repeated at most once per FM_SENTINEL_REWAKE_SECS for one beacon age.
#      The primary is the Herdr pane whose agent session is state/.lock-session.
#      The wake is typed only when that pane reads not busy and its composer
#      reads exactly empty, as the away daemon's injection does, so it never
#      lands mid-turn or on top of the captain's typing; a deferred wake stays
#      pending for the next tick. The typed text is an operational-input
#      doorbell whose record says what happened; handling it is an ordinary
#      turn, and that turn's end re-arms supervision through the primary's own
#      re-arm owner (docs/watcher-continuity.md).
#
# reconcile, for each local direct report in state/*.meta on the watched Herdr
# session (bin/fm-session-start.sh also runs it detached at every locked
# startup, so each home resumes its own lanes):
#   - The restart epoch is the server's socket bind time, the second half of the
#     identity. A lane whose busy record (state/<id>.busy-state ts=) or spawn or
#     relaunch (spawn_gen=) is at or after it acted since the restart and gets
#     no nudge or order; its placement and exit corrections below still run. A
#     lane whose agent reads busy is mid-turn and is left alone.
#   - An agent state other than alive, dead, or missing is not settled yet (a
#     server still resuming its sessions): the lane is left for the next pass.
#   - A secondmate whose agent is alive gets one recovery order through
#     bin/fm-send.sh, telling it to run bin/fm-session-start.sh, which resumes
#     its own lanes, and end its turn so its supervision re-arms. A dead
#     secondmate is left to the watcher's secondmate liveness relaunch; a
#     remote one is skipped.
#   - A ship or scout whose current state (bin/fm-crew-state.sh) is not done or
#     failed is relaunched in its recorded worktree through bin/fm-control.sh,
#     with a note carrying its current status line, when its agent is dead,
#     missing, or alive outside that worktree. A dead lane that acted since the
#     restart is left alone, as is a dead lane whose state/<id>.exit epoch (the
#     last verified fm-control exit) is newer than its spawn_gen, and no lane is
#     relaunched while it is an open captain call (bin/fm-captain-hold.sh open
#     exits 0, or 2 when unreadable).
#     Alive inside the worktree, the lane is
#     properly waiting and left alone when crew state reads parked, paused, or
#     blocked or its status log's current line (fm-classify-lib.sh) is an open
#     needs-decision or blocked, a paused wait, or a captain hold; otherwise its
#     turn was lost and it gets one resume nudge through bin/fm-send.sh.
#   - A done or failed ship or scout alive outside its worktree is exited
#     through bin/fm-control.sh, so no worker stays live in a primary checkout.
#   Orders and nudges are sent once per lane state: state/<id>.restart-nudged
#   keeps the key (its busy record, spawn_gen, and status log length), and a
#   lane whose key still matches is not nudged again until it moves.
#   One line per task goes to stdout and state/.sentinel.log.
# A one-shot reconcile whose episode state/.sentinel-herdr-identity already
# records prints that it is reconciled and does nothing else. After a one-shot
# reconcile that returns success it records the episode under the same settle
# rule tick uses, so a later session start in that episode skips it.
#
# Knobs: FM_SENTINEL_HERDR_SESSION (HERDR_SESSION, else default), FM_SENTINEL_INTERVAL (60),
# FM_SENTINEL_REWAKE_SECS (1800), FM_GUARD_GRACE (300).
# FM_SENTINEL_DRY_RUN=1 with reconcile decides as usual and prints each line to
# stdout, but runs no fm-control action, takes no lock, and writes nothing to the
# home; it is refused for tick and loop.
# Exit: 0 after a pass (including deferred work), 1 when the pass hit an error
# it logged, 2 for usage or a missing FM_HOME.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '14,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  tick|loop|reconcile|unit) CMD=$1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ -n "${FM_HOME:-}" ] || { echo "fm-sentinel: FM_HOME must be set explicitly" >&2; exit 2; }
FM_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || { echo "fm-sentinel: FM_HOME is not a directory" >&2; exit 2; }
export FM_HOME
STATE="$FM_HOME/state"
SESSION=${FM_SENTINEL_HERDR_SESSION:-${HERDR_SESSION:-default}}
INTERVAL=${FM_SENTINEL_INTERVAL:-60}
REWAKE=${FM_SENTINEL_REWAKE_SECS:-1800}
GRACE=${FM_GUARD_GRACE:-300}
LOG="$STATE/.sentinel.log"
DRY_RUN=${FM_SENTINEL_DRY_RUN:-0}
case "$DRY_RUN" in 0|1) ;; *) echo "fm-sentinel: FM_SENTINEL_DRY_RUN must be 0 or 1" >&2; exit 2 ;; esac
[ "$DRY_RUN" = 0 ] || [ "$CMD" = reconcile ] || { echo "fm-sentinel: FM_SENTINEL_DRY_RUN applies only to reconcile" >&2; exit 2; }

if [ "$CMD" = unit ]; then
  unit_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    printf '"%s"' "$value"
  }
  cat <<EOF
[Unit]
Description=Firstmate sentinel for ${FM_HOME//%/%%} (recovers supervision after an agent-runtime restart)

[Service]
Environment=$(unit_quote "FM_HOME=$FM_HOME")
Environment=$(unit_quote "PATH=$PATH")
ExecStart=$(unit_quote "$SCRIPT_DIR/fm-sentinel.sh") loop
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
  exit 0
fi

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
fm_backend_source herdr || { echo "fm-sentinel: cannot load the Herdr adapter" >&2; exit 1; }

say() {
  printf '%s\n' "$*"
  [ "$DRY_RUN" = 1 ] && return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true
}

# Inode and bind time of the server's API socket; empty when it is not running.
herdr_identity() {
  local status sock
  status=$(fm_backend_herdr_cli "$SESSION" status --json 2>/dev/null) || return 0
  [ "$(printf '%s' "$status" | jq -r '.server.running // false' 2>/dev/null)" = true ] || return 0
  sock=$(printf '%s' "$status" | jq -r '.server.socket // empty' 2>/dev/null)
  [ -S "$sock" ] || return 0
  # shellcheck disable=SC2012 # the socket path is Herdr's own, and ls -i is the portable inode read.
  printf '%s:%s\n' "$(ls -di "$sock" | awk '{print $1}')" "$(fm_path_mtime "$sock")"
}

# Run one recovery action, logging its outcome; a failure sets RECONCILE_RC.
act() {  # <task-id> <done-message> <command...>
  local id=$1 done=$2 out
  shift 2
  if [ "$DRY_RUN" = 1 ]; then
    say "$id: dry run, no action: $done"
    return 0
  fi
  if out=$("$@" 2>&1); then
    say "$id: $done"
  else
    say "$id: FAILED ($done): $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    RECONCILE_RC=1
    return 1
  fi
}

delivery_id() {
  printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16
}

# Epoch of a lane's latest spawn or relaunch, from its spawn_gen; 0 when absent.
lane_spawn_epoch() {  # <meta>
  local spawn
  spawn=$(fm_meta_get "$1" spawn_gen)
  spawn=${spawn#s}
  spawn=${spawn%%.*}
  case "$spawn" in ''|*[!0-9]*) spawn=0 ;; esac
  printf '%s\n' "$spawn"
}

# Newest epoch a lane is recorded acting at: its busy record or its spawn.
lane_acted_at() {  # <id> <meta>
  local ts spawn
  ts=$(sed -n 's/.* ts=\([0-9][0-9]*\).*/\1/p' "$STATE/$1.busy-state" 2>/dev/null | head -n 1)
  spawn=$(lane_spawn_epoch "$2")
  [ "${ts:-0}" -gt "$spawn" ] && spawn=$ts
  printf '%s\n' "$spawn"
}

# Epoch fm-control exit recorded for a lane's last verified stop; 0 when none.
lane_exited_at() {  # <id>
  local ts
  ts=$(head -n 1 "$STATE/$1.exit" 2>/dev/null)
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  printf '%s\n' "$ts"
}

# Why a lane idle in its worktree is properly waiting; fails for a lost turn.
lane_waiting() {  # <id> <kind> <crew-state>
  local verb
  case "$3" in parked|paused|blocked) printf '%s' "crew state $3"; return 0 ;; esac
  status_line_verb "$(status_current_line "$STATE/$1.status" "$2")" verb
  case "$verb" in
    needs-decision|blocked|paused|captain-held) printf '%s' "status $verb" ;;
    *) return 1 ;;
  esac
}

# Send <text> once per lane state, keyed in state/<id>.restart-nudged; the key
# is also a secondmate order's delivery id (fm-send takes one only for those).
nudge_once() {  # <id> <meta> <done-message> <text>
  local rec="$STATE/$1.restart-nudged" key ff=()
  key=$(delivery_id "$(cat "$STATE/$1.busy-state" 2>/dev/null)|$(fm_meta_get "$2" spawn_gen)|$(wc -l <"$STATE/$1.status" 2>/dev/null)")
  if [ "$(cat "$rec" 2>/dev/null)" = "$key" ]; then
    say "$1: already nudged in this state; left alone"
    return 0
  fi
  [ "$(fm_meta_get "$2" kind)" != secondmate ] || ff=(--fire-and-forget "$key")
  act "$1" "$3" "$SCRIPT_DIR/fm-send.sh" "$1" ${ff[@]+"${ff[@]}"} "$4" || return 1
  [ "$DRY_RUN" = 1 ] || printf '%s\n' "$key" >"$rec"
}

# Whether <id> is an open captain call, which no automatic relaunch may touch.
# Exit 1 (not open, or absent from the backlog) lets the lane through; exit 0
# (open) and exit 2 (cannot tell) hold it, so an unreadable hold fails closed.
captain_held() {  # <id>
  local rc=0
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 1 ] || return 1
  if [ "$rc" -eq 0 ]; then
    say "$1: captain hold open; left alone"
  else
    say "$1: captain hold unreadable (exit $rc); left alone"
  fi
  return 0
}

reconcile() {  # <episode>
  local restarted=${1##*:} meta id kind target agent cwd wt current note why acted
  RECONCILE_RC=0
  RECONCILE_UNSETTLED=
  case "$restarted" in ''|*[!0-9]*) say "no Herdr server identity for $SESSION; nothing to reconcile"; return 0 ;; esac
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$(fm_backend_of_meta "$meta")" = herdr ] || continue
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || { say "$id: skipped (remote)"; continue; }
    kind=$(fm_meta_get "$meta" kind)
    case "$kind" in ship|scout|secondmate) ;; *) continue ;; esac
    target=$(fm_backend_target_of_meta "$meta")
    [ "${target%%:*}" = "$SESSION" ] || continue
    acted=0
    [ "$(lane_acted_at "$id" "$meta")" -lt "$restarted" ] || acted=1
    agent=$(fm_backend_agent_state herdr "$target" "$meta" "$id" 2>/dev/null)
    case "$agent" in
      alive|dead|missing) ;;
      *) say "$id: agent ${agent:-unreadable}; not settled, left for the next pass"; RECONCILE_UNSETTLED="$RECONCILE_UNSETTLED $id"; continue ;;
    esac
    if [ "$agent" = alive ] && [ "$(fm_backend_busy_state herdr "$target")" = busy ]; then
      say "$id: mid-turn; left alone"
      continue
    fi
    if [ "$agent" != alive ] && [ "$(lane_exited_at "$id")" -gt "$(lane_spawn_epoch "$meta")" ]; then
      say "$id: stopped on purpose; left alone"
      continue
    fi
    if [ "$kind" = secondmate ]; then
      if [ "$agent" != alive ]; then
        say "$id: secondmate agent $agent; left to the watcher's secondmate liveness relaunch"
        continue
      fi
      [ "$acted" -eq 0 ] || { say "$id: acted since the restart; left alone"; continue; }
      nudge_once "$id" "$meta" "ordered to recover" \
        "The host session restarted, so your last turn was lost and your supervision stopped. Run bin/fm-session-start.sh, which resumes your own home's lanes, then reconcile what remains and end the turn so your supervision re-arms."
      continue
    fi
    current=$(FM_CREW_STATE_NO_FORGE=1 "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | awk '{print $2}')
    note="The host session restarted and stopped this task's agent; this relaunch put it back in its recorded worktree. Your last recorded status: $(status_current_line "$STATE/$id.status" "$kind" | cut -c1-300). Continue the brief you are already on from the local copy as it stands; this is not new work."
    wt=$(fm_canonical_existing_dir "$(fm_meta_get "$meta" worktree)")
    cwd=
    if [ "$agent" = alive ]; then
      cwd=$(fm_canonical_existing_dir "$(fm_backend_herdr_current_path "$target")")
    fi
    if [ -z "$wt" ]; then
      case "$agent:$current" in
        alive:done|alive:failed)
          act "$id" "$current, was live in ${cwd:-an unreadable folder}; exited" "$SCRIPT_DIR/fm-control.sh" "$id" exit
          ;;
        *)
          say "$id: worktree missing; skipped"
          RECONCILE_RC=1
          ;;
      esac
      continue
    fi
    case "$agent:$current" in
      alive:done|alive:failed)
        case "$cwd/" in
          "$wt"/*) say "$id: $current, in its worktree; left alone" ;;
          *) act "$id" "$current, was live in ${cwd:-an unreadable folder}; exited" \
               "$SCRIPT_DIR/fm-control.sh" "$id" exit ;;
        esac
        ;;
      *:done|*:failed) say "$id: $current, agent $agent; left alone" ;;
      alive:*)
        case "$cwd/" in
          "$wt"/*)
            if [ "$acted" -eq 1 ]; then
              say "$id: acted since the restart; left alone"
            elif why=$(lane_waiting "$id" "$kind" "$current"); then
              say "$id: properly waiting ($why); left alone"
            else
              nudge_once "$id" "$meta" "idle with its turn lost; nudged" \
                "The host session restarted, so your last turn was lost. Continue the brief you are already on from its durable records: your status log, your worktree, and your steering inbox. This is not new work and the task is unchanged."
            fi
            ;;
          *)
            captain_held "$id" && continue
            act "$id" "was live in ${cwd:-an unreadable folder}; relaunched in $wt" \
              "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note "$note"
            ;;
        esac
        ;;
      *)
        captain_held "$id" && continue
        [ "$acted" -eq 0 ] || { say "$id: acted since the restart; left alone"; continue; }
        act "$id" "agent $agent; relaunched in $wt" \
          "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note "$note"
        ;;
    esac
  done
  return "$RECONCILE_RC"
}

# The Herdr pane whose agent session is this home's locked primary session.
primary_target() {
  local sid panes
  sid=$(head -n 1 "$STATE/.lock-session" 2>/dev/null)
  [ -n "$sid" ] || return 1
  panes=$(fm_backend_herdr_cli "$SESSION" api snapshot 2>/dev/null \
    | jq -r --arg sid "$sid" '.result.snapshot.agents[]? | select(.agent_session.value == $sid) | .pane_id' 2>/dev/null)
  [ -n "$panes" ] && [ "$(printf '%s\n' "$panes" | wc -l)" -eq 1 ] || return 1
  printf '%s:%s\n' "$SESSION" "$panes"
}

wake_primary() {  # <body>
  local target doorbell verdict rec
  target=$(primary_target) || { say "primary: no single Herdr pane runs session $(head -n 1 "$STATE/.lock-session" 2>/dev/null); wake deferred"; return 1; }
  [ "$(fm_backend_busy_state herdr "$target")" != busy ] || { say "primary: $target mid-turn; wake deferred"; return 1; }
  [ "$(fm_backend_composer_state herdr "$target")" = empty ] || { say "primary: $target composer not empty; wake deferred"; return 1; }
  fm_operational_record_write "$STATE" watcher "$1" doorbell || { say "primary: could not write the wake record"; return 1; }
  verdict=$(fm_backend_send_text_submit herdr "$target" "$doorbell" 3 0.5 0.5 2>/dev/null)
  if [ "$verdict" != empty ]; then
    if fm_operational_doorbell_path "$doorbell" rec 2>/dev/null; then rm -f "$rec"; fi
    say "primary: wake typed into $target but not confirmed ($verdict)"; return 1;
  fi
  say "primary: woke $target"
}

# Record <episode> as reconciled once the pass left no lane unsettled, or 30
# minutes after the restart; until then the next pass reconciles again.
settle_episode() {  # <episode>
  [ "$DRY_RUN" = 0 ] || return 0
  if [ -z "$RECONCILE_UNSETTLED" ] || [ $(( $(date +%s) - ${1##*:} )) -ge 1800 ]; then
    [ -z "$RECONCILE_UNSETTLED" ] || say "still not settled 30 minutes after the restart; left to the primary:$RECONCILE_UNSETTLED"
    printf '%s\n' "$1" >"$STATE/.sentinel-herdr-identity"
  fi
}

# The one-shot reconcile: skipped for an episode already recorded as reconciled.
reconcile_episode() {  # <episode>
  local rc=0
  if [ -n "$1" ] && [ "$(cat "$STATE/.sentinel-herdr-identity" 2>/dev/null)" = "$1" ]; then
    say "herdr episode $1 already reconciled; nothing to do"
    return 0
  fi
  reconcile "$1" || rc=$?
  [ "$rc" -ne 0 ] || [ -z "$1" ] || settle_episode "$1"
  return "$rc"
}

tick() {
  local id prev beat woken_beat age last body rc=0
  id=$(herdr_identity)
  [ -n "$id" ] || return 0
  prev=$(cat "$STATE/.sentinel-herdr-identity" 2>/dev/null)
  if [ "$prev" != "$id" ]; then
    if [ -n "$prev" ]; then
      say "herdr session $SESSION restarted (socket $prev -> $id)"
      if reconcile "$id"; then
        [ "$(cat "$STATE/.sentinel-woken-for" 2>/dev/null)" = "$id" ] || {
          printf '%s\n' "$id" >"$STATE/.sentinel-woken-for"
          printf '%s\n' "The Herdr server restarted at $(date -u +%Y-%m-%dT%H:%M:%SZ), which stopped every agent and watcher in it. The sentinel already reconciled this home's direct reports; its lines are in $LOG. Run bin/fm-session-start.sh if this session was resumed, reconcile what remains, then end the turn so supervision re-arms." \
          >"$STATE/.sentinel-wake-pending"
        }
        settle_episode "$id"
      else
        rc=1
      fi
    else
      printf '%s\n' "$id" >"$STATE/.sentinel-herdr-identity"
    fi
  fi
  if [ -f "$STATE/.sentinel-wake-pending" ]; then
    wake_primary "$(cat "$STATE/.sentinel-wake-pending")" && rm -f "$STATE/.sentinel-wake-pending"
    return "$rc"
  fi
  fm_supervision_unhealthy "$STATE" "$GRACE" || return "$rc"
  beat=$(fm_path_mtime "$STATE/.last-watcher-beat")
  read -r last woken_beat <"$STATE/.sentinel-wake-last" 2>/dev/null || true
  age=$(( $(date +%s) - ${last:-0} ))
  [ "${woken_beat:-}" != "${beat:-none}" ] || [ "$age" -ge "$REWAKE" ] || return "$rc"
  body="Supervision is needed but the watcher beacon is $FM_SUP_BEACON_DESC old and no turn is running, so nothing is watching the fleet. Run bin/fm-session-start.sh if this session was resumed, reconcile, then end the turn so supervision re-arms."
  wake_primary "$body" && printf '%s %s\n' "$(date +%s)" "${beat:-none}" >"$STATE/.sentinel-wake-last"
  return "$rc"
}

locked() {
  local lock="$STATE/.sentinel.lock" rc=0
  if [ "$DRY_RUN" = 1 ]; then "$@"; return $?; fi
  fm_lock_try_acquire "$lock" || return 0
  "$@" || rc=$?
  fm_lock_release "$lock"
  if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 1000 ]; then
    tail -n 500 "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
  fi
  return "$rc"
}

case "$CMD" in
  tick) locked tick ;;
  reconcile) locked reconcile_episode "${FM_SENTINEL_EPISODE:-$(herdr_identity)}" ;;
  loop)
    while :; do
      locked tick || true
      sleep "$INTERVAL"
    done
    ;;
esac
