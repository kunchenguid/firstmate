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
    if [ -f "$state/$session.before-list-default" ]; then
      default_socket=$(cat "$state/$session.before-list-default")
      printf '%s\n' "$default_socket" > "$state/default-socket"
      rm "$state/$session.before-list-default"
    fi
    identity=normal
    [ ! -f "$state/$session.identity" ] || identity=$(cat "$state/$session.identity")
    running=false
    [ "$lab_state" = running ] && running=true
    jq -nc --arg socket "$default_socket" --arg name "$session" \
      --arg state "$lab_state" --arg identity "$identity" --argjson running "$running" '
      {default:true,name:"default",running:true,socket_path:$socket} as $default |
      {default:($identity == "default-marked"),name:$name,running:$running,
       socket_path:("/tmp/" + $name + ".sock")} as $lab |
      {sessions: (if $state == "absent" or $state == "deleted" then [$default]
        elif $identity == "ambiguous" then [$default,$lab,$lab]
        elif $identity == "wrong-name" then [$default,($lab | .name = "fm-lab-other")]
        else [$default,$lab] end)}'
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "server live-handoff")
    [ "$#" -eq 10 ] && [ "$3" = --import-exe ] && [ "$5" = --expected-version ] \
      && [ "$7" = --expected-protocol ] && [ "${HERDR_SESSION:-}" = "$session" ] || exit 95
    [ "$lab_state" = running ] || exit 96
    # A receipt records that the mutation was attempted even if import fails.
    printf '%s\n' "$session" >> "$state/handoff-receipts"
    if [ -f "$state/$session.handoff-default" ]; then
      cat "$state/$session.handoff-default" > "$state/default-socket"
    fi
    if [ -f "$state/$session.handoff-identity" ]; then
      cat "$state/$session.handoff-identity" > "$state/$session.identity"
    fi
    if [ -f "$state/$session.handoff-state" ]; then
      cat "$state/$session.handoff-state" > "$state/$session"
    fi
    result=0
    [ ! -f "$state/$session.handoff-result" ] || result=$(cat "$state/$session.handoff-result")
    [ "$result" -eq 0 ] || exit "$result"
    jq -nc --arg executable "$4" --arg version "$6" --argjson protocol "$8" \
      '{executable:$executable,version:$version,protocol:$protocol}' > "$state/$session.runtime"
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
  "terminal title")
    [ "${FM_FAKE_HERDR_TITLE_FAIL:-}" != 1 ] || exit 94
    reason=no_foreground_client
    [ ! -f "$state/$session.foreground" ] || reason=$(cat "$state/$session.foreground")
    jq -nc --arg reason "$reason" '{result:{reason:$reason,type:"client_window_title"}}'
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
    FM_FAKE_HERDR_TITLE_FAIL="${FM_FAKE_HERDR_TITLE_FAIL:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

handoff_digest() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}

prepare_handoff_fixture() {
  local name=$1
  HANDOFF_TARGET="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TMP_ROOT")/staged handoff"
  printf '#!/usr/bin/env bash\nprintf executed > "%s"\n' "$FAKE_STATE/target-executed" > "$HANDOFF_TARGET"
  chmod 700 "$HANDOFF_TARGET"
  HANDOFF_DIGEST=$(handoff_digest "$HANDOFF_TARGET")
  HANDOFF_VERSION=0.9.0-preview.2026-09-09-5a244caa60b0
  run_with_fake fm_herdr_lab_provision "$name" || fail "handoff fixture provision failed"
  rm -f "$FAKE_STATE/handoff-receipts" "$FAKE_STATE/target-executed"
}

