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

private_inode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %i "$1"
  else
    stat -c %i "$1"
  fi
}

# Publish a complete legacy board directory state/slack-board.meta/ holding a
# synthetic identity (channel+ts) and a same-day or prior-day state, so a board
# call exercises the lazy migration off the task-record namespace.
make_legacy_board() {
  local home=$1 channel=$2 ts=$3 date=$4 body=$5
  mkdir -p "$home/state/slack-board.meta"
  chmod 700 "$home/state/slack-board.meta"
  printf 'channel=%s\nts=%s\n' "$channel" "$ts" > "$home/state/slack-board.meta/slack-board.meta"
  chmod 600 "$home/state/slack-board.meta/slack-board.meta"
  printf '{"date":"%s","body":%s}' "$date" "$(jq -Rs . <<<"$body")" > "$home/state/slack-board.meta/slack-board.state"
  chmod 600 "$home/state/slack-board.meta/slack-board.state"
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
[ -f "$home/state/slack-board/slack-board.meta" ] || fail "board meta must be recorded"
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

home="$TMP_ROOT/board-refuses-state-only-layout"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf '%s\n' '{"date":"2026-08-27","body":"stale"}' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-state-only")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
state_before=$(cat "$home/state/slack-board/slack-board.state")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/so.err"; then
  fail "board must refuse a state-only layout (no identity, no recovery journal)"
fi
grep -Fq "a steady board requires both identity and daily state" "$home/so.err" \
  || fail "state-only refusal must name the missing identity: $(cat "$home/so.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "state-only refusal must not call Slack: $(cat "$log")"
[ "$(cat "$home/state/slack-board/slack-board.state")" = "$state_before" ] \
  || fail "state-only refusal must leave the state bytes unchanged"
[ ! -e "$home/state/slack-board/slack-board.meta" ] \
  || fail "state-only refusal must not create an identity"
[ ! -e "$home/state/slack-board/slack-board.pending" ] \
  || fail "state-only refusal must not create a recovery journal"
pass "fm-slack-post board refuses a state-only layout without a network call"

home="$TMP_ROOT/board-refuses-identity-only-layout"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=1786735224.690829\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
fakebin=$(make_fake_curl "$home/fake-refuse-identity-only")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
meta_before=$(cat "$home/state/slack-board/slack-board.meta")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/io.err"; then
  fail "board must refuse an identity-only layout (no daily state, no recovery journal)"
fi
grep -Fq "a steady board requires both identity and daily state" "$home/io.err" \
  || fail "identity-only refusal must name the missing state: $(cat "$home/io.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "identity-only refusal must not call Slack: $(cat "$log")"
[ "$(cat "$home/state/slack-board/slack-board.meta")" = "$meta_before" ] \
  || fail "identity-only refusal must leave the identity bytes unchanged"
pass "fm-slack-post board refuses an identity-only layout without a network call"

home="$TMP_ROOT/board-refuses-duplicate-ts-identity"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=1786735224.690829\nts=1786735230.111111\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
printf '{"date":"2026-08-27","body":"prior"}' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-dup-ts")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
meta_before=$(cat "$home/state/slack-board/slack-board.meta")
state_before=$(cat "$home/state/slack-board/slack-board.state")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/dt.err"; then
  fail "board must refuse an identity with a duplicate ts field"
fi
grep -Fq "invalid Slack board identity" "$home/dt.err" \
  || fail "duplicate-ts refusal must name the invalid identity: $(cat "$home/dt.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "duplicate-ts refusal must not call Slack: $(cat "$log")"
[ "$(cat "$home/state/slack-board/slack-board.meta")" = "$meta_before" ] \
  || fail "duplicate-ts refusal must leave the identity bytes unchanged"
[ "$(cat "$home/state/slack-board/slack-board.state")" = "$state_before" ] \
  || fail "duplicate-ts refusal must leave the state bytes unchanged"
pass "fm-slack-post board refuses a duplicate-ts identity without a network call"

home="$TMP_ROOT/board-refuses-duplicate-channel-identity"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nchannel=%s\nts=1786735224.690829\n' "$CHANNEL_ID" "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
printf '{"date":"2026-08-27","body":"prior"}' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-dup-chan")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
meta_before=$(cat "$home/state/slack-board/slack-board.meta")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/dc.err"; then
  fail "board must refuse an identity with a duplicate channel field"
fi
grep -Fq "invalid Slack board identity" "$home/dc.err" \
  || fail "duplicate-channel refusal must name the invalid identity: $(cat "$home/dc.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "duplicate-channel refusal must not call Slack: $(cat "$log")"
[ "$(cat "$home/state/slack-board/slack-board.meta")" = "$meta_before" ] \
  || fail "duplicate-channel refusal must leave the identity bytes unchanged"
pass "fm-slack-post board refuses a duplicate-channel identity without a network call"

home="$TMP_ROOT/board-refuses-empty-ts-identity"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
printf '{"date":"2026-08-27","body":"prior"}' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-empty-ts")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
meta_before=$(cat "$home/state/slack-board/slack-board.meta")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/et.err"; then
  fail "board must refuse an identity with an empty ts field"
fi
grep -Fq "invalid Slack board identity" "$home/et.err" \
  || fail "empty-ts refusal must name the invalid identity: $(cat "$home/et.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "empty-ts refusal must not call Slack: $(cat "$log")"
[ "$(cat "$home/state/slack-board/slack-board.meta")" = "$meta_before" ] \
  || fail "empty-ts refusal must leave the identity bytes unchanged"
pass "fm-slack-post board refuses an empty-ts identity without a network call"

home="$TMP_ROOT/board-refuses-malformed-ts-identity"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=not-a-ts\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
printf '{"date":"2026-08-27","body":"prior"}' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-malformed-ts")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
meta_before=$(cat "$home/state/slack-board/slack-board.meta")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/mt.err"; then
  fail "board must refuse an identity with a malformed ts field"
fi
grep -Fq "invalid Slack board identity" "$home/mt.err" \
  || fail "malformed-ts refusal must name the invalid identity: $(cat "$home/mt.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "malformed-ts refusal must not call Slack: $(cat "$log")"
[ "$(cat "$home/state/slack-board/slack-board.meta")" = "$meta_before" ] \
  || fail "malformed-ts refusal must leave the identity bytes unchanged"
pass "fm-slack-post board refuses a malformed-ts identity without a network call"

home="$TMP_ROOT/board-refuses-extra-field-identity"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=1786735224.690829\nbogus=field\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
printf '{"date":"2026-08-27","body":"prior"}' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-extra-field")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
meta_before=$(cat "$home/state/slack-board/slack-board.meta")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/ef.err"; then
  fail "board must refuse an identity with an extra unknown field"
fi
grep -Fq "invalid Slack board identity" "$home/ef.err" \
  || fail "extra-field refusal must name the invalid identity: $(cat "$home/ef.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "extra-field refusal must not call Slack: $(cat "$log")"
[ "$(cat "$home/state/slack-board/slack-board.meta")" = "$meta_before" ] \
  || fail "extra-field refusal must leave the identity bytes unchanged"
pass "fm-slack-post board refuses an identity with an extra field without a network call"

home="$TMP_ROOT/board-refuses-wrong-mode-identity"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=1786735224.690829\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 644 "$home/state/slack-board/slack-board.meta"
printf '{"date":"2026-08-27","body":"prior"}' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-wrong-mode")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/wm.err"; then
  fail "board must refuse an identity file with the wrong mode"
fi
grep -Fq "invalid Slack board identity" "$home/wm.err" \
  || fail "wrong-mode refusal must name the invalid identity: $(cat "$home/wm.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "wrong-mode refusal must not call Slack: $(cat "$log")"
[ "$(stat -f %Lp "$home/state/slack-board/slack-board.meta" 2>/dev/null || stat -c %a "$home/state/slack-board/slack-board.meta")" = "644" ] \
  || fail "wrong-mode refusal must leave the identity mode unchanged"
pass "fm-slack-post board refuses a wrong-mode identity without a network call"

home="$TMP_ROOT/board-refuses-nonregular-identity"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
ln -s /dev/null "$home/state/slack-board/slack-board.meta"
printf '{"date":"2026-08-27","body":"prior"}' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-nonregular")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/nr.err"; then
  fail "board must refuse a non-regular identity file"
fi
grep -Fq "invalid Slack board identity" "$home/nr.err" \
  || fail "non-regular refusal must name the invalid identity: $(cat "$home/nr.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "non-regular refusal must not call Slack: $(cat "$log")"
[ -L "$home/state/slack-board/slack-board.meta" ] \
  || fail "non-regular refusal must leave the symlink unchanged"
pass "fm-slack-post board refuses a non-regular identity without a network call"

home="$TMP_ROOT/board-refuses-malformed-state"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=1786735224.690829\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
printf 'not-json' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-malformed-state")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
state_before=$(cat "$home/state/slack-board/slack-board.state")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/ms.err"; then
  fail "board must refuse a malformed daily state file"
fi
grep -Fq "invalid Slack board daily state" "$home/ms.err" \
  || fail "malformed-state refusal must name the invalid state: $(cat "$home/ms.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "malformed-state refusal must not call Slack: $(cat "$log")"
[ "$(cat "$home/state/slack-board/slack-board.state")" = "$state_before" ] \
  || fail "malformed-state refusal must leave the state bytes unchanged"
pass "fm-slack-post board refuses a malformed daily state without a network call"

home="$TMP_ROOT/board-refuses-legacy-state-only-layout"
make_home "$home"
mkdir "$home/state/slack-board.meta"
chmod 700 "$home/state/slack-board.meta"
printf '%s\n' '{"date":"2026-08-27","body":"stale"}' > "$home/state/slack-board.meta/slack-board.state"
chmod 600 "$home/state/slack-board.meta/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-legacy-state-only")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
state_before=$(cat "$home/state/slack-board.meta/slack-board.state")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/lso.err"; then
  fail "board must refuse a legacy state-only layout before rename"
fi
grep -Fq "a steady board requires both identity and daily state" "$home/lso.err" \
  || fail "legacy state-only refusal must name the missing identity: $(cat "$home/lso.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "legacy state-only refusal must not call Slack: $(cat "$log")"
[ -d "$home/state/slack-board.meta" ] \
  || fail "legacy state-only refusal must not remove the legacy directory"
[ "$(cat "$home/state/slack-board.meta/slack-board.state")" = "$state_before" ] \
  || fail "legacy state-only refusal must leave the state bytes unchanged"
[ ! -e "$home/state/slack-board" ] \
  || fail "legacy state-only refusal must not create the new directory"
pass "fm-slack-post board refuses a legacy state-only layout without a network call"

