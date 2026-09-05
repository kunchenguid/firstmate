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
#   (e2) a start-time requirement the new version's own units make of a file the
#       MACHINE owns is checked, and refuses by name, before stopping anything
#   (e3) a command run as the service user starts somewhere that user can read,
#       so a refusal names the requirement it checked and never that command's
#       own working directory
#   (e4) a front end the user the app runs as cannot read refuses before
#       stopping anything, so the app is still serving the old version
#   (f) a deploy target that is missing a key, that names an unknown key, or
#       that carries shell metacharacters is refused rather than partly used
#   (g) every refusal is recorded in the durable ledger
#   (h) the merge trigger is completely inert for a project with no policy
#   (i) the merge trigger never deploys a captain-reserved range
#   (j) each of the four reasons a sealed bundle cannot be obtained is refused
#       as itself: no build yet, still running, finished without succeeding,
#       and a green build whose artifact has expired
#   (k) a deploy freeze pauses the merge trigger without touching the policy,
#       and leaves a hand-run deploy working
#   (j) a clone with no origin/HEAD still resolves its target through the
#       documented origin/main fallback
#   (l) only the two build races refuse with the transient exit status; every
#       other refusal keeps the ordinary one
#   (m) a merge that outran its own build is recorded rather than reported, and
#       the recorded deploy goes live exactly once when the build lands
#   (n) a merge that never builds is reported once and its record cleared
#   (o) a newer merge supersedes the pending one for the same project
#   (p) the pending deploy outlives the task whose merge created it
#   (q) a pending deploy that waits past its horizon stops waiting and says so
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
  # The sign-in unit's start is gated on a file the MACHINE owns rather than one
  # the release brings. Without a unit set carrying one, every assertion about
  # checking those requirements first would pass over an empty set.
  mkdir -p "$REPO/deploy/systemd"
  cat > "$REPO/deploy/systemd/demo-app.service" <<'UNIT'
[Unit]
Description=demo app
[Service]
User=demo
ExecStart=/opt/demo/.venv/bin/demo
UNIT
  cat > "$REPO/deploy/systemd/demo-proxy.service" <<'UNIT'
[Unit]
Description=demo sign-in proxy
[Service]
User=demo-proxy
ExecStartPre=/opt/demo/.venv/bin/python -B /opt/demo/deploy/validate_allowed_emails.py /etc/demo/allowed-emails
ExecStart=/opt/demo/.venv/bin/demo-proxy
UNIT
  printf 'x\n' > "$REPO/deploy/validate_allowed_emails.py"
  git_c add -A
  git_c commit -qm "the machine's own units"
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
# The login user's home is private, and a command run under \`sudo -u\` inherits
# the working directory of the shell that started it: \`find\` walks away from
# that directory and cannot get back. Any service-user command that does not
# start somewhere that user can read fails here as it did on the real machine,
# so a refusal built on one of them is refusing about the wrong thing.
case "\$cmd" in
  *'sudo -u '*)
    case "\$cmd" in
      'cd / && '*) ;;
      *)
        printf 'find: Failed to restore initial working directory: /home/ubuntu: Permission denied\n' >&2
        exit 1
        ;;
    esac
    ;;
esac
case "\$cmd" in
  *'rev-parse HEAD'*) printf '%s\n' "\${FMTEST_HOST_SHA:-$DEPLOYED}" ;;
  *'/proc/locks'*)    printf '%s\n' "\${FMTEST_RUN_STATE:-idle}" ;;
  *'http_code'*)      printf '%s\n' "\${FMTEST_HEALTH:-200}" ;;
  # Only the bundle install is fed on stdin; draining it for every command
  # would block on a pipe nothing ever closes.
  *'-xzf -'*)         cat >/dev/null 2>&1 || true ;;
  # A start-time requirement this machine does not meet yet.
  *'sudo -u '*'validate_allowed_emails.py'*)
    [ -z "\${FMTEST_PRECHECK_FAILS:-}" ] || { printf 'operator allow-list refused\n' >&2; exit 1; } ;;
  # The service user's own view of the front end: FMTEST_BUNDLE_UNREADABLE names
  # the paths it cannot read, which is what find puts on stdout.
  *'-readable'*)
    [ -z "\${FMTEST_BUNDLE_UNREADABLE:-}" ] || { printf '/opt/demo/dashboard/v2/dist\n'; exit 1; } ;;
