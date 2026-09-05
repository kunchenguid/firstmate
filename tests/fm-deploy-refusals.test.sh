#!/usr/bin/env bash
# Tests for the refusals in bin/fm-deploy.sh and the inertness of
# bin/fm-deploy-trigger.sh.
#
# Every case drives the real entry points through a fake host transport: `ssh`,
# `gh`, and `curl` are PATH fakes that record what they were asked to do. No
# case reaches a real machine. The fakes also make the important assertion
# possible: a refusal must be provable by the ABSENCE of a stop or checkout in
# the transport log, not just by an exit status.
#
# Matrix:
#   (a) a range touching a captain-reserved surface refuses, and refuses BEFORE
#       stopping anything on the machine
#   (b) the permission flag without the captain's own words refuses
#   (c) the permission flag with his words lets the same range through
#   (d) a run in progress refuses, before stopping anything
#   (e) an unobtainable sealed bundle refuses, before stopping anything, and
#       never falls back to a bundle built for another commit
#   (f) a deploy target that is missing a key, that names an unknown key, or
#       that carries shell metacharacters is refused rather than partly used
#   (g) every refusal is recorded in the durable ledger
#   (h) the merge trigger is completely inert for a project with no policy
#   (i) the merge trigger never deploys a captain-reserved range
#   (j) a clone with no origin/HEAD still resolves its target through the
#       documented origin/main fallback
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deploy-refusals-tests)

