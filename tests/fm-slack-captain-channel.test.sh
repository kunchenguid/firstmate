#!/usr/bin/env bash
# Behavior tests for the Slack captain channel poll/post clients and bootstrap
# activation. Hermetic via a fakebin curl; jq stays real.
set -u

# shellcheck source=tests/slack-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/slack-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-slack-captain-tests)

private_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

count_ack_reactions() {
  local log=$1
  awk 'index($0, "method=reactions.add") && index($0, "name=eyes") { n++ } END { print n + 0 }' "$log"
}

count_ack_posts() {
  local log=$1
  awk 'index($0, "method=chat.postMessage") && index($0, "thread_ts=") { n++ } END { print n + 0 }' "$log"
}

test_poll_continues_after_bot_cache_write_failure() {
  local home fakebin log out rc
  home="$TMP_ROOT/bot-cache-write-failure"
  make_home "$home"
  mkdir "$home/state/slack-bot-user"
  chmod 755 "$home/state/slack-bot-user"
  fakebin=$(make_fake_curl "$home/fake-cache-failure")
  log="$home/curl.log"
  : > "$log"
  export FM_SLACK_CURL_LOG="$log"
  export FAKE_SLACK_BOT_USER="$BOT_USER"
  export FAKE_SLACK_CHANNEL="$CHANNEL_ID"
  export FAKE_SLACK_HISTORY='{"ok":true,"messages":[{"type":"message","user":"U_CAPTAIN1","text":"cache failure still wakes","ts":"1786735226.111111"}]}'
  out=$(run_poll "$home" "$fakebin"); rc=$?
  [ "$rc" -eq 0 ] || fail "poll must continue after a bot cache publication failure"
  [[ "$out" == *"slack-captain-message 1786735226.111111"* ]] \
    || fail "poll must still collect messages after a bot cache publication failure: $out"
  [[ "$out" != *"auth.test failed"* ]] \
    || fail "poll must not misreport a bot cache publication failure as auth.test failed"
  [[ "$out" == *"slack-captain-warning bot user cache publication failed"* ]] \
    || fail "poll must surface the bot cache publication failure distinctly"
  grep -F '/conversations.history' "$log" >/dev/null \
    || fail "poll must reach conversations.history after a bot cache publication failure"
  pass "fm-slack-poll continues after a successful auth with a failed bot cache publication"
}

test_poll_continues_after_bot_cache_write_failure

test_private_artifact_path_works_under_public_state() {
  local home fakebin out rc
  home="$TMP_ROOT/public-state-success"
  make_home "$home"
  chmod 755 "$home/state"
  fakebin=$(make_fake_curl "$home/fake-public-state")
  export FAKE_SLACK_HISTORY='{"ok":true,"messages":[]}'
  out=$(run_poll "$home" "$fakebin"); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] \
    || fail "private artifact publication under a public state parent must stay quiet"
  [ "$(private_mode "$home/state/slack-bot-user")" = 700 ] \
    || fail "bot cache directory must be mode 700 under a public state parent"
  [ "$(private_mode "$home/state/slack-bot-user/slack-bot-user")" = 600 ] \
    || fail "bot cache file must be mode 600 under a public state parent"
  pass "private artifact publication succeeds under a public state parent"
}

test_private_artifact_path_works_under_public_state

# A curl that always fails at the transport level, so the poll reaches its
# error-marker path without any Slack API response.
make_failing_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

test_poll_error_marker_dedupes_under_public_state() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-error-public-state"
  make_home "$home"
  chmod 755 "$home/state"
  fakebin=$(make_failing_curl "$home/fake-down")
  out=$(run_poll "$home" "$fakebin"); rc=$?
  [ "$rc" -eq 0 ] || fail "poll error exit must stay 0 under a public state parent"
  [ "$out" = "slack-captain-error auth.test failed" ] \
    || fail "poll must emit its error diagnostic under a public state parent: $out"
  [ "$(private_mode "$home/state/slack-poll.error")" = 700 ] \
    || fail "poll error marker directory must be private under a public state parent"
  [ "$(private_mode "$home/state/slack-poll.error/slack-poll.error")" = 600 ] \
    || fail "poll error marker must be a private file under a public state parent"
  out=$(run_poll "$home" "$fakebin"); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] \
    || fail "a persisted poll error marker must dedupe the repeat diagnostic: $out"
  pass "fm-slack-poll error marker publishes and dedupes under a public state parent"
}

test_poll_error_marker_dedupes_under_public_state

test_poll_error_publication_failure_is_loud() {
  local home fakebin err out rc
  home="$TMP_ROOT/poll-error-write-failure"
  make_home "$home"
  mkdir "$home/state/slack-poll.error"
  chmod 755 "$home/state/slack-poll.error"
  fakebin=$(make_failing_curl "$home/fake-loud")
  err="$home/stderr"
  out=$(run_poll "$home" "$fakebin" 2>"$err"); rc=$?
  [ "$rc" -eq 0 ] || fail "poll must continue after an error marker publication failure"
  [ "$out" = "slack-captain-error auth.test failed" ] \
    || fail "poll must still emit its diagnostic after a marker publication failure: $out"
  grep -F "failed to publish Slack poll error marker" "$err" >/dev/null \
    || fail "poll must report its own error marker publication failure"
  pass "fm-slack-poll surfaces an error marker publication failure"
}

test_poll_error_publication_failure_is_loud

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
[ "$(count_ack_reactions "$log")" -eq 1 ] \
  || fail "poll must add exactly one received reaction"
[ "$(count_ack_posts "$log")" -eq 0 ] \
  || fail "poll must not post a threaded ack message"
grep -F 'timestamp=1786735224.690829' "$log" >/dev/null \
  || fail "ack reaction must target the captain message"
pass "fm-slack-poll reacts and wakes with captain message text"

out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "poll must stay silent for an already offered message"
[ "$(count_ack_reactions "$log")" -eq 1 ] \
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
[ "$(count_ack_reactions "$log")" -eq 0 ] \
  || fail "restart poll must not re-add the ack when marker survives"
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
[ "$(count_ack_reactions "$log")" -eq 1 ] || fail "ack-only setup must add one reaction"
rm -f "$home/state/slack-offered/1786735227.333333"
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] || fail "ack-only retry poll exited $rc"
[ -n "$out" ] || fail "ack-only retry must wake without the offer marker"
[ "$(count_ack_reactions "$log")" -eq 1 ] \
  || fail "ack-only retry must not re-add when the ack marker survives alone"
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
  */reactions.add) body='{"ok":true}' ;;
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
[ "$rc" -eq 0 ] || fail "thread setup poll1 failed"
printf -v expected 'slack-captain-message %s\t%s\nslack-captain-message %s\t%s' \
  "$parent_ts" "action item" "$newer_ts" "newer note"
