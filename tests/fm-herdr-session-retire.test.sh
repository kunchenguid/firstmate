#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-session-retire.sh using a stateful fake
# Herdr client. Never drives a live Herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-session-retire)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
mkdir -p "$FAKE_STATE/registry" "$FAKE_STATE/workspaces"

# Registry files hold "default=<true|false>\nrunning=<true|false>\n" for every
# session the standard fake knows about; a workspaces/<name> file holds a
# workspace count (absent means 0, i.e. empty).
write_session() { # <name> <default> <running>
  printf 'default=%s\nrunning=%s\n' "$2" "$3" > "$FAKE_STATE/registry/$1"
}

write_workspaces() { # <name> <count>
  printf '%s\n' "$2" > "$FAKE_STATE/workspaces/$1"
}

# The standard multi-session fake: session list is built live from the
# registry directory, workspace list is driven by the per-session count file,
# session stop flips the named registry file to running=false (and, when
# FM_FAKE_HERDR_STOP_INERT is set, deliberately does not - simulating a stop
# call that reports success but changes nothing, to exercise the postcondition
# check), and session delete / server are forbidden calls that fail loudly so
# a test can prove retirement never reaches them.
write_standard_fake() {
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

session_list_json() {
  local f name default running first=1
  printf '{"sessions":['
  for f in "$state/registry"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    default=$(sed -n 's/^default=//p' "$f")
    running=$(sed -n 's/^running=//p' "$f")
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"name":"%s","default":%s,"running":%s,"socket_path":"/tmp/%s.sock"}' \
      "$name" "$default" "$running" "$name"
  done
  printf ']}'
}

case "$1 ${2:-}" in
  "session list")
    session_list_json
    ;;
  "workspace list")
    if [ "${FM_FAKE_HERDR_WORKSPACES_BROKEN:-}" = "$session" ]; then
      printf '%s\n' 'not json'
    else
      count=0
      [ ! -f "$state/workspaces/$session" ] || count=$(cat "$state/workspaces/$session")
      if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
        jq -nc --argjson n "$count" \
          '{result:{workspaces: ([range($n)] | map({workspace_id: ("w" + (. | tostring))}))}}'
      else
        printf '%s\n' '{"result":{"workspaces":[]}}'
      fi
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    [ -f "$state/registry/$session" ] || exit 92
    if [ "${FM_FAKE_HERDR_STOP_INERT:-}" != 1 ]; then
      default=$(sed -n 's/^default=//p' "$state/registry/$session")
      printf 'default=%s\nrunning=false\n' "$default" > "$state/registry/$session"
    fi
    if [ -n "${FM_FAKE_HERDR_DRIFT_AFTER_STOP:-}" ]; then
      printf 'default=false\nrunning=false\n' > "$state/registry/${FM_FAKE_HERDR_DRIFT_AFTER_STOP}"
    fi
    printf '%s\n' '{"ok":true}'
    ;;
  "session delete"|"server")
    printf 'FORBIDDEN CALL: %s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
    exit 95
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
  chmod +x "$FAKEBIN/herdr"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-session-retire.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_WORKSPACES_BROKEN="${FM_FAKE_HERDR_WORKSPACES_BROKEN:-}" \
    FM_FAKE_HERDR_STOP_INERT="${FM_FAKE_HERDR_STOP_INERT:-}" \
    FM_FAKE_HERDR_DRIFT_AFTER_STOP="${FM_FAKE_HERDR_DRIFT_AFTER_STOP:-}" \
    "$@"
}

reset_fixture() {
  rm -rf "$FAKE_STATE/registry" "$FAKE_STATE/workspaces"
  mkdir -p "$FAKE_STATE/registry" "$FAKE_STATE/workspaces"
  : > "$FAKE_LOG"
  write_standard_fake
  write_session default true true
}

