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
ofile="" url="" data="" thread_ts=""
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
case "$data" in
  *thread_ts=*) thread_ts=${data##*thread_ts=} ;;
esac
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
    if [ -n "${FAKE_SLACK_JOIN_TS:-}" ] && [ "$thread_ts" = "$FAKE_SLACK_JOIN_TS" ]; then
      body='{"ok":false,"error":"cannot_reply_to_message"}'
    elif [ -n "${FAKE_SLACK_POST:-}" ]; then
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

# --- ack marker without offer marker (independent of offer dedup) ------------

home="$TMP_ROOT/ack-only"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-ack-only")
log="$home/curl-ack-only.log"
: > "$log"
export FM_SLACK_CURL_LOG=$log
export FAKE_SLACK_BOT_USER=$BOT_USER
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[{"type":"message","user":"'"$CAPTAIN_USER"'","text":"follow up","ts":"1786735227.333333"}]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] || fail "ack-only setup poll exited $rc"
[ -n "$out" ] || fail "ack-only setup poll must wake once"
[ "$(count_ack_posts "$log")" -eq 1 ] || fail "ack-only setup must post one ack"
rm -f "$home/state/slack-offered/1786735227.333333"
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] || fail "ack-only retry poll exited $rc"
[ -n "$out" ] || fail "ack-only retry must wake without the offer marker"
[ "$(count_ack_posts "$log")" -eq 1 ] \
  || fail "ack-only retry must not re-post when the ack marker survives alone"
pass "fm-slack-poll keeps ack idempotent without the offer marker"

# --- thread reply after older parents were offered ----------------------------
# Uses Slack-semantics fake curl (history honours oldest=; replies only via parent ts).

make_semantic_fake_curl() {
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
STORE=$FAKE_STORE
urldec() { printf '%b' "${1//%/\\x}"; }
field() { printf '%s' "$data" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
oldest=$(urldec "$(field oldest)"); [ -n "$oldest" ] || oldest=0
ts=$(urldec "$(field ts)")
thread_ts=$(urldec "$(field thread_ts)")
text=$(urldec "$(field text)")
case "$url" in
  */auth.test) body='{"ok":true,"user_id":"U_BOT12345"}' ;;
  */conversations.history)
    body=$(jq -c --arg o "$oldest" '
      . as $all
      | { ok:true, messages: [
            $all[]
            | select(.thread_ts == null)
            | select((.ts|tonumber) > ($o|tonumber))
            | . as $m
            | $m + {reply_count: ([ $all[] | select(.thread_ts == $m.ts) ] | length)} ] }' "$STORE") ;;
  */conversations.replies)
    body=$(jq -c --arg p "$ts" --arg o "$oldest" '
      { ok:true, messages: [ .[]
          | select(.ts == $p or .thread_ts == $p)
          | select((.ts|tonumber) > ($o|tonumber)) ] }' "$STORE") ;;
  */chat.postMessage)
    newts=$(jq -r '[.[].ts|tonumber]|max|.+0.000001|tostring' "$STORE")
    jq -c --arg t "$newts" --arg x "$text" --arg th "$thread_ts" \
      '. + [ ({ts:$t, text:$x, user:"U_BOT12345", bot_id:"B_FM1"} + (if $th=="" then {} else {thread_ts:$th} end)) ]' \
      "$STORE" > "$STORE.new" && mv "$STORE.new" "$STORE"
    body=$(printf '{"ok":true,"ts":"%s","channel":"C0BQ9K1TJKG"}' "$newts") ;;
  *) body='{"ok":false,"error":"unknown_method"}' ;;
esac
if [ -n "$ofile" ]; then printf '%s' "$body" > "$ofile"; else printf '%s' "$body"; fi
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

run_semantic_poll() {
  local home=$1 fakebin=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    FAKE_STORE="$home/fake-store.json" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-slack-poll.sh"
}

home="$TMP_ROOT/thread-reply"
make_home "$home"
fakebin=$(make_semantic_fake_curl "$home/fake-thread")
parent_ts=101.000100
newer_ts=103.000100
reply_ts=104.000100
jq -n --arg p "$parent_ts" --arg n "$newer_ts" --arg cap "$CAPTAIN_USER" \
  '[{ts:$p,text:"action item",user:$cap},
    {ts:$n,text:"newer note",user:$cap}]' > "$home/fake-store.json"