home="$TMP_ROOT/board-refuses-legacy-duplicate-ts-identity"
make_home "$home"
mkdir "$home/state/slack-board.meta"
chmod 700 "$home/state/slack-board.meta"
printf 'channel=%s\nts=1786735224.690829\nts=1786735230.111111\n' "$CHANNEL_ID" > "$home/state/slack-board.meta/slack-board.meta"
chmod 600 "$home/state/slack-board.meta/slack-board.meta"
printf '{"date":"2026-08-27","body":"prior"}' > "$home/state/slack-board.meta/slack-board.state"
chmod 600 "$home/state/slack-board.meta/slack-board.state"
fakebin=$(make_fake_curl "$home/fake-refuse-legacy-dup-ts")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
meta_before=$(cat "$home/state/slack-board.meta/slack-board.meta")
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/ldt.err"; then
  fail "board must refuse a legacy identity with a duplicate ts field before rename"
fi
grep -Fq "invalid Slack board identity" "$home/ldt.err" \
  || fail "legacy duplicate-ts refusal must name the invalid identity: $(cat "$home/ldt.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "legacy duplicate-ts refusal must not call Slack: $(cat "$log")"
[ -d "$home/state/slack-board.meta" ] \
  || fail "legacy duplicate-ts refusal must not remove the legacy directory"
[ "$(cat "$home/state/slack-board.meta/slack-board.meta")" = "$meta_before" ] \
  || fail "legacy duplicate-ts refusal must leave the identity bytes unchanged"
[ ! -e "$home/state/slack-board" ] \
  || fail "legacy duplicate-ts refusal must not create the new directory"
pass "fm-slack-post board refuses a legacy duplicate-ts identity without a network call"

home="$TMP_ROOT/board-initial-state-needs-write-recovery-completes"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=1786735224.690829\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
printf '{"phase":"initial-state-needs-write","date":"2026-08-27","body":"initialbody","today":"2026-08-27","new_body":"initialbody","live_ts":"1786735224.690829","snapshot_ts":"","channel":"%s"}' "$CHANNEL_ID" \
  > "$home/state/slack-board/slack-board.pending"
chmod 600 "$home/state/slack-board/slack-board.pending"
fakebin=$(make_fake_curl "$home/fake-recovery-completes")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$fakebin" board "today body")
[ "$ts" = "1786735224.690829" ] || fail "initial-state-needs-write recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] \
  || fail "initial-state-needs-write recovery must clear its pending journal"
[ "$(jq -r '.date' "$home/state/slack-board/slack-board.state")" = "2026-08-27" ] \
  || fail "initial-state-needs-write recovery must write the state date"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 1 ] \
  || fail "initial-state-needs-write recovery must update the live message once: $(cat "$log")"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 0 ] \
  || fail "initial-state-needs-write recovery must not post a replacement: $(cat "$log")"
pass "fm-slack-post board completes an initial-state-needs-write recovery without a replacement post"
unset FM_SLACK_BOARD_TODAY_OVERRIDE
unset FM_SLACK_BOARD_TODAY_OVERRIDE

# --- round-three phase-aware validator: red-before-green refusal matrix -----

# _r3_meta <home> <channel> <ts>  -- publish a private mode-600 board identity
_r3_meta() {
  printf 'channel=%s\nts=%s\n' "$2" "$3" \
    | fmx_private_artifact_publish_stdin "$1/state/slack-board" "slack-board.meta" 600
}
# _r3_state <home> <date> <body>  -- publish a private mode-600 daily state
_r3_state() {
  printf '%s\n' "{\"date\":\"$2\",\"body\":\"$3\"}" \
    | fmx_private_artifact_publish_stdin "$1/state/slack-board" "slack-board.state" 600
}
# _r3_pending <home> <phase> <date> <body> <today> <new_body> <live_ts> <snap_ts> <channel>
_r3_pending() {
  printf '{"phase":"%s","date":"%s","body":"%s","today":"%s","new_body":"%s","live_ts":"%s","snapshot_ts":"%s","channel":"%s"}' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" \
    | fmx_private_artifact_publish_stdin "$1/state/slack-board" "slack-board.pending" 600
}
# _r3_once <home> <date> <ts>  -- publish a private mode-600 snapshot once-file
_r3_once() {
  printf '%s\n' "$3" \
    | fmx_private_artifact_publish_stdin "$1/state/slack-board-snapshots" "$2" 600
}
# _r3_refuse <home> <errfile> <grep-fragment>  -- assert refusal + zero transport + preserved layout
_r3_refuse() {
  local home=$1 err=$2 frag=$3
  if run_post "$home" "$(make_fake_curl "$home/fake-r3")" board "today body" >/dev/null 2>"$err"; then
    fail "board must refuse this layout"
  fi
  grep -Fq "$frag" "$err" || fail "refusal must name the defect: $(cat "$err")"
  [ "$(grep -c '^method=' "$home/curl.log")" -eq 0 ] \
    || fail "refusal must not call Slack: $(cat "$home/curl.log")"
}

home="$TMP_ROOT/board-r3-malformed-channel"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_meta "$home" "c0BQ9K1TJKG" "1786735224.690829"
_r3_state "$home" "2026-08-27" "stale"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "invalid Slack board identity"
pass "fm-slack-post board refuses a malformed channel in a complete identity"

home="$TMP_ROOT/board-r3-two-dot-ts"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_meta "$home" "$CHANNEL_ID" "1.2.3"
_r3_state "$home" "2026-08-27" "stale"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "invalid Slack board identity"
pass "fm-slack-post board refuses a two-dot timestamp through the helper and board command"

home="$TMP_ROOT/board-r3-isnw-no-identity"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_pending "$home" "initial-state-needs-write" "2026-08-27" "initialbody" "2026-08-27" "initialbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "initial-state-needs-write requires an identity"
pass "fm-slack-post board refuses initial-state-needs-write without an identity"

home="$TMP_ROOT/board-r3-snapshot-needed-no-artifacts"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_pending "$home" "snapshot-needed" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "snapshot-needed requires an identity"
pass "fm-slack-post board refuses a non-initial phase without identity or state"

home="$TMP_ROOT/board-r3-empty-live-ts"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_pending "$home" "initial-posted" "2026-08-27" "initialbody" "2026-08-27" "initialbody" "" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "empty or malformed live_ts"
pass "fm-slack-post board refuses an empty live_ts in the journal"

home="$TMP_ROOT/board-r3-journal-ts-conflicts-identity"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_meta "$home" "$CHANNEL_ID" "1786735230.111111"
_r3_pending "$home" "initial-state-needs-write" "2026-08-27" "initialbody" "2026-08-27" "initialbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "identity timestamp differs from journal live_ts"
pass "fm-slack-post board refuses a journal live_ts that conflicts with the identity"

home="$TMP_ROOT/board-r3-journal-date-conflicts-state"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-28" "initialbody"
_r3_pending "$home" "initial-state-needs-write" "2026-08-27" "initialbody" "2026-08-27" "initialbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "initial-state-needs-write state date must equal journal today"
pass "fm-slack-post board refuses a journal date that conflicts with the daily state"

home="$TMP_ROOT/board-r3-snapshot-posting-no-once"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
_r3_pending "$home" "snapshot-posting" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "snapshot-posting has no once-file"
pass "fm-slack-post board refuses snapshot-posting without a matching once-file"

home="$TMP_ROOT/board-r3-snapshot-posted-empty-snap-ts"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
_r3_pending "$home" "snapshot-posted" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "" "$CHANNEL_ID"
_r3_once "$home" "2026-08-26" "1786735224.690829"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "empty or malformed snapshot_ts"
pass "fm-slack-post board refuses snapshot-posted with an empty snapshot timestamp"

home="$TMP_ROOT/board-r3-initial-meta-written-with-state"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-27" "initialbody"
_r3_pending "$home" "initial-meta-written" "2026-08-27" "initialbody" "2026-08-27" "initialbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "initial-meta-written must not yet have a daily state"
pass "fm-slack-post board refuses a contradictory optional artifact for the phase"

# --- positive phase fixtures: real recoverable states must still complete ---

home="$TMP_ROOT/board-r3-initial-posted-recovers"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_pending "$home" "initial-posted" "2026-08-27" "initialbody" "2026-08-27" "initialbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r3-ip")" board "initialbody")
[ "$ts" = "1786735224.690829" ] || fail "initial-posted recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "initial-posted recovery must clear its journal"
[ "$(grep -c '^channel=' "$home/state/slack-board/slack-board.meta")" -eq 1 ] || fail "initial-posted recovery must write the identity"
[ "$(jq -r '.date' "$home/state/slack-board/slack-board.state")" = "2026-08-27" ] || fail "initial-posted recovery must write the state date"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 1 ] || fail "initial-posted recovery must update the live message once: $(cat "$home/curl.log")"
[ "$(grep -c '^method=chat.postMessage ' "$home/curl.log")" -eq 0 ] || fail "initial-posted recovery must not post a replacement"
pass "fm-slack-post board completes an initial-posted recovery with one live update"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-r3-snapshot-posted-recovers"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
_r3_pending "$home" "snapshot-posted" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "1786740000.222222" "$CHANNEL_ID"
_r3_once "$home" "2026-08-26" "1786740000.222222"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r3-sp")" board "newbody")
[ "$ts" = "1786735224.690829" ] || fail "snapshot-posted recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "snapshot-posted recovery must clear its journal"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "newbody" ] || fail "snapshot-posted recovery must write the new body"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 2 ] || fail "snapshot-posted recovery must update the live message twice (recovery plus final): $(cat "$home/curl.log")"
[ "$(grep -c '^method=chat.postMessage ' "$home/curl.log")" -eq 0 ] || fail "snapshot-posted recovery must not post a replacement"
pass "fm-slack-post board completes a snapshot-posted recovery with two live updates"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-r3-state-needs-write-recovers"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
_r3_pending "$home" "state-needs-write" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "1786740000.222222" "$CHANNEL_ID"
_r3_once "$home" "2026-08-26" "1786740000.222222"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r3-snw")" board "newbody")
[ "$ts" = "1786735224.690829" ] || fail "state-needs-write recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "state-needs-write recovery must clear its journal"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "newbody" ] || fail "state-needs-write recovery must write the new body"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 1 ] || fail "state-needs-write recovery must update the live message once: $(cat "$home/curl.log")"
[ "$(grep -c '^method=chat.postMessage ' "$home/curl.log")" -eq 0 ] || fail "state-needs-write recovery must not post a replacement"
pass "fm-slack-post board completes a state-needs-write recovery with one live update"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-r3-snapshot-needed-recovers"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
_r3_pending "$home" "snapshot-needed" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "" "$CHANNEL_ID"
_r3_once "$home" "2026-08-26" "1786740000.222222"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r3-sn")" board "newbody")
[ "$ts" = "1786735224.690829" ] || fail "snapshot-needed recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "snapshot-needed recovery must clear its journal"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "newbody" ] || fail "snapshot-needed recovery must write the new body"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 2 ] || fail "snapshot-needed recovery must update the live message twice (recovery plus final): $(cat "$home/curl.log")"
[ "$(grep -c '^method=chat.postMessage ' "$home/curl.log")" -eq 0 ] || fail "snapshot-needed recovery must not post a replacement"
pass "fm-slack-post board completes a snapshot-needed recovery from a seeded once-file"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

