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
list_count_file="$root/list-count"
printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  listAccounts)
    while [ -e "$lock" ]; do sleep 0.02; done
    list_count=0
    [ ! -f "$list_count_file" ] || IFS= read -r list_count < "$list_count_file"
    list_count=$((list_count + 1))
    printf '%s\n' "$list_count" > "$list_count_file"
    if [ "${FM_FAKE_SIGNAL_FAIL_LIST_AT:-0}" = "$list_count" ]; then exit 96; fi
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
        body=$(cat)
        printf 'private-cli-metadata-fixture\n'
        printf 'private-cli-error-fixture\n' >&2
        if [ "${FM_FAKE_SIGNAL_FAIL:-0}" = 1 ]; then exit 93; fi
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
  for home in "$SIGNAL_ROOT/home" "$SIGNAL_ROOT/failure" "$SIGNAL_ROOT/validation" \
    "$SIGNAL_ROOT/rearm-failure" "$SIGNAL_ROOT/invalid-config"; do
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
if FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_READY_TOKEN=wrong-generation \
  "$ROOT/bin/fm-procevent.sh" ready signal-account >/dev/null 2>&1; then
  fail "a foreign runner generation marked the Signal source ready"
fi
if FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_READY_TOKEN=wrong-generation \
  "$ROOT/bin/fm-procevent.sh" unready signal-account >/dev/null 2>&1; then
  fail "a foreign runner generation cleared Signal readiness"
fi
[ -d "$SIGNAL_ROOT/account.lock" ] || fail "foreign readiness calls disturbed the live receive"
pass "only the owning runner generation can change source readiness"

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
signal "$H" send team "$MESSAGE" > "$SIGNAL_ROOT/send.out" 2> "$SIGNAL_ROOT/send.err" \
  || fail "supported send ordering failed"
[ -s "$SIGNAL_ROOT/sent.log" ] || fail "successful send was not recorded"
assert_contains "$(cat "$SIGNAL_ROOT/sent-body")" "Fixture: reply fixture" "configured label is prepended once"
assert_not_contains "$(cat "$SIGNAL_ROOT/cli.log")" "reply fixture" "message content never reaches a CLI argv record"
[ "$(cat "$SIGNAL_ROOT/send.out")" = "sent: Signal message" ] || fail "send did not emit only its sanitized success status"
[ ! -s "$SIGNAL_ROOT/send.err" ] || fail "successful send exposed unexpected stderr"
[ -d "$SIGNAL_ROOT/account.lock" ] || fail "successful send returned before receive became active"
pass "send retires before account access, keeps content private, and restores listening"

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
if FM_FAKE_SIGNAL_FAIL=1 signal "$HFAIL" send team "$MESSAGE" \
  > "$SIGNAL_ROOT/failure.out" 2> "$SIGNAL_ROOT/failure.err"; then
  fail "failed fake send unexpectedly succeeded"
fi
[ ! -s "$SIGNAL_ROOT/failure.out" ] || fail "failed send exposed unexpected stdout"
assert_grep 'error: Signal send failed or timed out' "$SIGNAL_ROOT/failure.err" "failed send reports a sanitized adapter error"
assert_not_contains "$(cat "$SIGNAL_ROOT/failure.out" "$SIGNAL_ROOT/failure.err")" "private-cli" "failed signal-cli output stays private"
[ -d "$SIGNAL_ROOT/account.lock" ] || fail "failed send returned before receive became active"
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
  if FM_SIGNAL_COMMAND_TIMEOUT=1 FM_FAKE_SIGNAL_ACCOUNT_OUTPUT="$malformed" \
    signal "$HVALID" send team "$MESSAGE" >/dev/null 2>&1; then
    fail "malformed account output was accepted: $malformed"
  fi
done
if FM_SIGNAL_COMMAND_TIMEOUT=1 \
  FM_FAKE_SIGNAL_ACCOUNT_OUTPUT=$'Number: +10000000000\nNumber: +20000000000' \
  signal "$HVALID" send team "$MESSAGE" >/dev/null 2>&1; then
  fail "multiple discovered accounts were accepted"
fi
send_count_after=$(grep -c ' send ' "$SIGNAL_ROOT/cli.log" || true)
[ "$send_count_before" = "$send_count_after" ] || fail "a malformed account number reached the send operation"
pass "account discovery requires exactly one strictly formed account"
signal "$HVALID" retire team >/dev/null

HCONFIG="$SIGNAL_ROOT/invalid-config"
new_home "$HCONFIG"
printf 'duplicate\tgroup-fixture-id\tDuplicate\n' >> "$HCONFIG/config/signal-groups"
cli_count_before=$(wc -l < "$SIGNAL_ROOT/cli.log" | tr -d ' ')
if signal "$HCONFIG" arm team >/dev/null 2>&1; then
  fail "arm accepted an invalid unselected routing row"
fi
cli_count_after=$(wc -l < "$SIGNAL_ROOT/cli.log" | tr -d ' ')
[ "$cli_count_before" = "$cli_count_after" ] || fail "invalid routing configuration reached signal-cli"
pass "arm validates the complete routing table before registration"

HREARM="$SIGNAL_ROOT/rearm-failure"
new_home "$HREARM"
printf '0\n' > "$SIGNAL_ROOT/list-count"
if FM_SIGNAL_COMMAND_TIMEOUT=1 FM_FAKE_SIGNAL_FAIL_LIST_AT=2 \
  signal "$HREARM" send team "$MESSAGE" > "$SIGNAL_ROOT/rearm.out" 2> "$SIGNAL_ROOT/rearm.err"; then
  fail "send succeeded after its restored source failed account discovery"
fi
assert_grep 'sent: Signal message' "$SIGNAL_ROOT/rearm.out" "the outbound send completed before restoration failed"
assert_grep 'error: could not restore Signal receive source: team' "$SIGNAL_ROOT/rearm.err" "failed readiness is reported without private state"
assert_not_contains "$(cat "$SIGNAL_ROOT/rearm.out" "$SIGNAL_ROOT/rearm.err")" "private-cli" "signal-cli output stays private"
pass "send fails closed unless the restored runner reaches receive"
