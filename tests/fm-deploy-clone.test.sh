#!/usr/bin/env bash
# Tests for bin/fm-deploy-clone.sh and its wiring into the merge-landed path via
# bin/fm-merge-outcome-lib.sh: after a merge lands for a registered deployed-CLI
# project, its machine-local clone is fast-forwarded to its default branch and
# rebuilt, while an unregistered project is untouched and a dirty clone,
# non-fast-forward, or build failure is reported as a failure and never as a
# deployment.
#
# The test_* functions below name the covered redeploy, no-op, guard, and
# merge-wiring behavior directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

DEPLOY="$ROOT/bin/fm-deploy-clone.sh"
MERGE_OUTCOME_LIB="$ROOT/bin/fm-merge-outcome-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-deploy-clone-tests)

command -v jq >/dev/null 2>&1 || fail "these tests read the registry with the real jq, which was not found"

# Build a fresh sandbox home with empty state/ and config/. Echoes its path.
make_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# Create a deployed clone whose default branch is one commit behind its origin,
# so a fast-forward has real work to do. Echoes the clone path.
make_behind_clone() {
  local dir=$1 upstream work clone
  upstream="$dir/upstream.git"
  work="$dir/work"
  clone="$dir/clone"
  git init --quiet --bare -b main "$upstream"
  git init --quiet -b main "$work"
  printf 'v1\n' > "$work/VERSION"
  git -C "$work" add VERSION
  git -C "$work" commit --quiet -m v1
  git -C "$work" remote add origin "$upstream"
  git -C "$work" push --quiet -u origin main
  git clone --quiet "$upstream" "$clone"
  # Advance origin so the clone is one commit behind.
  printf 'v2\n' > "$work/VERSION"
  git -C "$work" commit --quiet -am v2
  git -C "$work" push --quiet origin main
  printf '%s\n' "$clone"
}

# Write config/deploy-clones.json for one project name -> clone path + build.
write_registry() {
  local home=$1 name=$2 path=$3 build=$4
  jq -n --arg n "$name" --arg p "$path" --arg b "$build" \
    '{clones: [{name: $n, path: $p, build: $b}]}' > "$home/config/deploy-clones.json"
}

# Write state/<id>.meta with a project= worktree root whose basename is <name>.
write_meta() {
  local home=$1 id=$2 name=$3
  printf 'project=%s\n' "$home/projects/$name" > "$home/state/$id.meta"
}

run_deploy() {
  local home=$1; shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$DEPLOY" "$@"
}

# --- run: the guarded redeploy ---------------------------------------------

test_run_redeploys_registered_clone() {
  local home clone marker out rc
  home=$(make_home run-ok)
  clone=$(make_behind_clone "$home")
  marker="$home/built"
  write_registry "$home" missive-axi "$clone" "touch '$marker'"

  out=$(run_deploy "$home" run missive-axi 2>"$home/err"); rc=$?

  expect_code 0 "$rc" "run-ok: a registered clone must redeploy successfully"
  assert_contains "$out" "deployed: missive-axi" "run-ok: success is reported"
  assert_present "$marker" "run-ok: the build command must run"
  assert_equals v2 "$(cat "$clone/VERSION")" \
    "run-ok: the clone must be fast-forwarded to origin"
  pass "fm-deploy-clone run redeploys a registered clone"
}

test_run_is_idempotent_when_already_current() {
  local home clone marker rc
  home=$(make_home run-idem)
  clone=$(make_behind_clone "$home")
  marker="$home/built"
  write_registry "$home" missive-axi "$clone" "touch '$marker'"

  run_deploy "$home" run missive-axi >/dev/null 2>&1
  rm -f "$marker"
  run_deploy "$home" run missive-axi >"$home/out2" 2>&1; rc=$?

  expect_code 0 "$rc" "run-idem: an already-current clone redeploys cleanly"
  assert_grep "deployed: missive-axi" "$home/out2" \
    "run-idem: a no-op fast-forward still rebuilds and reports success"
  assert_present "$marker" "run-idem: the build runs again on a current clone"
  pass "fm-deploy-clone run is idempotent on an already-current clone"
}

# --- on-merge: resolve the project from task metadata ----------------------

