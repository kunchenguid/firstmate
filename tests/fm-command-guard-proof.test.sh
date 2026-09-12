#!/usr/bin/env bash
# Command guard proof and mutation-boundary coverage for fm-send and fm-control.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-command-guard-proof)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_tmux() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'literal=%s:%s\n' "$literal" "${1:-}" >> "$FM_GUARD_SEND_LOG"
    if [ "$literal" = 1 ]; then
      exit 0
    fi
    exit 0
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) printf 'claude\n'; exit 0 ;;
      esac
    done
    printf 'fake\n'
    ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'fm-t1\n' ;;
esac
SH
  chmod +x "$dir/fakebin/tmux"
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/sleep"
}

new_home() {
  local name=$1 dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state"
  make_tmux "$dir"
  printf '%s\n' "$dir"
}

write_send_meta() {
  local dir=$1
  cat > "$dir/home/state/t1.meta" <<EOF
window=sess:fm-t1
kind=ship
harness=claude
spawn_gen=gen-1
EOF
}

run_send() {
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_GUARD_SEND_LOG="$dir/send.log" FM_SEND_SETTLE=0 "$@"
}

test_probe_protocol() {
  local dir out rc before after
  dir=$(new_home probe)
  before=$(find "$dir/home/state" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  out=$(FM_HOME="$dir/home" "$SEND" --guard-capabilities --json); rc=$?
  expect_code 0 "$rc" "send capability probe should succeed"
  [ "$out" = '{"schema":"fm-command-guard-proof.v1","command":"send","verified":true,"guards":["spawn-generation","endpoint","remote-host"]}' ] \
    || fail "send proof has the wrong exact shape: $out"
  out=$(FM_HOME="$dir/home" "$CONTROL" --guard-capabilities --json); rc=$?
  expect_code 0 "$rc" "control capability probe should succeed"
  [ "$out" = '{"schema":"fm-command-guard-proof.v1","command":"control","verified":true,"guards":["spawn-generation"]}' ] \
    || fail "control proof has the wrong exact shape: $out"
  after=$(find "$dir/home/state" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  [ "$before" = "$after" ] || fail "the probe created state: before=<$before> after=<$after>"
  out=$(FM_HOME="$dir/home" "$SEND" --guard-capabilities --json extra 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "an inexact send probe was accepted"
  [ -z "$out" ] || fail "an inexact send probe emitted positive proof: $out"
  out=$(FM_HOME="$dir/home" "$CONTROL" --guard-capabilities 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "an inexact control probe was accepted"
  [ -z "$out" ] || fail "an inexact control probe emitted positive proof: $out"
  pass "command guard proof: exact probes emit deterministic JSON and create no state"
}

test_send_generation_and_endpoint_guards() {
  local dir rc
  dir=$(new_home send-guards); write_send_meta "$dir"; : > "$dir/send.log"
  run_send "$dir" env FM_SEND_EXPECTED_SPAWN_GEN=gen-1 FM_SEND_EXPECTED_ENDPOINT=sess:fm-t1 \
    "$SEND" t1 "matching steer" >/dev/null 2>"$dir/err"; rc=$?
  expect_code 0 "$rc" "matching send guards should allow an inbox send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "matching send guards did not enqueue"

  rm -rf "$dir/home/state/t1.inbox" "$dir/home/state/pending-replies"
  : > "$dir/send.log"
  run_send "$dir" env FM_SEND_EXPECTED_SPAWN_GEN=stale \
    "$SEND" t1 "stale generation" >/dev/null 2>"$dir/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a stale generation was accepted"
  [ ! -e "$dir/home/state/t1.inbox/001.msg" ] || fail "stale generation created an inbox record"
  [ ! -s "$dir/send.log" ] || fail "stale generation rang a doorbell"

  run_send "$dir" env FM_SEND_EXPECTED_ENDPOINT=stale:sess \
    "$SEND" t1 "stale endpoint" >/dev/null 2>"$dir/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a stale endpoint was accepted"
  [ ! -e "$dir/home/state/t1.inbox/001.msg" ] || fail "stale endpoint created an inbox record"
  [ ! -s "$dir/send.log" ] || fail "stale endpoint reached the backend"

  run_send "$dir" "$SEND" t1 "ordinary steer" >/dev/null 2>"$dir/err"; rc=$?
  expect_code 0 "$rc" "unset guards should preserve ordinary behavior"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "unset guards changed ordinary behavior"
  pass "fm-send guards: generation and endpoint mismatches refuse before durable delivery"
}

test_send_typed_path_guard() {
  local dir rc
  dir=$(new_home send-typed); write_send_meta "$dir"; : > "$dir/send.log"
  run_send "$dir" env FM_SEND_EXPECTED_SPAWN_GEN=gen-1 FM_SEND_EXPECTED_ENDPOINT=sess:fm-t1 \
    "$SEND" t1 /typed-command >/dev/null 2>"$dir/err"; rc=$?
  expect_code 0 "$rc" "matching typed task-selector guards should allow submission"
  assert_contains "$(cat "$dir/send.log")" "/typed-command" "typed task-selector did not reach the backend"

  : > "$dir/send.log"
  run_send "$dir" env FM_SEND_EXPECTED_ENDPOINT=stale:sess \
    "$SEND" t1 /stale-command >/dev/null 2>"$dir/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a stale endpoint was accepted on the typed path"
  [ ! -s "$dir/send.log" ] || fail "stale typed endpoint reached the backend"

  : > "$dir/send.log"
  run_send "$dir" env FM_SEND_EXPECTED_ENDPOINT=outside-ledger \
    "$SEND" sess:external "explicit target" >/dev/null 2>"$dir/err"; rc=$?
  expect_code 0 "$rc" "the explicit backend-target escape hatch should remain ordinary"
  assert_contains "$(cat "$dir/send.log")" "explicit target" "the explicit backend target did not receive its text"
  pass "fm-send guards: typed task selectors are guarded and explicit targets stay outside the proof"
}

test_generation_races_refuse_after_snapshot() {
  local dir lock marker release holder sender rc i
  dir=$(new_home send-race); write_send_meta "$dir"; : > "$dir/send.log"
  lock="$dir/home/state/.meta-t1.lock"; marker="$dir/locked"; release="$dir/release"
  bash -c '
    . "$1"
    fm_task_inbox_lock_acquire "$2" || exit 91
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.02; done
    while [ ! -e "$5" ]; do sleep 0.02; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$lock" "$marker" "$release" "$dir/home/state/t1.meta" &
  holder=$!
  i=0
  while [ ! -e "$marker" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ -e "$marker" ] || fail "send race lock holder did not start"
  run_send "$dir" env FM_SEND_EXPECTED_SPAWN_GEN=gen-1 FM_SEND_EXPECTED_ENDPOINT=sess:fm-t1 \
    "$SEND" t1 "race steer" >"$dir/out" 2>"$dir/err" &
  sender=$!
  sleep 0.1
  sed -i 's/^window=.*/window=sess:fm-t2/; s/^spawn_gen=.*/spawn_gen=gen-2/' "$dir/home/state/t1.meta"
  : > "$release"
  wait "$sender" || rc=$?
  wait "$holder" || fail "send race lock holder failed"
  [ "${rc:-0}" -ne 0 ] || fail "send acted on metadata replaced after the client snapshot"
  [ ! -e "$dir/home/state/t1.inbox/001.msg" ] || fail "send race created an inbox record"
  [ ! -s "$dir/send.log" ] || fail "send race reached the backend"

  dir=$(new_home control-race)
  mkdir -p "$dir/home/data"
  cat > "$dir/home/state/t1.meta" <<EOF
window=sess:fm-t1
spawn_gen=gen-1
EOF
  lock="$dir/home/state/.meta-t1.lock"; marker="$dir/locked"; release="$dir/release"
  bash -c '
    . "$1"
    fm_task_inbox_lock_acquire "$2" || exit 91
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.02; done
    while [ ! -e "$5" ]; do sleep 0.02; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$lock" "$marker" "$release" "$dir/home/state/t1.meta" &
  holder=$!
  i=0
  while [ ! -e "$marker" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ -e "$marker" ] || fail "control race lock holder did not start"
  rc=0
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_GUARD_SEND_LOG="$dir/send.log" FM_CONTROL_EXPECTED_SPAWN_GEN=gen-1 \
    "$CONTROL" t1 interrupt >"$dir/out" 2>"$dir/err" &
  sender=$!
  sleep 0.1
  sed -i 's/^spawn_gen=.*/spawn_gen=gen-2/' "$dir/home/state/t1.meta"
  : > "$release"
  wait "$sender" || rc=$?
  wait "$holder" || fail "control race lock holder failed"
  [ "${rc:-0}" -ne 0 ] || fail "control acted on metadata replaced after the client snapshot"
  [ ! -s "$dir/send.log" ] || fail "control race reached the backend"
  pass "command guard races: metadata replacement after the client snapshot is refused before mutation"
}

test_control_generation_guard() {
  local dir rc out
  dir=$(new_home control-guards)
  mkdir -p "$dir/home/data"
  cat > "$dir/home/state/t1.meta" <<EOF
window=sess:fm-t1
spawn_gen=gen-1
EOF
  : > "$dir/send.log"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_GUARD_SEND_LOG="$dir/send.log" FM_CONTROL_EXPECTED_SPAWN_GEN=stale \
    "$CONTROL" t1 interrupt 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a stale control generation was accepted"
  [ ! -s "$dir/send.log" ] || fail "stale control generation sent lifecycle bytes"

  sed -i '/^spawn_gen=/d' "$dir/home/state/t1.meta"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_GUARD_SEND_LOG="$dir/send.log" FM_CONTROL_EXPECTED_SPAWN_GEN=gen-1 \
    "$CONTROL" t1 interrupt 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "missing current control generation was accepted"
  [ "$out" != *"interrupt key"* ] || fail "missing generation reached lifecycle validation"
  pass "fm-control guard: stale and missing generations refuse before lifecycle bytes"
}

test_probe_protocol
test_send_generation_and_endpoint_guards
test_send_typed_path_guard
test_generation_races_refuse_after_snapshot
test_control_generation_guard
