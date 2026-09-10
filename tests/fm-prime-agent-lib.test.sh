#!/usr/bin/env bash
# tests/fm-prime-agent-lib.test.sh - cwd-scoped retirement of prime-agent's
# detached daemon sessions (bin/fm-prime-agent-lib.sh), which teardown runs
# before its generic leaked-process reaper.
#
# The load-bearing contract:
#   1. Only sessions whose recorded cwd IS the directory or lives INSIDE it are
#      stopped. A sibling directory that merely shares a name prefix, and any
#      other home's session, must survive - the daemon is fleet-wide, so a
#      wrong selection would kill the captain's own work.
#   2. A missing prime-agent binary is a silent no-op, while every failure to
#      list, validate, or stop an available daemon is reported as unconfirmed
#      retirement so teardown can preserve the target.
#   3. A session id that is not a plain token makes the whole retirement
#      unconfirmed and is never handed to the CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot prime-agent-lib)

# fake_prime_agent <dir> <list-stdout> [list-exit] [stop-exit]
#                  [list-delay] [stop-delay]
# Installs a `prime-agent` stub on PATH that answers `list --json` with the
# given payload and appends every other invocation to <dir>/calls.
fake_prime_agent() {
  local dir=$1 listing=$2 list_exit=${3:-0} stop_exit=${4:-0}
  local list_delay=${5:-0} stop_delay=${6:-0} fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '%s' "$listing" > "$dir/listing.json"
  cat > "$fakebin/prime-agent" <<SH
#!/usr/bin/env bash
if [ "\$1" = list ]; then
  [ "$list_delay" = 0 ] || sleep "$list_delay"
  cat "$dir/listing.json"
  exit $list_exit
fi
printf '%s\n' "\$*" >> "$dir/calls"
[ "$stop_delay" = 0 ] || sleep "$stop_delay"
exit $stop_exit
SH
  chmod +x "$fakebin/prime-agent"
  : > "$dir/calls"
  printf '%s\n' "$fakebin"
}

# run_stop_under <dir> <target> <fakebin>
run_stop_under() {
  local dir=$1 target=$2 fakebin=$3
  PATH="$fakebin:$PATH" FM_PRIME_AGENT_CLI_TIMEOUT="${FM_PRIME_AGENT_CLI_TIMEOUT:-5}" bash -c '
    set -u
    . "$1"
    fm_prime_agent_stop_sessions_under "$2"
  ' _ "$ROOT/bin/fm-prime-agent-lib.sh" "$target" > "$dir/stop.out" 2> "$dir/stop.err"
}

# stop_under <dir> <target> -> echoes the stub's recorded calls.
stop_under() {
  local dir=$1 target=$2 fakebin=$3
  run_stop_under "$dir" "$target" "$fakebin" \
    || fail "expected retirement success, got: $(cat "$dir/stop.err")"
  cat "$dir/calls"
}

session() {  # <id> <cwd>
  printf '{"id":"%s","cwd":"%s"}' "$1" "$2"
}

test_only_sessions_under_the_directory_are_stopped() {
  local dir target fakebin calls
  dir="$TMP_ROOT/scope"; mkdir -p "$dir"
  target="$dir/wt"; mkdir -p "$target/nested"
  # A sibling whose path shares the target's prefix is the case a naive
  # `startswith($dir)` gets wrong, so it is pinned explicitly.
  mkdir -p "$dir/wt-other"
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[
    $(session inside "$target"),
    $(session nested "$target/nested"),
    $(session sibling "$dir/wt-other"),
    $(session elsewhere "$dir")
  ]}")
  calls=$(stop_under "$dir" "$target" "$fakebin")
  [ "$calls" = "stop inside
stop nested" ] || fail "expected only the target's own and nested sessions to stop, got: $calls"
  pass "fm_prime_agent_stop_sessions_under: stops the directory's own and nested sessions, never a prefix sibling"
}

test_a_symlinked_target_matches_either_recorded_form() {
  local dir target link fakebin calls
  # The fixture root itself must be physical, or the recorded "physical" cwd
  # below would carry a logical prefix that no launch ever produces (macOS
  # puts TMPDIR under /var, a symlink to /private/var).
  dir="$(cd "$TMP_ROOT" && pwd -P)/symlinked"; mkdir -p "$dir"
  target="$dir/real"; mkdir -p "$target"
  link="$dir/link"; ln -s "$target" "$link"
  # prime-agent records whichever form the session was launched under, so a
  # worktree reached through a symlinked prefix must retire either way or it
  # goes back to the pool with a live worker still on it.
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[
    $(session logical "$link"),
    $(session physical "$target")
  ]}")
  calls=$(stop_under "$dir" "$link" "$fakebin")
  [ "$calls" = "stop logical
stop physical" ] || fail "expected both recorded forms of the symlinked target to stop, got: $calls"
  pass "fm_prime_agent_stop_sessions_under: a symlinked target stops sessions recorded under either form"
}

