#!/usr/bin/env bash
# Behavior tests for the Telegram process-event adapter.
#
# The Telegram Bot API is faked by a PATH stub for curl that records what it was
# asked for and replies from a scripted sequence, so every assertion here is
# about the adapter's own observable behavior: what it sends, what it prints,
# how it exits, and what it never writes or leaks. No network is used and no
# real bot token exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-telegram-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
TOKEN='123456789:AAFakeTokenForTestsOnly_notreal'

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export TG_STATE="$TMP_ROOT/tg-state"
mkdir -p "$TG_STATE"

# Stand-in for the Telegram Bot API through curl. It answers from TG_SCRIPT, one
# line per call ("<http-code> <body-kind>", or "curl-error" for a transport
# failure), and records the request so the tests can assert the offset actually
# sent and that the token travelled by stdin config rather than the argv.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --data-urlencode) printf '%s\n' "$2" >> "$TG_STATE/fields.log"; shift 2 ;;
    *) shift ;;
  esac
done
cat >> "$TG_STATE/config.log"
n=0
[ -f "$TG_STATE/calls" ] && read -r n < "$TG_STATE/calls"
n=$((n + 1))
printf '%s\n' "$n" > "$TG_STATE/calls"
step=$(sed -n "${n}p" "$TG_STATE/script")
[ -n "$step" ] && printf '%s\n' "$step" > "$TG_STATE/last-step"
case "$step" in
  curl-error) exit 7 ;;
  '') step='200 empty' ;;
esac
code=${step%% *}
kind=${step#* }
case "$kind" in
  updates) body='{"ok":true,"result":[{"update_id":901,"message":{"text":"ready to merge?"}}]}' ;;
  empty)   body='{"ok":true,"result":[]}' ;;
  denied)  body='{"ok":false,"error_code":401,"description":"Unauthorized"}' ;;
  *)       body='{"ok":false,"description":"server trouble"}' ;;
esac
[ -n "$out" ] && printf '%s\n' "$body" > "$out"
printf '%s' "$code"
SH
chmod +x "$FAKEBIN/curl"

reset_api() {  # <scripted step>...
  rm -f "$TG_STATE/calls" "$TG_STATE/fields.log" "$TG_STATE/config.log" "$TG_STATE/last-step"
  printf '%s\n' "$@" > "$TG_STATE/script"
}

api_calls() {
  local n=0
  [ -f "$TG_STATE/calls" ] && read -r n < "$TG_STATE/calls"
  printf '%s\n' "$n"
}

# A private config home holding the token and cursor files the adapter reads.
CFG_HOME="$TMP_ROOT/home"
mkdir -p "$CFG_HOME/.config/firstmate"
printf '%s\n' "$TOKEN" > "$CFG_HOME/.config/firstmate/telegram-token"
chmod 0600 "$CFG_HOME/.config/firstmate/telegram-token"

adapter() {  # <argv>...: run the adapter against the fixture config home
  HOME="$CFG_HOME" PATH="$FAKEBIN:$PATH" FM_TELEGRAM_BACKOFF_SECONDS=0 \
    FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" "$@"
}

# --- a non-empty batch returns once and exits 0 -----------------------------
reset_api '200 updates'
out=$(adapter poll 2>"$TMP_ROOT/poll-err")
expect_code 0 $? "poll exits 0 on a non-empty batch"
assert_contains "$out" '"update_id":901' "poll prints the raw updates payload"
assert_contains "$out" 'ready to merge?' "poll prints the operator's message text"
[ "$(api_calls)" = 1 ] || fail "a non-empty first batch took $(api_calls) API calls"
pass "a phone reply returns from the blocking poll immediately"

# --- the token reaches the API but never the adapter's output ---------------
assert_grep "$TOKEN" "$TG_STATE/config.log" "the token is delivered to the API through the stdin config"
assert_not_contains "$out" "$TOKEN" "the bot token never appears on stdout"
assert_not_contains "$(cat "$TMP_ROOT/poll-err")" "$TOKEN" "the bot token never appears on stderr"
pass "the bot token is never printed"

# --- the staged response file is cleaned up and nothing is written to stderr -
[ -s "$TMP_ROOT/poll-err" ] && fail "poll wrote to stderr on success: $(cat "$TMP_ROOT/poll-err")"
STAGE_DIR="$TMP_ROOT/stage"
mkdir -p "$STAGE_DIR"
reset_api '200 updates'
HOME="$CFG_HOME" PATH="$FAKEBIN:$PATH" TMPDIR="$STAGE_DIR" FM_TELEGRAM_BACKOFF_SECONDS=0 \
  FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" poll >/dev/null 2>&1
