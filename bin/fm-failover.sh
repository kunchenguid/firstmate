#!/usr/bin/env bash
# fm-failover.sh - preservation-first provider failover for one already-running
# OpenAI/Codex-routed direct report, keeping the same task identity, backend
# endpoint, isolated worktree, branch, commits, dirty bytes, and any existing
# no-mistakes run. This is the ONLY sanctioned relaunch path for an active
# worker's provider switch; docs/provider-failover.md owns the mechanism
# narrative and the backend-support evidence record, and the provider-failover
# skill owns the decision procedure around this script.
#
# Usage: fm-failover.sh <task-id> [--check-only] [--planned] [--reason <text>]
#   --check-only  print the deterministic eligibility verdict and evidence
#                 without mutating anything, then exit 0.
#   --planned     quota-pressure safe-checkpoint handoff: with no outage or
#                 dead-agent evidence, accept fresh usage telemetry at the
#                 handoff threshold (fm_failover_provider_pressure = handoff)
#                 as the evidence class, and switch ONLY at a safe checkpoint -
#                 a worker with an actively-running pipeline step or busy pane
#                 is never terminated on a threshold alone; the script defers
#                 (exit 6) and leaves everything intact for a later retry.
#   --reason      free-text context recorded in the append-only failover history.
#
# What it does, in order (each proof fails closed):
#   1. Refuse gate agents, secondmates, non-OpenAI routes (idempotent no-op),
#      unsupported backends, and a second concurrent failover of the same task.
#   2. Establish evidence the worker actually needs failover: provider
#      quota/rate-limit exhaustion in the pane or last status line, a
#      confidently dead agent process, or the watcher's accumulated
#      wedge-escalation count. A healthy worker, an intentionally parked
#      review decision, and a merely long-running pipeline are refused.
#   3. Atomically capture a durable preservation receipt under
#      data/<id>/failover/ (task identity, project, isolated-copy path, branch,
#      HEAD, working-copy status, recent commits, dirty-diff digest, active
#      no-mistakes run id/head/status/step, current route, endpoint, resume
#      context).
#   4. Prove the recorded isolated copy still exists, is a real worktree
#      distinct from the primary checkout, that no other recorded task's live
#      agent owns it, and that the endpoint shell sits in it.
#   5. Probe the destination ladder (claude claude-fable-5[1m], then pi
#      ollama/kimi-k2.7-code, then pi ollama/glm-5.2; OpenAI never) without
#      touching the preserved task; advance only past a genuinely unavailable
#      candidate, stop on an inconclusive probe.
#   6. Exit the old agent in place, write a resume prompt bound to the receipt
#      that instructs the new worker to inspect and continue the existing
#      no-mistakes run (never start or replace it), install the destination
#      harness's turn-end hook with the normal spawn semantics
#      (bin/fm-launch-lib.sh), and relaunch in the SAME endpoint and directory.
#   7. Verify the LIVE process command and model (not just configuration),
#      re-verify the preserved HEAD and dirty bytes, and only then atomically
#      update the task's recorded harness/model/effort and append the
#      append-only history record (data/<id>/failover/history).
# Failure at any point leaves all task work and every record intact.
#
# Generic dispatch preferences (config/crew-harness, config/crew-dispatch.json,
# config/secondmate-harness) are never read or written: this path recovers one
# active worker and changes nothing about future launches.
#
# Exit codes: 0 success or idempotent no-op; 1 blocker (proof failed, endpoint
# gone, inconclusive probe, old agent will not exit, preservation mismatch);
# 2 usage; 3 ineligible (healthy, parked review decision, long-running
# pipeline); 4 every allowed destination unavailable; 5 destination launched
# but live process verification failed (metadata deliberately left unchanged);
# 6 planned handoff deferred because the worker is not at a safe checkpoint.
#
# Tuning: FM_FAILOVER_PROBE_TIMEOUT (90s per candidate probe),
# FM_FAILOVER_EXIT_TIMEOUT (30s for the old agent to exit),
# FM_FAILOVER_VERIFY_TIMEOUT (45s for live-route verification),
# FM_FAILOVER_OUTAGE_RE / FM_FAILOVER_OUTAGE_TAIL_LINES (evidence signatures),
# FM_FAILOVER_CANDIDATES (ladder override; OpenAI entries are refused), and the
# usage-pressure thresholds owned by bin/fm-failover-lib.sh
# (FM_PROVIDER_SESSION_AVOID_PCT, FM_PROVIDER_SESSION_HANDOFF_PCT,
# FM_PROVIDER_WEEK_AVOID_PCT, FM_PROVIDER_USAGE_MAX_AGE_SECS).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() { awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "$0"; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-launch-lib.sh
. "$SCRIPT_DIR/fm-launch-lib.sh"
# shellcheck source=bin/fm-failover-lib.sh
. "$SCRIPT_DIR/fm-failover-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
"$FM_ROOT/bin/fm-guard.sh" || true

