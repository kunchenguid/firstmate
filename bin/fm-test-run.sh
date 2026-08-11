#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, portable
# CI lane composition, declarative runtime-gate evidence, local --jobs for the
# proven-isolated set, timing markers, durable progress journals, and the
# complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --check-coverage
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run
#   --progress-journal <directory>
#                   write an opt-in durable progress journal. Each selected worker
#                   gets immutable transition records and atomically replaced
#                   current-state records under the selected directory. Requires
#                   python3 when enabled.
#   --list          print selected script paths (one per line) and exit 0
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude the dedicated
#                   real-herdr-gated and native-backend-gated lanes)
#   --runtime-gate <runtime>=required|optional
#                   declare whether a selected runtime gate must be exercised.
#                   Required gates need a selected real-runtime test and explicit
#                   FM_TEST_RUNTIME_GATE evidence. Optional unavailable runtimes
#                   retain a successful typed intentionally-unavailable outcome.
#   --fail-on-gate-skip <token>
#                   legacy free-text skip refusal, retained for compatibility.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Default is 1 (serial). N>1 is allowed only when every
#                   selected script is in the proven-isolated set
#                   (bin/fm-test-isolation-proof.sh --list). Cap is 8. Stateful
#                   families never schedule under --jobs.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> runtime_gate=<runtime|none> gate_requirement=<required|optional|none>
#   FM_TEST_RUNTIME_GATE runtime=<runtime> outcome=<exercised|unavailable>  (exactly once from mapped tests)
#   FM_TEST_GATE <script> runtime=<runtime|none> requirement=<required|optional|none> outcome=<exercised|intentionally-unavailable|unexpectedly-skipped|legacy-skip|failed>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false> gate_outcome=<outcome>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#
# Exit status is non-zero if any selected script exits non-zero, a required
# runtime gate has no selected real-runtime test or lacks exercised evidence, a
# mapped test omits typed evidence, or a configured legacy
# --fail-on-gate-skip token appears. A mapped optional runtime may report
# intentionally-unavailable explicitly, while unmapped scripts retain the
# legacy successful skip behavior.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set (see docs/fm-test-portable-shards.md).
#
# portable-serial stays strictly serial. Its CI shards (portable-serial-<k>of<n>)
# split it across separate runners, so two of its stateful scripts still never
# share a machine. This script owns <n>: a lane whose <n> disagrees with the
# configured shard count is refused, so a CI matrix cannot silently drop a shard.
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODE=
LIST_ONLY=0
LIST_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
PROGRESS_JOURNAL=
SCRIPTS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
RUNTIME_GATE_DECLARATIONS=()
JOBS=1
JOBS_MAX=8

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
PORTABLE_SERIAL_SHARDS=4

# Balance hint for a portable-serial script with no measured duration, close to
# the measured per-script mean so a newly added test neither starves nor
# overloads the shard it lands in.
PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=20000

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-run: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    # Second precision only when python3 is unavailable.
    echo $(($(date +%s) * 1000))
  fi
}

# The progress journal is deliberately independent from timing JSON artifacts.
# It contains no test stdout, environment, credentials, or process inventory.
# Records are limited to run and worker identities, the runner PID, timestamps,
# selection and worker-plan metadata, script paths, transitions, exit codes,
# and durations needed to diagnose an abrupt runner exit.
#
# A journal directory is append-only at the transition layer. A worker's
# events/<worker>.<ordinal>.<state>.json record is created before its matching
# states/<worker>.json is atomically replaced. The atomically replaced run.json
# records the selected worker plan and the run's started or terminal state.
# Journal initialization durably publishes every newly created directory through
# the first existing ancestor and the started run record before deferred INT,
# TERM, or HUP delivery resumes. Each worker is likewise registered and its
# started transition made durable before that worker can launch or a deferred
# signal can terminate the runner. Terminal transitions record the adjudicated
# result before summary bookkeeping, and signal cleanup preserves an already
# adjudicated terminal result instead of replacing it with interrupted.
# Consequently, a crash can leave an older current-state record but cannot tear
# or lose a completed transition, and worker transitions advance monotonically.
# Existing runs are never parsed, so malformed historical records are inert;
# only a collision with this exact generated run ID is refused.
JOURNAL_RUN_DIR=
JOURNAL_RUN_ID=
JOURNAL_RUNNER_PID=
JOURNAL_RUN_INITIALIZED=
JOURNAL_SIGNAL_DEFERRED=
JOURNAL_PENDING_SIGNAL=
JOURNAL_ACTIVE_SERIAL_WORKER=
JOURNAL_ACTIVE_SERIAL_SCRIPT=
JOURNAL_ACTIVE_SERIAL_TERMINAL=
declare -a JOURNAL_PARALLEL_WORKERS=()
declare -a JOURNAL_PARALLEL_SCRIPTS=()
declare -a JOURNAL_PARALLEL_TERMINALS=()

# shellcheck disable=SC2329 # Registered by the signal traps below.
journal_handle_signal() {
  local rc=$1
  if [ -n "$JOURNAL_SIGNAL_DEFERRED" ]; then
    JOURNAL_PENDING_SIGNAL=$rc
    return 0
  fi
  exit "$rc"
}

journal_signal_boundary_begin() {
  JOURNAL_SIGNAL_DEFERRED=1
}

journal_signal_boundary_run() {
  (
    trap '' HUP INT TERM
    "$@"
  )
}

journal_signal_boundary_finish() {
  local operation_rc=$1 pending_signal
  JOURNAL_SIGNAL_DEFERRED=
  if [ -n "$JOURNAL_PENDING_SIGNAL" ]; then
    pending_signal=$JOURNAL_PENDING_SIGNAL
    JOURNAL_PENDING_SIGNAL=
    exit "$pending_signal"
  fi
  return "$operation_rc"
}

journal_terminal_state_for_exit() {
  case "$1" in
    0) printf '%s\n' passed ;;
    124) printf '%s\n' timed-out ;;
    *) printf '%s\n' failed ;;
  esac
}

