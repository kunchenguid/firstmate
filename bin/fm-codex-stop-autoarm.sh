#!/usr/bin/env bash
# Codex Stop-owned watcher auto-arm (async Stop hook).
#
# Registered in tracked .codex/hooks.json as a Stop command hook with
# "async": true and an explicit multi-hour timeout. Codex fires it in the
# background on EVERY Stop of a Codex primary session (verified live on
# codex-cli 0.159.0, docs/verification/supervision.md), with no deduplication
# across firings. It owns routine tokenless watcher continuity for Codex
# primaries (main home and marked secondmate homes) and is the Codex twin of
# bin/fm-claude-stop-autoarm.sh:
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session holds state/.lock, as
#     bin/fm-session-lock-lib.sh decides it (ancestry against the recorded
#     pid). A session a sandbox restricts so tightly that it cannot inspect
#     its own harness ancestry (for example macOS seatbelt builds that deny
#     ps) cannot prove ownership and stays inert by design; activation on such
#     a host needs a Codex launch mode whose hooks can run ps - this hook
#     never weakens the lock-ownership checks to accommodate a restricted
#     session. When an existing numeric owner fails the shared harness-liveness
#     predicate, the hook delegates guarded recovery to bin/fm-lock.sh and then
#     re-verifies ownership. A live owner, missing lock, malformed lock, or
#     unresolved ancestry remains inert, so a competing session never arms.
#   - Headless stand-down: a codex launcher argv carrying the standalone
#     `exec` subcommand token is a `codex exec` session. Codex awaits async
#     hooks before an exec process exits, so a park there would hold the whole
#     run hostage; such sessions stay inert and keep the model-driven
#     foreground-checkpoint path (docs/supervision-protocols/codex.md). The
#     token check reads the codex launcher's own argv and never inspects
#     ancestors above it, so a wrapper that launched Codex with `exec codex
#     ...` cannot stand an interactive session down; a missed detection is
#     still accepted because it only over-parks a headless run until its
#     timeout, never a wrong wake.
#   - AFK: while state/.afk exists the away daemon owns the watcher and
#     triage; this hook exits 0 and never wakes the primary (checked again at
#     close time so a mid-cycle AFK transition is honored).
#   - Need: arms only while the home needs supervision, as
#     bin/fm-supervision-lib.sh defines it; an idle home exits 0.
#   - Single-flight: Codex does not dedupe async hooks, so exactly one
#     GENERATION owner arms per event epoch, through the same epoch ledger
#     (state/.claude-autoarm-epoch) and fm_autoarm_claim_open/fm_autoarm_claim_next
#     contract bin/fm-wake-lib.sh owns; every firing defers (exit 0) to a live
#     open claim, and a stuck, dead, identity-mismatched, or finished claim is
#     superseded by taking the next generation instead of being unlocked or
#     revoked. No mutex is ever held across arming or delivery, and a
#     superseded owner goes completely silent: ownership is re-verified before
#     every arm invocation, episode-state mutation, ledger write, and
#     delivery.
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh as a tracked child it
#     waits on inside this hook-owned process tree (never a fire-and-forget
#     shell &). Codex reaps the hook process tree when the session exits
#     (verified live on codex-cli 0.159.0), so teardown kills arm and watcher
#     together exactly as Claude's does. HUP, TERM, and INT are translated
#     through the ordinary durable failure handoff; unlike Claude there is no
#     exit-2 delivery to lose, so the handler never delivers and always exits 0.
#   - Handling successor: after an actionable close, including an attached
#     peer cycle that ended, this hook starts one successor bin/fm-watch-arm.sh
#     with the closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID, detached
#     nohup-style so it survives this hook's exit and covers the handling
#     turn; the next Stop's foreground arm attaches to that live cycle.
#   - Supervision host: a home that runs it (config/supervision-host on a
#     Codex primary; docs/configuration.md "Supervision host" owns the gate
#     and its opt-out) runs bin/fm-supervision-host.sh in the arm's place,
#     bound to this generation, exactly as the Claude arm does; its
#     "supervision-host:" close lines are actionable here like wake lines.
#   - DELIVERY (the one Claude difference): Codex has no asyncRewake - an
#     async hook's exit 2 and stderr are never delivered as a rewake (verified
#     live on codex-cli 0.159.0). The actionable close is instead delivered as
#     a queued user turn: the winning generation commits its rewake outcome to
#     the epoch ledger first (the commit point), then runs
#     `codex queue --thread <session id> --message <envelope>`, where the
#     session id is the Stop payload's session_id and the message body is the
#     U+2063 FIRSTMATE_OP watcher envelope fm-operational-input.sh builds from
#     the same banner lines Claude delivers. `codex queue` wakes an idle
#     interactive session into a real handling turn (verified live); a message
#     queued mid-turn is delivered at the next turn boundary without loss; a
#     queue failure (session already exited, no shared app-server daemon,
#     codex absent) is non-fatal because the watcher's durable wake queue
#     retains the event and the next session or captain turn drains it. A
#     failed delivery immediately rewrites the same generation's owned ledger
#     outcome from rewake to plain failed (no notice marker), so the epoch
#     never claims a handling turn that is not under way: while the handling
#     successor is healthy the synchronous --codex guard allows through live
#     watcher health, and when the successor failed too the guard's bounded
#     block gives the model one recovery turn whose protocol step is draining
#     that durable event. This is the Codex shape of Claude's accepted
#     residual - a committed outcome whose delivery never reached the model -
#     where the durable idempotent wake queue is what keeps the event.
#     The synchronous --codex guard (bin/fm-turnend-guard.sh) reads the same
#     ledger, so a committed rewake lets the stop finish without a duplicate
#     continuation. FM_CODEX_QUEUE_BIN names the queue command and exists as a
#     test seam; it receives the thread id and the encoded envelope as its two
#     arguments, while the default invocation is
#     `codex queue --thread <id> --message <envelope>` resolved from PATH.
#
# The failure markers state/.claude-autoarm-failure-notified and
# state/.claude-autoarm-failure-alarmed are shared with the synchronous guard
# exactly as for Claude: one failure episode produces one notice, and after
# the guard consumes its attended fail-open this hook suppresses further
# deliveries until positive watcher recovery.
#
# In hook mode this script always exits 0 and prints nothing to stdout; the
# queued envelope is the only model-visible output. The Stop hook passes no
# arguments, so any argument means a manual run: -h or --help prints usage and
# an unknown argument is refused, both before anything is sourced, read, or
# armed.
set -u

