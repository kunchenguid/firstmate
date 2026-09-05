#!/usr/bin/env bash
# Tests for what bin/fm-deploy.sh does when it does NOT refuse: the completed
# deploy, the durable ledger it leaves, and the one-command rollback that ledger
# makes possible.
#
# tests/fm-deploy-refusals.test.sh covers the refusals. This file exists because
# a deploy tool whose refusals are all proved and whose success path is not can
# still be one that never successfully deploys anything.
#
# The host is a fake `ssh` that records every command it is asked to run, so the
# assertions are about the ORDER and CONTENT of what reached the machine, not
# just an exit status.
#
# Matrix:
#   (a) a clean auto-deployable range completes, and does so in the documented
#       order: set the old version aside, stop, check out, install the bundle,
#       reinstall the unit, verify the bundle, restart
#   (b) the completed deploy is recorded in the ledger with where it came from,
#       where it went, and under what authority
#   (c) the previous version's front end is copied aside BEFORE anything stops,
#       because the build that produced it may be past its retention by the time
#       it is wanted back
#   (d) `--rollback` needs no sha and no captain permission, targets exactly the
#       version the last completed deploy came from, and puts back the front end
#       set aside for it rather than a download that is no longer available
#   (e) a restart that comes up unhealthy is reported as a failed deploy, with
#       the rollback command, rather than reported as live
#   (f) a command run as the service user starts somewhere that user can read,
#       so a check answers its own question instead of the login shell's
#       working directory
#   (g) a rollback after a failed deploy ends with the previous version running
#       and answering, and re-runs none of the start-time checks
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deploy-ledger-tests)
rollback_root_for_test=/var/lib/demo-deploy/rollback

