#!/usr/bin/env bash
# Behavior tests for durable model-capacity holds on Firstmate-controlled paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-model-capacity-hold)
HOLD="$ROOT/bin/fm-model-capacity-hold.sh"
SEND="$ROOT/bin/fm-send.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

make_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data" "$home/fakebin"
  fm_write_meta "$home/state/lane.meta" 'window=test:fm-lane' 'kind=ship' 'harness=codex'
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '1\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  send-keys) printf '%s\n' "$*" >> "$FM_HOLD_SEND_LOG" ;;
esac
SH
  fm_fake_exit0 "$home/fakebin" sleep
  chmod +x "$home/fakebin/tmux"
}

test_registered_hold_blocks_send_until_digest_bound_release() {
  local home log err authority rc
  home="$TMP_ROOT/home"
  make_home "$home"
  log="$home/send.log"
  err="$home/send.err"
  authority="$home/release-authority.txt"
  : > "$log"

  FM_HOME="$home" "$HOLD" register reserve-night \
    --reason 'captain reserved model capacity' --dispatch-ref 'cm31r2 dispatch 2026-07-31' >/dev/null \
    || fail "could not register a model-capacity hold"
  rc=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_HOLD_SEND_LOG="$log" FM_SEND_SETTLE=0 "$SEND" lane 'new model work' \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "registered model-capacity hold allowed a text steer"
  [ ! -s "$log" ] || fail "held text steer reached the backend"
  assert_grep 'model-capacity hold reserve-night is active' "$err" \
    "held send did not identify the active durable hold"

  printf 'Captain released reserve-night after the protected dispatch ended.\n' > "$authority"
  FM_HOME="$home" "$HOLD" release reserve-night --authority-file "$authority" >/dev/null \
    || fail "could not release the registered hold"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_HOLD_SEND_LOG="$log" FM_SEND_SETTLE=0 "$SEND" lane 'new model work' \
    >/dev/null 2>"$err" || fail "released hold still blocked text delivery"
  [ -s "$log" ] || fail "released send never reached the backend"
  find "$home/data/model-capacity-holds" -name 'reserve-night.registered' -type f | grep . >/dev/null \
    || fail "registration receipt disappeared on release"
  release_receipt=$(find "$home/data/model-capacity-holds" -name 'reserve-night.released' -type f | head -1)
  assert_present "$release_receipt" "release has no durable receipt"
  authority_digest=$(shasum -a 256 "$authority" | awk '{print $1}')
  assert_grep "authority_sha256=$authority_digest" "$release_receipt" \
    "release receipt is not bound to its authority object"
  pass "registered model-capacity hold blocks sends until a digest-bound release"
}

test_registered_hold_blocks_spawn_before_fleet_mutation() {
  local home err rc
  home="$TMP_ROOT/spawn-home"
  make_home "$home"
  err="$home/spawn.err"
  FM_HOME="$home" "$HOLD" register reserve-spawn \
    --reason 'capacity reserved for another dispatch' --dispatch-ref 'dispatch reserve-spawn' >/dev/null \
    || fail "could not register the spawn hold"

  rc=0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SPAWN" new-lane sample \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "registered model-capacity hold allowed a spawn"
  assert_grep 'model-capacity hold reserve-spawn is active' "$err" \
    "held spawn did not identify the active durable hold"
  assert_absent "$home/state/new-lane.meta" "held spawn mutated fleet metadata before refusing"
  assert_absent "$home/data/new-lane" "held spawn created task data before refusing"
  pass "registered model-capacity hold blocks spawn before fleet mutation"
}

test_registration_serializes_competing_hold_ids() {
  local home fakebin first_pid second_pid first_rc second_rc wait_count
  home="$TMP_ROOT/race-home"
  make_home "$home"
  fakebin="$home/hold-fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/cp" <<'SH'
#!/usr/bin/env bash
set -u
case "${2:-}" in
  *.model-capacity-hold.tmp.*)
    : > "$FM_HOLD_CP_ENTERED"
    while [ ! -e "$FM_HOLD_CP_RELEASE" ]; do sleep 0.02; done
    ;;
esac
exec /bin/cp "$@"
SH
  chmod +x "$fakebin/cp"
  first_rc="$home/first.rc"
  second_rc="$home/second.rc"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HOLD_CP_ENTERED="$home/first.entered" \
    FM_HOLD_CP_RELEASE="$home/cp.release" "$HOLD" register reserve-first \
    --reason 'first reservation' --dispatch-ref 'dispatch first' >/dev/null 2>&1 &
  first_pid=$!
  wait_count=0
  while [ ! -e "$home/first.entered" ] && [ "$wait_count" -lt 100 ]; do
    sleep 0.02
    wait_count=$((wait_count + 1))
  done
  [ -e "$home/first.entered" ] || fail "first registration never reached marker publication"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HOLD_CP_ENTERED="$home/second.entered" \
    FM_HOLD_CP_RELEASE="$home/cp.release" "$HOLD" register reserve-second \
    --reason 'second reservation' --dispatch-ref 'dispatch second' >/dev/null 2>&1 &
  second_pid=$!
  sleep 0.2
  assert_absent "$home/data/model-capacity-holds/reserve-second.registered" \
    "competing registration published a receipt before the active lifecycle completed"
  : > "$home/cp.release"
  wait "$first_pid"; printf '%s\n' "$?" > "$first_rc"
  if wait "$second_pid"; then printf '0\n' > "$second_rc"; else printf '%s\n' "$?" > "$second_rc"; fi
  [ "$(cat "$first_rc")" -eq 0 ] || fail "first serialized registration failed"
  [ "$(cat "$second_rc")" -ne 0 ] || fail "competing hold id also registered successfully"
  assert_grep 'hold_id=reserve-first' "$home/state/.model-capacity-hold" \
    "serialized registration did not retain the first active hold"
  pass "competing hold registrations serialize behind one active marker"
}

