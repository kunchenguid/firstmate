#!/usr/bin/env bash
# Behavior tests for the Slack captain channel poll/post clients and bootstrap
# activation. Hermetic via a fakebin curl; jq stays real.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-slack-captain-tests)
CHANNEL_ID=C0BQ9K1TJKG
BOT_USER=U_BOT12345
CAPTAIN_USER=U_CAPTAIN1
ACK_TEXT='On it.'

make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -m|-w) shift 2 ;;
    -s*) shift ;;
    -H) shift 2 ;;
    --data) data=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FM_SLACK_CURL_LOG:-}" ]; then
  printf 'url=%s\ndata=%s\n' "$url" "$data" >> "$FM_SLACK_CURL_LOG"
fi
case "$url" in
  */auth.test)
    body=$(printf '{"ok":true,"user_id":"%s"}' "${FAKE_SLACK_BOT_USER:-U_BOT}")
    ;;
  */conversations.history)
    body="${FAKE_SLACK_HISTORY:-{\"ok\":true,\"messages\":[]}}"
    ;;
  */conversations.replies)
    body="${FAKE_SLACK_REPLIES:-{\"ok\":true,\"messages\":[]}}"
    ;;
  */chat.postMessage)
    if [ -n "${FAKE_SLACK_POST:-}" ]; then
      body=$FAKE_SLACK_POST
    else
      body=$(printf '{"ok":true,"ts":"1786735224.690829","channel":"%s"}' "${FAKE_SLACK_CHANNEL:-C0BQ9K1TJKG}")
    fi
    ;;
  */chat.update)
    if [ -n "${FAKE_SLACK_UPDATE:-}" ]; then
      body=$FAKE_SLACK_UPDATE
    else
      body=$(printf '{"ok":true,"ts":"1786735224.690829","channel":"%s"}' "${FAKE_SLACK_CHANNEL:-C0BQ9K1TJKG}")
    fi
    ;;
  *)
    body='{"ok":false,"error":"unknown_method"}'
    ;;
esac
if [ -n "$ofile" ]; then
  printf '%s' "$body" > "$ofile"
else
  printf '%s' "$body"
fi
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

make_home() {
  local dir=$1
  mkdir -p "$dir/config" "$dir/state"
  chmod 700 "$dir/config" "$dir/state"
  printf 'FM_SLACK_BOT_TOKEN=xoxb-synthetic-test-token\n' > "$dir/.env"
  chmod 600 "$dir/.env"
  printf '%s\n' "$CHANNEL_ID" > "$dir/config/slack-captain-channel"
  chmod 600 "$dir/config/slack-captain-channel"
}

run_poll() {
  local home=$1 fakebin=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-slack-poll.sh"
}

run_post() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-slack-post.sh" "$@"
}

count_ack_posts() {
  local log=$1 encoded
  encoded=$(printf '%s' "$ACK_TEXT" | jq -sRr @uri)
  awk -v t="$encoded" '
    index($0, "method=chat.postMessage") && index($0, "thread_ts=") && index($0, "text=" t) { n++ }
    END { print n + 0 }
  ' "$log"
}

# --- poll inert defaults ----------------------------------------------------

home="$TMP_ROOT/inert"
mkdir -p "$home/state"
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-slack-poll.sh"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "poll must be inert without token and channel"
pass "fm-slack-poll is inert without configuration"

home="$TMP_ROOT/token-only"
make_home "$home"
rm -f "$home/config/slack-captain-channel"
out=$(run_poll "$home" "$(make_fake_curl "$home/fake1")"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "poll must be inert without channel id"
pass "fm-slack-poll is inert without channel id"

# --- poll wake + ack --------------------------------------------------------

home="$TMP_ROOT/wake"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake2")
log="$home/curl-wake.log"
: > "$log"
export FM_SLACK_CURL_LOG=$log
export FAKE_SLACK_BOT_USER=$BOT_USER
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[{"type":"message","user":"'"$CAPTAIN_USER"'","text":"status","ts":"1786735224.690829"}]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] || fail "poll wake exited $rc"
printf -v expected 'slack-captain-message %s\t%s' "1786735224.690829" "status"
[ "$out" = "$expected" ] || fail "poll wake line wrong: $out"
[ -f "$home/state/slack-inbox/1786735224.690829.json" ] \
  || fail "poll must stash inbox payload"
[ "$(count_ack_posts "$log")" -eq 1 ] \
  || fail "poll must post exactly one threaded ack"
grep -F 'thread_ts=1786735224.690829' "$log" >/dev/null \
  || fail "ack must thread on the captain message"
pass "fm-slack-poll acks and wakes with captain message text"

out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "poll must stay silent for an already offered message"
[ "$(count_ack_posts "$log")" -eq 1 ] \
  || fail "poll must not re-ack an already acked message"
pass "fm-slack-poll does not re-wake or re-ack an offered message"

