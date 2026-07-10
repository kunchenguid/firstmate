#!/usr/bin/env bash
# Behavior tests for bin/fm-provision-worktree.sh and its fm-spawn integration.
#
# The helper makes a freshly-cut ship/scout worktree run-ready: it reads a per-project
# LOCAL config at config/provision/<project>.toml, copies the listed (gitignored) env
# and credential files into the worktree preserving their relative paths, and runs the
# configured setup_cmd. Provisioning is opt-in (no config = silent no-op) and
# best-effort (a failure warns but must never abort a spawn).
#
# These run the REAL helper as a subprocess against a fake FM_HOME so config resolution
# lands inside the fixture. The fm-spawn side is asserted structurally (the source
# carries the integration contract), matching tests/fm-gotmp.test.sh's approach for a
# spawn path that is too heavy to run end-to-end here.
set -u

# Source lib.sh only for its stateless assertion/reporter helpers. We build our own
# temp tree with a single mktemp -d (per tests/fm-gotmp.test.sh) rather than
# fm_test_tmproot, whose returned dir does not survive its own command-substitution
# EXIT trap.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROVISION="$ROOT/bin/fm-provision-worktree.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-provision-tests.XXXXXX")
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# --- fixture helpers --------------------------------------------------------
#
# Each test gets its own subtree under TMP_ROOT keyed by a unique name:
#   <name>/home  fake FM_HOME (config/provision/ prepared)
#   <name>/src   canonical source dir
#   <name>/wt    the "freshly cut worktree"

# new_case <name> sets HOME_DIR/SRC_DIR/WT_DIR for the case and creates them.
HOME_DIR=''
SRC_DIR=''
WT_DIR=''
new_case() {
  local base="$TMP_ROOT/$1"
  HOME_DIR="$base/home"
  SRC_DIR="$base/src"
  WT_DIR="$base/wt"
  mkdir -p "$HOME_DIR/config/provision" "$SRC_DIR" "$WT_DIR"
}

# write_config <home> <project> <body>: write the project's provision config.
write_config() {
  printf '%s\n' "$3" > "$1/config/provision/$2.toml"
}

# run_provision <home> <project> <worktree>: run the helper, capturing combined
# output into RUN_OUT and the exit code into RUN_RC.
RUN_OUT=
RUN_RC=
run_provision() {
  RUN_OUT=$(FM_HOME="$1" bash "$PROVISION" "$2" "$3" 2>&1)
  RUN_RC=$?
}

# --- tests ------------------------------------------------------------------

test_script_parses() {
  bash -n "$PROVISION" 2>&1 || fail "fm-provision-worktree.sh fails bash -n"
  pass "fm-provision-worktree.sh: bash -n succeeds"
}

test_noop_without_config() {
  new_case noconfig
  run_provision "$HOME_DIR" NoConfigProject "$WT_DIR"
  expect_code 0 "$RUN_RC" "no config must exit 0"
  [ -z "$RUN_OUT" ] || fail "no config must be a silent no-op, got: $RUN_OUT"
  pass "no config for the project is a silent exit-0 no-op"
}

test_copies_preserving_relative_paths() {
  new_case copies
  mkdir -p "$SRC_DIR/backend"
  printf 'ROOT_ENV=1\n' > "$SRC_DIR/.env"
  printf 'LOCAL_ENV=1\n' > "$SRC_DIR/.env.local"
  printf 'BACKEND_ENV=1\n' > "$SRC_DIR/backend/.env"
  # A credential/key file (any repo-relative path, not just .env) must copy too.
  printf '{"private_key":"x"}\n' > "$SRC_DIR/backend/service-account.json"
  write_config "$HOME_DIR" App "$(printf 'env_source_dir = "%s"\nenv_files = [".env", ".env.local", "backend/.env", "backend/service-account.json"]\n' "$SRC_DIR")"
  run_provision "$HOME_DIR" App "$WT_DIR"
  expect_code 0 "$RUN_RC" "clean copy must exit 0"
  assert_present "$WT_DIR/.env" "root .env not copied"
  assert_present "$WT_DIR/.env.local" ".env.local not copied"
  assert_present "$WT_DIR/backend/.env" "nested backend/.env not copied (relative path not preserved)"
  assert_present "$WT_DIR/backend/service-account.json" "credential json not copied (relative path not preserved)"
  assert_grep "ROOT_ENV=1" "$WT_DIR/.env" "copied .env content mismatch"
  assert_grep "BACKEND_ENV=1" "$WT_DIR/backend/.env" "copied backend/.env content mismatch"
  pass "copies listed files into the worktree preserving relative paths"
}

