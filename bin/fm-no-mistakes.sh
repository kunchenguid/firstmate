#!/usr/bin/env bash
# Drive one explicitly requested no-mistakes run under Firstmate's bounded policy.
#
# Usage:
#   fm-no-mistakes.sh run <task-id> --intent <user intent> [--skip <steps>]
#   fm-no-mistakes.sh respond <task-id> --action <approve|fix|skip> [axi respond flags]
#   fm-no-mistakes.sh status <task-id>
#
# The task must have mode=no-mistakes in state/<id>.meta and this command must run
# from that task's recorded worktree. This binds every drive call to the worker
# that owns the run; Firstmate relays keyed decisions back to that worker instead
# of issuing axi respond itself.
#
# A monotonic timestamp is captured immediately before the first `axi run` call.
# v1.53.0 does not expose the run's created_at through structured AXI, so this
# deliberately conservative pre-invocation timestamp is the deadline authority:
# startup overhead can stop a run early, never late. The timestamp and boot id are
# persisted in state/<id>.no-mistakes so later decision turns share one deadline.
#
# Every blocking AXI drive call runs in the foreground under the remaining time.
# On deadline expiry, or when a review gate returns after one authorized review
# fix, this helper aborts only a run id that AXI output authoritatively bound to
# this exact task branch. If the initial timed call returns no run id and branch,
# it refuses branch-unscoped discovery and abort. For a bound run it uses only
# `axi abort --run`, confirms a structured terminal outcome with `axi status --run`,
# then invokes guarded `axi sync --recover` to return branch custody without
# dropping correction commits. It never operates the daemon and never starts
# polling or a background process.
#
# Test hooks:
#   FM_NM_MONOTONIC_BIN prints integer monotonic milliseconds.
#   FM_NM_BOOT_ID overrides the current boot identity.
#   FM_NM_TIMEOUT_BIN overrides timeout/gtimeout (same CLI contract).
#   FM_NM_LIMIT_MS overrides 1200000 for fixtures only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LIMIT_MS=${FM_NM_LIMIT_MS:-1200000}
case "$LIMIT_MS" in ''|*[!0-9]*) echo "error: FM_NM_LIMIT_MS must be integer milliseconds" >&2; exit 2 ;; esac

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }
fail() { echo "error: $*" >&2; exit 2; }
field() { grep "^$1=" "$POLICY" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
meta_field() { grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

monotonic_ms() {
  if [ -n "${FM_NM_MONOTONIC_BIN:-}" ]; then "$FM_NM_MONOTONIC_BIN"; return; fi
  command -v node >/dev/null 2>&1 || fail "node is required for the monotonic deadline"
  node -e 'process.stdout.write(String(process.hrtime.bigint()/1000000n))'
}
boot_id() {
  if [ -n "${FM_NM_BOOT_ID:-}" ]; then printf '%s' "$FM_NM_BOOT_ID"; return; fi
  if [ -r /proc/sys/kernel/random/boot_id ]; then tr -d '\n' < /proc/sys/kernel/random/boot_id; return; fi
  if command -v sysctl >/dev/null 2>&1; then sysctl -n kern.boottime 2>/dev/null | tr -d '\n'; return; fi
  fail "cannot establish a stable boot identity for the monotonic deadline"
}
verify_bounded_profile() {
  local ref config head_config candidate
  ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -z "$ref" ]; then
    ref=
    for candidate in refs/heads/main refs/heads/master; do
      if git show-ref --verify --quiet "$candidate"; then ref=$candidate; break; fi
    done
  fi
  [ -n "$ref" ] || fail "cannot resolve the trusted default branch for the bounded NoMistakes profile"
  config=$(git show "$ref:.no-mistakes.yaml" 2>/dev/null || true)
  [ -n "$config" ] || fail "trusted default branch must configure agent: codex"
  printf '%s\n' "$config" | grep -Eq '^agent:[[:space:]]*codex[[:space:]]*(#.*)?$' \
    || fail "trusted default branch must use canonical agent: codex"
  head_config=$(git show HEAD:.no-mistakes.yaml 2>/dev/null || true)
  [ -n "$head_config" ] || fail "submitted HEAD must configure auto_fix.review: 0"
  printf '%s\n' "$head_config" | awk '
    /^[^[:space:]#][^:]*:/ { in_auto=0 }
    /^auto_fix:[[:space:]]*(#.*)?$/ { in_auto=1; next }
    in_auto && /^[[:space:]]+review:[[:space:]]*0[[:space:]]*(#.*)?$/ { review=1 }
    END { exit(review ? 0 : 1) }
  ' || fail "submitted HEAD must use canonical auto_fix.review: 0"
}

timeout_bin() {
  if [ -n "${FM_NM_TIMEOUT_BIN:-}" ]; then printf '%s' "$FM_NM_TIMEOUT_BIN"; return; fi
  if command -v timeout >/dev/null 2>&1; then command -v timeout; return; fi
  if command -v gtimeout >/dev/null 2>&1; then command -v gtimeout; return; fi
  fail "timeout or gtimeout is required for the hard wall-clock ceiling"
}
write_policy() {
  local tmp="$POLICY.tmp.$$"
  umask 077
  {
    echo "boot=$BOOT"
    echo "started_ms=$STARTED_MS"
    echo "deadline_ms=$DEADLINE_MS"
    echo "run_id=$RUN_ID"
    echo "bound_branch=$BOUND_BRANCH"
    echo "review_fix_used=$REVIEW_FIX_USED"
  } > "$tmp"
  mv "$tmp" "$POLICY"
}
parse_run_id() { printf '%s\n' "$1" | sed -n 's/^[[:space:]]*id:[[:space:]]*"\{0,1\}\([^"[:space:]]*\).*/\1/p' | head -1; }
parse_branch() { printf '%s\n' "$1" | sed -n 's/^[[:space:]]*branch:[[:space:]]*"\{0,1\}\([^"[:space:]]*\).*/\1/p' | head -1; }
bind_run_from_output() {
  local out=$1 candidate_id candidate_branch
  candidate_id=$(parse_run_id "$out")
  candidate_branch=$(parse_branch "$out")
  [ -n "$candidate_id" ] && [ -n "$candidate_branch" ] \
    || fail "AXI did not return a run id and branch; refusing branch-unscoped run discovery or abort"
  [ "$candidate_branch" = "$EXPECTED_BRANCH" ] \
    || fail "AXI run $candidate_id belongs to branch $candidate_branch, expected $EXPECTED_BRANCH; refusing abort"
  RUN_ID=$candidate_id
  BOUND_BRANCH=$candidate_branch
  write_policy
}
reject_auto_yes() {
  local arg
  for arg in "$@"; do
    case "$arg" in -y|--yes) fail "--yes is forbidden for Firstmate-managed no-mistakes runs" ;; esac
  done
}
has_review_gate() {
  printf '%s\n' "$1" | awk '
    /^gate:[[:space:]]*review[[:space:]]*$/ { found=1 }
    /^gate:[[:space:]]*$/ { nested=1; next }
    nested && /^[[:space:]]*step:[[:space:]]*review[[:space:]]*$/ { found=1 }
    END { exit(found ? 0 : 1) }
  '
}
structured_terminal() { printf '%s\n' "$1" | grep -Eq '^outcome:[[:space:]]*(cancelled|failed|passed)[[:space:]]*$'; }
load_policy() {
  [ -f "$POLICY" ] || fail "no bounded run record for task $ID"
  BOOT=$(field boot); STARTED_MS=$(field started_ms); DEADLINE_MS=$(field deadline_ms)
  RUN_ID=$(field run_id); BOUND_BRANCH=$(field bound_branch); REVIEW_FIX_USED=$(field review_fix_used)
  [ "$(boot_id)" = "$BOOT" ] || fail "the host rebooted; monotonic deadline custody requires manual reconciliation"
  case "$DEADLINE_MS:$REVIEW_FIX_USED" in *[!0-9:]*|:*|*:) fail "invalid bounded run record for task $ID" ;; esac
  [ -n "$RUN_ID" ] && [ "$BOUND_BRANCH" = "$EXPECTED_BRANCH" ] \
    || fail "bounded run record is not bound to task $ID on branch $EXPECTED_BRANCH"
}
remaining_ms() {
  local now remaining
  now=$(monotonic_ms)
  case "$now" in ''|*[!0-9]*) fail "monotonic clock returned a non-integer value" ;; esac
  remaining=$((DEADLINE_MS - now))
  [ "$remaining" -gt 0 ] || { echo 0; return; }
  echo "$remaining"
}
duration_for_ms() { local ms=$1; printf '%d.%03ds' "$((ms / 1000))" "$((ms % 1000))"; }
current_status() {
  [ -n "$RUN_ID" ] || fail "bounded run record has no branch-bound run id"
  no-mistakes axi status --run "$RUN_ID"
}
recover_and_report() {
  local reason=$1 evidence=${2:-} status_out abort_out sync_out head sync_rc=0
  if [ -z "$RUN_ID" ]; then
    bind_run_from_output "$evidence"
  fi
  [ "$BOUND_BRANCH" = "$EXPECTED_BRANCH" ] \
    || fail "$reason; run $RUN_ID is not authoritatively bound to branch $EXPECTED_BRANCH"
  status_out=$(no-mistakes axi status --run "$RUN_ID" 2>&1 || true)
  if ! structured_terminal "$status_out"; then
    abort_out=$(no-mistakes axi abort --run "$RUN_ID" 2>&1 || true)
    status_out=$(no-mistakes axi status --run "$RUN_ID" 2>&1 || true)
    structured_terminal "$status_out" || {
      printf '%s\n%s\n' "$abort_out" "$status_out" >&2
      fail "$reason; abort returned but structured AXI did not confirm a terminal run"
    }
  fi
  sync_out=$(no-mistakes axi sync --recover 2>&1) || sync_rc=$?
  head=$(git rev-parse HEAD 2>/dev/null || true)
  printf '%s\n' "$evidence"
  printf 'bounded_stop:\n  reason: "%s"\n  run: "%s"\n  preserved_head: "%s"\n  custody_recovery_exit: %s\n' "$reason" "$RUN_ID" "$head" "$sync_rc"
  printf '%s\n%s\n' "$status_out" "$sync_out"
  exit 75
}
drive() {
  local remaining duration timer out rc=0
  timer=$(timeout_bin)
  if [ "${INITIAL_DRIVE:-0}" -eq 1 ]; then
    STARTED_MS=$(monotonic_ms)
    case "$STARTED_MS" in ''|*[!0-9]*) fail "monotonic clock returned a non-integer value" ;; esac
    DEADLINE_MS=$((STARTED_MS + LIMIT_MS))
    write_policy
    remaining=$(remaining_ms)
    [ "$remaining" -gt 0 ] || recover_and_report "20-minute wall-clock ceiling reached before AXI startup"
    INITIAL_DRIVE=0
  else
    remaining=$(remaining_ms)
    [ "$remaining" -gt 0 ] || recover_and_report "20-minute wall-clock ceiling reached"
  fi
  duration=$(duration_for_ms "$remaining")
  out=$($timer --foreground "$duration" no-mistakes axi "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    recover_and_report "20-minute wall-clock ceiling reached" "$out"
  fi
  if [ -z "$RUN_ID" ]; then
    bind_run_from_output "$out"
  else
    write_policy
  fi
  if has_review_gate "$out" && [ "$REVIEW_FIX_USED" -eq 1 ]; then
    recover_and_report "review cycle limit reached after one fix and rereview" "$out"
  fi
  printf '%s\n' "$out"
  return "$rc"
}

CMD=${1:-}; ID=${2:-}
case "$CMD" in -h|--help|'') usage; exit 0 ;; run|respond|status) ;; *) fail "unknown command: $CMD" ;; esac
[ -n "$ID" ] || fail "task id is required"
case "$ID" in *[!A-Za-z0-9._-]*|'') fail "invalid task id" ;; esac
META="$STATE/$ID.meta"; POLICY="$STATE/$ID.no-mistakes"
[ -f "$META" ] || fail "missing task metadata: $META"
[ "$(meta_field kind)" = ship ] || fail "only ship tasks may run no-mistakes"
[ "$(meta_field mode)" = no-mistakes ] || fail "task $ID was not explicitly marked for no-mistakes"
WT=$(meta_field worktree); [ -n "$WT" ] || fail "task $ID has no recorded worktree"
[ "$(pwd -P)" = "$(cd "$WT" && pwd -P)" ] || fail "run this command from task $ID's recorded worktree"
EXPECTED_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$EXPECTED_BRANCH" ] || fail "task $ID must run from an attached branch"
shift 2

