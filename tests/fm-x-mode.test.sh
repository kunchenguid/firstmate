#!/usr/bin/env bash
# Behavior tests for X mode: the relay poll client (fm-x-poll.sh), the answer
# poster (fm-x-reply.sh), and bootstrap's .env-presence activation.
#
# X mode must be INERT by default (no token -> the poll is a hard no-op and
# bootstrap writes/prints nothing) and additive when on (a check shim + a 30s
# cadence config, both idempotent). The network is stubbed with a fakebin `curl`
# so these stay hermetic: no ports, no server, deterministic in CI. jq stays the
# real tool. End-to-end verification against a real HTTP relay is done out of
# band; this suite pins the client logic and the activation contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# The client under test uses the real jq; make it resolvable regardless of where
# it is installed (Homebrew, Nix profile bins, etc.), which the bare BASE_PATH may
# not include. Prepended after the fakebin so the fake curl still wins.
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-x-mode-tests)

# A fakebin `curl` that mimics the relay: it reads its behavior from env
# (FAKE_POLL_CODE/FAKE_POLL_BODY/FAKE_ANSWER_CODE), records each call to
# FAKE_CURL_LOG, writes the poll body to the script's -o file, and prints the
# HTTP code to stdout exactly as the real `-w '%{http_code}'` would.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET data="" url="" auth=""
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --data) data=$2; shift 2 ;;
    -H)
      case "$2" in
        @*) while IFS= read -r header; do case "$header" in Authorization:*) auth=$header ;; esac; done < "${2#@}" ;;
        Authorization:*) auth=$2 ;;
      esac
      shift 2
      ;;
    -m|-w) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "argv=$argv"; echo "method=$method"; echo "url=$url"; echo "auth=$auth"; echo "data=$data"; } >> "$FAKE_CURL_LOG"
fi
case "$url" in
  */connector/poll)
    [ -n "$ofile" ] && printf '%s' "${FAKE_POLL_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_POLL_CODE:-204}"
    ;;
  */connector/answer)
    printf '%s' "${FAKE_ANSWER_CODE:-200}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# ---------------------------------------------------------------------------

test_poll_no_token_is_hard_noop() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-noop"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  # No .env, no FMX_PAIRING_TOKEN: must exit 0 with no output and touch nothing.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_PAIRING_TOKEN='' \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-token exit"
  [ -z "$out" ] || fail "poll no-token must be silent (got: $out)"
  assert_absent "$home/state/x-inbox" "poll no-token must not create an inbox"
  pass "fm-x-poll is a hard no-op without a token (inert default)"
}

test_poll_empty_env_token_overrides_env_file() {
  local home fakebin log out rc
  home="$TMP_ROOT/poll-empty-env-token"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-dotenv\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_PAIRING_TOKEN='' \
    FAKE_CURL_LOG="$log" FAKE_POLL_CODE=204 \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll empty-env-token exit"
  [ -z "$out" ] || fail "empty env token must disable X mode despite .env token (got: $out)"
  [ ! -f "$log" ] || fail "empty env token must not call the relay"
  assert_absent "$home/state/x-inbox" "empty env token must not create an inbox"
  pass "fm-x-poll treats an explicitly empty env token as configured"
}

test_poll_204_is_silent() {
  local home fakebin log out rc
  home="$TMP_ROOT/poll-204"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-204\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_POLL_CODE=204 \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll 204 exit"
  [ -z "$out" ] || fail "poll 204 must be silent (got: $out)"
  assert_grep "auth=Authorization: Bearer tok-204" "$log" "poll must send the bearer token"
  grep '^argv=' "$log" | grep -F 'tok-204' >/dev/null 2>&1 \
    && fail "poll must not expose the bearer token in curl argv"
  assert_grep "url=https://relay.test/connector/poll" "$log" "poll must hit /connector/poll"
  ls "$home/state/x-inbox/"*.json >/dev/null 2>&1 && fail "poll 204 must not stash an inbox file"
  pass "fm-x-poll stays silent on HTTP 204 (the common case)"
}

