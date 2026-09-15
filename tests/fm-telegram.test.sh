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
if env "${send_env[@]}" "$BIN/fm-telegram.sh" send boundary >/dev/null 2>&1; then
  fail "public sender accepted a direct completion notification"
fi
notify_signal() {
  printf '%s\n%s\n%s\n' "signal:$1" "$2" "$3" | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake
}
mv "$home/state/.afk-contract" "$home/state/.afk-contract.saved"
notify_signal 'task.status' boundary event-1 || fail "non-AFK no-op failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 0 ] || fail "non-AFK send was delivered"
mv "$home/state/.afk-contract.saved" "$home/state/.afk-contract"
notify_signal 'task.status' boundary event-1 || fail "boundary notification failed"
notify_signal 'task.status' boundary event-1 || fail "duplicate boundary handling failed"
notify_signal 'task.status' boundary event-2 || fail "later completion boundary failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 2 ] || fail "event identity did not distinguish boundary notifications"
ok "AFK gating deduplicates replays without suppressing later boundaries"

rm -f "$home/state/.telegram-notifications"
touch "$home/state/.afk"
printf 'quiet\n' > "$home/state/.afk"
notify_signal 'task.status' boundary quiet-event || fail "quiet no-op failed"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 2 ] || fail "quiet mode sent an away notification"
rm -f "$home/state/.afk"
ok "quiet mode does not use the away Telegram channel"

rm -f "$home/state/.telegram-notifications" "$FAIL_ONCE"
printf '%s\n\n%s\n' 'check: failing check' check-event | env FM_TELEGRAM_FAIL_ONCE=1 "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "failed notification did not recover with an in-call retry"
printf '%s\n\n%s\n' 'check: failing check' check-event | env FM_TELEGRAM_FAIL_ONCE=1 "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "duplicate notification handling failed after in-call retry"
[ "$(grep -c '^sendMessage$' "$LOG")" -eq 4 ] || fail "failed notification was not retried exactly once in-call"
[ "$(grep -Fc 'error that needs attention' "$LOG")" -eq 2 ] || fail "fixed error text was not sent on both in-call attempts"
ok "failed delivery retries once in-call without duplicate success"

rm -f "$home/state/.telegram-notifications"
generic_before=$(grep -c '^sendMessage$' "$LOG")
for generic_source in quota quota-codex; do
  cat > "$home/state/quota.result" <<EOF
quota: $generic_source
status: low
detail: generic source must stay outside the AFK channel
EOF
  env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-result "$home/state/quota.result" || fail "generic quota result handling failed"
done
generic_after=$(grep -c '^sendMessage$' "$LOG")
[ "$generic_after" -eq "$generic_before" ] || fail "generic quota source produced a private AFK alert"
ok "generic quota sources do not produce weekly AFK alerts"

reserved_home="$LAB/reserved-quota-home"
for unsupported in --scope --inclusive --source-id; do
  if PATH="$FAKEBIN:$PATH" FM_HOME="$reserved_home" FM_STATE_OVERRIDE="$reserved_home/state" \
    "$BIN/fm-procevent-quota.sh" arm "$unsupported" weekly >/dev/null 2>&1; then
    fail "generic quota arm accepted AFK-only option: $unsupported"
  fi
done
PATH="$FAKEBIN:$PATH" FM_HOME="$reserved_home" FM_STATE_OVERRIDE="$reserved_home/state" \
  "$BIN/fm-procevent-quota.sh" arm-afk --interval 0.01 >/dev/null \
  || fail "fixed AFK quota source did not arm"
ok "weekly AFK quota is available only through its fixed arm path"

cat > "$home/state/quota.result" <<'EOF'
quota: afk-codex-weekly
status: low
detail: private test detail
EOF
env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-result "$home/state/quota.result" || fail "quota result notification failed"
grep -Fq 'weekly quota is at or below 70% remaining' "$LOG" || fail "quota notification text missing"
ok "quota result emits the fixed weekly protection notification"

cat > "$home/state/quota.result" <<'EOF'
quota: afk-codex-weekly
status: error
detail: quota check failed
EOF
quota_error_before=$(grep -c '^sendMessage$' "$LOG")
env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-result "$home/state/quota.result" || fail "quota error result notification failed"
printf '%s\n' 'check: process-event afk-codex-weekly error' | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "reserved quota check suppression failed"
quota_error_after=$(grep -c '^sendMessage$' "$LOG")
[ "$quota_error_after" -eq $((quota_error_before + 1)) ] || fail "reserved quota error produced duplicate notifications"
ok "reserved quota errors notify only from their owned result"