case "$CMD" in
  run)
    [ ! -e "$POLICY" ] || fail "bounded run already initialized; use respond or status"
    reject_auto_yes "$@"
    verify_bounded_profile
    case " $* " in *' --intent '*) ;; *) fail "run requires --intent" ;; esac
    BOOT=$(boot_id); RUN_ID=; BOUND_BRANCH=; REVIEW_FIX_USED=0
    STARTED_MS=; DEADLINE_MS=; INITIAL_DRIVE=1
    drive run "$@"
    ;;
  respond)
    load_policy
    reject_auto_yes "$@"
    remaining=$(remaining_ms)
    [ "$remaining" -gt 0 ] || recover_and_report "20-minute wall-clock ceiling reached"
    action=''; step=''
    prev=
    for arg in "$@"; do
      if [ "$prev" = action ]; then action=$arg; prev=; continue; fi
      if [ "$prev" = step ]; then step=$arg; prev=; continue; fi
      case "$arg" in --action) prev=action ;; --action=*) action=${arg#--action=} ;; --step) prev=step ;; --step=*) step=${arg#--step=} ;; esac
    done
    [ -n "$action" ] || fail "respond requires --action"
    status_before=$(current_status 2>&1 || true)
    if [ "$action" = fix ] && { [ "$step" = review ] || { [ -z "$step" ] && has_review_gate "$status_before"; }; }; then
      [ "$REVIEW_FIX_USED" -eq 0 ] || recover_and_report "review cycle limit reached before a second fix" "$status_before"
      REVIEW_FIX_USED=1
      write_policy
    fi
    drive respond "$@"
    ;;
  status)
    load_policy
    remaining=$(remaining_ms)
    printf 'bounded_policy:\n  remaining_ms: %s\n  review_fix_used: %s\n' "$remaining" "$REVIEW_FIX_USED"
    current_status
    ;;
esac
