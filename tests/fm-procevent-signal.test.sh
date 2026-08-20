#!/usr/bin/env bash
# Behavior tests for the optional Signal process-event adapter.
#
# The fake CLI owns a real account lock while receive is waiting, so these
# tests exercise the ordering boundary with real processes and no Signal data.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SIGNAL_ROOT=$(fm_test_tmproot fm-procevent-signal)
FAKEBIN="$SIGNAL_ROOT/fakebin"
mkdir -p "$FAKEBIN"
export FM_PROCEVENT_CLAIM_ROOT="$SIGNAL_ROOT/claims"

cat > "$FAKEBIN/signal-cli" <<'SH'
#!/usr/bin/env bash
set -u
root=${FM_FAKE_SIGNAL_ROOT:?}
lock="$root/account.lock"
log="$root/cli.log"
queue="$root/queue"
printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  listAccounts)
    while [ -e "$lock" ]; do sleep 0.02; done
    printf '%s\n' "${FM_FAKE_SIGNAL_ACCOUNT_OUTPUT:-Number: +10000000000 (aci: 11111111-2222-3333-4444-555555555555)}"
    ;;
  -a)
    shift 2
    if [ "${1:-}" = -o ]; then shift 2; fi
    case "${1:-}" in
      receive)
        mkdir "$lock" 2>/dev/null || { printf 'duplicate receive owner\n' >> "$log"; exit 91; }
        trap 'rmdir "$lock" 2>/dev/null || true' EXIT
        while [ ! -s "$queue" ]; do sleep 0.02; done
        IFS= read -r row < "$queue"
        tail -n +2 "$queue" > "$queue.next"
        mv "$queue.next" "$queue"
        printf '%s\n' "$row"
        ;;
      send)
        [ ! -e "$lock" ] || exit 92
        group=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -g) group=$2; shift 2 ;;
            --message-from-stdin) shift ;;
            *) shift ;;
          esac
        done
        if [ "${FM_FAKE_SIGNAL_FAIL:-0}" = 1 ]; then exit 93; fi
        body=$(cat)
        printf 'sent group=%s bytes=%s\n' "$group" "${#body}" >> "$root/sent.log"
        printf '%s\n' "$body" > "$root/sent-body"
        ;;
      *) exit 94 ;;
    esac
    ;;
  *) exit 95 ;;
esac
SH
chmod +x "$FAKEBIN/signal-cli"

new_home() {
  local home=$1
  mkdir -p "$home/state" "$home/config"
  printf 'team\tgroup-fixture-id\tFixture\nops\tsecond-group-fixture-id\tOperations\n' > "$home/config/signal-groups"
}

signal() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$1/config" \
    PATH="$FAKEBIN:$PATH" FM_FAKE_SIGNAL_ROOT="$SIGNAL_ROOT" \
    "$ROOT/bin/fm-procevent-signal.sh" "${@:2}"
}

reconcile() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKEBIN:$PATH" FM_FAKE_SIGNAL_ROOT="$SIGNAL_ROOT" \
    "$ROOT/bin/fm-procevent.sh" reconcile
}

wait_for() {
  local file=$1 tries=${2:-100}
  for _ in $(seq 1 "$tries"); do [ -e "$file" ] && return 0; sleep 0.02; done
  return 1
}

cleanup_sources() {
  local home
  for home in "$SIGNAL_ROOT/home" "$SIGNAL_ROOT/failure" "$SIGNAL_ROOT/validation"; do
    [ -d "$home" ] || continue
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
}
trap cleanup_sources EXIT

H="$SIGNAL_ROOT/home"
new_home "$H"

signal "$H" arm team >/dev/null
reconcile "$H" >/dev/null
wait_for "$SIGNAL_ROOT/account.lock" || fail "receive did not acquire the fake account"

