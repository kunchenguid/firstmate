#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-cloud-state-lib.sh
. "$ROOT/bin/fm-cloud-state-lib.sh"

run_cloud_credential_is_removed() {
  # The provider account credential a cloud spawn copies into the control home
  # must not outlive the task. docs/azure-workers.md states it never enters the
  # control home at all, and before this owner existed every completed cloud
  # crewmate left a plaintext auth.json there indefinitely.
  local tmp state id
  fm_test_tmproot_into tmp fm-cloud-state
  state="$tmp/state"
  id=cloud-task-1
  mkdir -p "$state/$id.cloud-account" "$state/$id.cloud-payload"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  printf '{}\n' > "$state/$id.cloud-account/settings.json"
  printf 'bundle\n' > "$state/$id.cloud-payload/repo.bundle"
  printf 'brief\n' > "$state/$id.cloud-payload/brief.md"
  printf 'entry\n' > "$state/$id.cloud-entrypoint"
  printf 'env\n' > "$state/$id.cloud-env"
  : > "$state/$id.cloud-execute-dispatched"
  printf '{}\n' > "$state/$id.worker-result.json"
  printf 'log\n' > "$state/$id.worker-execute.log"
  printf '{}\n' > "$state/$id.worker-reconcile.json"

  fm_cloud_state_remove "$state" "$id"

  assert_absent "$state/$id.cloud-account/auth.json" \
    "the provider account credential outlived the task in the control home"
  assert_absent "$state/$id.cloud-account" "the account staging directory survived"
  assert_absent "$state/$id.cloud-payload" "the payload staging directory survived"
  assert_absent "$state/$id.cloud-entrypoint" "the persisted entrypoint survived"
  assert_absent "$state/$id.cloud-env" "the persisted environment survived"
  assert_absent "$state/$id.cloud-execute-dispatched" "the dispatch marker survived"
  assert_absent "$state/$id.worker-result.json" "the worker result survived"
  assert_absent "$state/$id.worker-execute.log" "the execute log survived"
  pass "teardown removes the cloud account credential and its transport state"
}

run_teardown_actually_calls_the_owner() {
  # Driving the library proves the function works and NOT that anything calls
  # it. The first version of this check counted a literal string, so it stayed
  # green when a call was neutered to a no-op, and it hardcoded the terminal
  # count so it could never notice a THIRD success path that had no call at
  # all. It now enumerates every successful terminal in the script and
  # requires a real call statement before each one.
  local script
  script="$ROOT/bin/fm-teardown.sh"
  assert_grep 'fm-cloud-state-lib.sh' "$script" "teardown no longer sources the cloud state owner"
  python3 - "$script" <<'TERMINALS' || fail "a successful teardown terminal does not remove the cloud credential"
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
call = re.compile(r"^\s*fm_cloud_state_remove\s+\"\$STATE\"\s+\"\$ID\"\s*$")

terminals = [i for i, line in enumerate(lines) if re.match(r"^\s*exit 0\s*$", line)]
terminals.append(len(lines) - 1)
assert len(terminals) >= 3, ("expected at least three successful terminals", terminals)

uncovered = []
for index in terminals:
    window_start = 0
    for other in terminals:
        if other < index:
            window_start = max(window_start, other)
    if not any(call.match(lines[i]) for i in range(window_start, index + 1)):
        uncovered.append(index + 1)

assert not uncovered, (
    "these successful teardown terminals never remove the cloud credential (1-indexed lines)",
    uncovered,
)
TERMINALS
  pass "every successful teardown terminal removes the cloud credential"
}

run_cloud_state_survives_set_e() {
  # Teardown runs under `set -e` and removes the task metadata AFTER this. A
  # bare failing rm aborted it there, leaving a half-torn-down task and the
  # credential still present. The harness only sets `set -u`, so this drives
  # the function under production shell options explicitly.
  local tmp state id out status
  fm_test_tmproot_into tmp fm-cloud-state-set-e
  state="$tmp/state"
  id=cloud-task-3
  mkdir -p "$state/$id.cloud-account"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  chmod 0500 "$state/$id.cloud-account"
  out=$(set -e; . "$ROOT/bin/fm-cloud-state-lib.sh"; fm_cloud_state_remove "$state" "$id" 2>&1; echo REACHED)
  status=$?
  chmod 0700 "$state/$id.cloud-account"
  expect_code 0 "$status" "an unremovable credential aborted the caller under set -e"
  assert_contains "$out" "REACHED" "the caller never reached its remaining cleanup"
  assert_contains "$out" "could not remove its staged provider credential" \
    "a credential that could not be removed was not reported"
  pass "a failed credential removal never aborts a caller running under set -e"
}

run_cloud_credential_survives_a_symlinked_directory() {
  # rm -rf on a symlinked cloud-account unlinks the symlink and spares the
  # target, so the by-name removal is what actually guarantees the credential
  # goes. Without it this case leaves the file behind.
  local tmp state id real
  fm_test_tmproot_into tmp fm-cloud-state-symlink
  state="$tmp/state"
  id=cloud-task-4
  real="$tmp/elsewhere"
  mkdir -p "$state" "$real"
  printf '{"refresh":"secret"}\n' > "$real/auth.json"
  ln -s "$real" "$state/$id.cloud-account"

  fm_cloud_state_remove "$state" "$id"

  assert_absent "$real/auth.json" \
    "a symlinked account directory left the credential on disk"
  pass "a symlinked account directory still loses its credential"
}

run_cloud_credential_is_removed
run_teardown_actually_calls_the_owner
run_cloud_state_survives_set_e
run_cloud_credential_survives_a_symlinked_directory

echo "# fm-cloud-state.test.sh: all assertions passed"