# --- ack survives watcher restart -------------------------------------------

home="$TMP_ROOT/restart"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-restart")
log="$home/curl-restart.log"
: > "$log"
export FM_SLACK_CURL_LOG=$log
export FAKE_SLACK_BOT_USER=$BOT_USER
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[{"type":"message","user":"'"$CAPTAIN_USER"'","text":"ping","ts":"1786735225.111111"}]}'
# shellcheck source=bin/fm-x-lib.sh
. "$ROOT/bin/fm-x-lib.sh"
printf '%s\n' "1786735225.111111" \
  | fmx_private_artifact_publish_stdin "$home/state/slack-acked" "1786735225.111111" 600 \
  || fail "restart setup could not seed ack marker"
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] || fail "restart poll exited $rc"
printf -v expected 'slack-captain-message %s\t%s' "1786735225.111111" "ping"
[ "$out" = "$expected" ] || fail "restart poll wake wrong: $out"
[ "$(count_ack_posts "$log")" -eq 0 ] \
  || fail "restart poll must not re-post the ack when marker survives"
pass "fm-slack-poll keeps ack idempotent across watcher restart"

# --- ignore bot messages ----------------------------------------------------

home="$TMP_ROOT/bot-only"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-bot")
log="$home/curl-bot.log"
: > "$log"
export FM_SLACK_CURL_LOG=$log
export FAKE_SLACK_BOT_USER=$BOT_USER
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[{"type":"message","user":"'"$BOT_USER"'","text":"'"$ACK_TEXT"'","ts":"1786735226.222222"}]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "poll must ignore the bot's own messages"
[ "$(count_ack_posts "$log")" -eq 0 ] \
  || fail "poll must not ack bot messages"
pass "fm-slack-poll ignores bot messages including its own ack"

# --- channel enforcement ----------------------------------------------------

home="$TMP_ROOT/refuse-channel"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake3")
unset FM_SLACK_CURL_LOG
export FAKE_SLACK_CHANNEL=C_WRONGCHAN
export FAKE_SLACK_POST='{"ok":true,"ts":"1786735224.690829","channel":"C_WRONGCHAN"}'
if run_post "$home" "$fakebin" message "hello" >/dev/null 2>&1; then
  fail "post must refuse when response channel mismatches configuration"
fi
pass "fm-slack-post refuses a mismatched response channel"

log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG=$log
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[]}'
run_poll "$home" "$fakebin" >/dev/null || true
grep -F "channel=$CHANNEL_ID" "$log" >/dev/null \
  || fail "poll must request only the configured channel"
! grep -F 'conversations.list' "$log" >/dev/null \
  || fail "poll must never call conversations.list"
pass "fm-slack-poll reads only the configured channel"

# --- post board update ------------------------------------------------------

home="$TMP_ROOT/board"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake4")
unset FM_SLACK_CURL_LOG FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
ts=$(run_post "$home" "$fakebin" board "board v1")
[ "$ts" = "1786735224.690829" ] || fail "board post must return ts"
[ -f "$home/state/slack-board.meta" ] || fail "board meta must be recorded"
ts2=$(run_post "$home" "$fakebin" board "board v2")
[ "$ts2" = "1786735224.690829" ] || fail "board update must return same ts"
pass "fm-slack-post board creates then updates in place"

# --- bootstrap activation ---------------------------------------------------

home="$TMP_ROOT/bootstrap-on"
make_home "$home"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null
[ -x "$home/state/slack-watch.check.sh" ] \
  || fail "bootstrap must arm slack-watch.check.sh when configured"
[ -f "$home/config/slack-captain.env" ] \
  || fail "bootstrap must write slack cadence config"
grep -F 'export FM_SLACK_CHECK_INTERVAL=15' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must export the Slack fast cadence only"
! grep -F 'FM_CHECK_INTERVAL' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must not lower the global check interval"
pass "bootstrap arms Slack poll when token and channel are configured"

home="$TMP_ROOT/bootstrap-off"
mkdir -p "$home/state" "$home/config"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null
[ ! -e "$home/state/slack-watch.check.sh" ] \
  || fail "bootstrap must not arm Slack without configuration"
pass "bootstrap stays silent without Slack configuration"

# --- shim validation --------------------------------------------------------

home="$TMP_ROOT/shim"
make_home "$home"
shim="$home/state/slack-watch.check.sh"
# shellcheck source=bin/fm-slack-lib.sh
. "$ROOT/bin/fm-slack-lib.sh"
fms_poll_shim_content "$home" "$ROOT" > "$shim"
chmod 0700 "$shim"
fms_poll_shim_valid "$shim" "$home" "$ROOT" \
  || fail "generated shim must validate"
pass "slack-watch.check.sh shim validates against fm-slack-poll.sh"

printf 'ok - %s tests passed\n' 13