expect_handoff_refused() {
  local reason=$1 status=0
  shift
  HANDOFF_REFUSAL=$("$@" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$reason"
  assert_absent "$FAKE_STATE/handoff-receipts" "refused handoff still attempted a server mutation"
  assert_absent "$FAKE_STATE/target-executed" "validation executed the staged target"
}

test_handoff_owned_running_lab() {
  local name="fm-lab-handoff-ok-$$" before default_before
  prepare_handoff_fixture "$name"
  before=$(cat "$TRIPWIRES/$name.fleet-state.json")
  default_before=$(cat "$FAKE_STATE/default-socket")
  run_with_fake "$ROOT/bin/fm-herdr-lab.sh" handoff "$name" "${HANDOFF_TARGET%/*}/./${HANDOFF_TARGET##*/}" \
    "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22 >/dev/null || fail "owned running lab handoff failed"
  [ "$(cat "$FAKE_STATE/handoff-receipts")" = "$name" ] || fail "handoff did not mutate exactly the owned lab"
  jq -e --arg executable "$HANDOFF_TARGET" --arg version "$HANDOFF_VERSION" \
    '.executable == $executable and .version == $version and .protocol == 22' \
    "$FAKE_STATE/$name.runtime" >/dev/null || fail "lab did not adopt the verified runtime"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "handoff stopped the owned lab"
  [ "$(cat "$FAKE_STATE/default-socket")" = "$default_before" ] || fail "handoff changed the default session"
  [ "$(cat "$TRIPWIRES/$name.fleet-state.json")" = "$before" ] || fail "handoff discarded or rewrote ownership evidence"
  [ "$(handoff_digest "$HANDOFF_TARGET")" = "$HANDOFF_DIGEST" ] || fail "handoff modified the staged executable"
  assert_absent "$FAKE_STATE/target-executed" "the helper executed the target before guarded handoff"
  pass "fm-herdr-lab: owned running lab handoff preserves default and ownership evidence"
}

test_handoff_owned_lab_under_permissive_umask() {
  local name="fm-lab-handoff-umask-$$" record status=0
  record="$TRIPWIRES/$name.fleet-state.json"
  (
    umask 0002
    prepare_handoff_fixture "$name"
    run_with_fake "$ROOT/bin/fm-herdr-lab.sh" handoff "$name" "$HANDOFF_TARGET" \
      "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22 >/dev/null
  ) || status=$?
  expect_code 0 "$status" "handoff of a lab provisioned under umask 0002"
  python3 -c 'import os,sys; sys.exit(1 if os.stat(sys.argv[1]).st_mode & 0o077 else 0)' "$record" \
    || fail "ownership record created under umask 0002 is accessible beyond its owner"
  [ "$(cat "$FAKE_STATE/handoff-receipts")" = "$name" ] || fail "umask 0002 handoff did not reach the owned lab"
  pass "fm-herdr-lab: the ownership record is owner-only under a permissive umask and still admits handoff"
}

test_handoff_requires_owned_running_identity() {
  local name="fm-lab-handoff-identity-$$" other="fm-lab-unowned-$$" value
  prepare_handoff_fixture "$name"
  for value in default arbitrary-session; do
    expect_handoff_refused "unsafe session accepted" run_with_fake fm_herdr_lab_handoff \
      "$value" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  done
  printf '%s\n' running > "$FAKE_STATE/$other"
  expect_handoff_refused "unowned running lab accepted" run_with_fake fm_herdr_lab_handoff \
    "$other" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  for value in stopped absent; do
    printf '%s\n' "$value" > "$FAKE_STATE/$name"
    expect_handoff_refused "nonrunning lab accepted" run_with_fake fm_herdr_lab_handoff \
      "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  done
  printf '%s\n' running > "$FAKE_STATE/$name"
  for value in default-marked ambiguous wrong-name; do
    printf '%s\n' "$value" > "$FAKE_STATE/$name.identity"
    expect_handoff_refused "unsafe scoped lab identity accepted" run_with_fake fm_herdr_lab_handoff \
      "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  done
  rm "$FAKE_STATE/$name.identity"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "identity refusal discarded ownership evidence"
  pass "fm-herdr-lab: handoff requires one owned running nondefault lab"
}

test_handoff_rejects_unsafe_ownership_record() {
  local name="fm-lab-handoff-record-$$" record saved
  prepare_handoff_fixture "$name"
  record="$TRIPWIRES/$name.fleet-state.json"
  saved="$TMP_ROOT/handoff-record"
  mv "$record" "$saved"
  ln -s "$saved" "$record"
  expect_handoff_refused "symlink ownership accepted" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  rm "$record"
  ln "$saved" "$record"
  expect_handoff_refused "multiply-linked ownership accepted" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  rm "$record"
  mv "$saved" "$record"
  chmod 660 "$record"
  expect_handoff_refused "group-writable ownership accepted" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  assert_contains "$HANDOFF_REFUSAL" "$record" "unsafe ownership record refusal did not name the record"
  chmod 606 "$record"
  expect_handoff_refused "world-writable ownership accepted" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  chmod 600 "$record"
  mv "$record" "$saved"
  mkdir "$record"
  expect_handoff_refused "nonregular ownership accepted" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  rmdir "$record"
  mv "$saved" "$record"
  pass "fm-herdr-lab: handoff refuses unsafe ownership records"
}

test_handoff_rejects_unsafe_executable_and_digest() {
  local name="fm-lab-handoff-target-$$" target digest
  prepare_handoff_fixture "$name"
  ln -s "$HANDOFF_TARGET" "$TMP_ROOT/handoff-link"
  mkdir "$TMP_ROOT/handoff-directory"
  for target in "relative-executable" "$TMP_ROOT/handoff-link" "$TMP_ROOT/handoff-missing" "$TMP_ROOT/handoff-directory"; do
    expect_handoff_refused "unsafe executable accepted" run_with_fake fm_herdr_lab_handoff \
      "$name" "$target" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  done
  for target in 600 720 702; do
    chmod "$target" "$HANDOFF_TARGET"
    expect_handoff_refused "nonexecutable or writable target accepted" run_with_fake fm_herdr_lab_handoff \
      "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
    assert_contains "$HANDOFF_REFUSAL" "$HANDOFF_TARGET" "unsafe executable refusal did not name the executable"
  done
  chmod 700 "$HANDOFF_TARGET"
  digest=$(handoff_digest "$FAKEBIN/herdr")
  expect_handoff_refused "selected Herdr executable accepted as its own replacement" run_with_fake fm_herdr_lab_handoff \
    "$name" "$FAKEBIN/herdr" "$digest" "$HANDOFF_VERSION" 22
  for digest in invalid 0000000000000000000000000000000000000000000000000000000000000000; do
    expect_handoff_refused "unverified digest accepted" run_with_fake fm_herdr_lab_handoff \
      "$name" "$HANDOFF_TARGET" "$digest" "$HANDOFF_VERSION" 22
  done
  printf '%s\n' '# changed after digest was recorded' >> "$HANDOFF_TARGET"
  expect_handoff_refused "changed executable accepted against stale digest" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  pass "fm-herdr-lab: executable identity, permissions, and content are verified before mutation"
}

test_handoff_rejects_argument_injection_and_generic_server() {
  local name="fm-lab-handoff-args-$$" value
  prepare_handoff_fixture "$name"
  for value in --session=default --force; do
    expect_handoff_refused "extra handoff argument accepted" run_with_fake "$ROOT/bin/fm-herdr-lab.sh" \
      handoff "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22 "$value"
  done
  expect_handoff_refused "session override accepted" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22 --session default
  expect_handoff_refused "option-like version accepted" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" --session=default 22
  expect_handoff_refused "nonnumeric protocol accepted" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" --session=default
  expect_handoff_refused "missing protocol accepted" run_with_fake "$ROOT/bin/fm-herdr-lab.sh" \
    handoff "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION"
  expect_handoff_refused "generic run gained server passthrough" run_with_fake fm_herdr_lab_cli \
    "$name" server live-handoff --import-exe "$HANDOFF_TARGET" --expected-version "$HANDOFF_VERSION" --expected-protocol 22
  pass "fm-herdr-lab: handoff has fixed positional arguments and no generic server escape"
}

test_handoff_refreshes_default_tripwire_before_mutation() {
  local name="fm-lab-handoff-pre-$$" before default_before
  prepare_handoff_fixture "$name"
  before=$(cat "$TRIPWIRES/$name.fleet-state.json")
  default_before=$(cat "$FAKE_STATE/default-socket")
  printf '%s\n' /changed/before-handoff.sock > "$FAKE_STATE/$name.before-list-default"
  expect_handoff_refused "fresh default drift accepted" run_with_fake fm_herdr_lab_handoff \
    "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" "$HANDOFF_VERSION" 22
  [ "$(cat "$FAKE_STATE/default-socket")" = /changed/before-handoff.sock ] || fail "pre-handoff drift fixture was not exercised"
  [ "$(cat "$TRIPWIRES/$name.fleet-state.json")" = "$before" ] || fail "pre-handoff failure lost the original tripwire"
  printf '%s\n' "$default_before" > "$FAKE_STATE/default-socket"
  pass "fm-herdr-lab: a fresh pre-handoff default tripwire blocks mutation"
}

test_handoff_preserves_failure_and_rechecks_default() {
  local name="fm-lab-handoff-result-$$" before default_before result status
  prepare_handoff_fixture "$name"
  before=$(cat "$TRIPWIRES/$name.fleet-state.json")
  default_before=$(cat "$FAKE_STATE/default-socket")
  printf '%s\n' 37 > "$FAKE_STATE/$name.handoff-result"
  status=0
  run_with_fake fm_herdr_lab_handoff "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" \
    "$HANDOFF_VERSION" 22 >/dev/null 2>&1 || status=$?
  expect_code 37 "$status" "safe post-checks must preserve the actual handoff failure"
  [ "$(cat "$FAKE_STATE/handoff-receipts")" = "$name" ] || fail "failure fixture never attempted handoff"
  assert_absent "$FAKE_STATE/$name.runtime" "failed import unexpectedly changed the runtime"
  [ "$(cat "$TRIPWIRES/$name.fleet-state.json")" = "$before" ] || fail "failed handoff discarded ownership evidence"
  for result in 0 37; do
    printf '%s\n' "$result" > "$FAKE_STATE/$name.handoff-result"
    printf '%s\n' /changed/during-handoff.sock > "$FAKE_STATE/$name.handoff-default"
    rm "$FAKE_STATE/handoff-receipts"
    status=0
    run_with_fake fm_herdr_lab_handoff "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" \
      "$HANDOFF_VERSION" 22 >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "post-handoff default drift must override both success and import failure"
    [ "$(cat "$FAKE_STATE/handoff-receipts")" = "$name" ] || fail "post-check fixture never attempted handoff"
    [ "$(cat "$FAKE_STATE/default-socket")" = /changed/during-handoff.sock ] || fail "default drift was silently rolled back"
    [ "$(cat "$TRIPWIRES/$name.fleet-state.json")" = "$before" ] || fail "post-handoff failure lost original evidence"
    printf '%s\n' "$default_before" > "$FAKE_STATE/default-socket"
  done
  pass "fm-herdr-lab: handoff failures survive unless a fresh default safety check fails"
}

test_handoff_rechecks_running_scoped_identity_afterward() {
  local name="fm-lab-handoff-post-$$" value result status before
  prepare_handoff_fixture "$name"
  before=$(cat "$TRIPWIRES/$name.fleet-state.json")
  for result in 0 37; do
    printf '%s\n' "$result" > "$FAKE_STATE/$name.handoff-result"
    for value in stopped absent default-marked ambiguous wrong-name; do
      printf '%s\n' running > "$FAKE_STATE/$name"
      rm -f "$FAKE_STATE/$name.identity" "$FAKE_STATE/$name.handoff-state" \
        "$FAKE_STATE/$name.handoff-identity" "$FAKE_STATE/handoff-receipts"
      case "$value" in
        stopped|absent) printf '%s\n' "$value" > "$FAKE_STATE/$name.handoff-state" ;;
        *) printf '%s\n' "$value" > "$FAKE_STATE/$name.handoff-identity" ;;
      esac
      status=0
      run_with_fake fm_herdr_lab_handoff "$name" "$HANDOFF_TARGET" "$HANDOFF_DIGEST" \
        "$HANDOFF_VERSION" 22 >/dev/null 2>&1 || status=$?
      expect_code 1 "$status" "post-handoff unsafe lab identity must fail closed"
      [ "$(cat "$FAKE_STATE/handoff-receipts")" = "$name" ] || fail "post-handoff identity fixture never attempted mutation"
      [ "$(cat "$TRIPWIRES/$name.fleet-state.json")" = "$before" ] || fail "post-handoff identity failure discarded ownership"
    done
  done
  pass "fm-herdr-lab: both successful and failed imports recheck running nondefault lab identity"
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
  while [ -n "${FM_FAKE_HERDR_WAIT_MARKER:-}" ] && [ ! -f "$FM_FAKE_HERDR_WAIT_MARKER" ]; do
    "$FM_FAKE_HERDR_REAL_SLEEP" 0.01
  done
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