watch_signal_metadata() {
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    signal_files_actionable "$2" || true
    printf "%s\t%s\n" "$FM_SIGNAL_TELEGRAM_KIND" "$FM_SIGNAL_TELEGRAM_IDENTITY"
  ' _ "$BIN/fm-watch.sh" "$1"
}
failed_status="$home/state/failed-signal.status"
done_status="$home/state/done-signal.status"
printf 'failed: worker command exited nonzero\n' > "$failed_status"
printf 'done: final work complete\n' > "$done_status"
IFS=$'\t' read -r failed_kind failed_identity <<< "$(watch_signal_metadata "$failed_status")"
IFS=$'\t' read -r done_kind done_identity <<< "$(watch_signal_metadata "$done_status")"
IFS=$'\t' read -r unreadable_kind unreadable_identity <<< "$(
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    status_span_first_actionable_record() { return 2; }
    signal_files_actionable "$2" || true
    printf "%s\t%s\n" "$FM_SIGNAL_TELEGRAM_KIND" "$FM_SIGNAL_TELEGRAM_IDENTITY"
  ' _ "$BIN/fm-watch.sh" "$failed_status"
)"
[ "$failed_kind" = error ] || fail "watcher did not classify failed status as an error notification"
[ "$done_kind" = boundary ] || fail "watcher did not classify done status as a boundary notification"
[ "$unreadable_kind" = error ] || fail "watcher suppressed an unclassifiable status signal"
[ -n "$unreadable_identity" ] || fail "unclassifiable status signal omitted its event identity"
rm -f "$home/state/.telegram-notifications"
printf '%s\n' 'signal: private-status-secret' | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "routine signal suppression failed"
notify_signal 'failed.status' "$failed_kind" "$failed_identity" || fail "failed signal notification mapping failed"
notify_signal 'done.status' "$done_kind" "$done_identity" || fail "done signal notification mapping failed"
notify_signal 'unreadable.status' "$unreadable_kind" "$unreadable_identity" || fail "unclassifiable signal notification mapping failed"
printf '%s\n\n%s\n' 'stale: private-status-secret' stale-event | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "stale notification mapping failed"
printf '%s\n\n%s\n' 'check: private-status-secret' check-event-2 | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "check notification mapping failed"
printf '%s\n' heartbeat | env "${send_env[@]}" "$BIN/fm-telegram.sh" notify-wake || fail "heartbeat suppression failed"
[ "$(grep -Fc 'captain-facing boundary' "$LOG")" -ge 1 ] || fail "classified completion did not map to boundary text"
[ "$(grep -Fc 'error that needs attention' "$LOG")" -ge 2 ] || fail "classified failures did not map to error text"
grep -Fq 'may be stalled' "$LOG" || fail "stale did not map to stalled text"
! grep -Fq 'private-status-secret' "$LOG" || fail "watcher reason leaked into notification text"
ok "classified watcher events map to fixed text while routine signals stay silent"

out=$(QUOTA_TEST_MODE=weekly PATH="$FAKEBIN:$PATH" FM_HOME="$LAB/quota-home" FM_STATE_OVERRIDE="$LAB/quota-state" \
  "$BIN/fm-procevent-quota.sh" poll-afk --interval 0.01) \
  || fail "weekly inclusive quota poll failed"
printf '%s\n' "$out" | grep -qx 'status: low' || fail "weekly 70% inclusive boundary did not fire"
ok "weekly Codex quota fires at the inclusive 70% boundary"

if out=$(timeout 1.0 env PATH="$FAKEBIN:$PATH" FM_HOME="$LAB/quota-home-3" FM_STATE_OVERRIDE="$LAB/quota-state-3" \
  "$BIN/fm-procevent-quota.sh" poll-afk --interval 0.01 2>/dev/null); then
  fail "five-hour-only quota unexpectedly satisfied weekly scope"
fi
[ -z "$out" ] || fail "five-hour-only quota produced an unexpected result: $out"
ok "five-hour quota cannot trigger the weekly protection boundary"

printf '# all fm-telegram tests passed\n'