git_c() { git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

commit_file() {
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "$2" > "$REPO/$1"
  git_c add -A
  git_c commit -qm "$3"
}

# make_case <name>: builds a home with a project clone, a deploy policy, a
# deploy target, and a fake host transport. Sets CASE_DIR, HOME_DIR, REPO,
# SSH_LOG and FAKEBIN as globals rather than echoing them, because a command
# substitution would run this in a subshell and silently leave every later
# assertion pointed at the PREVIOUS case's fixture.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  REPO="$HOME_DIR/projects/demo"
  SSH_LOG="$case_dir/ssh.log"
  mkdir -p "$HOME_DIR/config/deploy-policy" "$HOME_DIR/config/deploy-target" \
    "$HOME_DIR/state" "$REPO"

  git_c init -q -b main
  commit_file README.md base "base"
  DEPLOYED=$(git_c rev-parse HEAD)
  commit_file src/engine.py engine "a plain code change"
  PLAIN=$(git_c rev-parse HEAD)
  commit_file dashboard/v2/src/app.tsx app "a design change"
  DESIGN=$(git_c rev-parse HEAD)
  git_c remote add origin git@github.com:example/demo.git
  git_c update-ref refs/remotes/origin/main "$DESIGN"
  # A real clone has origin/HEAD, and that is the ref the reporter prefers, so
  # the fixture carries it: otherwise every case here would exercise only the
  # fallback the live path never takes.
  git_c symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  cat > "$HOME_DIR/config/deploy-policy/demo" <<'POL'
dashboard/v2/src/**
POL
  cat > "$HOME_DIR/config/deploy-target/demo" <<'TGT'
host=host.invalid
user=deployer
checkout=/opt/demo
unit=demo-app
rollback_root=/var/lib/demo-deploy/rollback
health_url=http://127.0.0.1:8765/api/health
public_url=https://demo.invalid/
public_expect=403
bundle_path=dashboard/v2/dist
bundle_artifact=demo-dist
bundle_workflow=demo-ci.yml
run_lock=/var/lib/demo/runs/.lock
TGT

  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/ssh" <<SH
#!/usr/bin/env bash
set -u
cmd=\${!#}
printf '%s\n' "\$cmd" >> '$SSH_LOG'
case "\$cmd" in
  *'rev-parse HEAD'*) printf '%s\n' "\${FMTEST_HOST_SHA:-$DEPLOYED}" ;;
  *'/proc/locks'*)    printf '%s\n' "\${FMTEST_RUN_STATE:-idle}" ;;
  *'http_code'*)      printf '%s\n' "\${FMTEST_HEALTH:-200}" ;;
esac
exit \${FMTEST_SSH_RC:-0}
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit "${FMTEST_GH_RC:-1}"
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FMTEST_PUBLIC:-403}"
exit 0
SH
  chmod +x "$fakebin/ssh" "$fakebin/gh" "$fakebin/curl"
  FAKEBIN=$fakebin
  CASE_DIR=$case_dir
}

run_deploy() {
  ( PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-deploy.sh" "$@" 2>&1 )
}

assert_machine_untouched() {  # <case label>
  if grep -q -E 'systemctl stop|checkout --detach' "$SSH_LOG" 2>/dev/null; then
    fail "$1: the refusal came after the machine had already been changed: $(tr '\n' '|' < "$SSH_LOG")"
  fi
}

test_a_reserved_range_refuses_before_touching_the_machine() {
  local out rc=0
  make_case reserved-range
  out=$(run_deploy demo "$DESIGN") || rc=$?
  [ "$rc" -ne 0 ] || fail "reserved-range: a design change deployed without the captain"
  assert_contains "$out" "need your permission" "reserved-range"
  assert_contains "$out" "dashboard/v2/src/app.tsx" "reserved-range"
  assert_machine_untouched reserved-range
  assert_grep '"result":"refused"' "$HOME_DIR/state/deploy-ledger/demo.jsonl" \
    "reserved-range: the refusal was not recorded in the ledger"
  pass "a range touching a reserved design surface refuses before anything on the machine changes"
}

test_the_permission_flag_alone_is_not_permission() {
  local out rc=0
  make_case empty-permission
  out=$(run_deploy demo "$DESIGN" --with-captain-permission "ok") || rc=$?
  [ "$rc" -ne 0 ] || fail "empty-permission: a token reason was accepted as the captain's permission"
  assert_contains "$out" "own words" "empty-permission"
  assert_machine_untouched empty-permission
  pass "the permission flag without the captain's own words is not permission"
}

test_the_captains_words_let_the_same_range_through() {
  local out rc=0
  make_case granted-permission
  FMTEST_GH_RC=0 out=$(run_deploy demo "$DESIGN" \
    --with-captain-permission "yes, ship the new cockpit design") || rc=$?
  # It proceeds past the captain's gate: whatever it does next, it is no longer
  # refusing on permission grounds.
  case "$out" in
    *"need your permission"* | *"own words"*)
      fail "granted-permission: the captain's own words were still refused: $out"
      ;;
  esac
  pass "the captain's own words let the same range through the permission gate"
}

test_a_run_in_progress_refuses_before_touching_the_machine() {
  local out rc=0
  make_case run-in-progress
  out=$(FMTEST_RUN_STATE=busy run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "run-in-progress: deployed while a run was under way"
  assert_contains "$out" "middle of a run" "run-in-progress"
  assert_machine_untouched run-in-progress
  pass "a run in progress refuses before anything on the machine changes"
}

test_an_unreadable_run_state_refuses() {
  local out rc=0
  make_case unreadable-run-state
  out=$(FMTEST_RUN_STATE=nonsense run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable-run-state: deployed without knowing whether a run was under way"
  assert_contains "$out" "could not tell" "unreadable-run-state"
  assert_machine_untouched unreadable-run-state
  pass "an unreadable run state refuses rather than assuming the app is idle"
}

test_an_unobtainable_bundle_refuses_before_touching_the_machine() {
  local out rc=0
  make_case missing-bundle
  # The fake `gh` fails, standing in for a build artifact past its retention.
  out=$(run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing-bundle: deployed a version whose front end was never obtained"
  assert_contains "$out" "$PLAIN" "missing-bundle"
  assert_machine_untouched missing-bundle
  pass "an unobtainable sealed bundle refuses before anything on the machine changes"
}

test_a_broken_deploy_target_is_refused_rather_than_partly_used() {
  local out rc broken
  for broken in missing-key unknown-key metacharacters; do
    make_case "target-$broken"
    case "$broken" in
      missing-key)     grep -v '^unit=' "$HOME_DIR/config/deploy-target/demo" > "$CASE_DIR/t" ;;
      unknown-key)     { cat "$HOME_DIR/config/deploy-target/demo"; echo 'exec=rm -rf /'; } > "$CASE_DIR/t" ;;
      metacharacters)  sed 's#^checkout=.*#checkout=/opt/demo; curl evil.invalid#' \
                         "$HOME_DIR/config/deploy-target/demo" > "$CASE_DIR/t" ;;
    esac
    mv "$CASE_DIR/t" "$HOME_DIR/config/deploy-target/demo"
    rc=0
    out=$(run_deploy demo "$PLAIN") || rc=$?
    [ "$rc" -eq 2 ] || fail "target-$broken: expected a configuration refusal, got rc=$rc: $out"
    assert_machine_untouched "target-$broken"
  done
  pass "a deploy target that is incomplete, unknown, or carries shell metacharacters is refused"
}

test_the_merge_trigger_is_inert_without_a_policy() {
  make_case trigger-inert
  rm -f "$HOME_DIR/config/deploy-policy/demo"
  fm_write_meta "$HOME_DIR/state/task-a.meta" "project=$REPO" "worktree=$REPO"

  ( PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-deploy-trigger.sh" \
      "$HOME_DIR" "$HOME_DIR/state" task-a ) \
    || fail "trigger-inert: the trigger reported a failure for an unmanaged project"
  assert_absent "$HOME_DIR/state/deploy-ledger/demo.jsonl" \
    "trigger-inert: an unmanaged project reached the deploy path"
  assert_absent "$HOME_DIR/state/.wake-queue" \
    "trigger-inert: an unmanaged project produced a captain-facing line"
  [ ! -s "$SSH_LOG" ] \
    || fail "trigger-inert: an unmanaged project reached the machine: $(tr '\n' '|' < "$SSH_LOG")"
  pass "the merge trigger is completely inert for a project with no deploy policy"
}

test_a_clone_without_origin_head_still_resolves_its_target() {
  local queued
  make_case trigger-no-origin-head
  # Some clones have no origin/HEAD at all. The reporter falls back to
  # origin/main there, and must reach the same verdict rather than reporting
  # that it cannot tell.
  git_c symbolic-ref -d refs/remotes/origin/HEAD
  fm_write_meta "$HOME_DIR/state/task-c.meta" "project=$REPO" "worktree=$REPO"

  ( PATH="$FAKEBIN:$PATH" FM_DEPLOY_SYNC_TIMEOUT=5 \
      "$ROOT/bin/fm-deploy-trigger.sh" "$HOME_DIR" "$HOME_DIR/state" task-c ) \
    || fail "trigger-no-origin-head: the trigger reported a failure"
  assert_machine_untouched trigger-no-origin-head
  queued=$(cat "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queued" "design surfaces you asked to approve" "trigger-no-origin-head"
  pass "a clone with no origin/HEAD still resolves what is not live yet, through origin/main"
}

test_the_merge_trigger_never_deploys_a_reserved_range() {
  local queued
  make_case trigger-reserved
  fm_write_meta "$HOME_DIR/state/task-b.meta" "project=$REPO" "worktree=$REPO"

  ( PATH="$FAKEBIN:$PATH" FM_DEPLOY_SYNC_TIMEOUT=5 \
      "$ROOT/bin/fm-deploy-trigger.sh" "$HOME_DIR" "$HOME_DIR/state" task-b ) \
    || fail "trigger-reserved: the trigger reported a failure"
  assert_machine_untouched trigger-reserved
  queued=$(cat "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queued" "design surfaces you asked to approve" "trigger-reserved"
  pass "the merge trigger reports a reserved range to the captain instead of deploying it"
}

test_a_reserved_range_refuses_before_touching_the_machine
test_the_permission_flag_alone_is_not_permission
test_the_captains_words_let_the_same_range_through
test_a_run_in_progress_refuses_before_touching_the_machine
test_an_unreadable_run_state_refuses
test_an_unobtainable_bundle_refuses_before_touching_the_machine
test_a_broken_deploy_target_is_refused_rather_than_partly_used
test_the_merge_trigger_is_inert_without_a_policy
test_the_merge_trigger_never_deploys_a_reserved_range
test_a_clone_without_origin_head_still_resolves_its_target
