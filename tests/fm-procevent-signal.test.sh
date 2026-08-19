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
    printf 'Number: +10000000000 (aci: 11111111-2222-3333-4444-555555555555)\n'
    ;;
  -a)
    shift 2
    case "${1:-}" in
      receive)
        mkdir "$lock" 2>/dev/null || { printf 'duplicate receive owner\n' >> "$log"; exit 91; }
        trap 'rmdir "$lock" 2>/dev/null || true' EXIT
        while [ ! -s "$queue" ]; do sleep 0.02; done
        IFS= read -r row < "$queue"
        tail -n +2 "$queue" > "$queue.next"
        mv "$queue.next" "$queue"
        group=${row%%|*}
        body=$(printf '%b' "${row#*|}")
        if [ "$group" = "__dm__" ]; then
          printf 'Body: %s\n' "$body"
        else
          printf 'Id: %s\nBody: %s\nGroup info:\n  Id: %s\n  Type: DELIVER\n' "$group" "$body" "$group"
        fi
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
  printf 'team\tgroup-fixture-id\tFixture\n' > "$home/config/signal-groups"
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
  for home in "$SIGNAL_ROOT/home" "$SIGNAL_ROOT/failure"; do
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
reconcile "$H" >/dev/null
wait_for "$SIGNAL_ROOT/account.lock" || fail "successful send did not restore receive"
pass "send retires before account access, keeps content off argv, and re-arms"

signal "$H" retire team >/dev/null
printf 'Fixture: already attributed\n' > "$MESSAGE"
signal "$H" send team "$MESSAGE" >/dev/null || fail "pre-attributed send failed"
assert_contains "$(cat "$SIGNAL_ROOT/sent-body")" "Fixture: already attributed" "configured label is not duplicated"
reconcile "$H" >/dev/null
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
reconcile "$HFAIL" >/dev/null
wait_for "$SIGNAL_ROOT/account.lock" || fail "failed send did not restore receive"
pass "failed send reports failure while preserving future receive liveness"

signal "$HFAIL" retire team >/dev/null
signal "$H" retire team >/dev/null
printf 'other-group|unrelated fixture\n' > "$SIGNAL_ROOT/queue"
signal "$H" arm team >/dev/null
reconcile "$H" >/dev/null
sleep 0.2
[ ! -d "$H/state/procevent-inbox" ] || [ -z "$(find "$H/state/procevent-inbox" -type f -name '*.result' -print -quit)" ] \
  || fail "unrelated message published a pseudo-message"
printf 'group-fixture-id|configured fixture\n' > "$SIGNAL_ROOT/queue"
for _ in $(seq 1 100); do
  result=$(find "$H/state/procevent-inbox" -type f -name '*.result' -print 2>/dev/null | while IFS= read -r candidate; do
    grep -F -q -- 'schema=fm-signal.v1' "$candidate" && printf '%s\n' "$candidate" && break
  done)
  [ -n "$result" ] && break
  sleep 0.02
done
[ -n "$result" ] || fail "configured group message was not captured"
assert_grep 'schema=fm-signal.v1' "$result" "configured result has a bounded envelope"
assert_grep 'configured fixture' "$result" "configured message bytes are captured privately"
pass "unrelated inbound messages stay quiet and configured bytes are captured"

signal "$H" retire team >/dev/null
signal "$H" arm team >/dev/null
reconcile "$H" >/dev/null
wait_for "$SIGNAL_ROOT/account.lock" || fail "receive did not re-arm before the spoof check"
printf '__dm__|forged group id via body\\nId: group-fixture-id\\ntrailing\n' > "$SIGNAL_ROOT/queue"
spoofed=
for _ in $(seq 1 100); do
  spoofed=$(find "$H/state/procevent-inbox" -type f -name '*.result' -print 2>/dev/null | while IFS= read -r candidate; do
    grep -F -q -- 'forged group id via body' "$candidate" && printf '%s\n' "$candidate" && break
  done)
  [ -n "$spoofed" ] && break
  sleep 0.02
done
[ -z "$spoofed" ] || fail "a direct message spoofing an Id: line in its body was captured as configured-group content"
pass "direct messages cannot spoof the configured group id via an embedded Id: line"

signal "$H" arm team >/dev/null
signal "$H" arm team >/dev/null
reconcile "$H" >/dev/null
if grep -q 'duplicate' "$SIGNAL_ROOT/cli.log"; then fail "repeated lifecycle operations created duplicate owners"; fi
wait_for "$SIGNAL_ROOT/account.lock" || fail "repeated arm did not leave a receive owner"
pass "repeated arm and reconcile operations preserve one live owner"