test_poll_empty_env_relay_overrides_env_file() {
  local home fakebin log out rc
  home="$TMP_ROOT/poll-empty-env-relay"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-relay\nFMX_RELAY_URL=https://dotenv-relay.test/\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL='' \
    FAKE_CURL_LOG="$log" FAKE_POLL_CODE=204 \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll empty-env-relay exit"
  [ -z "$out" ] || fail "poll 204 with empty env relay must be silent (got: $out)"
  assert_grep "url=https://myfirstmate.io/connector/poll" "$log" \
    "empty env relay must override .env and fall back to the default relay"
  pass "fm-x-poll lets an explicitly empty relay env override .env"
}

test_poll_auth_error_reports_once() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-auth"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-auth\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=401 \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll auth error exit"
  [ "$out" = "x-mode-error relay returned HTTP 401" ] \
    || fail "poll auth error must emit one visible diagnostic (got: $out)"
  assert_present "$home/state/x-poll.error" "poll auth error must write a dedupe marker"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=401 \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll repeated auth error exit"
  [ -z "$out" ] || fail "repeated poll auth error must be quiet after the first diagnostic (got: $out)"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=204 \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll recovered auth error exit"
  [ -z "$out" ] || fail "poll recovery 204 must stay silent (got: $out)"
  assert_absent "$home/state/x-poll.error" "poll 204 must clear the auth diagnostic marker"
  pass "fm-x-poll surfaces auth/config errors once and clears on recovery"
}

test_poll_question_stashes_and_marks() {
  local home fakebin out rc body
  home="$TMP_ROOT/poll-q"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-q\n' > "$home/.env"
  body='{"request_id":"req-7","tweet_id":"555","author_id":"42","text":"what are you building?"}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll question exit"
  [ "$out" = "x-mention req-7" ] || fail "poll must print compact marker (got: $out)"
  assert_present "$home/state/x-inbox/req-7.json" "poll must stash the question"
  [ "$(jq -r .text "$home/state/x-inbox/req-7.json")" = "what are you building?" ] \
    || fail "stashed inbox must preserve the question text"
  [ "$(jq -r .tweet_id "$home/state/x-inbox/req-7.json")" = "555" ] \
    || fail "stashed inbox must preserve the full object"
  pass "fm-x-poll stashes the question and prints the compact marker"
}

test_poll_preserves_conversation_context() {
  local home fakebin out rc body f
  home="$TMP_ROOT/poll-ctx"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-c\n' > "$home/.env"
  # A follow-up reply: the relay includes in_reply_to with the parent tweet.
  body='{"request_id":"req-c","tweet_id":"9","author_id":"42","text":"and then what?","in_reply_to":{"author_handle":"@asker","text":"are you shipping today?"}}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll conversation exit"
  [ "$out" = "x-mention req-c" ] || fail "poll must mark the follow-up mention (got: $out)"
  f="$home/state/x-inbox/req-c.json"
  assert_present "$f" "poll must stash the follow-up"
  [ "$(jq -r '.in_reply_to.author_handle' "$f")" = "@asker" ] \
    || fail "inbox must preserve in_reply_to.author_handle for continuity"
  [ "$(jq -r '.in_reply_to.text' "$f")" = "are you shipping today?" ] \
    || fail "inbox must preserve in_reply_to.text for continuity"
  # A fresh, standalone mention: in_reply_to is null and round-trips as null.
  home="$TMP_ROOT/poll-ctx-fresh"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-c\n' > "$home/.env"
  body='{"request_id":"req-f","tweet_id":"10","author_id":"42","text":"what are you up to?","in_reply_to":null}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll fresh-mention exit"
  [ "$(jq -r '.in_reply_to' "$home/state/x-inbox/req-f.json")" = "null" ] \
    || fail "a fresh mention must round-trip in_reply_to as null"
  pass "fm-x-poll preserves in_reply_to conversation context in the inbox"
}