esac
exit \${FMTEST_SSH_RC:-0}
SH
  # By default no build is obtainable, which is what the missing-bundle case
  # needs. FMTEST_GH_RC=0 is how a case says the build for the commit it is
  # deploying is still downloadable, so the run reaches the steps past it.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FMTEST_GH_RC:-1}" = 0 ] || exit "${FMTEST_GH_RC:-1}"
case "${1:-} ${2:-}" in
  'run list')
    printf '[{"databaseId":4242,"headSha":"%s"}]\n' "${FMTEST_TARGET_SHA:-}"
    ;;
  'run view')
    printf '%s\n' "${FMTEST_BUILD_STATE:-completed success}"
    ;;
  'run download')
    [ -z "${FMTEST_DOWNLOAD_FAILS:-}" ] || exit 1
    out=''
    while [ "$#" -gt 0 ]; do
      [ "$1" = -D ] && { shift; out=$1; }
      shift
    done
    mkdir -p "$out"
    printf 'built\n' > "$out/index.html"
    printf '{}\n' > "$out/bundle-seal.json"
    ;;
esac
exit 0
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
  ( PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
      FMTEST_TARGET_SHA="${FMTEST_TARGET_SHA:-$PLAIN}" \
      "$ROOT/bin/fm-deploy.sh" "$@" 2>&1 )
}

# The trigger's two entry points, run against the fixture's fake transport.
# FMTEST_TARGET_SHA has to name the commit the fake `gh` should answer about,
# exactly as run_deploy does, or the run lookup answers about nothing.
run_trigger() {  # <task-id> | --resume-pending
  ( PATH="$FAKEBIN:$PATH" FM_DEPLOY_SYNC_TIMEOUT=5 \
      FMTEST_TARGET_SHA="${FMTEST_TARGET_SHA:-$PLAIN}" \
      "$ROOT/bin/fm-deploy-trigger.sh" "$HOME_DIR" "$HOME_DIR/state" "$@" 2>/dev/null )
}

pending_record() { printf '%s\n' "$HOME_DIR/state/deploy-pending/demo"; }

queued_wakes() { cat "$HOME_DIR/state/.wake-queue" 2>/dev/null || true; }

# How many times the machine was actually changed. `checkout --detach` is the
# first command that changes what the machine serves, so counting it is how a
# case proves a deploy happened once rather than twice.
deploy_count() { grep -c -- 'checkout --detach' "$SSH_LOG" 2>/dev/null || true; }

# make_deployable_case <name>: the standard fixture with origin/main moved off
# the reserved design commit, so the range from what is live to the target is
# auto-deployable and the trigger reaches the deploy instead of reporting a
# surface the captain reserved.
make_deployable_case() {
  make_case "$1"
  git_c update-ref refs/remotes/origin/main "$PLAIN"
  git_c symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  fm_write_meta "$HOME_DIR/state/task-p.meta" "project=$REPO" "worktree=$REPO"
}