out=$(run_semantic_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -n "$out" ] || fail "thread setup poll1 must offer the older parent"
out=$(run_semantic_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -n "$out" ] || fail "thread setup poll2 must offer the newer note"
jq --arg p "$parent_ts" --arg r "$reply_ts" --arg cap "$CAPTAIN_USER" \
  '. + [{ts:$r,thread_ts:$p,text:"yes merge it",user:$cap}]' "$home/fake-store.json" \
  > "$home/fake-store.next" && mv "$home/fake-store.next" "$home/fake-store.json"
out=$(run_semantic_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] || fail "thread reply poll exited $rc"
printf -v expected 'slack-captain-message %s\t%s' "$reply_ts" "yes merge it"
[ "$out" = "$expected" ] || fail "thread reply poll must wake with the in-thread answer: $out"
pass "fm-slack-poll still sees thread replies after older parents were offered"

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

# --- argv must not carry the bot token --------------------------------------

home="$TMP_ROOT/argv"
make_home "$home"
argv_token=xoxb-SENTINEL-DO-NOT-LOG-9999
printf 'FM_SLACK_BOT_TOKEN=%s\n' "$argv_token" > "$home/.env"
chmod 600 "$home/.env"
argvlog="$home/argv-capture.log"
: > "$argvlog"
cat > "$home/capture-curl" <<SH
#!/usr/bin/env bash
printf '=== invocation ===\n' >> "$argvlog"
for a in "\$@"; do printf '%s\n' "\$a" >> "$argvlog"; done
ofile=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) ofile=\$2; shift 2 ;;
    *) shift ;;
  esac
done
body='{"ok":true,"user_id":"U_BOT12345"}'
if [ -n "\$ofile" ]; then printf '%s' "\$body" > "\$ofile"; else printf '%s' "\$body"; fi
exit 0
SH
chmod +x "$home/capture-curl"
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[]}'
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$home/capture-curl" \
  PATH="$BASE_PATH" \
  "$ROOT/bin/fm-slack-poll.sh" >/dev/null 2>&1
if rg -q -- "$argv_token" "$argvlog" 2>/dev/null; then
  fail "poll must keep the bot token out of curl argv"
fi
pass "fm-slack-poll keeps the bot token out of curl argv"

# --- channel_join is never a captain message -------------------------------

home="$TMP_ROOT/channel-join"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-join")
join_ts=1786735228.100000
captain_ts=1786735229.100000
control="$home/fake-control.json"
FAKE_SLACK_JOIN_TS=$join_ts "$fakebin/curl" -o "$control" \
  --data "thread_ts=$join_ts" https://slack.test/api/chat.postMessage
[ "$(jq -r '.error // empty' "$control")" = "cannot_reply_to_message" ] \
  || fail "fake Slack transport must reject threaded ack on channel_join"
pass "fake Slack transport models channel_join ack rejection"
export FAKE_SLACK_JOIN_TS=$join_ts
unset FAKE_SLACK_POST
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[
  {"type":"message","subtype":"channel_join","user":"'"$CAPTAIN_USER"'","text":"<@U_CAPTAIN1> has joined the channel","ts":"'"$join_ts"'"},
  {"type":"message","user":"'"$CAPTAIN_USER"'","text":"new captain request","ts":"'"$captain_ts"'"}
]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
printf -v expected 'slack-captain-message %s\t%s' "$captain_ts" "new captain request"
[ "$rc" -eq 0 ] && [ "$out" = "$expected" ] \
  || fail "poll must skip oldest channel_join and select the genuine captain message (rc=$rc output=$out)"
pass "fm-slack-poll never selects channel_join as a captain message"
unset FAKE_SLACK_JOIN_TS

# --- API allowlist ----------------------------------------------------------

