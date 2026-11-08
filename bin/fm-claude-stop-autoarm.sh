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
#     When the shared fm_session_lock_pid_blocks_reclaim verdict refuses to
#     reclaim the recorded owner, the hook stays inert; otherwise it delegates
#     guarded recovery to bin/fm-lock.sh and then re-verifies ownership.
#     A missing lock, a malformed record, or unresolved ancestry stays inert too,
#     so a competing session never arms or rewakes.
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
#     HUP, TERM, and INT follow the session-aware interruption contract in
#     docs/turnend-guard.md. Claude does not deliver the exit 2 of a hook it
#     terminated at the configured timeout
#     as a rewake (measured on Claude Code 2.1.278 and 2.1.281,
#     docs/verification/supervision.md), so a park that outlives that timeout
#     records the failure durably without waking an idle primary. Nothing
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
#   - Inline drain and acknowledgement: the winning rewake runs
#     bin/fm-wake-drain.sh itself and carries its output, so the handling turn
#     starts from the presented wakes. When the Stop payload can prove it, the
#     Stop that ends the turn which received that delivery runs the exact
#     --ack-through acknowledgement; an interrupted or failed turn fires no
#     Stop, so its rows stay durable. The ticket contract after the identity
#     gate owns the proof; any doubt leaves the acknowledgement to the model.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 with a one-line suppression reason to guarantee the next
#     Stop-owned retry without repeating notice, until the episode's attended
#     fail-open is consumed. Two writers own that attended alarm
#     (state/.claude-autoarm-failure-alarmed) under the same owner-then-budget
#     lock order: the synchronous guard's terminal_fail_open, and this hook's
#     own terminal failure - the exhausted continuation is the one participant
#     that knows no automatic continuation remains, so once this session's
#     consumed block count is over the guard's budget it commits the alarm in
#     the same owned critical section as its failed-suppressed write and
#     delivers the one loud final rewake; later generations exit 0.
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
# Only this invocation's commit must survive an interruption as a final rewake.
AUTOARM_COMMITTED_ALARM=0
# The guard's attended-block budget (bin/fm-turnend-guard.sh --claude owns the
# accounting): the auto-arm reads this session's consumed count when its own
# terminal continuation failure is reached, to decide whether it must also
# commit the episode's attended alarm itself.
BUDGET_FILE="$STATE/.turnend-claude-blocks"
BUDGET_LOCK="$STATE/.turnend-claude-blocks.lock"
BLOCK_BUDGET=${FM_CLAUDE_TURNEND_BLOCK_BUDGET:-3}
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

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
# The same payload names the turn that just ended (prompt_id), which the
# hook-owned wake acknowledgement below uses as its completion proof.
TRANSCRIPT=
PROMPT_ID=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty | strings' 2>/dev/null)
  PROMPT_ID=$(printf '%s' "$PAYLOAD" | jq -r '.prompt_id // empty | strings' 2>/dev/null)
