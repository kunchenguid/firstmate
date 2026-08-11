#!/usr/bin/env bash
# Run every firstmate behavior test with bounded optional parallelism.
#
# FM_TEST_JOBS controls the number of test processes in flight. It defaults to
# min(4, nproc) and FM_TEST_JOBS=1 preserves the legacy serial loop. Every test
# receives a private TMPDIR and GOTMPDIR so temporary state cannot collide.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if ! bash "$ROOT/bin/fm-no-mistakes-pr-target-guard.sh"; then
  printf '%s\n' 'FAIL: PR target guard rejected this checkout; tests were not started' >&2
  exit 1
fi

if ! command -v tmux >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: tmux is required for e2e tests' >&2
  exit 1
fi
if ! tmux -V; then
  printf '%s\n' 'FAIL: tmux could not report its version' >&2
  exit 1
fi

default_jobs=1
cpu_count=
if command -v nproc >/dev/null 2>&1; then
  cpu_count=$(nproc 2>/dev/null || true)
elif command -v getconf >/dev/null 2>&1; then
  cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
fi
case "$cpu_count" in
  ''|*[!0-9]*) ;;
  0) ;;
  *)
    default_jobs=$cpu_count
    [ "$default_jobs" -le 4 ] || default_jobs=4
    ;;
esac

jobs=${FM_TEST_JOBS:-$default_jobs}
case "$jobs" in
  ''|*[!0-9]*)
    printf 'FAIL: FM_TEST_JOBS must be a positive integer (got %s)\n' "$jobs" >&2
    exit 1
    ;;
esac
if [ "$jobs" -lt 1 ]; then
  printf 'FAIL: FM_TEST_JOBS must be at least 1 (got %s)\n' "$jobs" >&2
  exit 1
fi

mapfile -t tests < <(
  { compgen -G 'tests/*.test.sh' || true; compgen -G 'tests/*.test.py' || true; } | sort
)
if [ "${#tests[@]}" -eq 0 ]; then
  printf '%s\n' 'FAIL: no behavior test files found' >&2
  exit 1
fi

gate_test="$ROOT/tests/fm-gate-refuse.test.sh"
if [ -f "$gate_test" ] && ! bash "$gate_test"; then
  printf '%s\n' 'FAIL: gate-refusal test failed; tests were not started' >&2
  exit 1
fi

base_tmp=${TMPDIR:-/tmp}
if ! mkdir -p "$base_tmp"; then
  printf 'FAIL: could not create temporary base %s\n' "$base_tmp" >&2
  exit 1
fi
suite_tmp=$(mktemp -d "$base_tmp/fm-behavior-tests.XXXXXX") || {
  printf 'FAIL: could not create an isolated behavior-test root\n' >&2
  exit 1
}
test_root="$suite_tmp/repo"
if ! git clone --quiet --no-hardlinks "$ROOT" "$test_root"; then
  printf 'FAIL: could not create a normal behavior-test clone\n' >&2
  exit 1
fi
delta_manifest="$suite_tmp/worktree-delta"
if ! {
  git -C "$ROOT" diff --name-only -z HEAD &&
  git -C "$ROOT" ls-files --others --exclude-standard -z
} >"$delta_manifest"; then
  printf 'FAIL: could not enumerate current working-tree contents\n' >&2
  exit 1
fi
copy_worktree_delta() {
  local path src dst
  while IFS= read -r -d '' path; do
    src="$ROOT/$path"
    dst="$test_root/$path"
    if [ -e "$src" ] || [ -L "$src" ]; then
      mkdir -p "$(dirname "$dst")" || return 1
      rm -rf -- "$dst" || return 1
      cp -a -- "$src" "$dst" || return 1
    else
      rm -rf -- "$dst" || return 1
    fi
  done <"$delta_manifest"
}
if ! copy_worktree_delta; then
  printf 'FAIL: could not overlay current working-tree contents\n' >&2
  exit 1
fi
if [ -f "$test_root/bin/fm-gate-refuse-lib.sh" ]; then
  cat > "$test_root/bin/fm-gate-refuse-lib.sh" <<'SH'
FM_GATE_REFUSE_EXIT=3
fm_refuse_if_gate_agent() { return 0; }
SH
fi
cleanup() {
  rm -rf -- "$suite_tmp"
}
trap cleanup EXIT

# These tests spawn real watcher processes or provision a real Herdr lab and
# wait on bounded pid-file, heartbeat, beacon, and lab-readiness windows.
# Sharing CPU with parallel jobs makes those bounds flaky on a loaded host, so
# they run alone in a serial phase.
serial_test_ids='
fm-codex-session-lock
fm-pr-check-security
fm-watch-session
fm-watch-triage
fm-watcher-lock
fm-watcher-protocol
fm-backend-herdr-presentation-e2e
fm-backend-herdr-prune-safety-e2e
fm-backend-herdr-respawn-idem-e2e
fm-backend-herdr-smoke
fm-herdr-lab
fm-herdr-session-cleanup-e2e
'
is_serial_test() {
  local candidate=$1 serial_id
  for serial_id in $serial_test_ids; do
    [ "$candidate" != "$serial_id" ] || return 0
  done
  return 1
}