# --- round-four: extra positive variants for every writer-reachable boundary ---

home="$TMP_ROOT/board-r4-initial-meta-written-no-meta"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_pending "$home" "initial-meta-written" "2026-08-27" "initialbody" "2026-08-27" "initialbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r4-imn")" board "initialbody")
[ "$ts" = "1786735224.690829" ] || fail "initial-meta-written(no meta) recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "initial-meta-written(no meta) recovery must clear its journal"
[ "$(grep -c '^channel=' "$home/state/slack-board/slack-board.meta")" -eq 1 ] || fail "initial-meta-written(no meta) recovery must write the identity"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 1 ] || fail "initial-meta-written(no meta) recovery must update the live message once"
pass "fm-slack-post board completes an initial-meta-written recovery before the meta write"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-r4-initial-meta-written-with-meta"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_pending "$home" "initial-meta-written" "2026-08-27" "initialbody" "2026-08-27" "initialbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r4-imw")" board "initialbody")
[ "$ts" = "1786735224.690829" ] || fail "initial-meta-written(with meta) recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "initial-meta-written(with meta) recovery must clear its journal"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 1 ] || fail "initial-meta-written(with meta) recovery must update the live message once"
pass "fm-slack-post board completes an initial-meta-written recovery after the meta write"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-r4-initial-state-needs-write-with-state"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-27" "initialbody"
_r3_pending "$home" "initial-state-needs-write" "2026-08-27" "initialbody" "2026-08-27" "initialbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r4-isnw")" board "initialbody")
[ "$ts" = "1786735224.690829" ] || fail "initial-state-needs-write(with state) recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "initial-state-needs-write(with state) recovery must clear its journal"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 1 ] || fail "initial-state-needs-write(with state) recovery must update the live message once"
pass "fm-slack-post board completes an initial-state-needs-write recovery after the state write"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-r4-live-needs-update-same-day"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-27" "priorbody"
_r3_pending "$home" "live-needs-update" "2026-08-27" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r4-lnu-sd")" board "newbody")
[ "$ts" = "1786735224.690829" ] || fail "same-day live-needs-update recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "same-day live-needs-update recovery must clear its journal"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "newbody" ] || fail "same-day live-needs-update recovery must write the new body"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 2 ] || fail "same-day live-needs-update recovery must update the live message twice: $(cat "$home/curl.log")"
pass "fm-slack-post board completes a same-day live-needs-update recovery"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-r4-live-needs-update-rollover"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
_r3_pending "$home" "live-needs-update" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "1786740000.222222" "$CHANNEL_ID"
_r3_once "$home" "2026-08-26" "1786740000.222222"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r4-lnu-rl")" board "newbody")
[ "$ts" = "1786735224.690829" ] || fail "rollover live-needs-update recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "rollover live-needs-update recovery must clear its journal"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "newbody" ] || fail "rollover live-needs-update recovery must write the new body"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 2 ] || fail "rollover live-needs-update recovery must update the live message twice: $(cat "$home/curl.log")"
pass "fm-slack-post board completes a rollover live-needs-update recovery"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-r4-state-needs-write-rollover-before"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
_r3_pending "$home" "state-needs-write" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "1786740000.222222" "$CHANNEL_ID"
_r3_once "$home" "2026-08-26" "1786740000.222222"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r4-snw-rl-b")" board "newbody")
[ "$ts" = "1786735224.690829" ] || fail "rollover state-needs-write(before) recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "rollover state-needs-write(before) recovery must clear its journal"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "newbody" ] || fail "rollover state-needs-write(before) recovery must write the new body"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 1 ] || fail "rollover state-needs-write(before) recovery must update the live message once: $(cat "$home/curl.log")"
pass "fm-slack-post board completes a rollover state-needs-write recovery before the state write"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-r4-state-needs-write-rollover-after"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-27" "newbody"
_r3_pending "$home" "state-needs-write" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "1786740000.222222" "$CHANNEL_ID"
_r3_once "$home" "2026-08-26" "1786740000.222222"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$(make_fake_curl "$home/fake-r4-snw-rl-a")" board "newbody")
[ "$ts" = "1786735224.690829" ] || fail "rollover state-needs-write(after) recovery must keep the live ts, got $ts"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "rollover state-needs-write(after) recovery must clear its journal"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "newbody" ] || fail "rollover state-needs-write(after) recovery must write the new body"
[ "$(grep -c '^method=chat.update ' "$home/curl.log")" -eq 1 ] || fail "rollover state-needs-write(after) recovery must update the live message once: $(cat "$home/curl.log")"
pass "fm-slack-post board completes a rollover state-needs-write recovery after the state write"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

# --- round-four: required negatives ---

home="$TMP_ROOT/board-r4-initial-date-mismatch"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_pending "$home" "initial-posted" "2026-08-20" "initialbody" "2026-08-27" "initialbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "initial-posted must have date equal to today"
pass "fm-slack-post board refuses an initial phase whose date differs from today"

home="$TMP_ROOT/board-r4-initial-body-mismatch"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_pending "$home" "initial-posted" "2026-08-27" "initialbody" "2026-08-27" "differentbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "initial-posted must have body equal to new_body"
pass "fm-slack-post board refuses an initial phase whose body differs from new_body"

home="$TMP_ROOT/board-r4-same-day-snapshot-needed"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-27" "priorbody"
_r3_pending "$home" "snapshot-needed" "2026-08-27" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "snapshot-needed is rollover-only"
pass "fm-slack-post board refuses a same-day snapshot-needed (rollover-only phase)"

home="$TMP_ROOT/board-r4-trailing-newline-body-conflict"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
printf '%s\n' '{"date":"2026-08-26","body":"priorbody\n"}' \
  | fmx_private_artifact_publish_stdin "$home/state/slack-board" "slack-board.state" 600
_r3_pending "$home" "snapshot-needed" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "" "$CHANNEL_ID"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "state body must equal journal body"
pass "fm-slack-post board refuses a trailing-newline body conflict (exact newline-safe comparison)"

home="$TMP_ROOT/board-r4-malformed-once-file"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
_r3_pending "$home" "snapshot-posting" "2026-08-26" "priorbody" "2026-08-27" "newbody" "1786735224.690829" "" "$CHANNEL_ID"
printf 'not-a-valid-ts' \
  | fmx_private_artifact_publish_stdin_once "$home/state/slack-board-snapshots" "2026-08-26" 600 \
  || fail "malformed once-file seed failed"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "malformed or non-canonical bytes"
[ "$(cat "$home/state/slack-board-snapshots/2026-08-26")" = "not-a-valid-ts" ] \
  || fail "malformed once-file refusal must not overwrite the once-file"
pass "fm-slack-post board refuses a malformed snapshot once-file without mutation"

home="$TMP_ROOT/board-r4-malformed-channel-suffix-board"
make_home "$home"
mkdir "$home/state/slack-board"; chmod 700 "$home/state/slack-board"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
printf 'channel=C012345678/\nts=1786735224.690829\n' \
  | fmx_private_artifact_publish_stdin "$home/state/slack-board" "slack-board.meta" 600 \
  || fail "malformed-channel meta seed failed"
_r3_state "$home" "2026-08-27" "stale"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "invalid Slack board identity"
pass "fm-slack-post board refuses a malformed channel suffix through the board entry point"

# Shared predicate + direct post/update entry points for a malformed channel suffix.
# shellcheck source=bin/fm-slack-lib.sh
. "$ROOT/bin/fm-slack-lib.sh"
if fms_channel_id_valid "C012345678/" 2>/dev/null; then
  fail "fms_channel_id_valid must reject a malformed channel suffix at the shared predicate"
fi
if fms_channel_id_valid "C0BQ9K1TJKG" 2>/dev/null; then :; else
  fail "fms_channel_id_valid must still accept a valid channel id at the shared predicate"
fi
home="$TMP_ROOT/board-r4-malformed-channel-direct-post"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-r4-badchan-post")
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL="C012345678/"
if run_post "$home" "$fakebin" message "hello" >/dev/null 2>&1; then
  fail "direct post must refuse a malformed configured channel suffix"
fi
pass "fm-slack-post refuses a malformed channel suffix at the direct post entry point"
export FAKE_SLACK_CHANNEL=$CHANNEL_ID

# --- round-four: writer-produced drift (pin validator and writer together) ---

home="$TMP_ROOT/board-r4-writer-drift"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-r4-drift")
log="$home/curl.log"
: > "$log"; export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$fakebin" board "body1")
[ "$ts" = "1786735224.690829" ] || fail "writer-drift setup must post the initial board"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "writer-drift setup must reach steady state"
# Crash the writer mid same-day update so it leaves a REAL live-needs-update journal.
export FAKE_SLACK_UPDATE='{"ok":false,"error":"chat_update_failed"}'
if run_post "$home" "$fakebin" board "body2" >/dev/null 2>"$home/drift.err"; then
  fail "writer-drift must crash when chat.update fails, leaving a real live-needs-update journal"
fi
[ -e "$home/state/slack-board/slack-board.pending" ] || fail "writer-drift must leave a pending journal after the crash"
real_phase=$(jq -er '.phase' "$home/state/slack-board/slack-board.pending")
[ "$real_phase" = "live-needs-update" ] || fail "writer-drift must leave a real live-needs-update journal, got $real_phase"
[ "$(jq -er '.date' "$home/state/slack-board/slack-board.pending")" = "2026-08-27" ] || fail "writer-drift journal date must equal today"
[ "$(jq -er '.snapshot_ts' "$home/state/slack-board/slack-board.pending")" = "" ] || fail "writer-drift same-day journal must have an empty snapshot_ts"
# Re-run with chat.update succeeding: the validator must accept the writer-produced layout and recover.
unset FAKE_SLACK_UPDATE
ts2=$(run_post "$home" "$fakebin" board "body2")
[ "$ts2" = "$ts" ] || fail "writer-drift recovery must keep the same live ts, got $ts2"
[ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "writer-drift recovery must clear the real journal"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "body2" ] || fail "writer-drift recovery must write the new body"
[ "$(grep -c '^method=chat.update ' "$log")" -ge 2 ] || fail "writer-drift recovery must retry the live update: $(cat "$log")"
pass "fm-slack-post board accepts a writer-produced live-needs-update journal and recovers"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

# --- round-four once-file axis: preflight through helper, bootstrap, and board
# Prove malformed steady-state snapshot evidence refuses before any rename,
# journal write, state write, or transport, through every entry point that can
# reach the shared migration preflight. Each case builds a steady rollover home
# (identity + daily state for a past date, no pending journal) with a malformed
# snapshot once-file and asserts every entry point refuses nonzero, names the
# defect, calls no transport, and leaves identity/state/once bytes unchanged.

