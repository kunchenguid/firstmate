#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session holds state/.lock, as
#     bin/fm-session-lock-lib.sh decides it: the recorded pid is a harness
#     ancestor, or a live lock was recorded under this same trusted Claude
#     session id (which is what keeps a background session arming after its
#     transient helper chain is recycled).
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while the home needs supervision, as
#     bin/fm-supervision-lib.sh defines it; an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so exactly one
#     GENERATION owner arms per event epoch: the epoch ledger's monotonic
#     sequence is the claim generation, every firing defers (exit 0) to a live
#     open claim, and a stuck, dead, identity-mismatched, or finished claim is
#     superseded by taking the next generation instead of being unlocked or
#     revoked. No mutex is ever held across arming or output - the owner lock
#     survives only as the micro-mutex serializing individual ledger writes -
#     and a superseded owner goes completely silent: ownership is re-verified
#     before every arm invocation, episode-state mutation, ledger write, and
#     continuation (fm_autoarm_claim_open/fm_autoarm_claim_next in
#     bin/fm-wake-lib.sh own the contract, including the legacy shim for a
#     pre-generation lock).
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh as a tracked child it
#     waits on inside this hook-owned process tree (never a fire-and-forget
#     shell &); Claude owns the process group, so its timeout/session teardown
#     kills arm and watcher together, and the hook TERMs the arm with itself.
#     HUP, TERM, and INT are translated through the ordinary durable failure
#     handoff instead of leaving the generation frozen at arming. Claude does
#     not deliver the exit 2 of a hook it terminated at the configured timeout
#     as a rewake (measured on Claude Code 2.1.278 and 2.1.281,
#     docs/verification/supervision.md), so a park that outlives that timeout
#     records the failure durably without waking an idle primary; nothing here
#     shortens a quiet park, because no-change heartbeats are absorbed without
#     closing the arm.
#   - Handling successor: Pi, omp, and OpenCode start the next arm before they
#     deliver an actionable wake, so the fleet stays covered while the model
#     handles it. After an actionable close, including an attached peer cycle
#     that ended, this hook starts one successor bin/fm-watch-arm.sh with the
#     closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID, the same handoff the
#     Pi extension passes for its closed arm child, so the arm starts a
#     handling-successor watcher and links the lifecycle ledger. A child of
#     this hook cannot outlive the exit-2 rewake, so the successor is launched
#     the one way a process survives a Claude hook: nohup, stdio detached, in
#     its own process group (the shape bin/fm-startup-network.sh uses;
#     docs/verification/supervision.md records the survival check). The hook
#     waits for the successor's one status line, adds one banner line when no
#     live watcher was confirmed, and never withholds the wake for it; the
#     next Stop's foreground arm attaches to that live cycle. The supervision
#     host owns its own successors, so its path is unchanged.
#   - Supervision host: a home that runs it (by default on this Claude
#     primary; docs/configuration.md "Supervision host" owns the gate and its
#     opt-out) runs bin/fm-supervision-host.sh in the arm's place, bound
#     to this generation.
#     To this hook it is an arm that also takes away-posture wakes itself and
#     ends its own park before the hook timeout with a "supervision-host:"
#     line, which is actionable here like a wake line; its rewake banner
#     carries every "supervision-host:" line the host printed, in order, while
#     its wake lines keep the arm's eight-line cap. A "supervision-host stood
#     down:" close exits 0 silently, and a host that died without a close is
#     retried instead of being judged by the healthy-watcher predicate
#     (docs/supervision-host.md). On a home that opted out nothing below
#     changes.
#   - Pre-drained wake and turn-end acknowledgement (docs/watcher-continuity.md
#     "Pre-drained wakes and the turn-end acknowledgement"): before it commits
#     a rewake, the owner runs main's drain itself as a staged presentation
#     (bin/fm-wake-drain.sh --stage), which commits nothing a later drain would
#     not present again. After the rewake commit it begins handling the
#     recovery episode, records the acknowledgement the drain would have asked
#     main to run (bin/fm-wake-ack.sh record), and puts the bounded
#     presentation into the banner: at most FM_CLAUDE_AUTOARM_PRESENT_BYTES
#     (default 12000) of lines each cut at FM_CLAUDE_AUTOARM_PRESENT_LINE
#     (default 400) characters, with a cut note naming the plain drain as the
#     full view. At the next Stop of the same session - the end of the handling
#     turn - this hook runs that acknowledgement (bin/fm-wake-ack.sh commit)
#     before it arms, unless main held the wake open or a prompt voided the
#     record. A staging failure of any kind falls back to today's banner, which
#     asks main to drain and acknowledge itself.
#   - Empty plumbing closes (lever D of the main wake-cost report): a close
#     whose only actionable lines are "check: rearm-resurface" or "check:
#     inactive-outcome", whose staged presentation printed nothing at all, and
#     that arrives while this hook still has FM_CLAUDE_AUTOARM_SUPPRESS_MIN
#     seconds (default 1800) of its registered FM_CLAUDE_AUTOARM_HOOK_TIMEOUT
#     (default 28800, the tracked .claude/settings.json timeout) left is
#     acknowledged by this hook and absorbed: the cycle re-arms in this same
#     process, bounded to the remaining budget, and main is not woken. A host
#     re-park ends at that bound with its cycle boundary; a watcher re-arm still
#     open at it is TERMed and delivered as a "check: hook-budget" wake. Any other close - a signal, a decision, a check with rows, a host
#     line, a heartbeat - is delivered unchanged. The host's cycle boundary is
#     delivered too, because it exists to end this hook before its timeout.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). The irrevocable commit point is the EXIT STATUS:
#     the harness delivers the collected stderr only on exit 2, so an owned
#     terminal commit decides the exit. Markerless outcomes commit with the
#     ledger write; the failure notice additionally requires its marker write.
#     A refused generation exits 0 silently even after printing. A close that
#     reports no actionable reason is benign when a live identity-matched
#     watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim
# generation and outcome, and binds rewake outcomes to the session-lock pid and
# watcher recovery generation, so the synchronous Stop guard
# (bin/fm-turnend-guard.sh --claude) can allow a stop whose recovery this hook
# already owns, instead of forcing a duplicate continuation for the same event
# epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# In hook mode it never blocks the Stop decision itself or prints to stdout:
# exit 0 is silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
#
# The Stop hook passes no arguments, so any argument means a manual run: -h or
# --help prints usage and an unknown argument is refused, both before anything
# is sourced, read, or armed. A park started from a model's tool call would be
# owned by that short-lived process and leave supervision down once it exits.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claude-stop-autoarm.sh

