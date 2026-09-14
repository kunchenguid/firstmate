#!/usr/bin/env bash
# fm-smoke.sh - exercise six lifecycle owners in an isolated Herdr lab.
#
# Usage: fm-smoke.sh [-h]
#
# Creates a fresh private home, state, data, config, and copied toolbelt for one
# named non-default Herdr lab. The six stages delegate to fm-session-start,
# fm-spawn, fm-send, fm-wake-drain, fm-pr-check, and fm-teardown respectively.
# Success is not independent proof of backend correctness, watcher continuity,
# or cleanup safety: those guarantees remain with their existing owners.
# No scheduler or context monitor is installed.
#
# Each stage prints:
#   stage=<name> result=pass|fail|skipped ms=<n> budget_ms=<n> detail=<one line>
# and appends a timestamped JSON row with those fields to the private lab ledger.
# Each invoked owner also prints owner=<script> exit_code=<n> ms=<n>.
# Exact owner exits and durations are retained in evidence/owners.jsonl under
# the printed private evidence directory; stage results include local checks.
# The complete session-start stdout is retained there so diagnostic evidence is
# not lost to an evidence bound; other owner captures remain bounded.
# Failed prerequisites skip downstream mutation but still attempt cleanup.
# Budgets bound owner calls via fm-timeout-lib; setup and cleanup overhead are
# measured, not a hard end-to-end deadline. Success requires cleanup.
#
# Environment (all optional):
#   FM_SMOKE_BUDGET_SESSION_START_MS  default 120000
#   FM_SMOKE_BUDGET_SPAWN_MS          default 120000
#   FM_SMOKE_BUDGET_STEER_MS          default 60000
#   FM_SMOKE_BUDGET_WAKE_MS           default 90000
#   FM_SMOKE_BUDGET_PR_MS             default 30000
#   FM_SMOKE_BUDGET_TEARDOWN_MS       default 90000
#   FM_SMOKE_PR_URL                   PR URL passed to fm-pr-check; skipped when unset
#   FM_SMOKE_BIN                      source toolbelt directory (default: this bin/)
#   FM_SMOKE_TASK_ID                  task id inside the fresh lab (default: smoke-<pid>-<random>)
#   HERDR_LAB_HELPER                  guarded lab helper (default: <bin>/fm-herdr-lab.sh)
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_BIN=${FM_SMOKE_BIN:-$SCRIPT_DIR}
CALLER_HOME=$(cd "$SCRIPT_DIR/.." && pwd)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$SOURCE_BIN/fm-herdr-lab.sh}
TASK=${FM_SMOKE_TASK_ID:-smoke-$$-$RANDOM}
NONCE="smoke-${TASK}-${RANDOM}"
LAB_ROOT=
LAB_HOME=
LAB_STATE=
LAB_DATA=
LAB_CONFIG=
LAB_BIN=
TELEMETRY=
HERDR_LAB_SESSION=
SPAWN_GEN=
META_RECEIPT=
CREATED_SCRATCH=
LAB_CLEANUP_ATTEMPTED=0
LAB_TORN=0
SCOUT_TORN=0
FAILED=0
PASSED=0
SKIPPED=0

BUDGET_SESSION_START=${FM_SMOKE_BUDGET_SESSION_START_MS:-120000}
BUDGET_SPAWN=${FM_SMOKE_BUDGET_SPAWN_MS:-120000}
BUDGET_STEER=${FM_SMOKE_BUDGET_STEER_MS:-60000}
BUDGET_WAKE=${FM_SMOKE_BUDGET_WAKE_MS:-90000}
BUDGET_PR=${FM_SMOKE_BUDGET_PR_MS:-30000}
BUDGET_TEARDOWN=${FM_SMOKE_BUDGET_TEARDOWN_MS:-90000}

# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

exec 3>&1
OWNER_ENV=()

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; }
now_ms() { fm_timing_now_ms; }

valid_budget() {
  case "$1" in
    ''|0|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -lt 10 ] || { [ "${#1}" -eq 10 ] && [ "$1" -le 2147483647 ]; }
}

