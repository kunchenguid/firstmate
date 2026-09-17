#!/usr/bin/env bash
# Behavior tests for bin/fm-packet.sh: the local mechanism that records and
# checks bounded packet-scoped merge authority (AGENTS.md section 7). Covers
# the full lifecycle - open -> grant -> in/out-of-scope check -> close ->
# expired check - and the ordering guards (check before open, check before
# grant) that keep an unauthorized PR from ever reading as in-scope.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PACKET="$ROOT/bin/fm-packet.sh"
TMP_ROOT=$(fm_test_tmproot fm-packet)
NOW=2026-09-13T00:00:00Z

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

run_packet() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_PACKET_NOW="$NOW" "$PACKET" "$@"
}

test_check_before_open_refuses() {
  local home
  home=$(make_home before-open)
  if run_packet "$home" check ghost-packet --repo owner/repo \
    > "$TMP_ROOT/bo.out" 2> "$TMP_ROOT/bo.err"; then
    fail "check authorized a packet that was never opened"
  fi
  assert_grep "does not exist" "$TMP_ROOT/bo.err" "refusal did not name the missing packet"
  pass "check refuses an unknown packet"
}

test_full_lifecycle() {
  local home
  home=$(make_home lifecycle)
  run_packet "$home" open demo --repo owner/repo-a --repo owner/repo-b \
    --objective "ship the local controls" >/dev/null \
    || fail "open failed"
  assert_present "$home/data/packets/demo.record" "open did not write a record"

  if run_packet "$home" check demo --repo owner/repo-a \
    > "$TMP_ROOT/pre-grant.out" 2> "$TMP_ROOT/pre-grant.err"; then
    fail "check authorized an in-scope repo before the packet was granted"
  fi
  assert_grep "has not been granted" "$TMP_ROOT/pre-grant.err" \
    "pre-grant refusal did not name the missing grant"

  run_packet "$home" grant demo >/dev/null || fail "grant failed"

  run_packet "$home" check demo --repo owner/repo-a >/dev/null \
    || fail "an in-scope repo under a granted, open packet was refused"
  run_packet "$home" check demo --repo owner/repo-b >/dev/null \
    || fail "the second in-scope repo was refused"

  if run_packet "$home" check demo --repo owner/repo-c \
    > "$TMP_ROOT/oos.out" 2> "$TMP_ROOT/oos.err"; then
    fail "check authorized a repo outside the packet's declared scope"
  fi
  assert_grep "outside packet demo's scope" "$TMP_ROOT/oos.err" \
    "out-of-scope refusal did not name the boundary"

  run_packet "$home" close demo >/dev/null || fail "close failed"

  if run_packet "$home" check demo --repo owner/repo-a \
    > "$TMP_ROOT/expired.out" 2> "$TMP_ROOT/expired.err"; then
    fail "check authorized a repo after the packet closed"
  fi
  assert_grep "merge authority has expired" "$TMP_ROOT/expired.err" \
    "post-close refusal did not name the expiry"

  pass "the full packet lifecycle (open -> grant -> scoped check -> close -> expired) behaves as authorized"
}

test_open_refuses_duplicate() {
  local home
  home=$(make_home duplicate)
  run_packet "$home" open dup --repo owner/repo --objective "first" >/dev/null \
    || fail "first open failed"
  if run_packet "$home" open dup --repo owner/repo --objective "second" \
    > "$TMP_ROOT/dup.out" 2> "$TMP_ROOT/dup.err"; then
    fail "a second open silently replaced an existing packet"
  fi
  assert_grep "already exists" "$TMP_ROOT/dup.err" "duplicate-open refusal did not name the boundary"
  pass "open refuses to silently replace an existing packet"
}

