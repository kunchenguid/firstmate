#!/usr/bin/env bash
# tests/fm-worker-memory-cap.test.sh - config/worker-memory-max runs each
# matched ship or scout lane inside a memory-capped systemd user scope and
# records a cgroup OOM kill as that lane's failure.
#
# The spawn cases drive the real bin/fm-spawn.sh against a fake pane, then
# EXECUTE the launch command the pane received under a synthetic pane
# environment, so the assertions describe what the worker actually got. The
# portable cases shadow systemd-run and systemctl with recording stubs; the live
# case uses the host's real systemd user manager and a 100 MiB cap, and skips
# when this host cannot start a user scope.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CAP="$ROOT/bin/fm-worker-memory-cap.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-memory-cap)

# make_case <name> <harness> <id>
make_case() {
  local name=$1 harness=$2 id=$3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  RUN_LOG="$CASE_DIR/systemd-run.log"
  CTL_LOG="$CASE_DIR/systemctl.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    FM_FAKE_SYSTEMD_RUN_LOG="$RUN_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# A systemd-run stand-in: the probe (a bare `true` command) answers with
# FM_FAKE_SYSTEMD_RUN_PROBE_RC, and a launch execs its command after `--`
# exactly as a real --scope launch execs it, inheriting the caller environment.
install_fake_systemd() {
  cat > "$FAKEBIN_DIR/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SYSTEMD_RUN_LOG:-/dev/null}"
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -p) shift 2 ;;
    true) exit "${FM_FAKE_SYSTEMD_RUN_PROBE_RC:-0}" ;;
    *) shift ;;
  esac
done
exec "$@"
SH
  cat > "$FAKEBIN_DIR/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SYSTEMCTL_LOG:-/dev/null}"
case " $* " in
  *" show "*)
    printf 'ActiveState=%s\nResult=%s\n' "${FM_FAKE_SCOPE_STATE:-failed}" "${FM_FAKE_SCOPE_RESULT:-oom-kill}"
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/systemd-run" "$FAKEBIN_DIR/systemctl"
}

# The worker stand-in reports the pane marker it inherited, which is what a
# harness-set identity marker also relies on: the scope must not scrub it.
install_env_probe() {  # <harness>
  cat > "$FAKEBIN_DIR/$1" <<'SH'
#!/bin/sh
printf 'marker=%s\n' "${PANE_MARKER-unset}"
SH
  chmod +x "$FAKEBIN_DIR/$1"
}

run_emitted_launch() {  # [extra env assignments...]
  local launch preamble
  launch=$(cat "$LAUNCH_LOG")
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane PANE_MARKER=pane-value \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
    FM_FAKE_SYSTEMD_RUN_LOG="$RUN_LOG" FM_FAKE_SYSTEMCTL_LOG="$CTL_LOG" \
    "$@" /bin/sh -c "$preamble
$launch"
}

test_resolve_rules() {
  local cfg="$TMP_ROOT/rules" out status
  # A stray file named like a rule token must never be globbed into a rule.
  mkdir -p "$TMP_ROOT/globdir" && : > "$TMP_ROOT/globdir/claude"
  cat > "$cfg" <<'EOF'
# harness project MiB
claude gtm 2560   # specific first
*      gtm 4096
codex  *   3072

*      *   8192
EOF
  out=$(cd "$TMP_ROOT/globdir" && "$CAP" resolve "$cfg" claude gtm)
  assert_equals 2560 "$out" "the first matching rule should win"
  out=$(cd "$TMP_ROOT/globdir" && "$CAP" resolve "$cfg" pi gtm)
  assert_equals 4096 "$out" "a wildcard harness should match any harness for its project"
  out=$("$CAP" resolve "$cfg" codex aio)
  assert_equals 3072 "$out" "a wildcard project should match any project for its harness"
  out=$("$CAP" resolve "$cfg" pi aio)
  assert_equals 8192 "$out" "the catch-all rule should match last"
  printf 'claude gtm 2048\n' > "$cfg"
  out=$("$CAP" resolve "$cfg" pi aio)
  status=$?
  expect_code 0 "$status" "an unmatched lane should resolve cleanly"
  assert_equals '' "$out" "an unmatched lane should run uncapped"
  for bad in 'claude gtm' 'claude gtm 2048 extra' 'claude gtm 0' 'claude gtm 2G' 'claude gtm 0100'; do
    printf '%s\n' "$bad" > "$cfg"
    out=$("$CAP" resolve "$cfg" claude gtm 2>&1)
    status=$?
    expect_code 1 "$status" "malformed rule '$bad' should be refused"
    assert_contains "$out" "line 1" "the refusal should name the malformed line for '$bad'"
  done
  pass "resolve applies first-match rules with wildcards and refuses malformed lines"
}