git_c() { git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

commit_file() {
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "$2" > "$REPO/$1"
  git_c add -A
  git_c commit -qm "$3"
}

# Sets CASE_DIR, HOME_DIR, REPO, SSH_LOG, FAKEBIN, DEPLOYED, PLAIN as globals;
# see the same note in tests/fm-deploy-refusals.test.sh.
make_case() {
  local name=$1 fakebin
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  REPO="$HOME_DIR/projects/demo"
  SSH_LOG="$CASE_DIR/ssh.log"
  mkdir -p "$HOME_DIR/config/deploy-policy" "$HOME_DIR/config/deploy-target" \
    "$HOME_DIR/state" "$REPO"

  git_c init -q -b main
  commit_file README.md base "base"
  DEPLOYED=$(git_c rev-parse HEAD)
  # A real unit set: the app's own unit, and a second unit whose start is gated
  # on a file the MACHINE owns rather than one the release brings. That second
  # requirement is the class this deploy path has to prove before it stops
  # anything, so the fixture has to carry one or every assertion below passes
  # over an empty precondition set.
  mkdir -p "$REPO/deploy/systemd"
  cat > "$REPO/deploy/systemd/demo-app.service" <<'UNIT'
[Unit]
Description=demo app
[Service]
User=demo
ExecStartPre=/opt/demo/.venv/bin/python -B /opt/demo/deploy/verify_bundle.py
ExecStart=/opt/demo/.venv/bin/demo
UNIT
  cat > "$REPO/deploy/systemd/demo-proxy.service" <<'UNIT'
[Unit]
Description=demo sign-in proxy
[Service]
User=demo-proxy
ExecStartPre=-/opt/demo/.venv/bin/python -B /opt/demo/deploy/optional_note.py /etc/demo/note
ExecStartPre=/opt/demo/.venv/bin/python -B /opt/demo/deploy/require_ready.py --timeout-seconds 30
ExecStartPre=/opt/demo/.venv/bin/python -B /opt/demo/deploy/validate_allowed_emails.py /etc/demo/allowed-emails
ExecStart=/opt/demo/.venv/bin/demo-proxy
UNIT
  printf 'x\n' > "$REPO/deploy/validate_allowed_emails.py"
  printf 'x\n' > "$REPO/deploy/require_ready.py"
  printf 'x\n' > "$REPO/deploy/optional_note.py"
  printf 'x\n' > "$REPO/deploy/verify_bundle.py"
  git_c add -A
  git_c commit -qm "the machine's own units"
  DEPLOYED=$(git_c rev-parse HEAD)
  commit_file src/engine.py engine "a plain code change"
  PLAIN=$(git_c rev-parse HEAD)
  git_c remote add origin git@github.com:example/demo.git
  git_c update-ref refs/remotes/origin/main "$PLAIN"

  printf 'dashboard/v2/src/**\n' > "$HOME_DIR/config/deploy-policy/demo"
  cat > "$HOME_DIR/config/deploy-target/demo" <<'TGT'
host=host.invalid
user=deployer
checkout=/opt/demo
unit=demo-app
python=/opt/demo/.venv/bin/python
rollback_root=/var/lib/demo-deploy/rollback
health_url=http://127.0.0.1:8765/api/health
public_url=https://demo.invalid/
public_expect=403
bundle_path=dashboard/v2/dist
bundle_artifact=demo-dist
bundle_workflow=demo-ci.yml
bundle_verify=deploy/verify_bundle.py
run_lock=/var/lib/demo/runs/.lock
TGT

  fakebin=$(fm_fakebin "$CASE_DIR")
  cat > "$fakebin/ssh" <<SH
#!/usr/bin/env bash
set -u
cmd=\${!#}
printf '%s\n' "\$cmd" >> '$SSH_LOG'
# This machine's login user has a private home, and a command run under
# \`sudo -u\` inherits the working directory of the shell that started it.
# \`find\` walks by changing directory and then cannot get back, which is the
# failure that took a live site down over a bundle that was perfectly readable.
# Any service-user command that does not start somewhere that user can read
# fails here exactly as it did on the real machine.
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
  # The restart above can win the race with the app's own bind, in which case a
  # probe taken right after gets connection-refused rather than an answer.
  # FMTEST_HEALTH_MISS_PROBES is how a test says that gap lasted a given number
  # of probes: this fake machine answers "000" - curl's own code for "never
  # connected" - that many times, then settles on FMTEST_HEALTH. Left unset, it
  # answers FMTEST_HEALTH from the first probe, as before.
  *'http_code'*)
    if [ -n "\${FMTEST_HEALTH_MISS_PROBES:-}" ]; then
      n=\$(( \$(cat '$CASE_DIR/health-probes' 2>/dev/null || printf 0) + 1 ))
      printf '%s' "\$n" > '$CASE_DIR/health-probes'
      if [ "\$n" -le "\${FMTEST_HEALTH_MISS_PROBES}" ]; then
        printf '000\n'
      else
        printf '%s\n' "\${FMTEST_HEALTH:-200}"
      fi
    else
      printf '%s\n' "\${FMTEST_HEALTH:-200}"
    fi
    ;;
  # A start-time requirement the machine does not meet yet: FMTEST_PRECHECK_FAILS
  # names the validator this fake machine refuses.
  *'sudo -u '*'validate_allowed_emails.py'*)
    [ -z "\${FMTEST_PRECHECK_FAILS:-}" ] || { printf 'operator allow-list refused\n' >&2; exit 1; } ;;
  # The service user's own view of the front end. FMTEST_BUNDLE_UNREADABLE is how
  # a test says the bundle landed in a mode that user cannot read - the paths go
  # to stdout, because that is where find puts what it was asked for.
  # FMTEST_READABLE_BROKEN is the other outcome: the check could not answer at
  # all, and said so on stderr.
  *'-readable'*)
    [ -z "\${FMTEST_READABLE_BROKEN:-}" ] || { printf 'find: /opt/demo: Permission denied\n' >&2; exit 1; }
    [ -z "\${FMTEST_BUNDLE_UNREADABLE:-}" ] || { printf '/opt/demo/dashboard/v2/dist\n'; exit 1; } ;;
  # The set-aside copy of a version's front end is real state on this fake
  # machine: only a version whose front end was actually copied aside answers
  # yes when the deployer asks whether it still has one.
  *'cp -a'*rollback*)
    printf '%s' "\$cmd" | grep -o '/var/lib/demo-deploy/rollback/[0-9a-f]*/bundle' \
      | head -1 >> '$CASE_DIR/aside.log' ;;
  *'test -d '*'/bundle'*)
    p=\$(printf '%s' "\$cmd" | grep -o '/var/lib/demo-deploy/rollback/[0-9a-f]*/bundle' | head -1)
    grep -qxF "\$p" '$CASE_DIR/aside.log' 2>/dev/null || exit 1 ;;
  # Only the bundle install is fed on stdin; draining it for every command
  # would block on a pipe nothing ever closes.
  *'-xzf -'*)         cat >/dev/null 2>&1 || true ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  run)
    case "${2:-}" in
      list)
        printf '[{"databaseId":4242,"headSha":"%s"}]\n' "$FMTEST_TARGET_SHA"
        ;;
      download)
        # A build is downloadable only briefly. FMTEST_GH_DOWNLOAD_FAILS is how
        # a test says that window has closed for the commit being asked for.
        [ -z "${FMTEST_GH_DOWNLOAD_FAILS:-}" ] || exit 1
        out=''
        while [ "$#" -gt 0 ]; do
          [ "$1" = -D ] && { shift; out=$1; }
          shift
        done
        mkdir -p "$out/assets" "$out/.vite"
        printf 'built\n' > "$out/index.html"
        printf '{}\n' > "$out/bundle-seal.json"
        printf '{}\n' > "$out/.vite/manifest.json"
        ;;
    esac
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
}