test_close_refuses_twice() {
  local home
  home=$(make_home double-close)
  run_packet "$home" open once --repo owner/repo --objective "one shot" >/dev/null \
    || fail "open failed"
  run_packet "$home" close once >/dev/null || fail "first close failed"
  if run_packet "$home" close once \
    > "$TMP_ROOT/close2.out" 2> "$TMP_ROOT/close2.err"; then
    fail "a second close on an already-closed packet was accepted"
  fi
  assert_grep "already closed" "$TMP_ROOT/close2.err" "double-close refusal did not name the boundary"
  pass "close refuses a packet that is already closed"
}

test_grant_refuses_on_closed_packet() {
  local home
  home=$(make_home grant-after-close)
  run_packet "$home" open late --repo owner/repo --objective "too late" >/dev/null \
    || fail "open failed"
  run_packet "$home" close late >/dev/null || fail "close failed"
  if run_packet "$home" grant late \
    > "$TMP_ROOT/grant-late.out" 2> "$TMP_ROOT/grant-late.err"; then
    fail "grant succeeded on an already-closed packet"
  fi
  assert_grep "not open" "$TMP_ROOT/grant-late.err" "late-grant refusal did not name the boundary"
  pass "grant refuses a closed packet"
}

# Concurrency regression (codex review finding on PR #4344): a grant and a
# close racing the same packet's read-modify-write must serialize, so a grant
# that started before a close cannot finish after it and resurrect merge
# authority on a now-closed packet. FM_PACKET_TEST_DELAY holds the lock across
# a deliberate pause in close's own critical section, and this test starts
# grant while that pause is in flight - it must block until close's lock
# releases, then correctly refuse against the now-closed record instead of
# racing it. Before the fm-wake-lib.sh per-slug lock, close would write last
# because the delay was inserted after read but before write, and grant would
# already have finished (reading the old open record) while close slept -
# writing merge_authority=yes and status=open moments before close's own write
# landed, so the final record briefly and then durably showed a granted,
# supposedly-open packet with a cleared close timestamp.
test_concurrent_grant_and_close_serialize() {
  local home slug=race grant_out grant_err
  home=$(make_home concurrency)
  run_packet "$home" open "$slug" --repo owner/repo --objective "race check" >/dev/null \
    || fail "open failed"
  run_packet "$home" grant "$slug" >/dev/null || fail "initial grant failed"

  ( FM_HOME="$home" FM_PACKET_NOW="$NOW" FM_PACKET_TEST_DELAY=2 \
      "$PACKET" close "$slug" >"$TMP_ROOT/race-close.out" 2>"$TMP_ROOT/race-close.err" ) &
  local close_pid=$!
  # Give close time to acquire the lock and enter its delay before grant
  # attempts to acquire the same lock.
  sleep 0.5
  grant_out=$TMP_ROOT/race-grant.out
  grant_err=$TMP_ROOT/race-grant.err
  run_packet "$home" grant "$slug" > "$grant_out" 2> "$grant_err"
  local grant_rc=$?
  wait "$close_pid" || fail "close failed"

  [ "$grant_rc" -ne 0 ] || fail "a grant that raced a concurrent close was not blocked and incorrectly succeeded"
  assert_grep "is not open" "$grant_err" \
    "grant did not correctly see the packet as closed after waiting out the lock"

  local status closed authority
  status=$(run_packet "$home" show "$slug" | sed -n 's/^status=//p')
  closed=$(run_packet "$home" show "$slug" | sed -n 's/^closed=//p')
  authority=$(run_packet "$home" show "$slug" | sed -n 's/^merge_authority=//p')
  assert_equals closed "$status" "the race left the packet's status reverted to open"
  assert_not_equals "" "$closed" "the race cleared the packet's close timestamp"
  assert_equals yes "$authority" \
    "closing must not itself revoke a real prior grant, only expire it via status=closed"
  pass "a grant racing a concurrent close serializes on the packet lock instead of corrupting the record"
}

test_check_before_open_refuses
test_full_lifecycle
test_open_refuses_duplicate
test_close_refuses_twice
test_grant_refuses_on_closed_packet
test_concurrent_grant_and_close_serialize
