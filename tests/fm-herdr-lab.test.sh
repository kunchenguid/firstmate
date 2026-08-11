#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot_into TMP_ROOT fm-herdr-lab
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
mkdir -p "$FAKE_STATE"
printf '%s\n' '/Users/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
printf '%s\n' captain crewmate-1 crewmate-2 > "$FAKE_STATE/default-agents"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
session=
previous=
before_separator=1
for arg in "$@"; do
  if [ "$arg" = -- ]; then
    before_separator=0
    previous=
    continue
  fi
  [ "$before_separator" = 1 ] || continue
  if [ "$previous" = --session ]; then
    [ -z "$session" ] || { echo "fake herdr: duplicate --session" >&2; exit 90; }
    session=$arg
  fi
  previous=$arg
done
[ -n "$session" ] || { echo "fake herdr: missing --session" >&2; exit 90; }
default_socket=$(cat "$state/default-socket")
default_running=${FM_FAKE_HERDR_DEFAULT_RUNNING:-true}
default_activity=$(cat "$state/default-activity" 2>/dev/null || printf '0\n')
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc --arg socket "$default_socket" --argjson default_running "$default_running" \
        '{sessions:[{default:true,name:"default",running:$default_running,socket_path:$socket}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg socket "$default_socket" --arg name "$session" --argjson running "$running" \
        --argjson default_running "$default_running" \
        '{sessions:[{default:true,name:"default",running:$default_running,socket_path:$socket},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"t1","label":"fleet"}]}}'
    ;;
  "pane list")
    jq -Rsc --argjson activity "$default_activity" \
      '{result:{panes:(split("\n")[:-1] | map({workspace_id:"w1",tab_id:"t1",pane_id:.,revision:$activity,scroll:{max_offset_from_bottom:$activity}}))}}' \
      "$state/default-agents"
    ;;
  "agent list")
    jq -Rsc '{result:{agents:(split("\n")[:-1] | map({pane_id:.,name:.,agent_session:{value:(. + "-session")},agent_status:"idle"}))}}' \
      "$state/default-agents"
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

# shellcheck source=bin/fm-herdr-lab.sh
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_FAKE_HERDR_DEFAULT_RUNNING="${FM_FAKE_HERDR_DEFAULT_RUNNING:-true}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name suite-fm-backend-herdr-respawn-idem-e2e)
  [ "${#generated}" -le 43 ] || fail "generated lab name can exceed its Unix-socket-safe bound: $generated"
  case "$generated" in
    fm-lab-suite-fm-backend-herdr-r-*) ;;
    *) fail "generated lab name lost its bounded readable prefix: $generated" ;;
  esac
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_timeout_is_bounded() {
  local status=0
  [ "$(FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS=1 fm_herdr_lab_provision_timeout)" = 1 ] \
    || fail "minimum provision timeout was refused"
  [ "$(FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS=600 fm_herdr_lab_provision_timeout)" = 600 ] \
    || fail "maximum provision timeout was refused"
  FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS=0 fm_herdr_lab_provision_timeout >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "zero provision timeout"
  status=0
  FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS=601 fm_herdr_lab_provision_timeout >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "oversized provision timeout"
  pass "fm-herdr-lab: provision timeout is configurable only within a bounded range"
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
      "workspace list --session default"|"tab list --session default"|\
      "pane list --session default"|"agent list --session default") : ;;
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