Claude Stop hook registered in .claude/settings.json; not for manual use.
It reads the Stop payload on stdin and, in a primary home that needs
supervision, arms the watcher or supervision host for this session.
Exit 0 is silent; exit 2 carries a rewake banner on stderr.
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
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

HOOK_START=$(date +%s)
HOOK_TIMEOUT=${FM_CLAUDE_AUTOARM_HOOK_TIMEOUT:-28800}
case "$HOOK_TIMEOUT" in ''|*[!0-9]*|0) HOOK_TIMEOUT=28800 ;; esac
SUPPRESS_MIN=${FM_CLAUDE_AUTOARM_SUPPRESS_MIN:-1800}
case "$SUPPRESS_MIN" in ''|*[!0-9]*) SUPPRESS_MIN=1800 ;; esac
PRESENT_BYTES=${FM_CLAUDE_AUTOARM_PRESENT_BYTES:-12000}
case "$PRESENT_BYTES" in ''|*[!0-9]*|0) PRESENT_BYTES=12000 ;; esac
PRESENT_LINE=${FM_CLAUDE_AUTOARM_PRESENT_LINE:-400}
case "$PRESENT_LINE" in ''|*[!0-9]*|0) PRESENT_LINE=400 ;; esac
SUPPRESS_MAX=100
SUPPRESSED=0