[ "$out" = "$expected" ] || fail "thread setup poll1 must offer both pending messages: $out"
out=$(run_semantic_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "thread setup poll2 must not duplicate either message: $out"
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
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[{"type":"message","user":"'"$BOT_USER"'","text":"eyes","ts":"1786735226.222222"}]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "poll must ignore the bot's own messages"
[ "$(count_ack_posts "$log")" -eq 0 ] \
  || fail "poll must not ack bot messages"
pass "fm-slack-poll ignores bot messages including its own ack"

# --- reaction failure must not suppress wake --------------------------------

home="$TMP_ROOT/reaction-failure"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-reaction-failure")
log="$home/curl-reaction-failure.log"
: > "$log"
export FM_SLACK_CURL_LOG=$log
export FAKE_SLACK_BOT_USER=$BOT_USER
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FAKE_SLACK_REACTION_FAIL=1
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[{"type":"message","user":"'"$CAPTAIN_USER"'","text":"still wake","ts":"1786735226.333333"}]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] || fail "poll must survive a failed reaction (rc=$rc)"
printf -v expected 'slack-captain-message %s\t%s' "1786735226.333333" "still wake"
[ "$out" = "$expected" ] || fail "failed reaction must not suppress wake: $out"
[ ! -e "$home/state/slack-acked/1786735226.333333" ] \
  || fail "failed reaction must not record a completed acknowledgement"
[ -f "$home/state/slack-ack-pending/1786735226.333333" ] \
  || fail "failed reaction must retain its durable retry marker"
[ "$(count_ack_posts "$log")" -eq 0 ] || fail "failed reaction must not fall back to a message post"
unset FAKE_SLACK_REACTION_FAIL
unset FAKE_SLACK_HISTORY
pass "fm-slack-poll wakes even when the received reaction fails"

# --- publication precedes acknowledgement and retry ------------------------

home="$TMP_ROOT/ack-retry"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-ack-retry")
log="$home/curl-ack-retry.log"
ack_fail_once="$home/ack-fail-once"
printf '1\n' > "$ack_fail_once"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
export FAKE_SLACK_BOT_USER=$BOT_USER
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FAKE_SLACK_REACTION_FAIL_ONCE="$ack_fail_once"
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[{"type":"message","user":"'"$CAPTAIN_USER"'","text":"durable before courtesy ack","ts":"1786735226.444444"}]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] || fail "ack failure poll must survive a failed acknowledgement (rc=$rc)"
printf -v expected 'slack-captain-message %s\t%s' "1786735226.444444" "durable before courtesy ack"
[ "$out" = "$expected" ] || fail "ack failure must still emit the primary wake: $out"
[ -f "$home/state/slack-inbox/1786735226.444444.json" ] \
  || fail "ack failure must still publish the captain message"
[ "$(grep -c '^method=reactions.add' "$log")" -eq 1 ] \
  || fail "first poll must attempt one acknowledgement"
inbox_digest=$(sha256sum "$home/state/slack-inbox/1786735226.444444.json")
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "ack retry must not publish or wake the message again: $out"
[ "$(grep -c '^method=reactions.add' "$log")" -eq 2 ] \
  || fail "a later poll must retry the failed acknowledgement"
[ "$(sha256sum "$home/state/slack-inbox/1786735226.444444.json")" = "$inbox_digest" ] \
  || fail "a later poll must not republish the already durable inbox message"
[ -f "$home/state/slack-acked/1786735226.444444" ] \
  || fail "successful retry must retain the acknowledgement marker"
[ ! -e "$home/state/slack-ack-pending/1786735226.444444" ] \
  || fail "successful retry must remove the pending acknowledgement marker"
pass "fm-slack-poll publishes and wakes before best-effort acknowledgement, then retries only the acknowledgement"
unset FAKE_SLACK_REACTION_FAIL_ONCE

# --- interrupted acknowledgement remains independently retryable ------------

home="$TMP_ROOT/ack-interrupted"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-ack-interrupted")
log="$home/curl-ack-interrupted.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
export FAKE_SLACK_BOT_USER=$BOT_USER
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
. "$ROOT/bin/fm-x-lib.sh"
printf '%s\n' 1786735226.499999 \
  | fmx_private_artifact_publish_stdin "$home/state/slack-offered" 1786735226.499999 600 >/dev/null \
  || fail "interrupted acknowledgement setup could not record delivery"
printf '%s\n' 1786735226.499999 \
  | fmx_private_artifact_publish_stdin "$home/state/slack-ack-pending" 1786735226.499999 600 >/dev/null \
  || fail "interrupted acknowledgement setup could not record pending work"
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "interrupted acknowledgement retry emitted a primary wake: $out"
[ -f "$home/state/slack-acked/1786735226.499999" ] || fail "interrupted acknowledgement was not completed"
[ ! -e "$home/state/slack-ack-pending/1786735226.499999" ] || fail "completed interrupted acknowledgement stayed pending"
[ "$(count_ack_reactions "$log")" -eq 1 ] || fail "interrupted acknowledgement was not retried once"
pass "fm-slack-poll resumes acknowledgement from its durable pending marker"

home="$TMP_ROOT/ack-already-reacted"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-ack-already-reacted")
log="$home/curl-ack-already-reacted.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
export FAKE_SLACK_BOT_USER=$BOT_USER
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FAKE_SLACK_ALREADY_REACTED=1
printf '%s\n' 1786735226.500000 \
  | fmx_private_artifact_publish_stdin "$home/state/slack-offered" 1786735226.500000 600 >/dev/null \
  || fail "already-reacted setup could not record delivery"
printf '%s\n' 1786735226.500000 \
  | fmx_private_artifact_publish_stdin "$home/state/slack-ack-pending" 1786735226.500000 600 >/dev/null \
  || fail "already-reacted setup could not record pending work"
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "already-reacted retry emitted a primary wake: $out"
[ -f "$home/state/slack-acked/1786735226.500000" ] || fail "already-reacted retry did not record completion"
[ ! -e "$home/state/slack-ack-pending/1786735226.500000" ] || fail "already-reacted retry remained pending"
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "completed already-reacted retry emitted output: $out"
[ "$(count_ack_reactions "$log")" -eq 1 ] || fail "already-reacted completion did not stop retries"
unset FAKE_SLACK_ALREADY_REACTED
pass "fm-slack-poll completes an acknowledgement Slack already applied"