# The pty attachment itself needs a real Herdr client, so the live guard
# tests/fm-herdr-attached-viewer-live-e2e.test.sh owns that proof. What is
# portable is who the helper will ever attach to, and who it will signal.
test_viewer_refuses_unowned_sessions() {
  local name="fm-lab-viewer-guard-$$" status=0 out
  : > "$FAKE_LOG"
  out=$(run_with_fake fm_herdr_lab_viewer_start "$name" 2>&1) || status=$?
  expect_code 1 "$status" "a session without an ownership tripwire must not be attached to"
  assert_contains "$out" "does not own" \
    "the viewer refusal did not name the missing ownership record"
  [ ! -s "$FAKE_LOG" ] \
    || fail "the unowned-session refusal reached Herdr instead of refusing first"

  status=0
  run_with_fake fm_herdr_lab_viewer_start default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "the default session must never be attached to"
  pass "fm-herdr-lab: the viewer attaches only to a session this lab owns"
}

start_viewer_fixture() {
  local pair=$1
  (
    "$REAL_SLEEP" 20 &
    printf '%s\n' "$!" > "$pair"
    wait
  ) &
  FIXTURE_LAUNCHER_PID=$!
  while [ ! -s "$pair" ]; do
    "$REAL_SLEEP" 0.01
  done
  FIXTURE_VIEWER_PID=$(cat "$pair")
}