test_agent_argv_inserts_session_before_separator() {
  local name="fm-lab-agent-argv-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "agent-argv fixture provision failed"
  run_with_fake fm_herdr_lab_cli_argv "$name" \
    agent start fm-probe --tab t1 -- echo hello >/dev/null \
    || fail "guarded agent-start argv call failed"
  grep -Fx "agent start fm-probe --tab t1 --session $name -- echo hello" "$FAKE_LOG" >/dev/null \
    || fail "agent-start session selector was not inserted before the argv separator"
  run_with_fake fm_herdr_lab_cli_argv "$name" \
    agent start fm-probe --tab t1 -- echo --session default >/dev/null \
    || fail "agent argv containing its own --session flag was refused"
  grep -Fx "agent start fm-probe --tab t1 --session $name -- echo --session default" "$FAKE_LOG" >/dev/null \
    || fail "agent argv was rewritten while inserting the Herdr session selector"
  run_with_fake fm_herdr_lab_cli_argv "$name" \
    agent start fm-probe --session default -- echo hello >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "agent-start caller session selector"
  status=0
  run_with_fake fm_herdr_lab_cli_argv "$name" \
    pane run p1 -- echo hello >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "run-argv non-agent command"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "agent-argv fixture teardown failed"
  pass "fm-herdr-lab: agent argv routing inserts only the owned session before --"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/Users/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_changed_default_fleet_members_trip_after_teardown() {
  local name="fm-lab-tripwire-members-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "fleet-member tripwire fixture provision failed"
  printf '%s\n' captain > "$FAKE_STATE/default-agents"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "lost default fleet members must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "fleet-member tripwire failure should retain evidence"
  printf '%s\n' captain crewmate-1 crewmate-2 > "$FAKE_STATE/default-agents"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: default pane and agent deaths trip the fleet-state guard"
}

test_default_runtime_activity_does_not_trip() {
  local name="fm-lab-tripwire-activity-$$"
  : > "$FAKE_LOG"
  printf '0\n' > "$FAKE_STATE/default-activity"
  run_with_fake fm_herdr_lab_provision "$name" || fail "runtime-activity tripwire fixture provision failed"
  printf '1\n' > "$FAKE_STATE/default-activity"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "transient default runtime activity tripped teardown"
  rm -f "$FAKE_STATE/default-activity"
  pass "fm-herdr-lab: transient default runtime activity does not change fleet identity"
}

test_stopped_default_refuses_provision() {
  local name="fm-lab-stopped-default-$$" status=0
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_DEFAULT_RUNNING=false run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a stopped default session must refuse provisioning"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "refused provisioning still recorded a fleet-state tripwire"
  assert_absent "$FAKE_STATE/$name" "refused provisioning still launched the lab session"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision with a running default session failed"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after the running-default provision failed"
  pass "fm-herdr-lab: provisioning requires a proven-running default session"
}

test_malformed_default_running_refuses_provision() {
  local name="fm-lab-malformed-default-$$" status=0
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_DEFAULT_RUNNING='"true"' run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a string-valued default running state must refuse provisioning"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "malformed running state still recorded a fleet-state tripwire"
  assert_absent "$FAKE_STATE/$name" "malformed running state still launched the lab session"
  if grep -F "server --session" "$FAKE_LOG" >/dev/null; then
    fail "malformed running state reached the lab server launch"
  fi
  pass "fm-herdr-lab: default running proof requires the JSON Boolean true"
}

test_stopped_default_blocks_destructive_boundaries() {
  local name="fm-lab-default-stops-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "running-default fixture provision failed"
  FM_FAKE_HERDR_DEFAULT_RUNNING=false run_with_fake fm_herdr_lab_cli "$name" workspace close main >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a mutating run command with a stopped default session must refuse"
  FM_FAKE_HERDR_DEFAULT_RUNNING=false run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null \
    || fail "a read-only run command was blocked by the stopped default session"
  status=0
  FM_FAKE_HERDR_DEFAULT_RUNNING=false run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "guarded stop with a stopped default session must refuse"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "refused stop still reached the lab session"
  status=0
  FM_FAKE_HERDR_DEFAULT_RUNNING=false run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "teardown with a stopped default session must refuse"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "refused teardown still reached the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "refused teardown removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after the default session resumed failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "teardown after resume left its tripwire behind"
  pass "fm-herdr-lab: destructive lab boundaries re-prove the running default session"
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
  FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS=1 \
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
test_provision_timeout_is_bounded
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_agent_argv_inserts_session_before_separator
test_changed_default_trips_after_teardown
test_changed_default_fleet_members_trip_after_teardown
test_default_runtime_activity_does_not_trip
test_stopped_default_refuses_provision
test_malformed_default_running_refuses_provision
test_stopped_default_blocks_destructive_boundaries
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
