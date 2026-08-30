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
SIGNAL_TMP="$SIGNAL_ROOT/private-tmp"
INTERRUPT_ROOT="$SIGNAL_ROOT/interruption-cli"
mkdir -p "$FAKEBIN" "$SIGNAL_TMP" "$INTERRUPT_ROOT"
export FM_PROCEVENT_CLAIM_ROOT="$SIGNAL_ROOT/claims"
export FM_REAL_PYTHON3
FM_REAL_PYTHON3=$(command -v python3)
export FM_REAL_MKTEMP
FM_REAL_MKTEMP=$(command -v mktemp)

cat > "$FAKEBIN/mktemp" <<'SH'
#!/usr/bin/env bash
set -u
path=$("$FM_REAL_MKTEMP" "$@") || exit 1
case "$path" in
  */state/signal/tmp/fm-signal-*|*/state/signal/tmp/invocation.*/*)
    if [ "${FM_FAKE_MKTEMP_INTERRUPT:-0}" = 1 ]; then
      group=$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')
      kill -TERM -- "-$group"
      sleep 1
      exit 143
    fi
    ;;
esac
printf '%s\n' "$path"
SH
chmod +x "$FAKEBIN/mktemp"

cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_SIGNAL_RAW:-}" ]; then
  if [ -n "${FM_FAKE_SIGNAL_PREFIX_DELAY_ONCE:-}" ]; then
    if mkdir "$FM_FAKE_SIGNAL_ROOT/prefix-delay-used" 2>/dev/null; then
      sleep "$FM_FAKE_SIGNAL_PREFIX_DELAY_ONCE"
    fi
  else
    sleep "${FM_FAKE_SIGNAL_PREFIX_DELAY:-0}"
  fi
fi
exec "$FM_REAL_PYTHON3" "$@"
SH
chmod +x "$FAKEBIN/python3"

cat > "$FAKEBIN/signal-cli" <<'SH'
#!/usr/bin/env bash
set -u
root=${FM_FAKE_SIGNAL_ROOT:?}
lock="$root/account.lock"
log="$root/cli.log"
queue="$root/queue"
list_count_file="$root/list-count"
printf '%s\n' "$*" >> "$log"
if [ "${1:-}" = --data-dir ]; then
  data_dir=$2
  shift 2
  [ "$data_dir" = "$FM_HOME/state/signal/data" ] || exit 97
  if [ "$(uname)" = Darwin ]; then
    data_mode=$(stat -f %Lp "$data_dir" 2>/dev/null)
  else
    data_mode=$(stat -c %a "$data_dir" 2>/dev/null)
  fi
  [ -d "$data_dir" ] && [ "$data_mode" = 700 ] || exit 97
fi
case "${1:-}" in
  listAccounts)
    while [ -e "$lock" ]; do sleep 0.02; done
    if [ -n "${FM_FAKE_SIGNAL_LIST_DELAY_ONCE:-}" ]; then
      if mkdir "$root/list-delay-used" 2>/dev/null; then
        sleep "$FM_FAKE_SIGNAL_LIST_DELAY_ONCE"
      fi
    else
      sleep "${FM_FAKE_SIGNAL_LIST_DELAY:-0}"
    fi
    list_count=0
    [ ! -f "$list_count_file" ] || IFS= read -r list_count < "$list_count_file"
    list_count=$((list_count + 1))
    printf '%s\n' "$list_count" > "$list_count_file"
    if [ "${FM_FAKE_SIGNAL_FAIL_LIST_AT:-0}" = "$list_count" ]; then exit 96; fi
    printf '%s\n' "${FM_FAKE_SIGNAL_ACCOUNT_OUTPUT:-Number: +10000000000 (aci: 11111111-2222-3333-4444-555555555555)}"
    ;;
  -o)
    shift 2
    case "${1:-}" in
      receive)
        printf '%s\n' "$PPID" > "$root/receive-parent"
        sleep "${FM_FAKE_SIGNAL_RECEIVE_START_DELAY:-0}"
        mkdir "$lock" 2>/dev/null || { printf 'duplicate receive owner\n' >> "$log"; exit 91; }
        trap 'rmdir "$lock" 2>/dev/null || true' EXIT
        while [ ! -s "$queue" ]; do sleep 0.02; done
        IFS= read -r row < "$queue"
        tail -n +2 "$queue" > "$queue.next"
        mv "$queue.next" "$queue"
        printf '%s\n' "$row"
        ;;
      *) exit 94 ;;
    esac
    ;;
  jsonRpc)
    [ ! -e "$lock" ] || exit 92
    "$FM_REAL_PYTHON3" -c '
import json
import os
import sys

document = json.load(sys.stdin)
if document.get("jsonrpc") != "2.0" or document.get("method") != "send" or document.get("id") != "fm-send":
    raise SystemExit(98)
params = document.get("params")
expected_account = os.environ.get("FM_FAKE_SIGNAL_EXPECTED_ACCOUNT", "+10000000000")
if (not isinstance(params, dict)
        or params.get("account") != expected_account
        or not isinstance(params.get("groupId"), str)
        or not isinstance(params.get("message"), str)):
    raise SystemExit(98)
with open(os.path.join(os.environ["FM_FAKE_SIGNAL_ROOT"], "sent-account"), "w", encoding="ascii") as target:
    target.write(params["account"])
with open(os.path.join(os.environ["FM_FAKE_SIGNAL_ROOT"], "sent-group"), "w", encoding="utf-8") as target:
    target.write(params["groupId"])
with open(os.path.join(os.environ["FM_FAKE_SIGNAL_ROOT"], "sent-body"), "w", encoding="utf-8") as target:
    target.write(params["message"])
' || exit $?
    sleep "${FM_FAKE_SIGNAL_SEND_DELAY:-0}"
    printf '%s\n' '{"jsonrpc":"2.0","method":"receive","params":{"fixture":"private-cli-metadata-fixture"}}'
    printf 'private-cli-error-fixture\n' >&2
    if [ "${FM_FAKE_SIGNAL_FAIL:-0}" = 1 ]; then
      printf '%s\n' '{"jsonrpc":"2.0","error":{"code":-1,"message":"fixture"},"id":"fm-send"}'
    else
      printf 'sent bytes=%s\n' "$(wc -c < "$root/sent-body" | tr -d ' ')" >> "$root/sent.log"
      printf '%s\n' '{"jsonrpc":"2.0","result":{"timestamp":1},"id":"fm-send"}'
    fi
    ;;
  -a)
    shift 2
    case "${1:-}" in
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
        sleep "${FM_FAKE_SIGNAL_SEND_DELAY:-0}"
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
  chmod 600 "$home/config/signal-groups"
}

signal() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$1/config" \
    PATH="$FAKEBIN:$PATH" TMPDIR="$SIGNAL_TMP" FM_FAKE_SIGNAL_ROOT="$SIGNAL_ROOT" \
    "$ROOT/bin/fm-procevent-signal.sh" "${@:2}"
}

reconcile() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKEBIN:$PATH" TMPDIR="$SIGNAL_TMP" \
    FM_FAKE_SIGNAL_ROOT="$SIGNAL_ROOT" \
    "$ROOT/bin/fm-procevent.sh" reconcile
}

wait_for() {
  local file=$1 tries=${2:-100}
  for _ in $(seq 1 "$tries"); do [ -e "$file" ] && return 0; sleep 0.02; done
  return 1
}

wait_for_absent() {
  local file=$1 tries=${2:-100}
  for _ in $(seq 1 "$tries"); do [ ! -e "$file" ] && return 0; sleep 0.02; done
  return 1
}

cleanup_sources() {
  local home
  for home in "$SIGNAL_ROOT/home" "$SIGNAL_ROOT/failure" "$SIGNAL_ROOT/validation" \
    "$SIGNAL_ROOT/rearm-failure" "$SIGNAL_ROOT/invalid-config" "$SIGNAL_ROOT/foreign" \
    "$SIGNAL_ROOT/interruption" "$SIGNAL_ROOT/public-config"; do
    [ -d "$home" ] || continue
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
}
trap cleanup_sources EXIT

wait_for_private_temp() {
  local home=$1 pattern=$2 dir="$1/state/signal/tmp" file
  for _ in $(seq 1 100); do
    file=$(find "$dir" -type f -name "$pattern" -print -quit 2>/dev/null)
    if [ -n "$file" ]; then
      [ "$(file_mode "$home/state/signal")" = 700 ] || fail "Signal state directory is not mode 0700"
      [ "$(file_mode "$dir")" = 700 ] || fail "Signal temporary directory is not mode 0700"
      [ "$(file_mode "$file")" = 600 ] || fail "Signal temporary file is not mode 0600"
      [ -z "$(find "$SIGNAL_TMP" -type f -name 'fm-signal-*' -print -quit)" ] \
        || fail "Signal operation staged sensitive bytes outside its effective home"
      return 0
    fi
    sleep 0.02
  done
  return 1
}

assert_no_private_temps() {
  local home=$1
  [ -z "$(find "$home/state/signal/tmp" -type f -name 'fm-signal-*' -print -quit 2>/dev/null)" ] \
    || fail "interrupted Signal operation retained a private temporary"
  [ -z "$(find "$SIGNAL_TMP" -type f -name 'fm-signal-*' -print -quit)" ] \
    || fail "interrupted Signal operation staged sensitive bytes outside its effective home"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

assert_runner_owned_receive() {
  local home=$1 root=${2:-$SIGNAL_ROOT} claim_pid source_pid source_parent
  wait_for "$root/receive-parent" || fail "restored receive process did not start"
  claim_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/signal-account.claim")
  IFS= read -r source_pid < "$root/receive-parent"
  source_parent=$(ps -o ppid= -p "$source_pid" 2>/dev/null | tr -d '[:space:]')
  [ "$source_parent" = "$claim_pid" ] || fail "receive was not foreground-owned by the generic runner"
  [ -f "$home/state/procevent/signal-account.ready" ] || fail "restored runner did not publish generation-bound readiness"
}

H="$SIGNAL_ROOT/home"
new_home "$H"

HINT="$SIGNAL_ROOT/interruption"
new_home "$HINT"
perl -e 'setpgrp(0, 0) or exit 125; exec @ARGV; exit 125' \
  env FM_HOME="$HINT" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$HINT/config" \
    PATH="$FAKEBIN:$PATH" TMPDIR="$SIGNAL_TMP" FM_FAKE_SIGNAL_ROOT="$INTERRUPT_ROOT" \
    FM_FAKE_MKTEMP_INTERRUPT=1 "$ROOT/bin/fm-procevent-signal.sh" \
    send team - < /dev/null > "$SIGNAL_ROOT/interrupted-create.out" \
    2> "$SIGNAL_ROOT/interrupted-create.err" &
interrupted_pid=$!
wait "$interrupted_pid" 2>/dev/null
interrupted_status=$?
[ "$interrupted_status" -eq 143 ] || fail "temporary-creation interruption returned $interrupted_status instead of 143"
assert_no_private_temps "$HINT"

INTERRUPT_FIFO="$SIGNAL_ROOT/interrupted-input"
mkfifo "$INTERRUPT_FIFO"
FM_HOME="$HINT" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$HINT/config" \
  PATH="$FAKEBIN:$PATH" TMPDIR="$SIGNAL_TMP" FM_FAKE_SIGNAL_ROOT="$SIGNAL_ROOT" \
  "$ROOT/bin/fm-procevent-signal.sh" send team - < "$INTERRUPT_FIFO" \
  > "$SIGNAL_ROOT/interrupted-stdin.out" 2> "$SIGNAL_ROOT/interrupted-stdin.err" &
interrupted_pid=$!
exec 9> "$INTERRUPT_FIFO"
printf 'partial fixture' >&9
wait_for_private_temp "$HINT" 'fm-signal-input.*' || fail "stdin staging interruption fixture never created its private temporary"
kill -TERM "$interrupted_pid" 2>/dev/null || true
exec 9>&-
wait "$interrupted_pid" 2>/dev/null || true
rm -f "$INTERRUPT_FIFO"
assert_no_private_temps "$HINT"

printf 'interruption fixture\n' > "$SIGNAL_ROOT/interruption-message"
perl -e 'setpgrp(0, 0) or exit 125; exec @ARGV; exit 125' \
  env FM_HOME="$HINT" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$HINT/config" \
    PATH="$FAKEBIN:$PATH" TMPDIR="$SIGNAL_TMP" FM_FAKE_SIGNAL_ROOT="$INTERRUPT_ROOT" \
    FM_FAKE_SIGNAL_LIST_DELAY_ONCE=30 "$ROOT/bin/fm-procevent-signal.sh" \
    send team "$SIGNAL_ROOT/interruption-message" \
    > "$SIGNAL_ROOT/interrupted-account.out" 2> "$SIGNAL_ROOT/interrupted-account.err" &
interrupted_pid=$!
wait_for_private_temp "$HINT" 'fm-signal-accounts.*' || fail "account interruption fixture never created its private temporary"
kill -TERM -"$interrupted_pid" 2>/dev/null || true
wait "$interrupted_pid" 2>/dev/null
interrupted_status=$?
[ "$interrupted_status" -eq 143 ] || fail "account interruption returned $interrupted_status instead of 143"
assert_no_private_temps "$HINT"
assert_runner_owned_receive "$HINT" "$INTERRUPT_ROOT"

rm -f "$INTERRUPT_ROOT/receive-parent"
perl -e 'setpgrp(0, 0) or exit 125; exec @ARGV; exit 125' \
  env FM_HOME="$HINT" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$HINT/config" \
    PATH="$FAKEBIN:$PATH" TMPDIR="$SIGNAL_TMP" FM_FAKE_SIGNAL_ROOT="$INTERRUPT_ROOT" \
    FM_FAKE_SIGNAL_PREFIX_DELAY_ONCE=30 "$ROOT/bin/fm-procevent-signal.sh" \
    send team "$SIGNAL_ROOT/interruption-message" \
    > "$SIGNAL_ROOT/interrupted-prefix.out" 2> "$SIGNAL_ROOT/interrupted-prefix.err" &
interrupted_pid=$!
wait_for_private_temp "$HINT" 'fm-signal-raw.*' || fail "raw message interruption fixture never created its private temporary"
wait_for_private_temp "$HINT" 'fm-signal-message.*' || fail "prefixed message interruption fixture never created its private temporary"
kill -TERM -"$interrupted_pid" 2>/dev/null || true
wait "$interrupted_pid" 2>/dev/null
interrupted_status=$?
[ "$interrupted_status" -eq 143 ] || fail "prefix interruption returned $interrupted_status instead of 143"
assert_no_private_temps "$HINT"
assert_runner_owned_receive "$HINT" "$INTERRUPT_ROOT"

rm -f "$INTERRUPT_ROOT/receive-parent"
perl -e 'setpgrp(0, 0) or exit 125; exec @ARGV; exit 125' \
  env FM_HOME="$HINT" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$HINT/config" \
    PATH="$FAKEBIN:$PATH" TMPDIR="$SIGNAL_TMP" FM_FAKE_SIGNAL_ROOT="$INTERRUPT_ROOT" \
    FM_FAKE_SIGNAL_SEND_DELAY=30 "$ROOT/bin/fm-procevent-signal.sh" \
    send team "$SIGNAL_ROOT/interruption-message" \
    > "$SIGNAL_ROOT/interrupted-send.out" 2> "$SIGNAL_ROOT/interrupted-send.err" &
interrupted_pid=$!
wait_for_private_temp "$HINT" 'fm-signal-message.*' || fail "send interruption fixture never created its private temporary"
wait_for_private_temp "$HINT" 'fm-signal-request.*' || fail "send interruption fixture never created its private request"
wait_for_private_temp "$HINT" 'fm-signal-response.*' || fail "send interruption fixture never created its private response"
kill -TERM -"$interrupted_pid" 2>/dev/null || true
wait "$interrupted_pid" 2>/dev/null
interrupted_status=$?
[ "$interrupted_status" -eq 143 ] || fail "send interruption returned $interrupted_status instead of 143"
assert_no_private_temps "$HINT"
assert_runner_owned_receive "$HINT" "$INTERRUPT_ROOT"
signal "$HINT" retire team >/dev/null
pass "Signal interruptions clean private state and restore inbound receive"

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

HFOREIGN="$SIGNAL_ROOT/foreign"
new_home "$HFOREIGN"
printf 'foreign fixture\n' > "$SIGNAL_ROOT/foreign-message"
cli_count_before=$(wc -l < "$SIGNAL_ROOT/cli.log" | tr -d ' ')
if signal "$HFOREIGN" send team "$SIGNAL_ROOT/foreign-message" \
  > "$SIGNAL_ROOT/foreign.out" 2> "$SIGNAL_ROOT/foreign.err"; then
  fail "a foreign home sent while another home owned the Signal source"
fi
assert_grep 'error: Signal account is active in another home' "$SIGNAL_ROOT/foreign.err" \
  "foreign-home account access fails with a sanitized adapter error"
cli_count_after=$(wc -l < "$SIGNAL_ROOT/cli.log" | tr -d ' ')
[ "$cli_count_before" = "$cli_count_after" ] || fail "foreign-home refusal reached signal-cli"
[ -d "$SIGNAL_ROOT/account.lock" ] || fail "foreign-home refusal disturbed the owning receive"
pass "a foreign home cannot access Signal while another runner owns the account"

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
rm -f "$SIGNAL_ROOT/receive-parent"
FM_FAKE_SIGNAL_RECEIVE_START_DELAY=0.5 \
  signal "$H" send team "$MESSAGE" > "$SIGNAL_ROOT/send.out" 2> "$SIGNAL_ROOT/send.err" \
  || fail "supported send ordering failed"
[ -s "$SIGNAL_ROOT/sent.log" ] || fail "successful send was not recorded"
assert_contains "$(cat "$SIGNAL_ROOT/sent-body")" "Fixture: reply fixture" "configured label is prepended once"
assert_contains "$(cat "$SIGNAL_ROOT/sent-account")" "+10000000000" "discovered account is delivered through JSON-RPC stdin"
assert_contains "$(cat "$SIGNAL_ROOT/sent-group")" "group-fixture-id" "configured group is delivered through JSON-RPC stdin"
assert_not_contains "$(cat "$SIGNAL_ROOT/cli.log")" "reply fixture" "message content never reaches a CLI argv record"
assert_not_contains "$(cat "$SIGNAL_ROOT/cli.log")" "group-fixture-id" "group identifier never reaches a CLI argv record"
assert_not_contains "$(cat "$SIGNAL_ROOT/cli.log")" "+10000000000" "account identifier never reaches a CLI argv record"
[ "$(cat "$SIGNAL_ROOT/send.out")" = "sent: Signal message" ] || fail "send did not emit only its sanitized success status"
[ ! -s "$SIGNAL_ROOT/send.err" ] || fail "successful send exposed unexpected stderr"
assert_runner_owned_receive "$H"
wait_for "$SIGNAL_ROOT/account.lock" || fail "successful send did not eventually restore receive"
pass "send restores a bounded generation-owned foreground receive"

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
rm -f "$SIGNAL_ROOT/receive-parent"
if FM_FAKE_SIGNAL_FAIL=1 FM_FAKE_SIGNAL_RECEIVE_START_DELAY=0.5 signal "$HFAIL" send team "$MESSAGE" \
  > "$SIGNAL_ROOT/failure.out" 2> "$SIGNAL_ROOT/failure.err"; then
  fail "failed fake send unexpectedly succeeded"
fi
[ ! -s "$SIGNAL_ROOT/failure.out" ] || fail "failed send exposed unexpected stdout"
assert_grep 'error: Signal send failed or timed out' "$SIGNAL_ROOT/failure.err" "failed send reports a sanitized adapter error"
assert_not_contains "$(cat "$SIGNAL_ROOT/failure.out" "$SIGNAL_ROOT/failure.err")" "private-cli" "failed signal-cli output stays private"
assert_runner_owned_receive "$HFAIL"
wait_for "$SIGNAL_ROOT/account.lock" || fail "failed send did not eventually restore receive"
pass "failed send restores a bounded generation-owned foreground receive"

signal "$HFAIL" retire team >/dev/null
signal "$H" retire team >/dev/null
printf '%s\n' '{"envelope":{"dataMessage":{"message":"unrelated fixture","groupInfo":{"groupId":"other-group"}}}}' > "$SIGNAL_ROOT/queue"
signal "$H" arm team >/dev/null
reconcile "$H" >/dev/null
sleep 0.2
[ ! -d "$H/state/procevent-inbox" ] || [ -z "$(find "$H/state/procevent-inbox" -type f -name '*.result' -print -quit)" ] \
  || fail "unrelated message published a pseudo-message"
wait_for "$SIGNAL_ROOT/account.lock" || fail "receiver did not continue after the unrelated message"
chmod 644 "$H/config/signal-groups"
printf '%s\n' '{"envelope":{"dataMessage":{"message":"replacement fixture","groupInfo":{"groupId":"group-fixture-id"}}}}' > "$SIGNAL_ROOT/queue"
wait_for_absent "$SIGNAL_ROOT/account.lock" || fail "receiver did not reject a live public routing replacement"
wait_for_absent "$H/state/procevent/signal-account.runner" || fail "runner did not settle after rejecting a live routing replacement"
[ ! -d "$H/state/procevent-inbox" ] || [ -z "$(find "$H/state/procevent-inbox" -type f -name '*.result' -print -quit)" ] \
  || fail "live public routing replacement published a Signal capture"
chmod 600 "$H/config/signal-groups"
reconcile "$H" >/dev/null
wait_for "$SIGNAL_ROOT/account.lock" || fail "receiver did not recover after routing permissions were restored"
pass "live route replacement revalidates private file permissions"
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

owner_before=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/signal-account.claim")
signal "$H" arm team >/dev/null
owner_after=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/signal-account.claim")
[ "$owner_before" = "$owner_after" ] || fail "an identical Signal arm replaced its active owner"
FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-procevent.sh" wait-ready signal-account 1 >/dev/null \
  || fail "an identical Signal arm invalidated active readiness"
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
send_count_before=$(grep -c ' jsonRpc ' "$SIGNAL_ROOT/cli.log" || true)
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
send_count_after=$(grep -c ' jsonRpc ' "$SIGNAL_ROOT/cli.log" || true)
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

HPERM="$SIGNAL_ROOT/public-config"
new_home "$HPERM"
chmod 644 "$HPERM/config/signal-groups"
cli_count_before=$(wc -l < "$SIGNAL_ROOT/cli.log" | tr -d ' ')
if signal "$HPERM" arm team > "$SIGNAL_ROOT/public-config.out" 2> "$SIGNAL_ROOT/public-config.err"; then
  fail "arm accepted a publicly readable Signal routing file"
fi
assert_grep 'error: Signal group configuration must have mode 0600' "$SIGNAL_ROOT/public-config.err" \
  "public Signal routing file fails with a sanitized permission error"
[ ! -s "$SIGNAL_ROOT/public-config.out" ] || fail "public Signal routing file exposed unexpected stdout"
cli_count_after=$(wc -l < "$SIGNAL_ROOT/cli.log" | tr -d ' ')
[ "$cli_count_before" = "$cli_count_after" ] || fail "public Signal routing file reached signal-cli"
pass "Signal routing requires private file permissions"

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