journal_write_record() {
  local kind=$1 path=$2
  shift 2
  python3 - "$kind" "$path" "$JOURNAL_RUN_ID" "$JOURNAL_RUNNER_PID" \
    "$RUN_STARTED_ISO" "$@" <<'PY'
import datetime
import json
import os
import sys

kind, path, run_id, runner_pid, started_at, *payload = sys.argv[1:]
recorded_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
if kind == "worker":
    worker_id, state, ordinal, script, exit_code, duration_ms = payload
    record = {
        "schema": 1,
        "run_id": run_id,
        "worker_id": worker_id,
        "state": state,
        "transition_ordinal": int(ordinal),
        "recorded_at": recorded_at,
        "runner_pid": int(runner_pid),
        "script": script,
    }
    if exit_code:
        record["exit"] = int(exit_code)
    if duration_ms:
        record["duration_ms"] = int(duration_ms)
elif kind == "run":
    state, exit_code, jobs, selection, *scripts = payload
    prefix = "serial" if int(jobs) == 1 else "parallel"
    workers = [
        {"worker_id": "%s-%s" % (prefix, index), "script": script}
        for index, script in enumerate(scripts, start=1)
    ]
    record = {
        "schema": 1,
        "run_id": run_id,
        "state": state,
        "recorded_at": recorded_at,
        "runner_pid": int(runner_pid),
        "started_at": started_at,
        "selection": selection,
        "jobs": int(jobs),
        "planned_worker_count": len(workers),
        "planned_workers": workers,
    }
    if state != "started":
        record["finished_at"] = recorded_at
        record["exit"] = int(exit_code)
else:
    raise SystemExit("unknown journal record kind: %s" % kind)

directory = os.path.dirname(path)
tmp = os.path.join(directory, ".%s.%s.tmp" % (os.path.basename(path), os.getpid()))
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(record, fh, sort_keys=True, separators=(",", ":"))
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
}

# shellcheck disable=SC2329 # Invoked indirectly through journal_signal_boundary_run.
journal_sync_directories() {
  python3 - sync-directories "$@" <<'PY'
import os
import sys

_, *directories = sys.argv[1:]
for directory in directories:
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
PY
}

journal_transition() {
  local worker_id=$1 state=$2 script=$3 ordinal=$4 exit_code=${5:-} duration_ms=${6:-}
  local event state_path
  [ -n "$JOURNAL_RUN_DIR" ] || return 0
  event="$JOURNAL_RUN_DIR/events/${worker_id}.${ordinal}.${state}.json"
  state_path="$JOURNAL_RUN_DIR/states/${worker_id}.json"
  # A repeated cleanup transition is idempotent. Immutable transition files
  # are never replaced; current state advances only after its event exists.
  if [ ! -e "$event" ]; then
    journal_write_record worker "$event" "$worker_id" "$state" "$ordinal" "$script" "$exit_code" "$duration_ms" \
      || return $?
  fi
  journal_write_record worker "$state_path" "$worker_id" "$state" "$ordinal" "$script" "$exit_code" "$duration_ms"
}

journal_register_worker() {
  local mode=$1 slot=$2 worker_id=$3 script=$4
  case "$mode" in
    serial)
      JOURNAL_ACTIVE_SERIAL_SCRIPT=$script
      JOURNAL_ACTIVE_SERIAL_TERMINAL=
      JOURNAL_ACTIVE_SERIAL_WORKER=$worker_id
      ;;
    parallel)
      JOURNAL_PARALLEL_SCRIPTS[slot]=$script
      unset 'JOURNAL_PARALLEL_TERMINALS[slot]'
      JOURNAL_PARALLEL_WORKERS[slot]=$worker_id
      ;;
    *)
      die "unknown journal worker mode: $mode"
      ;;
  esac
}

journal_start_worker() {
  local mode=$1 slot=$2 worker_id=$3 script=$4 operation_rc
  if [ -z "$JOURNAL_RUN_DIR" ]; then
    journal_register_worker "$mode" "$slot" "$worker_id" "$script"
    return 0
  fi
  journal_signal_boundary_begin
  journal_register_worker "$mode" "$slot" "$worker_id" "$script"
  if journal_signal_boundary_run journal_transition "$worker_id" started "$script" 1; then
    operation_rc=0
  else
    operation_rc=$?
  fi
  journal_signal_boundary_finish "$operation_rc"
}

# shellcheck disable=SC2329 # Invoked through indirect journal lifecycle entry points.
journal_write_run_record() {
  local state=$1 exit_code=${2:-}
  journal_write_record run "$JOURNAL_RUN_DIR/run.json" "$state" "$exit_code" \
    "$JOBS" "$SELECTION_DESC" "${SCRIPTS[@]+"${SCRIPTS[@]}"}"
}

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap through cleanup_run.
journal_write_run_state() {
  [ -n "$JOURNAL_RUN_INITIALIZED" ] || return 0
  journal_write_run_record "$@"
}

# shellcheck disable=SC2329 # Invoked indirectly through journal_signal_boundary_run.
journal_initialize_records() {
  umask 077
  mkdir -p "$PROGRESS_JOURNAL/runs" \
    || die "could not create progress journal: $PROGRESS_JOURNAL"
  mkdir "$JOURNAL_RUN_DIR" \
    || die "progress journal run already exists: $JOURNAL_RUN_ID"
  mkdir "$JOURNAL_RUN_DIR/events" "$JOURNAL_RUN_DIR/states" \
    || die "could not initialize progress journal run: $JOURNAL_RUN_ID"
  journal_sync_directories "$@" \
    || die "could not make progress journal durable: $JOURNAL_RUN_ID"
  journal_write_run_record started
}

journal_initialize() {
  local journal_existing_ancestor journal_sync_path operation_rc
  local -a journal_directories
  [ -n "$PROGRESS_JOURNAL" ] || return 0
  command -v python3 >/dev/null 2>&1 \
    || die "--progress-journal requires python3"
  if [ -e "$PROGRESS_JOURNAL" ] && [ ! -d "$PROGRESS_JOURNAL" ]; then
    die "--progress-journal is not a directory: $PROGRESS_JOURNAL"
  fi
  journal_existing_ancestor=$PROGRESS_JOURNAL
  while [ ! -e "$journal_existing_ancestor" ]; do
    journal_existing_ancestor=$(dirname "$journal_existing_ancestor")
  done
  JOURNAL_RUN_ID=$RUN_ID
  JOURNAL_RUNNER_PID=$$
  JOURNAL_RUN_DIR="$PROGRESS_JOURNAL/runs/$JOURNAL_RUN_ID"
  journal_directories=("$JOURNAL_RUN_DIR/events" "$JOURNAL_RUN_DIR/states" \
    "$JOURNAL_RUN_DIR" "$PROGRESS_JOURNAL/runs")
  journal_sync_path=$PROGRESS_JOURNAL
  while :; do
    journal_directories+=("$journal_sync_path")
    [ "$journal_sync_path" != "$journal_existing_ancestor" ] || break
    journal_sync_path=$(dirname "$journal_sync_path")
  done
  journal_signal_boundary_begin
  if journal_signal_boundary_run journal_initialize_records "${journal_directories[@]}"; then
    JOURNAL_RUN_INITIALIZED=1
    operation_rc=0
  else
    operation_rc=$?
  fi
  journal_signal_boundary_finish "$operation_rc"
}