test_skips_missing_source_files_with_warning() {
  new_case skipmissing
  printf 'PRESENT=1\n' > "$SRC_DIR/.env"
  write_config "$HOME_DIR" App "$(printf 'env_source_dir = "%s"\nenv_files = [".env", "gone.env"]\n' "$SRC_DIR")"
  run_provision "$HOME_DIR" App "$WT_DIR"
  # A missing source file is skipped, NOT a failure.
  expect_code 0 "$RUN_RC" "a missing source file must not fail provisioning"
  assert_present "$WT_DIR/.env" "present file must still be copied"
  assert_absent "$WT_DIR/gone.env" "missing source file must not be created"
  assert_contains "$RUN_OUT" "missing" "a missing source file must be warned about"
  pass "skips a missing source file with a warning, not a failure"
}

test_runs_setup_cmd() {
  new_case setup
  printf 'K=v\n' > "$SRC_DIR/.env"
  # setup_cmd runs in the worktree root: prove cwd by writing a marker there.
  write_config "$HOME_DIR" App "$(printf 'env_source_dir = "%s"\nenv_files = [".env"]\nsetup_cmd = "echo ran > setup-marker.txt"\n' "$SRC_DIR")"
  run_provision "$HOME_DIR" App "$WT_DIR"
  expect_code 0 "$RUN_RC" "setup_cmd success must exit 0"
  assert_present "$WT_DIR/setup-marker.txt" "setup_cmd was not run in the worktree root"
  pass "runs setup_cmd in the worktree root"
}

test_fails_on_missing_source_dir() {
  new_case missingdir
  write_config "$HOME_DIR" App "$(printf 'env_source_dir = "%s/does-not-exist"\nenv_files = [".env"]\n' "$HOME_DIR")"
  run_provision "$HOME_DIR" App "$WT_DIR"
  expect_code 1 "$RUN_RC" "a missing env_source_dir must exit non-zero"
  assert_contains "$RUN_OUT" "env_source_dir" "missing source dir must be reported"
  pass "fails cleanly (exit 1) when env_source_dir does not exist"
}

test_fails_on_setup_cmd_failure() {
  new_case setupfail
  printf 'K=v\n' > "$SRC_DIR/.env"
  write_config "$HOME_DIR" App "$(printf 'env_source_dir = "%s"\nenv_files = [".env"]\nsetup_cmd = "exit 3"\n' "$SRC_DIR")"
  run_provision "$HOME_DIR" App "$WT_DIR"
  expect_code 1 "$RUN_RC" "a failing setup_cmd must exit non-zero"
  # The env file must still have been copied before setup ran.
  assert_present "$WT_DIR/.env" "env file should copy even if setup_cmd later fails"
  pass "fails cleanly (exit 1) when setup_cmd exits non-zero"
}

test_setup_cmd_times_out() {
  new_case setuptimeout
  printf 'K=v\n' > "$SRC_DIR/.env"
  # A setup_cmd that would hang for 30s must be killed by the tiny timeout and
  # reported as a best-effort failure, completing well under those 30s.
  write_config "$HOME_DIR" App "$(printf 'env_source_dir = "%s"\nenv_files = [".env"]\nsetup_cmd = "sleep 30"\n' "$SRC_DIR")"
  local start end elapsed
  start=$(date +%s)
  FM_PROVISION_SETUP_TIMEOUT=2 run_provision "$HOME_DIR" App "$WT_DIR"
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 1 "$RUN_RC" "a timed-out setup_cmd must exit non-zero"
  [ "$elapsed" -lt 20 ] || fail "timeout must not hang: took ${elapsed}s"
  assert_contains "$RUN_OUT" "timeout" "the timeout must be warned about"
  assert_present "$WT_DIR/.env" "env file should copy even if setup_cmd later times out"
  pass "bounds setup_cmd by a timeout and kills a hanging install"
}