test_poll_inbox_commit_failure_reports_error() {
  local home fakebin out rc body
  home="$TMP_ROOT/poll-mv-fail"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/mv"
  printf 'FMX_PAIRING_TOKEN=tok-q\n' > "$home/.env"
  body='{"request_id":"req-rename","tweet_id":"555","author_id":"42","text":"what are you building?"}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll inbox commit failure exit"
  [ "$out" = "x-mode-error cannot write inbox" ] \
    || fail "poll inbox commit failure must emit an error, not a wake marker (got: $out)"
  assert_absent "$home/state/x-inbox/req-rename.json" "poll must not report a committed inbox file that was not created"
  assert_absent "$home/state/x-inbox/req-rename.json.tmp" "poll must clean up the failed inbox temp file"
  assert_present "$home/state/x-poll.error" "poll inbox commit failure must write a dedupe marker"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll repeated inbox commit failure exit"
  [ -z "$out" ] || fail "repeated poll inbox commit failure must be quiet after the first diagnostic (got: $out)"
  rm -f "$fakebin/mv"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll recovered inbox commit failure exit"
  [ "$out" = "x-mention req-rename" ] \
    || fail "poll must emit the mention marker once the inbox write succeeds (got: $out)"
  assert_absent "$home/state/x-poll.error" "successful inbox write must clear the diagnostic marker"
  pass "fm-x-poll reports inbox commit failures without emitting a mention wake"
}

test_poll_rejects_unsafe_request_id() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-evil"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-e\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY='{"request_id":"../../etc/x","text":"hi"}' \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll unsafe id exit"
  [ -z "$out" ] || fail "poll must not emit a marker for an unsafe request_id (got: $out)"
  assert_absent "$home/state/x-inbox/../../etc/x.json" "poll must not write outside the inbox"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY='{"request_id":".hidden","text":"hi"}' \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll hidden id exit"
  [ -z "$out" ] || fail "poll must not emit a marker for a hidden request_id (got: $out)"
  assert_absent "$home/state/x-inbox/.hidden.json" "poll must not stash a hidden inbox file"
  pass "fm-x-poll rejects an unsafe request_id (path-traversal guard)"
}

test_reply_success_posts_request_bound_only() {
  local home fakebin log out rc keys
  home="$TMP_ROOT/reply-ok"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-r\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_ANSWER_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-7" "Aye, charting a couple of fixes."); rc=$?
  expect_code 0 "$rc" "reply success exit"
  [ "$out" = "req-7" ] || fail "reply must echo only the request_id (got: $out)"
  assert_grep "url=https://relay.test/connector/answer" "$log" "reply must POST /connector/answer"
  assert_grep "method=POST" "$log" "reply must use POST"
  assert_grep "auth=Authorization: Bearer tok-r" "$log" "reply must send the bearer token"
  grep '^argv=' "$log" | grep -F 'tok-r' >/dev/null 2>&1 \
    && fail "reply must not expose the bearer token in curl argv"
  # The body must be exactly {request_id, text} - never a tweet id.
  local data
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r .request_id)" = "req-7" ] || fail "reply body request_id"
  [ "$(printf '%s' "$data" | jq -r .text)" = "Aye, charting a couple of fixes." ] || fail "reply body text"
  keys=$(printf '%s' "$data" | jq -r 'keys|join(",")')
  [ "$keys" = "request_id,text" ] || fail "reply body must carry only request_id,text (got: $keys)"
  pass "fm-x-reply posts a request-bound answer and echoes only the request_id"
}

test_reply_non_2xx_fails() {
  local home fakebin out rc err
  home="$TMP_ROOT/reply-500"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  printf 'FMX_PAIRING_TOKEN=tok-r\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_ANSWER_CODE=500 \
    "$ROOT/bin/fm-x-reply.sh" "req-7" "hi" 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "reply must exit non-zero on a non-2xx response"
  assert_grep "HTTP 500" "$err" "reply must report the failing status"
  pass "fm-x-reply exits non-zero on a non-2xx relay response"
}

test_reply_usage_error() {
  local home rc
  home="$TMP_ROOT/reply-usage"; mkdir -p "$home"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-reply.sh" "only-one" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "reply usage error exit"
  pass "fm-x-reply rejects missing arguments with a usage error"
}