test_matching_orphan_registration_is_repaired() {
  local home receipt out
  home="$TMP_ROOT/orphan-home"
  make_home "$home"
  receipt="$home/data/model-capacity-holds/reserve-orphan.registered"
  mkdir -p "${receipt%/*}"
  {
    printf 'schema=fm-model-capacity-hold.v1\n'
    printf 'hold_id=reserve-orphan\n'
    printf 'reason=interrupted reservation\n'
    printf 'dispatch_ref=dispatch orphan\n'
    printf 'registered_at=2026-08-03T12:00:00Z\n'
  } > "$receipt"
  out=$(FM_HOME="$home" "$HOLD" register reserve-orphan \
    --reason 'interrupted reservation' --dispatch-ref 'dispatch orphan') \
    || fail "matching orphan registration was not repairable"
  assert_contains "$out" 'registered: reserve-orphan' "orphan repair did not report success"
  cmp -s "$receipt" "$home/state/.model-capacity-hold" \
    || fail "orphan repair did not publish the exact durable receipt"
  pass "matching interrupted registration receipt repairs the active marker"
}

test_matching_orphan_release_is_repaired() {
  local home authority registered receipt registration_digest authority_digest
  home="$TMP_ROOT/release-orphan-home"
  make_home "$home"
  authority="$home/release-authority.txt"
  printf 'Captain released the interrupted hold.\n' > "$authority"
  FM_HOME="$home" "$HOLD" register reserve-release \
    --reason 'release interruption' --dispatch-ref 'dispatch release' >/dev/null \
    || fail "could not prepare interrupted release"
  registered="$home/data/model-capacity-holds/reserve-release.registered"
  receipt="$home/data/model-capacity-holds/reserve-release.released"
  registration_digest=$(shasum -a 256 "$registered" | awk '{print $1}')
  authority_digest=$(shasum -a 256 "$authority" | awk '{print $1}')
  {
    printf 'schema=fm-model-capacity-hold-release.v1\n'
    printf 'hold_id=reserve-release\n'
    printf 'registration_sha256=%s\n' "$registration_digest"
    printf 'authority_path=%s\n' "$authority"
    printf 'authority_sha256=%s\n' "$authority_digest"
    printf 'released_at=2026-08-03T12:01:00Z\n'
  } > "$receipt"
  FM_HOME="$home" "$HOLD" release reserve-release --authority-file "$authority" >/dev/null \
    || fail "matching interrupted release was not repairable"
  assert_absent "$home/state/.model-capacity-hold" "repaired release left the active marker in place"
  assert_present "$home/data/model-capacity-holds/reserve-release.active-marker-retired" \
    "repaired release did not retire the active marker"
  pass "matching interrupted release receipt retires the active marker"
}

test_active_same_id_requires_matching_metadata() {
  local home out err rc receipt
  home="$TMP_ROOT/same-id-home"
  make_home "$home"
  FM_HOME="$home" "$HOLD" register reserve-shared \
    --reason 'first owner reservation' --dispatch-ref 'dispatch first owner' >/dev/null \
    || fail "could not prepare same-id retry case"
  out=$(FM_HOME="$home" "$HOLD" register reserve-shared \
    --reason 'first owner reservation' --dispatch-ref 'dispatch first owner') \
    || fail "matching same-id registration was not idempotent"
  assert_contains "$out" 'registered: reserve-shared already active' \
    "matching same-id registration did not report the active reservation"

  err="$home/reason-mismatch.err"
  rc=0
  FM_HOME="$home" "$HOLD" register reserve-shared \
    --reason 'second owner reservation' --dispatch-ref 'dispatch first owner' \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "same-id registration accepted a different reason"
  assert_grep 'active hold metadata does not match retry' "$err" \
    "same-id reason collision did not identify the metadata mismatch"

  err="$home/dispatch-mismatch.err"
  rc=0
  FM_HOME="$home" "$HOLD" register reserve-shared \
    --reason 'first owner reservation' --dispatch-ref 'dispatch second owner' \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "same-id registration accepted a different dispatch reference"
  assert_grep 'active hold metadata does not match retry' "$err" \
    "same-id dispatch collision did not identify the metadata mismatch"

  receipt="$home/data/model-capacity-holds/reserve-shared.registered"
  {
    printf 'schema=fm-model-capacity-hold.v1\n'
    printf 'hold_id=reserve-shared\n'
    printf 'reason=first owner reservation\n'
    printf 'dispatch_ref=tampered receipt owner\n'
    printf 'registered_at=2026-08-03T12:02:00Z\n'
  } > "$receipt"
  err="$home/receipt-mismatch.err"
  rc=0
  FM_HOME="$home" "$HOLD" register reserve-shared \
    --reason 'first owner reservation' --dispatch-ref 'dispatch first owner' \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "same-id registration accepted a mismatched durable receipt"
  assert_grep 'active hold registration receipt does not match retry' "$err" \
    "same-id receipt collision did not identify the durable metadata mismatch"
  pass "active same-id retries require matching reservation metadata"
}

test_registered_hold_blocks_send_until_digest_bound_release
test_registered_hold_blocks_spawn_before_fleet_mutation
test_registration_serializes_competing_hold_ids
test_matching_orphan_registration_is_repaired
test_matching_orphan_release_is_repaired
test_active_same_id_requires_matching_metadata