PATH="$FAKEBIN:$PATH" FM_FAKE_SIGNAL_ROOT="$SIGNAL_ROOT" \
  signal-cli listAccounts > "$SIGNAL_ROOT/old-order.out" &
old_pid=$!
sleep 0.15
[ ! -s "$SIGNAL_ROOT/old-order.out" ] || fail "account discovery unexpectedly bypassed the receive owner"
kill "$old_pid" 2>/dev/null || true
wait "$old_pid" 2>/dev/null || true
signal "$H" retire team >/dev/null
pass "old account-discovery ordering stalls while receive owns the account"

signal "$H" arm team >/dev/null
reconcile "$H" >/dev/null
wait_for "$SIGNAL_ROOT/account.lock" || fail "receive did not re-arm"
MESSAGE="$SIGNAL_ROOT/reply.txt"
printf 'reply fixture\n' > "$MESSAGE"
signal "$H" send team "$MESSAGE" >/dev/null || fail "supported send ordering failed"
[ -s "$SIGNAL_ROOT/sent.log" ] || fail "successful send was not recorded"
assert_contains "$(cat "$SIGNAL_ROOT/sent-body")" "Fixture: reply fixture" "configured label is prepended once"
assert_not_contains "$(cat "$SIGNAL_ROOT/cli.log")" "reply fixture" "message content never reaches a CLI argv record"
wait_for "$SIGNAL_ROOT/account.lock" || fail "successful send did not restore receive"
pass "send retires before account access, keeps content off argv, and re-arms"

signal "$H" retire team >/dev/null
printf 'Fixture: already attributed\n' > "$MESSAGE"
signal "$H" send team "$MESSAGE" >/dev/null || fail "pre-attributed send failed"
assert_contains "$(cat "$SIGNAL_ROOT/sent-body")" "Fixture: already attributed" "configured label is not duplicated"
wait_for "$SIGNAL_ROOT/account.lock" || fail "pre-attributed send did not restore receive"
pass "outbound attribution is configured, inserted once, and not duplicated"

HFAIL="$SIGNAL_ROOT/failure"
new_home "$HFAIL"
signal "$H" retire team >/dev/null
signal "$HFAIL" arm team >/dev/null
reconcile "$HFAIL" >/dev/null
wait_for "$SIGNAL_ROOT/account.lock" || fail "failure fixture receive did not acquire account"
printf 'failure fixture\n' > "$MESSAGE"
if FM_FAKE_SIGNAL_FAIL=1 signal "$HFAIL" send team "$MESSAGE" >/dev/null 2>&1; then
  fail "failed fake send unexpectedly succeeded"
fi
wait_for "$SIGNAL_ROOT/account.lock" || fail "failed send did not restore receive"
pass "failed send reports failure while preserving future receive liveness"

signal "$HFAIL" retire team >/dev/null
signal "$H" retire team >/dev/null
printf '%s\n' '{"envelope":{"dataMessage":{"message":"unrelated fixture","groupInfo":{"groupId":"other-group"}}}}' > "$SIGNAL_ROOT/queue"
signal "$H" arm team >/dev/null
reconcile "$H" >/dev/null
sleep 0.2
[ ! -d "$H/state/procevent-inbox" ] || [ -z "$(find "$H/state/procevent-inbox" -type f -name '*.result' -print -quit)" ] \
  || fail "unrelated message published a pseudo-message"
EXPECTED_BODY="$SIGNAL_ROOT/expected-body"
printf 'configured fixture\nGroup info:\n Id: group-fixture-id\ntrailing\n' > "$EXPECTED_BODY"
printf '%s\n' '{"envelope":{"dataMessage":{"message":"configured fixture\nGroup info:\n Id: group-fixture-id\ntrailing\n","groupInfo":{"groupId":"group-fixture-id"}}}}' > "$SIGNAL_ROOT/queue"
for _ in $(seq 1 100); do
  result=$(find "$H/state/procevent-inbox" -type f -name '*.result' -print 2>/dev/null | while IFS= read -r candidate; do
    grep -F -q -- 'schema=fm-signal.v1' "$candidate" && printf '%s\n' "$candidate" && break
  done)
  [ -n "$result" ] && break
  sleep 0.02