ID=
CHECK_ONLY=0
PLANNED=0
REASON=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --planned) PLANNED=1 ;;
    --reason) shift; [ "$#" -gt 0 ] || { echo "error: --reason requires a value" >&2; exit 2; }; REASON=$1 ;;
    --*) echo "error: unknown flag $1" >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { echo "error: exactly one task id expected" >&2; exit 2; }
      ID=$1
      ;;
  esac
  shift
done
[ -n "$ID" ] || { usage >&2; exit 2; }
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no metadata for task $ID at $META" >&2; exit 1; }

KIND=$(fm_meta_get "$META" kind)
[ -n "$KIND" ] || KIND=ship
if [ "$KIND" = secondmate ]; then
  echo "error: task $ID is a secondmate; provider failover covers ordinary direct reports only (load secondmate-provisioning instead)" >&2
  exit 1
fi

BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
[ -n "$TARGET" ] || { echo "error: no backend target recorded in $META" >&2; exit 1; }
LABEL="fm-$ID"
fm_failover_backend_supported "$BACKEND" || exit 1
fm_backend_source "$BACKEND" || exit 1

FROM_HARNESS=$(fm_meta_get "$META" harness)
FROM_MODEL=$(fm_meta_get "$META" model)
[ -n "$FROM_MODEL" ] || FROM_MODEL=default
FROM_EFFORT=$(fm_meta_get "$META" effort)
[ -n "$FROM_EFFORT" ] || FROM_EFFORT=default

# Nested pipeline-agent inspection: a No Mistakes step can own a live native
# agent subprocess (e.g. `codex exec resume`) under an outer worker on a
# different provider, so the pipeline agent's route is inspected and reported
# separately from the outer route, and is never interrupted by this path.
nested_agents_summary() {
  local rows
  rows=$(fm_failover_nested_agents "$BACKEND" "$TARGET" "$FROM_HARNESS" 2>/dev/null) || { printf 'unreadable'; return 0; }
  [ -n "$rows" ] || { printf 'none'; return 0; }
  printf '%s' "$rows" | awk -F '\t' '{printf "%s%s:%s", (NR > 1 ? ";" : ""), $1, $2}'
}

if ! fm_failover_route_is_openai "$META"; then
  echo "no-op: task $ID route $FROM_HARNESS:$FROM_MODEL is not OpenAI/Codex-backed; nothing to fail over (live pipeline-owned agent subprocesses: $(nested_agents_summary))"
  exit 0
fi

WT=$(fm_meta_get "$META" worktree)
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  echo "error: recorded isolated copy for $ID is gone ($WT); failover preserves an existing copy - load stuck-crewmate-recovery instead" >&2
  exit 1
fi

FAILOVER_LOCK="$STATE/.failover-$ID.lock"
FAILOVER_LOCK_HELD=0
PROBE_DIR=
failover_cleanup() {
  local status=$?
  [ -z "$PROBE_DIR" ] || rm -rf "$PROBE_DIR"
  PROBE_DIR=
  if [ "$FAILOVER_LOCK_HELD" = 1 ]; then
    FAILOVER_LOCK_HELD=0
    fm_lock_release "$FAILOVER_LOCK" || true
  fi
  return "$status"
}
trap failover_cleanup EXIT
if [ "$CHECK_ONLY" -ne 1 ]; then
  if ! fm_lock_try_acquire "$FAILOVER_LOCK"; then
    echo "error: another failover is already handling task $ID" >&2
    exit 1
  fi
  FAILOVER_LOCK_HELD=1
fi

# Bounded external command, mirroring fm-crew-state.sh's nm_run shape.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
bounded_run() {  # <seconds> <cmd...>
  local secs=$1
  shift
  case "$HAVE_TIMEOUT" in
    timeout)  timeout "$secs" "$@" ;;
    gtimeout) gtimeout "$secs" "$@" ;;
    perl)     perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit(($? >> 8) || ($? & 127 ? 128 + ($? & 127) : 0))' "$secs" "$@" ;;
    *)        "$@" ;;
  esac
}

# --- evidence ---------------------------------------------------------------