test_outcome_records_oom_as_lane_failure() {
  local dir="$TMP_ROOT/outcome" status_file out
  mkdir -p "$dir/state" "$dir/config" "$dir/fakebin"
  FAKEBIN_DIR="$dir/fakebin" CTL_LOG="$dir/systemctl.log"
  install_fake_systemd
  status_file="$dir/state/lane-a1.status"
  FM_FAKE_SYSTEMCTL_LOG="$CTL_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CAP" outcome fm-lane-a1-s1.scope 100 "$status_file" "$dir/config"
  out=$(cat "$status_file")
  assert_contains "$out" "failed [at=" "an OOM-killed scope should be recorded as a failed lane"
  assert_contains "$out" "100 MiB" "the failure should name the cap"
  grep -q '^failed \[at=[0-9][0-9]*\]: ' "$status_file" \
    || fail "the failed line should carry a plain epoch stamp: $out"
  assert_contains "$(cat "$CTL_LOG")" "reset-failed fm-lane-a1-s1.scope" \
    "the failed scope unit should be cleared"

  : > "$CTL_LOG"
  rm -f "$status_file"
  FM_FAKE_SCOPE_STATE=inactive FM_FAKE_SCOPE_RESULT=success \
    FM_FAKE_SYSTEMCTL_LOG="$CTL_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CAP" outcome fm-lane-a1-s2.scope 100 "$status_file" "$dir/config"
  [ ! -e "$status_file" ] || fail "a scope that ended normally must not record a failure: $(cat "$status_file")"
  assert_not_contains "$(cat "$CTL_LOG")" "reset-failed" \
    "a scope that ended normally has no failed unit to clear"
  pass "outcome records only a cgroup OOM kill, as the lane's failed status line"
}