# shellcheck disable=SC2329 # Invoked indirectly by cleanup_run's signal path.
journal_mark_interrupted_workers() {
  local slot worker_id script rc duration state terminal rest
  [ -n "$JOURNAL_RUN_DIR" ] || return 0
  if [ -n "$JOURNAL_ACTIVE_SERIAL_WORKER" ]; then
    terminal=$JOURNAL_ACTIVE_SERIAL_TERMINAL
    if [ -n "$terminal" ]; then
      state=${terminal%%$'\t'*}
      rest=${terminal#*$'\t'}
      rc=${rest%%$'\t'*}
      duration=${rest#*$'\t'}
      journal_transition "$JOURNAL_ACTIVE_SERIAL_WORKER" "$state" \
        "$JOURNAL_ACTIVE_SERIAL_SCRIPT" 2 "$rc" "$duration"
    else
      journal_transition "$JOURNAL_ACTIVE_SERIAL_WORKER" interrupted \
        "$JOURNAL_ACTIVE_SERIAL_SCRIPT" 2
    fi
  fi
  for slot in "${!JOURNAL_PARALLEL_WORKERS[@]}"; do
    worker_id=${JOURNAL_PARALLEL_WORKERS[$slot]}
    script=${JOURNAL_PARALLEL_SCRIPTS[$slot]}
    terminal=${JOURNAL_PARALLEL_TERMINALS[$slot]:-}
    if [ -n "$terminal" ]; then
      state=${terminal%%$'\t'*}
      rest=${terminal#*$'\t'}
      rc=${rest%%$'\t'*}
      duration=${rest#*$'\t'}
      journal_transition "$worker_id" "$state" "$script" 2 "$rc" "$duration"
    else
      journal_transition "$worker_id" interrupted "$script" 2
    fi
  done
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
family_for_basename() {
  case "$1" in
    fm-arm-pretool-check.test.sh|fm-ask-user-authority.test.sh|\
    fm-brief.test.sh|fm-vendor-auth-probe.test.sh|\
    fm-calm-claude-adapter.test.sh|fm-calm-pi-extension.test.sh|fm-cd-pretool-check.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|\
    fm-crew-state.test.sh|fm-decision-hold-lifecycle.test.sh|\
    fm-documentation-audiences.test.sh|fm-ensure-agents-md.test.sh|fm-grok-harness.test.sh|\
    fm-kimi-harness.test.sh|fm-herdr-lab.test.sh|fm-lint.test.sh|\
    fm-operational-input.test.sh|fm-pi-primary-types.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|\
    fm-subagent-pretool-check.test.sh|\
    fm-supervision-instructions.test.sh|fm-task-delivery.test.sh|\
    fm-tmux-submit-busy.test.sh|fm-trace-context-lib.test.sh|\
    fm-transition-lib.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-refill.test.sh|fm-session-lock-ancestry.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-queue.test.sh|fm-watch-arm.test.sh|fm-watch-checkpoint.test.sh|fm-watch-triage.test.sh|\
    fm-watcher-lock.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-focus-flash-e2e.test.sh|\
    fm-backend-herdr-presentation-e2e.test.sh|\
    fm-backend-herdr-launcher-workspace-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-on.test.sh|fm-remote-backlog-handoff.test.sh|\
    fm-remote-doctor.test.sh|fm-remote-job.test.sh|\
    fm-remote-reply.test.sh|fm-remote-secondmate-lifecycle-e2e.test.sh|\
    fm-remote-secondmate-trace-context.test.sh|\
    fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-startup-memory-budget.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      printf '%s\n' secondmate
      ;;
    fm-bootstrap.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-tangle-guard.test.sh|\
    fm-update.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-calm-claude-adapter-live-e2e.test.sh|fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|fm-harness-liveness-drift-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-primary-live-e2e.test.sh|\
    fm-quota-array-dispatch-live-e2e.test.sh|fm-send-secondmate-marker-herdr-e2e.test.sh)
      printf '%s\n' live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-tmux-agent-liveness.test.sh|\
    fm-herdr-session-cleanup.test.sh|fm-send-strict.test.sh|fm-spawn-batch.test.sh|\
    fm-spawn-dispatch-profile.test.sh|\
    fm-trace-context-spawn.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-pr-check-security.test.sh|fm-pr-merge.test.sh|fm-test-inventory.test.sh|fm-review-diff.test.sh|\
    fm-teardown.test.sh|fm-x-mode.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
      printf '%s\n' afk
      ;;
    fm-bearings-snapshot.test.sh|fm-fleet-snapshot-view.test.sh)
      printf '%s\n' snapshot-bearings
      ;;
    fm-backend-cmux.test.sh)
      printf '%s\n' cmux
      ;;
    fm-backend-zellij.test.sh)
      printf '%s\n' zellij
      ;;
    fm-backend-orca.test.sh)
      printf '%s\n' orca
      ;;
    fm-backend-cmux-smoke.test.sh|fm-backend-orca-smoke.test.sh|fm-backend-zellij-smoke.test.sh)
      printf '%s\n' native-backend-gated
      ;;
    *)
      printf '%s\n' unclassified
      ;;
  esac
}

runtime_gate_for_basename() {
  case "$1" in
    fm-backend-cmux-smoke.test.sh) printf '%s\n' cmux ;;
    fm-backend-orca-smoke.test.sh) printf '%s\n' orca ;;
    fm-backend-zellij-smoke.test.sh) printf '%s\n' zellij ;;
    *)
      case "$(family_for_basename "$1")" in
        real-herdr-gated) printf '%s\n' herdr ;;
        *) printf '%s\n' none ;;
      esac
      ;;
  esac
}

known_runtime_gate() {
  case "$1" in
    herdr|cmux|zellij|orca) return 0 ;;
    *) return 1 ;;
  esac
}

parse_runtime_gate_declaration() {
  local declaration=$1 runtime requirement existing
  case "$declaration" in
    *=*) ;;
    *) die "malformed --runtime-gate declaration '$declaration' (expected <runtime>=required|optional)" ;;
  esac
  runtime=${declaration%%=*}
  requirement=${declaration#*=}
  [ -n "$runtime" ] && [ -n "$requirement" ] \
    || die "malformed --runtime-gate declaration '$declaration' (expected <runtime>=required|optional)"
  case "$requirement" in
    required|optional) ;;
    *) die "malformed --runtime-gate declaration '$declaration' (requirement must be required or optional)" ;;
  esac
  known_runtime_gate "$runtime" \
    || die "unknown runtime gate '$runtime' in declaration '$declaration'"
  for existing in "${RUNTIME_GATE_DECLARATIONS[@]+"${RUNTIME_GATE_DECLARATIONS[@]}"}"; do
    [ "${existing%%$'\t'*}" != "$runtime" ] \
      || die "duplicate runtime gate declaration for '$runtime'"
  done
  RUNTIME_GATE_DECLARATIONS+=("$runtime"$'\t'"$requirement")
}

