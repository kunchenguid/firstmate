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

test_registered_hold_blocks_send_until_digest_bound_release
test_registered_hold_blocks_spawn_before_fleet_mutation