AGENT_ALIVE=$(fm_backend_agent_alive "$BACKEND" "$TARGET" 2>/dev/null) || AGENT_ALIVE=unknown
if ! TAIL40=$(fm_backend_capture "$BACKEND" "$TARGET" 40 "$LABEL" 2>/dev/null); then
  echo "error: recorded endpoint $TARGET is unreadable or gone; same-endpoint failover is impossible - load stuck-crewmate-recovery instead" >&2
  exit 1
fi
LAST_STATUS=$(last_status_line "$STATE/$ID.status")
OUTAGE_EVIDENCE=$(fm_failover_outage_evidence "$TAIL40" || true)
[ -n "$OUTAGE_EVIDENCE" ] || OUTAGE_EVIDENCE=$(fm_failover_outage_evidence "$LAST_STATUS" || true)
WEDGE_KEY=$(printf '%s' "$TARGET" | tr ':/.' '___')
WEDGE_COUNT=$(cat "$STATE/.wedge-escalations-$WEDGE_KEY" 2>/dev/null || echo 0)
case "$WEDGE_COUNT" in ''|*[!0-9]*) WEDGE_COUNT=0 ;; esac
WEDGE_THRESHOLD=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

EVIDENCE=
EVIDENCE_DETAIL=
if [ -n "$OUTAGE_EVIDENCE" ]; then
  EVIDENCE=outage
  EVIDENCE_DETAIL=$OUTAGE_EVIDENCE
elif [ "$AGENT_ALIVE" = dead ]; then
  EVIDENCE=dead
  EVIDENCE_DETAIL="agent process confidently dead at $TARGET"
elif [ "$WEDGE_COUNT" -ge "$WEDGE_THRESHOLD" ]; then
  EVIDENCE=wedge
  EVIDENCE_DETAIL="watcher wedge escalations: $WEDGE_COUNT (threshold $WEDGE_THRESHOLD)"
elif [ "$PLANNED" = 1 ]; then
  # Planned safe-checkpoint handoff: fresh usage telemetry at the handoff
  # threshold is the evidence class. Stale or unknown telemetry never
  # qualifies - and never releases a hold - so a quiet quota cache cannot
  # trigger or suppress a switch on its own.
  FROM_PROVIDER_FOR_PRESSURE=$(fm_failover_provider_of_route "$FROM_HARNESS" "$FROM_MODEL")
  PRESSURE_LINE=$(fm_failover_provider_pressure "$STATE" "$FROM_PROVIDER_FOR_PRESSURE" "$FROM_MODEL")
  if [ "${PRESSURE_LINE%% *}" = handoff ]; then
    EVIDENCE=pressure
    EVIDENCE_DETAIL=$PRESSURE_LINE
  fi
fi