_r4_run_helper() {
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-slack-board-migrate.sh" --lock-held >/dev/null 2>"$2"
}
_r4_run_bootstrap() {
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" FM_ROOT_OVERRIDE="$ROOT" PATH="$BASE_PATH" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>"$2"
}
_r4_run_board() {
  : > "$1/curl.log"; export FM_SLACK_CURL_LOG="$1/curl.log"
  unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
  run_post "$1" "$(make_fake_curl "$1/fake-r4")" board "today body" >/dev/null 2>"$2"
}
# _r4_refuse_three <label> <once-date> <printf-fmt>  -- refuse through all three
_r4_refuse_three() {
  local label=$1 once_date=$2 fmt=$3
  local entries=(helper bootstrap board) i rc home err
  for i in 0 1 2; do
    home="$TMP_ROOT/board-r4-$label-${entries[$i]}"
    make_home "$home"
    mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
    chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
    _r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
    _r3_state "$home" "$once_date" "priorbody"
    printf '%b' "$fmt" | fmx_private_artifact_publish_stdin_once "$home/state/slack-board-snapshots" "$once_date" 600
    # Independent canonical expected bytes, built by printf never by reading the
    # artifact under test into a shell string (command substitution strips
    # trailing LF and would miss a truncation/rewrite mutation).
    printf '%b' "$fmt" > "$home/expected-once"
    printf '{"date":"%s","body":"priorbody"}\n' "$once_date" > "$home/expected-state"
    manifest "$home/state/slack-board" "$home/pre-b"
    manifest "$home/state/slack-board-snapshots" "$home/pre-s"
    err="$home/e.err"
    case "$i" in
      0) _r4_run_helper "$home" "$err"; rc=$? ;;
      1) _r4_run_bootstrap "$home" "$err"; rc=$? ;;
      2) _r4_run_board "$home" "$err"; rc=$? ;;
    esac
    [ "$rc" -ne 0 ] || fail "$label via ${entries[$i]} must refuse"
    grep -Fq "malformed or non-canonical bytes" "$err" || fail "$label via ${entries[$i]} must name the defect: $(cat "$err")"
    assert_bytes_eq "$home/expected-once" "$home/state/slack-board-snapshots/$once_date" \
      || fail "$label via ${entries[$i]} must not alter once bytes"
    assert_bytes_eq "$home/expected-state" "$home/state/slack-board/slack-board.state" \
      || fail "$label via ${entries[$i]} must not alter state bytes"
    grep -Fq "ts=1786735224.690829" "$home/state/slack-board/slack-board.meta" || fail "$label via ${entries[$i]} must not alter identity"
    [ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "$label via ${entries[$i]} must not write a pending journal"
    [ -d "$home/state/slack-board" ] || fail "$label via ${entries[$i]} must not rename the board directory"
    [ ! -e "$home/state/slack-board.meta" ] || fail "$label via ${entries[$i]} must not create the legacy directory"
    if [ "$i" -eq 2 ]; then
      [ "$(grep -c '^method=' "$home/curl.log")" -eq 0 ] || fail "$label via board must not call Slack: $(cat "$home/curl.log")"
    fi
    manifest "$home/state/slack-board" "$home/post-b"
    manifest "$home/state/slack-board-snapshots" "$home/post-s"
    assert_bytes_eq "$home/pre-b" "$home/post-b" || fail "$label via ${entries[$i]} must leave the board manifest unchanged"
    assert_bytes_eq "$home/pre-s" "$home/post-s" || fail "$label via ${entries[$i]} must leave the snapshot manifest unchanged"
  done
  pass "fm-slack-post board refuses a $label steady snapshot once-file through helper, bootstrap, and board"
}

_r4_refuse_three "not-a-ts" "2026-08-26" 'not-a-ts'
_r4_refuse_three "two-lf" "2026-08-26" '1786735224.690829\n\n'
_r4_refuse_three "no-lf" "2026-08-26" '1786735224.690829'

# Canonical one-LF once-file is accepted and preserves snapshot dedupe: a steady
# rollover with a pre-existing canonical once-file must skip the snapshot post
# and still update the live message, proving the strict reader accepts exactly
# one LF and reuses the recorded timestamp as delivery evidence.
home="$TMP_ROOT/board-r4-canonical-one-lf"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-r4-canonical")
log="$home/curl.log"; : > "$log"; export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
ts=$(run_post "$home" "$fakebin" board "closedbody")
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
mkdir -p "$home/state/slack-board-snapshots"; chmod 700 "$home/state/slack-board-snapshots"
printf '1786735230.111111\n' | fmx_private_artifact_publish_stdin_once "$home/state/slack-board-snapshots" "2026-08-27" 600
# Independent canonical expected bytes (printf, never read the artifact under test).
printf '1786735230.111111\n' > "$home/expected-once"
manifest "$home/state/slack-board-snapshots" "$home/pre-snap"
ts2=$(run_post "$home" "$fakebin" board "todaybody")
[ "$ts2" = "$ts" ] || fail "canonical one-LF once-file must preserve the live ts"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 1 ] || fail "canonical once-file must skip a duplicate snapshot post: $(cat "$log")"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 1 ] || fail "canonical once-file must still update the live message: $(cat "$log")"
assert_bytes_eq "$home/expected-once" "$home/state/slack-board-snapshots/2026-08-27" \
  || fail "canonical once-file must not be overwritten (bytes must match exactly)"
manifest "$home/state/slack-board-snapshots" "$home/post-snap"
assert_bytes_eq "$home/pre-snap" "$home/post-snap" || fail "canonical once-file must leave the snapshot manifest unchanged"
pass "fm-slack-post board accepts a canonical one-LF once-file and preserves snapshot dedupe"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

# Unsafe snapshot directory: a group-readable snapshot dir is not private and
# must refuse through the board entry point before any transport or mutation.
home="$TMP_ROOT/board-r4-unsafe-snap-dir"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 750 "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "not a private mode-700 directory"
[ "$(grep -c '^method=' "$home/curl.log")" -eq 0 ] || fail "unsafe snapshot dir must not call Slack"
pass "fm-slack-post board refuses a non-private snapshot directory"

# §3.3: a mode-0500 store is owner-only but not mode-700, so the one 700
# predicate refuses it. The diagnostic must name the directory and its mode,
# not the once-file entries (the old mode-&-077 check accepted 0500 and then
# the per-entry reader failed with a misleading "malformed bytes" message).
home="$TMP_ROOT/board-r5-snap-dir-mode-0500"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board"
chmod 500 "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "mode 500, not a private mode-700 directory"
grep -Fq "slack-board-snapshots" "$home/e.err" \
  || fail "the 0500 refusal must name the snapshot directory: $(cat "$home/e.err")"
[ "$(grep -c '^method=' "$home/curl.log")" -eq 0 ] || fail "a 0500 store must not call Slack"
pass "fm-slack-post board refuses a mode-0500 snapshot store naming the directory and mode"

# Unexpected snapshot entry: a non-date-shaped filename must refuse.
home="$TMP_ROOT/board-r4-unexpected-snap-entry"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
printf '1786735230.222222\n' | fmx_private_artifact_publish_stdin_once "$home/state/slack-board-snapshots" "not-a-date" 600
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "unexpected filename"
[ "$(grep -c '^method=' "$home/curl.log")" -eq 0 ] || fail "unexpected snapshot entry must not call Slack"
pass "fm-slack-post board refuses an unexpected snapshot entry filename"

# Malformed snapshot entry: a directory at a date-shaped name is not a regular
# once-file and must refuse.
home="$TMP_ROOT/board-r4-snap-entry-is-dir"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
mkdir "$home/state/slack-board-snapshots/2026-08-26"; chmod 600 "$home/state/slack-board-snapshots/2026-08-26"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "malformed or non-canonical bytes"
[ "$(grep -c '^method=' "$home/curl.log")" -eq 0 ] || fail "directory snapshot entry must not call Slack"
pass "fm-slack-post board refuses a non-regular snapshot entry"

# --- §7.3 new end-to-end refusal cases through the board entry point --------
# Each closes a §3 gap end-to-end: nonzero status, zero transport, no journal,
# and (for the layout-mutating candidates) a byte-identical pre/post manifest
# of both the board and snapshot directories via the §7.1 helpers.

# §5.5 orphan store: a snapshot store with no board directory refuses, naming
# the store and its remediation.
home="$TMP_ROOT/board-r5-orphan-store"
make_home "$home"
mkdir "$home/state/slack-board-snapshots"; chmod 700 "$home/state/slack-board-snapshots"
_r3_once "$home" "2026-08-26" "1786735224.690829"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
manifest "$home/state/slack-board-snapshots" "$home/pre-snap"
if run_post "$home" "$(make_fake_curl "$home/fake-r3")" board "today body" >/dev/null 2>"$home/e.err"; then
  fail "board must refuse an orphan snapshot store"
fi
grep -Fq "orphan Slack board snapshot store" "$home/e.err" \
  || fail "orphan refusal must name the orphan store: $(cat "$home/e.err")"
grep -Fq "move" "$home/e.err" \
  || fail "orphan refusal must name its remediation: $(cat "$home/e.err")"
[ "$(grep -c '^method=' "$home/curl.log")" -eq 0 ] || fail "orphan store must not call Slack"
[ ! -e "$home/state/slack-board" ] || fail "orphan refusal must not create a board directory"
manifest "$home/state/slack-board-snapshots" "$home/post-snap"
assert_bytes_eq "$home/pre-snap" "$home/post-snap"
pass "fm-slack-post board refuses an orphan snapshot store with remediation text"

# §3.1 fresh-path hole: a canonical board directory (slack-board/) is present
# AND a malformed once-file sits in the snapshot store. The old code skipped the
# snapshot preflight on the canonical branch; the one owner entry sequence
# validates the store before the board-directory branch, so this now refuses.
home="$TMP_ROOT/board-r5-fresh-path-malformed-once"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
printf 'not-a-ts\n' | fmx_private_artifact_publish_stdin "$home/state/slack-board-snapshots" "2026-08-26" 600
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "malformed or non-canonical bytes"
pass "fm-slack-post board refuses a malformed snapshot once-file with a canonical board present (§3.1)"

# §3.3 other directory: a mode-0500 board directory refuses, naming the
# directory and its mode (the one 700 predicate, applied to the board directory).
home="$TMP_ROOT/board-r5-board-dir-mode-0500"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 500 "$home/state/slack-board"
chmod 700 "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "mode 500, not a private mode-700 directory"
grep -Fq "slack-board " "$home/e.err" || grep -Fq "slack-board$" "$home/e.err" \
  || fail "the 0500 board refusal must name the board directory: $(cat "$home/e.err")"
pass "fm-slack-post board refuses a mode-0500 board directory naming the directory and mode"

# §3.7 end-to-end: a two-JSON-value slack-board.state refuses through the board
# entry point (the single-value validator, not just the unit test).
home="$TMP_ROOT/board-r5-two-value-state"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
printf '{"date":"2026-08-26","body":"a"}\n{"date":"2026-08-27","body":"b"}\n' \
  | fmx_private_artifact_publish_stdin "$home/state/slack-board" "slack-board.state" 600
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "invalid Slack board daily state"
pass "fm-slack-post board refuses a two-JSON-value slack-board.state (§3.7)"