write_viewer_record() {
  local record=$1 launcher_pid=$2 viewer_pid=$3 launcher_start viewer_start
  launcher_start=$(fm_herdr_lab_process_start "$launcher_pid") || fail "could not identify launcher fixture process"
  viewer_start=$(fm_herdr_lab_process_start "$viewer_pid") || fail "could not identify viewer fixture process"
  printf 'launcher_pid=%s\nlauncher_start=%s\nviewer_pid=%s\nviewer_start=%s\n' \
    "$launcher_pid" "$launcher_start" "$viewer_pid" "$viewer_start" > "$record"
}

test_viewer_start_cancels_an_unrecorded_launcher() {
  local name="fm-lab-viewer-late-$$" out status=0 launcher_pid
  local started="$TMP_ROOT/viewer-launcher-started"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-late fixture provision failed"
  cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_FAKE_VIEWER_STARTED"
exec "$FM_FAKE_HERDR_REAL_SLEEP" 20
SH
  chmod +x "$FAKEBIN/python3"
  out=$(FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_WAIT_MARKER="$started" \
    FM_FAKE_VIEWER_STARTED="$started" run_with_fake fm_herdr_lab_viewer_start "$name" 2>&1) || status=$?
  rm -f "$FAKEBIN/python3"
  expect_code 1 "$status" "an unrecorded launcher must not outlive viewer start"
  assert_present "$started" "delayed viewer launcher did not start"
  launcher_pid=$(cat "$started")
  kill -0 "$launcher_pid" 2>/dev/null && fail "timed-out viewer launcher remained alive"
  assert_contains "$out" "did not become the foreground client" "launcher timeout was unclear"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "viewer-late fixture teardown failed"
  pass "fm-herdr-lab: timed-out viewer startup cancels its exact launcher"
}