usage() {
  cat <<'EOF'
Usage: fm-codex-stop-autoarm.sh

Codex Stop hook registered in .codex/hooks.json; not for manual use.
It reads the Stop payload on stdin and, in a primary home that needs
supervision, arms the watcher or supervision host for this session and
delivers an actionable close as a queued `codex queue` user turn.
Exit 0 is silent in every path.
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# fm-watch.sh touches the liveness beacon once per cycle, immediately before
# its terminal wait, so a healthy watcher's beacon can legitimately age up to
# FM_POLL seconds between touches (docs/turnend-guard.md "Guard grace and the
# poll cadence"). fm_poll_derived_grace (bin/fm-wake-lib.sh) is the single
# owner of that max(300, poll+60) derivation.
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe, and its
# session id and host are inspected before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)
SESSION_ID=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)
fi

# Cursor Agent CLI and pi-code load tracked Claude-shaped hook files but never
# this Codex registration; the stand-downs below keep a foreign host's
# Claude-shaped duplicate from doing Codex work. The signals are the PAYLOAD,
# not the environment (bin/fm-hook-host-lib.sh header owns why), and the
# fail direction is toward running: no payload, no jq, or no transcript_path
# means the hook RUNS.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi

# --- headless stand-down: codex exec sessions never park ---------------------
# `codex exec` awaits its async hooks before the process exits (verified live
# on codex-cli 0.159.0), so a parked arm would hold a headless run hostage for
# the whole hook timeout. Walk the hook's harness ancestry with ps, and when
# the codex launcher process is reached (the ancestor whose argv names the
# codex binary), stand down exactly when that launcher argv carries the
# standalone `exec` subcommand token. The walk never inspects ancestors above
# the launcher, so a login shell or wrapper that launched Codex with `exec
# codex ...` cannot stand an interactive session down. ps denial or a partial
# listing finds no launcher token and lets the hook run; such a session is
# held inert by the identity gate above instead, never by guessing here.
is_codex_launcher_args() {  # <ps args string>
  local - ; set -f
  # shellcheck disable=SC2086 # deliberate argv approximation from ps args
  set -- $1
  case "${1:-}" in
    *codex|*codex.js) return 0 ;;
    node)
      case "${2:-}" in
        *codex|*codex.js) return 0 ;;
      esac
      ;;
  esac
  return 1
}
session_is_headless_exec() {
  local pid args tok depth=0
  pid=$(ps -o ppid= -p "$$" 2>/dev/null | tr -d ' ')
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ] && [ "$depth" -lt 12 ]; do
    depth=$((depth + 1))
    args=$(ps -o args= -p "$pid" 2>/dev/null) || args=
    if is_codex_launcher_args "$args"; then
      for tok in $args; do
        [ "$tok" = exec ] && return 0
      done
      return 1
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}
session_is_headless_exec && exit 0

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never wake -----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: whatever bin/fm-supervision-lib.sh counts as supervision need ------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight generation claim --------------------------------------------
fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
fm_autoarm_claim_next "$STATE" "$GRACE"
CLAIM_RC=$?
if [ "$CLAIM_RC" -ne 0 ]; then
  [ "$CLAIM_RC" -eq 2 ] && exit 0
  ROLE=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  [ -n "$ROLE" ] || exit 0
  fm_autoarm_release_abandoned "$STATE" "$GRACE" || exit 0
  fm_autoarm_claim_next "$STATE" "$GRACE" || exit 0