# §3.7 second site: a two-JSON-value slack-board.pending refuses end-to-end.
home="$TMP_ROOT/board-r5-two-value-pending"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
printf '{"phase":"snapshot-needed","date":"2026-08-26","today":"2026-09-04","body":"a","new_body":"b","live_ts":"1786735224.690829","snapshot_ts":"","channel":"%s"}\n{"phase":"snapshot-needed","date":"2026-08-27","today":"2026-09-04","body":"c","new_body":"d","live_ts":"1786735224.690829","snapshot_ts":"","channel":"%s"}\n' \
  "$CHANNEL_ID" "$CHANNEL_ID" \
  | fmx_private_artifact_publish_stdin "$home/state/slack-board" "slack-board.pending" 600
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "invalid Slack board pending journal"
pass "fm-slack-post board refuses a two-JSON-value slack-board.pending (§3.7)"

# §3.5 board-directory inventory: an unexpected regular file inside
# state/slack-board/ refuses (the inventory's unknown class, end-to-end).
home="$TMP_ROOT/board-r5-unexpected-board-entry"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
printf 'x\n' | fmx_private_artifact_publish_stdin "$home/state/slack-board" "unexpected" 600
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "unexpected filename"
pass "fm-slack-post board refuses an unexpected entry inside the board directory (§3.5)"

# §3.4 second site: a calendar-invalid date in slack-board.state refuses
# end-to-end (the calendar oracle, not just the unit test).
home="$TMP_ROOT/board-r5-calendar-invalid-state"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
printf '{"date":"2026-99-99","body":"b"}\n' \
  | fmx_private_artifact_publish_stdin "$home/state/slack-board" "slack-board.state" 600
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "invalid Slack board daily state"
pass "fm-slack-post board refuses a calendar-invalid slack-board.state date (§3.4)"

# §3.2 sentinel + lexical-hiding: a dangling symlink at 2026-09-01 followed by
# a malformed once-file at 2026-09-02. find -mindepth 1 -maxdepth 1 -print0 sees
# both (the dangling symlink is enumerated, not a sentinel the glob skips), so
# the once-file validator refuses on the dangling symlink. This is the §7.4
# inventory-mutant guard: the glob form (for entry in "$dir"/*) does not expand
# a dangling symlink whose target is missing the same way and can hide the
# malformed follower; the find-based inventory catches it.
home="$TMP_ROOT/board-r5-sentinel-lexical-hiding"
make_home "$home"
mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
_r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
_r3_state "$home" "2026-08-26" "priorbody"
ln -s missing "$home/state/slack-board-snapshots/2026-09-01"
printf 'not-a-ts\n' | fmx_private_artifact_publish_stdin "$home/state/slack-board-snapshots" "2026-09-02" 600
: > "$home/curl.log"; export FM_SLACK_CURL_LOG="$home/curl.log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE; export FAKE_SLACK_CHANNEL=$CHANNEL_ID
_r3_refuse "$home" "$home/e.err" "malformed or non-canonical bytes"
pass "fm-slack-post board refuses a dangling-symlink sentinel and a malformed follower (§3.2/§7.4)"

# --- P1 (round six) end-to-end: a temp-shaped invalid entry refuses through
# helper, network-skipped bootstrap, and fake-transport board with zero
# transport, no journal, and unchanged no-follow manifests of both stores.
# A real publisher temp is tolerated; a dangling symlink / directory /
# wrong-mode file under a temp-shaped name is not and must not reach rename
# or transport.
_r6_refuse_temp_three() {
  local label=$1 kind=$2 rel=$3 maker=$4
  local entries=(helper bootstrap board) i rc home err
  for i in 0 1 2; do
    home="$TMP_ROOT/board-r6-$label-${entries[$i]}"
    make_home "$home"
    mkdir "$home/state/slack-board" "$home/state/slack-board-snapshots"
    chmod 700 "$home/state/slack-board" "$home/state/slack-board-snapshots"
    _r3_meta "$home" "$CHANNEL_ID" "1786735224.690829"
    _r3_state "$home" "2026-08-26" "priorbody"
    # a real publisher temp is tolerated alongside the invalid candidate
    printf 'partial' > "$home/state/slack-board/.slack-board.state.fm-x.q7Z8ez"; chmod 600 "$home/state/slack-board/.slack-board.state.fm-x.q7Z8ez"
    printf 'partial' > "$home/state/slack-board-snapshots/.2026-08-26.fm-x.q7Z8ez"; chmod 600 "$home/state/slack-board-snapshots/.2026-08-26.fm-x.q7Z8ez"
    eval "$maker"
    manifest "$home/state/slack-board" "$home/pre-b"
    manifest "$home/state/slack-board-snapshots" "$home/pre-s"
    err="$home/e.err"
    case "$i" in
      0) _r4_run_helper "$home" "$err"; rc=$? ;;
      1) _r4_run_bootstrap "$home" "$err"; rc=$? ;;
      2) _r4_run_board "$home" "$err"; rc=$? ;;
    esac
    [ "$rc" -ne 0 ] || fail "$label via ${entries[$i]} must refuse"
    grep -Fq "inspect before the next board or bootstrap call" "$err" || fail "$label via ${entries[$i]} must name the defect: $(cat "$err")"
    [ -d "$home/state/slack-board" ] || fail "$label via ${entries[$i]} must not rename the board directory"
    [ ! -e "$home/state/slack-board.meta" ] || fail "$label via ${entries[$i]} must not create the legacy directory"
    [ ! -e "$home/state/slack-board/slack-board.pending" ] || fail "$label via ${entries[$i]} must not write a pending journal"
    if [ "$i" -eq 2 ]; then
      [ "$(grep -c '^method=' "$home/curl.log")" -eq 0 ] || fail "$label via board must not call Slack: $(cat "$home/curl.log")"
    fi
    manifest "$home/state/slack-board" "$home/post-b"
    manifest "$home/state/slack-board-snapshots" "$home/post-s"
    assert_bytes_eq "$home/pre-b" "$home/post-b"
    assert_bytes_eq "$home/pre-s" "$home/post-s"
  done
  pass "fm-slack-post refuses a $label temp-shaped entry through helper, bootstrap, and board"
}
# The maker snippets intentionally defer $home expansion to eval so the probe
# runs against each per-entry-point home; SC2016 is expected and suppressed.
# shellcheck disable=SC2016
_r6_refuse_temp_three "snap-temp-dangling" snapshots "" \
  'ln -s missing "$home/state/slack-board-snapshots/.2026-09-01.fm-x.AAAAAA"'
# shellcheck disable=SC2016
_r6_refuse_temp_three "snap-temp-644" snapshots "" \
  'printf p > "$home/state/slack-board-snapshots/.2026-09-02.fm-x.AAAAAA"; chmod 644 "$home/state/slack-board-snapshots/.2026-09-02.fm-x.AAAAAA"'
# shellcheck disable=SC2016
_r6_refuse_temp_three "board-temp-dir" board "" \
  'mkdir "$home/state/slack-board/.slack-board.pending.fm-x.AAAAAA"; chmod 700 "$home/state/slack-board/.slack-board.pending.fm-x.AAAAAA"'

# --- binary-safe helper self-test (§7.1) -----------------------------------
# assert_bytes_eq and manifest are the evidence layer for every later red-green
# slice in this redesign: byte equality must survive command substitution
# stripping trailing newlines, and a directory inventory must see dotfiles,
# dangling symlinks, and trailing bytes. Pin both properties here so a later
# change cannot silently regress the helpers the assertions depend on.
home="$TMP_ROOT/board-r5-binary-helpers"
make_home "$home"
hb="$home/h"; mkdir -p "$hb"; chmod 700 "$hb"
printf 'channel=C0BQ9K1TJKG\nts=1786735224.690829\n' > "$hb/meta"; chmod 600 "$hb/meta"
printf 'x' > "$hb/no-lf"; chmod 600 "$hb/no-lf"
ln -s missing "$hb/dangling"
manifest "$hb" "$home/m1"
manifest "$hb" "$home/m2"
assert_bytes_eq "$home/m1" "$home/m2"
# A trailing newline is a real byte the inventory must distinguish.
printf 'x\n' > "$hb/with-lf"; chmod 600 "$hb/with-lf"
manifest "$hb" "$home/m3"
if cmp -s "$home/m1" "$home/m3"; then fail "manifest must distinguish a trailing newline"; fi
# assert_bytes_eq must fail the suite on differing bytes; prove it would fire by
# checking the predicate directly (assert_bytes_eq exits on differ).
printf 'y' > "$home/other"; chmod 600 "$home/other"
if cmp -s "$hb/no-lf" "$home/other"; then fail "assert_bytes_eq must fail on differing bytes"; fi
# The manifest must also distinguish a mode change and a type change on the
# same content, not just trailing bytes: a future implementation that rewrites
# a fixture without its LF, changes mode 600 to 644, or replaces a file with a
# same-content symlink must leave the focused suite red.
printf 'x' > "$hb/mode-probe"; chmod 600 "$hb/mode-probe"
manifest "$hb" "$home/m-mode"
chmod 644 "$hb/mode-probe"
manifest "$hb" "$home/m-mode2"
if cmp -s "$home/m-mode" "$home/m-mode2"; then fail "manifest must distinguish a mode change"; fi
printf 'x' > "$hb/type-probe"; chmod 600 "$hb/type-probe"
manifest "$hb" "$home/m-type"
rm -f "$hb/type-probe"; ln -s "$hb/no-lf" "$hb/type-probe"
manifest "$hb" "$home/m-type2"
if cmp -s "$home/m-type" "$home/m-type2"; then fail "manifest must distinguish a type change"; fi
rm -f "$hb/mode-probe" "$hb/type-probe"
# Failing-mutation evidence for the round-five command-substitution oracle: a
# two-LF once-file mutated to no-LF compares equal under $(cat) (both strip
# trailing LF) but assert_bytes_eq detects it. This is the regression class the
# preservation surface must lock down.
printf '1786735230.111111\n\n' > "$home/two-lf"; chmod 600 "$home/two-lf"
printf '1786735230.111111' > "$home/no-lf-mut"; chmod 600 "$home/no-lf-mut"
if [ "$(cat "$home/two-lf")" != "$(cat "$home/no-lf-mut")" ]; then fail "the old \$(cat) oracle must miss the trailing-LF mutation (proof of why it was replaced)"; fi
if cmp -s "$home/two-lf" "$home/no-lf-mut"; then fail "assert_bytes_eq must detect the trailing-LF mutation the old oracle missed"; fi
pass "binary-safe helpers distinguish trailing bytes, mode, and type and see dotfiles and dangling symlinks"
rm -rf "$home/h" "$home/m1" "$home/m2" "$home/m3" "$home/other" "$home/m-mode" "$home/m-mode2" "$home/m-type" "$home/m-type2"