test_reserved_names_are_refused_without_reaching_herdr() {
  local status=0
  reset_fixture
  run_with_fake fm_herdr_retire_stop default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  run_with_fake fm_herdr_retire_stop fm-remote >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal fm-remote must be refused"
  status=0
  run_with_fake fm_herdr_retire_stop fm-lab-anything-123 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a generated lab session name must be refused"
  status=0
  run_with_fake fm_herdr_retire_stop '' >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an empty session name must be refused"
  [ ! -s "$FAKE_LOG" ] || fail "a reserved-name refusal reached Herdr instead of refusing first"
  pass "fm-herdr-session-retire: reserved names fail closed before any Herdr call"
}

test_absent_target_is_refused() {
  local status=0
  reset_fixture
  run_with_fake fm_herdr_retire_stop mbk >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an absent target must be refused"
  assert_no_grep "session stop" "$FAKE_LOG" "an absent-target refusal still reached session stop"
  pass "fm-herdr-session-retire: an absent target is refused"
}

test_stopped_target_is_refused() {
  local status=0
  reset_fixture
  write_session mbk false false
  run_with_fake fm_herdr_retire_stop mbk >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an already-stopped target must be refused"
  assert_no_grep "session stop" "$FAKE_LOG" "a stopped-target refusal still reached session stop"
  pass "fm-herdr-session-retire: an already-stopped target is refused"
}

test_default_flagged_target_is_refused() {
  local status=0
  reset_fixture
  # Reaches the guard by name, but the server itself reports default=true for
  # this row; the invariant checks the API field, not just the string.
  write_session weird-default true true
  run_with_fake fm_herdr_retire_stop weird-default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a target whose row reports default=true must be refused"
  assert_no_grep "session stop" "$FAKE_LOG" "a default-flagged target refusal still reached session stop"
  pass "fm-herdr-session-retire: a target reporting default=true is refused regardless of its name"
}

test_duplicate_target_rows_are_refused() {
  local status=0
  reset_fixture
  cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FAKE_LOG"
case "\$1 \${2:-}" in
  "session list")
    printf '{"sessions":[{"name":"mbk","default":false,"running":true,"socket_path":"/tmp/mbk-a.sock"},{"name":"mbk","default":false,"running":true,"socket_path":"/tmp/mbk-b.sock"}]}'
    ;;
  "session delete"|"server")
    printf 'FORBIDDEN CALL: %s\n' "\$*" >> "$FAKE_LOG"
    exit 95
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
  chmod +x "$FAKEBIN/herdr"
  run_with_fake fm_herdr_retire_stop mbk >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "two matching session rows must be refused as ambiguous"
  assert_no_grep "session stop" "$FAKE_LOG" "an ambiguous-target refusal still reached session stop"
  pass "fm-herdr-session-retire: more than one matching session row is refused"
}

test_nonempty_target_workspace_count_is_refused() {
  local status=0
  reset_fixture
  write_session mbk false true
  write_workspaces mbk 1
  run_with_fake fm_herdr_retire_stop mbk >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a target with one workspace must be refused"
  assert_no_grep "session stop" "$FAKE_LOG" "a nonempty-target refusal still reached session stop"
  pass "fm-herdr-session-retire: a target with a nonzero workspace count is refused"
}

test_nonempty_target_multiple_workspaces_is_refused() {
  local status=0
  reset_fixture
  write_session mbk false true
  write_workspaces mbk 3
  run_with_fake fm_herdr_retire_stop mbk >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a target with several workspaces must be refused"
  pass "fm-herdr-session-retire: a target with several workspaces is refused"
}

test_unreadable_workspace_shape_is_refused() {
  local status=0
  reset_fixture
  write_session mbk false true
  status=0
  FM_FAKE_HERDR_WORKSPACES_BROKEN=mbk run_with_fake fm_herdr_retire_stop mbk >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an unreadable workspace-list shape must fail closed, not be treated as empty"
  assert_no_grep "session stop" "$FAKE_LOG" "an unreadable-shape refusal still reached session stop"
  pass "fm-herdr-session-retire: an unreadable workspace-list response fails closed"
}