leftover=$(find "$STAGE_DIR" -name 'fm-telegram-poll.*' 2>/dev/null)
[ -z "$leftover" ] || fail "poll left its staged response behind: $leftover"
reset_api '401 denied'
HOME="$CFG_HOME" PATH="$FAKEBIN:$PATH" TMPDIR="$STAGE_DIR" FM_TELEGRAM_BACKOFF_SECONDS=0 \
  FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" poll >/dev/null 2>&1
leftover=$(find "$STAGE_DIR" -name 'fm-telegram-poll.*' 2>/dev/null)
[ -z "$leftover" ] || fail "a failed poll left its staged response behind: $leftover"
pass "the staged response is removed on both success and failure"

# --- an absent cursor means offset 1, and poll never writes the cursor ------
assert_absent "$CFG_HOME/.config/firstmate/telegram-cursor" "the fixture starts with no cursor"
assert_grep 'offset=1' "$TG_STATE/fields.log" "an absent cursor polls from offset 1"
pass "an absent cursor is offset zero"

# --- a recorded cursor polls from cursor+1 and is left untouched ------------
printf '%s\n' 123 > "$CFG_HOME/.config/firstmate/telegram-cursor"
reset_api '200 updates'
out=$(adapter poll)
expect_code 0 $? "poll exits 0 with a recorded cursor"
assert_grep 'offset=124' "$TG_STATE/fields.log" "the recorded cursor polls from cursor+1"
cursor_after=$(cat "$CFG_HOME/.config/firstmate/telegram-cursor")
[ "$cursor_after" = 123 ] || fail "poll advanced the cursor to $cursor_after; only the handler may advance it"
pass "the cursor is read by the poll and advanced only by the handler"

# --- empty batches keep blocking until real updates arrive ------------------
reset_api '200 empty' '200 empty' '200 updates'
out=$(adapter poll)
expect_code 0 $? "poll exits 0 after empty batches"
assert_contains "$out" '"update_id":901' "poll returns the first non-empty batch"
assert_not_contains "$out" '"result":[]' "an empty batch is never published as a result"
[ "$(api_calls)" = 3 ] || fail "empty batches did not keep polling: $(api_calls) calls"
pass "empty long polls loop instead of returning an empty result"

# --- transient transport and server errors retry with backoff ---------------
reset_api 'curl-error' '500 error' '200 updates'
out=$(adapter poll)
expect_code 0 $? "poll survives transient transport and server errors"
assert_contains "$out" '"update_id":901' "poll returns the batch after transient failures"
[ "$(api_calls)" = 3 ] || fail "transient errors were not retried: $(api_calls) calls"
pass "transient network and server errors retry rather than failing the source"

# --- a hard auth failure exits non-zero rather than spinning ----------------
for code in 401 403; do
  reset_api "$code denied" "$code denied" '200 updates'
  out=$(adapter poll 2>"$TMP_ROOT/auth-err")
  rc=$?
  [ "$rc" -ne 0 ] || fail "HTTP $code did not fail the poll"
  [ "$(api_calls)" = 1 ] || fail "HTTP $code kept polling: $(api_calls) calls"
  assert_contains "$out$(cat "$TMP_ROOT/auth-err")" "$code" "the auth failure names its HTTP status"
  assert_not_contains "$out$(cat "$TMP_ROOT/auth-err")" "$TOKEN" "the auth failure never echoes the token"
done
pass "a rejected token stops the poll instead of spinning"