# --- fms_date_calendar_valid unit cases (§5.4, step 2) -----------------------
# One calendar oracle for every YYYY-MM-DD in the contract. No callers yet;
# pin the predicate directly so a later step that points the four call sites
# (once-file name, state .date, journal .date, journal .today) at it
# cannot silently change its behaviour.
# shellcheck source=bin/fm-slack-lib.sh
. "$ROOT/bin/fm-slack-lib.sh"
for d in 2026-09-04 2024-02-29 2026-01-31 2026-12-31; do
  fms_date_calendar_valid "$d" || fail "fms_date_calendar_valid must accept $d"
done
for d in 2026-99-99 2026-00-10 2026-13-01 2026-02-30 2026-02-29 2026-1-1 "" not-a-date 2026-09-4; do
  if fms_date_calendar_valid "$d" 2>/dev/null; then fail "fms_date_calendar_valid must reject $d"; fi
done
pass "fms_date_calendar_valid accepts real dates and rejects impossible or normalising dates"

# --- fms_board_state_valid / fms_board_journal_valid unit cases (§5.4, step 4)
# The single-value enforcement (jq -es 'length == 1') is the §3.7 fix AND the
# §7.4 value-predicate mutant guard: a two-value state or journal file passes
# jq -e '…' (last value wins) but is not a layout the writer can produce, and
# feeding it through the writer wedges the home. The mutant that replaces
# jq -es 'length == 1 and …' with jq -e '…' must fail the two-value cases below
# and the end-to-end two-value cases above. Pin both predicates directly; no
# are deleted and callers re-pointed in later steps).
_mkstate() { local d=$1; printf '{"date":"%s","body":"b"}\n' "$d"; }
home="$TMP_ROOT/board-r5-state-journal"
mkdir -p "$home"; chmod 700 "$home"
# state: valid single value accepted
_mkstate 2026-09-04 > "$home/slack-board.state"; chmod 600 "$home/slack-board.state"
fms_board_state_valid "$home" || fail "fms_board_state_valid must accept a single-value state"
# state: two values refused (the §3.7 defect)
printf '{"junk":1}\n{"date":"2026-09-04","body":"b"}\n' > "$home/slack-board.state"; chmod 600 "$home/slack-board.state"
if fms_board_state_valid "$home" 2>/dev/null; then fail "fms_board_state_valid must refuse a two-value state"; fi
# state: calendar-invalid date refused (§3.4 second site)
_mkstate 2026-99-99 > "$home/slack-board.state"; chmod 600 "$home/slack-board.state"
if fms_board_state_valid "$home" 2>/dev/null; then fail "fms_board_state_valid must refuse a calendar-invalid date"; fi
# state: non-object refused
printf '"scalar"\n' > "$home/slack-board.state"; chmod 600 "$home/slack-board.state"
if fms_board_state_valid "$home" 2>/dev/null; then fail "fms_board_state_valid must refuse a non-object state"; fi
# state: trailing garbage refused
printf '{"date":"2026-09-04","body":"b"}x' > "$home/slack-board.state"; chmod 600 "$home/slack-board.state"
if fms_board_state_valid "$home" 2>/dev/null; then fail "fms_board_state_valid must refuse trailing garbage"; fi
# state: zero-byte refused
: > "$home/slack-board.state"; chmod 600 "$home/slack-board.state"
if fms_board_state_valid "$home" 2>/dev/null; then fail "fms_board_state_valid must refuse a zero-byte state"; fi
pass "fms_board_state_valid accepts one value and refuses two-value, calendar-invalid, and garbage states"

_mkpending() {
  local phase=$1 date=$2 today=$3 chan=$4
  printf '{"phase":"%s","date":"%s","today":"%s","body":"b","new_body":"n","live_ts":"1786735224.690829","snapshot_ts":"","channel":"%s"}\n' \
    "$phase" "$date" "$today" "$chan"
}
# journal: valid single value accepted (channel required for every phase)
_mkpending snapshot-needed 2026-09-03 2026-09-04 C0BQ9K1TJKG > "$home/slack-board.pending"; chmod 600 "$home/slack-board.pending"
fms_board_journal_valid "$home" || fail "fms_board_journal_valid must accept a single-value journal"
# journal: two values refused (§3.7 second site)
printf '{"junk":1}\n{"phase":"snapshot-needed","date":"2026-09-03","today":"2026-09-04","body":"b","new_body":"n","live_ts":"1786735224.690829","snapshot_ts":"","channel":"C0BQ9K1TJKG"}\n' > "$home/slack-board.pending"; chmod 600 "$home/slack-board.pending"
if fms_board_journal_valid "$home" 2>/dev/null; then fail "fms_board_journal_valid must refuse a two-value journal"; fi
# journal: missing .channel on a non-initial phase refused (§4 drift, strict direction)
printf '{"phase":"snapshot-needed","date":"2026-09-03","today":"2026-09-04","body":"b","new_body":"n","live_ts":"1786735224.690829","snapshot_ts":""}\n' > "$home/slack-board.pending"; chmod 600 "$home/slack-board.pending"
if fms_board_journal_valid "$home" 2>/dev/null; then fail "fms_board_journal_valid must require .channel on every phase"; fi
# journal: calendar-invalid .today refused (§3.4 third/fourth site)
_mkpending snapshot-needed 2026-09-03 2026-99-99 C0BQ9K1TJKG > "$home/slack-board.pending"; chmod 600 "$home/slack-board.pending"
if fms_board_journal_valid "$home" 2>/dev/null; then fail "fms_board_journal_valid must refuse a calendar-invalid today"; fi
# journal: unknown phase refused
_mkpending not-a-phase 2026-09-03 2026-09-04 C0BQ9K1TJKG > "$home/slack-board.pending"; chmod 600 "$home/slack-board.pending"
if fms_board_journal_valid "$home" 2>/dev/null; then fail "fms_board_journal_valid must refuse an unknown phase"; fi
# journal: zero-byte refused
: > "$home/slack-board.pending"; chmod 600 "$home/slack-board.pending"
if fms_board_journal_valid "$home" 2>/dev/null; then fail "fms_board_journal_valid must refuse a zero-byte journal"; fi
pass "fms_board_journal_valid accepts one value, requires channel, and refuses two-value and garbage journals"
rm -rf "$home"

# --- fms_board_identity_valid unit cases (§5.4, step 5) ----------------------
# One identity owner, replacing the grep | tail -1 last-duplicate-wins readers.
# The contract: exactly one channel= line, exactly one ts= line, no other
# non-empty line; channel and ts valid; trailing blank lines tolerated.
home="$TMP_ROOT/board-r5-identity"
mkdir -p "$home"; chmod 700 "$home"
# valid identity accepted, prints channel<TAB>ts
printf 'channel=C0BQ9K1TJKG\nts=1786735224.690829\n' > "$home/slack-board.meta"; chmod 600 "$home/slack-board.meta"
out=$(fms_board_identity_valid "$home") || fail "fms_board_identity_valid must accept a valid identity"
[ "$out" = "$(printf 'C0BQ9K1TJKG\t1786735224.690829')" ] || fail "fms_board_identity_valid must print channel<TAB>ts"
# trailing blank line tolerated (parse is total, grep -c '.' ignores blank lines)
printf 'channel=C0BQ9K1TJKG\nts=1786735224.690829\n\n' > "$home/slack-board.meta"; chmod 600 "$home/slack-board.meta"
fms_board_identity_valid "$home" >/dev/null || fail "fms_board_identity_valid must tolerate a trailing blank line"
# field order is irrelevant
printf 'ts=1786735224.690829\nchannel=C0BQ9K1TJKG\n' > "$home/slack-board.meta"; chmod 600 "$home/slack-board.meta"
fms_board_identity_valid "$home" >/dev/null || fail "fms_board_identity_valid must tolerate field order"
# duplicate channel refused (last-duplicate-wins is gone)
printf 'channel=C0BQ9K1TJKG\nchannel=C0BQ9K1TJKG\nts=1786735224.690829\n' > "$home/slack-board.meta"; chmod 600 "$home/slack-board.meta"
if fms_board_identity_valid "$home" 2>/dev/null; then fail "fms_board_identity_valid must refuse a duplicate channel"; fi
# missing ts refused
printf 'channel=C0BQ9K1TJKG\n' > "$home/slack-board.meta"; chmod 600 "$home/slack-board.meta"
if fms_board_identity_valid "$home" 2>/dev/null; then fail "fms_board_identity_valid must refuse a missing ts"; fi
# extra non-empty line refused
printf 'channel=C0BQ9K1TJKG\nts=1786735224.690829\nbogus=1\n' > "$home/slack-board.meta"; chmod 600 "$home/slack-board.meta"
if fms_board_identity_valid "$home" 2>/dev/null; then fail "fms_board_identity_valid must refuse an extra field"; fi
# invalid channel refused
printf 'channel=not-a-channel\nts=1786735224.690829\n' > "$home/slack-board.meta"; chmod 600 "$home/slack-board.meta"
if fms_board_identity_valid "$home" 2>/dev/null; then fail "fms_board_identity_valid must refuse an invalid channel"; fi
# invalid ts refused
printf 'channel=C0BQ9K1TJKG\nts=not-a-ts\n' > "$home/slack-board.meta"; chmod 600 "$home/slack-board.meta"
if fms_board_identity_valid "$home" 2>/dev/null; then fail "fms_board_identity_valid must refuse an invalid ts"; fi
# zero-byte refused
: > "$home/slack-board.meta"; chmod 600 "$home/slack-board.meta"
if fms_board_identity_valid "$home" 2>/dev/null; then fail "fms_board_identity_valid must refuse a zero-byte identity"; fi
pass "fms_board_identity_valid accepts one channel+ts and refuses duplicates, missing fields, and extra lines"
rm -rf "$home"