run_deploy() {
  ( PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FMTEST_TARGET_SHA="${FMTEST_TARGET_SHA:-$PLAIN}" \
      "$ROOT/bin/fm-deploy.sh" "$@" 2>&1 )
}

# step_line <pattern>: the 1-based line number of the first transport command
# matching <pattern>, or empty.
step_line() { grep -n -- "$1" "$SSH_LOG" | head -1 | cut -d: -f1; }

test_a_clean_range_deploys_in_the_documented_order() {
  local out rc=0 stage readable aside stop checkout swap unit verify restart
  make_case clean-deploy
  out=$(run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -eq 0 ] || fail "clean-deploy: an auto-deployable range failed: $out"
  assert_contains "$out" "is live at $PLAIN" "clean-deploy"

  stage=$(step_line 'install -d .*dashboard/v2/dist.incoming')
  readable=$(step_line "'!' -readable")
  # The copy aside is the one command that copies INTO rollback_root; the
  # precheck extraction mentions that directory too, so matching the directory
  # name alone would silently assert about the wrong step.
  aside=$(step_line 'cp -a')
  stop=$(step_line 'systemctl stop')
  checkout=$(step_line 'checkout --detach')
  swap=$(step_line 'mv .*dashboard/v2/dist.incoming')
  unit=$(step_line '/etc/systemd/system/demo-app.service')
  verify=$(step_line 'deploy/verify_bundle.py')
  restart=$(step_line 'systemctl restart')
  for step in stage readable aside stop checkout swap unit verify restart; do
    [ -n "${!step}" ] || fail "clean-deploy: the $step step never reached the machine: $(tr '\n' '|' < "$SSH_LOG")"
  done
  # Everything the machine can answer about the new version is answered while
  # the old one is still serving: the front end is staged and proved readable,
  # and only then is anything set aside, stopped, or swapped.
  [ "$stage" -lt "$readable" ] && [ "$readable" -lt "$aside" ] && [ "$aside" -lt "$stop" ] \
    || fail "clean-deploy: the new front end was not staged and proved readable before the app was stopped: $(tr '\n' '|' < "$SSH_LOG")"
  [ "$stop" -lt "$checkout" ] && [ "$checkout" -lt "$swap" ] && [ "$swap" -lt "$unit" ] \
    && [ "$unit" -lt "$verify" ] && [ "$verify" -lt "$restart" ] \
    || fail "clean-deploy: steps ran out of order: $(tr '\n' '|' < "$SSH_LOG")"

  # The sign-in and TLS units are never STARTED, STOPPED, or REINSTALLED. That
  # is the standing safety boundary, and it is what these assert. The deploy
  # does now READ the sign-in unit's start-time requirements before it stops
  # anything, so a bare mention of that unit's name is no longer the right
  # test; a systemctl action or a unit-file install on it still is.
  # These are fixed strings, as assert_no_grep requires: the deploy quotes the
  # unit it acts on, so these are exactly what a stop, a restart, or a
  # reinstall of the sign-in unit would put in the log.
  assert_no_grep "systemctl stop 'demo-proxy'" "$SSH_LOG" \
    "clean-deploy: the sign-in unit was stopped"
  assert_no_grep "systemctl restart 'demo-proxy'" "$SSH_LOG" \
    "clean-deploy: the sign-in unit was restarted"
  assert_no_grep '/etc/systemd/system/demo-proxy' "$SSH_LOG" \
    "clean-deploy: the sign-in unit was reinstalled"
  # ...and it did read that unit's start-time requirement, which is what makes
  # the three assertions above a narrower boundary rather than a vacuous one.
  assert_grep "sudo -u 'demo-proxy'" "$SSH_LOG" \
    "clean-deploy: the sign-in unit's start-time requirement was never checked at all"
  assert_no_grep 'caddy' "$SSH_LOG" "clean-deploy: the TLS unit was touched"
  pass "a clean auto-deployable range deploys in the documented order and touches no other unit"
}