mapfile -t all_tests < <(
  cd "$test_root" || exit 1
  for test_path in tests/*.test.sh tests/*.test.py; do
    [ -f "$test_path" ] || continue
    [ "$test_path" = tests/fm-gate-refuse.test.sh ] || printf '%s\n' "$test_path"
  done
)
tests=()
serial_tests=()
for test_path in "${all_tests[@]}"; do
  test_name=${test_path##*/}
  test_id=${test_name%.test.sh}
  [ "$test_id" != "$test_name" ] || test_id=${test_name%.test.py}
  if is_serial_test "$test_id"; then
    serial_tests+=("$test_path")
  else
    tests+=("$test_path")
  fi
done
total=${#tests[@]}
serial_total=${#serial_tests[@]}
active_jobs=$jobs
[ "$active_jobs" -le "$total" ] || active_jobs=$total
[ "$active_jobs" -ge 1 ] || active_jobs=1
printf 'Running %s behavior tests with %s parallel job(s)\n' "$total" "$active_jobs"
if [ "$serial_total" -ne 0 ]; then
  printf 'Reserving %s timing-sensitive test(s) for a serial phase\n' "$serial_total"
fi

run_one() {
  local test_path=$1 job_root=$2 log_path=$3
  (
    cd "$test_root" || exit 1
    # A Firstmate supervisor may export its operational home into the shell that
    # launches this gate. Do not let tests share that live state; fixture tests
    # that need a home set their own FM_* overrides explicitly.
    unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
      FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
    if [ "${FM_HERDR_ALLOW_AMBIENT:-0}" != 1 ]; then
      unset HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_TAB_ID \
        HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
      if [ -z "${FM_BACKEND:-}" ]; then
        export FM_BACKEND=tmux
      fi
    fi
    export TMPDIR="$job_root/tmp"
    export GOTMPDIR="$job_root/gotmp"
    case "$test_path" in
      *.test.py) python3 "$test_path" ;;
      *) bash "$test_path" ;;
    esac
  ) >"$log_path" 2>&1
}

failed_count=0

# Runs every path in the global phase_tests array, at most phase_jobs at a time.
run_phase() {
  local phase_total=${#phase_tests[@]} index=0
  local test_path test_name test_id job_root log_path test_rc batch_index
  local pids batch_paths batch_logs batch_count
  while [ "$index" -lt "$phase_total" ]; do
    pids=()
    batch_paths=()
    batch_logs=()
    batch_count=0

    while [ "$index" -lt "$phase_total" ] && [ "$batch_count" -lt "$phase_jobs" ]; do
      test_path=${phase_tests[$index]}
      test_name=${test_path##*/}
      test_id=${test_name%.test.sh}
      [ "$test_id" != "$test_name" ] || test_id=${test_name%.test.py}
      job_root="$suite_tmp/$test_id"
      log_path="$job_root/output.log"
      mkdir -p "$job_root/tmp" "$job_root/gotmp"
      printf 'START: %s (TMPDIR=%s GOTMPDIR=%s)\n' "$test_path" "$job_root/tmp" "$job_root/gotmp"
      run_one "$test_path" "$job_root" "$log_path" &
      pids+=("$!")
      batch_paths+=("$test_path")
      batch_logs+=("$log_path")
      index=$((index + 1))
      batch_count=$((batch_count + 1))
    done

    for batch_index in "${!pids[@]}"; do
      test_rc=0
      wait "${pids[$batch_index]}" || test_rc=$?
      if [ "$test_rc" -eq 0 ]; then
        printf 'PASS: %s\n' "${batch_paths[$batch_index]}"
      else
        printf 'FAIL: %s (exit %s)\n' "${batch_paths[$batch_index]}" "$test_rc" >&2
        failed_count=$((failed_count + 1))
      fi
      if [ -s "${batch_logs[$batch_index]}" ]; then
        cat "${batch_logs[$batch_index]}"
      fi
    done
  done
}

if [ "$total" -ne 0 ]; then
  phase_tests=("${tests[@]}")
  phase_jobs=$active_jobs
  run_phase
fi

if [ "$serial_total" -ne 0 ]; then
  printf 'Running %s timing-sensitive test(s) serially\n' "$serial_total"
  phase_tests=("${serial_tests[@]}")
  phase_jobs=1
  run_phase
fi

total=$((total + serial_total))

if [ "$failed_count" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failed_count" >&2
  exit 1
fi
printf 'All %s behavior tests passed\n' "$total"