# --- fms_board_dir_inventory_assert unit cases (§5.3, step 7) ----------------
# Complete enumeration: find -print0 sees dotfiles and dangling symlinks and
# has no early-termination sentinel, closing §3.2 (hidden/dangling/shape-only
# entries) and §3.5 (the board directory had no inventory at all). Three entry
# classes: artifact, temp (the publishers' own .fm-x.XXXXXX pattern, §3.6),
# unknown (refuse). Pin both directories.
home="$TMP_ROOT/board-r5-inventory"
mkdir -p "$home"; chmod 700 "$home"
# board directory: three named artifacts accepted
hb="$home/board"; mkdir -p "$hb"; chmod 700 "$hb"
printf 'channel=C0BQ9K1TJKG\nts=1786735224.690829\n' > "$hb/slack-board.meta"; chmod 600 "$hb/slack-board.meta"
printf '{"date":"2026-09-04","body":"b"}\n' > "$hb/slack-board.state"; chmod 600 "$hb/slack-board.state"
printf '{"phase":"snapshot-needed","date":"2026-09-03","today":"2026-09-04","body":"b","new_body":"n","live_ts":"1786735224.690829","snapshot_ts":"","channel":"C0BQ9K1TJKG"}\n' > "$hb/slack-board.pending"; chmod 600 "$hb/slack-board.pending"
fms_board_dir_inventory_assert "$hb" board || fail "board inventory must accept the three named artifacts"
# board directory: a publisher temp is ignored (writer-reachable, §3.6)
printf 'partial' > "$hb/.slack-board.state.fm-x.q7Z8ez"; chmod 600 "$hb/.slack-board.state.fm-x.q7Z8ez"
fms_board_dir_inventory_assert "$hb" board || fail "board inventory must ignore a publisher temp"
# board directory: an unexpected file refuses (§3.5)
printf 'x' > "$hb/unexpected"; chmod 600 "$hb/unexpected"
if fms_board_dir_inventory_assert "$hb" board 2>/dev/null; then fail "board inventory must refuse an unexpected entry"; fi
rm -f "$hb/unexpected"
# board directory: a hidden dotfile that is not a temp refuses (§3.2 dotfile blindness)
printf 'x' > "$hb/.2026-09-01"; chmod 600 "$hb/.2026-09-01"
if fms_board_dir_inventory_assert "$hb" board 2>/dev/null; then fail "board inventory must refuse a hidden non-temp dotfile"; fi
rm -f "$hb/.2026-09-01"
# board directory: a dangling symlink is enumerated (not a sentinel), and as an unknown name refuses (§3.2)
ln -s missing "$hb/dangling"
if fms_board_dir_inventory_assert "$hb" board 2>/dev/null; then fail "board inventory must refuse a dangling symlink"; fi
rm -f "$hb/dangling"
pass "board directory inventory accepts artifacts+temps and refuses unknown, hidden, and dangling entries"

# snapshot store: a calendar-valid once-file accepted; a temp ignored
hs="$home/snaps"; mkdir -p "$hs"; chmod 700 "$hs"
printf '1786735224.690829\n' > "$hs/2026-09-03"; chmod 600 "$hs/2026-09-03"
fms_board_dir_inventory_assert "$hs" snapshots || fail "snapshot inventory must accept a calendar-valid once-file"
printf 'partial' > "$hs/.2026-09-03.fm-x.q7Z8ez"; chmod 600 "$hs/.2026-09-03.fm-x.q7Z8ez"
fms_board_dir_inventory_assert "$hs" snapshots || fail "snapshot inventory must ignore a publisher temp"
# snapshot store: a calendar-invalid name refuses (§3.4)
printf '1786735224.690829\n' > "$hs/2026-99-99"; chmod 600 "$hs/2026-99-99"
if fms_board_dir_inventory_assert "$hs" snapshots 2>/dev/null; then fail "snapshot inventory must refuse a calendar-invalid name"; fi
rm -f "$hs/2026-99-99"
# snapshot store: a hidden malformed dotfile refuses (§3.2)
printf 'x' > "$hs/.2026-09-01"; chmod 600 "$hs/.2026-09-01"
if fms_board_dir_inventory_assert "$hs" snapshots 2>/dev/null; then fail "snapshot inventory must refuse a hidden non-temp dotfile"; fi
rm -f "$hs/.2026-09-01"
# snapshot store: a dangling symlink with a date-shaped name is a known artifact
# name, so the inventory (classification only) accepts it; the value validator
# fms_board_once_valid owns file-type/mode/bytes and refuses it (§3.2 sentinel).
ln -s missing "$hs/2026-09-02"
fms_board_dir_inventory_assert "$hs" snapshots || fail "snapshot inventory must accept a date-named dangling symlink (value validator owns refusal)"
fms_board_once_valid "$hs" "2026-09-02" >/dev/null 2>&1 && fail "fms_board_once_valid must refuse a dangling symlink snapshot"
rm -f "$hs/2026-09-02"
# snapshot store: a non-date name refuses
printf 'x' > "$hs/not-a-date"; chmod 600 "$hs/not-a-date"
if fms_board_dir_inventory_assert "$hs" snapshots 2>/dev/null; then fail "snapshot inventory must refuse a non-date name"; fi
rm -f "$hs/not-a-date"
pass "snapshot store inventory accepts calendar-valid once-files+temps and refuses invalid names"
rm -rf "$home"

# --- P1 (round six): temp-shaped entries must satisfy the publisher's filesystem
# invariants, not just the name. A real interrupted-publisher temp is a private
# regular non-symlink single-link mode-600 file on the store device; a dangling
# symlink, directory, FIFO, hard link, or wrong-mode file under a temp-shaped
# name cannot be left by the publisher and must refuse. Pin both stores.
home="$TMP_ROOT/board-r6-temp-shape"
mkdir -p "$home"; chmod 700 "$home"
hb="$home/board"; mkdir -p "$hb"; chmod 700 "$hb"
hs="$home/snaps"; mkdir -p "$hs"; chmod 700 "$hs"
# valid real interrupted-publisher temps are accepted and never read or mutated.
printf 'partial' > "$hb/.slack-board.state.fm-x.q7Z8ez"; chmod 600 "$hb/.slack-board.state.fm-x.q7Z8ez"
printf 'partial' > "$hs/.2026-09-03.fm-x.q7Z8ez"; chmod 600 "$hs/.2026-09-03.fm-x.q7Z8ez"
fms_board_dir_inventory_assert "$hb" board || fail "board inventory must accept a real publisher temp"
fms_board_dir_inventory_assert "$hs" snapshots || fail "snapshot inventory must accept a real publisher temp"
# board temp: dangling symlink refuses
ln -s missing "$hb/.slack-board.pending.fm-x.AAAAAA"
if fms_board_dir_inventory_assert "$hb" board 2>/dev/null; then fail "board inventory must refuse a dangling-symlink temp"; fi
rm -f "$hb/.slack-board.pending.fm-x.AAAAAA"
# board temp: a directory refuses
mkdir "$hb/.slack-board.meta.fm-x.AAAAAA"; chmod 700 "$hb/.slack-board.meta.fm-x.AAAAAA"
if fms_board_dir_inventory_assert "$hb" board 2>/dev/null; then fail "board inventory must refuse a directory temp"; fi
rmdir "$hb/.slack-board.meta.fm-x.AAAAAA"
# board temp: a wrong-mode (644) file refuses
printf 'partial' > "$hb/.slack-board.state.fm-x.AAAAAA"; chmod 644 "$hb/.slack-board.state.fm-x.AAAAAA"
if fms_board_dir_inventory_assert "$hb" board 2>/dev/null; then fail "board inventory must refuse a wrong-mode temp"; fi
rm -f "$hb/.slack-board.state.fm-x.AAAAAA"
# snapshot temp: dangling symlink refuses
ln -s missing "$hs/.2026-09-01.fm-x.AAAAAA"
if fms_board_dir_inventory_assert "$hs" snapshots 2>/dev/null; then fail "snapshot inventory must refuse a dangling-symlink temp"; fi
rm -f "$hs/.2026-09-01.fm-x.AAAAAA"
# snapshot temp: a directory refuses
mkdir "$hs/.2026-09-02.fm-x.AAAAAA"; chmod 700 "$hs/.2026-09-02.fm-x.AAAAAA"
if fms_board_dir_inventory_assert "$hs" snapshots 2>/dev/null; then fail "snapshot inventory must refuse a directory temp"; fi
rmdir "$hs/.2026-09-02.fm-x.AAAAAA"
# snapshot temp: a wrong-mode (644) file refuses
printf 'partial' > "$hs/.2026-09-04.fm-x.AAAAAA"; chmod 644 "$hs/.2026-09-04.fm-x.AAAAAA"
if fms_board_dir_inventory_assert "$hs" snapshots 2>/dev/null; then fail "snapshot inventory must refuse a wrong-mode temp"; fi
rm -f "$hs/.2026-09-04.fm-x.AAAAAA"
# snapshot temp: a FIFO refuses
mkfifo "$hs/.2026-09-05.fm-x.AAAAAA"
if fms_board_dir_inventory_assert "$hs" snapshots 2>/dev/null; then fail "snapshot inventory must refuse a FIFO temp"; fi
rm -f "$hs/.2026-09-05.fm-x.AAAAAA"
# snapshot temp: a hard link (nlink > 1) refuses
printf 'partial' > "$hs/.2026-09-06.fm-x.AAAAAA"; chmod 600 "$hs/.2026-09-06.fm-x.AAAAAA"
ln "$hs/.2026-09-06.fm-x.AAAAAA" "$hs/.2026-09-06.fm-x.BBBBBB"
if fms_board_dir_inventory_assert "$hs" snapshots 2>/dev/null; then fail "snapshot inventory must refuse a hard-link temp"; fi
rm -f "$hs/.2026-09-06.fm-x.AAAAAA" "$hs/.2026-09-06.fm-x.BBBBBB"
pass "inventory temp entries must satisfy the publisher filesystem invariants"
rm -rf "$home"

home="$TMP_ROOT/board-initial-recovery-channel"
make_home "$home"
mkdir "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf '%s\n' '{"phase":"initial-posted","date":"2026-08-27","body":"initialbody","today":"2026-08-27","new_body":"initialbody","live_ts":"1786735224.690829","snapshot_ts":"","channel":"C0BQ9K1TJ99"}' \
  > "$home/state/slack-board/slack-board.pending"
chmod 600 "$home/state/slack-board/slack-board.pending"
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
[ ! -e "$home/state/slack-board/slack-board.meta" ] \
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
printf 'channel=C0BQ9K1TJ99\nts=1786735224.690829\n' \
  | fmx_private_artifact_publish_stdin "$home/state/slack-board" "slack-board.meta" 600 \
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
  | fmx_private_artifact_publish_stdin "$home/state/slack-board" "slack-board.meta" 600 \
  || fail "invalid-meta setup must publish malformed board metadata"
if run_post "$home" "$fakebin" board "board v2" >/dev/null 2>"$home/board.err"; then
  fail "malformed board metadata must refuse the update"
fi
grep -Fq "invalid Slack board identity" "$home/board.err" \
  || fail "malformed board metadata refusal must name the invalid identity: $(cat "$home/board.err")"
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
[ "$(private_mode "$home/state/slack-board")" = 700 ] \
  || fail "board meta directory must be private under a public state parent"
[ "$(private_mode "$home/state/slack-board/slack-board.meta")" = 600 ] \
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
printf '%s\n' '{"date":"2026-08-27","body":' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
if run_post "$home" "$fakebin" board "board v2" >/dev/null 2>"$home/board.err"; then
  fail "malformed board state must refuse the update"
fi
grep -Fq "invalid Slack board daily state" "$home/board.err" \
  || fail "malformed board state refusal must name the invalid state: $(cat "$home/board.err")"
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
[ "$(grep '^ts=' "$home/state/slack-board/slack-board.meta" | cut -d= -f2)" = "$ts" ] \
  || fail "live board meta must keep its original ts through a rollover"
[ "$(jq -r '.date' "$home/state/slack-board/slack-board.state")" = "2026-08-28" ] \
  || fail "board state date must advance to today after rollover"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "todaybody" ] \
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
printf '1786735230.999999\n' \
  | fmx_private_artifact_publish_stdin_once "$home/state/slack-board-snapshots" "2026-08-27" 600 \
  || fail "dedupe once-file seed failed"