# fm-watch.sh touches the liveness beacon once per cycle, immediately before
# its terminal wait, so a healthy watcher's beacon can legitimately age up to
# FM_POLL seconds between touches (docs/turnend-guard.md "Guard grace and the
# poll cadence"). fm_poll_derived_grace (bin/fm-wake-lib.sh) is the single
# owner of that max(300, poll+60) derivation.
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe, and its host
# is inspected before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too. Cursor has no asyncRewake, so if
# a future Cursor build starts firing the Claude-shaped Stop entry, this arm
# would run SYNCHRONOUSLY inside Cursor's stop step and hold that turn open for
# the declared multi-hour timeout - the exact wedge grok 1.0.0 produced
# (docs/turnend-guard.md "Harness integrations"). Cursor's own park adapter owns
# its turn boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# pi-code (Pi's Claude-hook compatibility extension) also loads the tracked
# Claude settings and has no asyncRewake, so it awaits every Stop hook and this
# arm would run SYNCHRONOUSLY inside Pi's turn end, holding that turn open for
# the declared multi-hour timeout - the same wedge as Cursor above (issue
# #3343). Pi's own native extensions own Pi supervision, so stand down on a
# pi-code-delivered payload. The signal is again the PAYLOAD, not the
# environment: pi-code stamps every hook payload's transcript_path with Pi's
# own session file under .pi/, which a Claude transcript path never contains.
# Fail direction matches the guard above: no payload, no jq, or no
# transcript_path means the hook RUNS.
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi

# The payload's session id binds a pending acknowledgement to this session;
# empty when the payload or jq is missing, and then the session-lock pid alone
# does the binding (bin/fm-wake-ack.sh header).
SESSION_ID=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)
  case "$SESSION_ID" in *[!A-Za-z0-9._:-]*) SESSION_ID= ;; esac
fi
SESSION_ID_ARGS=()
[ -z "$SESSION_ID" ] || SESSION_ID_ARGS=(--session-id "$SESSION_ID")

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its harness identity in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case; it
# resolves a tagged identity too, so a dead Windows session is still recoverable
# rather than being read as a malformed lock nobody may ever clear.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$LOCK_PID" || exit 0
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- turn-end acknowledgement of a pre-drained wake --------------------------
# This Stop ends the turn that handled the wake the previous rewake delivered
# pre-drained, so run its recorded acknowledgement before anything else
# (bin/fm-wake-ack.sh owns the record, the hold, and the session binding). It
# runs before the AFK and need gates because the wake was already main's; a
# home with no pending record pays one file test.
if [ "$RECOVER_SESSION_LOCK" -eq 0 ] && [ -e "$STATE/.wake-ack-pending" ] && [ -x "$SCRIPT_DIR/fm-wake-ack.sh" ]; then
  "$SCRIPT_DIR/fm-wake-ack.sh" commit "${SESSION_ID_ARGS[@]+"${SESSION_ID_ARGS[@]}"}" >/dev/null 2>&1 || true
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: whatever bin/fm-supervision-lib.sh counts as supervision need ------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight generation claim --------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# generation owner arms and translates per event epoch: every firing defers to
# a live open claim, and a stuck, dead, identity-mismatched, or finished claim
# is superseded by taking the next generation (fm_autoarm_claim_open and
# fm_autoarm_claim_next in bin/fm-wake-lib.sh own the contract). No mutex is
# held past this point. A micro-mutex contention with a bare hold is another
# participant's short ledger section and the next Stop firing simply retries,
# while a role-carrying hold is a legacy lock-holding claim from a
# pre-generation build (or the guard's own terminal-check), which the legacy
# shim defers to while genuinely deciding and reclaims once when proven
# abandoned.
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
# this generation. Success means this generation's translation WINS and the
# caller exits 2 unconditionally. Markerless outcomes commit with the owned
# ledger write; a notice wins only when its following marker write succeeds in
# the same hold. Failure means refused or unverifiable: the caller goes silent
# (cleanup, exit 0) - the harness discards the collected stderr on exit 0, so
# even an already-printed banner is never delivered by a losing generation.
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