test_never_emits_env_contents() {
  new_case nosecret
  local secret="S3CR3T-do-not-print-abc123"
  printf 'API_KEY=%s\n' "$secret" > "$SRC_DIR/.env"
  write_config "$HOME_DIR" App "$(printf 'env_source_dir = "%s"\nenv_files = [".env"]\n' "$SRC_DIR")"
  run_provision "$HOME_DIR" App "$WT_DIR"
  expect_code 0 "$RUN_RC" "copy must succeed"
  assert_not_contains "$RUN_OUT" "$secret" "provisioning output must never contain env file contents"
  pass "never prints copied file contents"
}

test_refuses_unsafe_paths() {
  new_case unsafe
  # A stray ".." entry must never escape the worktree.
  printf 'OUTSIDE=1\n' > "$SRC_DIR/outside.env"
  write_config "$HOME_DIR" App "$(printf 'env_source_dir = "%s"\nenv_files = ["../escape.env"]\n' "$SRC_DIR")"
  run_provision "$HOME_DIR" App "$WT_DIR"
  expect_code 1 "$RUN_RC" "an unsafe ../ entry must fail"
  assert_absent "$(dirname "$WT_DIR")/escape.env" "unsafe ../ entry must not write outside the worktree"
  assert_contains "$RUN_OUT" "unsafe" "unsafe entry must be reported"
  pass "refuses env_files entries that are absolute or contain .."
}

test_idempotent_rerun() {
  new_case idem
  printf 'K=v1\n' > "$SRC_DIR/.env"
  write_config "$HOME_DIR" App "$(printf 'env_source_dir = "%s"\nenv_files = [".env"]\nsetup_cmd = "true"\n' "$SRC_DIR")"
  run_provision "$HOME_DIR" App "$WT_DIR"
  expect_code 0 "$RUN_RC" "first run must succeed"
  # Re-run over the already-provisioned worktree: must still succeed and refresh.
  printf 'K=v2\n' > "$SRC_DIR/.env"
  run_provision "$HOME_DIR" App "$WT_DIR"
  expect_code 0 "$RUN_RC" "re-run must succeed (idempotent)"
  assert_grep "K=v2" "$WT_DIR/.env" "re-run must refresh the copied file"
  pass "is safe to re-run (idempotent copy)"
}

# --- fm-spawn integration (structural, per fm-gotmp.test.sh precedent) -------

test_spawn_integration_contract() {
  # fm-spawn must invoke the helper for ship/scout spawns, gate it on
  # FM_SPAWN_NO_PROVISION, not run it for secondmate homes, and warn-not-abort on
  # failure.
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source strings
  grep -F 'bin/fm-provision-worktree.sh' "$SPAWN" >/dev/null \
    || fail "fm-spawn does not call fm-provision-worktree.sh"
  # shellcheck disable=SC2016
  grep -F 'FM_SPAWN_NO_PROVISION' "$SPAWN" >/dev/null \
    || fail "fm-spawn does not honor FM_SPAWN_NO_PROVISION"
  # shellcheck disable=SC2016
  grep -F '$KIND" != secondmate ] && [ -z "${FM_SPAWN_NO_PROVISION' "$SPAWN" >/dev/null \
    || fail "fm-spawn provisioning must skip secondmate homes and respect the skip flag"
  grep -F 'PROVISION: warning:' "$SPAWN" >/dev/null \
    || fail "fm-spawn must emit a PROVISION: warning (not abort) on failure"
  pass "fm-spawn integrates provisioning: ship/scout only, skippable, warn-not-abort"
}

test_script_parses
test_noop_without_config
test_copies_preserving_relative_paths
test_skips_missing_source_files_with_warning
test_runs_setup_cmd
test_fails_on_missing_source_dir
test_fails_on_setup_cmd_failure
test_setup_cmd_times_out
test_never_emits_env_contents
test_refuses_unsafe_paths
test_idempotent_rerun
test_spawn_integration_contract