runtime_gate_requirement() {
  local runtime=$1 declaration
  [ "$runtime" != none ] || {
    printf '%s\n' none
    return
  }
  for declaration in "${RUNTIME_GATE_DECLARATIONS[@]+"${RUNTIME_GATE_DECLARATIONS[@]}"}"; do
    if [ "${declaration%%$'\t'*}" = "$runtime" ]; then
      printf '%s\n' "${declaration#*$'\t'}"
      return
    fi
  done
  printf '%s\n' optional
}

validate_required_runtime_gate_selections() {
  local declaration runtime requirement script selected_runtime matched
  for declaration in "${RUNTIME_GATE_DECLARATIONS[@]+"${RUNTIME_GATE_DECLARATIONS[@]}"}"; do
    runtime=${declaration%%$'\t'*}
    requirement=${declaration#*$'\t'}
    [ "$requirement" = required ] || continue
    matched=0
    for script in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      selected_runtime=$(runtime_gate_for_basename "$(basename "$script")")
      if [ "$selected_runtime" = "$runtime" ]; then
        matched=1
        break
      fi
    done
    if [ "$matched" -eq 0 ]; then
      printf 'FM_TEST_GATE selection runtime=%s requirement=required outcome=unexpectedly-skipped reason=no-selected-gate\n' "$runtime"
      log "required runtime gate has no selected real-runtime test: runtime=$runtime"
      return 1
    fi
  done
  return 0
}

list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
secondmate
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
snapshot-bearings
cmux
zellij
orca
native-backend-gated
unclassified
EOF
}

list_known_lanes() {
  local i
  printf '%s\n' portable-parallel-1
  printf '%s\n' portable-parallel-2
  printf '%s\n' portable-serial
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    printf 'portable-serial-%sof%s\n' "$i" "$PORTABLE_SERIAL_SHARDS"
    i=$((i + 1))
  done
  printf '%s\n' real-herdr-gated
  printf '%s\n' native-backend-gated
}

# Exact proven-isolated candidate set (same paths as
# bin/fm-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
list_proven_isolated() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-brief.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

# Portable parallel shard 1: LPT balance of the proven-isolated set using the
# current concurrent-proof durations in docs/fm-test-isolation-proof.json.
# Execution order is longest first so wall-clock stays near the balanced sum.
list_portable_parallel_1() {
  cat <<'EOF'
tests/fm-x-mode.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-test-run.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-grok-harness.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-review-diff.test.sh
tests/fm-brief.test.sh
tests/fm-transition-lib.test.sh
EOF
}

# Portable parallel shard 2: the complementary LPT half of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/fm-backend-herdr.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-crew-state.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-pr-merge.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-composer-lib.test.sh
EOF
}

is_proven_isolated_script() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_proven_isolated)
  return 1
}

# The portable serial remainder: every tests/*.test.sh that is neither
# proven-isolated, real-herdr-gated, nor native-backend-gated. Watcher, lock, AFK, real tmux, daemon,
# secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other
# unproven work stays here. Derived rather than enumerated so a newly added test
# lands here by default instead of falling out of every lane.
list_portable_serial() {
  local s base fam
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "real-herdr-gated" ]; then
      continue
    fi
    if [ "$fam" = "native-backend-gated" ]; then
      continue
    fi
    if is_proven_isolated_script "$s"; then
      continue
    fi
    printf '%s\n' "$s"
  done < <(all_repo_tests)
}

# Measured portable-serial script durations in milliseconds, from the CI timing
# artifact recorded in docs/fm-test-portable-shards.md. These are balance hints
# only: the shard partition stays complete and disjoint whatever they say, so a
# stale hint costs balance rather than coverage. That doc owns the refresh
# procedure.
portable_serial_weight_hints() {
  cat <<'EOF'
tests/fm-afk-inject-e2e.test.sh 34019
tests/fm-afk-pi-herdr-return-e2e.test.sh 42
tests/fm-afk-return.test.sh 1105
tests/fm-ask-user-authority.test.sh 68
tests/fm-backend-cmux-smoke.test.sh 29
tests/fm-backend-cmux.test.sh 2349
tests/fm-backend-orca.test.sh 12041
tests/fm-backend-tmux-smoke.test.sh 314
tests/fm-backend-zellij-smoke.test.sh 21
tests/fm-backend-zellij.test.sh 4225
tests/fm-backend.test.sh 16370
tests/fm-backlog-handoff.test.sh 2786
tests/fm-bearings-snapshot.test.sh 60103
tests/fm-bootstrap.test.sh 21912
tests/fm-busy-adapter-wiring.test.sh 13962
tests/fm-busy-state.test.sh 607
tests/fm-calm-pi-extension.test.sh 203
tests/fm-claude-stop-autoarm-live-e2e.test.sh 19
tests/fm-claude-stop-autoarm.test.sh 60521
tests/fm-codex-continuity-live-e2e.test.sh 19
tests/fm-daemon.test.sh 15140
tests/fm-documentation-audiences.test.sh 572
tests/fm-fleet-snapshot-view.test.sh 5902
tests/fm-fleet-sync.test.sh 16417
tests/fm-gate-refuse.test.sh 2839
tests/fm-gitignore-config.test.sh 28
tests/fm-gotmp.test.sh 308
tests/fm-grok-continuity-live-e2e.test.sh 19
tests/fm-grok-stop-live-e2e.test.sh 19
tests/fm-guard-stale-banner.test.sh 2917
tests/fm-herdr-session-cleanup.test.sh 4802
tests/fm-kimi-harness.test.sh 12590
tests/fm-opencode-primary-live-e2e.test.sh 18
tests/fm-operational-input.test.sh 184
tests/fm-pending-reply.test.sh 7328
tests/fm-pi-primary-live-e2e.test.sh 19
tests/fm-pi-watch-extension.test.sh 16386
tests/fm-pr-check-security.test.sh 199573
tests/fm-procevent.test.sh 42789
tests/fm-public-followup.test.sh 23365
tests/fm-quota-array-dispatch-live-e2e.test.sh 19
tests/fm-secondmate-harness.test.sh 87895
tests/fm-secondmate-lifecycle-e2e.test.sh 4929
tests/fm-secondmate-liveness.test.sh 12553
tests/fm-secondmate-safety.test.sh 24432
tests/fm-secondmate-sync.test.sh 12289
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 27
tests/fm-send-secondmate-marker.test.sh 2136
tests/fm-session-start.test.sh 37289
tests/fm-sessionstart-nudge.test.sh 264
tests/fm-shared-captain-inheritance.test.sh 3506
tests/fm-spawn-dispatch-profile.test.sh 41351
tests/fm-spawn-worktree-settle.test.sh 4598
tests/fm-startup-memory-budget.test.sh 4260
tests/fm-subagent-pretool-check.test.sh 901
tests/fm-supervision-events.test.sh 413
tests/fm-tangle-guard.test.sh 7230
tests/fm-teardown-endpoint-safety.test.sh 1073
tests/fm-teardown.test.sh 23237
tests/fm-test-isolation-proof.test.sh 326
tests/fm-turnend-guard.test.sh 5986
tests/fm-update.test.sh 1894
tests/fm-vendor-auth-probe.test.sh 42796
tests/fm-wake-daemon-lifecycle-e2e.test.sh 4284
tests/fm-wake-queue.test.sh 22787
tests/fm-watch-checkpoint.test.sh 3943
tests/fm-watch-triage.test.sh 113051
tests/fm-watcher-lock.test.sh 98342
EOF
}