test_reply_whitespace_text_rejected() {
  local home out rc err
  home="$TMP_ROOT/reply-whitespace"; mkdir -p "$home"
  err="$home/err.txt"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" "req-space" "   " 2>"$err"); rc=$?
  expect_code 2 "$rc" "reply whitespace text exit"
  [ -z "$out" ] || fail "whitespace-only reply must not echo the request_id (got: $out)"
  assert_grep "empty reply text" "$err" "reply must reject whitespace-only text"
  assert_absent "$home/state/x-outbox/req-space.json" "whitespace-only dry-run must not record an outbox preview"
  pass "fm-x-reply rejects whitespace-only reply text"
}

test_bootstrap_activates_on_env_token() {
  local home out sum1 sum2 n
  home="$TMP_ROOT/boot-on"; mkdir -p "$home"
  printf 'FMX_PAIRING_TOKEN=tok-boot\n' > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMX: X mode on" "bootstrap must announce X mode"
  assert_present "$home/state/x-watch.check.sh" "bootstrap must drop the check shim"
  [ -x "$home/state/x-watch.check.sh" ] || fail "the check shim must be executable"
  assert_grep "fm-x-poll.sh" "$home/state/x-watch.check.sh" "the shim must exec the poll script"
  assert_present "$home/config/x-mode.env" "bootstrap must drop the cadence config"
  assert_grep "export FM_CHECK_INTERVAL=30" "$home/config/x-mode.env" "cadence must be 30s"
  # Cadence inheritance: sourcing the config exports the 30s interval to a child,
  # exactly how fm-watch-arm.sh's forked watcher inherits it.
  local inherited
  # shellcheck source=/dev/null
  inherited=$( . "$home/config/x-mode.env" && bash -c 'echo "${FM_CHECK_INTERVAL:-300}"' )
  [ "$inherited" = "30" ] \
    || fail "sourcing the cadence config must export FM_CHECK_INTERVAL=30 to a child"
  # Idempotent: re-running changes nothing and does not duplicate the shim.
  sum1=$(cat "$home/state/x-watch.check.sh" "$home/config/x-mode.env" | shasum)
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/x-watch.check.sh" "$home/config/x-mode.env" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap X-mode setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'x-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the shim (found $n)"
  pass "bootstrap activates X mode from an .env token, idempotently"
}

test_bootstrap_reports_missing_x_dependency() {
  local home fakebin out tool tool_path
  home="$TMP_ROOT/boot-missing-x"; mkdir -p "$home"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux node no-mistakes gh-axi chrome-devtools-axi lavish-axi curl
  for tool in dirname grep tail; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf 'FMX_PAIRING_TOKEN=tok-missing\n' > "$home/.env"
  out=$(PATH="$fakebin" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$BASH" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "MISSING: jq" "bootstrap must report missing jq when X mode is opted in"
  assert_not_contains "$out" "FMX: X mode on" "bootstrap must not announce X mode when a dependency is missing"
  assert_absent "$home/state/x-watch.check.sh" "missing jq must not arm the check shim"
  assert_absent "$home/config/x-mode.env" "missing jq must not write the cadence config"
  pass "bootstrap reports missing X-mode dependencies before arming"
}

test_bootstrap_does_not_announce_when_arm_fails() {
  local home out
  home="$TMP_ROOT/boot-arm-fail"; mkdir -p "$home"
  printf 'FMX_PAIRING_TOKEN=tok-boot\n' > "$home/.env"
  printf '%s\n' 'not a directory' > "$home/config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMX: X mode off - failed to arm relay poll shim or 30s cadence" \
    "bootstrap must report a failed X-mode activation"
  assert_not_contains "$out" "FMX: X mode on" \
    "bootstrap must not announce X mode when the shim or cadence was not armed"
  assert_absent "$home/state/x-watch.check.sh" "failed X-mode activation must not leave an armed shim"
  pass "bootstrap does not report X mode on when activation artifacts cannot be written"
}

test_bootstrap_inert_without_token() {
  local home out
  # No .env at all.
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMX:" "bootstrap must say nothing about X mode without a token"
  assert_absent "$home/state/x-watch.check.sh" "no token -> no check shim"
  assert_absent "$home/config/x-mode.env" "no token -> no cadence config"
  # .env present but token empty -> still off.
  home="$TMP_ROOT/boot-empty"; mkdir -p "$home"
  printf 'FMX_PAIRING_TOKEN=\n' > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMX:" "an empty token must be treated as off"
  assert_absent "$home/state/x-watch.check.sh" "empty token -> no check shim"
  pass "bootstrap is inert without a non-empty .env token (non-X users unaffected)"
}

test_poll_empty_text_is_silent() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-empty-text"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-t\n' > "$home/.env"
  # A 200 with a request_id but an empty .text is not an actionable question.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY='{"request_id":"req-9","text":""}' \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll empty-text exit"
  [ -z "$out" ] || fail "poll must not emit a marker for an empty question (got: $out)"
  assert_absent "$home/state/x-inbox/req-9.json" "poll must not stash an empty question"
  # Same when .text is missing entirely.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY='{"request_id":"req-10"}' \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll missing-text exit"
  [ -z "$out" ] || fail "poll must not emit a marker when .text is absent (got: $out)"
  assert_absent "$home/state/x-inbox/req-10.json" "poll must not stash when .text is absent"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_POLL_CODE=200 FAKE_POLL_BODY='{"request_id":"req-11","text":" \n\t "}' \
    "$ROOT/bin/fm-x-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll whitespace-text exit"
  [ -z "$out" ] || fail "poll must not emit a marker for a whitespace-only question (got: $out)"
  assert_absent "$home/state/x-inbox/req-11.json" "poll must not stash a whitespace-only question"
  pass "fm-x-poll requires a non-empty question before waking"
}