CREW_STATE_LINE=$("$FM_CREW_STATE_BIN" "$ID" 2>/dev/null || true)
CREW_STATE=${CREW_STATE_LINE#state: }
CREW_STATE=${CREW_STATE%% *}

ineligible() {  # <reason>
  if [ "$CHECK_ONLY" = 1 ]; then
    echo "ineligible $ID reason=$1"
    exit 0
  fi
  echo "error: task $ID is not eligible for failover: $1" >&2
  exit 3
}

if [ -z "$EVIDENCE" ]; then
  if [ "$PLANNED" = 1 ]; then
    ineligible "planned handoff requires fresh usage telemetry at the handoff threshold (${PRESSURE_LINE:-no telemetry}); no outage, dead-agent, or wedge evidence either"
  fi
  ineligible "no provider-outage evidence, agent not confidently dead, wedge escalations $WEDGE_COUNT below threshold $WEDGE_THRESHOLD (healthy worker; state: ${CREW_STATE:-unknown})"
fi
# An intentionally parked review decision is never failed over on wedge
# pressure alone: the pipeline is waiting for a response, not broken. Verified
# provider exhaustion or a dead agent still qualifies - a quota-dead worker
# cannot answer its own gate.
if [ "$CREW_STATE" = parked ] && [ "$EVIDENCE" = wedge ]; then
  ineligible "run is parked at a review decision (intentional wait); wedge pressure alone does not justify a provider switch"
fi
# A pipeline that is merely long-running (an actively working run) is not
# failed over on wedge pressure alone either.
if [ "$CREW_STATE" = working ] && [ "$EVIDENCE" = wedge ]; then
  ineligible "run is actively working (long-running pipeline); wedge pressure alone does not justify a provider switch"
fi
# Safe-checkpoint gate for a planned quota-pressure handoff: never terminate
# or switch a worker that owns an actively-running pipeline step or busy pane
# merely because a threshold was crossed - defer and leave everything intact.
if [ "$EVIDENCE" = pressure ] && [ "$CHECK_ONLY" != 1 ]; then
  pane_busy=0
  if printf '%s' "$TAIL40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-${FM_TMUX_BUSY_REGEX_DEFAULT:-esc (to )?interrupt|Working\\.\\.\\.|Ctrl\\+c:cancel}}"; then
    pane_busy=1
  fi
  if [ "$CREW_STATE" = working ] || [ "$pane_busy" = 1 ]; then
    echo "deferred: task $ID is not at a safe checkpoint (state: ${CREW_STATE:-unknown}, busy pane: $pane_busy); planned handoff left everything intact - retry at the next heartbeat" >&2
    exit 6
  fi
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo "eligible $ID evidence=$EVIDENCE route=$FROM_HARNESS:$FROM_MODEL crew_state=${CREW_STATE:-unknown} nested_agents=$(nested_agents_summary) detail=$EVIDENCE_DETAIL"
  exit 0
fi

# Verified provider exhaustion creates a durable hold immediately - before any
# switch work - so NEW launches on the exhausted provider are refused even if
# quota-cache data is stale, until bin/fm-provider-hold.sh verifies recovery.
if [ "$EVIDENCE" = outage ]; then
  FROM_PROVIDER=$(fm_failover_provider_of_route "$FROM_HARNESS" "$FROM_MODEL")
  "$SCRIPT_DIR/fm-provider-hold.sh" set "$FROM_PROVIDER" --task "$ID" --evidence "$EVIDENCE_DETAIL" \
    || echo "warning: could not record provider hold for $FROM_PROVIDER" >&2
fi

# --- preservation receipt ---------------------------------------------------

WT_REAL=$(cd "$WT" 2>/dev/null && pwd -P) || { echo "error: isolated copy $WT is unreadable" >&2; exit 1; }
PROJ=$(fm_meta_get "$META" project)
PROJ_REAL=$(cd "$PROJ" 2>/dev/null && pwd -P) || PROJ_REAL=$PROJ
WT_TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
WT_TOP_REAL=$(cd "$WT_TOP" 2>/dev/null && pwd -P) || WT_TOP_REAL=
if [ -z "$WT_TOP_REAL" ] || [ "$WT_TOP_REAL" != "$WT_REAL" ] || [ "$WT_REAL" = "$PROJ_REAL" ]; then
  echo "error: recorded isolated copy failed the isolation proof (copy '$WT', worktree root '${WT_TOP:-none}', primary '$PROJ'); refusing to touch it" >&2
  exit 1
fi

BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'DETACHED')
HEAD=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || { echo "error: cannot read HEAD in $WT" >&2; exit 1; }
PORCELAIN=$(git -C "$WT" status --porcelain 2>/dev/null || true)
RECENT_COMMITS=$(git -C "$WT" log --oneline -20 2>/dev/null || true)
failover_hash_stream() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else cksum | awk '{print $1}'
  fi
}
dirty_digest() {
  git -C "$WT" diff HEAD 2>/dev/null | failover_hash_stream 2>/dev/null
}
DIRTY_SHA=$(dirty_digest)