budget_secs() { printf '%s\n' "$(( ($1 + 999) / 1000 ))"; }
sanitize() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -cd '[:print:]' | tr -s ' ' | cut -c1-80 | sed 's/^ *//; s/ *$//'
}
receipt() {
  # Exclude mutable registration fields owned by fm-pr-check.sh and the
  # unresolved-decision inventory added by startup reconciliation.
  # All other spawn metadata must survive both successful and failed owners.
  LC_ALL=C awk -F= '$1 !~ /^(pr|pr_head|missing_review_override_ts|red_override_ts|red_override_pr|red_override_head|red_override_condition|decisions_reviewed|decision_keys)$/ {print}' \
    "$LAB_STATE/$TASK.meta" 2>/dev/null | cksum | awk '{print $1":"$2}'
}
owned_task() {
  [ -n "$SPAWN_GEN" ] && [ -f "$LAB_STATE/$TASK.meta" ] && [ ! -L "$LAB_STATE/$TASK.meta" ] &&
    [ "$(sed -n 's/^spawn_gen=//p' "$LAB_STATE/$TASK.meta" | tail -1)" = "$SPAWN_GEN" ] &&
    [ "$(receipt)" = "$META_RECEIPT" ]
}

telemetry_ready() {
  [ ! -L "$LAB_DATA" ] && [ ! -L "$LAB_DATA/telemetry" ] || return 1
  mkdir -p "$LAB_DATA/telemetry" || return 1
  [ -d "$LAB_DATA/telemetry" ] && [ ! -L "$LAB_DATA/telemetry" ] || return 1
  fm_pr_regular_destination_or_absent "$TELEMETRY" || return 1
  [ ! -e "$TELEMETRY" ] || fm_pr_private_file_valid "$TELEMETRY" 600 "$(fm_pr_file_device "$LAB_DATA")"
}

emit() { # <stage> <result> <ms> <budget> <detail>
  local stage=$1 result=$2 ms=$3 budget=$4 detail row at
  detail=$(sanitize "$5"); [ -n "$detail" ] || detail=empty
  if ! telemetry_ready || ! at=$(date -u +%Y-%m-%dT%H:%M:%SZ) ||
    ! row=$(jq -nc --arg at "$at" --arg stage "$stage" --arg result "$result" --argjson ms "$ms" \
      --argjson budget "$budget" --arg detail "$detail" \
      '{at:$at,stage:$stage,result:$result,ms:$ms,budget_ms:$budget,detail:$detail}') ||
    ! printf '%s\n' "$row" >> "$TELEMETRY"; then
    # Preserve prerequisite skips: their earlier failure already fails the run.
    if [ "$result" != skipped ] || [ "$detail" != prior-stage-failed ]; then
      result=fail; detail=telemetry-failed
    fi
  fi
  printf 'stage=%s result=%s ms=%s budget_ms=%s detail=%s\n' "$stage" "$result" "$ms" "$budget" "$detail"
  case "$result" in pass) PASSED=$((PASSED + 1));; fail) FAILED=$((FAILED + 1));; skipped) SKIPPED=$((SKIPPED + 1));; esac
}

owner() { "${OWNER_ENV[@]}" "$@"; }