test_reply_text_file_and_stdin() {
  local home fakebin log data rc out
  home="$TMP_ROOT/reply-input"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-r\n' > "$home/.env"
  # --text-file: text with shell metacharacters must survive verbatim (no shell
  # expansion) because it never touches a shell command line.
  log="$home/file.log"
  # shellcheck disable=SC2016  # single quotes are deliberate: the metacharacters must stay literal
  printf '%s' 'Aye $(whoami) & "fixes" `now`' > "$home/reply.txt"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_ANSWER_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-1" --text-file "$home/reply.txt"); rc=$?
  expect_code 0 "$rc" "reply --text-file exit"
  [ "$out" = "req-1" ] || fail "reply --text-file must echo only the request_id (got: $out)"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  # shellcheck disable=SC2016  # single quotes are deliberate: comparing against the literal text
  [ "$(printf '%s' "$data" | jq -r .text)" = 'Aye $(whoami) & "fixes" `now`' ] \
    || fail "reply --text-file must send the text verbatim, unexpanded"
  # stdin form.
  log="$home/stdin.log"
  out=$(printf '%s' 'reply via stdin' | PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    FMX_RELAY_URL="https://relay.test" FAKE_CURL_LOG="$log" FAKE_ANSWER_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-2" -); rc=$?
  expect_code 0 "$rc" "reply stdin exit"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r .text)" = 'reply via stdin' ] \
    || fail "reply via stdin must send the piped text"
  pass "fm-x-reply accepts the reply via --text-file and stdin (safe, unexpanded)"
}

test_bootstrap_opt_out_cleanup() {
  local home out
  home="$TMP_ROOT/boot-optout"; mkdir -p "$home"
  # Opt in, artifacts appear.
  printf 'FMX_PAIRING_TOKEN=tok-out\n' > "$home/.env"
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/x-watch.check.sh" "opt-in must create the shim"
  assert_present "$home/config/x-mode.env" "opt-in must create the cadence config"
  # Opt out: empty the token, re-run bootstrap -> artifacts removed + one off line.
  printf 'FMX_PAIRING_TOKEN=\n' > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMX: X mode off" "opt-out must announce X mode off when it removed artifacts"
  assert_absent "$home/state/x-watch.check.sh" "opt-out must remove the shim"
  assert_absent "$home/config/x-mode.env" "opt-out must remove the cadence config"
  # Steady-state off: another run with nothing to remove is silent.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMX:" "steady-state off must be silent"
  pass "bootstrap cleans up X artifacts on opt-out and is silent once off"
}

