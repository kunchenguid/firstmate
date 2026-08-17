#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
#
# The fake controller fleet is exactly one `default` session plus whichever lab
# session a case provisions, so every ambient protection authority is dropped
# here at the fixture boundary: bin/fm-ci.sh exports the dedicated Water 7
# controller into the whole suite, and a Herdr-launched developer shell carries
# its own endpoint markers. Each case supplies its own authority explicitly.
set -u
unset FM_HERDR_LAB_PROTECTED_SESSION FM_HERDR_LAB_TASK_ID FM_HERDR_LAB_TASK_STATE_DIR FM_HERDR_LAB_STATE_DIR
unset FM_HOME FM_STATE_OVERRIDE
unset HERDR_ENV HERDR_SESSION HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_SOCKET_PATH

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
mkdir -p "$FAKE_STATE"
printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
last=
for arg in "$@"; do
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing trailing --session" >&2; exit 90; }
session=$last
default_socket=$(cat "$state/default-socket")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    if [ -f "$state/session-fixture.json" ]; then
      sessions=$(jq -c '.sessions' "$state/session-fixture.json")
    else
      sessions=$(jq -nc --arg socket "$default_socket" \
        '[{default:true,name:"default",running:true,socket_path:$socket}]')
    fi
    if [ "$lab_state" != absent ] && [ "$lab_state" != deleted ]; then
      running=false
      [ "$lab_state" = running ] && running=true
      sessions=$(printf '%s' "$sessions" | jq -c --arg name "$session" --argjson running "$running" \
        '. + [{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]')
    fi
    jq -nc --argjson sessions "$sessions" '{sessions:$sessions}'
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    # A real controller has no obligation to succeed at stopping a session that
    # is already stopped, so the fake refuses it and teardown must not depend
    # on that redundant call.
    [ "$lab_state" = running ] || exit 94
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

write_task_meta() { # <home> <task> [backend] [session] [window]
  local home=$1 task=$2 backend=${3:-herdr} session=${4:-fm-remote} window=${5:-fm-remote:w8:p2}
  mkdir -p "$home/state"
  cat > "$home/state/$task.meta" <<EOF
window=$window
endpoint_task_id=$task
worktree=$home/worktree
project=$home/project
backend=$backend
herdr_session=$session
herdr_workspace_id=w8
herdr_tab_id=w8:t2
herdr_pane_id=w8:p2
EOF
}