test_protected_session_drift_between_checks_is_refused() {
  local status=0 out
  reset_fixture
  cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FAKE_LOG"
case "\$1 \${2:-}" in
  "session list")
    calls_file="$TMP_ROOT/drift-list-calls"
    n=0
    [ ! -f "\$calls_file" ] || n=\$(cat "\$calls_file")
    n=\$((n + 1))
    printf '%s' "\$n" > "\$calls_file"
    if [ "\$n" -le 1 ]; then other_running=true; else other_running=false; fi
    printf '{"sessions":[{"name":"default","default":true,"running":true,"socket_path":"/tmp/default.sock"},{"name":"mbk","default":false,"running":true,"socket_path":"/tmp/mbk.sock"},{"name":"other-live","default":false,"running":%s,"socket_path":"/tmp/other-live.sock"}]}\n' "\$other_running"
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[]}}'
    ;;
  "session delete"|"server")
    printf 'FORBIDDEN CALL: %s\n' "\$*" >> "$FAKE_LOG"
    exit 95
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
  chmod +x "$FAKEBIN/herdr"
  status=0
  out=$(run_with_fake fm_herdr_retire_stop mbk 2>&1) || status=$?
  expect_code 1 "$status" "another session changing between the two internal prechecks must be refused"
  assert_contains "$out" "changed between checks" "the drift refusal did not name itself"
  assert_no_grep "session stop" "$FAKE_LOG" "protected-session drift still reached session stop"
  pass "fm-herdr-session-retire: another session drifting between the two internal prechecks is refused"
}

test_race_target_becomes_nonempty_between_the_two_stop_prechecks() {
  local status=0 out
  reset_fixture
  cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -eu
printf '%s\n' "\$*" >> "$FAKE_LOG"
case "\$1 \${2:-}" in
  "session list")
    printf '{"sessions":[{"name":"default","default":true,"running":true,"socket_path":"/tmp/default.sock"},{"name":"mbk","default":false,"running":true,"socket_path":"/tmp/mbk.sock"}]}'
    ;;
  "workspace list")
    calls_file="$TMP_ROOT/race-calls"
    n=0
    [ ! -f "\$calls_file" ] || n=\$(cat "\$calls_file")
    n=\$((n + 1))
    printf '%s' "\$n" > "\$calls_file"
    if [ "\$n" -le 1 ]; then
      printf '%s\n' '{"result":{"workspaces":[]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1"}]}}'
    fi
    ;;
  "session delete"|"server")
    printf 'FORBIDDEN CALL: %s\n' "\$*" >> "$FAKE_LOG"
    exit 95
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
  chmod +x "$FAKEBIN/herdr"
  out=$(run_with_fake fm_herdr_retire_stop mbk 2>&1) || status=$?
  expect_code 1 "$status" "a target that becomes nonempty between the two internal prechecks must be refused"
  assert_contains "$out" "not empty" "the race refusal did not name the emptiness check"
  assert_no_grep "session stop" "$FAKE_LOG" "the race refusal still reached session stop"
  pass "fm-herdr-session-retire: a target racing to nonempty between the two internal prechecks is refused"
}

test_exact_stop_invocation_and_no_other_destructive_call() {
  reset_fixture
  write_session mbk false true
  write_workspaces mbk 0
  run_with_fake fm_herdr_retire_stop mbk >/dev/null || fail "guarded stop failed on a clean empty target"
  [ "$(sed -n 's/^running=//p' "$FAKE_STATE/registry/mbk")" = false ] \
    || fail "guarded stop did not stop the target session"
  assert_grep "session stop mbk --json --session mbk" "$FAKE_LOG" \
    "the exact required stop invocation was not issued"
  assert_no_grep "session delete" "$FAKE_LOG" "retirement must never call session delete"
  assert_no_grep "FORBIDDEN CALL" "$FAKE_LOG" "retirement reached a forbidden delete or server call"
  while IFS= read -r line; do
    case "$line" in
      *"--session mbk") : ;;
      *) fail "Herdr call lacks a trailing target session: $line" ;;
    esac
  done < "$FAKE_LOG"
  pass "fm-herdr-session-retire: the exact stop call is issued and no delete/server call is ever made"
}