test_bootstrap_opt_out_reports_cleanup_failure() {
  local home fakebin out
  home="$TMP_ROOT/boot-optout-fail"; mkdir -p "$home"
  printf 'FMX_PAIRING_TOKEN=tok-out\n' > "$home/.env"
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/x-watch.check.sh" "opt-in must create the shim before cleanup failure"
  assert_present "$home/config/x-mode.env" "opt-in must create the cadence config before cleanup failure"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/rm"
  printf 'FMX_PAIRING_TOKEN=\n' > "$home/.env"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMX: X mode off - failed to remove relay poll shim or 30s cadence" \
    "opt-out cleanup failure must be reported"
  assert_present "$home/state/x-watch.check.sh" "failed opt-out cleanup must leave the stale shim visible"
  assert_present "$home/config/x-mode.env" "failed opt-out cleanup must leave the stale cadence visible"
  pass "bootstrap reports failed X artifact cleanup on opt-out"
}

test_reply_dry_run_records_not_posts() {
  local home fakebin log out rc
  home="$TMP_ROOT/reply-dry"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-d\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_DRY_RUN=1 FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-x-reply.sh" "req-1" "Aye, a couple of fixes underway." 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "dry-run reply exit"
  [ "$out" = "req-1" ] || fail "dry-run must still echo the request_id (got: $out)"
  # It must NOT have posted: the fake curl is never invoked, so no POST is logged.
  [ -f "$log" ] && grep -q "method=POST" "$log" && fail "dry-run must not POST to the relay"
  assert_present "$home/state/x-outbox/req-1.json" "dry-run must record the would-be reply"
  [ "$(jq -r .text "$home/state/x-outbox/req-1.json")" = "Aye, a couple of fixes underway." ] \
    || fail "outbox record must hold the would-be reply text"
  [ "$(jq -r .request_id "$home/state/x-outbox/req-1.json")" = "req-1" ] \
    || fail "outbox record must hold the request_id"
  assert_grep "DRY RUN" "$home/err" "dry-run must surface a DRY RUN summary on stderr"
  pass "fm-x-reply dry-run records the would-be reply and never posts"
}

test_reply_dry_run_needs_no_token() {
  local home out rc
  home="$TMP_ROOT/reply-dry-notoken"; mkdir -p "$home"
  # No token at all: dry-run still previews (it neither authenticates nor posts).
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" "req-2" "preview without creds" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "dry-run no-token exit"
  [ "$out" = "req-2" ] || fail "dry-run without a token must still echo the request_id (got: $out)"
  assert_present "$home/state/x-outbox/req-2.json" "dry-run without a token must still record the preview"
  pass "fm-x-reply dry-run works without a token"
}

test_reply_dry_run_from_env_file() {
  local home fakebin log out rc
  home="$TMP_ROOT/reply-dry-env"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # FMX_DRY_RUN read from .env (not just the environment).
  printf 'FMX_PAIRING_TOKEN=tok-d\nFMX_DRY_RUN=1\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" "$ROOT/bin/fm-x-reply.sh" "req-3" "from dotenv" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "dry-run-from-.env exit"
  [ "$out" = "req-3" ] || fail "dry-run from .env must echo the request_id (got: $out)"
  [ -f "$log" ] && grep -q "method=POST" "$log" && fail "dry-run from .env must not POST"
  assert_present "$home/state/x-outbox/req-3.json" "dry-run from .env must record the preview"
  pass "fm-x-reply honors FMX_DRY_RUN from .env"
}

test_reply_empty_env_dry_run_overrides_env_file() {
  local home fakebin log out rc
  home="$TMP_ROOT/reply-dry-empty-env"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-d\nFMX_DRY_RUN=1\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_DRY_RUN='' FAKE_CURL_LOG="$log" FAKE_ANSWER_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-5" "empty env disables dry run" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "dry-run empty-env override exit"
  [ "$out" = "req-5" ] || fail "empty dry-run env override must still echo the request_id (got: $out)"
  assert_grep "method=POST" "$log" "empty dry-run env override must post instead of previewing"
  assert_absent "$home/state/x-outbox/req-5.json" "empty dry-run env override must not record an outbox preview"
  pass "fm-x-reply lets an explicitly empty dry-run env override .env"
}

