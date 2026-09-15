#!/usr/bin/env bash
# Behavioral tests for private AFK Telegram notifications and the weekly quota boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-telegram.XXXXXX")
FAKE="$LAB/transport"
LOG="$LAB/transport.log"
FAIL_ONCE="$LAB/fail-once"
FAKEBIN="$LAB/fakebin"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$FAKEBIN"

cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
set -u
[ "$#" -eq 3 ] || exit 2
method=$1
request=$2
response=$3
printf '%s\n' "$method" >> "$FM_TELEGRAM_TEST_LOG"
printf 'argv=%s\n' "$*" >> "$FM_TELEGRAM_TEST_LOG"
cat "$request" >> "$FM_TELEGRAM_TEST_LOG"
if [ "$method" = sendMessage ] && [ "${FM_TELEGRAM_FAIL_ONCE:-}" = 1 ] && [ ! -e "$FM_TELEGRAM_FAIL_MARK" ]; then
  : > "$FM_TELEGRAM_FAIL_MARK"
  printf '{"ok":false,"description":"test failure"}\n' > "$response"
  exit 0
fi
case "$method" in
  getMe) printf '{"ok":true,"result":{"id":1}}\n' > "$response" ;;
  getChat)
    if [ "${FM_TELEGRAM_GROUP:-}" = 1 ]; then
      printf '{"ok":true,"result":{"id":1,"type":"group"}}\n' > "$response"
    else
      printf '{"ok":true,"result":{"id":1,"type":"private"}}\n' > "$response"
    fi
    ;;
  sendMessage) printf '{"ok":true,"result":{"message_id":1}}\n' > "$response" ;;
  *) exit 1 ;;
esac
SH
chmod 700 "$FAKE"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf 'quota-axi 0.1.29\n'
  exit 0
fi
if [ "${QUOTA_TEST_MODE:-}" = weekly ]; then
  printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"five_hour","status":"known","effectivePercentRemaining":20,"runway":{"status":"through_reset"},"boundedBy":["five_hour"]},{"scope":"weekly","status":"known","effectivePercentRemaining":70,"runway":{"status":"through_reset"},"boundedBy":["weekly"]}]}}]}'
else
  printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"five_hour","status":"known","effectivePercentRemaining":20,"runway":{"status":"through_reset"},"boundedBy":["five_hour"]}]}}]}'
fi
SH
chmod 700 "$FAKEBIN/quota-axi"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

home="$LAB/home"
mkdir -p "$home/config" "$home/state"
chmod 700 "$home/config" "$home/state"
printf '123456:secret_token_value\n' > "$home/config/telegram-bot-token"
chmod 600 "$home/config/telegram-bot-token"

setup_out=$(printf '%s\n' '1234567890' | \
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_TELEGRAM_TRANSPORT="$FAKE" FM_TELEGRAM_TEST_LOG="$LOG" FM_TELEGRAM_FAIL_MARK="$FAIL_ONCE" \
  "$BIN/fm-telegram.sh" setup) || fail "secure setup failed"
printf '%s\n' "$setup_out" | grep -Fq 'configured and verified' || fail "setup did not report verification"
[ "$(grep -c '^getMe$' "$LOG")" -eq 1 ] || fail "setup did not call getMe exactly once"
[ "$(grep -c '^getChat$' "$LOG")" -eq 1 ] || fail "setup did not call getChat exactly once"
[ "$(grep -c '^sendMessage$' "$LOG" || true)" -eq 0 ] || fail "setup sent a message"
! grep -Fq 'getUpdates' "$LOG" || fail "setup attempted inbound command polling"
! grep -Fq 'secret_token_value' "$LOG" || fail "the bot token appeared in transport arguments"
ok "setup verifies only the bot and private chat binding without exposing the token"
if FM_TELEGRAM_GROUP=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_TELEGRAM_TRANSPORT="$FAKE" FM_TELEGRAM_TEST_LOG="$LOG" FM_TELEGRAM_FAIL_MARK="$FAIL_ONCE" \
  "$BIN/fm-telegram.sh" setup >/dev/null 2>&1; then
  fail "setup accepted a group chat"