test_successful_postconditions_are_verified() {
  local out
  reset_fixture
  write_session mbk false true
  write_workspaces mbk 0
  write_session other-kept false true
  out=$(run_with_fake fm_herdr_retire_stop mbk) || fail "guarded stop failed"
  assert_contains "$out" "stopped mbk" "success output did not name the stopped session"
  [ "$(sed -n 's/^running=//p' "$FAKE_STATE/registry/mbk")" = false ] \
    || fail "target session was not left stopped"
  [ "$(sed -n 's/^running=//p' "$FAKE_STATE/registry/other-kept")" = true ] \
    || fail "an unrelated protected session was disturbed"
  [ "$(sed -n 's/^running=//p' "$FAKE_STATE/registry/default")" = true ] \
    || fail "the default session was disturbed"
  pass "fm-herdr-session-retire: a clean stop leaves every other session untouched and reports success"
}

test_failed_postcondition_target_still_running_is_refused() {
  local status=0
  reset_fixture
  write_session mbk false true
  write_workspaces mbk 0
  status=0
  FM_FAKE_HERDR_STOP_INERT=1 run_with_fake fm_herdr_retire_stop mbk >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a stop call that leaves the target running must fail the postcondition check"
  pass "fm-herdr-session-retire: a target still reporting running=true after stop fails the postcondition"
}

test_failed_postcondition_protected_session_drift_is_refused() {
  local status=0 out
  reset_fixture
  write_session mbk false true
  write_workspaces mbk 0
  write_session collateral false true
  status=0
  out=$(FM_FAKE_HERDR_DRIFT_AFTER_STOP=collateral run_with_fake fm_herdr_retire_stop mbk 2>&1) || status=$?
  expect_code 1 "$status" "another session changing during the stop call must refuse to report success"
  assert_contains "$out" "refusing to report success" \
    "the postcondition drift refusal did not name itself"
  [ "$(sed -n 's/^running=//p' "$FAKE_STATE/registry/mbk")" = false ] \
    || fail "the target was not actually stopped even though success was correctly refused"
  pass "fm-herdr-session-retire: collateral drift during the stop call is refused even though the target did stop"
}

test_main_requires_exactly_one_argument() {
  local status=0
  reset_fixture
  status=0
  run_with_fake bash -c '. "'"$ROOT"'/bin/fm-herdr-session-retire.sh"; fm_herdr_retire_main' >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "no argument must print usage and exit 2"
  status=0
  run_with_fake bash -c '. "'"$ROOT"'/bin/fm-herdr-session-retire.sh"; fm_herdr_retire_main a b' \
    >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "two arguments must print usage and exit 2"
  run_with_fake bash -c '. "'"$ROOT"'/bin/fm-herdr-session-retire.sh"; fm_herdr_retire_main --help' \
    >/dev/null || fail "--help must exit 0"
  pass "fm-herdr-session-retire: main enforces exactly one argument and serves --help"
}

test_help_is_processed_as_a_session_name() {
  local out
  reset_fixture
  write_session help false true
  write_workspaces help 0
  out=$(run_with_fake "$ROOT/bin/fm-herdr-session-retire.sh" help) \
    || fail "a session named help did not reach the guarded retirement path"
  assert_contains "$out" "stopped help" "retiring a session named help did not report success"
  [ "$(sed -n 's/^running=//p' "$FAKE_STATE/registry/help")" = false ] \
    || fail "a session named help was not stopped"
  pass "fm-herdr-session-retire: help is processed as a session name"
}

test_reserved_names_are_refused_without_reaching_herdr
test_absent_target_is_refused
test_stopped_target_is_refused
test_default_flagged_target_is_refused
test_duplicate_target_rows_are_refused
test_nonempty_target_workspace_count_is_refused
test_nonempty_target_multiple_workspaces_is_refused
test_unreadable_workspace_shape_is_refused
test_protected_session_drift_between_checks_is_refused
test_race_target_becomes_nonempty_between_the_two_stop_prechecks
test_exact_stop_invocation_and_no_other_destructive_call
test_successful_postconditions_are_verified
test_failed_postcondition_target_still_running_is_refused
test_failed_postcondition_protected_session_drift_is_refused
test_main_requires_exactly_one_argument
test_help_is_processed_as_a_session_name
