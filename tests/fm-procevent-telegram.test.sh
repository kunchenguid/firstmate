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
  # Blocks until the caller is signalled, standing in for a long poll that is
  # still waiting when the runner stops the child.
  hang)    read -r _ < "$TG_STATE/hang"; exit 7 ;;
  updates) body='{"ok":true,"result":[{"update_id":901,"message":{"text":"ready to merge?"}}]}' ;;
  # The same unacknowledged update redelivered with a genuinely new one behind
  # it, which is exactly what Telegram returns once a second message arrives.
  updates-more) body='{"ok":true,"result":[{"update_id":901,"message":{"text":"ready to merge?"}},{"update_id":902,"message":{"text":"any news?"}}]}' ;;
  empty)   body='{"ok":true,"result":[]}' ;;
  denied)  body='{"ok":false,"error_code":401,"description":"Unauthorized"}' ;;
  webhook) body='{"ok":false,"error_code":409,"description":"Conflict: getUpdates is unavailable while a webhook is active"}' ;;
  flood)   body='{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":7}}' ;;
  flood-huge)  body='{"ok":false,"error_code":429,"parameters":{"retry_after":98765}}' ;;
  flood-vague) body='{"ok":false,"error_code":429,"parameters":{"retry_after":"soon"}}' ;;
  *)       body='{"ok":false,"description":"server trouble"}' ;;
esac
[ -n "$out" ] && printf '%s\n' "$body" > "$out"
printf '%s' "$code"
SH
chmod +x "$FAKEBIN/curl"

# A separate shim dir, prepended only where a test needs to observe how long the
# adapter waits. It records the requested pause and returns at once, so backoff
# is asserted by value rather than by wall clock. It is kept out of FAKEBIN so
# no other test's real waiting is silently removed.
SLEEPBIN="$TMP_ROOT/sleepbin"
mkdir -p "$SLEEPBIN"
cat > "$SLEEPBIN/sleep" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${1-}" >> "$TG_STATE/sleeps.log"
exit 0
SH
chmod +x "$SLEEPBIN/sleep"