# Best-effort ownership-checked record for exit-0 paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1 || true
}

# Claude terminates the complete async-hook process tree when the configured
# hook timeout expires. The arm is intentionally allowed to follow a healthy
# watcher until its next wake, so that wait cannot be shortened without adding
# artificial turns. Translate a host interruption through the ordinary durable
# failure protocol instead: the winning generation records a terminal outcome,
# creates the episode marker, and exits 2 so Claude delivers a recovery turn -
# except after Claude's own timeout kill, whose exit 2 is dropped (header).
# A superseded generation remains silent, and an episode whose attended
# fail-open was already consumed must not restart automatic continuation.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_autoarm_signal() {
  local signal=$1
  trap - HUP TERM INT
  if [ -n "${ARM_PID:-}" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  ! command -v predrain_reset >/dev/null 2>&1 || predrain_reset
  if [ -e "$FAILURE_ALARM" ]; then
    autoarm_record failed-suppressed
    exit 0
  fi
  if [ ! -e "$FAILURE_NOTICE" ]; then
    printf 'firstmate watcher auto-arm INTERRUPTED by %s - the Stop-owned automatic supervision mechanism did not reach a terminal watcher outcome.\n' "$signal" >&2
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n' >&2
    autoarm_commit failed "$FAILURE_NOTICE" && exit 2
    exit 0
  fi
  autoarm_commit failed-suppressed && exit 2
  exit 0
}

trap 'handle_autoarm_signal HUP' HUP
trap 'handle_autoarm_signal TERM' TERM
trap 'handle_autoarm_signal INT' INT

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# The arm is a tracked child this hook waits on, never a fire-and-forget shell
# & whose child would be reaped when the hook returned: this hook process tree
# is the harness-owned lifecycle. The arm forks the watcher as its own tracked
# child exactly as it does for the model-driven background-task path, and
# propagates the wake reason on close. Holding the arm's pid lets the signal
# handler TERM it with the hook and lets the handling successor below name it
# as the predecessor whose cycle just closed.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
# With a bound, an arm still open when it expires is TERMed and ARM_BOUND_HIT
# is set, so the caller can deliver a wake before Claude's hook timeout.
ARM_PID=
CLOSED_ARM_PID=
ARM_BOUND_HIT=0
run_arm() {  # <output file, or empty for none> [bound seconds]
  local deadline
  ARM_BOUND_HIT=0
  if [ -n "$1" ]; then
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >"$1" 2>&1 &
  else
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  if [ -n "${2:-}" ]; then
    deadline=$(( $(date +%s) + $2 ))
    while kill -0 "$ARM_PID" 2>/dev/null; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        ARM_BOUND_HIT=1
        kill -TERM "$ARM_PID" 2>/dev/null || true
        break
      fi
      sleep 1
    done
  fi
  wait "$ARM_PID" || true
  CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
}

# --- handling successor --------------------------------------------------------
# Start the next arm before the rewake delivers the wake, as the Pi, omp, and
# OpenCode adapters do from their child-close handlers, so a watcher covers the
# handling turn instead of the home waiting uncovered for the next Stop. The
# successor receives the closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID; it
# must outlive this hook's exit, so it is detached three ways: nohup, stdio
# away from the hook's pipes, and its own process group. Its one status line
# is awaited within the arm's own confirmation budget plus slack. Sets
# SUCCESSOR_FAILURE to the banner line for an unconfirmed successor.
SUCCESSOR_FAILURE=
start_handling_successor() {  # <closed-arm-pid>
  local out pid deadline budget line monitor_was_on=0
  budget=${FM_ARM_CONFIRM_TIMEOUT:-30}
  case "$budget" in ''|*[!0-9]*) budget=30 ;; esac
  if ! out=$(mktemp "$STATE/.claude-autoarm-successor.XXXXXX"); then
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