fi
case "$TRANSCRIPT" in */.pi/*) exit 0 ;; esac
case "$PROMPT_ID" in *[!A-Za-z0-9._-]*) PROMPT_ID= ;; esac

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its harness identity in .lock.
# Use the shared fm_session_lock_pid_blocks_reclaim verdict to recognize only
# that stale-owner case; it resolves a tagged identity too, so a dead Windows
# session is still recoverable rather than being read as a malformed lock nobody
# may ever clear.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$LOCK_PID" || exit 0
  fm_session_lock_pid_blocks_reclaim "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- hook-owned wake acknowledgement -----------------------------------------
# A won rewake below runs bin/fm-wake-drain.sh itself and delivers the output.
# When this payload can later prove the receiving turn completed, the delivery
# drops the WAKE_ACK_REQUIRED line and carries a random nonce, and the ticket
# file records that nonce with the exact --ack-through cutoff and recovery
# generation. Claude fires Stop only when a turn finishes responding: never on
# a user interrupt, and an API error fires StopFailure instead. So a Stop whose
# prompt_id names the turn the transcript shows receiving the nonce proves the
# wakes were handled, and only then does the hook run the acknowledgement.
# Every other outcome leaves the rows durable for the next drain to present
# again: a missing field, an undelivered nonce, a Stop for another turn, or a
# newer drain, which presents the same unacknowledged rows under a new ticket.
ACK_TICKET="$STATE/.claude-autoarm-ack-ticket"
# A hook-run acknowledgement that fails (error or timeout) is never silent: the
# ticket stays for a retry and the error waits here for the next rewake to
# report, because the harness discards a hook's output on exit 0.
ACK_FAILURE="$STATE/.claude-autoarm-ack-failure"
WAKE_DRAIN_TIMEOUT=120

run_wake_drain() {  # [drain args...]
  fm_run_timed "$WAKE_DRAIN_TIMEOUT" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISION_ACTOR=main "$SCRIPT_DIR/fm-wake-drain.sh" "$@" </dev/null
}

# Print what the transcript says about the delivery carrying <nonce> for the
# turn <stop> that just ended: handled when that turn received it, superseded
# when that turn began after another turn received it (an interrupt), and
# pending otherwise. An idle rewake is a user entry that is its own turn; a
# rewake queued into a running turn is a queued_command attachment of the
# latest prompt's turn. Queue bookkeeping, request copies, tool results, and
# assistant text that merely quote the nonce are not deliveries.
delivery_verdict() {  # <transcript> <nonce> <stop prompt id>
  grep -F -e '"promptId"' -e "$2" "$1" 2>/dev/null | jq -n -R -r --arg nonce "$2" --arg stop "$3" '
    def text: if type == "string" then .
      elif type == "array" then [.[]? | objects | select(.type == "text") | .text | strings] | join("\n")
      else "" end;
    reduce (inputs | fromjson? | objects | select(.isSidechain != true)) as $r (
      {turn: null, delivered: null, later: false};
      if $r.type == "user" and ($r.promptId | type) == "string" then
        .turn = $r.promptId
        | if .delivered == null and ($r.message.content | text | contains($nonce)) then .delivered = $r.promptId
          elif .delivered != null and $r.promptId == $stop then .later = true
          else . end
      elif .delivered == null and .turn != null and $r.type == "attachment"
        and $r.attachment.type == "queued_command" and ($r.attachment.prompt | text | contains($nonce)) then
        .delivered = .turn
      else . end)
    | if .delivered == $stop then "handled" elif .delivered != null and .later then "superseded"
      else "pending" end' 2>/dev/null
}

settle_ack_ticket() {
  local claimed nonce ack generation verdict ack_out ack_rc keep=0
  [ -f "$ACK_TICKET" ] && [ -n "$PROMPT_ID" ] && [ -r "$TRANSCRIPT" ] || return 0
  claimed="$ACK_TICKET.settling.$$"
  mv -f "$ACK_TICKET" "$claimed" 2>/dev/null || return 0
  nonce=$(sed -n 's/^nonce=\([A-Za-z0-9-][A-Za-z0-9-]*\)$/\1/p' "$claimed" 2>/dev/null)
  ack=$(sed -n 's/^ack=\([0-9][0-9]*\)$/\1/p' "$claimed" 2>/dev/null)
  generation=$(sed -n 's/^generation=\([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$claimed" 2>/dev/null)
  if [ -n "$nonce" ] && [ -n "$ack" ] && [ -n "$generation" ]; then
    verdict=$(delivery_verdict "$TRANSCRIPT" "$nonce" "$PROMPT_ID")
    case "$verdict" in
      handled)
        ack_rc=0
        ack_out=$(run_wake_drain --ack-through "$ack" --recovery-generation "$generation" 2>&1) || ack_rc=$?
        if [ "$ack_rc" -ne 0 ]; then
          keep=1
          {
            printf 'exit %s from bin/fm-wake-drain.sh --ack-through %s --recovery-generation %s\n' "$ack_rc" "$ack" "$generation"
            printf '%s\n' "$ack_out" | head -n 20
          } > "$ACK_FAILURE" 2>/dev/null || true
        fi
        ;;
      superseded) ;;
      # Not yet received, or received by a later turn: keep it for a later
      # Stop, unless a newer drain has already replaced it.
      *) keep=1 ;;
    esac
    [ "$keep" -eq 0 ] || ln "$claimed" "$ACK_TICKET" 2>/dev/null || true
  fi
  rm -f "$claimed" 2>/dev/null || true
}

# Settle before the AFK and need gates: the handling turn may itself have
# entered the away posture or retired the last supervised work.
[ "$RECOVER_SESSION_LOCK" -eq 1 ] || settle_ack_ticket

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
SESSION_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
SESSION_IDENTITY=$(fm_session_pid_identity "$SESSION_PID" 2>/dev/null || true)
SESSION_ID=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
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
autoarm_commit() {  # <outcome> [marker-file] [interrupted-session-identity]
  local outcome=$1 marker=${2:-} marker_identity=${3:-} session_pid recovery
  if [ "$outcome" = rewake ]; then
    fm_session_lock_owned_by_self "$STATE" || return 2
    session_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 2
    case "$FM_RECOVERY_MARKER_TOKEN" in
      pending:downtime:*|announced:downtime:*) recovery=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
      *) return 2 ;;
    esac
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker" "$session_pid" "$recovery"
  else
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker" '' '' "$marker_identity" "$SESSION_ID"
  fi
}

# Best-effort ownership-checked record for exit-0 paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1 || true
}

# Commit this generation's terminal failed-suppressed outcome together with
# the failure episode's attended alarm, when the episode has already burned
# this session's whole attended block budget. The exhausted continuation is
# the one participant that knows no automatic continuation remains, so the
# auto-arm is the second writer of .claude-autoarm-failure-alarmed beside
# bin/fm-turnend-guard.sh --claude's terminal_fail_open.
#
# The decision and the commit share one critical section under the documented
# lock order - owner lock, then budget lock, the same order terminal_fail_open
# uses. Holding the budget lock across the marker write excludes
# fm_failure_episode_reset, so an alarm can never be orphaned into a reset
# episode, and holding the owner lock makes the ledger write and the alarm
# create one atomic section (_fm_autoarm_write_owned_locked). The open-claim
# exclusion that keeps the guard's alarm from firing mid-generation is already
# satisfied: this generation's own claim is the open one, and its terminal
# failure is the proof the continuation is gone.
#
# Returns 0 when the alarm was committed, 2 when a verified healthy watcher
# appeared inside the hold (the caller resets and closes clean instead), and
# 1 on any other refusal or uncertainty.
autoarm_commit_attended_alarm() {
  local session_id budget_session budget_count rc=1 i=0
  fm_lock_try_acquire "$OWNER_LOCK" || return 1
  while ! fm_lock_try_acquire "$BUDGET_LOCK"; do
    if [ "$i" -ge 20 ]; then
      fm_lock_release "$OWNER_LOCK"
      return 1
    fi
    sleep 0.02
    i=$((i + 1))
  done
  if fm_autoarm_ledger_read "$STATE" \
    && [ "$FM_AUTOARM_GEN" = "$MY_GEN" ] \
    && [ "$FM_AUTOARM_OWNER" = "${BASHPID:-$$}" ] \
    && [ -e "$FAILURE_NOTICE" ] \
    && [ ! -e "$FAILURE_ALARM" ] \
    && [ ! -e "$STATE/.afk" ]; then
    if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
      rc=2
    else
      session_id=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
      budget_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
      budget_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
      case "$budget_count" in ''|*[!0-9]*) budget_count=0 ;; esac
      if [ "$budget_session" = "$session_id" ] \
        && [ "$budget_count" -gt "$BLOCK_BUDGET" ] \
        && _fm_autoarm_write_owned_locked "$STATE" "$MY_GEN" failed-suppressed "$FAILURE_ALARM"; then
        AUTOARM_COMMITTED_ALARM=1
        rc=0
      fi
    fi
  fi
  fm_lock_release "$BUDGET_LOCK"
  fm_lock_release "$OWNER_LOCK"
  return "$rc"
}

autoarm_alarm_banner() {
  local need_desc
  if [ "${FM_SUP_IN_FLIGHT:-0}" -gt 0 ]; then
    need_desc="$FM_SUP_IN_FLIGHT task(s) in flight"
  elif [ "${FM_SUP_SOURCES:-0}" -gt 0 ]; then
    need_desc="$FM_SUP_SOURCES process-event source(s) registered"
  elif [ "${FM_SUP_CHECKS:-0}" -gt 0 ]; then
    need_desc="$FM_SUP_CHECKS registered custom check(s)"
  else
    need_desc="X-mode relay polling active"
  fi
  {
    printf 'FIRSTMATE SUPERVISION IS GENUINELY DOWN: %s - the Stop-owned auto-arm exhausted its bounded retries and one failure notice, no live watcher or automatic continuation exists, and this session block budget is exhausted.\n' "$need_desc"
    printf 'Keep this session attended and diagnose the automatic Stop-hook and watcher startup before relying on unattended supervision; do not launch a manual background arm from this notice.\n'
  } >&2
}

# The one terminal exhaustion decision every failed-suppressed continuation
# goes through - the ordinary exhausted failure, a lost supervision-host
# hand-back, an interruption, and a refused healthy-watcher reset alike - so
# none of them can commit another retry once the episode's attended alarm is
# due (bin/fm-turnend-guard.sh --claude steps aside for every open claim, so a
# path that skipped this decision could burn the block budget forever with no
# participant alarming). In order: commit the attended alarm with the one loud
# final rewake; close clean when a verified healthy watcher lets the episode
# reset; otherwise commit failed-suppressed. <cause> says why this continuation
# is suppressed, and the appended clause states the outcome the commit actually
# decided: an already-alarmed episode schedules no Stop-owned retry (exit 0),
# anything else keeps it alive (exit 2). Text already on stderr, such as the
# host's actionable wake lines, is delivered with whichever rewake wins.
autoarm_exit_suppressed() {  # <cause> [interrupted-session-identity]
  local cause=$1 marker_identity=${2:-} rc
  if [ -n "$marker_identity" ] && ! fm_autoarm_session_matches "$STATE" "$marker_identity" "$SESSION_ID"; then
    autoarm_record session-ended
    [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  autoarm_commit_attended_alarm
  rc=$?
  if [ "$rc" -eq 0 ]; then
    autoarm_alarm_banner
    [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  if [ "$rc" -eq 2 ]; then
    fm_autoarm_reset_owned "$STATE" "$MY_GEN" >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || autoarm_record clean
    if [ "$rc" -ne 1 ]; then
      [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    cause='firstmate watcher auto-arm could not clear the resolved failure episode - a verified healthy watcher is running, but the episode reset was refused'
  fi
  if ! autoarm_commit failed-suppressed '' "$marker_identity"; then
    [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  if [ -e "$FAILURE_ALARM" ]; then
    printf '%s; the attended failure alarm is already committed for this episode, so this suppressed continuation repeats no operator notice and schedules no Stop-owned retry.\n' "$cause" >&2
    exit 0
  fi
  printf '%s; no operator notice repeats in this episode, and this suppressed continuation keeps the Stop-owned retry alive.\n' "$cause" >&2
  exit 2
}

# Claude terminates the complete async-hook process tree when the configured
# hook timeout expires. The arm is intentionally allowed to follow a healthy
# watcher until its next wake, so that wait cannot be shortened without adding
# artificial turns. Translate a host interruption through the ordinary durable
# failure protocol instead: the winning generation records a terminal outcome,
# creates the episode marker, and exits 2 so Claude delivers a recovery turn -
# except after Claude's own timeout kill, whose exit 2 is dropped (header).
# Without a matching session, the hook closes silently as session-ended.
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
  if ! fm_autoarm_session_matches "$STATE" "$SESSION_IDENTITY" "$SESSION_ID"; then
    autoarm_record session-ended
    exit 0
  fi
  if [ "$AUTOARM_COMMITTED_ALARM" -eq 1 ]; then
    autoarm_alarm_banner
    exit 2
  fi
  if [ -e "$FAILURE_ALARM" ]; then
    printf 'firstmate watcher auto-arm interrupted by %s after the attended alarm - the failure episode is already alarmed, so this suppressed continuation emits no further rewake.\n' "$signal" >&2
    autoarm_record failed-suppressed
    exit 0
  fi
  if [ ! -e "$FAILURE_NOTICE" ]; then
    printf 'firstmate watcher auto-arm INTERRUPTED by %s - the Stop-owned automatic supervision mechanism did not reach a terminal watcher outcome.\n' "$signal" >&2
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n' >&2
    autoarm_commit failed "$FAILURE_NOTICE" "$SESSION_IDENTITY" && exit 2
    exit 0
  fi
  autoarm_exit_suppressed "firstmate watcher auto-arm interrupted by $signal - the failure episode notice was already consumed" "$SESSION_IDENTITY"
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

# --- handling successor --------------------------------------------------------
# Start the next arm before the rewake delivers the wake, as the Pi, omp, and
# OpenCode adapters do from their child-close handlers, so a watcher covers the
# handling turn instead of the home waiting uncovered for the next Stop. The
# successor receives the closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID; it
# must outlive this hook's exit, so it is detached three ways: nohup, stdio
# away from the hook's pipes, and its own process group. Its one status line
# is awaited within its own short successor budget plus slack - deliberately
# not the arm's fresh-child backstop, which may run far longer. Sets
# SUCCESSOR_FAILURE to the banner line for an unconfirmed successor.
SUCCESSOR_FAILURE=
start_handling_successor() {  # <closed-arm-pid>
  local out pid deadline budget line monitor_was_on=0
  budget=${FM_ARM_SUCCESSOR_CONFIRM_TIMEOUT:-30}
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

# --- inline drain --------------------------------------------------------------
# Only a generation whose rewake already won drains, so no losing generation
# claims rows it never delivers. The output rides the rewake under the ticket
# contract above when this payload can prove the receiving turn later;
# otherwise the model runs the printed acknowledgement itself. Output past the
# delivery bound (a live probe delivered 60 KB intact on Claude Code 2.1.311)
# is left in a file for the model to read. A drain that printed output but no
# acknowledgement still delivers that output, because it may hold status it
# marked as shown; only a drain that printed nothing, or failed without
# presenting any status, falls back to the model running the drain itself.
CONTINUITY_NOTE='This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.'
MODEL_DRAIN_LINE="Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. $CONTINUITY_NOTE"
DRAIN_DELIVERY_MAX=48000
DRAIN_OVERFLOW="$STATE/.claude-autoarm-drain-output"
deliver_inline_drain() {
  local out='' line ack='' generation='' nonce ticket stale=0 drain_rc=0
  # An acknowledgement this hook ran earlier and could not complete: say so
  # before the drain, which presents any rows it left unacknowledged again.
  if [ -s "$ACK_FAILURE" ]; then
    printf 'The hook-run acknowledgement of an earlier drain failed, so those wakes may be presented again below; the failure was:\n'
    cat "$ACK_FAILURE" 2>/dev/null || true
    rm -f "$ACK_FAILURE" 2>/dev/null || true
  fi
  # A ticket still waiting here has no proof its turn completed, perhaps
  # because the transcript format changed: this delivery leaves its
  # acknowledgement to the model rather than let unproven tickets keep rows
  # unacknowledged. Either way this drain presents the earlier ticket's rows
  # again.
  if [ -e "$ACK_TICKET" ]; then
    stale=1
    rm -f "$ACK_TICKET" 2>/dev/null || true
  fi
  if out=$(mktemp "$STATE/.claude-autoarm-drain.XXXXXX"); then
    run_wake_drain >"$out" 2>&1 || drain_rc=$?
    line=$(sed -n 's/^WAKE_ACK_REQUIRED:.* --ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1 \2/p' "$out" | tail -n 1)
    ack=${line%% *}
    generation=${line#* }
  else
    out=
  fi
  # Nothing worth keeping: the model runs the drain itself. Output of a failed
  # drain is only an error unless it already presented unread status.
  if [ -z "$out" ] || [ ! -s "$out" ] \
    || { [ -z "$ack" ] && [ "$drain_rc" -ne 0 ] && ! grep -q '^UNREAD STATUS' "$out"; }; then
    [ -z "$out" ] || rm -f "$out" 2>/dev/null || true
    printf '%s\n' "$MODEL_DRAIN_LINE"
    return 0
  fi
  # A drain can print status sections it marks as shown (UNREAD STATUS) yet no
  # acknowledgement line, so captured output is never discarded for that alone.
  if [ "$(wc -c < "$out")" -gt "$DRAIN_DELIVERY_MAX" ] && mv -f "$out" "$DRAIN_OVERFLOW" 2>/dev/null; then
    if [ -n "$ack" ]; then
      printf 'The wake drain already ran, but its output is too large to carry here: read %s in full, handle it, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. %s\n' "$DRAIN_OVERFLOW" "$CONTINUITY_NOTE"
    else
      printf 'The wake drain already ran, but its output is too large to carry here and printed no acknowledgement command: read %s in full and handle it, then run bin/fm-wake-drain.sh yourself for anything still queued. %s\n' "$DRAIN_OVERFLOW" "$CONTINUITY_NOTE"
    fi
    return 0
  fi
  if [ -z "$ack" ]; then
    printf 'The wake drain already ran and its output follows (status it marks as shown is not printed again), but it printed no acknowledgement command: handle it, then run bin/fm-wake-drain.sh yourself for anything still queued. %s\n' "$CONTINUITY_NOTE"
    cat "$out"
    rm -f "$out" 2>/dev/null || true
    return 0
  fi
  nonce=fmwake-$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ "$stale" -eq 0 ] && [ "${#nonce}" -eq 23 ] && [ -n "$PROMPT_ID" ] && [ -r "$TRANSCRIPT" ] \
    && ticket=$(mktemp "$ACK_TICKET.tmp.XXXXXX") \
    && printf 'nonce=%s\nack=%s\ngeneration=%s\n' "$nonce" "$ack" "$generation" > "$ticket" \
    && mv -f "$ticket" "$ACK_TICKET"; then
    rm -f "$ACK_TICKET".settling.* 2>/dev/null || true
    printf 'The wake drain already ran (ticket %s) and its output follows: handle it without running bin/fm-wake-drain.sh or an --ack-through command. This hook acknowledges these wakes once this turn ends normally; an interrupted turn leaves them durable for re-handling. %s\n' "$nonce" "$CONTINUITY_NOTE"
    grep -v '^WAKE_ACK_REQUIRED:' "$out"
  else
    [ -z "${ticket:-}" ] || rm -f "$ticket" 2>/dev/null || true
    printf 'The wake drain already ran and its output follows: handle it, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. %s\n' "$CONTINUITY_NOTE"
    cat "$out"
  fi
  rm -f "$out" 2>/dev/null || true
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
    FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
      FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
      FM_WARM_COMPACT_TRANSCRIPT=$TRANSCRIPT \
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
  autoarm_exit_suppressed 'firstmate watcher auto-arm could not clear the resolved failure episode - a verified healthy watcher is running, but the episode reset was refused'
fi

# After either alarm writer has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  printf 'firstmate watcher auto-arm suppressed - the attended failure alarm is already committed for this episode, so this suppressed continuation emits no further rewake.\n' >&2
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
  {
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
  } >&2
  if autoarm_commit rewake; then
    # The exit status is committed: a signal from here on must not rewrite
    # the ledger, and only this winning generation drains.
    trap - HUP TERM INT
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    deliver_inline_drain >&2
    exit 2
  fi
  if [ "$HOST_MODE" -eq 1 ] && fm_autoarm_still_owner "$STATE" "$MY_GEN" \
    && fm_recovery_marker_snapshot "$STATE/.watcher-down" \
    && [[ "$FM_RECOVERY_MARKER_TOKEN" == pending:handling:* || "$FM_RECOVERY_MARKER_TOKEN" == announced:handling:* ]] \
    && ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    # No drain ran for this lost hand-back, so the turn runs its own.
    printf '%s\n' "$MODEL_DRAIN_LINE" >&2
    [ ! -e "$FAILURE_NOTICE" ] \
      || autoarm_exit_suppressed 'firstmate watcher auto-arm hand-back still uncommitted - the supervision host returned an actionable wake, but its rewake could not be committed, and the failure episode notice was already consumed'
    printf 'firstmate watcher auto-arm FAILED - the supervision host returned an actionable wake, but its rewake could not be committed.\n' >&2
    if autoarm_commit failed "$FAILURE_NOTICE"; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 2
    fi
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# The notice marker commits in the same owned critical section as the winning
# failed write, so a losing generation can neither consume nor deliver it.
# Later failures use autoarm_exit_suppressed's exhaustion decision below.
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
# Every later failure in the episode goes through the shared exhaustion
# decision, which commits the attended alarm once this session's block budget
# is burned (bin/fm-turnend-guard.sh --claude's terminal_fail_open is the other
# alarm writer; docs/turnend-guard.md names both and the owner-then-budget lock
# order they share).
autoarm_exit_suppressed 'firstmate watcher auto-arm still down - the automatic supervision mechanism remains broken in the recorded failure episode, whose notice was already consumed'