# --- failed acknowledgement does not block newer delivery -------------------

home="$TMP_ROOT/ack-head-of-line"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-ack-head-of-line")
log="$home/curl-ack-head-of-line.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
export FAKE_SLACK_BOT_USER=$BOT_USER
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FAKE_SLACK_REACTION_FAIL=1
export FAKE_SLACK_HISTORY='{"ok":true,"messages":[
  {"type":"message","user":"'"$CAPTAIN_USER"'","text":"first","ts":"1786735226.555551"},
  {"type":"message","user":"'"$CAPTAIN_USER"'","text":"second","ts":"1786735226.555552"}]}'
out=$(run_poll "$home" "$fakebin"); rc=$?
[ "$rc" -eq 0 ] || fail "poll with two failed acknowledgements exited $rc"
printf -v expected 'slack-captain-message %s\t%s\nslack-captain-message %s\t%s' \
  1786735226.555551 first 1786735226.555552 second
[ "$out" = "$expected" ] || fail "failed acknowledgement blocked a newer captain message: $out"
[ -f "$home/state/slack-inbox/1786735226.555551.json" ] || fail "first captain message was not published"
[ -f "$home/state/slack-inbox/1786735226.555552.json" ] || fail "second captain message was not published"
unset FAKE_SLACK_REACTION_FAIL
pass "fm-slack-poll delivers newer messages independently of failed acknowledgements"

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
if grep -q -- "$argv_token" "$argvlog" 2>/dev/null; then
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

# --- watcher intervals owner regression (PARTIAL GATE) -----------------------
# POLL, CHECK_INTERVAL, and SLACK_CHECK_INTERVAL are set by fm_watch_intervals in
# bin/fm-slack-lib.sh; fm-watch.sh evaluates its output, and the assertions below
# call the same function. This is a PARTIAL GATE, not a complete one, and what it
# closes and what it provably does not are stated here, each named by the
# refuter's mutation id with its green-27 evidence cited from
# data/refute-cadence-stop-condition/report.md, so the comments cannot re-derive
# a false completeness claim and the limits link to their evidence.
#
# CLOSED: the fixture-equal constant class (m1/m4) - the two-value loop below
# asserts distinct configured cadences (37 and 53) both transport, so no single
# hardcoded constant in the owner satisfies the oracle. Also closed: the owner's
# config load deleted or made unreachable; the owner returning the default when a
# cadence is configured (hardcoding 15, the only cadence constant in shipped
# code); and disagreement between fm_watch_intervals and a sourced fm-watch.sh.
#
# NOT CLOSED - two KNOWN ESCAPES that ship unclosed and are written down as such
# (each verified green with a configured cadence resolving to the default while all
# 27 checks pass, evidence in data/refute-cadence-stop-condition/report.md,
# mutations m10 and m11):
#   - m10: a mode-gated eval at the fm-watch.sh call site. The call site is top
#     level where BASH_SOURCE/$0 can distinguish sourced from executed (unlike
#     inside the owner function, where BASH_SOURCE[0] is the defining file in both
#     modes); wrapping the eval in that condition drops a configured 45 to 15 in
#     executed mode with all 27 checks green. Historical site: the eval at commit
#     b3449187:122; the line number moves with fm-watch.sh. NOT closed.
#   - m11: any override in the executed-only region after fm-watch.sh's Main entry
#     return guard, which a sourced oracle never reaches; same result, all 27
#     checks green. Historical site: just after the guard at commit b3449187:763;
#     the line number moves with fm-watch.sh. NOT closed.
# A bounded executed-mode seam exists and would distinguish both known escapes:
# record a live external process as the holder of this home's watcher lock, run
# bin/fm-watch.sh as a script so the existing singleton-collision path exits
# before the loop, and use a BASH_ENV-injected EXIT trap to capture the effective
# SLACK_CHECK_INTERVAL from that shell. The repository already uses BASH_ENV
# injection for test instrumentation in tests/fm-bootstrap.test.sh and
# tests/fm-session-start.test.sh; their BASH_ENV payloads do not install EXIT traps.
# On this bounded path, fm-watch.sh acquires no watcher lock and enters no loop.
# The targeted Slack cadence suite does not exercise that available seam. Under
# the pre-declared stop condition, m10 and m11 remain open by decision even though
# the bounded seam above can test them.
#
# The two-value transport assertion (37 and 53) closes the constant class and
# nothing else - it does not make the oracle complete, and nothing here claims it
# does. The watcher-consumes assertions below source fm-watch.sh (the documented
# unit-test seam, which returns before the Main entry loop), not execute it; they
# verify the sourced path agrees with the owner, not that the executed path does.
# The defaults (POLL=15, CHECK_INTERVAL=300) must surface with no env files
# present; an x-mode.env FM_CHECK_INTERVAL must win for the global sweep without
# touching the Slack cadence; two distinct slack-captain.env FM_SLACK_CHECK_INTERVAL
# values must both flow into the effective Slack interval.

run_intervals() {
  # shellcheck source=bin/fm-x-lib.sh
  # shellcheck source=bin/fm-slack-lib.sh
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" \
    FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
    bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-slack-lib.sh"; eval "$(fm_watch_intervals)"; printf %s:%s:%s "$POLL" "$CHECK_INTERVAL" "$SLACK_CHECK_INTERVAL"'
}

home="$TMP_ROOT/intervals-defaults"
mkdir -p "$home/config" "$home/state"
out=$(run_intervals "$home")
[ "$out" = "15:300:15" ] \
  || fail "fm_watch_intervals defaults must be POLL=15 CHECK_INTERVAL=300 SLACK_CHECK_INTERVAL=15 (got '$out')"

# x-mode.env raises the global sweep cadence; the Slack path stays on POLL=15
# when slack-captain.env is absent, proving the two intervals are independent.
home="$TMP_ROOT/intervals-xmode"
mkdir -p "$home/config" "$home/state"
printf 'export FM_CHECK_INTERVAL=120\n' > "$home/config/x-mode.env"
chmod 600 "$home/config/x-mode.env"
out=$(run_intervals "$home")
[ "$out" = "15:120:15" ] \
  || fail "fm_watch_intervals must let x-mode.env set CHECK_INTERVAL without touching POLL or Slack (got '$out')"