test_on_merge_redeploys_registered_project() {
  local home clone marker rc
  home=$(make_home onmerge-ok)
  clone=$(make_behind_clone "$home")
  marker="$home/built"
  write_registry "$home" review-axi "$clone" "touch '$marker'"
  write_meta "$home" task-1 review-axi

  FM_DEPLOY_CLONE_FOREGROUND=1 run_deploy "$home" on-merge task-1 >/dev/null 2>&1; rc=$?

  expect_code 0 "$rc" "onmerge-ok: on-merge for a registered project succeeds"
  assert_present "$marker" "onmerge-ok: the registered clone is rebuilt"
  assert_equals v2 "$(cat "$clone/VERSION")" \
    "onmerge-ok: the registered clone is fast-forwarded"
  pass "fm-deploy-clone on-merge redeploys a registered project"
}

test_on_merge_leaves_unregistered_project_untouched() {
  local home clone marker rc
  home=$(make_home onmerge-unreg)
  clone=$(make_behind_clone "$home")
  marker="$home/built"
  write_registry "$home" review-axi "$clone" "touch '$marker'"
  # The merged project is a different, unregistered one.
  write_meta "$home" task-1 some-other-project

  FM_DEPLOY_CLONE_FOREGROUND=1 run_deploy "$home" on-merge task-1 >/dev/null 2>&1; rc=$?

  expect_code 0 "$rc" "onmerge-unreg: an unregistered project is a clean no-op"
  assert_absent "$marker" "onmerge-unreg: an unregistered project is never built"
  assert_equals v1 "$(cat "$clone/VERSION")" \
    "onmerge-unreg: an unregistered project's clone is never touched"
  assert_absent "$home/state/.wake-queue" \
    "onmerge-unreg: an unregistered project raises no failure wake"
  pass "fm-deploy-clone on-merge leaves an unregistered project untouched"
}

test_absent_registry_is_a_noop() {
  local home rc
  home=$(make_home no-registry)
  write_meta "$home" task-1 review-axi

  FM_DEPLOY_CLONE_FOREGROUND=1 run_deploy "$home" on-merge task-1 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "no-registry: on-merge without a registry is a clean no-op"
  run_deploy "$home" run review-axi >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "no-registry: run without a registry is a clean no-op"
  assert_absent "$home/state/.wake-queue" \
    "no-registry: no registry raises no wake"
  pass "fm-deploy-clone treats an absent registry as a no-op"
}

# --- guards: reported as a failure, never as a deployment ------------------

test_dirty_clone_is_reported_not_deployed() {
  local home clone marker rc
  home=$(make_home dirty)
  clone=$(make_behind_clone "$home")
  marker="$home/built"
  write_registry "$home" missive-axi "$clone" "touch '$marker'"
  printf 'local edit\n' >> "$clone/VERSION"

  run_deploy "$home" run --wake missive-axi >"$home/out" 2>"$home/err"; rc=$?

  expect_code 1 "$rc" "dirty: a clone with uncommitted changes must fail"
  assert_grep "uncommitted changes" "$home/err" \
    "dirty: the concrete uncommitted-changes reason is reported"
  assert_no_grep "deployed:" "$home/out" \
    "dirty: a dirty clone is never reported as deployed"
  assert_absent "$marker" "dirty: a dirty clone is never rebuilt"
  assert_grep "CLI redeploy failed for missive-axi" "$home/state/.wake-queue" \
    "dirty: the failure is surfaced through the durable wake queue"
  assert_grep "local edit" "$clone/VERSION" \
    "dirty: the uncommitted local change is never discarded"
  pass "fm-deploy-clone reports a dirty clone as a failure, not a deployment"
}

test_non_fast_forward_is_reported_not_deployed() {
  local home clone marker rc
  home=$(make_home non-ff)
  clone=$(make_behind_clone "$home")
  marker="$home/built"
  write_registry "$home" missive-axi "$clone" "touch '$marker'"
  # Give the clone a committed divergent history so its default branch cannot
  # fast-forward to origin.
  printf 'divergent\n' > "$clone/VERSION"
  git -C "$clone" commit --quiet -am divergent

  run_deploy "$home" run --wake missive-axi >"$home/out" 2>"$home/err"; rc=$?

  expect_code 1 "$rc" "non-ff: a non-fast-forwardable clone must fail"
  assert_grep "not fast-forwardable" "$home/err" \
    "non-ff: the concrete non-fast-forward reason is reported"
  assert_no_grep "deployed:" "$home/out" \
    "non-ff: a non-fast-forward is never reported as deployed"
  assert_absent "$marker" "non-ff: a non-fast-forward clone is never rebuilt"
  assert_grep "CLI redeploy failed for missive-axi" "$home/state/.wake-queue" \
    "non-ff: the failure is surfaced through the durable wake queue"
  pass "fm-deploy-clone reports a non-fast-forward as a failure, not a deployment"
}