# --- staged pre-drain, its acknowledgement, and empty plumbing closes ---------
# Header bullets "Pre-drained wake and turn-end acknowledgement" and "Empty
# plumbing closes" own the rules; these helpers are their mechanics.
PREDRAIN_DONE=0
PREDRAIN_OK=0
PREDRAIN_OUT=
PREDRAIN_ERR=
PREDRAIN_ACK_THROUGH=
PREDRAIN_GENERATION=
PREDRAIN_PROCESSED=0
PREDRAIN_RECEIPT="$STATE/.wake-ack-pending.receipt"

predrain_reset() {
  [ -z "${PREDRAIN_OUT:-}" ] || rm -f "$PREDRAIN_OUT" 2>/dev/null || true
  [ -z "${PREDRAIN_ERR:-}" ] || rm -f "$PREDRAIN_ERR" 2>/dev/null || true
  PREDRAIN_DONE=0
  PREDRAIN_OK=0
  PREDRAIN_OUT=
  PREDRAIN_ERR=
  PREDRAIN_ACK_THROUGH=
  PREDRAIN_GENERATION=
  PREDRAIN_PROCESSED=0
}

# Stage main's drain once per close. 0 when the receipt is usable; any other
# outcome (no drain, a nonzero drain, no receipt, an unparseable receipt) means
# the banner falls back to asking main to drain and acknowledge itself.
predrain_stage() {
  if [ "$PREDRAIN_DONE" -eq 1 ]; then
    [ "$PREDRAIN_OK" -eq 1 ]
    return
  fi
  PREDRAIN_DONE=1
  [ -x "$SCRIPT_DIR/fm-wake-drain.sh" ] && [ -x "$SCRIPT_DIR/fm-wake-ack.sh" ] || return 1
  PREDRAIN_OUT=$(mktemp "$STATE/.claude-autoarm-predrain.XXXXXX") || { PREDRAIN_OUT=; return 1; }
  PREDRAIN_ERR="$PREDRAIN_OUT.err"
  rm -f "$PREDRAIN_RECEIPT" 2>/dev/null || true
  if ! FM_SUPERVISION_ACTOR=main "$SCRIPT_DIR/fm-wake-drain.sh" --stage "$PREDRAIN_RECEIPT" \
      >"$PREDRAIN_OUT" 2>"$PREDRAIN_ERR" </dev/null; then
    rm -f "$PREDRAIN_RECEIPT" 2>/dev/null || true
    return 1
  fi
  [ -f "$PREDRAIN_RECEIPT" ] || return 1
  PREDRAIN_ACK_THROUGH=$(sed -n 's/^ack_through=//p' "$PREDRAIN_RECEIPT" | head -n 1)
  PREDRAIN_GENERATION=$(sed -n 's/^recovery_generation=//p' "$PREDRAIN_RECEIPT" | head -n 1)
  PREDRAIN_PROCESSED=$(sed -n 's/^outcomes_processed_target=//p' "$PREDRAIN_RECEIPT" | head -n 1)
  case "$PREDRAIN_ACK_THROUGH" in ''|*[!0-9]*) rm -f "$PREDRAIN_RECEIPT"; return 1 ;; esac
  case "$PREDRAIN_GENERATION" in *[!A-Za-z0-9._-]*) rm -f "$PREDRAIN_RECEIPT"; return 1 ;; esac
  case "$PREDRAIN_PROCESSED" in ''|*[!0-9]*) PREDRAIN_PROCESSED=0 ;; esac
  PREDRAIN_OK=1
}

# Seconds this hook may still spend before its registered timeout, less slack.
hook_budget_remaining() {
  printf '%s\n' $(( HOOK_TIMEOUT - ( $(date +%s) - HOOK_START ) - 300 ))
}

# 0 when every actionable line of <out> is one of the two plumbing closes.
close_is_plumbing_only() {  # <out-file>
  local lines
  lines=$(grep -E "$ACTIONABLE_RE" "$1" 2>/dev/null) || return 1
  [ -n "$lines" ] || return 1
  ! printf '%s\n' "$lines" | grep -Ev '^check: (rearm-resurface|inactive-outcome)$' >/dev/null
}