run_to() { # <remaining-ms> <stdout> <stderr> <command...>
  local ms=$1 secs rc=0 out=$2 err=$3 command start elapsed
  shift 3
  [ "$ms" -gt 0 ] || return 124
  if [ "${1:-}" = owner ]; then
    shift
    command=${1##*/}
    set -- "${OWNER_ENV[@]}" "$@"
  else
    command=${1##*/}
  fi
  secs=$(budget_secs "$ms")
  start=$(now_ms)
  fm_run_timed "$secs" "$@" >"$out" 2>"$err" || rc=$?
  elapsed=$(( $(now_ms) - start )); [ "$elapsed" -ge 0 ] || elapsed=0
  jq -nc --arg owner "$command" --argjson exit_code "$rc" --argjson ms "$elapsed" \
    '{owner:$owner,exit_code:$exit_code,ms:$ms}' >> "$LAB_ROOT/evidence/owners.jsonl" || return 1
  printf 'owner=%s exit_code=%s ms=%s\n' "$command" "$rc" "$elapsed" >&3
  return "$rc"
}
remaining() { # <stage-start> <budget>
  local used=$(( $(now_ms) - $1 ))
  [ "$used" -lt "$2" ] || { printf '0\n'; return; }
  printf '%s\n' "$(( $2 - used ))"
}

capture() { # <name> <file> - retain redacted private evidence.
  local name=$1 file=$2 target
  target="$LAB_ROOT/evidence/$name"
  mkdir -p "$LAB_ROOT/evidence" || return 1
  if [ "$name" = session-start.out ]; then
    tr '\000' '?' < "$file" | sed -E 's/(token|password|secret)=[^[:space:]]+/\1=[REDACTED]/Ig' > "$target" || return 1
  else
    tr '\000' '?' < "$file" | sed -E 's/(token|password|secret)=[^[:space:]]+/\1=[REDACTED]/Ig' | head -c 4096 > "$target" || return 1
  fi
}

run_stage() { # <name> <budget>
  local name=$1 budget=$2 start rc=0 detail elapsed result detail_file
  start=$(now_ms)
  if [ "$FAILED" -ne 0 ] && [ "$name" != teardown ]; then
    emit "$name" skipped 0 "$budget" prior-stage-failed
    return
  fi
  detail_file=$(mktemp "$LAB_ROOT/stage-detail.XXXXXX") || { FAILED=$((FAILED + 1)); return; }
  case "$name" in
    session-start) stage_session_start "$start" "$budget" >"$detail_file" || rc=$? ;;
    spawn) stage_spawn "$start" "$budget" >"$detail_file" || rc=$? ;;
    steer) stage_steer "$start" "$budget" >"$detail_file" || rc=$? ;;
    wake) stage_wake "$start" "$budget" >"$detail_file" || rc=$? ;;
    pr) stage_pr "$start" "$budget" >"$detail_file" || rc=$? ;;
    teardown) stage_teardown "$start" "$budget" >"$detail_file" || rc=$? ;;
    *) printf 'unknown-stage\n' >"$detail_file"; rc=1 ;;
  esac
  detail=$(cat "$detail_file"); rm -f "$detail_file"
  elapsed=$(( $(now_ms) - start )); [ "$elapsed" -ge 0 ] || elapsed=0
  if [ "$elapsed" -gt "$budget" ]; then rc=1; detail=over-budget; fi
  case "$rc" in 0) result=pass;; 2) result=skipped;; *) result=fail;; esac
  emit "$name" "$result" "$elapsed" "$budget" "$detail"
}

actionable_bootstrap() {
  grep -Eq '^(MISSING|MISSING_MANUAL|BACKEND_INVALID|TANGLE|STARTUP_MEMORY_BUDGET|MEMORY_DOCTOR|CREW_DISPATCH|FLEET_SYNC|NETWORK_CHECKS|HOME_SUMMARY|BACKLOG_RECONCILE|SECONDMATE_SYNC|SECONDMATE_LIVENESS|SECONDMATE_HANDOFF|NUDGE_SECONDMATES|FMX):|^NEEDS_GH_AUTH$' "$1"
}
refusal_banner() {
  grep -Eq '^●  (READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED|STARTUP TRUNCATED - SESSION START HIT ITS [0-9]+s RUNTIME BOUND)$' "$1"
}
stage_session_start() {
  local start=$1 budget=$2 out err rc
  out=$(mktemp "$LAB_ROOT/session-start.out.XXXXXX") || return 1; err="$out.err"
  run_to "$(remaining "$start" "$budget")" "$out" "$err" owner "$LAB_BIN/fm-session-start.sh" || rc=$?
  capture session-start.out "$out"; capture session-start.err "$err"
  [ "${rc:-0}" -eq 0 ] || { printf 'session-start-exit-%s\n' "${rc:-1}"; return 1; }
  if ! grep -Eq '^SESSION START( \(CONTEXT RE-EMIT\))? - .+$' "$out" ||
    ! grep -Fxq 'FLEET STATE' "$out" || ! grep -Fxq 'CONTEXT' "$out" ||
    actionable_bootstrap "$out" || refusal_banner "$out"; then
    printf 'startup-not-owned-or-complete\n'
    return 1
  fi
  printf 'digest-ok\n'
}