test_build_failure_is_reported_not_deployed() {
  local home clone rc
  home=$(make_home build-fail)
  clone=$(make_behind_clone "$home")
  write_registry "$home" missive-axi "$clone" "exit 1"

  run_deploy "$home" run --wake missive-axi >"$home/out" 2>"$home/err"; rc=$?

  expect_code 1 "$rc" "build-fail: a failing build must fail the redeploy"
  assert_grep "build failed" "$home/err" \
    "build-fail: the concrete build-failure reason is reported"
  assert_no_grep "deployed:" "$home/out" \
    "build-fail: a failed build is never reported as deployed"
  assert_grep "CLI redeploy failed for missive-axi" "$home/state/.wake-queue" \
    "build-fail: the failure is surfaced through the durable wake queue"
  pass "fm-deploy-clone reports a build failure as a failure, not a deployment"
}

test_missing_clone_is_reported_not_deployed() {
  local home rc
  home=$(make_home missing-clone)
  write_registry "$home" missive-axi "$home/does-not-exist" "true"

  run_deploy "$home" run --wake missive-axi >"$home/out" 2>"$home/err"; rc=$?

  expect_code 1 "$rc" "missing-clone: an absent clone path must fail"
  assert_grep "deployed clone not found" "$home/err" \
    "missing-clone: the concrete missing-clone reason is reported"
  assert_no_grep "deployed:" "$home/out" \
    "missing-clone: an absent clone is never reported as deployed"
  pass "fm-deploy-clone reports a missing clone as a failure, not a deployment"
}

# --- wiring: the merge-landed path triggers the redeploy -------------------

test_merge_outcome_triggers_the_redeploy() {
  local home clone marker url
  home=$(make_home merge-wired)
  clone=$(make_behind_clone "$home")
  marker="$home/built"
  write_registry "$home" ahrefs-axi "$clone" "touch '$marker'"
  write_meta "$home" task-1 ahrefs-axi
  url="https://github.com/example/repo/pull/9"

  # Drive the single funnel both merge callers use, in a main home, with the
  # redeploy forced to run in the foreground so the test can observe it.
  (
    # shellcheck source=/dev/null
    . "$MERGE_OUTCOME_LIB"
    export FM_DEPLOY_CLONE_FOREGROUND=1
    fm_merge_outcome_report "$home" "$home/state" task-1 "$url" self attended
  ) >/dev/null 2>&1 || fail "merge-wired: fm_merge_outcome_report must succeed in a main home"

  assert_grep "check: merge landed" "$home/state/.wake-queue" \
    "merge-wired: the merge outcome must still be published"
  assert_present "$marker" \
    "merge-wired: a landed merge for a registered project must trigger its redeploy"
  assert_equals v2 "$(cat "$clone/VERSION")" \
    "merge-wired: the merge-triggered redeploy fast-forwards the clone"
  pass "a landed merge triggers the registered clone's redeploy"
}

test_merge_outcome_without_registry_does_not_redeploy() {
  local home url rc
  home=$(make_home merge-no-registry)
  write_meta "$home" task-1 ahrefs-axi
  url="https://github.com/example/repo/pull/9"

  (
    # shellcheck source=/dev/null
    . "$MERGE_OUTCOME_LIB"
    fm_merge_outcome_report "$home" "$home/state" task-1 "$url" self attended
  ) >/dev/null 2>&1; rc=$?

  expect_code 0 "$rc" "merge-no-registry: the merge outcome still records cleanly"
  assert_grep "check: merge landed" "$home/state/.wake-queue" \
    "merge-no-registry: the merge outcome is published with no registry present"
  pass "a landed merge with no registry records cleanly and redeploys nothing"
}

test_run_redeploys_registered_clone
test_run_is_idempotent_when_already_current
test_on_merge_redeploys_registered_project
test_on_merge_leaves_unregistered_project_untouched
test_absent_registry_is_a_noop
test_dirty_clone_is_reported_not_deployed
test_non_fast_forward_is_reported_not_deployed
test_build_failure_is_reported_not_deployed
test_missing_clone_is_reported_not_deployed
test_merge_outcome_triggers_the_redeploy
test_merge_outcome_without_registry_does_not_redeploy