test_absent_config_leaves_launch_unwrapped() {
  local out status
  make_case absent codex absent-a1
  install_fake_systemd
  out=$(run_case_spawn absent-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn without a cap file should succeed: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "systemd-run" "no cap file should mean no scope wrapper"
  assert_not_contains "$out" "memory_max=" "no cap should be reported"
  [ ! -s "$RUN_LOG" ] || fail "no cap file should never probe systemd-run: $(cat "$RUN_LOG")"
  pass "an absent config/worker-memory-max leaves the launch unchanged"
}

test_capped_launch_runs_in_scope() {
  local allowlist out status launch seen
  for allowlist in absent enabled; do
    make_case "capped-$allowlist" codex "capped-$allowlist-a1"
    install_fake_systemd
    [ "$allowlist" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    printf 'claude * 999\ncodex project 2560\n' > "$HOME_DIR/config/worker-memory-max"
    out=$(run_case_spawn "capped-$allowlist-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "allowlist=$allowlist: a capped spawn should succeed: $out"
    assert_contains "$out" "memory_max=2560MiB" "allowlist=$allowlist: the spawn line should report the cap"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "-p MemoryMax=2560M -p MemorySwapMax=2560M" \
      "allowlist=$allowlist: the launch should carry the matched cap for memory and swap"
    : > "$RUN_LOG"
    [ "$allowlist" = absent ] || printf 'PANE_MARKER\n' > "$HOME_DIR/config/launch-env-allowlist"
    install_env_probe codex
    seen=$(run_emitted_launch FM_FAKE_SCOPE_STATE=inactive FM_FAKE_SCOPE_RESULT=success) \
      || fail "allowlist=$allowlist: the emitted launch failed to run"
    grep -q -- "--scope" "$RUN_LOG" \
      || fail "allowlist=$allowlist: the worker should have been started through systemd-run --scope"
    if [ "$allowlist" = absent ]; then
      assert_equals marker=pane-value "$seen" \
        "the worker should inherit the pane environment through the scope"
    else
      assert_contains "$seen" marker= "allowlist=$allowlist: the worker should still start inside the scope"
    fi
    [ ! -e "$HOME_DIR/state/capped-$allowlist-a1.status" ] ||
      ! grep -q '^failed' "$HOME_DIR/state/capped-$allowlist-a1.status" ||
      fail "allowlist=$allowlist: a normal worker exit must not be recorded as a failure"
  done
  pass "a matched cap launches the worker inside a MemoryMax/MemorySwapMax scope with its environment intact"
}

test_refusals_happen_before_any_record() {
  local out status
  make_case malformed codex malformed-a1
  install_fake_systemd
  printf 'codex project lots\n' > "$HOME_DIR/config/worker-memory-max"
  out=$(run_case_spawn malformed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a malformed cap file should refuse the spawn: $out"
  assert_contains "$out" "worker-memory-max" "the refusal should name the file"
  [ ! -e "$HOME_DIR/state/malformed-a1.meta" ] || fail "a malformed cap file must refuse before any task record exists"
  [ ! -s "$LAUNCH_LOG" ] || fail "a malformed cap file must refuse before any launch is sent"

  make_case noscope codex noscope-a1
  install_fake_systemd
  printf '* * 2048\n' > "$HOME_DIR/config/worker-memory-max"
  out=$(FM_FAKE_SYSTEMD_RUN_PROBE_RC=1 run_case_spawn noscope-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a host that cannot start the scope should refuse a capped spawn: $out"
  assert_contains "$out" "systemd-run --user --scope" "the refusal should name the missing capability"
  [ ! -e "$HOME_DIR/state/noscope-a1.meta" ] || fail "a failed probe must refuse before any task record exists"

  make_case unmatched codex unmatched-a1
  install_fake_systemd
  printf 'claude * 2048\n' > "$HOME_DIR/config/worker-memory-max"
  out=$(FM_FAKE_SYSTEMD_RUN_PROBE_RC=1 run_case_spawn unmatched-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a lane no rule matches should launch uncapped without probing: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "systemd-run" "an unmatched lane should not be wrapped"
  pass "a malformed cap file or an unusable scope refuses before any record, and unmatched lanes run uncapped"
}

test_secondmate_is_never_capped() {
  local sm out status
  make_case secondmate codex sm-a1
  install_fake_systemd
  printf '* * 2048\n' > "$HOME_DIR/config/worker-memory-max"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf 'sm-a1\n' > "$sm/.fm-secondmate-home"
  printf 'charter for sm-a1\n' > "$sm/data/charter.md"
  out=$(run_case_spawn sm-a1 "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "systemd-run" "a secondmate must never be placed in a lane scope"
  pass "a secondmate launch is never memory-capped"
}

# Live: a real 100 MiB scope around a worker that tries to hold 400 MiB. The
# kernel OOM-kills it inside the scope, the pane shell survives, and the lane's
# status log gains the failure line.
test_live_oom_is_a_lane_failure() {
  local status_file seen
  if ! command -v systemd-run >/dev/null 2>&1 ||
    ! systemd-run --user --scope --quiet -p MemoryMax=64M -p MemorySwapMax=64M true >/dev/null 2>&1; then
    echo "skip: live OOM case needs a reachable systemd user manager (systemd-run --user --scope)"
    return 0
  fi
  command -v perl >/dev/null 2>&1 || { echo "skip: live OOM case needs perl"; return 0; }
  make_case live codex live-a1
  printf 'codex * 100\n' > "$HOME_DIR/config/worker-memory-max"
  run_case_spawn live-a1 "$PROJ_DIR" --mode no-mistakes --yolo off >/dev/null ||
    fail "live: the capped spawn should succeed"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
exec perl -e '$x = "a" x (400 * 1024 * 1024); print "survived\n"'
SH
  chmod +x "$FAKEBIN_DIR/codex"
  seen=$(run_emitted_launch 2>&1)
  assert_not_contains "$seen" survived "live: the worker must not outgrow its 100 MiB cap"
  status_file="$HOME_DIR/state/live-a1.status"
  [ -f "$status_file" ] || fail "live: the OOM kill should have been recorded in the lane's status log"
  grep -q '^failed \[at=[0-9][0-9]*\]: worker memory cap of 100 MiB exceeded' "$status_file" \
    || fail "live: the lane should be recorded as failed on its cap: $(cat "$status_file")"
  pass "live: a worker over a 100 MiB cap dies to the cgroup OOM killer and is recorded as a lane failure"
}

test_resolve_rules
test_outcome_records_oom_as_lane_failure
test_absent_config_leaves_launch_unwrapped
test_capped_launch_runs_in_scope
test_refusals_happen_before_any_record
test_secondmate_is_never_capped
test_live_oom_is_a_lane_failure