# slack-captain.env sets the Slack cadence only; the global sweep stays default.
# Two distinct configured values must both transport, so no single hardcoded
# constant in the owner can satisfy the oracle - this kills the fixture-equal
# constant escape (a hardcode equal to one configured value fails the other).
for cadence in 37 53; do
  home="$TMP_ROOT/intervals-slack-$cadence"
  mkdir -p "$home/config" "$home/state"
  printf 'export FM_SLACK_CHECK_INTERVAL=%s\n' "$cadence" > "$home/config/slack-captain.env"
  chmod 600 "$home/config/slack-captain.env"
  out=$(run_intervals "$home")
  [ "$out" = "15:300:$cadence" ] \
    || fail "fm_watch_intervals must transport the configured cadence $cadence, not a constant (got '$out')"
done

# fm-watch.sh must evaluate that same owner, not a separate inline copy, so a
# sourced fm-watch.sh's effective Slack interval matches the owner's. This
# sources fm-watch.sh (its top-level runs the owner via eval, then the Main entry
# guard returns before the loop); it does NOT exercise executed mode. The owner
# assertions above already cover the owner's own transport; this checks the
# sourced fm-watch.sh path agrees with the owner. An override at the eval call
# site that fires only in executed mode, or in the executed-only region after the
# Main entry guard, leaves this assertion green while executed production is not
# covered - those escapes are documented in the PARTIAL GATE note above.
home="$TMP_ROOT/watcher-consumes"
make_home "$home"
cat > "$home/config/slack-captain.env" <<ENV
# Auto-generated by fm-bootstrap.sh - Slack captain channel watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh runs the Slack check on this watcher cycle. The value below is the
# operator-set cadence from config/slack-captain-cadence (seconds) or the built-in
# default when that file is absent; edit the source file, not this one.
export FM_SLACK_CHECK_INTERVAL=30
ENV
chmod 600 "$home/config/slack-captain.env"
executed=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-watch.sh" >/dev/null 2>&1; printf %s "$SLACK_CHECK_INTERVAL"')
[ "$executed" = 30 ] \
  || fail "sourced fm-watch.sh must apply the generated Slack cadence via fm_watch_intervals (got SLACK_CHECK_INTERVAL='$executed', expected 30); this covers the sourced path only, not executed mode"
[ "$executed" = "$(run_intervals "$home" | cut -d: -f3)" ] \
  || fail "sourced fm-watch.sh and fm_watch_intervals must agree on the Slack interval"

# fallback: no slack-captain.env -> effective 15 via the same owner in both paths
home="$TMP_ROOT/watcher-fallback"
make_home "$home"
rm -f "$home/config/slack-captain.env"
executed=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-watch.sh" >/dev/null 2>&1; printf %s "$SLACK_CHECK_INTERVAL"')
[ "$executed" = 15 ] \
  || fail "sourced fm-watch.sh must fall back to POLL=15 when no cadence env is present (got '$executed'); this covers the sourced path only, not executed mode"
pass "watcher interval owner transports distinct cadences; sourced fm-watch.sh agrees (partial gate)"

# fm-watch.sh still keeps the global sweep narrow: the slow sweep skips the
# Slack shim, which runs on its own dedicated fast path.
awk '/elif.*slack-watch\.check\.sh/ { getline; if ($0 ~ /continue/) found=1 } END { exit found ? 0 : 1 }' \
  "$ROOT/bin/fm-watch.sh" \
  || fail "fm-watch.sh must skip the Slack shim in the slow sweep"
pass "fm-watch.sh keeps a dedicated Slack fast path"
home="$TMP_ROOT/watch-cadence"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-watch-cadence")
shim="$home/state/slack-watch.check.sh"
# shellcheck source=bin/fm-slack-lib.sh
. "$ROOT/bin/fm-slack-lib.sh"
fms_poll_shim_content "$home" "$ROOT" > "$shim"
chmod 0700 "$shim"

# Each case ends on the watcher's own terminal wake, never on a timer: wake()
# exits the process, so every assertion below reads one completed cycle instead
# of whatever a fixed sleep happened to catch. The away flag plus a zero
# heartbeat is the backstop wake, and it fires strictly after both check blocks,
# so a case whose intended wake never happens still ends the cycle - and ends it
# with evidence of how far the cycle got. The tick bound only keeps a watcher
# that stops waking altogether a failure here instead of a hung CI shard.
touch "$home/state/.afk"

run_watch_cadence_cycle() {  # <slow-check-interval> <curl-log> <history-json>
  local slow_interval=$1 curl_log=$2 history=$3 pid ticks=0
  : > "$curl_log"
  touch "$home/state/.last-check"
  rm -f "$home/state/.last-slack-check"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ROOT_OVERRIDE="$ROOT" FM_POLL=60 FM_CHECK_INTERVAL="$slow_interval" \
    FM_SLACK_CHECK_INTERVAL=0 FM_HEARTBEAT=0 FM_SIGNAL_GRACE=0 \
    FM_SLACK_API_URL=https://slack.test/api FM_SLACK_CURL_BIN="$fakebin/curl" \
    FM_SLACK_CURL_LOG="$curl_log" FAKE_SLACK_CHANNEL="$CHANNEL_ID" \
    FAKE_SLACK_HISTORY="$history" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge 600 ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "watcher never reached a terminal wake: $(cat "$home/watch.out" "$home/watch.err")"
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null || true
}

ack_watch_cadence_cycle() {
  local err="$home/drain.err" sequence generation
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-drain.sh" \
    > "$home/drain.out" 2> "$err" || fail "watch cadence drain failed"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "watch cadence acknowledgement was not emitted"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null \
    || fail "watch cadence acknowledgement failed"
}

history_calls() {  # <curl-log>
  awk '/^url=.*conversations\.history/ { n++ } END { print n + 0 }' "$1"
}

# Fast path due, slow sweep not. The captain message wakes before the heartbeat
# backstop can, so that wake is itself the proof the Slack poll ran off the
# dedicated fast interval rather than the sweep that is not due here.
log="$home/fast-only.log"
run_watch_cadence_cycle 1000000 "$log" \
  '{"ok":true,"messages":[{"type":"message","user":"U_CAPTAIN1","text":"cadence probe","ts":"1786735230.222222"}]}'