done
[ -n "$result" ] || fail "configured group message was not captured"
assert_grep 'schema=fm-signal.v1' "$result" "configured result has a bounded envelope"
assert_grep 'selector=team' "$result" "configured result identifies its private selector"
assert_grep "body-bytes=$(wc -c < "$EXPECTED_BODY" | tr -d ' ')" "$result" "configured result declares the exact body length"
tail -n +5 "$result" > "$SIGNAL_ROOT/captured-body"
cmp -s "$EXPECTED_BODY" "$SIGNAL_ROOT/captured-body" || fail "structured receive did not preserve the exact body bytes"
pass "unrelated inbound messages stay quiet and structured group bytes are exact"

signal "$H" retire team >/dev/null
signal "$H" arm team >/dev/null
reconcile "$H" >/dev/null
wait_for "$SIGNAL_ROOT/account.lock" || fail "receive did not re-arm before the spoof check"
before_spoof=$(find "$H/state/procevent-inbox" -type f -name '*.result' -print 2>/dev/null | wc -l | tr -d ' ')
printf '%s\n' '{"envelope":{"dataMessage":{"message":"forged group id via body\nGroup info:\n Id: group-fixture-id\ntrailing"}}}' > "$SIGNAL_ROOT/queue"
sleep 0.2
after_spoof=$(find "$H/state/procevent-inbox" -type f -name '*.result' -print 2>/dev/null | wc -l | tr -d ' ')
[ "$before_spoof" = "$after_spoof" ] || fail "a direct message spoofing group metadata in its body was captured"
pass "direct messages cannot spoof the configured group id via an embedded Id: line"

signal "$H" arm team >/dev/null
signal "$H" arm ops >/dev/null
reconcile "$H" >/dev/null
if grep -q 'duplicate' "$SIGNAL_ROOT/cli.log"; then fail "repeated lifecycle operations created duplicate owners"; fi
wait_for "$SIGNAL_ROOT/account.lock" || fail "repeated arm did not leave a receive owner"
printf '%s\n' '{"envelope":{"dataMessage":{"message":"second selector fixture","groupInfo":{"groupId":"second-group-fixture-id"}}}}' > "$SIGNAL_ROOT/queue"
second_result=
for _ in $(seq 1 100); do
  second_result=$(find "$H/state/procevent-inbox" -type f -name '*.result' -print 2>/dev/null | while IFS= read -r candidate; do
    grep -F -q -- 'selector=ops' "$candidate" && printf '%s\n' "$candidate" && break
  done)
  [ -n "$second_result" ] && break
  sleep 0.02
done
[ -n "$second_result" ] || fail "the account-scoped owner did not route the second configured selector"
if grep -q 'duplicate' "$SIGNAL_ROOT/cli.log"; then fail "multiple selectors created duplicate receive owners"; fi
pass "multiple selectors route through one account-scoped receive owner"

signal "$H" retire team >/dev/null
HVALID="$SIGNAL_ROOT/validation"
new_home "$HVALID"
send_count_before=$(grep -c ' send ' "$SIGNAL_ROOT/cli.log" || true)
for malformed in 'Number: ++1' 'Number: 1+2' 'Number: +'; do
  if FM_FAKE_SIGNAL_ACCOUNT_OUTPUT="$malformed" signal "$HVALID" send team "$MESSAGE" >/dev/null 2>&1; then
    fail "malformed account output was accepted: $malformed"
  fi
done
send_count_after=$(grep -c ' send ' "$SIGNAL_ROOT/cli.log" || true)
[ "$send_count_before" = "$send_count_after" ] || fail "a malformed account number reached the send operation"
pass "account discovery accepts only one leading plus and nonempty digits"