fi
MY_GEN=$FM_AUTOARM_MY_GEN
[ -n "$MY_GEN" ] || exit 0

# Commit <outcome> (optionally with the once-per-episode notice marker) for
# this generation. Success means this generation's delivery WINS and the
# caller delivers the queued envelope. Markerless outcomes commit with the
# owned ledger write; a notice wins only when its following marker write
# succeeds in the same hold. Failure means refused or unverifiable: the caller
# goes silent (cleanup, exit 0).
autoarm_commit() {  # <outcome> [marker-file]
  local outcome=$1 marker=${2:-} session_pid recovery
  if [ "$outcome" = rewake ]; then
    fm_session_lock_owned_by_self "$STATE" || return 2
    session_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 2
    case "$FM_RECOVERY_MARKER_TOKEN" in
      pending:downtime:*|announced:downtime:*) recovery=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
      *) return 2 ;;
    esac
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker" "$session_pid" "$recovery"
  elif [ -n "$marker" ]; then
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker"
  else
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome"
  fi
}

# Best-effort ownership-checked record for silent paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1 || true
}

# A signal means the host is tearing this hook's tree down (session exit or
# hook timeout). There is no session left to deliver into, so unlike the
# Claude handler this never prints and never exits 2: it records the ordinary
# durable failure outcome - once per episode with its notice marker, so the
# next session's synchronous guard drives exactly one recovery turn - or the
# suppressed outcome once the episode's attended fail-open was consumed, and
# always exits 0.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_autoarm_signal() {
  trap - HUP TERM INT
  if [ -n "${ARM_PID:-}" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  if [ -e "$FAILURE_ALARM" ]; then
    autoarm_record failed-suppressed
    exit 0
  fi
  if [ ! -e "$FAILURE_NOTICE" ]; then
    autoarm_commit failed "$FAILURE_NOTICE" || autoarm_record failed
    exit 0
  fi
  autoarm_commit failed-suppressed || autoarm_record failed-suppressed
  exit 0
}