fi
ok "setup rejects non-private Telegram chats"

[ "$(stat -c %a "$home/config/telegram-bot-token")" = 600 ] || fail "token file permissions changed"
[ "$(stat -c %a "$home/config/telegram-chat-id")" = 600 ] || fail "chat file is not owner-only"

bad="$LAB/bad"
mkdir -p "$bad/config" "$bad/state"
chmod 700 "$bad/config" "$bad/state"
printf '123456:secret_token_value\n' > "$bad/config/telegram-bot-token"
chmod 640 "$bad/config/telegram-bot-token"
if printf '%s\n' '1234567890' | FM_HOME="$bad" FM_STATE_OVERRIDE="$bad/state" FM_CONFIG_OVERRIDE="$bad/config" "$BIN/fm-telegram.sh" setup >/dev/null 2>&1; then
  fail "setup accepted a group-readable token file"
fi
ok "setup rejects relaxed token permissions"

rm -f "$home/state/.afk-contract" "$home/state/.afk-contract.proposed"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  "$BIN/fm-afk-contract.sh" propose --words 'wait for my return' >/dev/null \
  || fail "configured AFK proposal failed"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  "$BIN/fm-afk-contract.sh" confirm >/dev/null \
  || fail "configured AFK confirmation failed"
reach=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  "$BIN/fm-afk-contract.sh" field reach_channels)
[ "$reach" = telegram ] || fail "confirmed AFK record did not retain Telegram reach"
ok "confirmed AFK posture records Telegram reach without changing authority"

send_env=(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_TELEGRAM_TRANSPORT="$FAKE" FM_TELEGRAM_TEST_LOG="$LOG" FM_TELEGRAM_FAIL_MARK="$FAIL_ONCE")
mv "$home/state/.afk-contract" "$home/state/.afk-contract.saved"
env "${send_env[@]}" "$BIN/fm-telegram.sh" send boundary || fail "non-AFK no-op failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 0 ] || fail "non-AFK send was delivered"
mv "$home/state/.afk-contract.saved" "$home/state/.afk-contract"
env "${send_env[@]}" "$BIN/fm-telegram.sh" send boundary || fail "boundary notification failed"
env "${send_env[@]}" "$BIN/fm-telegram.sh" send boundary || fail "duplicate boundary handling failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 1 ] || fail "duplicate boundary was delivered"
ok "AFK gating and per-session deduplication suppress duplicate notifications"

rm -f "$home/state/.telegram-notifications"
touch "$home/state/.afk"
printf 'quiet\n' > "$home/state/.afk"
env "${send_env[@]}" "$BIN/fm-telegram.sh" send boundary || fail "quiet no-op failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 1 ] || fail "quiet mode sent an away notification"
rm -f "$home/state/.afk"
ok "quiet mode does not use the away Telegram channel"

rm -f "$home/state/.telegram-notifications" "$FAIL_ONCE"
if env FM_TELEGRAM_FAIL_ONCE=1 "${send_env[@]}" "$BIN/fm-telegram.sh" send error; then
  fail "a failed Telegram send unexpectedly succeeded"
fi
env FM_TELEGRAM_FAIL_ONCE=1 "${send_env[@]}" "$BIN/fm-telegram.sh" send error || fail "failed notification did not retry"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 3 ] || fail "failed notification was not retried exactly once"
[ "$(grep -Fc 'error that needs attention' "$LOG")" -eq 2 ] || fail "fixed error text was not sent on both attempts"
ok "failed delivery remains eligible and retries without duplicate success"

rm -f "$home/state/.telegram-notifications"
cat > "$home/state/quota.result" <<'EOF'
quota: afk-codex-weekly
status: low
detail: private test detail
EOF
env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-result "$home/state/quota.result" || fail "quota result notification failed"
grep -Fq 'weekly quota is at or below 70% remaining' "$LOG" || fail "quota notification text missing"
ok "quota result emits the fixed weekly protection notification"