[ "$(history_calls "$log")" -eq 1 ] \
  || fail "watcher must run the Slack fast path while the slow check sweep is not due: $(cat "$log")"
grep -Fq 'slack-captain-message 1786735230.222222' "$home/watch.out" \
  || fail "watcher must wake on the fast-path Slack message: $(cat "$home/watch.out")"
ack_watch_cadence_cycle

# Both due, and the fast path stays quiet. Ending on the heartbeat backstop is
# the proof the cycle ran the sweep to completion: a sweep that had touched the
# Slack shim would have exited inside the check block with its own wake instead.
log="$home/both-due.log"
run_watch_cadence_cycle 0 "$log" '{"ok":true,"messages":[]}'
[ "$(history_calls "$log")" -eq 1 ] \
  || fail "watcher must not run the Slack shim again in the slow check sweep"
[ "$(cat "$home/watch.out")" = heartbeat ] \
  || fail "slow check sweep must pass over the authenticated Slack shim silently: $(cat "$home/watch.out")"
pass "fm-watch.sh keeps Slack polling on one dedicated fast path"

# --- post board update ------------------------------------------------------

home="$TMP_ROOT/board"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake4")
unset FM_SLACK_CURL_LOG FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
ts=$(run_post "$home" "$fakebin" board "board v1")
[ "$ts" = "1786735224.690829" ] || fail "board post must return ts"
[ -f "$home/state/slack-board.meta/slack-board.meta" ] || fail "board meta must be recorded"
ts2=$(run_post "$home" "$fakebin" board "board v2")
[ "$ts2" = "1786735224.690829" ] || fail "board update must return same ts"
pass "fm-slack-post board creates then updates in place"

home="$TMP_ROOT/board-missing-state"
make_home "$home"
rmdir "$home/state" || fail "missing-state setup must leave the state directory removable"
fakebin=$(make_fake_curl "$home/fake-board-missing-state")
unset FM_SLACK_CURL_LOG FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
ts=$(run_post "$home" "$fakebin" board "board v1")
[ "$ts" = "1786735224.690829" ] || fail "board must create its state root before acquiring the lock"
[ -d "$home/state" ] || fail "board must recreate a missing state root"
pass "fm-slack-post board initializes a missing state root before locking"

home="$TMP_ROOT/board-initial-state-recovery"
make_home "$home"
mkdir "$home/state/slack-board.meta"
chmod 700 "$home/state/slack-board.meta"
printf '%s\n' '{"date":"2026-08-27","body":"stale"}' > "$home/state/slack-board.meta/slack-board.state"
chmod 400 "$home/state/slack-board.meta/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-board-initial-state-recovery")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
if run_post "$home" "$fakebin" board "initialbody" >"$home/initial.out" 2>"$home/initial.err"; then
  chmod 600 "$home/state/slack-board.meta/slack-board.state"
  fail "initial state-write failure must exit non-zero"
fi
[ -f "$home/state/slack-board.meta/slack-board.meta" ] \
  || fail "initial state-write failure must retain the posted live meta"
[ -f "$home/state/slack-board.meta/slack-board.pending" ] \
  || fail "initial state-write failure must retain its recovery journal"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 0 ] \
  || fail "initial state-write failure must not update the live message"
chmod 600 "$home/state/slack-board.meta/slack-board.state"
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
export FAKE_SLACK_POST='{"ok":true,"ts":"1786735230.999999","channel":"C0BQ9K1TJKG"}'
run_post "$home" "$fakebin" board "todaybody" >/dev/null \
  || fail "initial state recovery must complete on the next board call"
unset FAKE_SLACK_POST
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 2 ] \
  || fail "initial state recovery must close the recovered active date once"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 1 ] \
  || fail "initial state recovery must update the live message after recovery"
[ ! -e "$home/state/slack-board.meta/slack-board.pending" ] \
  || fail "initial state recovery must clear its pending journal"
[ "$(jq -r '.date' "$home/state/slack-board.meta/slack-board.state")" = "2026-08-28" ] \
  || fail "initial state recovery must advance the state date"
pass "fm-slack-post board recovers an initial state-write failure"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-initial-recovery-channel"
make_home "$home"
mkdir "$home/state/slack-board.meta"
chmod 700 "$home/state/slack-board.meta"
printf '%s\n' '{"phase":"initial-posted","date":"2026-08-27","body":"initialbody","today":"2026-08-27","new_body":"initialbody","live_ts":"1786735224.690829","snapshot_ts":"","channel":"C_WRONGCHAN"}' \
  > "$home/state/slack-board.meta/slack-board.pending"
chmod 600 "$home/state/slack-board.meta/slack-board.pending"
fakebin=$(make_fake_curl "$home/fake-board-initial-recovery-channel")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
if run_post "$home" "$fakebin" board "todaybody" >/dev/null 2>"$home/channel.err"; then
  fail "initial recovery must refuse a mismatched journal channel"
fi
grep -Fq "mismatched channel" "$home/channel.err" \
  || fail "initial recovery channel refusal must name the mismatch"
[ ! -e "$home/state/slack-board.meta/slack-board.meta" ] \
  || fail "initial recovery channel refusal must not create live metadata"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "initial recovery channel refusal must not call Slack"
pass "fm-slack-post board refuses an initial recovery channel mismatch"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

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
  | fmx_private_artifact_publish_stdin "$home/state/slack-board.meta" "slack-board.meta" 600 \
  || fail "board channel mismatch setup failed"
if run_post "$home" "$fakebin" board "board v2" >/dev/null 2>&1; then
  fail "board update must refuse a mismatched stored channel"
fi
pass "fm-slack-post board refuses a mismatched stored channel"

home="$TMP_ROOT/board-invalid-meta"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-board-invalid-meta")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
run_post "$home" "$fakebin" board "board v1" >/dev/null \
  || fail "invalid-meta setup board post must succeed"
printf 'channel=%s\n' "$CHANNEL_ID" \
  | fmx_private_artifact_publish_stdin "$home/state/slack-board.meta" "slack-board.meta" 600 \
  || fail "invalid-meta setup must publish malformed board metadata"
if run_post "$home" "$fakebin" board "board v2" >/dev/null 2>"$home/board.err"; then
  fail "malformed board metadata must refuse the update"
fi
grep -Fq "invalid board meta" "$home/board.err" \
  || fail "malformed board metadata refusal must name the invalid metadata"
[ "$(grep -c '^method=' "$log")" -eq 1 ] \
  || fail "malformed board metadata must not call Slack again"
