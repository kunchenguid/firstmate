#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
mkdir -p "$FAKE_STATE"
printf '%s\n' '/Users/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
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
default_present=${FM_FAKE_HERDR_DEFAULT_PRESENT:-1}
default_running=${FM_FAKE_HERDR_DEFAULT_RUNNING:-true}
lab_socket=${FM_FAKE_HERDR_LAB_SOCKET:-/tmp/$session.sock}
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")
visible_lab_state=$lab_state
case "$1 ${2:-}:$lab_state" in
  "session list:deleting:"*)
    remaining=${lab_state#deleting:}
    if [ "$remaining" -gt 0 ]; then
      printf 'deleting:%s\n' "$((remaining - 1))" > "$state/$session"
      visible_lab_state=stopped
    else
      printf '%s\n' deleted > "$state/$session"
      visible_lab_state=deleted
    fi
    ;;
esac

case "$1 ${2:-}" in
  "session list")
    if [ -n "${FM_FAKE_HERDR_SESSION_LIST_JSON:-}" ]; then
      printf '%s\n' "$FM_FAKE_HERDR_SESSION_LIST_JSON"
      exit 0
    fi
    if [ "$visible_lab_state" = absent ] || [ "$visible_lab_state" = deleted ]; then
      if [ "$default_present" = 1 ]; then
        jq -nc --arg socket "$default_socket" --argjson running "$default_running" \
          '{sessions:[{default:true,name:"default",running:$running,socket_path:$socket}]}'
      else
        printf '%s\n' '{"sessions":[]}'
      fi
    else
      running=false
      if [ "$visible_lab_state" = running ] || [ "$visible_lab_state" = foreign-running ]; then
        running=true
      fi
      lab_default=false
      [ "${FM_FAKE_HERDR_LAB_DEFAULT:-0}" != 1 ] || lab_default=true
      if [ "$visible_lab_state" = foreign-running ]; then
        lab_socket="/tmp/$session.foreign.sock"
      fi
      if [ "$visible_lab_state" = stopped ] && [ "${FM_FAKE_HERDR_MUTATE_LAB_AFTER_STOP:-0}" = 1 ]; then
        lab_socket="/tmp/$session.changed.sock"
      fi
      if [ "$default_present" = 1 ]; then
        jq -nc --arg socket "$default_socket" --arg lab_socket "$lab_socket" --arg name "$session" --argjson running "$running" --argjson default_running "$default_running" --argjson lab_default "$lab_default" \
          '{sessions:[{default:true,name:"default",running:$default_running,socket_path:$socket},{default:$lab_default,name:$name,running:$running,socket_path:$lab_socket}]} '
      else
        jq -nc --arg lab_socket "$lab_socket" --arg name "$session" --argjson running "$running" --argjson lab_default "$lab_default" \
          '{sessions:[{default:$lab_default,name:$name,running:$running,socket_path:$lab_socket}]} '
      fi
    fi
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_COLLISION:-0}" = 1 ]; then
      printf '%s\n' foreign-running > "$state/$session"
      exit 94
    fi
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    while [ -f "$state/$session" ] && [ "$(cat "$state/$session")" = running ]; do
      "$FM_FAKE_HERDR_REAL_SLEEP" 0.05
    done
    ;;
  "status --json")
    if [ "${FM_FAKE_HERDR_MUTATE_DEFAULT_ON_STATUS:-0}" = 1 ]; then
      printf '%s\n' '/tmp/mutated-default.sock' > "$state/default-socket"
    fi
    if [ "$lab_state" = running ] || [ "$lab_state" = foreign-running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    if [ "${FM_FAKE_HERDR_COLLAPSE_ON_STOP:-0}" = 1 ]; then
      printf '%s\n' deleted > "$state/$session"
    else
      printf '%s\n' stopped > "$state/$session"
    fi
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    if [ "${FM_FAKE_HERDR_DELETE_LAG_LISTS:-0}" -gt 0 ]; then
      printf 'deleting:%s\n' "$FM_FAKE_HERDR_DELETE_LAG_LISTS" > "$state/$session"
    else
      printf '%s\n' deleted > "$state/$session"
    fi
    [ "${FM_FAKE_HERDR_DELETE_EXIT:-0}" = 0 ] || exit "$FM_FAKE_HERDR_DELETE_EXIT"
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
    FM_FAKE_HERDR_SERVER_COLLISION="${FM_FAKE_HERDR_SERVER_COLLISION:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_FAKE_HERDR_DELETE_LAG_LISTS="${FM_FAKE_HERDR_DELETE_LAG_LISTS:-0}" \
    FM_FAKE_HERDR_DELETE_EXIT="${FM_FAKE_HERDR_DELETE_EXIT:-0}" \
    FM_FAKE_HERDR_COLLAPSE_ON_STOP="${FM_FAKE_HERDR_COLLAPSE_ON_STOP:-0}" \
    FM_FAKE_HERDR_LAB_DEFAULT="${FM_FAKE_HERDR_LAB_DEFAULT:-0}" \
    FM_FAKE_HERDR_LAB_SOCKET="${FM_FAKE_HERDR_LAB_SOCKET:-}" \
    FM_FAKE_HERDR_MUTATE_LAB_AFTER_STOP="${FM_FAKE_HERDR_MUTATE_LAB_AFTER_STOP:-0}" \
    FM_FAKE_HERDR_MUTATE_DEFAULT_ON_STATUS="${FM_FAKE_HERDR_MUTATE_DEFAULT_ON_STATUS:-0}" \
    FM_FAKE_HERDR_DEFAULT_PRESENT="${FM_FAKE_HERDR_DEFAULT_PRESENT:-1}" \
    FM_FAKE_HERDR_DEFAULT_RUNNING="${FM_FAKE_HERDR_DEFAULT_RUNNING:-true}" \
    FM_FAKE_HERDR_SESSION_LIST_JSON="${FM_FAKE_HERDR_SESSION_LIST_JSON:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
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
  printf '%s\n' '/Users/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_absent_default_fleet_state_is_preserved() {
  local name="fm-lab-no-default-$$" transition_name="fm-lab-default-appeared-$$"
  local disappearance_name="fm-lab-default-disappeared-$$" invalid_name="fm-lab-invalid-default-$$" status=0
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_DEFAULT_PRESENT=0 run_with_fake fm_herdr_lab_provision "$name" \
    || fail "clean-runner provision required a pre-existing default session"
  [ "$(cat "$TRIPWIRES/$name.fleet-state.json")" = '{"baseline":{"sessions":[]},"owned_session":{"default":false,"name":"'$name'","socket_path":"/tmp/'$name'.sock"}}' ] \
    || fail "clean-runner tripwire did not record default-session absence"
  FM_FAKE_HERDR_DEFAULT_PRESENT=0 run_with_fake fm_herdr_lab_teardown "$name" \
    || fail "clean-runner teardown did not preserve default-session absence"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "clean-runner teardown retained the verified tripwire"
  assert_no_grep "session stop default" "$FAKE_LOG" "clean-runner lifecycle targeted the default session"
  assert_no_grep "session delete default" "$FAKE_LOG" "clean-runner lifecycle targeted the default session"

  FM_FAKE_HERDR_DEFAULT_PRESENT=0 run_with_fake fm_herdr_lab_provision "$transition_name" \
    || fail "default-transition fixture provision failed"
  FM_FAKE_HERDR_DEFAULT_PRESENT=1 run_with_fake fm_herdr_lab_teardown "$transition_name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an appearing default session must fail the exact-state tripwire"
  assert_present "$TRIPWIRES/$transition_name.fleet-state.json" \
    "default-state transition discarded tripwire evidence"
  FM_FAKE_HERDR_DEFAULT_PRESENT=0 run_with_fake fm_herdr_lab_teardown "$transition_name" \
    || fail "default-transition fixture cleanup failed"

  run_with_fake fm_herdr_lab_provision "$disappearance_name" \
    || fail "default-disappearance fixture provision failed"
  status=0
  FM_FAKE_HERDR_DEFAULT_PRESENT=0 run_with_fake fm_herdr_lab_teardown "$disappearance_name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a disappearing default session must fail the exact-state tripwire"
  assert_present "$TRIPWIRES/$disappearance_name.fleet-state.json" \
    "default disappearance discarded tripwire evidence"
  run_with_fake fm_herdr_lab_teardown "$disappearance_name" \
    || fail "default-disappearance fixture cleanup failed"

  status=0
  FM_FAKE_HERDR_DEFAULT_RUNNING=false run_with_fake fm_herdr_lab_provision "$invalid_name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a stopped default session must remain an invalid initial fleet state"
  assert_absent "$TRIPWIRES/$invalid_name.fleet-state.json" \
    "invalid initial default state retained an ownership tripwire"
  pass "fm-herdr-lab: absent default state is preserved and transitions fail closed"
}

test_malformed_session_inventories_fail_closed() {
  local inventory name owned_name="fm-lab-malformed-owned-$$" index=0 status
  for inventory in \
    '{}' \
    '[]' \
    '{"sessions":null}' \
    '{"sessions":{}}' \
    '{"sessions":[null]}' \
    '{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/default.sock"}]}' \
    '{"sessions":[{"name":"default","default":"true","running":true,"socket_path":"/tmp/default.sock"}]}' \
    '{"sessions":[{"name":"default","default":true,"running":"true","socket_path":"/tmp/default.sock"}]}' \
    '{"sessions":[{"name":"default","default":true,"running":true,"socket_path":null}]}' \
    '{"sessions":[{"name":"dup","default":false,"running":true,"socket_path":"/tmp/a"},{"name":"dup","default":false,"running":true,"socket_path":"/tmp/b"}]}' \
    $'{"sessions":[]}\n{"sessions":[]}'
  do
    index=$((index + 1))
    name="fm-lab-malformed-$index-$$"
    status=0
    FM_FAKE_HERDR_SESSION_LIST_JSON="$inventory" run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "malformed session inventory must fail before provisioning"
    assert_absent "$TRIPWIRES/$name.fleet-state.json" "malformed inventory created a tripwire"
    assert_absent "$FAKE_STATE/$name" "malformed inventory started a lab session"
    assert_no_grep "server --session $name" "$FAKE_LOG" "malformed inventory reached server provisioning"
  done

  run_with_fake fm_herdr_lab_provision "$owned_name" || fail "malformed teardown fixture provision failed"
  : > "$FAKE_LOG"
  status=0
  FM_FAKE_HERDR_SESSION_LIST_JSON='{}' run_with_fake fm_herdr_lab_teardown "$owned_name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "malformed teardown inventory must fail closed"
  assert_no_grep "session stop $owned_name" "$FAKE_LOG" "malformed inventory allowed session stop"
  assert_no_grep "session delete $owned_name" "$FAKE_LOG" "malformed inventory allowed session delete"
  assert_present "$TRIPWIRES/$owned_name.fleet-state.json" "malformed teardown discarded tripwire evidence"
  run_with_fake fm_herdr_lab_teardown "$owned_name" || fail "malformed teardown fixture cleanup failed"
  pass "fm-herdr-lab: malformed inventories fail before provisioning or destruction"
}

test_ambiguous_initial_and_owned_inventories_fail_closed() {
  local name="fm-lab-ambiguous-initial-$$" owned_name="fm-lab-foreign-owned-$$" inventory status=0
  for inventory in \
    '{"sessions":[{"name":"foreign","default":false,"running":true,"socket_path":"/tmp/foreign.sock"}]}' \
    '{"sessions":[{"name":"default","default":false,"running":true,"socket_path":"/tmp/default.sock"}]}' \
    '{"sessions":[{"name":"default","default":true,"running":true,"socket_path":"/tmp/default.sock"},{"name":"foreign","default":false,"running":true,"socket_path":"/tmp/foreign.sock"}]}'
  do
    status=0
    FM_FAKE_HERDR_SESSION_LIST_JSON="$inventory" run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "ambiguous initial inventory must fail before provisioning"
    assert_absent "$TRIPWIRES/$name.fleet-state.json" "ambiguous initial inventory created a tripwire"
    assert_absent "$FAKE_STATE/$name" "ambiguous initial inventory started a lab session"
  done

  run_with_fake fm_herdr_lab_provision "$owned_name" || fail "foreign-owned fixture provision failed"
  inventory=$(jq -nc --arg name "$owned_name" '{sessions:[
    {name:"default",default:true,running:true,socket_path:"/Users/test/.config/herdr/herdr.sock"},
    {name:$name,default:false,running:true,socket_path:("/tmp/" + $name + ".sock")},
    {name:"foreign",default:false,running:true,socket_path:"/tmp/foreign.sock"}
  ]}')
  : > "$FAKE_LOG"
  status=0
  FM_FAKE_HERDR_SESSION_LIST_JSON="$inventory" run_with_fake fm_herdr_lab_teardown "$owned_name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "foreign session during lab ownership must fail closed"
  assert_no_grep "session stop $owned_name" "$FAKE_LOG" "foreign inventory allowed session stop"
  assert_no_grep "session delete $owned_name" "$FAKE_LOG" "foreign inventory allowed session delete"
  assert_present "$TRIPWIRES/$owned_name.fleet-state.json" "foreign inventory discarded tripwire evidence"
  run_with_fake fm_herdr_lab_teardown "$owned_name" || fail "foreign-owned fixture cleanup failed"
  pass "fm-herdr-lab: initial and owned inventories reject foreign or contradictory sessions"
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

test_delayed_delete_converges_in_one_teardown() {
  local name="fm-lab-delayed-delete-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delayed-delete fixture provision failed"
  FM_FAKE_HERDR_DELETE_LAG_LISTS=2 FM_FAKE_HERDR_DELETE_EXIT=93 \
    run_with_fake fm_herdr_lab_teardown "$name" \
    || fail "teardown did not wait for an asynchronously disappearing lab session"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "delayed deletion never reached absent state"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "successful delayed deletion left the ownership tripwire behind"
  pass "fm-herdr-lab: delayed deletion converges in one guarded teardown even when delete exits nonzero"
}

test_stop_auto_collapse_is_idempotent() {
  local name="fm-lab-stop-collapse-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "stop-collapse fixture provision failed"
  FM_FAKE_HERDR_COLLAPSE_ON_STOP=1 run_with_fake fm_herdr_lab_teardown "$name" \
    || fail "teardown rejected a lab session that safely disappeared during guarded stop"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "stop-collapse teardown left the ownership tripwire behind"
  assert_no_grep "session delete $name" "$FAKE_LOG" \
    "teardown attempted delete after guarded stop had already removed the lab session"
  pass "fm-herdr-lab: disappearance during guarded stop is an idempotent successful teardown"
}

test_default_flag_still_blocks_teardown() {
  local name="fm-lab-default-flag-$$" status=0
  run_with_fake fm_herdr_lab_provision "$name" || fail "default-guard fixture provision failed"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_LAB_DEFAULT=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a lab-named session reported as default must block teardown"
  assert_no_grep "session stop $name" "$FAKE_LOG" "default-flag guard allowed session stop"
  assert_no_grep "session delete $name" "$FAKE_LOG" "default-flag guard allowed session delete"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "default-flag refusal removed ownership evidence"
  printf '%s\n' deleted > "$FAKE_STATE/$name"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "default-guard fixture cleanup failed"
  pass "fm-herdr-lab: default-session protection remains fail-closed"
}

test_same_name_foreign_session_is_never_adopted() {
  local name="fm-lab-same-name-foreign-$$" status=0
  run_with_fake fm_herdr_lab_prepare "$name" || fail "same-name fixture prepare failed"
  printf '%s\n' stopped > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "same-name foreign session must not be adopted"
  assert_no_grep "server --session $name" "$FAKE_LOG" "same-name foreign session reached server provisioning"
  assert_no_grep "session stop $name" "$FAKE_LOG" "same-name foreign session reached stop"
  assert_no_grep "session delete $name" "$FAKE_LOG" "same-name foreign session reached delete"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "same-name ownership refusal discarded evidence"
  printf '%s\n' deleted > "$FAKE_STATE/$name"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "same-name fixture evidence cleanup failed"
  pass "fm-herdr-lab: a same-name foreign session is never adopted"
}

test_launch_collision_cannot_capture_foreign_identity() {
  local name="fm-lab-launch-collision-$$" status=0 state
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_SERVER_COLLISION=1 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "launch collision must fail provisioning"
  state=$(cat "$TRIPWIRES/$name.fleet-state.json")
  [ "$(printf '%s' "$state" | jq -r '.owned_session')" = null ] \
    || fail "launch collision captured a foreign identity"
  status=0
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "foreign collision session must remain unowned"
  assert_no_grep "session stop $name" "$FAKE_LOG" "launch collision reached stop"
  assert_no_grep "session delete $name" "$FAKE_LOG" "launch collision reached delete"
  printf '%s\n' deleted > "$FAKE_STATE/$name"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "launch-collision evidence cleanup failed"
  pass "fm-herdr-lab: launch collision cannot capture foreign ownership"
}

test_changed_owned_identity_blocks_lifecycle() {
  local name="fm-lab-changed-identity-$$" status=0
  run_with_fake fm_herdr_lab_provision "$name" || fail "changed-identity fixture provision failed"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_LAB_SOCKET="/tmp/$name.foreign.sock" \
    run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed owned identity must block teardown"
  assert_no_grep "session stop $name" "$FAKE_LOG" "changed identity reached stop"
  assert_no_grep "session delete $name" "$FAKE_LOG" "changed identity reached delete"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "changed identity discarded ownership evidence"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "changed-identity fixture cleanup failed"
  pass "fm-herdr-lab: changed identity blocks every lifecycle action"
}

test_identity_change_after_stop_blocks_delete() {
  local name="fm-lab-change-after-stop-$$" status=0
  run_with_fake fm_herdr_lab_provision "$name" || fail "post-stop identity fixture provision failed"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_MUTATE_LAB_AFTER_STOP=1 \
    run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "identity change after stop must block delete"
  assert_grep "session stop $name" "$FAKE_LOG" "post-stop identity fixture never reached guarded stop"
  assert_no_grep "session delete $name" "$FAKE_LOG" "post-stop identity change reached delete"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "post-stop identity change discarded evidence"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "post-stop identity fixture cleanup failed"
  pass "fm-herdr-lab: identity is rechecked immediately before delete"
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

test_timeout_surfaces_default_mutation_postcheck() {
  local name="fm-lab-timeout-default-change-$$" status=0 output
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  output=$(FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 FM_FAKE_HERDR_MUTATE_DEFAULT_ON_STATUS=1 \
    run_with_fake fm_herdr_lab_provision "$name" 2>&1) || status=$?
  expect_code 1 "$status" "timeout with default mutation must fail"
  assert_contains "$output" "did not report running within 10 seconds" \
    "timeout postcheck lost the original timeout diagnostic"
  assert_contains "$output" "FLEET-STATE TRIPWIRE FAILED" \
    "timeout postcheck did not surface the default mutation"
  assert_no_grep "session stop $name" "$FAKE_LOG" "timeout postcheck attempted unowned stop"
  assert_no_grep "session delete $name" "$FAKE_LOG" "timeout postcheck attempted unowned delete"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "timeout postcheck discarded safety evidence"
  pass "fm-herdr-lab: timeout preserves diagnostics and surfaces default mutation"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_absent_default_fleet_state_is_preserved
test_malformed_session_inventories_fail_closed
test_ambiguous_initial_and_owned_inventories_fail_closed
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_delayed_delete_converges_in_one_teardown
test_stop_auto_collapse_is_idempotent
test_default_flag_still_blocks_teardown
test_same_name_foreign_session_is_never_adopted
test_launch_collision_cannot_capture_foreign_identity
test_changed_owned_identity_blocks_lifecycle
test_identity_change_after_stop_blocks_delete
test_timed_out_provision_cancels_late_launch
test_timeout_surfaces_default_mutation_postcheck