test_reply_dry_run_fails_when_outbox_unwritable() {
  local home err out rc
  home="$TMP_ROOT/reply-dry-unwritable"; mkdir -p "$home/state"
  err="$home/err.txt"
  printf '%s\n' 'not a directory' > "$home/state/x-outbox"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" "req-4" "preview text" 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "dry-run must fail when it cannot record the preview"
  [ -z "$out" ] || fail "dry-run record failure must not echo the request_id (got: $out)"
  assert_grep "cannot create dry-run outbox" "$err" "dry-run must explain the outbox failure"
  pass "fm-x-reply dry-run fails when it cannot record the preview"
}

test_split_thread_lib() {
  # shellcheck source=bin/fm-x-lib.sh
  . "$ROOT/bin/fm-x-lib.sh"
  local out n last rejoin maxlen txt
  # A reply that fits one tweet stays a single, UNNUMBERED chunk.
  out=$(printf 'Aye, all shipshape.' | fmx_split_thread 280 25)
  [ "$(printf '%s' "$out" | jq 'length')" = "1" ] || fail "short reply must be one chunk"
  [ "$(printf '%s' "$out" | jq -r '.[0]')" = "Aye, all shipshape." ] || fail "short reply must be verbatim and unnumbered"
  # A long reply splits on word boundaries; every chunk within the limit; lossless.
  txt="alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november"
  out=$(printf '%s' "$txt" | fmx_split_thread 30 25)
  n=$(printf '%s' "$out" | jq 'length')
  [ "$n" -gt 1 ] || fail "a long reply must split into more than one chunk"
  maxlen=$(printf '%s' "$out" | jq 'map(length)|max')
  [ "$maxlen" -le 30 ] || fail "every thread chunk must be within the limit (got max $maxlen)"
  last=$(printf '%s' "$out" | jq -r '.[0]')
  case "$last" in *" (1/$n)") : ;; *) fail "chunks must be numbered (k/n): $last" ;; esac
  rejoin=$(printf '%s' "$out" | jq -r 'map(sub(" \\([0-9]+/[0-9]+\\)$";""))|join(" ")')
  [ "$rejoin" = "$txt" ] || fail "thread must rejoin losslessly (got: $rejoin)"
  # A single over-long word is hard-split so no chunk exceeds the limit.
  out=$(printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | fmx_split_thread 20 25)
  [ "$(printf '%s' "$out" | jq 'map(length)|max')" -le 20 ] || fail "over-long word must hard-split within the limit"
  # The cap bounds the thread; a truncated thread is marked with an ellipsis.
  out=$(printf 'one two three four five six seven eight nine ten' | fmx_split_thread 20 2)
  [ "$(printf '%s' "$out" | jq 'length')" -le 2 ] || fail "thread must respect the cap"
  case "$(printf '%s' "$out" | jq -r '.[-1]')" in *…*) : ;; *) fail "a capped thread must mark truncation" ;; esac
  pass "fmx_split_thread: word-boundary, within-limit, numbered, lossless, capped"
}

test_reply_single_no_texts() {
  local home out
  home="$TMP_ROOT/reply-single"; mkdir -p "$home"
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 "$ROOT/bin/fm-x-reply.sh" req-s "Short and sweet." 2>/dev/null)
  [ "$out" = "req-s" ] || fail "single dry-run must echo the request_id (got: $out)"
  jq -e 'has("texts")|not' "$home/state/x-outbox/req-s.json" >/dev/null || fail "a one-tweet reply must not include texts"
  [ "$(jq -r '.text' "$home/state/x-outbox/req-s.json")" = "Short and sweet." ] || fail "single reply text must be verbatim and unnumbered"
  pass "fm-x-reply keeps a concise reply as a single unnumbered tweet"
}