test_the_completed_deploy_is_recorded() {
  local ledger
  make_case recorded-deploy
  run_deploy demo "$PLAIN" >/dev/null || fail "recorded-deploy: the deploy failed"
  ledger="$HOME_DIR/state/deploy-ledger/demo.jsonl"
  assert_present "$ledger" "recorded-deploy: no ledger was written"
  assert_grep '"result":"deployed"' "$ledger" "recorded-deploy: the outcome was not recorded"
  assert_grep "\"from\":\"$DEPLOYED\"" "$ledger" "recorded-deploy: the previous version was not recorded"
  assert_grep "\"to\":\"$PLAIN\"" "$ledger" "recorded-deploy: the new version was not recorded"
  assert_grep '"authority":"auto"' "$ledger" "recorded-deploy: the authority was not recorded"
  pass "a completed deploy is recorded with where it came from, where it went, and under what authority"
}

test_rollback_targets_the_version_the_last_deploy_came_from() {
  local out rc=0
  make_case rollback
  run_deploy demo "$PLAIN" >/dev/null || fail "rollback: the first deploy failed"
  : > "$SSH_LOG"
  # The machine now runs the new version, as it would after that deploy.
  # The build that produced the previous front end is past its download window,
  # which is the ordinary case: a rollback is wanted days after the deploy it
  # undoes. The copy set aside on the machine is what makes this one command.
  out=$(FMTEST_HOST_SHA="$PLAIN" FMTEST_GH_DOWNLOAD_FAILS=1 run_deploy demo --rollback) || rc=$?
  [ "$rc" -eq 0 ] || fail "rollback: --rollback failed: $out"
  assert_contains "$out" "$DEPLOYED" "rollback"
  assert_grep "checkout --detach '$DEPLOYED'" "$SSH_LOG" \
    "rollback: the machine was not returned to the version the last deploy came from"
  # The direction matters: the read-only probe above and the aside copy of a
  # later deploy both mention this path too. Only the restore copies FROM the
  # set-aside bundle INTO the checkout.
  assert_grep "cp -a \"$rollback_root_for_test/$DEPLOYED/bundle\" \"/opt/demo/dashboard/v2/dist\"" "$SSH_LOG" \
    "rollback: the front end the previous version ran with was never put back"
  assert_no_grep 'dist.incoming' "$SSH_LOG" \
    "rollback: the front end was re-downloaded instead of restored from the copy kept for exactly this"
  pass "--rollback needs no sha and no permission, and restores the version and front end the last deploy came from"
}