trap 'handle_autoarm_signal' HUP
trap 'handle_autoarm_signal' TERM
trap 'handle_autoarm_signal' INT

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

ARM_PID=
CLOSED_ARM_PID=
run_arm() {  # <output file, or empty for none>
  if [ -n "$1" ]; then
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >"$1" 2>&1 &
  else
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  wait "$ARM_PID" || true
  CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
}

SUCCESSOR_FAILURE=
start_handling_successor() {  # <closed-arm-pid>
  local out pid deadline budget line monitor_was_on=0
  budget=${FM_ARM_CONFIRM_TIMEOUT:-30}
  case "$budget" in ''|*[!0-9]*) budget=30 ;; esac
  if ! out=$(mktemp "$STATE/.codex-autoarm-successor.XXXXXX"); then
    SUCCESSOR_FAILURE='The handling successor did not confirm a live watcher (its output file could not be created); this handling turn runs uncovered until the next turn end re-arms.'
    return 1
  fi
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  FM_WATCH_PREDECESSOR_ARM_PID=$1 FM_GUARD_GRACE="$GRACE" \
    nohup "$SCRIPT_DIR/fm-watch-arm.sh" >"$out" 2>&1 </dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  deadline=$(( $(date +%s) + budget + 2 ))
  while :; do
    if grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null; then
      rm -f "$out" 2>/dev/null || true
      return 0
    fi
    grep -q '^watcher: FAILED' "$out" 2>/dev/null && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  line=$(grep '^watcher: FAILED' "$out" 2>/dev/null | head -n 1 || true)
  rm -f "$out" 2>/dev/null || true
  [ -z "$line" ] || line=" ($line)"
  SUCCESSOR_FAILURE="The handling successor pid=$pid did not confirm a live watcher$line; this handling turn runs uncovered until the next turn end re-arms."
  return 1
}

# Deliver one encoded envelope as a queued user turn in the session that
# fired this Stop. Best-effort by contract: any failure (codex absent, no
# shared app-server daemon, session already exited) returns nonzero while the
# watcher's durable wake queue retains the event.
deliver_wake() {  # <encoded-envelope>
  local encoded=$1
  [ -n "$SESSION_ID" ] || return 1
  if [ -n "${FM_CODEX_QUEUE_BIN:-}" ]; then
    # shellcheck disable=SC2086 # the seam may carry queue arguments
    fm_run_timed 30 $FM_CODEX_QUEUE_BIN "$SESSION_ID" "$encoded" >/dev/null 2>&1
  else
    fm_run_timed 30 codex queue --thread "$SESSION_ID" --message "$encoded" >/dev/null 2>&1
  fi
}

OUT=
ENCODED=
ACTIONABLE=0
HEALTHY=0
HOST_MODE=0
HOST_RC=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
# The home gate's owner decides (docs/configuration.md "Supervision host").
if fm_supervision_host_enabled "$CONFIG" codex; then
  HOST_MODE=1
  ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