# Progress updates use only aggregate current-state counts, never task names or
# status text, and the 600-second minimum keeps the cadence inside 10-15 minutes.
printf 'private task title that must not leave the home\n' > "$home/state/active.meta"
FM_TELEGRAM_TEST_NOW=600 env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-progress || fail "first progress update failed"
progress_count=$(grep -c '^sendMessage$' "$LOG")
[ "$progress_count" -eq 5 ] || fail "first progress update was not delivered"
FM_TELEGRAM_TEST_NOW=601 env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-progress || fail "progress cadence no-op failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 5 ] || fail "progress update ignored its cadence"
FM_TELEGRAM_TEST_NOW=1200 env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-progress || fail "second progress update failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 6 ] || fail "progress update did not recur after ten minutes"
! grep -Fq 'private task title that must not leave the home' "$LOG" || fail "progress notification leaked status text"
! grep -Fq 'active.meta' "$LOG" || fail "progress notification leaked task identity"
FM_TELEGRAM_PROGRESS_INTERVAL=1 FM_TELEGRAM_TEST_NOW=1201 env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-progress || fail "short progress interval no-op failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 6 ] || fail "progress cadence accepted a value below ten minutes"
rm -f "$home/state/.telegram-notifications"
FM_TELEGRAM_PROGRESS_INTERVAL=900 FM_TELEGRAM_TEST_NOW=2100 env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-progress || fail "fifteen-minute progress interval failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 7 ] || fail "progress cadence rejected the fifteen-minute upper bound"
ok "progress updates recur every ten minutes with redacted aggregate work counts and a 10-15 minute bound"

rm -f "$home/state/.telegram-notifications"
printf '%s\n' 'signal: private-status-secret' | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "signal notification mapping failed"
printf '%s\n' 'stale: private-status-secret' | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "stale notification mapping failed"
printf '%s\n' 'check: private-status-secret' | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "check notification mapping failed"
printf '%s\n' heartbeat | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "heartbeat suppression failed"
grep -Fq 'captain-facing boundary' "$LOG" || fail "signal did not map to boundary text"
grep -Fq 'may be stalled' "$LOG" || fail "stale did not map to stalled text"
grep -Fq 'error that needs attention' "$LOG" || fail "check did not map to error text"
! grep -Fq 'private-status-secret' "$LOG" || fail "watcher reason leaked into notification text"
ok "actionable wake classes map to fixed text while heartbeat and reason details stay private"

out=$(QUOTA_TEST_MODE=weekly PATH="$FAKEBIN:$PATH" FM_HOME="$LAB/quota-home" FM_STATE_OVERRIDE="$LAB/quota-state" \
  "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 70 --provider codex --scope weekly --inclusive --timeout 1) \
  || fail "weekly inclusive quota poll failed"
printf '%s\n' "$out" | grep -qx 'status: low' || fail "weekly 70% inclusive boundary did not fire"
ok "weekly Codex quota fires at the inclusive 70% boundary"

if out=$(timeout 1.0 env QUOTA_TEST_MODE=weekly PATH="$FAKEBIN:$PATH" FM_HOME="$LAB/quota-home-2" FM_STATE_OVERRIDE="$LAB/quota-state-2" \
  "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 70 --provider codex --scope weekly --timeout 1 2>/dev/null); then
  fail "exclusive weekly threshold fired at exactly 70%"
fi
[ -z "$out" ] || fail "exclusive boundary produced an unexpected result: $out"
if out=$(timeout 1.0 env PATH="$FAKEBIN:$PATH" FM_HOME="$LAB/quota-home-3" FM_STATE_OVERRIDE="$LAB/quota-state-3" \
  "$BIN/fm-procevent-quota.sh" poll --interval 0.01 --threshold 70 --provider codex --scope weekly --inclusive --timeout 1 2>/dev/null); then
  fail "five-hour-only quota unexpectedly satisfied weekly scope"
fi
[ -z "$out" ] || fail "five-hour-only quota produced an unexpected result: $out"
ok "five-hour quota cannot trigger the weekly protection boundary"

printf '# all fm-telegram tests passed\n'