test_viewer_timeout_allows_launcher_escalation() {
  local launcher_pid started="$TMP_ROOT/viewer-grace-started"
  local terminating="$TMP_ROOT/viewer-grace-terminating" completed="$TMP_ROOT/viewer-grace-completed"
  cat > "$FAKEBIN/viewer-launcher" <<'SH'
#!/usr/bin/env bash
trap 'printf "" > "$FM_FAKE_VIEWER_TERMINATING"; "$FM_FAKE_HERDR_REAL_SLEEP" 1.2; printf "" > "$FM_FAKE_VIEWER_COMPLETED"; exit 0' TERM
printf '' > "$FM_FAKE_VIEWER_STARTED"
while :; do
  "$FM_FAKE_HERDR_REAL_SLEEP" 0.1
done
SH
  chmod +x "$FAKEBIN/viewer-launcher"
  FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" FM_FAKE_VIEWER_STARTED="$started" \
    FM_FAKE_VIEWER_TERMINATING="$terminating" FM_FAKE_VIEWER_COMPLETED="$completed" \
    "$FAKEBIN/viewer-launcher" &
  launcher_pid=$!
  while [ ! -f "$started" ]; do
    "$REAL_SLEEP" 0.01
  done
  run_with_fake fm_herdr_lab_cancel_viewer_launcher "$launcher_pid"
  assert_present "$terminating" "timed-out viewer launcher did not receive TERM"
  assert_present "$completed" "viewer launcher was killed before completing child escalation"
  pass "fm-herdr-lab: startup timeout allows launcher child escalation"
}