pass "fm-slack-post board fails closed on malformed persisted metadata"

home="$TMP_ROOT/board-public-state"
make_home "$home"
chmod 755 "$home/state"
fakebin=$(make_fake_curl "$home/fake-board-public")
unset FM_SLACK_CURL_LOG FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
ts=$(run_post "$home" "$fakebin" board "board v1")
[ "$ts" = "1786735224.690829" ] \
  || fail "board post must return ts under a public state parent"
[ "$(private_mode "$home/state/slack-board.meta")" = 700 ] \
  || fail "board meta directory must be private under a public state parent"
[ "$(private_mode "$home/state/slack-board.meta/slack-board.meta")" = 600 ] \
  || fail "board meta must be a private file under a public state parent"
ts2=$(run_post "$home" "$fakebin" board "board v2")
[ "$ts2" = "1786735224.690829" ] \
  || fail "board update must read its recorded meta back under a public state parent"
pass "fm-slack-post board meta persists and reads back under a public state parent"

home="$TMP_ROOT/board-invalid-state"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-board-invalid-state")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
run_post "$home" "$fakebin" board "board v1" >/dev/null \
  || fail "invalid-state setup board post must succeed"
printf '%s\n' '{"date":"2026-08-27","body":' > "$home/state/slack-board.meta/slack-board.state"
chmod 600 "$home/state/slack-board.meta/slack-board.state"
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
if run_post "$home" "$fakebin" board "board v2" >/dev/null 2>"$home/board.err"; then
  fail "malformed board state must refuse the update"
fi
grep -Fq "invalid board state" "$home/board.err" \
  || fail "malformed board state refusal must name the invalid state"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 1 ] \
  || fail "malformed board state must not post a rollover snapshot"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 0 ] \
  || fail "malformed board state must not update the live message"
pass "fm-slack-post board fails closed on malformed persisted state"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-trailing-newline"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-board-trailing-newline")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
run_post "$home" "$fakebin" board $'closedbody\n' >/dev/null \
  || fail "trailing-newline setup board post must succeed"
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
run_post "$home" "$fakebin" board "todaybody" >/dev/null \
  || fail "trailing-newline rollover board update must succeed"
snapshot_line=$(grep '^data=' "$log" | sed -n '2p')
case "$snapshot_line" in
  *closedbody%0A*) : ;;
  *) fail "rollover snapshot must preserve a trailing newline in the prior body: $snapshot_line" ;;
esac
pass "fm-slack-post board preserves trailing newlines through rollover"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-concurrent-rollover"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-board-concurrent-rollover")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
run_post "$home" "$fakebin" board "closedbody" >/dev/null \
  || fail "concurrent-rollover setup board post must succeed"
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
export FAKE_SLACK_POST_DELAY=1
run_post "$home" "$fakebin" board "todaybody-a" >"$home/one.out" 2>"$home/one.err" &
pid_one=$!
sleep 0.1
run_post "$home" "$fakebin" board "todaybody-b" >"$home/two.out" 2>"$home/two.err" &
pid_two=$!
wait "$pid_one" || fail "first concurrent rollover board call failed: $(cat "$home/one.err")"
wait "$pid_two" || fail "second concurrent rollover board call failed: $(cat "$home/two.err")"
unset FAKE_SLACK_POST_DELAY
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 2 ] \
  || fail "concurrent rollover calls must create one snapshot post: $(cat "$log")"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 2 ] \
  || fail "concurrent rollover calls must each update the stable live board: $(cat "$log")"
[ -f "$home/state/slack-board-snapshots/2026-08-27" ] \
  || fail "concurrent rollover calls must leave one snapshot once-file"
pass "fm-slack-post board serializes concurrent rollover transitions"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

# --- board rollover snapshot -------------------------------------------------

home="$TMP_ROOT/board-rollover"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-rollover")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$fakebin" board "yesterdaybody")
[ "$ts" = "1786735224.690829" ] || fail "rollover setup post must return ts"
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
export FAKE_SLACK_POST='{"ok":true,"ts":"1786735230.999999","channel":"C0BQ9K1TJKG"}'
ts2=$(run_post "$home" "$fakebin" board "todaybody")
unset FAKE_SLACK_POST
[ "$ts2" = "$ts" ] || fail "rollover must keep updating the same live ts, not the snapshot ts"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 2 ] \
  || fail "rollover must post exactly one snapshot beyond the setup post: $(cat "$log")"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 1 ] \
  || fail "rollover must update the live message exactly once: $(cat "$log")"
snapshot_line=$(grep '^method=chat.postMessage ' "$log" | sed -n '2p')
case "$snapshot_line" in
  *2026-08-27*) : ;;
  *) fail "snapshot must reference the closed date: $snapshot_line" ;;
esac
case "$snapshot_line" in
  *yesterdaybody*) : ;;
  *) fail "snapshot must carry the previous active date's body: $snapshot_line" ;;
esac
[ -f "$home/state/slack-board-snapshots/2026-08-27" ] \
  || fail "snapshot once-file must be recorded for the closed date"
[ "$(cat "$home/state/slack-board-snapshots/2026-08-27")" = "1786735230.999999" ] \
  || fail "snapshot once-file must record the snapshot post's own ts, not the live ts"
[ "$(private_mode "$home/state/slack-board-snapshots")" = 700 ] \
  || fail "snapshot directory must be private"
[ "$(private_mode "$home/state/slack-board-snapshots/2026-08-27")" = 600 ] \
  || fail "snapshot once-file must be private"
[ "$(grep '^ts=' "$home/state/slack-board.meta/slack-board.meta" | cut -d= -f2)" = "$ts" ] \
  || fail "live board meta must keep its original ts through a rollover"
[ "$(jq -r '.date' "$home/state/slack-board.meta/slack-board.state")" = "2026-08-28" ] \
  || fail "board state date must advance to today after rollover"
[ "$(jq -r '.body' "$home/state/slack-board.meta/slack-board.state")" = "todaybody" ] \
  || fail "board state body must record today's applied text after rollover"
pass "fm-slack-post board rollover posts one snapshot of the closed date then updates the live message"

ts3=$(run_post "$home" "$fakebin" board "todaybody-v2")
[ "$ts3" = "$ts" ] || fail "same-day follow-up after rollover must keep the same live ts"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 2 ] \
  || fail "a same-day follow-up after rollover must not post a second snapshot: $(cat "$log")"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 2 ] \
  || fail "a same-day follow-up after rollover must still update the live message: $(cat "$log")"