NM_RUN_ID=
NM_RUN_HEAD=
NM_RUN_STATUS=
NM_RUN_STEP=
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
if [ "$KIND" = ship ] && [ "$BRANCH" != DETACHED ] && command -v no-mistakes >/dev/null 2>&1; then
  NM_OUT=$( (cd "$WT" && bounded_run "$NM_TIMEOUT" no-mistakes axi status) 2>/dev/null || true)
  if [ -n "$NM_OUT" ]; then
    nm_field() { printf '%s\n' "$NM_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1 | sed 's/^"\(.*\)"$/\1/'; }
    NM_BRANCH=$(nm_field branch)
    if [ "$NM_BRANCH" = "$BRANCH" ]; then
      NM_RUN_ID=$(nm_field id)
      NM_RUN_HEAD=$(nm_field head)
      NM_RUN_STATUS=$(nm_field status)
      NM_RUN_STEP=$(printf '%s\n' "$NM_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(running|fixing|awaiting_approval|fix_review)"?[[:space:]]*,' | head -1 | sed 's/^[[:space:]]*//; s/,.*//')
    fi
  fi
fi

FAILOVER_DIR="$DATA/$ID/failover"
mkdir -p "$FAILOVER_DIR" || { echo "error: cannot create $FAILOVER_DIR" >&2; exit 1; }
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
RECEIPT="$FAILOVER_DIR/receipt-$STAMP.md"
RECEIPT_TMP=$(mktemp "$FAILOVER_DIR/.receipt.XXXXXX") || exit 1
{
  echo "# Provider-failover preservation receipt (fm-failover-receipt v1)"
  echo
  echo "- task: $ID"
  echo "- captured_at: $STAMP (epoch $(date +%s))"
  echo "- project: $PROJ"
  echo "- isolated_copy: $WT"
  echo "- isolated_copy_real: $WT_REAL"
  echo "- branch: $BRANCH"
  echo "- head: $HEAD"
  echo "- dirty_diff_sha256: ${DIRTY_SHA:-none}"
  echo "- nm_run_id: ${NM_RUN_ID:-none}"
  echo "- nm_run_head: ${NM_RUN_HEAD:-none}"
  echo "- nm_run_status: ${NM_RUN_STATUS:-none}"
  echo "- nm_run_step: ${NM_RUN_STEP:-none}"
  echo "- from_harness: $FROM_HARNESS"
  echo "- from_model: $FROM_MODEL"
  echo "- from_effort: $FROM_EFFORT"
  echo "- backend: $BACKEND"
  echo "- endpoint: $TARGET"
  echo "- kind: $KIND"
  echo "- mode: $(fm_meta_get "$META" mode)"
  echo "- brief: $DATA/$ID/brief.md"
  echo "- evidence: $EVIDENCE"
  echo "- evidence_detail: $EVIDENCE_DETAIL"
  echo "- reason: ${REASON:-none}"
  echo
  echo "## Working-copy status (git status --porcelain)"
  echo
  if [ -n "$PORCELAIN" ]; then printf '%s\n' "$PORCELAIN" | sed 's/^/    /'; else echo "    (clean)"; fi
  echo
  echo "## Recent commits (git log --oneline -20)"
  echo
  printf '%s\n' "$RECENT_COMMITS" | sed 's/^/    /'
  echo
  echo "## Last status line"
  echo
  printf '    %s\n' "${LAST_STATUS:-none}"
} > "$RECEIPT_TMP" || { rm -f "$RECEIPT_TMP"; echo "error: cannot write receipt" >&2; exit 1; }
mv "$RECEIPT_TMP" "$RECEIPT" || { rm -f "$RECEIPT_TMP"; echo "error: cannot publish receipt" >&2; exit 1; }
grep -qF -- "- task: $ID" "$RECEIPT" || { echo "error: receipt readback failed at $RECEIPT" >&2; exit 1; }

# --- ownership proof: no second live agent owns this copy -------------------

for other_meta in "$STATE"/*.meta; do
  [ -e "$other_meta" ] || continue
  [ "$other_meta" != "$META" ] || continue
  other_wt=$(fm_meta_get "$other_meta" worktree)
  [ -n "$other_wt" ] || continue
  other_real=$(cd "$other_wt" 2>/dev/null && pwd -P) || continue
  [ "$other_real" = "$WT_REAL" ] || continue
  other_target=$(fm_backend_target_of_meta "$other_meta")
  other_backend=$(fm_backend_of_meta "$other_meta")
  other_alive=$(fm_backend_agent_alive "$other_backend" "$other_target" 2>/dev/null) || other_alive=unknown
  if [ "$other_alive" != dead ]; then
    echo "error: a second recorded task ($(basename "$other_meta" .meta)) claims the same isolated copy and its agent is $other_alive; refusing to relaunch until ownership is reconciled" >&2
    exit 1
  fi
done

# --- candidate probing ------------------------------------------------------

PROBE_TIMEOUT=${FM_FAILOVER_PROBE_TIMEOUT:-90}
case "$PROBE_TIMEOUT" in ''|*[!0-9]*) PROBE_TIMEOUT=90 ;; esac
PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-failover-probe.XXXXXX") || exit 1
PROBE_OUT=
PROBE_VERDICT=
probe_candidate() {  # <harness> <model> -> sets PROBE_VERDICT and PROBE_OUT
  local harness=$1 model=$2 code=0
  PROBE_OUT=
  PROBE_VERDICT=
  case "$harness" in
    claude)
      PROBE_OUT=$( (cd "$PROBE_DIR" && bounded_run "$PROBE_TIMEOUT" claude --model "$model" -p 'Reply with exactly OK.') 2>&1 ) || code=$?
      ;;
    pi)
      PROBE_OUT=$( (cd "$PROBE_DIR" && bounded_run "$PROBE_TIMEOUT" pi --print --model "$model" 'Reply with exactly OK.') 2>&1 ) || code=$?
      ;;
    *)
      echo "error: no verified availability probe for harness '$harness'" >&2
      return 1
      ;;
  esac
  PROBE_VERDICT=$(fm_failover_probe_classify "$code" "$PROBE_OUT")
}

TO_HARNESS=
TO_MODEL=
CANDIDATES=$(fm_failover_candidates) || exit 1
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  c_harness=${candidate%%:*}
  c_model=${candidate#*:}
  c_provider=$(fm_failover_provider_of_route "$c_harness" "$c_model")
  if fm_failover_provider_held "$STATE" "$c_provider"; then
    echo "candidate $candidate: provider $c_provider is held after verified exhaustion; advancing" >&2
    continue
  fi
  # A PLANNED handoff also respects destination quota pressure (rebalancing
  # must not pile onto a nearly-exhausted provider); emergency recovery from
  # outage/dead/wedge evidence uses any non-held available candidate.
  if [ "$EVIDENCE" = pressure ]; then
    c_pressure=$(fm_failover_provider_pressure "$STATE" "$c_provider" "$c_model")
    case "${c_pressure%% *}" in
      avoid|handoff)
        echo "candidate $candidate: provider $c_provider under quota pressure ($c_pressure); advancing" >&2
        continue
        ;;
    esac
  fi
  if ! command -v "$c_harness" >/dev/null 2>&1; then
    echo "candidate $candidate: CLI not installed; advancing" >&2
    continue
  fi
  probe_candidate "$c_harness" "$c_model" || exit 1
  case "$PROBE_VERDICT" in
    available)
      TO_HARNESS=$c_harness
      TO_MODEL=$c_model
      break
      ;;
    unavailable)
      echo "candidate $candidate: unavailable ($(printf '%s' "$PROBE_OUT" | head -1 | cut -c1-160)); advancing" >&2
      ;;
    *)
      echo "error: probe of candidate $candidate failed inconclusively (evidence: $(printf '%s' "$PROBE_OUT" | head -3 | tr '\n' ' ' | cut -c1-300)); stopping rather than advancing past a provider that may be fine" >&2
      exit 1
      ;;
  esac
done <<EOF
$CANDIDATES
EOF
rm -rf "$PROBE_DIR"
PROBE_DIR=

if [ -z "$TO_HARNESS" ]; then
  echo "error: every allowed failover destination is unavailable; task $ID, its isolated copy, records, and current worker are left intact - captain decision needed (candidates tried: $(printf '%s' "$CANDIDATES" | tr '\n' ' '))" >&2
  exit 4
fi

# --- exit the old agent in place -------------------------------------------

# Preserve live pipeline-owned agent subprocesses: exiting the outer agent
# while a nested agent (e.g. a No Mistakes step's `codex exec resume`) is
# still running inside this endpoint could kill it mid-review. Refuse and
# report; the pipeline step finishes on its own and is never interrupted or
# restarted here.
NESTED_ROWS=$(fm_failover_nested_agents "$BACKEND" "$TARGET" "$FROM_HARNESS" 2>/dev/null || true)
if [ -n "$NESTED_ROWS" ]; then
  echo "error: live pipeline-owned agent subprocess(es) are running inside this endpoint and must not be interrupted:" >&2
  printf '%s\n' "$NESTED_ROWS" | awk -F '\t' '{printf "  - %s (model %s): %s\n", $1, $2, substr($3, 1, 160)}' >&2
  echo "wait for the pipeline step to finish (or handle the run through its own gate flow), then retry; task, records, and subprocesses left intact (receipt: $RECEIPT)" >&2
  exit 1
fi

EXIT_TIMEOUT=${FM_FAILOVER_EXIT_TIMEOUT:-30}
case "$EXIT_TIMEOUT" in ''|*[!0-9]*) EXIT_TIMEOUT=30 ;; esac
if [ "$AGENT_ALIVE" != dead ]; then
  EXIT_CMD=$(fm_failover_exit_command "$FROM_HARNESS") || {
    echo "error: no verified exit command for harness '$FROM_HARNESS'" >&2
    exit 1
  }
  # Interrupt any running turn first (harness-adapters: Escape for the
  # verified OpenAI-routed adapters), then submit the exit command with the
  # backend's verified retry.
  fm_backend_send_key "$BACKEND" "$TARGET" Escape "$LABEL" 2>/dev/null || true
  sleep 1
  fm_backend_send_text_submit "$BACKEND" "$TARGET" "$EXIT_CMD" "${FM_SEND_RETRIES:-3}" "${FM_SEND_SLEEP:-0.4}" 1.2 "$LABEL" >/dev/null 2>&1 || true
  waited=0
  while [ "$waited" -lt "$EXIT_TIMEOUT" ]; do
    AGENT_ALIVE=$(fm_backend_agent_alive "$BACKEND" "$TARGET" 2>/dev/null) || AGENT_ALIVE=unknown
    [ "$AGENT_ALIVE" = dead ] && break
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$AGENT_ALIVE" != dead ]; then
    echo "error: the current $FROM_HARNESS agent at $TARGET did not exit within ${EXIT_TIMEOUT}s (state: $AGENT_ALIVE); task left intact - inspect the endpoint before retrying" >&2
    exit 1
  fi
fi

# Same-directory proof: the endpoint shell must sit in the preserved copy.
PANE_PATH=$(fm_launch_current_path "$BACKEND" "$TARGET" "$LABEL" 2>/dev/null || true)
PANE_REAL=$(cd "$PANE_PATH" 2>/dev/null && pwd -P) || PANE_REAL=
if [ "$PANE_REAL" != "$WT_REAL" ]; then
  echo "error: endpoint shell is at '${PANE_PATH:-unreadable}', not the preserved isolated copy '$WT'; refusing to relaunch elsewhere" >&2
  exit 1
fi

# --- resume prompt bound to the receipt ------------------------------------

RESUME="$FAILOVER_DIR/resume-$STAMP.md"
DIRTY_SUMMARY=clean
[ -z "$PORCELAIN" ] || DIRTY_SUMMARY="dirty ($(printf '%s\n' "$PORCELAIN" | grep -c .) entries)"
RESUME_TMP=$(mktemp "$FAILOVER_DIR/.resume.XXXXXX") || exit 1
{
  echo "You are resuming task $ID after a provider failover from $FROM_HARNESS/$FROM_MODEL. This is the SAME task and the SAME pipeline, not a new task and not a new pipeline run."
  echo
  echo "Preservation receipt: $RECEIPT"
  echo
  echo "Preserved identity you must verify before any other action:"
  echo
  echo "- Task: $ID"
  echo "- Isolated copy: $WT"
  echo "- Branch: $BRANCH"
  echo "- HEAD: $HEAD"
  echo "- Working copy: $DIRTY_SUMMARY"
  echo "- Existing no-mistakes run: ${NM_RUN_ID:-none} (status ${NM_RUN_STATUS:-none}, step ${NM_RUN_STEP:-none})"
  echo
  echo "Steps:"
  echo
  echo "1. Run pwd -P, git branch/rev-parse HEAD, and git status; every value must match the receipt exactly. On any mismatch append 'blocked: failover identity mismatch <detail>' to the status file named in the original instructions and stop."
  echo "2. Read the original instructions at $DATA/$ID/brief.md - the task contract, status protocol, and definition of done are unchanged."
  if [ -n "$NM_RUN_ID" ]; then
    echo "3. Inspect the existing no-mistakes run with 'no-mistakes axi status' and continue THAT run through its own gate flow as its help directs. Never abort, restart, or start a new run; never reset, stash, clean, rebase, or switch branches; never allocate another copy. If the exact run cannot be continued, append 'blocked:' with that evidence instead of replacing it."
  else
    echo "3. No pipeline run is recorded for this task yet; continue the task work itself. Never reset, stash, clean, rebase, or switch branches; never allocate another copy."
  fi
  echo "4. Append 'resolved: provider failover to $TO_HARNESS/$TO_MODEL resumed this task' once the identity above is verified and work is under way, then continue under the original instructions."
} > "$RESUME_TMP" || { rm -f "$RESUME_TMP"; echo "error: cannot write resume prompt" >&2; exit 1; }
mv "$RESUME_TMP" "$RESUME" || { rm -f "$RESUME_TMP"; echo "error: cannot publish resume prompt" >&2; exit 1; }

# --- relaunch in the same endpoint and directory ----------------------------

mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
fm_launch_install_turnend_hook "$TO_HARNESS" "$WT" "$STATE" "$ID" "$TURNEND"

# Captain's standing Fable rule (fm_launch_fable_effort_cap): a Fable
# destination runs at normal speed and at most effort high; the recorded
# effort below uses the same capped value so metadata matches the live launch.
TO_EFFORT=$(fm_launch_fable_effort_cap "$TO_HARNESS" "$TO_MODEL" "$FROM_EFFORT")
LAUNCH=$(fm_launch_template "$TO_HARNESS" "$KIND") || {
  echo "error: no launch template for destination harness '$TO_HARNESS'" >&2
  exit 1
}
LAUNCH=$(fm_launch_render "$LAUNCH" "$TO_HARNESS" "$TO_MODEL" "$TO_EFFORT" \
  "$RESUME" "$TURNEND" "$STATE/$ID.pi-ext.ts" \
  "$WT/.pi/extensions/fm-primary-turnend-guard.ts" \
  "$WT/.pi/extensions/fm-primary-pi-watch.ts")

TASK_TMP=$(fm_meta_get "$META" tasktmp)
[ -n "$TASK_TMP" ] || TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp" 2>/dev/null || true
fm_launch_send_text_line "$BACKEND" "$TARGET" "export GOTMPDIR=$TASK_TMP/gotmp" "$LABEL"
sleep 0.3
fm_launch_send_literal "$BACKEND" "$TARGET" "$LAUNCH" "$LABEL"
sleep 0.3
fm_launch_send_key "$BACKEND" "$TARGET" Enter "$LABEL"

# --- live verification ------------------------------------------------------

VERIFY_TIMEOUT=${FM_FAILOVER_VERIFY_TIMEOUT:-45}
case "$VERIFY_TIMEOUT" in ''|*[!0-9]*) VERIFY_TIMEOUT=45 ;; esac
LIVE_ARGS=
waited=0
while [ "$waited" -lt "$VERIFY_TIMEOUT" ]; do
  LIVE_ARGS=$(fm_failover_live_route_verified "$BACKEND" "$TARGET" "$TO_HARNESS" "$TO_MODEL" 2>/dev/null || true)
  [ -n "$LIVE_ARGS" ] && break
  sleep 1
  waited=$((waited + 1))
done
if [ -z "$LIVE_ARGS" ]; then
  echo "error: destination $TO_HARNESS/$TO_MODEL was launched at $TARGET but no live process running that harness and model could be verified within ${VERIFY_TIMEOUT}s; task metadata deliberately left unchanged - inspect the endpoint (receipt: $RECEIPT)" >&2
  exit 5
fi

HEAD2=$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)
DIRTY_SHA2=$(dirty_digest)
if [ "$HEAD2" != "$HEAD" ] || [ "$DIRTY_SHA2" != "$DIRTY_SHA" ]; then
  echo "error: preserved state changed during failover (HEAD $HEAD -> ${HEAD2:-unreadable}, dirty digest ${DIRTY_SHA:-none} -> ${DIRTY_SHA2:-none}); a live $TO_HARNESS agent is running at $TARGET but task metadata was NOT updated - reconcile before anything else (receipt: $RECEIPT)" >&2
  exit 1
fi

# --- atomic route update + append-only history ------------------------------

META_TMP=$(mktemp "$STATE/.meta-failover.XXXXXX") || exit 1
awk -v h="$TO_HARNESS" -v m="$TO_MODEL" -v e="$TO_EFFORT" '
  /^harness=/ { print "harness=" h; seen_h=1; next }
  /^model=/   { print "model=" m; seen_m=1; next }
  /^effort=/  { print "effort=" e; seen_e=1; next }
  { print }
  END {
    if (!seen_h) print "harness=" h
    if (!seen_m) print "model=" m
    if (!seen_e) print "effort=" e
  }' "$META" > "$META_TMP" || { rm -f "$META_TMP"; echo "error: cannot rewrite task metadata" >&2; exit 1; }
mv "$META_TMP" "$META" || { rm -f "$META_TMP"; echo "error: cannot publish task metadata" >&2; exit 1; }

VERIFY_SUMMARY="live process args: $(printf '%s' "$LIVE_ARGS" | head -1 | cut -c1-200); head unchanged $HEAD; dirty digest unchanged ${DIRTY_SHA:-none}"
printf '%s %s from=%s:%s:%s to=%s:%s:%s evidence=%s receipt=%s reason=%s verify=%s\n' \
  "$(date +%s)" "$ID" \
  "$FROM_HARNESS" "$FROM_MODEL" "$FROM_EFFORT" \
  "$TO_HARNESS" "$TO_MODEL" "$TO_EFFORT" \
  "$EVIDENCE" "$RECEIPT" "${REASON:-none}" "$VERIFY_SUMMARY" \
  >> "$FAILOVER_DIR/history"

TO_PROVIDER=$TO_HARNESS
case "$TO_HARNESS:$TO_MODEL" in
  claude:*) TO_PROVIDER=anthropic ;;
  pi:ollama/*) TO_PROVIDER=ollama ;;
esac
echo "failed-over $ID provider=$TO_PROVIDER harness=$TO_HARNESS model=$TO_MODEL effort=$TO_EFFORT window=$TARGET worktree=$WT nm_run=${NM_RUN_ID:-none} receipt=$RECEIPT"