test_reply_thread_dry_run() {
  local home out long
  home="$TMP_ROOT/reply-thread"; mkdir -p "$home"
  long="The captain has me on a sign-in redirect fix, a docs tidy, and keeping the build green while other jobs run in the background today."
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 FMX_X_REPLY_MAX_CHARS=50 \
    "$ROOT/bin/fm-x-reply.sh" req-t "$long" 2>/dev/null)
  [ "$out" = "req-t" ] || fail "thread dry-run must echo the request_id (got: $out)"
  assert_present "$home/state/x-outbox/req-t.json" "thread dry-run must record the outbox preview"
  jq -e '.texts and (.texts|length>1)' "$home/state/x-outbox/req-t.json" >/dev/null || fail "a long reply must record a texts[] thread"
  [ "$(jq '.texts|map(length)|max' "$home/state/x-outbox/req-t.json")" -le 50 ] || fail "each thread tweet must be within the limit"
  [ "$(jq -r '.text' "$home/state/x-outbox/req-t.json")" = "$(jq -r '.texts[0]' "$home/state/x-outbox/req-t.json")" ] || fail "text must equal the first chunk"
  pass "fm-x-reply auto-splits a long reply into a numbered thread (texts[])"
}

test_reply_max_chars_floor_clamps_to_minimum() {
  local home out long
  home="$TMP_ROOT/reply-max-floor"; mkdir -p "$home"
  long="alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november"
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 FMX_X_REPLY_MAX_CHARS=49 \
    "$ROOT/bin/fm-x-reply.sh" req-floor "$long" 2>/dev/null)
  [ "$out" = "req-floor" ] || fail "reply max floor dry-run must echo the request_id (got: $out)"
  jq -e '.texts and (.texts|length>1)' "$home/state/x-outbox/req-floor.json" >/dev/null || fail "a below-floor max must clamp to 50 and still split"
  [ "$(jq '.texts|map(length)|max' "$home/state/x-outbox/req-floor.json")" -le 50 ] || fail "clamped thread tweets must be within the 50 character floor"
  pass "fm-x-reply clamps a below-floor max to 50 characters"
}

test_reply_thread_live_posts_texts() {
  local home fakebin log out data
  home="$TMP_ROOT/reply-thread-live"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-th\n' > "$home/.env"
  # 50 is the configured minimum per-tweet budget; the text is well over it so it
  # must split into a multi-tweet thread.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_X_REPLY_MAX_CHARS=50 FAKE_CURL_LOG="$log" FAKE_ANSWER_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" req-l "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo")
  [ "$out" = "req-l" ] || fail "live thread must echo the request_id (got: $out)"
  assert_grep "method=POST" "$log" "live thread must POST"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  printf '%s' "$data" | jq -e '.texts and (.texts|length>1)' >/dev/null || fail "live thread POST body must carry texts[]"
  printf '%s' "$data" | jq -e '.text == .texts[0]' >/dev/null || fail "live thread text must equal the first chunk"
  pass "fm-x-reply posts a thread payload (texts[]) to the relay"
}

test_poll_no_token_is_hard_noop
test_poll_empty_env_token_overrides_env_file
test_poll_204_is_silent
test_poll_empty_env_relay_overrides_env_file
test_poll_auth_error_reports_once
test_poll_question_stashes_and_marks
test_poll_preserves_conversation_context
test_poll_inbox_commit_failure_reports_error
test_poll_empty_text_is_silent
test_poll_rejects_unsafe_request_id
test_reply_success_posts_request_bound_only
test_reply_text_file_and_stdin
test_reply_non_2xx_fails
test_reply_usage_error
test_reply_whitespace_text_rejected
test_reply_dry_run_records_not_posts
test_reply_dry_run_needs_no_token
test_reply_dry_run_from_env_file
test_reply_empty_env_dry_run_overrides_env_file
test_reply_dry_run_fails_when_outbox_unwritable
test_split_thread_lib
test_reply_single_no_texts
test_reply_thread_dry_run
test_reply_max_chars_floor_clamps_to_minimum
test_reply_thread_live_posts_texts
test_bootstrap_activates_on_env_token
test_bootstrap_reports_missing_x_dependency
test_bootstrap_does_not_announce_when_arm_fails
test_bootstrap_inert_without_token
test_bootstrap_opt_out_cleanup
test_bootstrap_opt_out_reports_cleanup_failure