test_missing_binary_is_a_silent_no_op() {
  local dir status err
  dir="$TMP_ROOT/nobinary"; mkdir -p "$dir/fakebin"
  # jq is reachable and nothing else is, so no prime-agent installed to a user
  # prefix can stand in for the absent one and the jq guard cannot answer for
  # the binary guard. A machine without prime-agent is exactly the machine
  # teardown must not fail on, and "silent" is half the contract: reaching the
  # CLI at all would put a "command not found" on teardown's stderr.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/jq"
  chmod +x "$dir/fakebin/jq"
  ln -sf "$(command -v dirname)" "$dir/fakebin/dirname"
  # shellcheck disable=SC2016  # the positional args are the inner shell's.
  err=$(PATH="$dir/fakebin" "$BASH" -c '
    set -u
    . "$1"
    fm_prime_agent_stop_sessions_under "$2"
  ' _ "$ROOT/bin/fm-prime-agent-lib.sh" "$dir" 2>&1 >/dev/null)
  status=$?
  [ "$status" -eq 0 ] || fail "a missing prime-agent binary must be a silent no-op, got exit $status"
  [ -z "$err" ] || fail "a missing prime-agent binary must stay silent, got: $err"
  pass "fm_prime_agent_stop_sessions_under: a missing prime-agent binary is a silent no-op"
}

test_listing_failure_is_unconfirmed() {
  local dir fakebin rc
  dir="$TMP_ROOT/listing-failure"; mkdir -p "$dir"
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[$(session x "$dir")]}" 9)
  run_stop_under "$dir" "$dir" "$fakebin"; rc=$?
  expect_code 75 "$rc" "a failed listing must make retirement unconfirmed"
  assert_grep "prime-agent list --json failed with exit 9" "$dir/stop.err" \
    "listing failure did not report the concrete command status"
  [ ! -s "$dir/calls" ] || fail "a failed listing still attempted a stop"
  pass "fm_prime_agent_stop_sessions_under: a failed listing reports unconfirmed retirement"
}

test_invalid_listing_data_is_unconfirmed() {
  local dir fakebin rc case_id
  for case_id in unparseable shapeless; do
    dir="$TMP_ROOT/listing-$case_id"; mkdir -p "$dir"
    case "$case_id" in
      unparseable) fakebin=$(fake_prime_agent "$dir" 'not json at all') ;;
      shapeless) fakebin=$(fake_prime_agent "$dir" '{"sessions":"not-an-array"}') ;;
    esac
    run_stop_under "$dir" "$dir" "$fakebin"; rc=$?
    expect_code 75 "$rc" "invalid listing data ($case_id) must make retirement unconfirmed"
    assert_grep "invalid JSON or session shape" "$dir/stop.err" \
      "invalid listing data ($case_id) did not report its validation failure"
    [ ! -s "$dir/calls" ] || fail "invalid listing data ($case_id) still attempted a stop"
  done
  pass "fm_prime_agent_stop_sessions_under: invalid JSON and session shapes report unconfirmed retirement"
}

test_unsafe_session_id_is_unconfirmed() {
  local dir fakebin rc
  dir="$TMP_ROOT/unsafe-id"; mkdir -p "$dir"
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[
    $(session good-1 "$dir"),
    $(session '--all' "$dir")
  ]}")
  run_stop_under "$dir" "$dir" "$fakebin"; rc=$?
  expect_code 75 "$rc" "an unsafe session id must make retirement unconfirmed"
  assert_grep "invalid matching session id" "$dir/stop.err" \
    "unsafe session id did not report its validation failure"
  [ ! -s "$dir/calls" ] || fail "an unsafe id allowed a partial stop: $(cat "$dir/calls")"
  pass "fm_prime_agent_stop_sessions_under: an unsafe session id refuses the whole retirement"
}

test_stop_failure_is_unconfirmed() {
  local dir fakebin rc
  dir="$TMP_ROOT/stop-failure"; mkdir -p "$dir"
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[$(session stop-fail "$dir")]}" 0 17)
  run_stop_under "$dir" "$dir" "$fakebin"; rc=$?
  expect_code 75 "$rc" "a failed stop must make retirement unconfirmed"
  assert_grep "prime-agent stop stop-fail failed with exit 17" "$dir/stop.err" \
    "stop failure did not report the concrete command status"
  [ "$(cat "$dir/calls")" = "stop stop-fail" ] || fail "stop failure did not drive the CLI"
  pass "fm_prime_agent_stop_sessions_under: a failed stop reports unconfirmed retirement"
}

test_cli_timeouts_are_unconfirmed() {
  local dir fakebin rc
  dir="$TMP_ROOT/list-timeout"; mkdir -p "$dir"
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[$(session slow-list "$dir")]}" 0 0 2)
  FM_PRIME_AGENT_CLI_TIMEOUT=1 run_stop_under "$dir" "$dir" "$fakebin"; rc=$?
  expect_code 75 "$rc" "a list timeout must make retirement unconfirmed"
  assert_grep "prime-agent list --json timed out after 1s" "$dir/stop.err" \
    "list timeout did not report the concrete deadline"

  dir="$TMP_ROOT/stop-timeout"; mkdir -p "$dir"
  fakebin=$(fake_prime_agent "$dir" "{\"sessions\":[$(session slow-stop "$dir")]}" 0 0 0 2)
  FM_PRIME_AGENT_CLI_TIMEOUT=1 run_stop_under "$dir" "$dir" "$fakebin"; rc=$?
  expect_code 75 "$rc" "a stop timeout must make retirement unconfirmed"
  assert_grep "prime-agent stop slow-stop timed out after 1s" "$dir/stop.err" \
    "stop timeout did not report the concrete deadline"
  pass "fm_prime_agent_stop_sessions_under: list and stop timeouts report unconfirmed retirement"
}

test_only_sessions_under_the_directory_are_stopped
test_a_symlinked_target_matches_either_recorded_form
test_missing_binary_is_a_silent_no_op
test_listing_failure_is_unconfirmed
test_invalid_listing_data_is_unconfirmed
test_unsafe_session_id_is_unconfirmed
test_stop_failure_is_unconfirmed
test_cli_timeouts_are_unconfirmed
