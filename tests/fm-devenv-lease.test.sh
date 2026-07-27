#!/usr/bin/env bash
# fm-devenv-lease.test.sh - atomic generation-token lease ownership.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

LIB="$ROOT/bin/fm-devenv-lease-lib.sh"
# shellcheck source=/dev/null
[ ! -f "$LIB" ] || . "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-devenv-lease)
LEASE_DIR="$TMP_ROOT/reviews"
MARKER="$LEASE_DIR/lease.json"
TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STALE_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ISSUED_AT=2026-07-27T12:00:00Z
mkdir -p "$LEASE_DIR"

fm_devenv_new_token() {
  printf '%s\n' "$TOKEN"
}

mode_of() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

reset_marker() {
  rm -rf "$MARKER" "$MARKER.lock"
  find "$LEASE_DIR" -maxdepth 1 -name '.lease.json.tmp.*' -delete
}

claim_marker() {
  fm_devenv_lease_claim \
    "$MARKER" reviews expanly-reviews fm-example fm/fm-example "$ISSUED_AT"
}

assert_exact_lease() {
  local expected_state=$1
  jq -e \
    --arg token "$TOKEN" \
    --arg state "$expected_state" \
    'keys == ["branch","environment","generation_token","issued_at","lease_state","schema","task_id","vm"]
      and .schema == "firstmate.devenv.lease.v1"
      and .generation_token == $token
      and (.generation_token | test("^[0-9a-f]{64}$"))
      and .environment == "reviews"
      and .vm == "expanly-reviews"
      and .task_id == "fm-example"
      and .branch == "fm/fm-example"
      and .lease_state == $state
      and .issued_at == "2026-07-27T12:00:00Z"' \
    "$MARKER" >/dev/null || fail "lease marker does not match the exact durable schema"
  [ "$(mode_of "$MARKER")" = 600 ] || fail "lease marker mode is not 0600"
}

assert_no_publish_temp() {
  local leaked
  leaked=$(find "$LEASE_DIR" -maxdepth 1 -name '.lease.json.tmp.*' -print -quit)
  [ -z "$leaked" ] || fail "lease mutation leaked a publication temp: $leaked"
}

test_new_token_uses_32_random_bytes() {
  local token
  token=$(bash -c '. "$1"; fm_devenv_new_token' _ "$LIB") \
    || fail "random token generation failed"
  printf '%s\n' "$token" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' \
    || fail "random token is not 64 lowercase hex characters: $token"
  pass "devenv lease: token contains 32 bytes encoded as lowercase hex"
}

test_claim_publishes_exact_marker_and_refuses_duplicates() {
  local token before rc
  reset_marker
  token=$(claim_marker) || fail "unleased environment could not be claimed"
  [ "$token" = "$TOKEN" ] || fail "claim did not use the post-source token override"
  assert_exact_lease leased
  assert_no_publish_temp
  before=$(cat "$MARKER")
  claim_marker >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate claim was accepted"
  [ "$(cat "$MARKER")" = "$before" ] || fail "duplicate claim changed the existing lease"
  pass "devenv lease: claim publishes the exact private marker and refuses duplicates"
}

test_concurrent_claim_has_one_winner() {
  local wins pids pid i
  reset_marker
  : > "$TMP_ROOT/claim-wins"
  pids=
  i=1
  while [ "$i" -le 20 ]; do
    bash -c '
      . "$1"
      fm_devenv_new_token() { printf "%064d\n" "$2"; }
      fm_devenv_lease_claim "$3" reviews expanly-reviews fm-example fm/fm-example 2026-07-27T12:00:00Z >/dev/null
    ' _ "$LIB" "$i" "$MARKER" >/dev/null 2>&1 && printf '%s\n' "$i" >> "$TMP_ROOT/claim-wins" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { count++ } END { print count + 0 }' "$TMP_ROOT/claim-wins")
  [ "$wins" = 1 ] || fail "concurrent claim produced $wins winners instead of one"
  fm_devenv_lease_read "$MARKER" >/dev/null || fail "winning concurrent claim is unreadable"
  assert_no_publish_temp
  pass "devenv lease: concurrent claim produces exactly one durable winner"
}

test_transition_requires_the_exact_token() {
  local before rc
  reset_marker
  claim_marker >/dev/null || fail "transition fixture claim failed"
  before=$(cat "$MARKER")
  fm_devenv_lease_transition "$MARKER" "$STALE_TOKEN" takeover >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "stale token transitioned a lease"
  [ "$(cat "$MARKER")" = "$before" ] || fail "stale-token transition changed the marker"
  fm_devenv_lease_transition "$MARKER" "$TOKEN" takeover \
    || fail "exact token could not transition the lease"
  assert_exact_lease takeover
  assert_no_publish_temp
  pass "devenv lease: transition requires the exact generation token"
}

test_release_requires_the_exact_token() {
  local before rc
  reset_marker
  claim_marker >/dev/null || fail "release fixture claim failed"
  before=$(cat "$MARKER")
  fm_devenv_lease_release "$MARKER" "$STALE_TOKEN" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "stale token released a lease"
  [ "$(cat "$MARKER")" = "$before" ] || fail "stale-token release changed the marker"
  fm_devenv_lease_release "$MARKER" "$TOKEN" || fail "exact token could not release the lease"
  [ ! -e "$MARKER" ] || fail "exact-token release left the lease marker"
  assert_no_publish_temp
  pass "devenv lease: release requires the exact generation token"
}

test_missing_and_invalid_markers_are_distinct() {
  local rc before
  reset_marker
  fm_devenv_lease_read "$MARKER" >/dev/null 2>&1
  rc=$?
  expect_code 3 "$rc" "missing lease marker"

  printf '{\n' > "$MARKER"
  before=$(cat "$MARKER")
  fm_devenv_lease_read "$MARKER" >/dev/null 2>&1
  rc=$?
  expect_code 4 "$rc" "malformed lease marker"
  claim_marker >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "malformed marker was treated as unleased"
  [ "$(cat "$MARKER")" = "$before" ] || fail "claim replaced a malformed marker"

  rm -f "$MARKER"
  mkdir "$MARKER"
  fm_devenv_lease_read "$MARKER" >/dev/null 2>&1
  rc=$?
  expect_code 4 "$rc" "unreadable lease marker"
  claim_marker >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable marker was treated as unleased"
  [ -d "$MARKER" ] || fail "claim replaced an unreadable marker"
  pass "devenv lease: only a missing marker is considered unleased"
}

test_lock_timeout_leaves_state_unchanged() {
  local before rc
  reset_marker
  claim_marker >/dev/null || fail "lock-timeout fixture claim failed"
  before=$(cat "$MARKER")
  fm_lock_try_acquire "$MARKER.lock" || fail "lock-timeout fixture could not hold the lease lock"
  FM_DEVENV_LEASE_LOCK_TIMEOUT=0 \
    fm_devenv_lease_transition "$MARKER" "$TOKEN" takeover >/dev/null 2>&1
  rc=$?
  fm_lock_release "$MARKER.lock"
  [ "$rc" -ne 0 ] || fail "lease mutation ignored its lock timeout"
  [ "$(cat "$MARKER")" = "$before" ] || fail "lock timeout changed the lease marker"
  assert_no_publish_temp
  pass "devenv lease: lock timeout leaves durable state unchanged"
}

test_new_token_uses_32_random_bytes
test_claim_publishes_exact_marker_and_refuses_duplicates
test_concurrent_claim_has_one_winner
test_transition_requires_the_exact_token
test_release_requires_the_exact_token
test_missing_and_invalid_markers_are_distinct
test_lock_timeout_leaves_state_unchanged