! grep -Eq '^method=(pins\.add|pins\.remove|chat\.delete) ' "$log" \
  || fail "board must never call pins.add, pins.remove, or chat.delete: $(cat "$log")"
pass "fm-slack-post board does not re-snapshot a second same-day call after rollover"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-rollover-dedupe"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-rollover-dedupe")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$fakebin" board "closedbody")
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
printf 'seeded-snapshot-ts' \
  | fmx_private_artifact_publish_stdin_once "$home/state/slack-board-snapshots" "2026-08-27" 600 \
  || fail "dedupe once-file seed failed"
ts2=$(run_post "$home" "$fakebin" board "todaybody")
[ "$ts2" = "$ts" ] || fail "a dedupe-skipped rollover must still update the live message"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 1 ] \
  || fail "a pre-existing once-file must prevent a duplicate snapshot post: $(cat "$log")"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 1 ] \
  || fail "a dedupe-skipped rollover must still update the live message once: $(cat "$log")"
[ "$(cat "$home/state/slack-board-snapshots/2026-08-27")" = "seeded-snapshot-ts" ] \
  || fail "a pre-existing once-file must not be overwritten"
[ "$(jq -r '.date' "$home/state/slack-board.meta/slack-board.state")" = "2026-08-28" ] \
  || fail "a dedupe-skipped rollover must still close the last active date"
pass "fm-slack-post board skips a snapshot post when its once-file already exists"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-rollover-dedupe-write-failure"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-rollover-dedupe-fail")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$fakebin" board "closedbody")
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
mkdir -p "$home/state/slack-board-snapshots"
chmod 500 "$home/state/slack-board-snapshots"
err_out="$home/board.err"
if run_post "$home" "$fakebin" board "todaybody" >"$home/board.out" 2>"$err_out"; then
  chmod 700 "$home/state/slack-board-snapshots"
  fail "a failed snapshot dedupe write must exit non-zero"
fi
chmod 700 "$home/state/slack-board-snapshots"
grep -Fq "board snapshot posted at" "$err_out" \
  || fail "a failed snapshot dedupe write must name the created snapshot ts: $(cat "$err_out")"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 2 ] \
  || fail "the snapshot must still post once even though its dedupe write failed: $(cat "$log")"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 0 ] \
  || fail "a failed snapshot dedupe write must not advance the live message: $(cat "$log")"
[ "$(jq -r '.date' "$home/state/slack-board.meta/slack-board.state")" = "2026-08-27" ] \
  || fail "a failed snapshot dedupe write must not advance the stored active date"
pass "fm-slack-post board dies naming the snapshot ts when its dedupe write fails, without advancing live state"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

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

# --- bootstrap adoption of a pre-convention cadence -------------------------
# The captain's decision may already live in config/slack-captain.env from before
# this operator-owned source existed. Bootstrap must adopt that value into
# config/slack-captain-cadence on the first regeneration instead of silently
# reverting it to the default - the reported defect's upgrade path. Mutating the
# generator to ignore the existing file must turn these red.

write_preconvention_env() {
  local home=$1 value=$2
  cat > "$home/config/slack-captain.env" <<ENV
# Auto-generated by fm-bootstrap.sh - Slack captain channel watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh runs the Slack check on the 15-second watcher cycle.
export FM_SLACK_CHECK_INTERVAL=$value
ENV
  chmod 600 "$home/config/slack-captain.env"
}

home="$TMP_ROOT/bootstrap-adopt-existing"
make_home "$home"
write_preconvention_env "$home" 30
[ ! -e "$home/config/slack-captain-cadence" ] \
  || fail "adoption precondition: no source cadence file yet"
log="$home/bootstrap.log"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" > "$log" 2>&1
grep -F 'export FM_SLACK_CHECK_INTERVAL=30' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must preserve an existing cadence across regeneration, not revert to 15"
! grep -F 'export FM_SLACK_CHECK_INTERVAL=15' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must not revert an existing cadence to the built-in default"
[ -f "$home/config/slack-captain-cadence" ] \
  || fail "bootstrap must adopt the existing cadence into config/slack-captain-cadence"
grep -Eq '^[[:space:]]*30([[:space:]]|$)' "$home/config/slack-captain-cadence" \
  || fail "bootstrap must write the adopted cadence value into config/slack-captain-cadence"
grep -F 'adopted 30s' "$log" >/dev/null \
  || fail "bootstrap must announce cadence adoption so the transition is not silent"

# idempotent: cadence source now owns the value, so a second run keeps 30 and
# does not re-adopt
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" > "$log" 2>&1
grep -F 'export FM_SLACK_CHECK_INTERVAL=30' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must keep an adopted cadence across a second regeneration"
! grep -F 'adopted' "$log" >/dev/null \
  || fail "bootstrap must not re-announce adoption once the source file exists"

# reset safety: deleting the source file must fall back to the default, not
# re-adopt a stale value from the now-post-convention env
rm -f "$home/config/slack-captain-cadence"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" > "$log" 2>&1
grep -F 'export FM_SLACK_CHECK_INTERVAL=15' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must fall back to the default when the operator deletes the cadence source, not re-adopt a stale value"
! grep -F 'export FM_SLACK_CHECK_INTERVAL=30' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must not re-adopt a stale cadence after the source file is deleted"
[ ! -e "$home/config/slack-captain-cadence" ] \
  || fail "bootstrap must not recreate the cadence source after a reset to default"
pass "bootstrap adopts an existing cadence on upgrade and defends reset-to-default"

# a pre-convention env with a present but unparseable cadence must warn and use
# the default, never silently keep a broken value or revert without notice
home="$TMP_ROOT/bootstrap-adopt-malformed"
make_home "$home"
write_preconvention_env "$home" abc
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" > "$log" 2>&1
grep -F 'is not a positive integer' "$log" >/dev/null \
  || fail "bootstrap must warn when an existing cadence is unparseable rather than silently reverting"
grep -F 'export FM_SLACK_CHECK_INTERVAL=15' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must use the built-in default when the existing cadence is unparseable"
[ ! -e "$home/config/slack-captain-cadence" ] \
  || fail "bootstrap must not adopt an unparseable cadence into the source file"
pass "bootstrap warns and uses the default when an existing cadence is unparseable"

