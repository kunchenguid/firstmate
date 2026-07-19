#!/usr/bin/env bash
# Behavior tests for Telegram mode Stages 1-2: send, poll, respond, bootstrap
# activation, and threat-model controls.
#
# Telegram mode must be INERT by default (no token -> hard no-op) and additive
# when on. The network is stubbed with a fakebin curl so these stay hermetic:
# no real Telegram token, no network. jq stays the real tool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
# head, date, tr, etc. for status/respond paths
for extra in "$(dirname "$(command -v head)")" "$(dirname "$(command -v date)")" "$(dirname "$(command -v tr)")"; do
  case ":$BASE_PATH:" in
    *":$extra:"*) ;;
    *) BASE_PATH="$extra:$BASE_PATH" ;;
  esac
done
TMP_ROOT=$(fm_test_tmproot fm-telegram-mode-tests)

make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" url="" data="" method=GET
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --data|--data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -H|-m|-w) shift 2 ;;
    --config|-K)
      cfgurl=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$2" 2>/dev/null | head -n1)
      [ -n "$cfgurl" ] && url=$cfgurl
      shift 2
      ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "argv=$argv"; echo "method=$method"; echo "url=$url"; echo "data=$data"; } >> "$FAKE_CURL_LOG"
fi
case "$url" in
  */getUpdates*)
    [ -n "$ofile" ] && printf '%s' "${FAKE_POLL_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_POLL_CODE:-200}"
    ;;
  */sendMessage*)
    [ -n "$ofile" ] && printf '%s' "${FAKE_SEND_BODY:-{\"ok\":true}}" > "$ofile"
    printf '%s' "${FAKE_SEND_CODE:-200}"
    ;;
  *)
    [ -n "$ofile" ] && printf '%s' '' > "$ofile"
    printf '%s' "${FAKE_POLL_CODE:-404}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