ack_log() {  # <action> <detail>
  printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$STATE/wake-ack.log" 2>/dev/null || true
}

# Absorb an empty plumbing close: 0 when it was acknowledged here and the
# cycle may re-arm without waking main; 1 when it must be delivered.
try_suppress_plumbing_close() {
  local remaining rc=0
  [ -n "$OUT" ] || return 1
  close_is_plumbing_only "$OUT" || return 1
  [ "$SUPPRESSED" -lt "$SUPPRESS_MAX" ] || return 1
  remaining=$(hook_budget_remaining)
  [ "$remaining" -ge "$SUPPRESS_MIN" ] || return 1
  fm_autoarm_still_owner "$STATE" "$MY_GEN" || return 1
  predrain_stage || return 1
  if [ -s "$PREDRAIN_OUT" ] || [ -s "$PREDRAIN_ERR" ]; then
    return 1
  fi
  if [ -n "$PREDRAIN_GENERATION" ]; then
    FM_SUPERVISION_ACTOR=main "$SCRIPT_DIR/fm-wake-drain.sh" --ack-through "$PREDRAIN_ACK_THROUGH" \
      --recovery-generation "$PREDRAIN_GENERATION" --commit-stage "$PREDRAIN_RECEIPT" >/dev/null 2>&1 </dev/null || rc=$?
  else
    rm -f "$PREDRAIN_RECEIPT" 2>/dev/null || true
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$PREDRAIN_RECEIPT" 2>/dev/null || true
    predrain_reset
    return 1
  fi
  SUPPRESSED=$((SUPPRESSED + 1))
  ack_log suppressed "$(grep -E "$ACTIONABLE_RE" "$OUT" 2>/dev/null | head -n 1 | tr '\t' ' ') presented nothing; acknowledged (ack_through=$PREDRAIN_ACK_THROUGH recovery_generation=$PREDRAIN_GENERATION) and re-armed without waking main"
  predrain_reset
  return 0
}