test_an_unhealthy_restart_is_a_failed_deploy_not_a_live_one() {
  local out rc=0
  make_case unhealthy-restart
  out=$(FMTEST_HEALTH=503 run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "unhealthy-restart: a version that never came up healthy was reported as live"
  assert_not_contains "$out" "is live at" "unhealthy-restart"
  assert_contains "$out" "--rollback" "unhealthy-restart"
  assert_grep '"result":"failed"' "$HOME_DIR/state/deploy-ledger/demo.jsonl" \
    "unhealthy-restart: the failure was not recorded"
  pass "a restart that never comes up healthy is reported as a failed deploy with its rollback command"
}

test_a_health_probe_that_wins_the_bind_race_on_retry_still_deploys() {
  local out rc=0 probes ledger
  make_case health-probe-bind-race
  # The restart above can win the race with the app's own bind: the first
  # probes taken land in that gap and get "000" - curl's own code for "never
  # connected" - even though the app answers moments later. This is the
  # incident itself: a probe taken once during that gap reported a version
  # live-but-unhealthy that the host journal showed had already answered 200.
  out=$(FMTEST_HEALTH_MISS_PROBES=2 FM_DEPLOY_HEALTH_INTERVAL_SECONDS=1 run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -eq 0 ] || fail "health-probe-bind-race: a health check that only needed to catch up with the app's own bind was reported as failed: $out"
  assert_contains "$out" "is live at $PLAIN" "health-probe-bind-race"
  probes=$(grep -c "http_code" "$SSH_LOG")
  [ "$probes" -eq 3 ] || fail "health-probe-bind-race: expected 3 health probes (2 misses then an answer), saw $probes: $(tr '\n' '|' < "$SSH_LOG")"
  ledger="$HOME_DIR/state/deploy-ledger/demo.jsonl"
  assert_grep '"result":"deployed"' "$ledger" "health-probe-bind-race: the deploy was not recorded"
  grep -E '"detail":"[^"]*health answered 200 after [0-9]+s' "$ledger" >/dev/null \
    || fail "health-probe-bind-race: the ledger detail did not record the final probe outcome and the elapsed wait: $(cat "$ledger")"
  pass "a health probe that only needs to catch up with the app's own bind window retries instead of failing, and the ledger records the wait"
}

test_a_health_probe_that_never_answers_fails_within_its_window() {
  local out rc=0 probes ledger
  make_case health-probe-never-answers
  # A window this small still exercises the same bounded-wait mechanism: the
  # probe never gets past "000", so this proves the OTHER half of the same
  # incident - a version that truly never comes up must still be declared
  # failed, not left waiting forever or reported live on a hopeful first try.
  out=$(FMTEST_HEALTH_MISS_PROBES=999 FM_DEPLOY_HEALTH_WINDOW_SECONDS=1 FM_DEPLOY_HEALTH_INTERVAL_SECONDS=1 \
    run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "health-probe-never-answers: a health check that never came up was reported as live"
  assert_not_contains "$out" "is live at" "health-probe-never-answers"
  assert_contains "$out" "--rollback" "health-probe-never-answers"
  probes=$(grep -c "http_code" "$SSH_LOG")
  [ "$probes" -ge 2 ] || fail "health-probe-never-answers: only one probe was taken, so the window was not honored: $(tr '\n' '|' < "$SSH_LOG")"
  ledger="$HOME_DIR/state/deploy-ledger/demo.jsonl"
  assert_grep '"result":"failed"' "$ledger" "health-probe-never-answers: the failure was not recorded"
  grep -E '"detail":"[^"]*after waiting [0-9]+s \(it answered 000\)' "$ledger" >/dev/null \
    || fail "health-probe-never-answers: the ledger detail did not record the final probe outcome and the elapsed wait: $(cat "$ledger")"
  pass "a health check that never comes up is declared failed once its window is exhausted, and the ledger records the wait"
}

test_the_precheck_runs_before_the_stop_and_only_on_host_owned_files() {
  local out rc=0 precheck stop
  make_case precheck-order
  out=$(run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -eq 0 ] || fail "precheck-order: the deploy failed: $out"

  precheck=$(step_line 'validate_allowed_emails.py')
  stop=$(step_line 'systemctl stop')
  [ -n "$precheck" ] \
    || fail "precheck-order: the allow-list requirement was never checked: $(tr '\n' '|' < "$SSH_LOG")"
  [ -n "$stop" ] && [ "$precheck" -lt "$stop" ] \
    || fail "precheck-order: the machine was stopped before its start-time requirements were checked"
  assert_grep "sudo -u 'demo-proxy'" "$SSH_LOG" \
    "precheck-order: the requirement was not checked as the user the unit runs as"

  # A requirement whose answer needs the new release already running cannot be
  # proved first, and must not be pretended: the readiness check and the
  # ignore-failure line are both absent from what ran before the stop.
  assert_no_grep 'require_ready.py' "$SSH_LOG" \
    "precheck-order: a runtime readiness check was run as if it were a precondition"
  assert_no_grep 'optional_note.py' "$SSH_LOG" \
    "precheck-order: a requirement systemd itself ignores was treated as one"
  pass "the start-time requirements a machine can answer are checked, as the unit's own user, before anything stops"
}

test_a_bundle_the_service_user_cannot_read_never_restarts() {
  local out rc=0
  make_case unreadable-bundle
  out=$(FMTEST_BUNDLE_UNREADABLE=1 run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable-bundle: a front end the app could not read was reported as live"
  assert_not_contains "$out" "is live at" "unreadable-bundle"
  assert_contains "$out" "cannot read all of it" "unreadable-bundle"
  # The whole point of asking while the old version is still serving: this is a
  # refusal that changed nothing, not a failure with the app already down.
  assert_no_grep 'systemctl stop' "$SSH_LOG" \
    "unreadable-bundle: the app was stopped over a front end that never passed its check"
  assert_no_grep 'checkout --detach' "$SSH_LOG" \
    "unreadable-bundle: the machine was moved to the new version anyway"
  assert_no_grep 'systemctl restart' "$SSH_LOG" \
    "unreadable-bundle: the app was restarted onto a front end it cannot read"
  assert_grep 'chmod -R a+rX' "$SSH_LOG" \
    "unreadable-bundle: the staged front end was never made readable at all"
  assert_grep '"result":"refused"' "$HOME_DIR/state/deploy-ledger/demo.jsonl" \
    "unreadable-bundle: the refusal was not recorded"
  pass "a front end the service user cannot read refuses the deploy with the app still serving"
}

test_a_service_user_check_answers_from_a_directory_it_can_read() {
  local out rc=0
  make_case service-user-cwd
  # The fake machine fails every service-user command that starts in the login
  # user's private home, exactly as the real one did. A deploy that completes
  # here is one whose checks ran from somewhere the service user can read.
  out=$(run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -eq 0 ] || fail "service-user-cwd: a check failed on its own working directory rather than its question: $out"
  assert_contains "$out" "is live at $PLAIN" "service-user-cwd"
  assert_grep "sudo -u 'demo-proxy'" "$SSH_LOG" \
    "service-user-cwd: no command ran as a service user at all, so this proves nothing"
  assert_grep "sudo -u 'demo'" "$SSH_LOG" \
    "service-user-cwd: the front end was never checked as the user the app runs as"
  assert_not_contains "$out" 'Failed to restore initial working directory' \
    "service-user-cwd: the working-directory failure reached the deploy's own report"
  pass "a check run as the service user starts where that user can read, and answers its own question"
}

test_a_readability_check_that_cannot_answer_says_so() {
  local out rc=0
  make_case readable-unanswerable
  out=$(FMTEST_READABLE_BROKEN=1 run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "readable-unanswerable: deployed without knowing whether the app could read its front end"
  assert_contains "$out" "could not tell" "readable-unanswerable"
  assert_not_contains "$out" "cannot read all of it" "readable-unanswerable"
  assert_no_grep 'systemctl stop' "$SSH_LOG" \
    "readable-unanswerable: the app was stopped on a check that never answered"
  pass "a readability check that cannot answer refuses as itself, not as an unreadable release"
}

test_rollback_works_after_a_failed_deploy() {
  local out rc=0 ledger
  make_case rollback-after-failure
  # The deploy that just failed is exactly when a rollback is wanted, and it set
  # the outgoing version aside before it stopped anything, same as a completed
  # one does. The ledger therefore holds only a `failed` record here.
  out=$(FMTEST_HEALTH=503 run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "rollback-after-failure: the unhealthy deploy did not fail"
  ledger="$HOME_DIR/state/deploy-ledger/demo.jsonl"
  assert_no_grep '"result":"deployed"' "$ledger" \
    "rollback-after-failure: the fixture recorded a completed deploy, so this proves nothing"

  : > "$SSH_LOG"
  rc=0
  out=$(FMTEST_HOST_SHA="$PLAIN" FMTEST_GH_DOWNLOAD_FAILS=1 run_deploy demo --rollback) || rc=$?
  [ "$rc" -eq 0 ] || fail "rollback-after-failure: --rollback refused after a failed deploy: $out"
  assert_contains "$out" "$DEPLOYED" "rollback-after-failure"
  assert_grep "checkout --detach '$DEPLOYED'" "$SSH_LOG" \
    "rollback-after-failure: the machine was not returned to the version the failed deploy came from"
  assert_grep "cp -a \"$rollback_root_for_test/$DEPLOYED/bundle\" \"/opt/demo/dashboard/v2/dist\"" "$SSH_LOG" \
    "rollback-after-failure: the front end the previous version ran with was never put back"
  assert_grep '"result":"rolled-back"' "$ledger" \
    "rollback-after-failure: the recovery was not recorded"
  # Undoing the deploy is only half of it: the previous version has to be
  # running and answering when this returns, or the site is still down.
  assert_contains "$out" "is live at $DEPLOYED" "rollback-after-failure"
  assert_grep "systemctl restart 'demo-app'" "$SSH_LOG" \
    "rollback-after-failure: the previous version was put back but never started"
  # A rollback restores a version this machine already served, so it re-runs
  # none of the start-time checks: one that refused would only keep that version
  # off a site that is already down.
  assert_no_grep 'validate_allowed_emails.py' "$SSH_LOG" \
    "rollback-after-failure: a start-time check was re-run for a version that was already live"
  assert_no_grep "'!' -readable" "$SSH_LOG" \
    "rollback-after-failure: the front end this machine already served was re-checked before it could go back"
  pass "--rollback undoes a deploy that failed and ends with the previous version running"
}

test_record_live_catches_the_record_up_without_touching_the_machine() {
  local out rc=0 ledger
  make_case record-live
  # What is live was restored by hand after a failed deploy, so the record and
  # the machine disagree until someone says so.
  out=$(FMTEST_HEALTH=503 run_deploy demo "$PLAIN") || rc=$?
  [ "$rc" -ne 0 ] || fail "record-live: the unhealthy deploy did not fail"
  : > "$SSH_LOG"

  rc=0
  out=$(FMTEST_HOST_SHA="$PLAIN" run_deploy demo "$PLAIN" --record-live \
    --with-captain-permission "deploy all, I fixed it by hand") || rc=$?
  [ "$rc" -eq 0 ] || fail "record-live: recording what is already live failed: $out"
  ledger="$HOME_DIR/state/deploy-ledger/demo.jsonl"
  assert_grep '"result":"recorded-live"' "$ledger" "record-live: nothing was recorded"
  assert_grep "\"to\":\"$PLAIN\"" "$ledger" "record-live: the live version was not recorded"
  if grep -q -E 'systemctl|checkout --detach|cp -a' "$SSH_LOG" 2>/dev/null; then
    fail "record-live: the machine was changed: $(tr '\n' '|' < "$SSH_LOG")"
  fi

  # It asserts what is live, so it refuses when the machine says otherwise.
  rc=0
  out=$(FMTEST_HOST_SHA="$DEPLOYED" run_deploy demo "$PLAIN" --record-live \
    --with-captain-permission "deploy all, I fixed it by hand") || rc=$?
  [ "$rc" -ne 0 ] || fail "record-live: a version the machine does not run was recorded as live"
  assert_contains "$out" "not what is live" "record-live"
  pass "--record-live catches the record up on a hand-restored version, and refuses to record one that is not live"
}

test_a_clean_range_deploys_in_the_documented_order
test_the_completed_deploy_is_recorded
test_the_precheck_runs_before_the_stop_and_only_on_host_owned_files
test_a_bundle_the_service_user_cannot_read_never_restarts
test_a_service_user_check_answers_from_a_directory_it_can_read
test_a_readability_check_that_cannot_answer_says_so
test_rollback_works_after_a_failed_deploy
test_record_live_catches_the_record_up_without_touching_the_machine
test_rollback_targets_the_version_the_last_deploy_came_from
test_an_unhealthy_restart_is_a_failed_deploy_not_a_live_one
test_a_health_probe_that_wins_the_bind_race_on_retry_still_deploys
test_a_health_probe_that_never_answers_fails_within_its_window