run_with_recorded_controller() { # <home> <task> <command...>
  local home=$1 task=$2
  shift 2
  FM_HOME="$home" \
    FM_HERDR_LAB_TASK_ID="$task" \
    HERDR_ENV=0 \
    HERDR_SESSION=ambient-must-not-authorize \
    HERDR_WORKSPACE_ID=ambient-workspace \
    HERDR_TAB_ID=ambient-tab \
    HERDR_PANE_ID=ambient-pane \
    run_with_fake "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_recorded_named_controller_is_authoritative_and_fail_closed() {
  local home task name tripwire protected status=0 before after
  home="$TMP_ROOT/recorded-controller-home"
  task='remote-task'
  name="fm-lab-recorded-$$"
  write_task_meta "$home" "$task"
  jq -n '{sessions:[
    {default:true,name:"default",running:false,socket_path:"/tmp/default.sock"},
    {default:false,name:"fm-remote",running:true,socket_path:"/tmp/fm-remote.sock"}
  ]}' > "$FAKE_STATE/session-fixture.json"
  : > "$FAKE_LOG"

  protected=$(FM_HOME='' FM_STATE_OVERRIDE='' \
    FM_HERDR_LAB_TASK_STATE_DIR="$home/state" \
    FM_HERDR_LAB_TASK_ID="$task" \
    HERDR_SESSION=ambient-must-not-authorize \
    run_with_fake fm_herdr_lab_protected_session) \
    || fail "explicit task-state authority failed without an ambient home"
  [ "$protected" = fm-remote ] \
    || fail "explicit task-state authority selected the wrong controller: $protected"

  run_with_recorded_controller "$home" "$task" fm_herdr_lab_provision "$name" \
    || fail "authoritative recorded controller did not permit isolated provisioning"
  tripwire="$TRIPWIRES/$name.fleet-state.json"
  jq -e '. == {
    name:"fm-remote", default:false, running:true,
    socket_path:"/tmp/fm-remote.sock"
  }' "$tripwire" >/dev/null || fail "tripwire did not bind the recorded controller state"

  before=$(grep -c "^session stop $name " "$FAKE_LOG" || true)
  write_task_meta "$home" "$task" herdr fm-changed fm-changed:w8:p2
  run_with_recorded_controller "$home" "$task" fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed recorded controller must refuse stop"
  after=$(grep -c "^session stop $name " "$FAKE_LOG" || true)
  [ "$before" = "$after" ] || fail "changed recorded identity reached destructive stop"

  write_task_meta "$home" "$task"
  run_with_recorded_controller "$home" "$task" fm_herdr_lab_teardown "$name" \
    || fail "restored authoritative controller could not tear down the owned lab"
  assert_absent "$tripwire" "recorded-controller teardown left its tripwire behind"
  if grep -E '^session (stop|delete) fm-remote ' "$FAKE_LOG" >/dev/null; then
    fail "recorded protected controller was targeted by a destructive call"
  fi

  rm -f "$FAKE_STATE/session-fixture.json"
  pass "fm-herdr-lab: authoritative named controller is exact, protected, and fail-closed"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_teardown_is_idempotent_for_a_stopped_owned_lab() {
  local name="fm-lab-stopped-teardown-$$" stops
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "stopped-teardown fixture provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded mid-run stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_teardown "$name" \
    || fail "teardown aborted on an owned lab that was already stopped"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the stopped lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown of a stopped owned lab left its tripwire behind"
  stops=$(grep -c "^session stop $name " "$FAKE_LOG" || true)
  [ "$stops" = 0 ] || fail "teardown re-issued a redundant stop against an already-stopped lab"
  pass "fm-herdr-lab: teardown of an already-stopped owned lab is idempotent and still deletes it"
}

test_explicit_named_controller_protects_a_host_without_a_default() {
  local name="fm-lab-named-controller-$$" tripwire status=0
  jq -n '{sessions:[
    {default:false,name:"fm-ci-water7",running:true,socket_path:"/tmp/fm-ci-water7.sock"}
  ]}' > "$FAKE_STATE/session-fixture.json"
  : > "$FAKE_LOG"

  FM_HERDR_LAB_PROTECTED_SESSION=fm-ci-water7 \
    run_with_fake fm_herdr_lab_provision "$name" \
    || fail "an explicitly named controller did not permit isolated provisioning"
  tripwire="$TRIPWIRES/$name.fleet-state.json"
  jq -e '. == {
    name:"fm-ci-water7", default:false, running:true,
    socket_path:"/tmp/fm-ci-water7.sock"
  }' "$tripwire" >/dev/null || fail "tripwire did not bind the explicitly named controller state"

  run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "the default-controller fallback must not adopt a lab owned by a named controller"

  status=0
  FM_HERDR_LAB_PROTECTED_SESSION=fm-lab-pretend \
    run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a lab-prefixed protected controller must be refused"

  FM_HERDR_LAB_PROTECTED_SESSION=fm-ci-water7 \
    run_with_fake fm_herdr_lab_teardown "$name" \
    || fail "teardown under the explicitly named controller failed"
  assert_absent "$tripwire" "named-controller teardown left its tripwire behind"
  if grep -E '^session (stop|delete) fm-ci-water7 ' "$FAKE_LOG" >/dev/null; then
    fail "the explicitly named protected controller was targeted by a destructive call"
  fi

  rm -f "$FAKE_STATE/session-fixture.json"
  pass "fm-herdr-lab: an explicitly named non-default controller is protected on a host with no default session"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_recorded_named_controller_is_authoritative_and_fail_closed
test_stopped_owned_lab_can_reprovision
test_teardown_is_idempotent_for_a_stopped_owned_lab
test_explicit_named_controller_protects_a_host_without_a_default
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