portable_serial_weight_for() {
  local want=$1 path ms
  while read -r path ms; do
    if [ "$path" = "$want" ]; then
      printf '%s\n' "$ms"
      return 0
    fi
  done < <(portable_serial_weight_hints)
  printf '%s\n' "$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS"
}

# Longest-processing-time assignment of the serial remainder to
# PORTABLE_SERIAL_SHARDS bins, printing "<shard>\t<script>" for every script.
# Deterministic: candidates are ordered by hint descending then path, and ties
# between equally loaded bins always take the lowest bin index.
portable_serial_assignments() {
  local ms script i best best_load
  local -a loads=()
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    loads[i]=0
    i=$((i + 1))
  done
  while IFS=$'\t' read -r ms script; do
    [ -n "$script" ] || continue
    best=1
    best_load=${loads[1]}
    i=2
    while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
      if [ "${loads[i]}" -lt "$best_load" ]; then
        best_load=${loads[i]}
        best=$i
      fi
      i=$((i + 1))
    done
    loads[best]=$((best_load + ms))
    printf '%s\t%s\n' "$best" "$script"
  done < <(
    while IFS= read -r script; do
      [ -n "$script" ] || continue
      printf '%s\t%s\n' "$(portable_serial_weight_for "$script")" "$script"
    done < <(list_portable_serial) | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2
  )
}