fi
attempt=0
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  # A superseded owner must not start or attach another watcher or mutate any
  # watcher/wake state: re-verify generation ownership before every arm
  # invocation, first attempt and retries alike.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.codex-autoarm-output.XXXXXX") || OUT=
  if [ "$HOST_MODE" -eq 1 ]; then
    HOST_RC=0
    FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
      FM_SUPERVISION_HOST_PRIMARY=codex FM_GUARD_GRACE="$GRACE" \
      "$SCRIPT_DIR/fm-supervision-host.sh" park >"${OUT:-/dev/null}" 2>&1 || HOST_RC=$?
  else
    run_arm "$OUT"
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
  # every subsequent classification and handoff.
  if [ -e "$STATE/.afk" ]; then
    autoarm_record afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq "$ACTIONABLE_RE" "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break
  if [ "$HOST_MODE" -eq 1 ]; then
    if [ -n "$OUT" ] && grep -q '^supervision-host stood down:' "$OUT" 2>/dev/null; then
      autoarm_record clean
      rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    if [ "$HOST_RC" -gt 128 ] || [ -z "$OUT" ] || [ ! -s "$OUT" ]; then
      [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      OUT=
      continue
    fi
    [ "$HOST_RC" -eq 0 ] || break
  fi

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating within the shared grace window.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  autoarm_record clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  fm_autoarm_reset_owned "$STATE" "$MY_GEN"
  RESET_RC=$?
  if [ "$RESET_RC" -eq 0 ]; then
    autoarm_record clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if [ "$RESET_RC" -eq 2 ]; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if autoarm_commit failed-suppressed; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another delivery that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  autoarm_record failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  # Cheap early-out before composing the envelope; the real commit decision is
  # the owned terminal write below.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  # The host owns its own successors and stops its cycle before handing back.
  if [ "$HOST_MODE" -eq 0 ]; then
    start_handling_successor "$CLOSED_ARM_PID" || true
  fi
  BODY=$( {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    if [ "$HOST_MODE" -eq 1 ]; then
      [ -n "$OUT" ] && awk '/^supervision-host:/ { print; next } /^(signal:|stale:|check:|heartbeat)/ && shown++ < 8' "$OUT" 2>/dev/null
    else
      [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    fi
    if [ "$HOST_MODE" -eq 1 ] && [ -e "$STATE/.afk-contract" ] \
      && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
      printf 'This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.\n'
    fi
    [ -z "$SUCCESSOR_FAILURE" ] || printf '%s\n' "$SUCCESSOR_FAILURE"
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. The Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } )
  fm_operational_input_encode watcher "$BODY" ENCODED || {
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  }
  # The owned terminal write is the commit point; the queued delivery happens
  # only in a generation that won it. A failed delivery rewrites the epoch to
  # plain failed so it never claims a handling turn that is not under way:
  # the handling successor (started above) still covers the home when it is
  # healthy, and the durable wake queue retains the event either way.
  if autoarm_commit rewake; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    if ! deliver_wake "$ENCODED"; then
      fm_autoarm_write_owned "$STATE" "$MY_GEN" failed >/dev/null 2>&1 || true
    fi
    exit 0
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# Notify only once for this continuous failure episode; every later winning
# generation still delivers so Codex must continue into another Stop-owned
# retry without creating a repeated operator notice or manual-arm loop. The
# notice marker commits in the same owned critical section as the winning
# failed write, so a losing generation can neither consume nor deliver it.
if [ ! -e "$FAILURE_NOTICE" ]; then
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  BODY=$( {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat|supervision-host)' "$OUT" 2>/dev/null | head -8
    [ "$HOST_MODE" -eq 0 ] || printf 'The supervision host (docs/supervision-host.md) ran these cycles; its last one exited %s without a wake.\n' "$HOST_RC"
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } )
  fm_operational_input_encode watcher "$BODY" ENCODED || {
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  }
  if autoarm_commit failed "$FAILURE_NOTICE"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    deliver_wake "$ENCODED" || true
    exit 0
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi
if autoarm_commit failed-suppressed; then
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  SUPPRESSED_BODY=$(printf 'firstmate watcher auto-arm still failing; supervision stays broken. Investigate the automatic Stop hook and watcher startup before ending blind.')
  if fm_operational_input_encode watcher "$SUPPRESSED_BODY" SUPPRESSED_ENCODED; then
    deliver_wake "$SUPPRESSED_ENCODED" || true
  fi
  exit 0
fi
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 0