test_viewer_start_requires_its_owned_process() {
  local name="fm-lab-viewer-ownership-$$" out status=0 marker="$TMP_ROOT/viewer-launched"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-ownership fixture provision failed"
  printf '%s\n' cleared > "$FAKE_STATE/$name.foreground"
  cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
: > "$FM_FAKE_VIEWER_MARKER"
exit 0
SH
  chmod +x "$FAKEBIN/python3"
  out=$(FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_VIEWER_MARKER="$marker" \
    run_with_fake fm_herdr_lab_viewer_start "$name" 2>&1) || status=$?
  rm -f "$FAKEBIN/python3"
  expect_code 1 "$status" "a foreign foreground client must not satisfy viewer start"
  assert_present "$marker" "viewer ownership fixture did not launch"
  assert_contains "$out" "did not become the foreground client" "ownership failure did not time out clearly"
  assert_not_contains "$out" "viewer attached" "start claimed a foreign foreground client as its own"
  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "viewer-ownership fixture teardown failed"
  pass "fm-herdr-lab: viewer start requires an identity-matched owned process"
}

test_viewer_stop_only_signals_owned_processes() {
  local name="fm-lab-viewer-stop-$$" record status=0 holder_pid pair="$TMP_ROOT/viewer-stop-pair"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-stop fixture provision failed"
  record=$(run_with_fake fm_herdr_lab_viewer_record_path "$name")

  # No record: a client attached by someone else is not ours to kill.
  printf '%s\n' cleared > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_viewer_stop "$name" \
    || fail "stopping with no recorded viewer must succeed without touching a foreign client"
  [ "$(cat "$FAKE_STATE/$name.foreground")" = cleared ] \
    || fail "an unrecorded foreground client was detached by the lab helper"

  # A recorded viewer is signalled until it exits and the session reports no
  # foreground client again.
  start_viewer_fixture "$pair"
  write_viewer_record "$record" "$FIXTURE_LAUNCHER_PID" "$FIXTURE_VIEWER_PID"
  status=0
  FM_FAKE_HERDR_FAST_POLL=1 run_with_fake fm_herdr_lab_viewer_stop "$name" \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must fail while the session still reports a foreground client"
  wait "$FIXTURE_LAUNCHER_PID" 2>/dev/null || true
  kill -0 "$FIXTURE_VIEWER_PID" 2>/dev/null && fail "stop left the recorded viewer process running"
  assert_present "$record" "a failed detach discarded the viewer record it still needs"

  sleep 20 &
  holder_pid=$!
  printf 'launcher_pid=%s\nlauncher_start=not-this-process\nviewer_pid=%s\nviewer_start=not-this-process\n' \
    "$holder_pid" "$holder_pid" > "$record"
  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_viewer_stop "$name" || fail "stop rejected a stale process record"
  kill -0 "$holder_pid" 2>/dev/null || fail "stop signalled a PID whose recorded identity did not match"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  run_with_fake fm_herdr_lab_viewer_stop "$name" || fail "stop failed once the client had detached"
  assert_absent "$record" "a confirmed detach left the viewer record behind"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after viewer stop failed"
  pass "fm-herdr-lab: viewer stop signals only recorded processes and confirms the detach"
}