# Parse "<k>of<n>" from a portable-serial shard lane and echo <k>, refusing when
# <n> disagrees with this script's configured count so a CI matrix built for a
# different shard count fails loudly instead of dropping tests.
portable_serial_shard_index() {
  local lane=$1 spec index count
  spec=${lane#portable-serial-}
  index=${spec%%of*}
  count=${spec#*of}
  case "$spec" in
    *of*) ;;
    *) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$index" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$count" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  if [ "$count" -ne "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' asks for $count portable serial shards but this runner is configured for $PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  if [ "$index" -lt 1 ] || [ "$index" -gt "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' shard index is outside 1..$PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  printf '%s\n' "$index"
}

select_proven_isolated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 s shard idx found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-serial)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_serial)
      ;;
    portable-serial-*)
      # One separate-runner shard of the same remainder, still serial in itself.
      shard=$(portable_serial_shard_index "$want")
      while IFS=$'\t' read -r idx s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done < <(portable_serial_assignments)
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    native-backend-gated)
      select_family native-backend-gated
      found=1
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp missing extra a b shard
  local -a saved_scripts=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-coverage.XXXXXX")

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"

  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial (whole lane and each CI shard) + required-runtime lane listings without
  # disturbing a caller's selection.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  : >"$tmp/serial_shards_raw"
  shard=1
  while [ "$shard" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    SCRIPTS=()
    select_lane "portable-serial-${shard}of${PORTABLE_SERIAL_SHARDS}"
    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
      log "coverage guard: portable serial shard $shard of $PORTABLE_SERIAL_SHARDS is empty"
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    printf '%s\n' "${SCRIPTS[@]}" >>"$tmp/serial_shards_raw"
    shard=$((shard + 1))
  done
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  SCRIPTS=()
  select_family native-backend-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/native"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  # Every serial script runs in exactly one CI shard: no duplicate work across
  # runners, and no script silently left out of the required lane.
  LC_ALL=C sort "$tmp/serial_shards_raw" | uniq -d >"$tmp/serial_shard_dups"
  if [ -s "$tmp/serial_shard_dups" ]; then
    log "coverage guard: portable serial shards share scripts:"
    cat "$tmp/serial_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/serial_shards_raw" >"$tmp/serial_shards"
  missing=$(comm -23 "$tmp/serial" "$tmp/serial_shards" || true)
  extra=$(comm -13 "$tmp/serial" "$tmp/serial_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable serial shards must equal the portable serial lane"
    [ -z "$missing" ] || { log "missing from serial shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond serial lane:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  for pair in "shards_union:serial" "shards_union:herdr" "shards_union:native" \
    "serial:herdr" "serial:native" "herdr:native"; do
    a=${pair%%:*}
    b=${pair#*:}
    comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" "$tmp/native" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + required-runtime families must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list"
      comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s serial=%s serial_shards=%s herdr=%s native=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$PORTABLE_SERIAL_SHARDS" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')" \
    "$(wc -l <"$tmp/native" | tr -d ' ')"
  rm -rf "$tmp"
  return 0
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--aggregate-json requires python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
total = 0
wall_ms = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "critical_path_duration_ms": wall_ms,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"FM_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} critical_path_duration_ms={wall_ms}")
PY
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    tests/*|./tests/*)
      p=${p#./}
      printf '%s\n' "$p"
      ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# Append unique relative-or-absolute script paths to SCRIPTS.
add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s base fam found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1 fixture_ref
  case "$path" in
    tests/fm-test-run.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    tests/fm-backend-herdr-eventwait.test.py)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/fm-test-run.sh|bin/fm-test-isolation-proof.sh)
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-herdr-session-cleanup.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' zellij
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' cmux
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' orca
      ;;
    bin/fm-backend.sh|bin/fm-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-watch*|bin/fm-wake*|bin/fm-refill.sh|\
    bin/fm-classify-lib.sh|bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/fm-startup-memory-budget.sh|bin/fm-startup-memory-budget-lib.sh)
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-secondmate*|bin/fm-remote*|bin/fm-on.sh|bin/fm-home-seed.sh|\
    bin/fm-backlog-handoff.sh|bin/fm-backlog-receive.sh|bin/fm-procevent-remote-reply.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*)
      printf '%s\n' secondmate
      ;;
    bin/fm-session-start.sh|bin/fm-bootstrap.sh|bin/fm-fleet-sync.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*|bin/fm-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-sessionstart-run.sh|.claude/settings.json|.codex/hooks.json|\
    .pi/extensions/fm-primary-turnend-guard.ts)
      # The run tier's two harness-supplied facts (source vocabulary and
      # context-reset stdout injection) only show up against a real harness.
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
      ;;
    bin/fm-timeout-lib.sh)
      # The shared hard bound: session start's runtime bound, the fleet/bearings
      # snapshots, and the vendor auth probe all depend on it.
      printf '%s\n' session-bootstrap
      printf '%s\n' snapshot-bearings
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-pr-*|bin/fm-merge-execute.sh|bin/fm-merge-local.sh|bin/fm-test-inventory.sh|bin/fm-teardown.sh|bin/fm-review-diff.sh|\
    bin/fm-x-*|bin/fm-check*)
      printf '%s\n' pr-forge
      ;;
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|\
    bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh)
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-install-zellij.sh)
      printf '%s\n' pure-contract-unit
      # The pinned native installer is part of the required native lane's
      # provisioning contract.
      printf '%s\n' native-backend-gated
      ;;
    bin/fm-lint.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-crew-state.sh|\
    bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
    bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
    bin/fm-vendor-auth-probe.sh|\
    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-promote.sh|\
    bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    .agents/skills/quota-array-dispatch/SKILL.md)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/*/SKILL.md)
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/fm-test-portable-shards.md|docs/fm-test-isolation-proof.md|\
    docs/fm-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/lib.sh|tests/*-helpers.sh)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/fixtures/*/*)
      # A fixture belongs to whichever suite reads its directory, found by the
      # same reference scan used for shared helpers. Keyed on the directory
      # rather than the file so adding a fixture selects the same suite.
      # A removed fixture directory has no consuming suite left to select.
      fixture_ref=${path#tests/fixtures/}
      fixture_ref=${fixture_ref%%/*}
      if [ -d "tests/fixtures/$fixture_ref" ]; then
        families_for_test_reference "fixtures/$fixture_ref" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    bin/*)
      # A deleted script has no consuming suite left to select, the same rule
      # the fixture case above applies. Refusing on its absent mapping would
      # make every retirement branch unable to select its changed tests.
      if [ -e "$path" ]; then
        families_for_test_reference "$(basename "$path")" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    README.md|LICENSE|assets/*|docs/*|.gitignore)
      ;;
    *)
      families_for_test_reference "$path" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(family_for_basename "$(basename "$s")")" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    fam=$(family_for_basename "$(basename "$s")")
    keep=1
    for ex in "${EXCLUDE_FAMILIES[@]}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! command -v python3 >/dev/null 2>&1; then
    die "--json requires python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, family, runtime, requirement, exit_s, dur_s, gate, outcome = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "runtime_gate": runtime,
            "gate_requirement": requirement,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
            "gate_outcome": outcome,
        })

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --progress-journal)
      [ "$#" -gt 1 ] || die "--progress-journal requires a directory"
      [ -n "$2" ] || die "--progress-journal requires a non-empty directory"
      PROGRESS_JOURNAL=$2
      shift 2
      ;;
    --progress-journal=*)
      PROGRESS_JOURNAL=${1#--progress-journal=}
      [ -n "$PROGRESS_JOURNAL" ] || die "--progress-journal requires a non-empty directory"
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    --runtime-gate)
      [ "$#" -gt 1 ] || die "--runtime-gate requires <runtime>=required|optional"
      parse_runtime_gate_declaration "$2"
      shift 2
      ;;
    --runtime-gate=*)
      parse_runtime_gate_declaration "${1#--runtime-gate=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  run_coverage_guard
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

case "${MODE:-}" in
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

apply_exclude_families
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "${#RUNTIME_GATE_DECLARATIONS[@]}" -gt 0 ]; then
  runtime_gate_selection=$(printf '%s\n' "${RUNTIME_GATE_DECLARATIONS[@]}" | tr '\t' '=' | paste -sd, -)
  SELECTION_DESC="${SELECTION_DESC};runtime-gate=$runtime_gate_selection"
fi
if [ "$JOBS" -gt 1 ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

validate_required_runtime_gate_selections || exit 1

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    printf '%s\n' "$s"
  done
  exit 0
fi

if [ "${#SCRIPTS[@]}" -eq 0 ] && [ -z "$PROGRESS_JOURNAL" ]; then
  log "nothing to run"
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0\n'
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    started=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$started" "$started" \
      "empty" 0 0 0 0 "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit 0
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# --jobs N>1 only for the proven-isolated set. Stateful families stay serial.
if [ "$JOBS" -gt 1 ]; then
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    if ! is_proven_isolated_script "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list). Stateful families stay serial."
    fi
  done
fi

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
SERIAL_CHILD_PID=
SERIAL_TEE_PID=
: >"$RECORDS"
: >"$FAMILIES_TSV"

# shellcheck disable=SC2329 # Invoked indirectly by the cleanup and worker signal traps.
terminate_and_reap_process_tree() {
  local root=$1 idx=0 parent children child seen pid grace=0 running state
  local -a process_tree_pids=()
  if ! kill -STOP "$root" 2>/dev/null; then
    wait "$root" 2>/dev/null || true
    return
  fi
  process_tree_pids[0]=$root
  while [ "$idx" -lt "${#process_tree_pids[@]}" ]; do
    parent=${process_tree_pids[$idx]}
    children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$parent" '$2 == parent { print $1 }' || true)
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      seen=0
      for pid in "${process_tree_pids[@]}"; do
        if [ "$pid" = "$child" ]; then
          seen=1
          break
        fi
      done
      if [ "$seen" -eq 0 ] && kill -STOP "$child" 2>/dev/null; then
        process_tree_pids[${#process_tree_pids[@]}]=$child
      fi
    done <<<"$children"
    idx=$((idx + 1))
  done
  for pid in "${process_tree_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${process_tree_pids[@]}"; do
    kill -CONT "$pid" 2>/dev/null || true
  done
  while [ "$grace" -lt 100 ]; do
    running=0
    for pid in "${process_tree_pids[@]}"; do
      state=$(ps -o stat= -p "$pid" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
      case "$state" in
        ""|Z*) ;;
        *) running=1; break ;;
      esac
    done
    [ "$running" -eq 1 ] || break
    sleep 0.01
    grace=$((grace + 1))
  done
  for pid in "${process_tree_pids[@]}"; do
    kill -STOP "$pid" 2>/dev/null || true
  done
  idx=0
  while [ "$idx" -lt "${#process_tree_pids[@]}" ]; do
    parent=${process_tree_pids[$idx]}
    children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$parent" '$2 == parent { print $1 }' || true)
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      seen=0
      for pid in "${process_tree_pids[@]}"; do
        if [ "$pid" = "$child" ]; then
          seen=1
          break
        fi
      done
      if [ "$seen" -eq 0 ] && kill -STOP "$child" 2>/dev/null; then
        process_tree_pids[${#process_tree_pids[@]}]=$child
      fi
    done <<<"$children"
    idx=$((idx + 1))
  done
  for pid in "${process_tree_pids[@]}"; do
    state=$(ps -o stat= -p "$pid" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
    case "$state" in
      ""|Z*) ;;
      *) kill -KILL "$pid" 2>/dev/null || true ;;
    esac
  done
  wait "$root" 2>/dev/null || true
  grace=0
  while [ "$grace" -lt 100 ]; do
    running=0
    for pid in "${process_tree_pids[@]}"; do
      state=$(ps -o stat= -p "$pid" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
      case "$state" in
        ""|Z*) ;;
        *) running=1; break ;;
      esac
    done
    [ "$running" -eq 1 ] || break
    sleep 0.01
    grace=$((grace + 1))
  done
}

process_group_has_running_members() {
  ps -eo pgid=,stat= 2>/dev/null \
    | awk -v group="$1" '$1 == group && $2 !~ /^Z/ { found=1; exit } END { exit !found }'
}

terminate_and_reap_process_group() {
  local group=$1 grace=0
  if ! kill -STOP -- "-$group" 2>/dev/null; then
    wait "$group" 2>/dev/null || true
    return
  fi
  kill -TERM -- "-$group" 2>/dev/null || true
  kill -CONT -- "-$group" 2>/dev/null || true
  while [ "$grace" -lt 100 ] && process_group_has_running_members "$group"; do
    sleep 0.01
    grace=$((grace + 1))
  done
  kill -STOP -- "-$group" 2>/dev/null || true
  kill -KILL -- "-$group" 2>/dev/null || true
  wait "$group" 2>/dev/null || true
  grace=0
  while [ "$grace" -lt 100 ] && process_group_has_running_members "$group"; do
    sleep 0.01
    grace=$((grace + 1))
  done
}

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT and signal traps through cleanup_run.
terminate_and_reap_background_job() {
  local pid=$1 group
  group=$(ps -o pgid= -p "$pid" 2>/dev/null | awk 'NR == 1 { gsub(/[[:space:]]/, "", $1); print $1 }' || true)
  if [ "$group" = "$pid" ]; then
    terminate_and_reap_process_group "$group"
  else
    terminate_and_reap_process_tree "$pid"
  fi
}

# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
cleanup_run() {
  local rc=$? pid run_state journal_rc=0 serial_child_owned=0 cleanup_pids="$RUN_TMP/cleanup-pids"
  trap - EXIT INT TERM HUP
  case "$rc" in
    129|130|143)
      journal_mark_interrupted_workers || true
      run_state=interrupted
      ;;
    0) run_state=passed ;;
    *) run_state=failed ;;
  esac
  journal_write_run_state "$run_state" "$rc" || journal_rc=$?
  if [ "$rc" -eq 0 ] && [ "$journal_rc" -ne 0 ]; then
    rc=$journal_rc
  fi
  jobs -p >"$cleanup_pids" 2>/dev/null || true
  if [ -n "$SERIAL_CHILD_PID" ]; then
    terminate_and_reap_process_group "$SERIAL_CHILD_PID"
    serial_child_owned=1
  fi
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if [ "$pid" = "$SERIAL_CHILD_PID" ] || [ "$pid" = "$SERIAL_TEE_PID" ]; then
      continue
    fi
    terminate_and_reap_background_job "$pid"
    if [ -n "$SERIAL_TEE_PID" ]; then
      serial_child_owned=1
    fi
  done <"$cleanup_pids"
  if [ -n "$SERIAL_TEE_PID" ]; then
    if [ "$serial_child_owned" -eq 1 ]; then
      wait "$SERIAL_TEE_PID" 2>/dev/null || true
    else
      terminate_and_reap_process_tree "$SERIAL_TEE_PID"
    fi
  fi
  rm -rf "$RUN_TMP"
  exit "$rc"
}

trap cleanup_run EXIT
trap 'journal_handle_signal 130' INT
trap 'journal_handle_signal 143' TERM
trap 'journal_handle_signal 129' HUP

RUN_STARTED_ISO=$(now_iso)
RUN_STARTED_MS=$(now_ms)
RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
journal_initialize
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0\n'
  if [ -n "$JSON_PATH" ]; then
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$RUN_STARTED_ISO" "$RUN_STARTED_ISO" \
      "empty" 0 0 0 0 "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  fi
  exit 0
fi

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

record_script_result() {
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5 journal_slot=$6
  local base family runtime requirement gate_skip gate_outcome fail_delta
  local runtime_signal runtime_signal_count runtime_signal_line terminal_state terminal_tuple worker_id
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  runtime=$(runtime_gate_for_basename "$base")
  requirement=$(runtime_gate_requirement "$runtime")

  gate_skip=false
  runtime_signal=
  runtime_signal_count=0
  while IFS= read -r runtime_signal_line; do
    runtime_signal=$runtime_signal_line
    runtime_signal_count=$((runtime_signal_count + 1))
  done < <(grep '^FM_TEST_RUNTIME_GATE ' "$out" 2>/dev/null || true)

  if [ "$rc" -ne 0 ]; then
    gate_outcome=failed
  elif [ "$runtime" != none ]; then
    case "$runtime_signal_count:$runtime_signal" in
      "1:FM_TEST_RUNTIME_GATE runtime=$runtime outcome=exercised")
        gate_outcome=exercised
        ;;
      "1:FM_TEST_RUNTIME_GATE runtime=$runtime outcome=unavailable")
        gate_skip=true
        SKIPPED_GATE=$((SKIPPED_GATE + 1))
        if [ "$requirement" = required ]; then
          gate_outcome=unexpectedly-skipped
          rc=1
          log "required runtime gate not exercised: runtime=$runtime script=$script"
        else
          gate_outcome=intentionally-unavailable
        fi
        ;;
      *)
        gate_skip=true
        SKIPPED_GATE=$((SKIPPED_GATE + 1))
        gate_outcome=unexpectedly-skipped
        rc=1
        log "runtime gate evidence missing or invalid: runtime=$runtime script=$script markers=$runtime_signal_count"
        ;;
    esac
  elif detect_gate_skip "$out"; then
    gate_skip=true
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
    gate_outcome=legacy-skip
  else
    gate_outcome=exercised
  fi

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
    gate_outcome=unexpectedly-skipped
  fi

  terminal_state=$(journal_terminal_state_for_exit "$rc")
  terminal_tuple="$terminal_state"$'\t'"$rc"$'\t'"$duration"
  if [ "$journal_slot" = serial ]; then
    JOURNAL_ACTIVE_SERIAL_TERMINAL=$terminal_tuple
    worker_id=$JOURNAL_ACTIVE_SERIAL_WORKER
  else
    JOURNAL_PARALLEL_TERMINALS[journal_slot]=$terminal_tuple
    worker_id=${JOURNAL_PARALLEL_WORKERS[$journal_slot]}
  fi
  journal_transition "$worker_id" "$terminal_state" "$script" 2 "$rc" "$duration"

  printf 'FM_TEST_GATE %s runtime=%s requirement=%s outcome=%s\n' \
    "$script" "$runtime" "$requirement" "$gate_outcome"

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s gate_outcome=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip" "$gate_outcome"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$runtime" "$requirement" "$rc" "$duration" "$gate_skip" "$gate_outcome" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

run_one_serial() {
  local script=$1
  local base family runtime requirement out fifo begin_iso begin_ms end_ms end_iso duration rc child_pid monitor_mode=''
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  runtime=$(runtime_gate_for_basename "$base")
  requirement=$(runtime_gate_requirement "$runtime")
  out="$RUN_TMP/out.$TOTAL"
  begin_iso=$(now_iso)
  begin_ms=$(now_ms)

  printf 'FM_TEST_BEGIN %s %s family=%s runtime_gate=%s gate_requirement=%s\n' \
    "$begin_iso" "$script" "$family" "$runtime" "$requirement"
  journal_start_worker serial "$((TOTAL + 1))" "serial-$((TOTAL + 1))" "$script"

  set +e
  fifo="$RUN_TMP/serial.$TOTAL.fifo"
  mkfifo "$fifo"
  tee "$out" <"$fifo" &
  SERIAL_TEE_PID=$!
  case $- in *m*) monitor_mode=1 ;; esac
  set -m
  bash "$script" >"$fifo" 2>&1 &
  SERIAL_CHILD_PID=$!
  [ -n "$monitor_mode" ] || set +m
  wait "$SERIAL_CHILD_PID"
  rc=$?
  wait "$SERIAL_TEE_PID" 2>/dev/null || true
  SERIAL_CHILD_PID=
  SERIAL_TEE_PID=
  rm -f "$fifo"
  set -e
  : "${rc:=1}"

  end_ms=$(now_ms)
  end_iso=$(now_iso)
  duration=$((end_ms - begin_ms))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso" serial
  JOURNAL_ACTIVE_SERIAL_WORKER=
  JOURNAL_ACTIVE_SERIAL_SCRIPT=
  JOURNAL_ACTIVE_SERIAL_TERMINAL=
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    run_one_serial "$script"
  done
else
  # Bounded concurrent execution for proven-isolated scripts only. Each worker
  # gets a private mode-0700 TMPDIR so mktemp roots cannot collide. Retries are
  # never used as a green strategy.
  declare -a WORKER_PIDS=()
  declare -a WORKER_IDX=()
  declare -a WORKER_SCRIPTS=()
  worker_n=0
  active_workers=0

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    set +e
    wait "$pid"
    terminate_and_reap_process_group "$pid"
    set -e
    work="$RUN_TMP/w$idx"
    rc=$(cat "$work/exit" 2>/dev/null || echo 1)
    duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
    out="$work/output"
    end_iso=$(now_iso)
    # Replay captured output after the worker finishes so markers stay ordered.
    if [ -s "$out" ]; then
      cat "$out"
    fi
    mode=$(stat -c %a "$work" 2>/dev/null || stat -f %Lp "$work" 2>/dev/null || echo unknown)
    case "$mode" in
      700|0700) ;;
      *)
        log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
        rc=1
        ;;
    esac
    record_script_result "$script" "$rc" "$duration" "$out" "$end_iso" "$slot"
    unset 'JOURNAL_PARALLEL_WORKERS[slot]'
    unset 'JOURNAL_PARALLEL_SCRIPTS[slot]'
    unset 'JOURNAL_PARALLEL_TERMINALS[slot]'
  }

  worker_pid_is_running() {
    local want=$1 running inventory="$RUN_TMP/running-pids"
    # Keep `jobs` in this shell. A process substitution runs it in a subshell
    # without this shell's job table on Bash 3.2/5.x, falsely reporting every
    # worker complete and making the scheduler wait for the oldest PID.
    jobs -r -p >"$inventory"
    while IFS= read -r running; do
      [ "$running" = "$want" ] && return 0
    done <"$inventory"
    return 1
  }

  wait_one_completed_job_worker() {
    local slot work
    while :; do
      for slot in "${!WORKER_PIDS[@]}"; do
        work="$RUN_TMP/w${WORKER_IDX[$slot]}"
        if [ -f "$work/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
          wait_one_job_worker "$slot"
          return
        fi
      done
      sleep 0.01
    done
  }

  for script in "${SCRIPTS[@]}"; do
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    worker_n=$((worker_n + 1))
    work="$RUN_TMP/w$worker_n"
    mkdir -p "$work/tmp"
    chmod 0700 "$work" "$work/tmp" || die "could not chmod 0700 worker root $work"
    base=$(basename "$script")
    family=$(family_for_basename "$base")
    runtime=$(runtime_gate_for_basename "$base")
    requirement=$(runtime_gate_requirement "$runtime")
    printf 'FM_TEST_BEGIN %s %s family=%s runtime_gate=%s gate_requirement=%s\n' \
      "$(now_iso)" "$script" "$family" "$runtime" "$requirement"
    worker_id="parallel-$worker_n"
    journal_start_worker parallel "$worker_n" "$worker_id" "$script"
    monitor_mode=
    case $- in *m*) monitor_mode=1 ;; esac
    set -m
    (
      set +m
      set +e
      child_pid=
      # shellcheck disable=SC2329 # Registered by the worker signal traps below.
      worker_signal_exit() {
        local signal_rc=$1 pid signal_pids="$work/signal-pids"
        trap - INT TERM HUP
        if [ -n "$child_pid" ]; then
          terminate_and_reap_process_tree "$child_pid"
        else
          jobs -p >"$signal_pids" 2>/dev/null || true
          while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            terminate_and_reap_process_tree "$pid"
          done <"$signal_pids"
        fi
        exit "$signal_rc"
      }
      trap 'worker_signal_exit 130' INT
      trap 'worker_signal_exit 143' TERM
      trap 'worker_signal_exit 129' HUP
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
        FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      bash "$script" >"$work/output" 2>&1 &
      child_pid=$!
      wait "$child_pid"
      rc=$?
      trap - INT TERM HUP
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    WORKER_PIDS[worker_n]=$!
    [ -n "$monitor_mode" ] || set +m
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'FM_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Slowest scripts (top 15) from records.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k6,6nr "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _runtime _requirement _rc duration _gate _outcome; do
    printf 'FM_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  log "wrote timing artifact: $JSON_PATH"
fi

exit "$AGG_RC"