# An operator-set cadence in config/slack-captain-cadence must survive bootstrap
# regeneration. The captain owns this value; bootstrap reads but never writes the
# source file, so rerunning the generator must keep the operator's number rather
# than reverting it to the built-in default - the regression that motivated this
# test. Mutating the generator to ignore the source file must turn these red.
home="$TMP_ROOT/bootstrap-cadence-set"
make_home "$home"
printf '7\n' > "$home/config/slack-captain-cadence"
chmod 600 "$home/config/slack-captain-cadence"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null
grep -F 'export FM_SLACK_CHECK_INTERVAL=7' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must preserve an operator-set Slack cadence across regeneration"
# idempotent on a second regeneration with the same operator value
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null
grep -F 'export FM_SLACK_CHECK_INTERVAL=7' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must keep the operator-set Slack cadence across a second regeneration"
# the operator value, not the generated file, is the surviving source of truth:
# change the source and regenerate, and the generated file must follow it
printf '9\n' > "$home/config/slack-captain-cadence"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null
grep -F 'export FM_SLACK_CHECK_INTERVAL=9' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must follow an updated operator cadence on regeneration"
! grep -F 'export FM_SLACK_CHECK_INTERVAL=15' "$home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must not revert an operator cadence to the built-in default"

# absent operator file falls back to the built-in default
cadence_default_home="$TMP_ROOT/bootstrap-cadence-default"
make_home "$cadence_default_home"
FM_HOME="$cadence_default_home" FM_STATE_OVERRIDE="$cadence_default_home/state" \
  FM_CONFIG_OVERRIDE="$cadence_default_home/config" FM_ROOT_OVERRIDE="$ROOT" \
  PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null
grep -F 'export FM_SLACK_CHECK_INTERVAL=15' "$cadence_default_home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must fall back to the built-in default cadence when the operator file is absent"

# a malformed operator file falls back to the built-in default rather than
# arming a non-numeric or zero cadence
cadence_bad_home="$TMP_ROOT/bootstrap-cadence-malformed"
make_home "$cadence_bad_home"
printf '# not a number\nnope\n0\n' > "$cadence_bad_home/config/slack-captain-cadence"
chmod 600 "$cadence_bad_home/config/slack-captain-cadence"
FM_HOME="$cadence_bad_home" FM_STATE_OVERRIDE="$cadence_bad_home/state" \
  FM_CONFIG_OVERRIDE="$cadence_bad_home/config" FM_ROOT_OVERRIDE="$ROOT" \
  PATH="$BASE_PATH" \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null
grep -F 'export FM_SLACK_CHECK_INTERVAL=15' "$cadence_bad_home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must ignore a malformed cadence file and use the built-in default"
! grep -F 'export FM_SLACK_CHECK_INTERVAL=0' "$cadence_bad_home/config/slack-captain.env" >/dev/null \
  || fail "bootstrap must not arm a zero or non-numeric cadence"
pass "bootstrap preserves an operator-set Slack cadence and falls back to the built-in default"

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

# --- decision posts ------------------------------------------------------------
# A decision post must bind the returned message ts to its decision key so a
# later captain emoji reaction can resolve that key, and must number posted
# options with the keycap emoji so a number reaction is unambiguous.

home="$TMP_ROOT/decision-plain"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-decision-plain")
unset FM_SLACK_CURL_LOG FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
log="$home/curl.log"; : > "$log"
ts=$(FM_SLACK_CURL_LOG="$log" run_post "$home" "$fakebin" decision merge-pr-42 "Ship PR 42?") \
  || fail "decision post failed"
[ "$ts" = "1786735224.690829" ] || fail "decision post must return the posted ts: $ts"
binding="$home/state/slack-decision-bindings/1786735224.690829.json"
[ -f "$binding" ] || fail "decision post must record its binding"
[ "$(jq -r '.key' "$binding")" = merge-pr-42 ] || fail "binding recorded the wrong key"
[ "$(jq -r '.options' "$binding")" = 0 ] || fail "plain decision must record zero options"
grep -F 'text=Ship%20PR%2042%3F' "$log" >/dev/null \
  || fail "plain decision must post the text unchanged"
pass "fm-slack-post decision binds the posted ts to the decision key"

home="$TMP_ROOT/decision-options"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-decision-options")
unset FM_SLACK_CURL_LOG FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
log="$home/curl.log"; : > "$log"
ts=$(FM_SLACK_CURL_LOG="$log" run_post "$home" "$fakebin" \
  decision pick-harness "Pick a harness" claude codex pi) \
  || fail "option decision post failed"
binding="$home/state/slack-decision-bindings/1786735224.690829.json"
[ "$(jq -r '.options' "$binding")" = 3 ] || fail "option decision must record the option count"
# The posted text must number each option with the keycap emoji: the combining
# enclosing keycap U+20E3 appears exactly once per option in the encoded text
# (counted on the fake-curl data line, since the client logs the payload twice).
[ "$(grep '^data=' "$log" | grep -o '%E2%83%A3' | wc -l | tr -d '[:space:]')" = 3 ] \
  || fail "option decision must number options with keycap emoji"
grep -F 'claude' "$log" >/dev/null || fail "option decision must post the option texts"
grep -F 'codex' "$log" >/dev/null || fail "option decision must post the option texts"
pass "fm-slack-post decision numbers posted options with keycap emoji"

home="$TMP_ROOT/decision-bad-key"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-decision-bad-key")
unset FM_SLACK_CURL_LOG FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
log="$home/curl.log"; : > "$log"
if FM_SLACK_CURL_LOG="$log" run_post "$home" "$fakebin" decision 'bad key' "Ship?" >/dev/null 2>&1; then
  fail "decision post must refuse an invalid key"
fi
! grep -F 'chat.postMessage' "$log" >/dev/null \
  || fail "invalid key must refuse before posting"
pass "fm-slack-post decision refuses an invalid key before posting"

home="$TMP_ROOT/decision-too-many"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-decision-too-many")
unset FM_SLACK_CURL_LOG FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
log="$home/curl.log"; : > "$log"
if FM_SLACK_CURL_LOG="$log" run_post "$home" "$fakebin" \
  decision pick-ten "Pick one" o1 o2 o3 o4 o5 o6 o7 o8 o9 o10 >/dev/null 2>&1; then
  fail "decision post must refuse more than nine options"
fi
! grep -F 'chat.postMessage' "$log" >/dev/null \
  || fail "too many options must refuse before posting"
pass "fm-slack-post decision refuses more than nine options before posting"