reset_api() {  # <scripted step>...
  rm -f "$TG_STATE/calls" "$TG_STATE/fields.log" "$TG_STATE/config.log" "$TG_STATE/last-step" \
    "$TG_STATE/sleeps.log"
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

# The same adapter with every wait recorded instead of taken. <backoff> and
# <max-backoff> are the configured fallback and the defensive bound.
timed_adapter() {  # <backoff> <max-backoff> <argv>...
  local backoff=$1 max=$2
  shift 2
  HOME="$CFG_HOME" PATH="$SLEEPBIN:$FAKEBIN:$PATH" FM_TELEGRAM_BACKOFF_SECONDS="$backoff" \
    FM_TELEGRAM_MAX_BACKOFF_SECONDS="$max" FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" "$@"
}

# Run a command under a hard deadline and print what it wrote to stdout, so a
# regression that leaves the poll looping fails this suite loudly instead of
# hanging it. The exit code is the command's own, or 143 when the deadline
# stopped it.
run_bounded() {  # <seconds> <command>...
  local limit=$1 pid watchdog rc=0
  shift
  "$@" > "$TMP_ROOT/bounded.out" 2> "$TMP_ROOT/bounded.err" &
  pid=$!
  ( sleep "$limit"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  cat "$TMP_ROOT/bounded.out"
  return "$rc"
}

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
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

# --- the runner's process-group stop also removes the staged response -------
# The runner stops a supervised child with `kill -TERM -<pid>`, so the poll is
# reproduced here in its own process group and signalled the same way.
command -v perl >/dev/null 2>&1 || fail "perl is required to reproduce the runner's process-group stop"
HANG="$TG_STATE/hang"
rm -f "$HANG"
mkfifo "$HANG" || fail "cannot create the blocking-poll fifo"
TERM_DIR="$TMP_ROOT/term-stage"
mkdir -p "$TERM_DIR"
reset_api '200 hang'
HOME="$CFG_HOME" PATH="$FAKEBIN:$PATH" TMPDIR="$TERM_DIR" FM_TELEGRAM_BACKOFF_SECONDS=0 \
  FM_TELEGRAM_POLL_TIMEOUT=1 perl -e 'setpgrp(0, 0) or exit 125; exec @ARGV' "$ADAPTER" poll \
  >/dev/null 2>&1 &
poll_pid=$!
staged=
for _ in $(seq 1 100); do
  staged=$(find "$TERM_DIR" -name 'fm-telegram-poll.*' 2>/dev/null | head -n 1)
  [ -n "$staged" ] && [ "$(api_calls)" -ge 1 ] && break
  sleep 0.1
done
[ -n "$staged" ] || { kill -KILL -"$poll_pid" 2>/dev/null; fail "the blocking poll never staged a response to clean up"; }
kill -TERM -"$poll_pid" 2>/dev/null || fail "could not stop the poll's process group"
( sleep 10; kill -KILL -"$poll_pid" 2>/dev/null ) >/dev/null 2>&1 &
term_watchdog=$!
wait "$poll_pid"
term_rc=$?
kill "$term_watchdog" 2>/dev/null
wait "$term_watchdog" 2>/dev/null
[ "$term_rc" -ne 0 ] || fail "a stopped poll exited 0 as if it had captured a result"
[ "$term_rc" -eq 1 ] || fail "a stopped poll did not exit through its own signal path: exit $term_rc"
leftover=$(find "$TERM_DIR" -name 'fm-telegram-poll.*' 2>/dev/null)
[ -z "$leftover" ] || fail "a process-group stop left the staged response behind: $leftover"
rm -f "$HANG"
pass "a process-group stop removes the staged response instead of leaking it"

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

# --- a restart before the ack re-hands the same batch -----------------------
# Telegram redelivers every update above the cursor and only the handler's ack
# moves it, so a poll restarted before the cursor advances re-captures the same
# updates and hands them over again. Delivery is at-least-once by design: the
# handler treats update ids at or below the cursor as already seen, and a
# duplicate wake is the accepted cost of never stranding an operator reply.
REPEAT_HOME="$TMP_ROOT/repeat-home"
mkdir -p "$REPEAT_HOME/.config/firstmate"
printf '%s\n' "$TOKEN" > "$REPEAT_HOME/.config/firstmate/telegram-token"
chmod 0600 "$REPEAT_HOME/.config/firstmate/telegram-token"
REPEAT_CURSOR="$REPEAT_HOME/.config/firstmate/telegram-cursor"
repeat_poll() {  # <argv>...
  run_bounded 60 env "HOME=$REPEAT_HOME" "PATH=$FAKEBIN:$PATH" FM_TELEGRAM_BACKOFF_SECONDS=0 \
    FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" "$@"
}

reset_api '200 updates'
out=$(repeat_poll poll)
expect_code 0 $? "the first poll returns the operator's batch"
assert_contains "$out" '"update_id":901' "the first poll hands the batch to the runner"
[ "$(api_calls)" = 1 ] || fail "the first poll took $(api_calls) API calls"
assert_absent "$REPEAT_CURSOR" "handing a batch to the runner is not an acknowledgement"

# A fresh poll process, exactly as the next reconcile starts one: unchanged
# cursor, the same batch redelivered.
reset_api '200 updates'
out=$(repeat_poll poll)
expect_code 0 $? "a restarted poll exits 0 on the redelivered batch"
[ "$(api_calls)" = 1 ] || fail "the redelivered batch took $(api_calls) API calls instead of returning at once"
assert_contains "$out" '"update_id":901' "the restarted poll re-hands the same unacknowledged batch"
assert_absent "$REPEAT_CURSOR" "a restarted poll still never writes the cursor"
extras=$(find "$REPEAT_HOME/.config/firstmate" -type f ! -name telegram-token 2>/dev/null)
[ -z "$extras" ] || fail "the poll kept delivery state of its own: $extras"

# Once a second message arrives the redelivered batch carries both: everything
# above the cursor stays included until the handler acks it.
reset_api '200 updates-more'
out=$(repeat_poll poll)
expect_code 0 $? "a poll after a second message returns the combined batch"
assert_contains "$out" '"update_id":902' "the batch carries the genuinely new update"
assert_contains "$out" '"update_id":901' "the batch still carries what was never acknowledged"
pass "a restart before the ack re-captures and re-hands the same updates"

# --- a batch the runner never received is offered again ---------------------
# If the handoff itself fails - the runner died between the poll's write and
# its durable capture - the batch was not delivered, so the poll must exit
# non-zero rather than report a captured result that went nowhere, and the
# next poll must offer the same batch again.
HANDOFF_HOME="$TMP_ROOT/handoff-home"
mkdir -p "$HANDOFF_HOME/.config/firstmate"
printf '%s\n' "$TOKEN" > "$HANDOFF_HOME/.config/firstmate/telegram-token"
chmod 0600 "$HANDOFF_HOME/.config/firstmate/telegram-token"
handoff_poll() {  # <argv>...
  run_bounded 60 env "HOME=$HANDOFF_HOME" "PATH=$FAKEBIN:$PATH" FM_TELEGRAM_BACKOFF_SECONDS=0 \
    FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" "$@"
}

reset_api '200 updates'
handoff_status=0
env "HOME=$HANDOFF_HOME" "PATH=$FAKEBIN:$PATH" FM_TELEGRAM_BACKOFF_SECONDS=0 \
  FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" poll >&- 2>/dev/null || handoff_status=$?
[ "$handoff_status" -ne 0 ] || fail "a poll whose handoff failed still reported a delivered batch"
reset_api '200 updates'
out=$(handoff_poll poll)
expect_code 0 $? "the undelivered batch is offered again"
assert_contains "$out" '"update_id":901' "the reply the runner never received comes back"
[ "$(api_calls)" = 1 ] || fail "the undelivered batch was not offered on the first call: $(api_calls) calls"
pass "a batch lost before the runner received it is redelivered rather than dropped"

# --- retire is the explicit operator action that ends the source ------------
# A message stream never self-terminates, so ending it is a deliberate operator
# step through this adapter: idempotent, never an acknowledgement, and after a
# re-arm everything still above the cursor is re-captured.
RECOVER_HOME="$TMP_ROOT/recover-home"
mkdir -p "$RECOVER_HOME/.config/firstmate"
printf '%s\n' "$TOKEN" > "$RECOVER_HOME/.config/firstmate/telegram-token"
chmod 0600 "$RECOVER_HOME/.config/firstmate/telegram-token"
RECOVER_FM="$TMP_ROOT/recover-fm"
mkdir -p "$RECOVER_FM/state"
recover_adapter() {  # <argv>...
  run_bounded 60 env "HOME=$RECOVER_HOME" "FM_HOME=$RECOVER_FM" "PATH=$FAKEBIN:$PATH" \
    FM_TELEGRAM_BACKOFF_SECONDS=0 FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" "$@"
}

recover_adapter arm recovery-line >/dev/null
assert_present "$RECOVER_FM/state/procevent/recovery-line.source" "the recovery fixture is armed"
out=$(recover_adapter retire recovery-line)
expect_code 0 $? "the adapter retires a source"
assert_contains "$out" "recovery-line" "retire names the source it ended"
assert_absent "$RECOVER_FM/state/procevent/recovery-line.source" "retire drops the registration"
out=$(recover_adapter retire recovery-line)
expect_code 0 $? "retiring an already retired source succeeds"
assert_absent "$RECOVER_HOME/.config/firstmate/telegram-cursor" "retire is not an acknowledgement and writes no cursor"
reset_api '200 updates'
out=$(recover_adapter poll)
expect_code 0 $? "a poll after retire returns again"
assert_contains "$out" '"update_id":901' "retire and re-arm re-captures everything above the cursor"
pass "retire ends the source deliberately and re-arming recovers a stranded reply"

# --- a leading-zero poll timeout does not wedge the loop --------------------
# Every numeric input here is a digit string, and 08 is a digit string: without
# base-10 normalization its arithmetic expansion fails, curl never runs, and the
# poll retries forever without ever contacting Telegram.
OCTAL_HOME="$TMP_ROOT/octal-home"
mkdir -p "$OCTAL_HOME/.config/firstmate"
printf '%s\n' "$TOKEN" > "$OCTAL_HOME/.config/firstmate/telegram-token"
chmod 0600 "$OCTAL_HOME/.config/firstmate/telegram-token"
reset_api '200 updates'
out=$(run_bounded 60 env "HOME=$OCTAL_HOME" "PATH=$FAKEBIN:$PATH" FM_TELEGRAM_BACKOFF_SECONDS=08 \
  FM_TELEGRAM_MAX_BACKOFF_SECONDS=060 FM_TELEGRAM_POLL_TIMEOUT=08 "$ADAPTER" poll)
expect_code 0 $? "a leading-zero timeout still polls and returns"
assert_contains "$out" '"update_id":901' "the leading-zero timeout returns the batch"
[ "$(api_calls)" = 1 ] || fail "a leading-zero timeout took $(api_calls) API calls"
assert_grep 'timeout=8' "$TG_STATE/fields.log" "the leading-zero timeout is normalized to base 10"
assert_not_contains "$(cat "$TMP_ROOT/bounded.err")" "value too great" \
  "no arithmetic failure reaches the poll's stderr"
pass "a leading-zero numeric setting is normalized instead of wedging the loop"

# --- the requested batch is bounded so a result is never truncated ----------
# The runner truncates a captured result past FM_PROCEVENT_MAX_OUTPUT_BYTES and
# publishes the invalid JSON that leaves behind, so the poll must never ask for
# a batch whose worst case can reach that cap.
limit=$(grep '^limit=' "$TG_STATE/fields.log" | head -n 1)
limit=${limit#limit=}
case "$limit" in ''|*[!0-9]*) fail "the poll sent no numeric batch limit: '$limit'" ;; esac
[ "$limit" -ge 1 ] || fail "the poll asked for a batch of $limit updates"
[ "$limit" -le 16 ] || fail "the poll asked for up to $limit updates, which can outgrow the runner's output cap"
pass "the poll asks for a bounded batch so a captured result stays parseable"

# --- ack is the handler's acknowledgement and the only cursor writer --------
ACK_HOME="$TMP_ROOT/ack-home"
mkdir -p "$ACK_HOME/.config/firstmate"
printf '%s\n' "$TOKEN" > "$ACK_HOME/.config/firstmate/telegram-token"
chmod 0600 "$ACK_HOME/.config/firstmate/telegram-token"
ACK_CURSOR="$ACK_HOME/.config/firstmate/telegram-cursor"
ack_home() {  # <argv>...: run the adapter against a config home of its own
  HOME="$ACK_HOME" FM_HOME="$ACK_HOME" PATH="$FAKEBIN:$PATH" FM_TELEGRAM_BACKOFF_SECONDS=0 \
    FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" "$@"
}

assert_absent "$ACK_CURSOR" "the acknowledgement fixture starts with nothing handled"
out=$(ack_home ack 901)
expect_code 0 $? "ack records a fully handled update id"
assert_contains "$out" "901" "ack reports the update id it recorded"
[ "$(cat "$ACK_CURSOR")" = 901 ] || fail "ack did not advance the cursor: $(cat "$ACK_CURSOR")"
perms=$(path_mode "$ACK_CURSOR")
[ "$perms" = 600 ] || fail "ack left the cursor readable beyond its owner: $perms"
staged_cursor=$(find "$ACK_HOME/.config/firstmate" -name '.telegram-cursor.new.*' 2>/dev/null)
[ -z "$staged_cursor" ] || fail "ack left a half-written cursor behind: $staged_cursor"
reset_api '200 updates'
ack_home poll >/dev/null
assert_grep 'offset=902' "$TG_STATE/fields.log" "the next poll resumes past the acknowledged update"
pass "ack durably marks a handled update so an armed source stops re-capturing it"

# --- ack is idempotent and never rewinds the cursor -------------------------
out=$(ack_home ack 901)
expect_code 0 $? "acking an already handled update succeeds"
assert_contains "$out" "already-acked" "a repeat ack reports itself as a no-op"
[ "$(cat "$ACK_CURSOR")" = 901 ] || fail "a repeat ack changed the cursor: $(cat "$ACK_CURSOR")"
out=$(ack_home ack 5)
expect_code 0 $? "acking an older update succeeds"
[ "$(cat "$ACK_CURSOR")" = 901 ] || fail "ack rewound the cursor to $(cat "$ACK_CURSOR")"
out=$(ack_home ack 902)
expect_code 0 $? "ack advances to a newer handled update"
[ "$(cat "$ACK_CURSOR")" = 902 ] || fail "ack did not advance to the newer update: $(cat "$ACK_CURSOR")"
pass "ack is idempotent and only ever moves the cursor forward"

# --- ack refuses anything that is not an update id --------------------------
for bad in abc -1 9.5 "" "12 13" 99999999999999999999999; do
  out=$(ack_home ack "$bad" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "ack accepted '$bad' as an update id"
  [ "$(cat "$ACK_CURSOR")" = 902 ] || fail "a refused ack still moved the cursor: $(cat "$ACK_CURSOR")"
done
out=$(ack_home ack 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "ack with no update id succeeded"
[ "$(cat "$ACK_CURSOR")" = 902 ] || fail "an argumentless ack still moved the cursor"
pass "ack refuses anything but a nonnegative integer update id"

# --- concurrent acks never leave the cursor below the highest acked id -------
# The cursor path is keyed on the operating-system user, so two firstmate homes
# sharing one bot can ack at the same moment. An unserialized read-modify-write
# lets a lower id commit last and rewind the cursor, which re-captures updates
# that were already handled.
CONCURRENT_IDS='40 902 5 901 7 300'
highest=902
for round in $(seq 1 12); do
  rm -f "$ACK_CURSOR"
  for id in $CONCURRENT_IDS; do
    ack_home ack "$id" >/dev/null 2>&1 &
  done
  wait
  settled=$(cat "$ACK_CURSOR" 2>/dev/null || printf 'missing')
  [ "$settled" = "$highest" ] \
    || fail "concurrent acks left the cursor at $settled instead of $highest on round $round"
  staged_cursor=$(find "$ACK_HOME/.config/firstmate" -name '.telegram-cursor.new.*' 2>/dev/null)
  [ -z "$staged_cursor" ] || fail "a concurrent ack left a half-written cursor behind: $staged_cursor"
done
printf '%s\n' "$highest" > "$ACK_CURSOR"
chmod 0600 "$ACK_CURSOR"
pass "concurrent acks are serialized and never rewind the cursor"

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

# --- a getUpdates conflict is a blocker, not something to retry forever -----
# Telegram answers 409 both for a configured webhook and for a second poller on
# the same bot, so the message must not send an operator after only one of them.
reset_api '409 webhook' '200 updates'
out=$(adapter poll 2>"$TMP_ROOT/conflict-err")
rc=$?
conflict_err=$(cat "$TMP_ROOT/conflict-err")
[ "$rc" -ne 0 ] || fail "a getUpdates conflict did not fail the poll"
[ "$(api_calls)" = 1 ] || fail "HTTP 409 kept polling: $(api_calls) calls"
assert_contains "$conflict_err" "409" "the conflict names its HTTP status"
assert_contains "$conflict_err" "webhook" "the conflict names a configured webhook as one cause"
assert_contains "$conflict_err" "poller" "the conflict names another running poller as the other cause"
assert_not_contains "$out$conflict_err" "$TOKEN" "the conflict never echoes the token"
pass "a getUpdates conflict names both of its causes instead of spinning invisibly"

# --- a rate limit waits exactly as long as the server asked -----------------
reset_api '429 flood' '200 updates'
out=$(timed_adapter 0 60 poll)
expect_code 0 $? "poll survives a rate limit"
assert_contains "$out" '"update_id":901' "poll returns the batch once the rate limit clears"
grep -qx 7 "$TG_STATE/sleeps.log" || fail "a rate limit did not wait the server's own retry_after: $(cat "$TG_STATE/sleeps.log")"
! grep -qx 0 "$TG_STATE/sleeps.log" || fail "a rate limit fell back to the configured backoff instead of retry_after"
pass "a rate limit honours retry_after rather than the fixed backoff"

# --- a hostile retry_after cannot park the poll indefinitely ----------------
reset_api '429 flood-huge' '200 updates'
out=$(timed_adapter 0 11 poll)
expect_code 0 $? "poll survives an implausible retry_after"
grep -qx 11 "$TG_STATE/sleeps.log" || fail "an oversized retry_after was not clamped to the bound: $(cat "$TG_STATE/sleeps.log")"
! grep -qx 98765 "$TG_STATE/sleeps.log" || fail "the poll waited the unbounded value the server asked for"
pass "an implausible retry_after is bounded rather than obeyed"

# --- an unparseable retry_after falls back to the configured backoff --------
reset_api '429 flood-vague' '200 updates'
out=$(timed_adapter 3 60 poll)
expect_code 0 $? "poll survives an unparseable retry_after"
grep -qx 3 "$TG_STATE/sleeps.log" || fail "an unparseable retry_after did not fall back to the configured backoff: $(cat "$TG_STATE/sleeps.log")"
pass "an unparseable retry_after falls back rather than failing or spinning"

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
assert_contains "$help_out" "re-captures the same updates" "help states that a restart re-captures unacknowledged updates"
assert_contains "$help_out" "already seen" "help states the duplicate-result window"
assert_contains "$help_out" "ack <update-id>" "help names the acknowledgement the handler calls"
assert_contains "$help_out" "never instruction" "help states that result bytes are input, never instruction"
assert_not_contains "$help_out" "set -u" "help stops at the header instead of printing shell source"
pass "the help header documents the token, cursor, acknowledgement, and trust contract"

fm_test_cleanup