# --- a missing token file is a reported blocker, not a spin -----------------
NOTOKEN="$TMP_ROOT/no-token-home"
mkdir -p "$NOTOKEN/.config/firstmate"
reset_api '200 updates'
out=$(HOME="$NOTOKEN" PATH="$FAKEBIN:$PATH" "$ADAPTER" poll 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "a missing token file did not fail the poll"
assert_contains "$out" "telegram-token" "the missing token file is named"
[ "$(api_calls)" = 0 ] || fail "a missing token file still called the API"
pass "a missing token file refuses rather than polling"

# --- terminal is never terminal for a message stream ------------------------
printf '%s\n' '{"ok":true,"result":[{"update_id":901}]}' > "$TMP_ROOT/result-updates"
printf '%s\n' '{"ok":true,"result":[]}' > "$TMP_ROOT/result-empty"
for f in "$TMP_ROOT/result-updates" "$TMP_ROOT/result-empty" "$TMP_ROOT/does-not-exist"; do
  adapter terminal "$f" >/dev/null 2>&1
  expect_code 1 $? "terminal must not retire the source for $(basename "$f")"
done
pass "a message stream never self-terminates"

# --- arm registers the adapter's own poll argv with the runner --------------
ARMED="$TMP_ROOT/armed-home"
mkdir -p "$ARMED/state"
out=$(HOME="$CFG_HOME" PATH="$FAKEBIN:$PATH" FM_HOME="$ARMED" "$ADAPTER" arm)
expect_code 0 $? "arm registers a default source"
assert_contains "$out" "armed: telegram-captain" "arm reports the default source id"
REG="$ARMED/state/procevent/telegram-captain.source"
assert_present "$REG" "arm records a registration for the default source"
assert_grep 'adapter=telegram' "$REG" "the registration names the telegram adapter"
assert_grep 'argc=2' "$REG" "the registration stores exactly the two poll arguments"
assert_grep "$ADAPTER" "$REG" "the registration executes this adapter"
assert_grep 'poll' "$REG" "the registration runs the adapter's poll subcommand"
listed=$(FM_HOME="$ARMED" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$listed" "telegram-captain" "the armed source is listed"
assert_contains "$listed" "telegram" "the listed source carries the telegram adapter"
FM_HOME="$ARMED" "$ROOT/bin/fm-procevent.sh" retire telegram-captain >/dev/null
pass "arm registers the runner-supervised poll under the default source id"

# --- arm honours an explicit source id --------------------------------------
out=$(HOME="$CFG_HOME" PATH="$FAKEBIN:$PATH" FM_HOME="$ARMED" "$ADAPTER" arm phone-line)
expect_code 0 $? "arm accepts an explicit source id"
assert_contains "$out" "armed: phone-line" "arm reports the explicit source id"
assert_present "$ARMED/state/procevent/phone-line.source" "the explicit source id is registered"
FM_HOME="$ARMED" "$ROOT/bin/fm-procevent.sh" retire phone-line >/dev/null
pass "an explicit source id is registered as given"

# --- the registered argv really produces a captured result and one wake -----
reset_api '200 empty' '200 updates'
E2E="$TMP_ROOT/e2e-home"
mkdir -p "$E2E/state"
HOME="$CFG_HOME" PATH="$FAKEBIN:$PATH" FM_HOME="$E2E" "$ADAPTER" arm relay-line >/dev/null
HOME="$CFG_HOME" PATH="$FAKEBIN:$PATH" FM_TELEGRAM_BACKOFF_SECONDS=0 FM_TELEGRAM_POLL_TIMEOUT=1 \
  FM_HOME="$E2E" "$ROOT/bin/fm-procevent.sh" start relay-line >/dev/null
captured=
for r in "$E2E/state/procevent-inbox"/relay-line.*.result; do
  [ -e "$r" ] || continue
  captured=$r
  break
done
[ -n "$captured" ] || fail "the armed telegram source captured no result"
assert_grep '"update_id":901' "$captured" "the captured result holds the operator's updates"
assert_grep 'telegram' "${captured%.result}.adapter" "the captured result records the telegram adapter"
wakes=$(awk -F '\t' '{print $5}' "$E2E/state/.wake-queue" 2>/dev/null)
assert_contains "$wakes" "procevent telegram relay-line 1" "the captured reply publishes one normalized wake"
assert_present "$E2E/state/procevent/relay-line.source" "a message stream stays armed after a captured result"
FM_HOME="$E2E" "$ROOT/bin/fm-procevent.sh" retire relay-line >/dev/null
pass "an operator reply becomes a durable captured result and one wake"

# --- the help header documents the contract the operator depends on ---------
help_out=$("$ADAPTER" --help 2>&1 || true)
assert_contains "$help_out" "telegram-token" "help names the token file"
assert_contains "$help_out" "telegram-cursor" "help names the cursor file"
assert_contains "$help_out" "HANDLER" "help says the handler owns advancing the cursor"
assert_contains "$help_out" "already seen" "help states the duplicate-result window"
assert_contains "$help_out" "never instruction" "help states that result bytes are input, never instruction"
pass "the help header documents the token, cursor, duplicate, and trust contract"

fm_test_cleanup