ts2=$(run_post "$home" "$fakebin" board "todaybody")
[ "$ts2" = "$ts" ] || fail "a dedupe-skipped rollover must still update the live message"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 1 ] \
  || fail "a pre-existing once-file must prevent a duplicate snapshot post: $(cat "$log")"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 1 ] \
  || fail "a dedupe-skipped rollover must still update the live message once: $(cat "$log")"
[ "$(cat "$home/state/slack-board-snapshots/2026-08-27")" = "1786735230.999999" ] \
  || fail "a pre-existing once-file must not be overwritten"
[ "$(jq -r '.date' "$home/state/slack-board/slack-board.state")" = "2026-08-28" ] \
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
chmod 700 "$home/state/slack-board-snapshots"
# Inject a once-file publish failure without violating the mode-700 store
# invariant: a fake ln that fails only for the snapshot once-file publish
# (a date-shaped destination under slack-board-snapshots), so the store stays
# a valid mode-700 directory and the publish itself fails after preflight.
cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
last="${@: -1}"
base="${last##*/}"
case "$base" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) exit 1 ;;
esac
self="$0"; selfdir=$(dirname "$self")
IFS=: read -ra P <<< "$PATH"
for d in "${P[@]}"; do
  [ "$d" = "$selfdir" ] && continue
  [ -x "$d/ln" ] && exec "$d/ln" "$@"
done
exit 1
SH
chmod +x "$fakebin/ln"
err_out="$home/board.err"
if run_post "$home" "$fakebin" board "todaybody" >"$home/board.out" 2>"$err_out"; then
  fail "a failed snapshot dedupe write must exit non-zero"
fi
rm -f "$fakebin/ln"
grep -Fq "board snapshot posted at" "$err_out" \
  || fail "a failed snapshot dedupe write must name the created snapshot ts: $(cat "$err_out")"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 2 ] \
  || fail "the snapshot must still post once even though its dedupe write failed: $(cat "$log")"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 0 ] \
  || fail "a failed snapshot dedupe write must not advance the live message: $(cat "$log")"
[ "$(jq -r '.date' "$home/state/slack-board/slack-board.state")" = "2026-08-27" ] \
  || fail "a failed snapshot dedupe write must not advance the stored active date"
pass "fm-slack-post board dies naming the snapshot ts when its dedupe write fails, without advancing live state"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

# --- board namespace migration (state/slack-board.meta/ -> state/slack-board/) ---

home="$TMP_ROOT/board-migrate-legacy-same-day"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-migrate-same-day")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
make_legacy_board "$home" "$CHANNEL_ID" "1786735224.690829" "2026-08-27" "prior body"
meta_before=$(cat "$home/state/slack-board.meta/slack-board.meta")
inode_meta_before=$(private_inode "$home/state/slack-board.meta/slack-board.meta")
ts=$(run_post "$home" "$fakebin" board "today body")
[ "$ts" = "1786735224.690829" ] || fail "same-day migration must return the preserved live ts, got $ts"
[ ! -e "$home/state/slack-board.meta" ] || fail "migration must remove the legacy directory from the task namespace"
[ -d "$home/state/slack-board" ] || fail "migration must create the new board directory"
[ "$(cat "$home/state/slack-board/slack-board.meta")" = "$meta_before" ] \
  || fail "migration must preserve the identity bytes"
[ "$(jq -r '.date' "$home/state/slack-board/slack-board.state")" = "2026-08-27" ] \
  || fail "same-day migration must keep the stored date"
[ "$(jq -r '.body' "$home/state/slack-board/slack-board.state")" = "today body" ] \
  || fail "same-day migration must still apply today's body to the state"
[ "$(private_mode "$home/state/slack-board/slack-board.meta")" = 600 ] \
  || fail "migration must preserve the identity file mode"
[ "$(private_inode "$home/state/slack-board/slack-board.meta")" = "$inode_meta_before" ] \
  || fail "migration must preserve the identity file inode"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 1 ] \
  || fail "same-day migration must issue exactly one chat.update with the preserved ts: $(cat "$log")"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 0 ] \
  || fail "same-day migration must not post a replacement live message: $(cat "$log")"
grep -Fq "ts=1786735224.690829" "$log" \
  || fail "same-day migration must update the same live ts: $(cat "$log")"
pass "fm-slack-post board migrates a legacy directory and updates the same live ts with no replacement post"

home="$TMP_ROOT/board-migrate-legacy-rollover"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-migrate-rollover")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
make_legacy_board "$home" "$CHANNEL_ID" "1786735224.690829" "2026-08-27" "closed body"
meta_before=$(cat "$home/state/slack-board.meta/slack-board.meta")
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
export FAKE_SLACK_POST='{"ok":true,"ts":"1786735230.999999","channel":"C0BQ9K1TJKG"}'
ts=$(run_post "$home" "$fakebin" board "today body")
unset FAKE_SLACK_POST
[ "$ts" = "1786735224.690829" ] || fail "rollover migration must keep the original live ts, got $ts"
[ ! -e "$home/state/slack-board.meta" ] || fail "rollover migration must remove the legacy directory"
[ "$(cat "$home/state/slack-board/slack-board.meta")" = "$meta_before" ] \
  || fail "rollover migration must preserve the live identity bytes"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 1 ] \
  || fail "rollover migration must post exactly one archival snapshot: $(cat "$log")"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 1 ] \
  || fail "rollover migration must update the live message exactly once: $(cat "$log")"
if ! grep -Fq "method=chat.update" "$log" || ! grep -Fq "ts=1786735224.690829" "$log"; then
  fail "rollover migration must update the original live ts: $(cat "$log")"
fi
pass "fm-slack-post board migrates a legacy directory through rollover with one snapshot plus one update of the same live ts"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

home="$TMP_ROOT/board-migrate-refuse-both"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-migrate-both")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
make_legacy_board "$home" "$CHANNEL_ID" "1786735224.690829" "2026-08-27" "prior body"
mkdir -p "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=1786735224.690829\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/both.err"; then
  fail "board must refuse when both legacy and new board directories exist"
fi
grep -Fq "ambiguous Slack board state" "$home/both.err" \
  || fail "both-paths refusal must name the ambiguity: $(cat "$home/both.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "both-paths refusal must not call Slack: $(cat "$log")"
[ -e "$home/state/slack-board.meta" ] || fail "both-paths refusal must not delete the legacy directory"
[ -e "$home/state/slack-board" ] || fail "both-paths refusal must not delete the new directory"
pass "fm-slack-post board refuses ambiguous legacy and new board directories without a network call"

home="$TMP_ROOT/board-migrate-refuse-symlink"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-migrate-symlink")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
mkdir -p "$home/state/slack-target"
chmod 700 "$home/state/slack-target"
ln -s "$home/state/slack-target" "$home/state/slack-board.meta"
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/sym.err"; then
  fail "board must refuse a legacy board directory that is a symlink"
fi
grep -Fq "invalid Slack board state directory" "$home/sym.err" \
  || fail "symlink refusal must name the invalid directory: $(cat "$home/sym.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "symlink refusal must not call Slack: $(cat "$log")"
[ -L "$home/state/slack-board.meta" ] || fail "symlink refusal must not delete the symlink"
pass "fm-slack-post board refuses a symlinked legacy board directory without a network call"

home="$TMP_ROOT/board-migrate-refuse-initial-posting"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-migrate-initial-posting")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
mkdir -p "$home/state/slack-board.meta"
chmod 700 "$home/state/slack-board.meta"
printf '{"phase":"initial-posting","date":"2026-08-27","body":"pending","today":"2026-08-27","new_body":"pending","live_ts":"","snapshot_ts":"","channel":"%s"}' "$CHANNEL_ID" \
  > "$home/state/slack-board.meta/slack-board.pending"
chmod 600 "$home/state/slack-board.meta/slack-board.pending"
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/ip.err"; then
  fail "board must refuse a legacy directory with an initial-posting pending journal"
fi
grep -Fq "initial-posting pending has an unknown delivery outcome" "$home/ip.err" \
  || fail "initial-posting refusal must name the unknown outcome: $(cat "$home/ip.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "initial-posting refusal must not call Slack: $(cat "$log")"
[ -e "$home/state/slack-board.meta" ] || fail "initial-posting refusal must not delete the legacy directory"
pass "fm-slack-post board refuses an ambiguous initial-posting legacy journal without a network call"

home="$TMP_ROOT/board-migrate-refuse-malformed-pending"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-migrate-malformed-pending")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
mkdir -p "$home/state/slack-board.meta"
chmod 700 "$home/state/slack-board.meta"
printf 'not-json' > "$home/state/slack-board.meta/slack-board.pending"
chmod 600 "$home/state/slack-board.meta/slack-board.pending"
if run_post "$home" "$fakebin" board "today body" >/dev/null 2>"$home/mp.err"; then
  fail "board must refuse a legacy directory with a malformed pending journal"
fi
grep -Fq "invalid Slack board pending journal" "$home/mp.err" \
  || fail "malformed-pending refusal must name the invalid journal: $(cat "$home/mp.err")"
[ "$(grep -c '^method=' "$log")" -eq 0 ] \
  || fail "malformed-pending refusal must not call Slack: $(cat "$log")"
[ -e "$home/state/slack-board.meta" ] || fail "malformed-pending refusal must not delete the legacy directory"
pass "fm-slack-post board refuses a malformed legacy pending journal without a network call"

home="$TMP_ROOT/board-migrate-already-migrated"
make_home "$home"
fakebin=$(make_fake_curl "$home/fake-migrate-already")
log="$home/curl.log"
: > "$log"
export FM_SLACK_CURL_LOG="$log"
unset FAKE_SLACK_POST FAKE_SLACK_UPDATE
export FAKE_SLACK_CHANNEL=$CHANNEL_ID
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
mkdir -p "$home/state/slack-board"
chmod 700 "$home/state/slack-board"
printf 'channel=%s\nts=1786735224.690829\n' "$CHANNEL_ID" > "$home/state/slack-board/slack-board.meta"
chmod 600 "$home/state/slack-board/slack-board.meta"
printf '{"date":"2026-08-27","body":"prior body"}' > "$home/state/slack-board/slack-board.state"
chmod 600 "$home/state/slack-board/slack-board.state"
ts=$(run_post "$home" "$fakebin" board "today body")
[ "$ts" = "1786735224.690829" ] || fail "an already-migrated home must keep its live ts"
[ ! -e "$home/state/slack-board.meta" ] || fail "an already-migrated home must not recreate the legacy directory"
[ "$(grep -c '^method=chat.update ' "$log")" -eq 1 ] \
  || fail "an already-migrated home must update the live message once: $(cat "$log")"
[ "$(grep -c '^method=chat.postMessage ' "$log")" -eq 0 ] \
  || fail "an already-migrated home must not post a replacement: $(cat "$log")"
pass "fm-slack-post board treats an already-migrated home as idempotent"
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