stage_spawn() {
  local start=$1 budget=$2 harness repo intent out err rc=0 line
  [ ! -e "$LAB_STATE/$TASK.meta" ] && [ ! -e "$LAB_STATE/$TASK.lock" ] && [ ! -e "$LAB_DATA/$TASK" ] || { printf 'task-collision\n'; return 1; }
  harness=$(owner "$LAB_BIN/fm-harness.sh" crew 2>/dev/null || true); [ -n "$harness" ] || harness=unknown
  repo=$CALLER_HOME; [ -d "$repo/.git" ] || repo=$(cd "$SCRIPT_DIR/.." && pwd)
  intent=$(mktemp "$LAB_ROOT/intent.XXXXXX") || return 1
  printf 'Append exactly one status line containing smoke-nonce=%s, then acknowledge the matching inbox message.\n' "$NONCE" > "$intent"
  out=$(mktemp "$LAB_ROOT/spawn.out.XXXXXX") || return 1; err="$out.err"
  run_to "$(remaining "$start" "$budget")" "$out" "$err" owner "$LAB_BIN/fm-brief.sh" "$TASK" firstmate --scout --access reader || { capture brief.err "$err"; printf 'brief-failed\n'; return 1; }
  run_to "$(remaining "$start" "$budget")" "$out" "$err" owner "$LAB_BIN/fm-brief.sh" "$TASK" --fill "$intent" || { capture brief.err "$err"; printf 'brief-fill-failed\n'; return 1; }
  rm -f "$intent"
  set -- "$LAB_BIN/fm-spawn.sh" "$TASK" "$repo" --scout --access reader --backend herdr
  [ "$harness" = unknown ] || set -- "$@" --harness "$harness"
  run_to "$(remaining "$start" "$budget")" "$out" "$err" owner "$@" || rc=$?
  capture spawn.out "$out"; capture spawn.err "$err"
  [ "$rc" -eq 0 ] || { printf 'spawn-exit-%s\n' "$rc"; return 1; }
  line=$(grep -E "^spawned $TASK " "$out" | tail -1 || true)
  [ -n "$line" ] && [ -f "$LAB_STATE/$TASK.meta" ] && [ ! -L "$LAB_STATE/$TASK.meta" ] || { printf 'spawn-receipt-missing\n'; return 1; }
  SPAWN_GEN=$(sed -n 's/^spawn_gen=//p' "$LAB_STATE/$TASK.meta" | tail -1)
  CREATED_SCRATCH=$(sed -n 's/^worktree=//p' "$LAB_STATE/$TASK.meta" | tail -1)
  [ -n "$SPAWN_GEN" ] && [ -n "$CREATED_SCRATCH" ] || { printf 'spawn-incarnation-missing\n'; return 1; }
  META_RECEIPT=$(receipt); owned_task || { printf 'spawn-receipt-invalid\n'; return 1; }
  printf 'spawned\n'
}
stage_steer() {
  local start=$1 budget=$2 out err rc=0 found=0
  owned_task || { printf 'spawn-receipt-lost\n'; return 1; }
  out=$(mktemp "$LAB_ROOT/steer.out.XXXXXX") || return 1; err="$out.err"
  OWNER_ENV+=(FM_SEND_EXPECTED_SPAWN_GEN="$SPAWN_GEN")
  run_to "$(remaining "$start" "$budget")" "$out" "$err" owner "$LAB_BIN/fm-send.sh" "$TASK" "smoke-nonce=$NONCE spawn-gen=$SPAWN_GEN; append it to status and acknowledge this message" || rc=$?
  capture steer.out "$out"; capture steer.err "$err"
  [ "$rc" -eq 0 ] || { printf 'send-failed\n'; return 1; }
  while [ "$(remaining "$start" "$budget")" -gt 0 ]; do
    owned_task || { printf 'spawn-receipt-lost\n'; return 1; }
    if grep -RFl -- "$NONCE" "$LAB_STATE/$TASK.inbox/handled"/*.msg >/dev/null 2>&1 && grep -F -- "$NONCE" "$LAB_STATE/$TASK.status" >/dev/null 2>&1; then found=1; break; fi
    sleep 0.05
  done
  [ "$found" -eq 1 ] || { printf 'correlated-steer-missing\n'; return 1; }
  printf 'handled\n'
}
stage_wake() {
  local start=$1 budget=$2 out err rc=0 ack_seq ack_gen
  owned_task || { printf 'spawn-receipt-lost\n'; return 1; }
  out=$(mktemp "$LAB_ROOT/wake.out.XXXXXX") || return 1; err="$out.err"
  run_to "$(remaining "$start" "$budget")" "$out" "$err" owner "$LAB_BIN/fm-wake-drain.sh" || rc=$?
  capture wake.out "$out"; capture wake.err "$err"
  if [ "$rc" -ne 0 ] || ! grep -F -- "$NONCE" "$out" >/dev/null; then
    printf 'correlated-wake-missing\n'
    return 1
  fi
  ack_seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err" | tail -1)
  ack_gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err" | tail -1)
  [ -n "$ack_seq" ] && [ -n "$ack_gen" ] || { printf 'ack-missing\n'; return 1; }
  run_to "$(remaining "$start" "$budget")" "$out" "$err" owner "$LAB_BIN/fm-wake-drain.sh" --ack-through "$ack_seq" --recovery-generation "$ack_gen" || { printf 'ack-rejected\n'; return 1; }
  printf 'acked\n'
}
stage_pr() {
  local start=$1 budget=$2 out err rc=0
  [ -n "${FM_SMOKE_PR_URL:-}" ] || { printf 'no-FM_SMOKE_PR_URL\n'; return 2; }
  owned_task || { printf 'spawn-receipt-lost\n'; return 1; }
  out=$(mktemp "$LAB_ROOT/pr.out.XXXXXX") || return 1; err="$out.err"
  run_to "$(remaining "$start" "$budget")" "$out" "$err" owner "$LAB_BIN/fm-pr-check.sh" "$TASK" "$FM_SMOKE_PR_URL" || rc=$?
  capture pr.out "$out"; capture pr.err "$err"
  [ "$rc" -eq 0 ] || { printf 'pr-check-failed\n'; return 1; }
  owned_task || { printf 'spawn-receipt-lost\n'; return 1; }
  printf 'registered\n'
}
stage_teardown() {
  local start=$1 budget=$2 out err rc=0
  out=$(mktemp "$LAB_ROOT/teardown.out.XXXXXX") || return 1; err="$out.err"
  if [ -n "$SPAWN_GEN" ]; then
    owned_task || { printf 'spawn-receipt-lost\n'; return 1; }
    run_to "$(remaining "$start" "$budget")" "$out" "$err" owner "$LAB_BIN/fm-teardown.sh" "$TASK" --force || rc=$?
    [ "$rc" -eq 0 ] || { capture teardown.err "$err"; printf 'task-teardown-failed\n'; return 1; }
    SCOUT_TORN=1
    [ ! -e "$LAB_STATE/$TASK.meta" ] && [ ! -e "$LAB_STATE/$TASK.lock" ] && [ ! -e "$CREATED_SCRATCH" ] || { printf 'orphan-task-artifact\n'; return 1; }
  fi
  LAB_CLEANUP_ATTEMPTED=1
  run_to "$(remaining "$start" "$budget")" "$out" "$err" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=$?
  capture teardown.out "$out"; capture teardown.err "$err"
  [ "$rc" -eq 0 ] || { printf 'lab-teardown-failed\n'; return 1; }
  LAB_TORN=1
  printf 'retired\n'
}
case "${1:-}" in -h|--help) usage; exit 0;; '') ;; *) usage >&2; exit 2;; esac
for b in "$BUDGET_SESSION_START" "$BUDGET_SPAWN" "$BUDGET_STEER" "$BUDGET_WAKE" "$BUDGET_PR" "$BUDGET_TEARDOWN"; do valid_budget "$b" || { echo 'error: smoke budgets must be canonical positive millisecond integers' >&2; exit 2; }; done
case "$TASK" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid smoke task id' >&2; exit 2;; esac
[ -x "$HERDR_LAB_HELPER" ] && [ -d "$SOURCE_BIN" ] || { echo 'error: smoke toolbelt is unavailable' >&2; exit 2; }
LAB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-smoke.XXXXXX") || exit 2
LAB_HOME="$LAB_ROOT/home"; LAB_STATE="$LAB_HOME/state"; LAB_DATA="$LAB_HOME/data"; LAB_CONFIG="$LAB_HOME/config"; LAB_BIN="$LAB_HOME/bin"; TELEMETRY="$LAB_DATA/telemetry/smoke.jsonl"
mkdir -p "$LAB_STATE" "$LAB_DATA" "$LAB_CONFIG" "$LAB_ROOT/evidence" || exit 2
printf 'evidence=%s\n' "$LAB_ROOT/evidence" >&3
# Seed only tracked support files, never the caller's private state or config.
(
  set -o pipefail
  while IFS= read -r key; do
    case "$key" in GIT_*) unset "$key" ;; esac
  done < <(compgen -e)
  git -C "$SCRIPT_DIR/.." archive HEAD | tar -x -C "$LAB_HOME"
) || exit 2
cp -R "$SOURCE_BIN/." "$LAB_BIN/" || exit 2
# An archive under another checkout must not discover that checkout's Git root.
env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
  -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
  git -C "$LAB_HOME" init -q --initial-branch=main || exit 2
env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
  -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
  git -C "$LAB_HOME" add -A || exit 2
env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
  -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
  git -C "$LAB_HOME" -c user.name='fm-smoke' -c user.email='fm-smoke@invalid' \
    -c commit.gpgsign=false commit -qm 'archive smoke checkout' || exit 2
trap '
  rc=$?
  if [ "$SCOUT_TORN" -eq 0 ] && owned_task; then
    owner "$LAB_BIN/fm-teardown.sh" "$TASK" --force >"$LAB_ROOT/evidence/cleanup-task.out" 2>&1 || rc=1
  fi
  if [ "$LAB_CLEANUP_ATTEMPTED" -eq 0 ] && [ -n "$HERDR_LAB_SESSION" ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >"$LAB_ROOT/evidence/cleanup-lab.out" 2>&1 || {
      echo "error: guarded lab cleanup refused; inspect private evidence" >&2
      rc=1
    }
  fi
  exit "$rc"
' EXIT
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "$TASK") || { echo 'error: herdr lab name failed' >&2; exit 2; }
[[ "$HERDR_LAB_SESSION" =~ ^fm-lab-[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || { echo 'error: invalid Herdr lab session' >&2; exit 2; }
printf 'lab_session=%s\n' "$HERDR_LAB_SESSION" >&3
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >"$LAB_ROOT/evidence/provision.out" 2>"$LAB_ROOT/evidence/provision.err" || { echo 'error: herdr lab provision failed' >&2; exit 2; }
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json >/dev/null 2>&1 || { echo 'error: herdr lab scope verification failed' >&2; exit 2; }
# Clear inherited operational selectors instead of interpreting their precedence.
OWNER_ENV=(env)
while IFS= read -r key; do
  case "$key" in
    FM_SMOKE_*|FM_TEST_*) ;;
    FM_*|HERDR_*|TMUX*|ZELLIJ*|CMUX*|GIT_*|STATE|DATA|CONFIG|PROJECTS) OWNER_ENV+=(-u "$key") ;;
  esac
done < <(compgen -e)
OWNER_ENV+=(PATH="$LAB_BIN:$PATH" FM_HOME="$LAB_HOME" FM_ROOT_OVERRIDE="$LAB_HOME" FM_STATE_OVERRIDE="$LAB_STATE"
  FM_DATA_OVERRIDE="$LAB_DATA" FM_CONFIG_OVERRIDE="$LAB_CONFIG" FM_BACKEND=herdr
  HERDR_ENV=1 HERDR_SESSION="$HERDR_LAB_SESSION")
run_stage session-start "$BUDGET_SESSION_START"
run_stage spawn "$BUDGET_SPAWN"
run_stage steer "$BUDGET_STEER"
run_stage wake "$BUDGET_WAKE"
run_stage pr "$BUDGET_PR"
run_stage teardown "$BUDGET_TEARDOWN"
if [ "$FAILED" -eq 0 ] && [ "$LAB_TORN" -eq 1 ]; then printf 'summary result=pass passed=%s failed=%s skipped=%s\n' "$PASSED" "$FAILED" "$SKIPPED"; exit 0; fi
printf 'summary result=fail passed=%s failed=%s skipped=%s\n' "$PASSED" "$FAILED" "$SKIPPED"
exit 1