test_viewer_stop_requires_the_recorded_parent() {
  local name="fm-lab-viewer-parent-$$" record launcher_pid viewer_pid
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-parent fixture provision failed"
  record=$(run_with_fake fm_herdr_lab_viewer_record_path "$name")
  sleep 20 &
  launcher_pid=$!
  sleep 20 &
  viewer_pid=$!
  write_viewer_record "$record" "$launcher_pid" "$viewer_pid"
  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_viewer_stop "$name" || fail "parent-mismatch stop failed"
  kill -0 "$launcher_pid" 2>/dev/null || fail "stop signalled a launcher without its recorded child"
  kill -0 "$viewer_pid" 2>/dev/null || fail "stop signalled a viewer outside the recorded launcher"
  kill "$launcher_pid" "$viewer_pid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  wait "$viewer_pid" 2>/dev/null || true
  run_with_fake fm_herdr_lab_teardown "$name" || fail "viewer-parent fixture teardown failed"
  pass "fm-herdr-lab: viewer ownership requires the recorded parent"
}

test_interrupted_viewer_start_cancels_launcher() {
  local name="fm-lab-viewer-interrupt-$$" command_pid launcher_pid status=0
  local started="$TMP_ROOT/viewer-interrupt-started" attached="$TMP_ROOT/viewer-interrupt-attached"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-interrupt fixture provision failed"
  cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_FAKE_VIEWER_STARTED"
"$FM_FAKE_HERDR_REAL_SLEEP" 0.5
: > "$FM_FAKE_VIEWER_ATTACHED"
printf '%s\n' cleared > "$FM_FAKE_HERDR_STATE/$FM_FAKE_VIEWER_SESSION.foreground"
exec "$FM_FAKE_HERDR_REAL_SLEEP" 20
SH
  chmod +x "$FAKEBIN/python3"
  FM_FAKE_VIEWER_STARTED="$started" FM_FAKE_VIEWER_ATTACHED="$attached" \
    FM_FAKE_VIEWER_SESSION="$name" run_with_fake exec "$ROOT/bin/fm-herdr-lab.sh" \
    viewer start "$name" >/dev/null 2>&1 &
  command_pid=$!
  while [ ! -f "$started" ]; do
    "$REAL_SLEEP" 0.01
  done
  launcher_pid=$(cat "$started")
  kill -TERM "$command_pid"
  wait "$command_pid" || status=$?
  rm -f "$FAKEBIN/python3"
  [ "$status" -ne 0 ] || fail "interrupted viewer start unexpectedly succeeded"
  "$REAL_SLEEP" 0.6
  kill -0 "$launcher_pid" 2>/dev/null && fail "interrupted viewer start left its launcher running"
  assert_absent "$attached" "interrupted viewer start attached after its command exited"
  [ ! -f "$FAKE_STATE/$name.foreground" ] || fail "interrupted viewer start left a foreground client"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "viewer-interrupt fixture teardown failed"
  pass "fm-herdr-lab: interrupted viewer start cancels its launcher"
}

