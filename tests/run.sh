#!/bin/sh
# Authoritative entry point for every firstmate behavior test.
set -u

TEST_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$TEST_DIR/.." && pwd -P)
SEAL=$TEST_DIR/test-seal.py
RUN_ONE=$TEST_DIR/run-one.py
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
skip_herdr=${FM_TEST_SKIP_HERDR:-0}
result=0

case "$skip_herdr" in 0|1) ;; *) echo "test admission refused: FM_TEST_SKIP_HERDR must be 0 or 1" >&2; exit 97 ;; esac
if [ "${1:-}" = --skip-herdr ]; then
  skip_herdr=1
  shift
fi

python3 "$SEAL" verify || exit $?
if [ "$#" -eq 0 ]; then
  set -- "$TEST_DIR"/*.test.sh
fi

suite_root=$(mktemp -d "${TMPDIR:-/tmp}/firstmate-test-suite.XXXXXX") || exit 1
suite_root=$(cd "$suite_root" && pwd -P)
chmod 700 "$suite_root"
runner_pid=$$
original_path=$PATH
real_herdr=$(command -v herdr 2>/dev/null || true)
lab_state=$suite_root/herdr-state
mkdir -p "$lab_state"
chmod 700 "$lab_state"

# Invoked by the trap installed immediately below.
# shellcheck disable=SC2329
cleanup_suite() {
  status=$?
  if find "$suite_root/herdr-state" -type f -name '*.fleet-state.json' -print -quit 2>/dev/null | grep -q .; then
    printf 'test isolation violation: retained owned suite state after failed Herdr teardown: %s\n' \
      "$suite_root" >&2
    status=97
  else
    rm -rf "$suite_root"
  fi
  trap - EXIT HUP INT TERM
  exit "$status"
}
trap cleanup_suite EXIT HUP INT TERM

write_token() {
  token=$1
  test_script=$2
  capability=$3
  umask 077
  python3 - "$token" "$runner_pid" "$test_script" "$capability" <<'PY'
import json
from pathlib import Path
import sys

path, runner_pid, test, capability = sys.argv[1:]
Path(path).write_text(json.dumps({
    "runner_pid": int(runner_pid),
    "test": test,
    "capability": capability,
}) + "\n", encoding="utf-8")
PY
}

run_admitted() {
  test_script=$1
  capability=$2
  token=$suite_root/admission.json
  rm -f "$token"
  write_token "$token" "$test_script" "$capability" || return 1
  PATH="$TEST_DIR/herdr-guard-bin:$original_path" \
  FM_TEST_RUNNER_ACTIVE=firstmate-test-runner-v1 \
  FM_TEST_RUNNER_PID="$runner_pid" \
  FM_TEST_RUNNER_TOKEN="$token" \
  FM_TEST_SUITE_ROOT="$suite_root" \
  FM_TEST_REPO_ROOT="$ROOT" \
  FM_TEST_CURRENT_TEST="$test_script" \
  FM_TEST_HERDR_CAPABILITY="$capability" \
  FM_TEST_SKIP_HERDR="$skip_herdr" \
    python3 "$RUN_ONE" bash "$test_script"
}

run_herdr_lab() (
  test_script=$1
  capability=$2
  test_name=$(basename "$test_script" .test.sh)
  session=$(PATH="$original_path" "$LAB_HELPER" name "suite-$test_name") || exit 1
  tripwire=$lab_state/$session.fleet-state.json
  lab_prepared=0
  # Invoked by the trap installed immediately below.
  # shellcheck disable=SC2329
  cleanup_lab() {
    status=$?
    if [ "$lab_prepared" -eq 1 ] || [ -f "$tripwire" ]; then
      FM_HERDR_LAB_STATE_DIR="$lab_state" PATH="$original_path" \
        "$LAB_HELPER" teardown "$session" || status=1
    fi
    trap - EXIT HUP INT TERM
    exit "$status"
  }
  trap cleanup_lab EXIT HUP INT TERM
  # Provision owns preparation internally. Mark cleanup as owed before the
  # call so a partial prepare/provision failure still takes the guarded path.
  lab_prepared=1
  FM_HERDR_LAB_STATE_DIR="$lab_state" PATH="$original_path" \
    "$LAB_HELPER" provision "$session" || exit 97
  token=$suite_root/admission.json
  rm -f "$token"
  write_token "$token" "$test_script" "$capability" || exit 1
  PATH="$TEST_DIR/herdr-guard-bin:$original_path" \
  HERDR_SESSION="$session" \
  HERDR_LAB_HELPER="$LAB_HELPER" \
  FM_HERDR_LAB_STATE_DIR="$lab_state" \
  FM_TEST_ORIGINAL_PATH="$original_path" \
  FM_TEST_REAL_HERDR="$real_herdr" \
  FM_TEST_HERDR_LAB_SESSION="$session" \
  FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
  FM_TEST_RUNNER_ACTIVE=firstmate-test-runner-v1 \
  FM_TEST_RUNNER_PID="$runner_pid" \
  FM_TEST_RUNNER_TOKEN="$token" \
  FM_TEST_SUITE_ROOT="$suite_root" \
  FM_TEST_REPO_ROOT="$ROOT" \
  FM_TEST_CURRENT_TEST="$test_script" \
  FM_TEST_HERDR_CAPABILITY="$capability" \
    python3 "$RUN_ONE" bash "$test_script"
)

for requested in "$@"; do
  capability=$(python3 "$SEAL" capability "$requested") || exit $?
  case "$requested" in /*) test_script=$requested ;; *) test_script=$ROOT/$requested ;; esac
  test_script=$(cd "$(dirname "$test_script")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$test_script")")
  printf '== %s ==\n' "${test_script#"$ROOT/"}"
  case "$capability" in
    hermetic)
      run_admitted "$test_script" "$capability" || result=1
      ;;
    herdr-lab|herdr-mixed)
      if [ "$skip_herdr" -eq 1 ]; then
        if [ "$capability" = herdr-mixed ]; then
          run_admitted "$test_script" "$capability" || result=1
        else
          printf 'skip: %s declares real Herdr lifecycle; --skip-herdr selected\n' "${test_script#"$ROOT/"}"
        fi
      elif [ -z "$real_herdr" ] || ! command -v jq >/dev/null 2>&1; then
        printf 'test admission refused: %s declares real Herdr lifecycle, but herdr and jq are not both available; use --skip-herdr explicitly\n' \
          "${test_script#"$ROOT/"}" >&2
        result=1
      else
        run_herdr_lab "$test_script" "$capability" || result=1
      fi
      ;;
  esac
done

exit "$result"
