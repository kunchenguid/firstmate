#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-watch.sh, the one owner of a task's
# pipeline-state watch (when-nm-state-<id>) and of registering the path where a
# lane's no-mistakes run actually executes.
#
# Each case names the gap it pins:
#   relaunch: arming a task that already has the watch converges (retire and
#     re-arm), where the spawn's former direct arm refused the second time.
#   escalation: an arm that cannot complete leaves a durable check wake, not
#     only a stderr warning nobody reads.
#   registration: a registered clone is recorded in the task record and the
#     re-armed watch polls that clone instead of the task worktree; a bad path
#     is refused without touching the record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NMW="$ROOT/bin/fm-nm-watch.sh"
WHEN="$ROOT/bin/fm-procevent-when.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-watch-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
fm_git_identity fmtest fmtest@example.invalid

new_task_home() {  # <name> <task-id> -> echoes a home holding one no-mistakes ship task
  local home="$TMP_ROOT/$1" id=$2
  mkdir -p "$home/state" "$home/wt"
  chmod 755 "$home/state"
  fm_test_track_procevent_home "$home"
  git -C "$home/wt" init -q
  git -C "$home/wt" commit -q --allow-empty -m init
  fm_write_meta "$home/state/$id.meta" "window=none" "backend=tmux" \
    "worktree=$home/wt" "kind=ship" "mode=no-mistakes"
  printf '%s\n' "$home"
}

spec_of() { cat "$1/state/when/when-nm-state-$2.spec" 2>/dev/null; }
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

test_rearm_converges_on_existing_watch() {
  local home id=relaunch-a out
  home=$(new_task_home relaunch "$id")
  FM_HOME="$home" "$NMW" arm "$id" >/dev/null || fail "the first arm failed"
  # Counterfactual: the direct arm the spawn used refuses once the watch exists,
  # which is exactly what a relaunch hit.
  if FM_HOME="$home" "$WHEN" arm "nm-state-$id" --repeat --condition true --action true >/dev/null 2>&1; then
    fail "a second direct arm succeeded, so this case no longer reproduces the relaunch refusal"
  fi
  out=$(FM_HOME="$home" "$NMW" arm "$id" 2>&1) || fail "re-arming over an existing watch failed: $out"
  assert_contains "$(spec_of "$home" "$id")" "$home/wt" "the re-armed watch polls the task worktree"
  [ -z "$(wake_payloads "$home")" ] || fail "a successful re-arm raised a wake: $(wake_payloads "$home")"
  pass "arming a task that already has its pipeline-state watch converges instead of refusing"
}

test_arm_failure_raises_check_wake() {
  local home id=armfail-a rc payloads
  home=$(new_task_home armfail "$id")
  # A task record with no recorded worktree (and no registered clone) makes
  # cmd_arm's own "no worktree recorded" guard refuse before it ever calls
  # the underlying when-primitive.
  sed -i '/^worktree=/d' "$home/state/$id.meta"
  FM_HOME="$home" "$NMW" arm "$id" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "an arm that could not register reported success"
  payloads=$(wake_payloads "$home")
  assert_contains "$payloads" "pipeline-state watch" "the arm failure reached the durable wake queue"
  assert_contains "$payloads" "$id" "the wake names the task"
  pass "a pipeline-state watch that cannot be armed leaves a durable check wake"
}

test_register_clone_records_and_rearms() {
  local home id=clone-a clone out
  home=$(new_task_home register "$id")
  clone="$TMP_ROOT/register-clone"
  git clone -q "$home/wt" "$clone"
  FM_HOME="$home" "$NMW" arm "$id" >/dev/null || fail "the initial arm failed"
  out=$(FM_HOME="$home" "$NMW" register-clone "$id" "$clone" 2>&1) || fail "register-clone failed: $out"
  assert_grep "nm_clone=$clone" "$home/state/$id.meta" "the clone path is recorded in the task record"
  assert_contains "$(spec_of "$home" "$id")" "$clone" "the watch now polls the registered clone"
  assert_not_contains "$(spec_of "$home" "$id")" "$home/wt" "the watch no longer polls the task worktree"
  FM_HOME="$home" "$NMW" register-clone "$id" "$clone" >/dev/null 2>&1 || fail "re-registering the same clone failed"
  [ "$(grep -c '^nm_clone=' "$home/state/$id.meta")" = 1 ] || fail "re-registering duplicated the record"

  mkdir -p "$TMP_ROOT/not-a-repo"
  for bad in "relative/path" "$TMP_ROOT/not-a-repo" "$TMP_ROOT/missing-dir"; do
    if FM_HOME="$home" "$NMW" register-clone "$id" "$bad" >/dev/null 2>&1; then
      fail "register-clone accepted an unusable path: $bad"
    fi
  done
  assert_grep "nm_clone=$clone" "$home/state/$id.meta" "a refused registration left the record untouched"
  pass "register-clone records the clone and re-arms the watch on it, refusing unusable paths"
}

test_rearm_converges_on_existing_watch
test_arm_failure_raises_check_wake
test_register_clone_records_and_rearms

echo "all fm-nm-watch tests passed"