test_teardown_refuses_while_viewer_attached() {
  local name="fm-lab-viewer-teardown-$$" record status=0 pair="$TMP_ROOT/viewer-teardown-pair"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-teardown fixture provision failed"
  record=$(run_with_fake fm_herdr_lab_viewer_record_path "$name")
  printf '%s\n' cleared > "$FAKE_STATE/$name.foreground"
  start_viewer_fixture "$pair"
  write_viewer_record "$record" "$FIXTURE_LAUNCHER_PID" "$FIXTURE_VIEWER_PID"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 run_with_fake fm_herdr_lab_teardown "$name" \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "teardown must refuse while an owned viewer is still attached"
  [ "$(cat "$FAKE_STATE/$name")" = running ] \
    || fail "the refused teardown stopped the lab session anyway"
  assert_no_grep "session delete $name" "$FAKE_LOG" \
    "the refused teardown still reached the destructive delete"

  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after the viewer detached failed"
  pass "fm-herdr-lab: teardown refuses to destroy a session an attached viewer still holds"
}

test_viewer_stop_retains_record_when_detach_is_unreadable() {
  local name="fm-lab-viewer-unreadable-$$" record status=0
  run_with_fake fm_herdr_lab_provision "$name" || fail "unreadable-detach fixture provision failed"
  record=$(run_with_fake fm_herdr_lab_viewer_record_path "$name")
  printf 'launcher_pid=99999999\nlauncher_start=stale\nviewer_pid=99999999\nviewer_start=stale\n' > "$record"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_TITLE_FAIL=1 \
    run_with_fake fm_herdr_lab_viewer_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an unreadable detach result on a running session must fail closed"
  assert_present "$record" "an unreadable detach result discarded the ownership record"
  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after a confirmed detach failed"
  pass "fm-herdr-lab: unreadable detach results fail closed on running sessions"
}

test_viewer_launcher_refuses_unsafe_arguments() {
  local launcher="$ROOT/bin/fm-herdr-lab-viewer.py" status=0
  command -v python3 >/dev/null 2>&1 || { pass "fm-herdr-lab: viewer launcher argument guard (skipped, no python3)"; return; }
  python3 "$launcher" default "$TMP_ROOT/pid" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "the launcher must refuse the default session"
  status=0
  python3 "$launcher" arbitrary-session "$TMP_ROOT/pid" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "the launcher must refuse a non-lab session name"
  status=0
  python3 "$launcher" fm-lab-args relative-pidfile >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "the launcher must refuse a relative pidfile path"
  assert_absent "$TMP_ROOT/pid" "a refused launch still wrote a pid record"
  pass "fm-herdr-lab: the viewer launcher refuses unsafe sessions and pidfiles"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_handoff_owned_running_lab
test_handoff_owned_lab_under_permissive_umask
test_handoff_requires_owned_running_identity
test_handoff_rejects_unsafe_ownership_record
test_handoff_rejects_unsafe_executable_and_digest
test_handoff_rejects_argument_injection_and_generic_server
test_handoff_refreshes_default_tripwire_before_mutation
test_handoff_preserves_failure_and_rechecks_default
test_handoff_rechecks_running_scoped_identity_afterward
test_timed_out_provision_cancels_late_launch
test_viewer_refuses_unowned_sessions
test_viewer_start_cancels_an_unrecorded_launcher
test_viewer_timeout_allows_launcher_escalation
test_viewer_start_requires_its_owned_process
test_viewer_stop_only_signals_owned_processes
test_viewer_stop_requires_the_recorded_parent
test_interrupted_viewer_start_cancels_launcher
test_teardown_refuses_while_viewer_attached
test_viewer_stop_retains_record_when_detach_is_unreadable
test_viewer_launcher_refuses_unsafe_arguments