# Drive the trigger to the one refusal that waits: the commit merged, and its
# own build has not finished.
record_an_early_merge() {  # <case label>
  FMTEST_GH_RC=0 FMTEST_BUILD_STATE='in_progress ' run_trigger task-p \
    || fail "$1: the trigger reported a failure for a merge that outran its build"
  assert_present "$(pending_record)" \
    "$1: a deploy refused only because the build was still running left no record to finish it"
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
  out=$(FMTEST_GH_RC=0 run_deploy demo "$DESIGN" \
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
  assert_contains "$out" "no build has appeared yet" "missing-bundle"
  assert_machine_untouched missing-bundle
  pass "an unobtainable sealed bundle refuses before anything on the machine changes"
}

test_an_unmet_host_requirement_refuses_before_touching_the_machine() {
  local out rc=0
  make_case unmet-host-requirement
  # The new version's own units gate their start on a file this machine owns and
  # does not have yet. Discovering that after the app is stopped is how a
  # dashboard came back while the sign-in stack stayed down.
  out=$(FMTEST_GH_RC=0 FMTEST_PRECHECK_FAILS=1 run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "unmet-host-requirement: deployed although the machine did not meet the new version's requirements"
  assert_contains "$out" "validate_allowed_emails.py" "unmet-host-requirement"
  assert_contains "$out" "demo-proxy.service" "unmet-host-requirement"
  # It refuses on the requirement it checked. The machine makes every
  # service-user command run from a directory that user cannot read, so a check
  # that answered from there would refuse about its own working directory
  # instead, and name a problem the release does not have.
  assert_not_contains "$out" "Failed to restore initial working directory" \
    "unmet-host-requirement"
  assert_machine_untouched unmet-host-requirement
  assert_grep '"result":"refused"' "$HOME_DIR/state/deploy-ledger/demo.jsonl" \
    "unmet-host-requirement: the refusal was not recorded in the ledger"
  pass "a start-time requirement the machine does not meet refuses by name, before anything on the machine changes"
}

test_a_front_end_the_service_user_cannot_read_refuses_before_touching_the_machine() {
  local out rc=0
  make_case unreadable-front-end
  # The bundle is on the machine but landed in a mode the app's own user cannot
  # open. Discovering that after the stop and the checkout is how a site stayed
  # down over a front end that only needed its modes fixed.
  out=$(FMTEST_GH_RC=0 FMTEST_BUNDLE_UNREADABLE=1 run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable-front-end: deployed a front end the app cannot read"
  assert_contains "$out" "cannot read all of it" "unreadable-front-end"
  assert_machine_untouched unreadable-front-end
  assert_grep '"result":"refused"' "$HOME_DIR/state/deploy-ledger/demo.jsonl" \
    "unreadable-front-end: the refusal was not recorded in the ledger"
  pass "a front end the app's own user cannot read refuses before anything on the machine changes"
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

test_a_build_still_running_is_a_race_not_a_missing_bundle() {
  local out rc=0
  make_case build-running
  # The deploy that follows a merge can outrun the commit's own build. That is
  # the incident this covers: the captain was told the bundle was gone when it
  # simply did not exist yet.
  out=$(FMTEST_GH_RC=0 FMTEST_BUILD_STATE='in_progress ' \
    run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "build-running: deployed against a build that had not finished"
  assert_contains "$out" "has not finished yet" build-running
  case "$out" in
    *"no longer available"* | *"kept only briefly"*)
      fail "build-running: a build still in progress was reported as an expired bundle: $out"
      ;;
  esac
  assert_machine_untouched build-running
  pass "a build that has not finished yet is refused as a race, not as a bundle that expired"
}

test_a_build_that_failed_is_named_as_a_failed_build() {
  local out rc=0
  make_case build-failed
  out=$(FMTEST_GH_RC=0 FMTEST_BUILD_STATE='completed failure' \
    run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "build-failed: deployed against a build that did not succeed"
  assert_contains "$out" "finished without succeeding" build-failed
  assert_machine_untouched build-failed
  pass "a build that finished without succeeding is refused as that, not as a missing bundle"
}

test_an_expired_artifact_is_still_reported_as_expired() {
  local out rc=0
  make_case build-expired
  # The one case that is genuinely about retention: the build for this commit
  # ran and succeeded, and only the artifact is gone. Splitting the races out
  # must not cost this path its own message.
  out=$(FMTEST_GH_RC=0 FMTEST_BUILD_STATE='completed success' FMTEST_DOWNLOAD_FAILS=1 \
    run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "build-expired: deployed a version whose front end was never downloaded"
  assert_contains "$out" "no longer available for download" build-expired
  assert_machine_untouched build-expired
  pass "a green build whose artifact has expired is still reported as an expired artifact"
}

test_a_deploy_freeze_pauses_the_trigger_but_not_the_captain() {
  local queued out rc=0
  make_case trigger-frozen
  fm_write_meta "$HOME_DIR/state/task-f.meta" "project=$REPO" "worktree=$REPO"
  mkdir -p "$HOME_DIR/config/deploy-freeze"
  : > "$HOME_DIR/config/deploy-freeze/demo"

  ( PATH="$FAKEBIN:$PATH" FM_DEPLOY_SYNC_TIMEOUT=5 \
      "$ROOT/bin/fm-deploy-trigger.sh" "$HOME_DIR" "$HOME_DIR/state" task-f ) \
    || fail "trigger-frozen: the trigger reported a failure for a frozen project"
  assert_machine_untouched trigger-frozen
  # The policy is untouched, so the reserved-surface list survives the pause.
  [ -f "$HOME_DIR/config/deploy-policy/demo" ] \
    || fail "trigger-frozen: the freeze removed the policy it was supposed to leave alone"
  queued=$(cat "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queued" "going live on its own is paused" trigger-frozen
  assert_absent "$HOME_DIR/state/deploy-ledger/demo.jsonl" \
    "trigger-frozen: a frozen project still reached the deploy path"

  # The captain running it by hand is exactly what the freeze reserves, so that
  # path must stay open: it gets past the freeze and refuses for its own reason.
  out=$(run_deploy demo "$PLAIN") || rc=$?
  case "$out" in
    *paused*) fail "trigger-frozen: the freeze blocked a deploy the captain ran by hand: $out" ;;
  esac
  pass "a deploy freeze pauses the merge trigger, keeps the policy, and leaves a hand-run deploy working"
}

test_only_a_build_race_refuses_with_the_transient_status() {
  local rc
  make_case transient-status
  # The whole deferred re-check turns on telling "wait" apart from "no" by exit
  # status alone, so this pins both halves of that split in one place. The two
  # build races are the only refusals whose condition clears with nobody doing
  # anything.
  rc=0; FMTEST_GH_RC=0 FMTEST_BUILD_STATE='in_progress ' run_deploy demo "$PLAIN" >/dev/null 2>&1 || rc=$?
  expect_code 4 "$rc" "transient-status: a build still running"
  rc=0; run_deploy demo "$PLAIN" >/dev/null 2>&1 || rc=$?
  expect_code 4 "$rc" "transient-status: no build for the commit yet"
  rc=0; FMTEST_GH_RC=0 FMTEST_BUILD_STATE='completed failure' run_deploy demo "$PLAIN" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "transient-status: a build that finished without succeeding"
  rc=0; FMTEST_GH_RC=0 FMTEST_DOWNLOAD_FAILS=1 run_deploy demo "$PLAIN" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "transient-status: an artifact past its retention"
  rc=0; run_deploy demo "$DESIGN" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "transient-status: a range touching a reserved surface"
  pass "only the two build races refuse with the status that means wait; every other refusal means no"
}

test_a_merge_that_outran_its_build_is_recorded_not_reported() {
  local record out
  make_deployable_case early-merge
  out=$(FMTEST_GH_RC=0 FMTEST_BUILD_STATE='in_progress ' run_trigger task-p) \
    || fail "early-merge: the trigger reported a failure"
  [ -z "$out" ] || fail "early-merge: the merge path printed something: $out"
  assert_machine_untouched early-merge
  # Being a few minutes early is not news, so nothing is said.
  assert_not_contains "$(queued_wakes)" "needs a look" early-merge
  assert_not_contains "$(queued_wakes)" "up to date with everything merged" early-merge
  record=$(pending_record)
  assert_present "$record" "early-merge: no record was written to finish the deploy later"
  assert_grep "sha=$PLAIN" "$record" "early-merge: the record does not name the commit that was refused"
  assert_grep "from_sha=$DEPLOYED" "$record" "early-merge: the record does not name the version it would replace"
  assert_grep "authority=auto" "$record" "early-merge: the record does not name the authority it acted under"
  assert_grep "has not finished yet" "$record" "early-merge: the record does not name the reason"
  pass "a merge that outran its own build is recorded to be finished later, not reported to the captain"
}

test_the_recorded_deploy_goes_live_once_the_build_lands() {
  local out
  make_deployable_case build-lands
  record_an_early_merge build-lands
  [ "$(deploy_count)" = 0 ] || fail "build-lands: the early merge changed the machine"

  out=$(FMTEST_GH_RC=0 FMTEST_BUILD_STATE='completed success' run_trigger --resume-pending) \
    || fail "build-lands: the deferred re-check reported a failure"
  assert_contains "$out" demo "build-lands: the re-check did not name the project it acted on"
  [ "$(deploy_count)" = 1 ] \
    || fail "build-lands: the deploy did not happen once the build landed: $(tr '\n' '|' < "$SSH_LOG")"
  assert_absent "$(pending_record)" "build-lands: the record outlived the deploy it asked for"
  assert_contains "$(queued_wakes)" "up to date with everything merged" build-lands
  # ...and it cleared the record because the deploy SUCCEEDED, not because it
  # reached the machine and failed there. Without this the case would pass on
  # the failure path and still look like proof the build landing works.
  assert_not_contains "$(queued_wakes)" "could not be updated automatically" build-lands

  # Nothing is left to re-run, so a later cycle is silent and the machine is not
  # deployed to a second time.
  out=$(FMTEST_GH_RC=0 FMTEST_BUILD_STATE='completed success' run_trigger --resume-pending) \
    || fail "build-lands: the second re-check reported a failure"
  [ -z "$out" ] || fail "build-lands: an empty re-check still woke firstmate: $out"
  [ "$(deploy_count)" = 1 ] || fail "build-lands: the same merge deployed twice"
  pass "a deploy refused only because the build was late goes live exactly once when the build lands"
}

test_a_merge_that_never_builds_is_reported_once_and_cleared() {
  local out
  make_deployable_case build-never
  record_an_early_merge build-never

  out=$(FMTEST_GH_RC=0 FMTEST_BUILD_STATE='completed failure' run_trigger --resume-pending) \
    || fail "build-never: the deferred re-check reported a failure"
  assert_contains "$out" demo "build-never: the re-check did not name the project it acted on"
  assert_machine_untouched build-never
  assert_contains "$(queued_wakes)" "could not be updated automatically" build-never
  assert_contains "$(queued_wakes)" "finished without succeeding" build-never
  assert_absent "$(pending_record)" "build-never: a build that will never succeed is still being waited for"

  out=$(FMTEST_GH_RC=0 FMTEST_BUILD_STATE='completed failure' run_trigger --resume-pending) \
    || fail "build-never: the second re-check reported a failure"
  [ -z "$out" ] || fail "build-never: the same failed build was reported twice: $out"
  pass "a merge whose build never succeeds is reported once and stops being waited for"
}

test_a_newer_merge_supersedes_the_pending_one() {
  local record newer
  make_deployable_case superseded
  record_an_early_merge superseded
  record=$(pending_record)
  assert_grep "sha=$PLAIN" "$record" "superseded: the first merge was not recorded"

  # The newer merge has to build on the commit origin/main already points at,
  # not on the reserved design commit further along this branch, or the range
  # would stop being auto-deployable and the case would be measuring that
  # instead of supersession.
  git_c checkout -q --detach "$PLAIN"
  commit_file src/engine.py engine2 "a second plain code change"
  newer=$(git_c rev-parse HEAD)
  git_c update-ref refs/remotes/origin/main "$newer"
  FMTEST_TARGET_SHA=$newer FMTEST_GH_RC=0 FMTEST_BUILD_STATE='in_progress ' run_trigger task-p \
    || fail "superseded: the trigger reported a failure for the newer merge"

  assert_grep "sha=$newer" "$record" "superseded: the newer merge did not take over the record"
  assert_no_grep "sha=$PLAIN" "$record" "superseded: the older commit is still what would be deployed"
  [ "$(find "$HOME_DIR/state/deploy-pending" -type f | wc -l)" -eq 1 ] \
    || fail "superseded: the project ended up with more than one pending deploy"
  pass "a newer merge supersedes the pending one for the same project rather than queueing behind it"
}

test_the_pending_deploy_outlives_the_task_that_merged_it() {
  local out
  make_deployable_case outlives-task
  record_an_early_merge outlives-task

  # Cleaning up the task that merged the work is ordinary, and it happens well
  # before a slow build finishes. Teardown removes that task's own records and
  # nothing else, so this leaves exactly what a completed one leaves: no trace
  # of task-p at all. That the record itself survives a REAL teardown is
  # asserted where a real teardown fixture exists, in tests/fm-teardown.test.sh;
  # what this case owns is that the deploy still happens afterwards.
  rm -f "$HOME_DIR/state/task-p".*
  out=$(FMTEST_GH_RC=0 FMTEST_BUILD_STATE='completed success' run_trigger --resume-pending) \
    || fail "outlives-task: the deferred re-check reported a failure"
  assert_contains "$out" demo "outlives-task: the re-check did not name the project it acted on"
  [ "$(deploy_count)" = 1 ] \
    || fail "outlives-task: the deploy did not happen after the task was cleaned up: $(tr '\n' '|' < "$SSH_LOG")"
  assert_absent "$(pending_record)" "outlives-task: the record outlived the deploy it asked for"
  pass "a pending deploy outlives the task whose merge created it"
}

test_a_pending_deploy_stops_waiting_past_its_horizon() {
  local out record
  make_deployable_case gives-up
  record_an_early_merge gives-up
  record=$(pending_record)
  # Age the record rather than wait out the horizon.
  sed -i.bak "s/^first_seen=.*/first_seen=$(( $(date +%s) - 4000 ))/" "$record"
  rm -f "$record.bak"

  out=$(FM_DEPLOY_PENDING_MAX_SECS=300 FMTEST_GH_RC=0 FMTEST_BUILD_STATE='in_progress ' \
    run_trigger --resume-pending) || fail "gives-up: the deferred re-check reported a failure"
  assert_contains "$out" demo "gives-up: the re-check did not name the project it acted on"
  assert_contains "$(queued_wakes)" "still has not gone live" gives-up
  assert_machine_untouched gives-up
  assert_absent "$record" "gives-up: the record is still being waited on past its horizon"
  pass "a pending deploy that waits past its horizon stops waiting and says the merge never built"
}


test_a_reserved_range_refuses_before_touching_the_machine
test_a_build_still_running_is_a_race_not_a_missing_bundle
test_a_build_that_failed_is_named_as_a_failed_build
test_an_expired_artifact_is_still_reported_as_expired
test_a_deploy_freeze_pauses_the_trigger_but_not_the_captain
test_the_permission_flag_alone_is_not_permission
test_the_captains_words_let_the_same_range_through
test_a_run_in_progress_refuses_before_touching_the_machine
test_an_unreadable_run_state_refuses
test_an_unobtainable_bundle_refuses_before_touching_the_machine
test_an_unmet_host_requirement_refuses_before_touching_the_machine
test_a_front_end_the_service_user_cannot_read_refuses_before_touching_the_machine
test_a_broken_deploy_target_is_refused_rather_than_partly_used
test_the_merge_trigger_is_inert_without_a_policy
test_the_merge_trigger_never_deploys_a_reserved_range
test_a_clone_without_origin_head_still_resolves_its_target
test_only_a_build_race_refuses_with_the_transient_status
test_a_merge_that_outran_its_build_is_recorded_not_reported
test_the_recorded_deploy_goes_live_once_the_build_lands
test_a_merge_that_never_builds_is_reported_once_and_cleared
test_a_newer_merge_supersedes_the_pending_one
test_the_pending_deploy_outlives_the_task_that_merged_it
test_a_pending_deploy_stops_waiting_past_its_horizon