# Print <file> for the banner under the line and byte caps.
print_presentation_bounded() {  # <file>
  local line used=0 omitted=0 bytes
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$omitted" -eq 0 ]; then
      fm_cap_line_var "$line" "$PRESENT_LINE"
      line=$FM_LINE_CAP_LINE
      bytes=$(( ${#line} + 1 ))
      if [ $((used + bytes)) -le "$PRESENT_BYTES" ]; then
        printf '%s\n' "$line"
        used=$((used + bytes))
        continue
      fi
    fi
    omitted=$((omitted + 1))
  done < "$1"
  [ "$omitted" -eq 0 ] \
    || printf 'WAKE PRESENTATION CUT: %s more line(s) not shown (byte cap); run bin/fm-wake-drain.sh to see everything - it presents this same wake again, and the turn-end acknowledgement still covers it.\n' "$omitted"
}

OUT=
ACTIONABLE=0
HEALTHY=0
HOST_MODE=0
HOST_RC=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
# The home gate's owner decides (docs/configuration.md "Supervision host").
if fm_supervision_host_enabled "$CONFIG" claude; then
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
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  if [ "$HOST_MODE" -eq 1 ]; then
    HOST_RC=0
    if [ "$SUPPRESSED" -gt 0 ]; then
      # A re-park after an absorbed close must still end inside this hook's
      # registered timeout, so bound it to what is left.
      HOST_PARK_BOUND=$(hook_budget_remaining)
      case "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" in
        ''|*[!0-9]*) ;;
        *) [ "$FM_SUPERVISION_HOST_PARK_SECONDS" -ge "$HOST_PARK_BOUND" ] || HOST_PARK_BOUND=$FM_SUPERVISION_HOST_PARK_SECONDS ;;
      esac
      [ "$HOST_PARK_BOUND" -ge 60 ] || HOST_PARK_BOUND=60
      FM_SUPERVISION_HOST_PARK_SECONDS=$HOST_PARK_BOUND \
        FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
        FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
        "$SCRIPT_DIR/fm-supervision-host.sh" park >"${OUT:-/dev/null}" 2>&1 || HOST_RC=$?
    else
      FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
        FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
        "$SCRIPT_DIR/fm-supervision-host.sh" park >"${OUT:-/dev/null}" 2>&1 || HOST_RC=$?
    fi
  elif [ "$SUPPRESSED" -gt 0 ]; then
    # The watcher re-arm after an absorbed close gets the same bound; a cycle
    # still open at it is delivered as an ordinary wake instead of being
    # killed silently at the hook timeout.
    ARM_BOUND=$(hook_budget_remaining)
    [ "$ARM_BOUND" -ge 1 ] || ARM_BOUND=1
    run_arm "$OUT" "$ARM_BOUND"
    [ "$ARM_BOUND_HIT" -eq 0 ] || [ -z "$OUT" ] \
      || printf 'check: hook-budget - this Stop hook re-armed after absorbing an empty plumbing close and reached its registered timeout budget; handle the wake and end the turn, and the next cycle arms on its own\n' >> "$OUT"
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
  if [ "$ACTIONABLE" -eq 1 ]; then
    # An empty plumbing close is acknowledged here and the cycle re-arms in
    # this process (header "Empty plumbing closes"); it spends no attempt.
    if try_suppress_plumbing_close; then
      ACTIONABLE=0
      rm -f "$OUT" 2>/dev/null || true
      OUT=
      if ! need_supervision; then
        autoarm_record clean
        exit 0
      fi
      attempt=$((attempt - 1))
      continue
    fi
    break
  fi
  if [ "$HOST_MODE" -eq 1 ]; then
    # The host stood down because this session or generation no longer owns
    # supervision: whoever does owns continuity now.
    if [ -n "$OUT" ] && grep -q '^supervision-host stood down:' "$OUT" 2>/dev/null; then
      autoarm_record clean
      rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    # A host that died without a close may have left its cycle running with
    # no owner to deliver the close; retrying lets the next host stop what it
    # left and own a fresh cycle, which the healthy-watcher predicate cannot.
    if [ "$HOST_RC" -gt 128 ] || [ -z "$OUT" ] || [ ! -s "$OUT" ]; then
      [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      OUT=
      continue
    fi
    # A failed hand-back cannot be dismissed just because its successor
    # watcher is healthy: the close is still undelivered.
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
    [ -e "$FAILURE_ALARM" ] && exit 0
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  autoarm_record failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  # Cheap early-out before composing the banner; the real commit decision is
  # the owned terminal write below.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  # The host owns its own successors and stops its cycle before handing back.
  if [ "$HOST_MODE" -eq 0 ]; then
    start_handling_successor "$CLOSED_ARM_PID" || true
  fi
  # Stage main's drain before the commit (the staged drain leaves the recovery
  # marker in downtime, which the rewake commit requires); begin handling and
  # record the acknowledgement only once the rewake is committed.
  predrain_stage || true
  if autoarm_commit rewake; then
    PREDRAINED=0
    if [ "$PREDRAIN_OK" -eq 1 ]; then
      PREDRAINED=1
      if [ -n "$PREDRAIN_GENERATION" ] \
        && ! fm_recovery_marker_begin_handling "$STATE/.watcher-down" "$PREDRAIN_GENERATION"; then
        PREDRAINED=0
      fi
      if [ "$PREDRAINED" -eq 1 ]; then
        ACK_NONCE=$("$SCRIPT_DIR/fm-wake-ack.sh" record --ack-through "$PREDRAIN_ACK_THROUGH" \
          --recovery-generation "$PREDRAIN_GENERATION" --receipt "$PREDRAIN_RECEIPT" \
          --session-pid "$(sed -n '1p' "$STATE/.lock" 2>/dev/null)" --generation "$MY_GEN" \
          "${SESSION_ID_ARGS[@]+"${SESSION_ID_ARGS[@]}"}" 2>/dev/null) || PREDRAINED=0
        [ -n "$ACK_NONCE" ] || PREDRAINED=0
      fi
      [ "$PREDRAINED" -eq 1 ] || rm -f "$PREDRAIN_RECEIPT" 2>/dev/null || true
    fi
    {
      printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
      [ "$PREDRAINED" -eq 0 ] || printf 'Wake acknowledgement id: %s (it pends until this turn ends).\n' "$ACK_NONCE"
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
      if [ "$PREDRAINED" -eq 1 ]; then
        if [ -s "$PREDRAIN_OUT" ]; then
          printf 'WAKE PRESENTATION (this hook already ran bin/fm-wake-drain.sh for you; this is what it printed):\n'
          print_presentation_bounded "$PREDRAIN_OUT"
        else
          printf 'WAKE PRESENTATION: the drain presented nothing - no queued row, unread status line, open decision, record divergence, or branch outcome is waiting for you, so the close above is the whole wake.\n'
        fi
        [ ! -s "$PREDRAIN_ERR" ] || print_presentation_bounded "$PREDRAIN_ERR"
        if [ -n "$PREDRAIN_GENERATION" ]; then
          printf 'Handle the wake from that presentation; do not run bin/fm-wake-drain.sh again unless it says the presentation was cut. Its acknowledgement (--ack-through %s --recovery-generation %s%s) runs automatically when this turn ends, so end the turn only once the wake is handled; to keep the wake open past this turn, run bin/fm-wake-ack.sh hold. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n' \
            "$PREDRAIN_ACK_THROUGH" "$PREDRAIN_GENERATION" \
            "$([ "$PREDRAIN_PROCESSED" -gt 0 ] && printf ', plus the BRANCH OUTCOMES mark-processed through %s' "$PREDRAIN_PROCESSED")"
        else
          printf 'Handle the wake from that presentation; do not run bin/fm-wake-drain.sh again unless it says the presentation was cut. Nothing is queued to acknowledge; what it presented is marked read automatically when this turn ends%s, so end the turn only once the wake is handled; to keep the wake open past this turn, run bin/fm-wake-ack.sh hold. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n' \
            "$([ "$PREDRAIN_PROCESSED" -gt 0 ] && printf ' (including the BRANCH OUTCOMES mark-processed through %s)' "$PREDRAIN_PROCESSED")"
        fi
      else
        printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
      fi
    } >&2
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    predrain_reset
    exit 2
  fi
  rm -f "$PREDRAIN_RECEIPT" 2>/dev/null || true
  predrain_reset
  if [ "$HOST_MODE" -eq 1 ] && fm_autoarm_still_owner "$STATE" "$MY_GEN" \
    && fm_recovery_marker_snapshot "$STATE/.watcher-down" \
    && [[ "$FM_RECOVERY_MARKER_TOKEN" == pending:handling:* || "$FM_RECOVERY_MARKER_TOKEN" == announced:handling:* ]] \
    && ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    LOST_HANDBACK_COMMITTED=0
    if [ ! -e "$FAILURE_NOTICE" ]; then
      printf 'firstmate watcher auto-arm FAILED - the supervision host returned an actionable wake, but its rewake could not be committed.\n' >&2
      autoarm_commit failed "$FAILURE_NOTICE" && LOST_HANDBACK_COMMITTED=1
    else
      autoarm_commit failed-suppressed && LOST_HANDBACK_COMMITTED=1
    fi
    if [ "$LOST_HANDBACK_COMMITTED" -eq 1 ]; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 2
    fi
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop. The notice marker
# commits in the same owned critical section as the winning failed write, so a
# losing generation can neither consume nor deliver it.
if [ ! -e "$FAILURE_NOTICE" ]; then
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat|supervision-host)' "$OUT" 2>/dev/null | head -8
    [ "$HOST_MODE" -eq 0 ] || printf 'The supervision host (docs/supervision-host.md) ran these cycles; its last one exited %s without a wake.\n' "$HOST_RC"
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  if autoarm_commit failed "$FAILURE_NOTICE"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi
if autoarm_commit failed-suppressed; then
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 0