write_env() {
  local home=$1
  shift
  {
    printf 'FM_TELEGRAM_BOT_TOKEN=test-bot-token\n'
    printf 'FM_TELEGRAM_CHAT_ID=111\n'
    printf 'FM_TELEGRAM_ALLOW_FROM=222\n'
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$home/.env"
  chmod 600 "$home/.env"
}

now_epoch() {
  date +%s
}

# --- inert / config ---------------------------------------------------------

test_poll_no_token_is_hard_noop() {
  local home out rc
  home="$TMP_ROOT/poll-noop"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-token exit"
  [ -z "$out" ] || fail "poll must be silent without token (got: $out)"
  pass "poll is hard no-op without token"
}

test_send_mode_off_exits_2() {
  local home rc
  home="$TMP_ROOT/send-off"; mkdir -p "$home"
  printf 'hello\n' > "$home/msg.txt"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-send.sh" --text-file "$home/msg.txt" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "send mode-off exit"
  pass "send refuses when mode is off"
}

test_kill_switch_disables_mode() {
  local home fakebin out rc
  home="$TMP_ROOT/kill"; mkdir -p "$home/config" "$home/state"
  write_env "$home"
  printf 'off\n' > "$home/config/telegram-mode"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    "$ROOT/bin/fm-telegram-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll kill-switch exit"
  [ -z "$out" ] || fail "kill switch must silence poll (got: $out)"
  pass "config/telegram-mode off kill switch disables poll"
}

# --- bootstrap --------------------------------------------------------------

test_bootstrap_activates_on_env_tokens() {
  local home out sum1 sum2 n
  home="$TMP_ROOT/boot-on"; mkdir -p "$home"
  write_env "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMT: Telegram mode on" "bootstrap must announce Telegram mode"
  assert_present "$home/state/telegram-watch.check.sh" "bootstrap must drop the check shim"
  [ -x "$home/state/telegram-watch.check.sh" ] || fail "shim must be executable"
  assert_grep "fm-telegram-poll.sh" "$home/state/telegram-watch.check.sh" "shim must exec poll"
  assert_present "$home/config/telegram-mode.env" "bootstrap must drop cadence config"
  assert_grep "export FM_CHECK_INTERVAL=30" "$home/config/telegram-mode.env" "cadence must be 30s"
  sum1=$(cat "$home/state/telegram-watch.check.sh" "$home/config/telegram-mode.env" | shasum)
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/telegram-watch.check.sh" "$home/config/telegram-mode.env" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap Telegram setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'telegram-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the shim (found $n)"
  pass "bootstrap activates Telegram mode from .env tokens, idempotently"
}

test_bootstrap_inert_without_tokens() {
  local home out
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMT:" "bootstrap must say nothing about Telegram without tokens"
  assert_absent "$home/state/telegram-watch.check.sh" "no tokens -> no shim"
  pass "bootstrap is inert without Telegram tokens"
}

test_bootstrap_opt_out_cleanup() {
  local home out
  home="$TMP_ROOT/boot-optout"; mkdir -p "$home/state" "$home/config"
  write_env "$home"
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/telegram-watch.check.sh" "precondition: shim present"
  # Remove tokens.
  printf '\n' > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMT: Telegram mode off" "bootstrap must announce opt-out cleanup"
  assert_absent "$home/state/telegram-watch.check.sh" "opt-out must remove shim"
  assert_absent "$home/config/telegram-mode.env" "opt-out must remove cadence"
  pass "bootstrap removes Telegram artifacts on opt-out"
}

test_bootstrap_kill_switch_cleanup() {
  local home out
  home="$TMP_ROOT/boot-kill"; mkdir -p "$home"
  write_env "$home"
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  mkdir -p "$home/config"
  printf 'off\n' > "$home/config/telegram-mode"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMT: Telegram mode off" "kill switch must disarm"
  assert_absent "$home/state/telegram-watch.check.sh" "kill switch must remove shim"
  pass "bootstrap kill switch removes Telegram artifacts"
}

# --- poll allowlist / offset / 409 ------------------------------------------

sample_update() {
  local uid=$1 from=$2 chat=$3 text=$4 date=${5:-$(now_epoch)} type=${6:-private}
  jq -cn \
    --argjson uid "$uid" \
    --argjson from "$from" \
    --argjson chat "$chat" \
    --arg text "$text" \
    --argjson date "$date" \
    --arg type "$type" \
    '{ok:true,result:[{update_id:$uid,message:{message_id:1,date:$date,text:$text,chat:{id:$chat,type:$type},from:{id:$from}}}]}'
}

# Build a multi-update getUpdates body from lines "uid from chat text [type]".
# Types default to private. Used for rate-cap defer / offset tests.
sample_updates_body() {
  local date msg type uid from chat text first=1 spec rest
  date=$(now_epoch)
  printf '{"ok":true,"result":['
  for spec in "$@"; do
    # Parse without clobbering the outer "$@".
    uid=${spec%% *}
    rest=${spec#"$uid"}
    rest=${rest# }
    from=${rest%% *}
    rest=${rest#"$from"}
    rest=${rest# }
    chat=${rest%% *}
    rest=${rest#"$chat"}
    rest=${rest# }
    text=${rest%% *}
    rest=${rest#"$text"}
    rest=${rest# }
    type=${rest:-private}
    [ -n "$type" ] || type=private
    msg=$(jq -cn \
      --argjson uid "$uid" \
      --argjson from "$from" \
      --argjson chat "$chat" \
      --arg text "$text" \
      --argjson date "$date" \
      --arg type "$type" \
      '{update_id:$uid,message:{message_id:1,date:$date,text:$text,chat:{id:$chat,type:$type},from:{id:$from}}}')
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ','
    fi
    printf '%s' "$msg"
  done
  printf ']}'
}

test_poll_allowlisted_stashes_and_wakes() {
  local home fakebin out rc body log
  home="$TMP_ROOT/poll-ok"; mkdir -p "$home"
  write_env "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  body=$(sample_update 10 222 111 "status")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_CURL_LOG="$log" FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-telegram-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll ok exit"
  assert_contains "$out" "telegram-msg 10" "poll must emit wake"
  assert_present "$home/state/telegram-inbox/10.json" "poll must stash inbox"
  assert_grep "status" "$home/state/telegram-inbox/10.json" "inbox must carry text"
  [ "$(cat "$home/state/telegram-offset")" = "11" ] || fail "offset must advance to update_id+1"
  assert_grep "accepted" "$home/state/telegram-audit.log" "audit must record accepted"
  if grep '^argv=' "$log" | grep -q 'test-bot-token'; then
    fail "bot token must not appear in curl argv"
  fi
  pass "poll stashes allowlisted message and wakes"
}

test_poll_non_allowlisted_dropped_and_audited() {
  local home fakebin out body
  home="$TMP_ROOT/poll-deny"; mkdir -p "$home"
  write_env "$home"
  fakebin=$(make_fake_curl "$home")
  body=$(sample_update 20 999 111 "status")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-telegram-poll.sh")
  [ -z "$out" ] || fail "non-allowlisted must not wake (got: $out)"
  assert_absent "$home/state/telegram-inbox/20.json" "must not stash non-allowlisted"
  assert_grep "dropped-auth" "$home/state/telegram-audit.log" "must audit auth drop"
  [ "$(cat "$home/state/telegram-offset")" = "21" ] || fail "offset still advances for drops"
  pass "poll drops non-allowlisted senders and audits"
}

test_poll_wrong_chat_dropped() {
  local home fakebin out body
  home="$TMP_ROOT/poll-chat"; mkdir -p "$home"
  write_env "$home"
  fakebin=$(make_fake_curl "$home")
  body=$(sample_update 30 222 999 "status")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-telegram-poll.sh")
  [ -z "$out" ] || fail "wrong chat must not wake"
  assert_absent "$home/state/telegram-inbox/30.json" "must not stash wrong chat"
  pass "poll drops non-matching chat id"
}

test_poll_group_chat_dropped() {
  local home fakebin out body
  home="$TMP_ROOT/poll-group"; mkdir -p "$home"
  write_env "$home"
  fakebin=$(make_fake_curl "$home")
  body=$(sample_update 31 222 111 "status" "$(now_epoch)" "group")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-telegram-poll.sh")
  [ -z "$out" ] || fail "group chat must not wake"
  assert_absent "$home/state/telegram-inbox/31.json" "must not stash group"
  pass "poll drops group chats"
}

test_poll_409_surfaces_error_once() {
  local home fakebin out1 out2
  home="$TMP_ROOT/poll-409"; mkdir -p "$home"
  write_env "$home"
  fakebin=$(make_fake_curl "$home")
  out1=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=409 FAKE_POLL_BODY='{"ok":false}' \
    "$ROOT/bin/fm-telegram-poll.sh")
  assert_contains "$out1" "telegram-mode-error" "409 must wake with error"
  assert_contains "$out1" "409" "error must mention 409"
  out2=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=409 FAKE_POLL_BODY='{"ok":false}' \
    "$ROOT/bin/fm-telegram-poll.sh")
  [ -z "$out2" ] || fail "duplicate 409 must be silent (got: $out2)"
  pass "poll 409 conflict surfaces once then dedupes"
}

# Captain decision key=telegram-rate-cap: DEFER, never drop authenticated over-cap.
test_poll_rate_cap_defers_authenticated_offset_holds() {
  local home fakebin body out offset
  home="$TMP_ROOT/poll-defer-offset"; mkdir -p "$home"
  write_env "$home" "FM_TELEGRAM_RATE_MAX=2"
  fakebin=$(make_fake_curl "$home")
  # Three authenticated messages; cap=2 so the third is deferred.
  body=$(sample_updates_body \
    "100 222 111 status" \
    "101 222 111 status" \
    "102 222 111 status")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-telegram-poll.sh")
  assert_contains "$out" "telegram-msg 100" "first under-cap must wake"
  assert_contains "$out" "telegram-msg 101" "second under-cap must wake"
  assert_not_contains "$out" "telegram-msg 102" "over-cap must not wake this sweep"
  assert_present "$home/state/telegram-inbox/100.json" "first stashed"
  assert_present "$home/state/telegram-inbox/101.json" "second stashed"
  assert_absent "$home/state/telegram-inbox/102.json" "deferred must not stash this sweep"
  assert_grep "deferred" "$home/state/telegram-audit.log" "must audit deferred rate-cap"
  offset=$(cat "$home/state/telegram-offset")
  # Confirmed through 101 only -> offset 102, so 102 is re-fetched next sweep.
  [ "$offset" = "102" ] || fail "offset must hold before deferred update (got $offset, want 102)"
  pass "poll rate-cap defers authenticated updates and holds offset"
}

test_poll_rate_cap_deferred_processed_next_sweep() {
  local home fakebin body1 body2 out1 out2 offset
  home="$TMP_ROOT/poll-defer-next"; mkdir -p "$home"
  write_env "$home" "FM_TELEGRAM_RATE_MAX=1"
  fakebin=$(make_fake_curl "$home")
  # Text tokens must be single words (helper splits on spaces).
  body1=$(sample_updates_body "200 222 111 status" "201 222 111 approve-k1")
  out1=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body1" \
    "$ROOT/bin/fm-telegram-poll.sh")
  assert_contains "$out1" "telegram-msg 200" "sweep1 processes first"
  assert_not_contains "$out1" "telegram-msg 201" "sweep1 defers second"
  [ "$(cat "$home/state/telegram-offset")" = "201" ] || fail "sweep1 offset holds at deferred (got $(cat "$home/state/telegram-offset" 2>/dev/null))"
  # Next sweep re-serves the deferred update (offset=201 means id>=201).
  body2=$(sample_updates_body "201 222 111 approve-k1")
  out2=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body2" \
    "$ROOT/bin/fm-telegram-poll.sh")
  assert_contains "$out2" "telegram-msg 201" "sweep2 must process deferred update"
  assert_present "$home/state/telegram-inbox/201.json" "deferred stashed on next sweep"
  offset=$(cat "$home/state/telegram-offset")
  [ "$offset" = "202" ] || fail "sweep2 must advance past processed deferred (got $offset)"
  pass "poll processes deferred authenticated updates on the next sweep"
}

test_poll_deferred_approve_still_subject_to_freshness() {
  local home fakebin body out stale
  home="$TMP_ROOT/poll-defer-fresh"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1" "FM_TELEGRAM_FRESHNESS_SECS=60"
  # Stash a deferred-style approve with a stale message date (as poll would).
  stale=$(( $(now_epoch) - 3600 ))
  seed_inbox "$home" 300 "approve api-shape" "$stale"
  printf 'needs-decision [key=api-shape]: which shape?\n' > "$home/state/ship-1.status"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "refused 300 stale" "deferred approval still enforces freshness"
  pass "deferred approvals remain subject to freshness window"
}

test_poll_auth_rejects_cannot_pin_offset() {
  local home fakebin body out offset
  home="$TMP_ROOT/poll-auth-pin"; mkdir -p "$home"
  write_env "$home" "FM_TELEGRAM_RATE_MAX=1"
  fakebin=$(make_fake_curl "$home")
  # Flood of unauthenticated updates after one accept: auth drops advance offset.
  body=$(sample_updates_body \
    "400 222 111 status" \
    "401 999 111 status" \
    "402 999 111 status" \
    "403 999 111 status")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-telegram-poll.sh")
  assert_contains "$out" "telegram-msg 400" "authenticated accept wakes"
  assert_not_contains "$out" "telegram-msg 401" "auth reject must not wake"
  offset=$(cat "$home/state/telegram-offset")
  # All four resolved: one accept + three auth drops -> offset 404.
  [ "$offset" = "404" ] || fail "auth rejects must advance offset (got $offset, want 404)"
  assert_grep "dropped-auth" "$home/state/telegram-audit.log" "auth drops audited"
  pass "unauthenticated rejects cannot pin the getUpdates offset"
}

test_poll_409_resurfaces_after_healthy_poll() {
  local home fakebin out1 out2 out3
  home="$TMP_ROOT/poll-409-recover"; mkdir -p "$home"
  write_env "$home"
  fakebin=$(make_fake_curl "$home")
  out1=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=409 FAKE_POLL_BODY='{"ok":false}' \
    "$ROOT/bin/fm-telegram-poll.sh")
  assert_contains "$out1" "telegram-mode-error" "first 409 must surface"
  out2=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY='{"ok":true,"result":[]}' \
    "$ROOT/bin/fm-telegram-poll.sh")
  [ -z "$out2" ] || fail "healthy empty poll must stay silent (got: $out2)"
  assert_absent "$home/state/telegram-poll.error" "healthy poll must clear the error marker"
  out3=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=409 FAKE_POLL_BODY='{"ok":false}' \
    "$ROOT/bin/fm-telegram-poll.sh")
  assert_contains "$out3" "telegram-mode-error" "new 409 after recovery must surface again"
  pass "poll clears error marker on healthy 200 so a new 409 surfaces"
}

# --- send / secrets / afk / audit -------------------------------------------

test_send_dry_run_no_network() {
  local home out rc
  home="$TMP_ROOT/send-dry"; mkdir -p "$home"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  touch "$home/state/.afk" 2>/dev/null || mkdir -p "$home/state" && touch "$home/state/.afk"
  printf 'PR ready https://github.com/acme/app/pull/42\n' > "$home/msg.txt"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-send.sh" --text-file "$home/msg.txt" 2>&1); rc=$?
  expect_code 0 "$rc" "dry-run send exit"
  assert_contains "$out" "DRY RUN" "must print dry-run marker"
  n=$(find "$home/state/telegram-outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 1 ] || fail "dry-run must write outbox"
  assert_grep "https://github.com/acme/app/pull/42" "$home/state/telegram-notified-prs.log" \
    "dry-run must still record notified PR URLs"
  pass "send dry-run records outbox and PR registry without network"
}

test_send_refuses_secretish() {
  local home rc
  home="$TMP_ROOT/send-secret"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  touch "$home/state/.afk"
  printf 'password: supersecretvalue99\n' > "$home/msg.txt"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-send.sh" --text-file "$home/msg.txt" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "secretish refuse exit"
  assert_grep "secretish" "$home/state/telegram-audit.log" "must audit secretish refuse"
  pass "send refuses secret-looking text"
}

test_send_skips_when_not_afk() {
  local home fakebin log
  home="$TMP_ROOT/send-afk"; mkdir -p "$home/state"
  write_env "$home"
  # No .afk file.
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'hello captain\n' > "$home/msg.txt"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-telegram-send.sh" --text-file "$home/msg.txt" >/dev/null 2>&1
  [ ! -f "$log" ] || [ ! -s "$log" ] || fail "must not call curl when not AFK"
  assert_grep "not-afk" "$home/state/telegram-audit.log" "must audit not-afk skip"
  pass "send skips routine outbound when not AFK"
}

test_send_reply_bypasses_afk_gate() {
  local home fakebin log
  home="$TMP_ROOT/send-reply"; mkdir -p "$home/state"
  write_env "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'ack\n' > "$home/msg.txt"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_CURL_LOG="$log" FAKE_SEND_CODE=200 FAKE_SEND_BODY='{"ok":true}' \
    "$ROOT/bin/fm-telegram-send.sh" --text-file "$home/msg.txt" --reply >/dev/null 2>&1
  assert_grep "sendMessage" "$log" "reply must post even without AFK"
  if grep '^argv=' "$log" | grep -q 'test-bot-token'; then
    fail "bot token must not appear in curl argv"
  fi
  pass "send --reply bypasses AFK-only gate"
}

test_send_truncates_long_utf8_safely() {
  local home rc file len
  home="$TMP_ROOT/send-trunc"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  touch "$home/state/.afk"
  jq -rn '"é" * 5000' > "$home/msg.txt"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-send.sh" --text-file "$home/msg.txt" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "truncated dry-run send exit"
  file=$(find "$home/state/telegram-outbox" -name '*.json' 2>/dev/null | head -n1)
  [ -n "$file" ] || fail "truncated dry-run must write outbox"
  len=$(jq -r '.text | length' "$file")
  [ "$len" = "4096" ] || fail "truncated text must be 4096 chars (got $len)"
  jq -e '.text | contains("�") | not' "$file" >/dev/null \
    || fail "truncation must not split a multibyte character"
  jq -e '.text | endswith("é...")' "$file" >/dev/null \
    || fail "truncated text must keep whole characters before the ellipsis"
  pass "send truncates long multibyte text on character boundaries"
}

# --- respond grammar / freshness / authority --------------------------------

seed_inbox() {
  local home=$1 uid=$2 text=$3 date=${4:-$(now_epoch)}
  mkdir -p "$home/state"
  chmod 700 "$home/state" 2>/dev/null || true
  (umask 077; mkdir -p "$home/state/telegram-inbox")
  chmod 700 "$home/state/telegram-inbox"
  jq -cn \
    --argjson uid "$uid" \
    --arg text "$text" \
    --argjson date "$date" \
    '{update_id:$uid,text:$text,from_id:"222",chat_id:"111",date:$date,raw:{}}' \
    > "$home/state/telegram-inbox/$uid.json"
  chmod 600 "$home/state/telegram-inbox/$uid.json"
}

test_respond_status() {
  local home fakebin out
  home="$TMP_ROOT/resp-status"; mkdir -p "$home/state" "$home/data"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  seed_inbox "$home" 40 "status"
  printf '## In flight\n- something\n' > "$home/data/backlog.md"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "ok 40 status" "status must succeed"
  assert_absent "$home/state/telegram-inbox/40.json" "inbox must clear"
  pass "respond status replies and clears inbox"
}

test_respond_closed_scope_refuses_free_text() {
  local home out
  home="$TMP_ROOT/resp-scope"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  seed_inbox "$home" 41 "please rewrite the auth module carefully"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "refused 41 scope" "free text must be refused"
  assert_grep "refused-scope" "$home/state/telegram-audit.log" "must audit scope refuse"
  assert_absent "$home/state/telegram-inbox/41.json" "inbox must clear after refuse"
  pass "respond refuses free-text (Stage 3 not authorized)"
}

test_respond_stale_approve_refused() {
  local home out stale
  home="$TMP_ROOT/resp-stale"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1" "FM_TELEGRAM_FRESHNESS_SECS=60"
  stale=$(( $(now_epoch) - 3600 ))
  seed_inbox "$home" 42 "approve deploy-key" "$stale"
  printf 'needs-decision [key=deploy-key]: rotate deploy key?\n' > "$home/state/task-a.status"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "refused 42 stale" "stale approve must refuse"
  assert_grep "dropped-stale" "$home/state/telegram-audit.log" "must audit stale"
  pass "respond refuses stale approval commands"
}

test_respond_approve_open_key() {
  local home out
  home="$TMP_ROOT/resp-approve"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  seed_inbox "$home" 43 "approve api-shape"
  printf 'needs-decision [key=api-shape]: which shape?\n' > "$home/state/ship-1.status"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "ok 43 approve api-shape ship-1" "approve must succeed"
  assert_present "$home/state/telegram-actions/43.json" "must write action record"
  assert_grep '"action":"approve"' "$home/state/telegram-actions/43.json" "action is approve"
  pass "respond approve records action for open key"
}

test_respond_action_write_failure_reports_error() {
  local home out
  home="$TMP_ROOT/resp-action-fail"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  seed_inbox "$home" 46 "approve api-shape"
  printf 'needs-decision [key=api-shape]: which shape?\n' > "$home/state/ship-1.status"
  # Occupy the actions dir path with a plain file so the durable write fails.
  touch "$home/state/telegram-actions"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "error 46 action-write-failed" "failed action write must report error"
  assert_present "$home/state/telegram-inbox/46.json" "inbox must stay queued for retry"
  assert_grep "action-write-failed" "$home/state/telegram-audit.log" "must audit action write failure"
  pass "respond reports error and keeps inbox when action write fails"
}

test_respond_approve_unknown_key_refused() {
  local home out
  home="$TMP_ROOT/resp-unknown-key"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  seed_inbox "$home" 44 "approve no-such-key"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "refused 44 unknown-key" "unknown key must refuse"
  pass "respond refuse unknown decision key"
}

test_respond_desk_only_decision_refused() {
  local home out
  home="$TMP_ROOT/resp-desk"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  seed_inbox "$home" 45 "approve rotate-creds"
  printf 'needs-decision [key=rotate-creds]: credential rotation for prod secrets\n' \
    > "$home/state/sec.status"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "refused 45 desk-only" "credential decision must be desk-only"
  pass "respond refuses security-sensitive decisions as desk-only"
}

test_respond_merge_requires_notified_and_green() {
  local home out hook
  home="$TMP_ROOT/resp-merge"; mkdir -p "$home/state"
  chmod 700 "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  pr='https://github.com/acme/app/pull/99'
  # Not previously notified.
  seed_inbox "$home" 50 "merge $pr"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "refused 50 unknown-pr" "unknown PR must refuse"

  # Notified but not green - use the same registry helper production uses.
  # shellcheck source=bin/fm-telegram-lib.sh
  . "$ROOT/bin/fm-telegram-lib.sh"
  FM_HOME="$home" fmt_load_config
  FM_HOME="$home" fmt_notified_pr_record "$pr" || fail "could not record notified PR"
  assert_grep "$pr" "$home/state/telegram-notified-prs.log" "precondition: PR registered"
  seed_inbox "$home" 51 "merge $pr"
  hook="$home/pr-check-red"
  cat > "$hook" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$hook"
  out=$(FM_HOME="$home" FM_TELEGRAM_PR_CHECK_HOOK="$hook" \
    "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "refused 51 not-green" "red PR must refuse"

  # Notified and green.
  seed_inbox "$home" 52 "merge $pr"
  cat > "$hook" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$hook"
  out=$(FM_HOME="$home" FM_TELEGRAM_PR_CHECK_HOOK="$hook" \
    "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "ok 52 merge $pr" "green notified PR must authorize"
  assert_present "$home/state/telegram-actions/52.json" "must write merge action"
  pass "respond merge requires notified URL and green status"
}

test_respond_merge_unnamed_refused() {
  local home out
  home="$TMP_ROOT/resp-merge-unnamed"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  seed_inbox "$home" 53 "merge 99"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "refused 53 scope" "unnamed PR number must refuse"
  pass "respond refuses unnamed merge target"
}

test_respond_dedupe() {
  local home out1 out2
  home="$TMP_ROOT/resp-dedupe"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  seed_inbox "$home" 60 "status"
  out1=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out1" "ok 60 status" "first status ok"
  seed_inbox "$home" 61 "status"
  out2=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out2" "refused 61 deduped" "second identical status deduped"
  pass "respond dedupes identical commands"
}

test_respond_rate_limit() {
  local home out
  home="$TMP_ROOT/resp-rate"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1" "FM_TELEGRAM_RATE_MAX=2" "FM_TELEGRAM_RATE_WINDOW_SECS=3600" \
    "FM_TELEGRAM_DEDUPE_WINDOW_SECS=1"
  # Distinct commands to avoid dedupe.
  seed_inbox "$home" 70 "status"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" >/dev/null 2>&1
  sleep 1
  seed_inbox "$home" 71 "approve k1"
  printf 'needs-decision [key=k1]: q\n' > "$home/state/t.status"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" >/dev/null 2>&1
  sleep 1
  seed_inbox "$home" 72 "approve k2"
  printf 'needs-decision [key=k2]: q\n' >> "$home/state/t.status"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" 2>/dev/null)
  assert_contains "$out" "rate-limited" "third command in window must rate-limit"
  pass "respond rate-limits inbound commands"
}

test_audit_covers_inbound_and_outbound() {
  local home fakebin body
  home="$TMP_ROOT/audit"; mkdir -p "$home/state"
  write_env "$home" "FM_TELEGRAM_DRY_RUN=1"
  touch "$home/state/.afk"
  fakebin=$(make_fake_curl "$home")
  body=$(sample_update 80 222 111 "status")
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_TELEGRAM_API_URL="https://api.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-telegram-poll.sh" >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-telegram-respond.sh" >/dev/null 2>&1
  printf 'hello\n' > "$home/msg.txt"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-send.sh" --text-file "$home/msg.txt" --reply >/dev/null 2>&1
  assert_grep $'inbound\taccepted' "$home/state/telegram-audit.log" "audit inbound"
  assert_grep $'respond\tok' "$home/state/telegram-audit.log" "audit respond"
  assert_grep $'outbound\t' "$home/state/telegram-audit.log" "audit outbound"
  # Token must never appear in the audit log.
  assert_no_grep "test-bot-token" "$home/state/telegram-audit.log" "token redacted from audit"
  # Line-oriented log: every record is newline-terminated (wc -l counts them).
  [ "$(wc -l < "$home/state/telegram-audit.log" | tr -d '[:space:]')" -ge 3 ] \
    || fail "audit records must each end with a newline"
  pass "audit log covers inbound, respond, outbound without secrets"
}

test_lib_parse_command_closed_grammar() {
  # shellcheck source=bin/fm-telegram-lib.sh
  . "$ROOT/bin/fm-telegram-lib.sh"
  local out
  out=$(fmt_parse_command "status") || fail "status parse"
  [ "$out" = "status" ] || fail "status verb"
  out=$(fmt_parse_command "approve my-key") || fail "approve parse"
  [ "$out" = $'approve\tmy-key' ] || fail "approve args ($out)"
  out=$(fmt_parse_command "deny my-key bad idea") || fail "deny parse"
  [ "$out" = $'deny\tmy-key\tbad idea' ] || fail "deny args ($out)"
  out=$(fmt_parse_command "merge https://github.com/a/b/pull/1") || fail "merge parse"
  [ "$out" = $'merge\thttps://github.com/a/b/pull/1' ] || fail "merge args ($out)"
  if out=$(fmt_parse_command "do something freeform"); then
    fail "freeform must fail parse"
  fi
  pass "lib closed command grammar parses and refuses freeform"
}

# --- run --------------------------------------------------------------------

test_poll_no_token_is_hard_noop
test_send_mode_off_exits_2
test_kill_switch_disables_mode
test_bootstrap_activates_on_env_tokens
test_bootstrap_inert_without_tokens
test_bootstrap_opt_out_cleanup
test_bootstrap_kill_switch_cleanup
test_poll_allowlisted_stashes_and_wakes
test_poll_non_allowlisted_dropped_and_audited
test_poll_wrong_chat_dropped
test_poll_group_chat_dropped
test_poll_409_surfaces_error_once
test_poll_409_resurfaces_after_healthy_poll
test_poll_rate_cap_defers_authenticated_offset_holds
test_poll_rate_cap_deferred_processed_next_sweep
test_poll_deferred_approve_still_subject_to_freshness
test_poll_auth_rejects_cannot_pin_offset
test_send_dry_run_no_network
test_send_refuses_secretish
test_send_skips_when_not_afk
test_send_reply_bypasses_afk_gate
test_send_truncates_long_utf8_safely
test_respond_status
test_respond_closed_scope_refuses_free_text
test_respond_stale_approve_refused
test_respond_approve_open_key
test_respond_action_write_failure_reports_error
test_respond_approve_unknown_key_refused
test_respond_desk_only_decision_refused
test_respond_merge_requires_notified_and_green
test_respond_merge_unnamed_refused
test_respond_dedupe
test_respond_rate_limit
test_audit_covers_inbound_and_outbound
test_lib_parse_command_closed_grammar

printf 'All Telegram mode tests passed.\n'