home="$TMP_ROOT/allowlist"
make_home "$home"
trap_curl=$(mktemp "${TMPDIR:-/tmp}/fm-slack-trap-curl.XXXXXX")
cat > "$trap_curl" <<'SH'
#!/usr/bin/env bash
printf 'curl must not run for blocked Slack methods\n' >&2
exit 42
SH
chmod +x "$trap_curl"
# shellcheck source=bin/fm-slack-lib.sh
. "$ROOT/bin/fm-slack-lib.sh"
FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SLACK_BOT_TOKEN=xoxb-test FM_SLACK_CAPTAIN_CHANNEL_ID=$CHANNEL_ID \
  FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$trap_curl" \
  fms_load_config
rc=0
fms_api_post conversations.list 'channel=test' /dev/null 2>/dev/null || rc=$?
rm -f -- "$trap_curl"
[ "$rc" -eq 1 ] || fail "API allowlist must refuse conversations.list before curl (rc=$rc)"
pass "fm-slack API allowlist refuses conversations.list"

# --- invalid channel id format ----------------------------------------------

home="$TMP_ROOT/bad-channel"
make_home "$home"
# shellcheck source=bin/fm-slack-lib.sh
. "$ROOT/bin/fm-slack-lib.sh"
fms_channel_id_valid 'not-a-channel' 2>/dev/null \
  && fail "must reject an invalid configured channel id"
fms_channel_id_valid "$CHANNEL_ID" || fail "must accept a valid configured channel id"
printf 'not-a-channel\n' > "$home/config/slack-captain-channel"
out=$(run_poll "$home" "$(make_fake_curl "$home/fake-badchan")"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "poll must stay inert with an invalid configured channel id"
pass "fm-slack-poll stays inert with an invalid channel id"

# --- watcher globals stay narrow --------------------------------------------

grep -F 'CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}' "$ROOT/bin/fm-watch.sh" >/dev/null \
  || fail "fm-watch.sh must keep the global CHECK_INTERVAL default at 300"
grep -F 'SLACK_CHECK_INTERVAL=${FM_SLACK_CHECK_INTERVAL:-$POLL}' "$ROOT/bin/fm-watch.sh" >/dev/null \
  || fail "fm-watch.sh must use a dedicated Slack fast interval"
! grep -E '^CHECK_INTERVAL=\$\{FM_SLACK_CHECK_INTERVAL' "$ROOT/bin/fm-watch.sh" >/dev/null \
  || fail "fm-watch.sh must not route Slack cadence through CHECK_INTERVAL"
awk '/elif.*slack-watch\.check\.sh/ { getline; if ($0 ~ /continue/) found=1 } END { exit found ? 0 : 1 }' \
  "$ROOT/bin/fm-watch.sh" \
  || fail "fm-watch.sh must skip the Slack shim in the slow sweep"
pass "fm-watch.sh keeps the global check interval and a dedicated Slack fast path"

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

home="$TMP_ROOT/board-channel"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-boardchan")
# shellcheck source=bin/fm-x-lib.sh
. "$ROOT/bin/fm-x-lib.sh"
unset FM_SLACK_CURL_LOG FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
run_post "$home" "$fakebin" board "board v1" >/dev/null \
  || fail "board setup post must succeed"
printf 'channel=C_WRONGCHAN\nts=1786735224.690829\n' \
  | fmx_private_artifact_publish_stdin "$home/state" "slack-board.meta" 600 \
  || fail "board channel mismatch setup failed"
if run_post "$home" "$fakebin" board "board v2" >/dev/null 2>&1; then
  fail "board update must refuse a mismatched stored channel"
fi
pass "fm-slack-post board refuses a mismatched stored channel"

# --- invalid thread ts ------------------------------------------------------

home="$TMP_ROOT/bad-ts"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-badts")
if run_post "$home" "$fakebin" message "hello" 'not-a-ts' >/dev/null 2>&1; then
  fail "post must refuse an invalid thread_ts"
fi
pass "fm-slack-post refuses an invalid thread_ts"

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
printf '\n# tamper\n' >> "$shim"
if fms_poll_shim_valid "$shim" "$home" "$ROOT" 2>/dev/null; then
  fail "tampered slack-watch.check.sh shim must not validate"
fi
pass "slack-watch.check.sh shim rejects tampering"
