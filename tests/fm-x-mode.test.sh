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
    --data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
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
    [ -n "$ofile" ] && printf '%s' "${FAKE_ANSWER_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_ANSWER_CODE:-200}"
    ;;
  */connector/followup)
    [ -n "$ofile" ] && printf '%s' "${FAKE_FOLLOWUP_BODY:-${FAKE_ANSWER_BODY:-}}" > "$ofile"
    [ -n "${FAKE_CURL_TOUCH_AFTER_POST:-}" ] && : > "$FAKE_CURL_TOUCH_AFTER_POST"
    printf '%s' "${FAKE_FOLLOWUP_CODE:-${FAKE_ANSWER_CODE:-200}}"
    ;;
  */connector/dismiss)
    printf '%s' "${FAKE_DISMISS_CODE:-200}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

make_sample_image() {
  local path=$1
  case "$path" in
    *.png) printf '\211PNG\r\n\032\nfirstmate-test-png' > "$path" ;;
    *.jpg|*.jpeg) printf '\377\330\377firstmate-test-jpeg' > "$path" ;;
    *.gif) printf 'GIF89afirstmate-test-gif' > "$path" ;;
    *.webp) printf 'RIFF....WEBPfirstmate-test-webp' > "$path" ;;
    *) printf 'firstmate-test-image' > "$path" ;;
  esac
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

test_reply_auth_header_tempfile_cleans_up_on_interrupted_post() {
  local home fakebin log out rc auth_file
  home="$TMP_ROOT/reply-auth-interrupt"; mkdir -p "$home"
  fakebin=$(fm_fakebin "$home")
  log="$home/auth-file.txt"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
auth_file=
while [ $# -gt 0 ]; do
  case "$1" in
    -H)
      case "$2" in @*) auth_file=${2#@} ;; esac
      shift 2
      ;;
    -o|-w|-X|-m|--data|--data-binary) shift 2 ;;
    -s) shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$auth_file" > "$FAKE_AUTH_FILE_LOG"
kill -TERM "$PPID"
exit 143
SH
  chmod +x "$fakebin/curl"
  printf 'FMX_PAIRING_TOKEN=tok-clean\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_AUTH_FILE_LOG="$log" \
    "$ROOT/bin/fm-x-reply.sh" "req-clean" "Hello." 2>"$home/err"); rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted relay post must fail"
  [ -z "$out" ] || fail "interrupted relay post must not echo the request_id (got: $out)"
  auth_file=$(cat "$log")
  [ -n "$auth_file" ] || fail "fake curl must record the auth header temp file"
  [ ! -e "$auth_file" ] || fail "auth header temp file must be removed after an interrupted post"
  pass "fm-x-reply cleans up auth header temp files on interrupted posts"
}

test_reply_usage_error() {
  local home rc err
  home="$TMP_ROOT/reply-usage"; mkdir -p "$home"
  err="$home/err.txt"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-reply.sh" "only-one" >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "reply usage error exit"
  assert_grep "--image <path>" "$err" "reply usage must mention --image"
  pass "fm-x-reply rejects missing arguments with a usage error"
}

test_reply_help_mentions_image() {
  local home out rc
  home="$TMP_ROOT/reply-help"; mkdir -p "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-reply.sh" --help); rc=$?
  expect_code 0 "$rc" "reply --help exit"
  assert_contains "$out" "--image <path>" "reply help must mention --image"
  assert_contains "$out" "threaded replies attach it to the opener tweet" \
    "reply help must document thread image placement"
  pass "fm-x-reply --help makes image support discoverable"
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
  out=$(CLAUDECODE=1 FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMX: X mode off" "opt-out must announce X mode off when it removed artifacts"
  assert_contains "$out" "Claude Code background task" "opt-out remediation must use the harness-aware repair renderer"
  assert_not_contains "$out" "bin/fm-watch-arm.sh --restart" "opt-out remediation must not hardcode a background-arm restart"
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
  txt=$(cat <<'TXT'
Intro paragraph has enough words to make the reply split before the fenced block.

```bash
printf '%s\n' "hello from a fenced block"
printf '%s\n' "the marker must not land in here"
```

Final paragraph also has enough words to make the reply split after the fenced block.
TXT
)
  out=$(printf '%s' "$txt" | fmx_split_thread 120 25)
  [ "$(printf '%s' "$out" | jq 'length')" -gt 1 ] || fail "fenced markdown reply must split"
  printf '%s' "$out" | jq -e \
    'all(.[]; (((gsub(" \\([0-9]+/[0-9]+\\)$"; "") | split("```") | length) - 1) % 2) == 0)' \
    >/dev/null || fail "thread chunks must not leave an open code fence"
  printf '%s' "$out" | jq -e \
    'any(.[]; contains("```bash\nprintf") and contains("marker must not land in here\"") and contains("\n```"))' \
    >/dev/null || fail "the fenced code block must stay in one chunk"
  printf '%s' "$out" | jq -e \
    'all(.[] | split("\n")[]; (test("^[[:space:]]*```.* \\([0-9]+/[0-9]+\\)$") | not))' \
    >/dev/null || fail "numbering markers must not be appended to fenced-code boundary lines"
  pass "fmx_split_thread: word-boundary, fence-aware, within-limit, numbered, lossless, capped"
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

test_reply_discord_inbox_uses_discord_budget() {
  local home out reply
  home="$TMP_ROOT/reply-discord-budget"; mkdir -p "$home/state/x-inbox"
  jq -cn '{request_id:"req-discord",tweet_id:"discord:channel:message",text:"question"}' \
    > "$home/state/x-inbox/req-discord.json"
  reply=$(cat <<'TXT'
First paragraph stays intact in a single Discord reply even though it is comfortably over the X tweet budget.

```bash
printf '%s\n' "the code fence must remain intact"
printf '%s\n' "no numbering marker belongs here"
```

Final paragraph also remains in the same public Discord message because the total is far below the 1900 character split budget.
TXT
)
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 "$ROOT/bin/fm-x-reply.sh" req-discord "$reply" 2>/dev/null)
  [ "$out" = "req-discord" ] || fail "Discord dry-run must echo the request_id (got: $out)"
  jq -e 'has("texts")|not' "$home/state/x-outbox/req-discord.json" >/dev/null \
    || fail "Discord reply below its message budget must not be split into texts[]"
  assert_contains "$(jq -r '.text' "$home/state/x-outbox/req-discord.json")" '```bash' \
    "Discord reply must preserve the fenced code block"
  pass "fm-x-reply uses the Discord inbox platform budget instead of the X tweet budget"
}

test_reply_x_inbox_still_uses_x_budget() {
  local home out long
  home="$TMP_ROOT/reply-x-budget"; mkdir -p "$home/state/x-inbox"
  jq -cn '{request_id:"req-x",tweet_id:"1234567890",text:"question"}' > "$home/state/x-inbox/req-x.json"
  long="This X reply intentionally runs beyond the default tweet budget so it still needs a numbered thread on X. It has enough plain words to cross the limit while staying easy to split at word boundaries without code fences or platform ambiguity. The old default must remain intact for numeric tweet ids."
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 "$ROOT/bin/fm-x-reply.sh" req-x "$long" 2>/dev/null)
  [ "$out" = "req-x" ] || fail "X dry-run must echo the request_id (got: $out)"
  jq -e '.texts and (.texts|length>1)' "$home/state/x-outbox/req-x.json" >/dev/null \
    || fail "X reply over 280 characters must still split into texts[]"
  [ "$(jq '.texts|map(length)|max' "$home/state/x-outbox/req-x.json")" -le 280 ] \
    || fail "X reply chunks must stay within the default X budget"
  pass "fm-x-reply keeps numeric X requests on the X tweet budget"
}

test_reply_inbox_explicit_limit_wins() {
  local home out long
  home="$TMP_ROOT/reply-explicit-limit"; mkdir -p "$home/state/x-inbox"
  jq -cn '{request_id:"req-limit",platform:"discord",reply_max_chars:90,text:"question"}' \
    > "$home/state/x-inbox/req-limit.json"
  long="Discord normally has a much larger budget, but an explicit relay-provided reply_max_chars value must be honored when the payload carries one."
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 "$ROOT/bin/fm-x-reply.sh" req-limit "$long" 2>/dev/null)
  [ "$out" = "req-limit" ] || fail "explicit-limit dry-run must echo the request_id (got: $out)"
  jq -e '.texts and (.texts|length>1)' "$home/state/x-outbox/req-limit.json" >/dev/null \
    || fail "explicit reply_max_chars must force a split even on Discord"
  [ "$(jq '.texts|map(length)|max' "$home/state/x-outbox/req-limit.json")" -le 90 ] \
    || fail "explicit-limit chunks must stay within the relay-provided budget"
  pass "fm-x-reply prefers an explicit relay-provided reply limit"
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

test_reply_image_live_posts_image_object() {
  local home fakebin log out rc data img expected
  home="$TMP_ROOT/reply-image-live"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  img="$home/diagram.png"
  make_sample_image "$img"
  expected=$(base64 < "$img" | tr -d '\n\r')
  printf 'FMX_PAIRING_TOKEN=tok-img\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_ANSWER_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-img" --image "$img" "Here is the illustration."); rc=$?
  expect_code 0 "$rc" "reply image live exit"
  [ "$out" = "req-img" ] || fail "image reply must echo only the request_id (got: $out)"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r '.image.media_type')" = "image/png" ] \
    || fail "image reply must detect PNG media_type"
  [ "$(printf '%s' "$data" | jq -r '.image.data_base64')" = "$expected" ] \
    || fail "image reply must include base64 image bytes"
  [ "$(printf '%s' "$data" | jq -r '.text')" = "Here is the illustration." ] \
    || fail "image reply must preserve text"
  pass "fm-x-reply --image posts an image object on answer"
}

test_reply_image_live_streams_payload_file() {
  local home fakebin log out rc data img i
  home="$TMP_ROOT/reply-image-stream"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  img="$home/large.png"
  make_sample_image "$img"
  i=0
  while [ "$i" -lt 4096 ]; do
    printf '0123456789abcdef0123456789abcdef' >> "$img"
    i=$((i + 1))
  done
  printf 'FMX_PAIRING_TOKEN=tok-img-stream\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_ANSWER_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-img-stream" --image "$img" "Here is the illustration."); rc=$?
  expect_code 0 "$rc" "streamed image reply exit"
  [ "$out" = "req-img-stream" ] || fail "streamed image reply must echo only the request_id (got: $out)"
  assert_grep "--data-binary @" "$log" "image reply must stream the POST body from a file"
  grep '^argv=' "$log" | tail -1 | grep -F 'data_base64' >/dev/null 2>&1 \
    && fail "image reply must not place image JSON in curl argv"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  printf '%s' "$data" | jq -e '.image.media_type == "image/png" and (.image.data_base64 | length > 100000)' >/dev/null \
    || fail "streamed image reply must still send the base64 image body"
  pass "fm-x-reply streams large image payloads outside curl argv"
}

test_reply_image_thread_dry_run_records_compact_marker() {
  local home fakebin log out rc img bytes
  home="$TMP_ROOT/reply-image-thread-dry"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  img="$home/illustration.webp"
  make_sample_image "$img"
  bytes=$(wc -c < "$img" | tr -d '[:space:]')
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 FMX_X_REPLY_MAX_CHARS=50 \
    FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-x-reply.sh" "req-img-dry" --image "$img" \
    "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november" \
    2>"$home/err"); rc=$?
  expect_code 0 "$rc" "reply image dry-run exit"
  [ "$out" = "req-img-dry" ] || fail "image dry-run must echo the request_id (got: $out)"
  [ -f "$log" ] && grep -q "method=POST" "$log" && fail "image dry-run must not POST"
  assert_present "$home/state/x-outbox/req-img-dry.json" "image dry-run must record the preview"
  jq -e '.texts and (.texts|length>1)' "$home/state/x-outbox/req-img-dry.json" >/dev/null \
    || fail "image dry-run thread must keep texts[]"
  [ "$(jq -r '.image.media_type' "$home/state/x-outbox/req-img-dry.json")" = "image/webp" ] \
    || fail "image dry-run marker must hold media_type"
  [ "$(jq -r '.image.bytes' "$home/state/x-outbox/req-img-dry.json")" = "$bytes" ] \
    || fail "image dry-run marker must hold byte count"
  [ "$(jq -r '.image.source_path' "$home/state/x-outbox/req-img-dry.json")" = "$img" ] \
    || fail "image dry-run marker must hold source_path"
  jq -e '.image | has("data_base64") | not' "$home/state/x-outbox/req-img-dry.json" >/dev/null \
    || fail "image dry-run marker must not include base64 bytes"
  pass "fm-x-reply dry-run records compact image metadata for threaded replies"
}

test_reply_image_dry_run_cleans_payload_temp_files() {
  local home tmpdir img out rc leftovers
  home="$TMP_ROOT/reply-image-temp-clean"; mkdir -p "$home"
  tmpdir="$home/tmp"; mkdir -p "$tmpdir"
  img="$home/preview.png"
  make_sample_image "$img"
  out=$(PATH="$BASE_PATH" TMPDIR="$tmpdir" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" "req-img-temp-clean" --image "$img" "Here is the image." \
    2>"$home/err"); rc=$?
  expect_code 0 "$rc" "reply image temp cleanup exit"
  [ "$out" = "req-img-temp-clean" ] || fail "image dry-run temp cleanup must echo the request_id (got: $out)"
  leftovers=$(find "$tmpdir" -type f -name 'fm-x-reply.*' -print)
  [ -z "$leftovers" ] || fail "reply temp files must be cleaned (left: $leftovers)"
  pass "fm-x-reply cleans image and payload temp files"
}

test_reply_image_path_errors_are_clear() {
  local home out rc err img
  home="$TMP_ROOT/reply-image-errors"; mkdir -p "$home"
  err="$home/err.txt"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" "req-missing" --image "$home/missing.png" "text" 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "missing image path must fail"
  [ -z "$out" ] || fail "missing image path must not echo the request_id (got: $out)"
  assert_grep "image file does not exist" "$err" "missing image path must explain the error"
  img="$home/not-image.txt"
  printf 'not an image' > "$img"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" "req-badtype" --image "$img" "text" 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported image path must fail"
  assert_grep "unsupported image media type" "$err" "unsupported image path must explain the error"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" "req-noarg" --image 2>"$err"); rc=$?
  expect_code 2 "$rc" "missing --image argument exit"
  assert_grep "missing --image path" "$err" "missing --image argument must explain the error"
  pass "fm-x-reply --image rejects missing and unsupported image paths clearly"
}

# --- follow-up reply mode (--followup -> /connector/followup) ----------------

test_reply_followup_live_posts_to_followup_endpoint() {
  local home fakebin log out rc data keys
  home="$TMP_ROOT/reply-followup-live"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_FOLLOWUP_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-7" --followup "Done, captain - the fix has shipped."); rc=$?
  expect_code 0 "$rc" "followup live exit"
  [ "$out" = "req-7" ] || fail "followup must echo only the request_id (got: $out)"
  assert_grep "url=https://relay.test/connector/followup" "$log" "followup must POST /connector/followup"
  assert_grep "method=POST" "$log" "followup must use POST"
  assert_grep "auth=Authorization: Bearer tok-fu" "$log" "followup must send the bearer token"
  # The live body is identical to an answer: {request_id, text}, never a marker.
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  keys=$(printf '%s' "$data" | jq -r 'keys|join(",")')
  [ "$keys" = "request_id,text" ] || fail "followup live body must carry only request_id,text (got: $keys)"
  [ "$(printf '%s' "$data" | jq -r .request_id)" = "req-7" ] || fail "followup body request_id"
  pass "fm-x-reply --followup posts to /connector/followup with the same request-bound body"
}

test_reply_followup_409_marker_exits_distinctly() {
  local home fakebin out rc err
  home="$TMP_ROOT/reply-followup-409-marker"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_FOLLOWUP_CODE=409 FAKE_FOLLOWUP_BODY='{"error":"followup_unavailable"}' \
    "$ROOT/bin/fm-x-reply.sh" "req-409-marker" --followup "Late follow-up." 2>"$err"); rc=$?
  expect_code 9 "$rc" "followup 409 marker exit"
  [ -z "$out" ] || fail "followup 409 marker must not echo the request_id (got: $out)"
  assert_grep "confirmed followup_unavailable marker" "$err" \
    "followup 409 marker must be reflected in diagnostics"
  pass "fm-x-reply maps a followup_unavailable follow-up 409 to exit 9"
}

test_reply_followup_409_without_marker_still_exits_distinctly() {
  local home fakebin out rc err
  home="$TMP_ROOT/reply-followup-409-fallback"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_FOLLOWUP_CODE=409 \
    "$ROOT/bin/fm-x-reply.sh" "req-409-bare" --followup "Late follow-up." 2>"$err"); rc=$?
  expect_code 9 "$rc" "followup bare 409 exit"
  [ -z "$out" ] || fail "followup bare 409 must not echo the request_id (got: $out)"
  assert_grep "marker absent" "$err" "bare followup 409 must use the fallback diagnostic"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_FOLLOWUP_CODE=409 FAKE_FOLLOWUP_BODY='{"error":"some_other_conflict"}' \
    "$ROOT/bin/fm-x-reply.sh" "req-409-other" --followup "Late follow-up." 2>"$err"); rc=$?
  expect_code 9 "$rc" "followup unrelated-body 409 exit"
  [ -z "$out" ] || fail "followup unrelated-body 409 must not echo the request_id (got: $out)"
  assert_grep "marker absent" "$err" \
    "unrelated followup 409 body must still use the fallback diagnostic"
  pass "fm-x-reply maps every follow-up 409 to exit 9 even without the marker"
}

test_reply_answer_409_is_generic_failure() {
  local home fakebin out rc err
  home="$TMP_ROOT/reply-answer-409"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  printf 'FMX_PAIRING_TOKEN=tok-answer\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_ANSWER_CODE=409 FAKE_ANSWER_BODY='{"error":"followup_unavailable"}' \
    "$ROOT/bin/fm-x-reply.sh" "req-answer-409" "Normal answer." 2>"$err"); rc=$?
  expect_code 1 "$rc" "answer 409 exit"
  [ -z "$out" ] || fail "answer 409 must not echo the request_id (got: $out)"
  assert_grep "relay returned HTTP 409" "$err" "answer 409 must stay on the generic failure path"
  pass "fm-x-reply treats answer-endpoint 409 as a generic failure"
}

test_reply_followup_image_live_posts_image_object() {
  local home fakebin log out rc data img expected
  home="$TMP_ROOT/reply-followup-image-live"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  img="$home/result.jpg"
  make_sample_image "$img"
  expected=$(base64 < "$img" | tr -d '\n\r')
  printf 'FMX_PAIRING_TOKEN=tok-fu-img\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_FOLLOWUP_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-fu-img" --followup --image "$img" \
    "Done - here is the generated image."); rc=$?
  expect_code 0 "$rc" "followup image live exit"
  [ "$out" = "req-fu-img" ] || fail "followup image must echo only the request_id (got: $out)"
  assert_grep "url=https://relay.test/connector/followup" "$log" "image followup must hit followup endpoint"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r '.image.media_type')" = "image/jpeg" ] \
    || fail "image followup must detect JPEG media_type"
  [ "$(printf '%s' "$data" | jq -r '.image.data_base64')" = "$expected" ] \
    || fail "image followup must include base64 image bytes"
  pass "fm-x-reply --followup --image posts an image object"
}

test_reply_followup_flag_position_is_flexible() {
  local home fakebin log rc out
  home="$TMP_ROOT/reply-followup-pos"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-fp\n' > "$home/.env"
  printf '%s' 'done via file' > "$home/reply.txt"
  # --followup AFTER the text source must still select the followup endpoint.
  log="$home/after.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_FOLLOWUP_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-a" --text-file "$home/reply.txt" --followup); rc=$?
  expect_code 0 "$rc" "followup-after-textfile exit"
  assert_grep "url=https://relay.test/connector/followup" "$log" "--followup after --text-file must still hit followup"
  # Without --followup, the answer endpoint is unchanged.
  log="$home/answer.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_ANSWER_CODE=200 \
    "$ROOT/bin/fm-x-reply.sh" "req-a" --text-file "$home/reply.txt"); rc=$?
  expect_code 0 "$rc" "answer-still-default exit"
  assert_grep "url=https://relay.test/connector/answer" "$log" "no flag must keep the answer endpoint"
  pass "fm-x-reply --followup is accepted in any position and leaves the answer path default"
}

test_reply_followup_dry_run_marks_endpoint() {
  local home out rc
  home="$TMP_ROOT/reply-followup-dry"; mkdir -p "$home"
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" "req-d" --followup "Shipped - all green." 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "followup dry-run exit"
  [ "$out" = "req-d" ] || fail "followup dry-run must echo the request_id (got: $out)"
  assert_present "$home/state/x-outbox/req-d.json" "followup dry-run must record the preview"
  [ "$(jq -r '.endpoint' "$home/state/x-outbox/req-d.json")" = "followup" ] \
    || fail "followup dry-run preview must carry the endpoint marker"
  [ "$(jq -r '.text' "$home/state/x-outbox/req-d.json")" = "Shipped - all green." ] \
    || fail "followup dry-run preview must hold the reply text"
  assert_grep "/connector/followup" "$home/err" "followup dry-run summary must name the followup endpoint"
  # An answer dry-run must remain unchanged: no endpoint marker.
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 "$ROOT/bin/fm-x-reply.sh" "req-ans" "Aye." 2>/dev/null)
  jq -e 'has("endpoint")|not' "$home/state/x-outbox/req-ans.json" >/dev/null \
    || fail "an answer dry-run preview must not gain an endpoint marker"
  pass "fm-x-reply --followup dry-run marks the endpoint without changing the answer path"
}

test_reply_followup_thread_dry_run() {
  local home out long
  home="$TMP_ROOT/reply-followup-thread"; mkdir -p "$home"
  long="The captain has me on a sign-in redirect fix, a docs tidy, and keeping the build green while other jobs run in the background today."
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 FMX_X_REPLY_MAX_CHARS=50 \
    "$ROOT/bin/fm-x-reply.sh" req-ft --followup "$long" 2>/dev/null)
  [ "$out" = "req-ft" ] || fail "followup thread dry-run must echo the request_id (got: $out)"
  jq -e '.texts and (.texts|length>1)' "$home/state/x-outbox/req-ft.json" >/dev/null \
    || fail "a long followup must record a texts[] thread"
  [ "$(jq -r '.endpoint' "$home/state/x-outbox/req-ft.json")" = "followup" ] \
    || fail "followup thread preview must carry the endpoint marker"
  [ "$(jq -r '.text' "$home/state/x-outbox/req-ft.json")" = "$(jq -r '.texts[0]' "$home/state/x-outbox/req-ft.json")" ] \
    || fail "followup thread text must equal the first chunk"
  pass "fm-x-reply --followup auto-splits a long follow-up into a marked thread"
}

test_reply_followup_image_dry_run_marks_endpoint_and_compacts_image() {
  local home out rc img
  home="$TMP_ROOT/reply-followup-image-dry"; mkdir -p "$home"
  img="$home/result.gif"
  make_sample_image "$img"
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-reply.sh" "req-fu-img-dry" --followup --image "$img" "Done with art." \
    2>"$home/err"); rc=$?
  expect_code 0 "$rc" "followup image dry-run exit"
  [ "$out" = "req-fu-img-dry" ] || fail "followup image dry-run must echo the request_id (got: $out)"
  [ "$(jq -r '.endpoint' "$home/state/x-outbox/req-fu-img-dry.json")" = "followup" ] \
    || fail "followup image dry-run must carry endpoint marker"
  [ "$(jq -r '.image.media_type' "$home/state/x-outbox/req-fu-img-dry.json")" = "image/gif" ] \
    || fail "followup image dry-run must detect GIF media_type"
  jq -e '.image | has("data_base64") | not' "$home/state/x-outbox/req-fu-img-dry.json" >/dev/null \
    || fail "followup image dry-run must omit base64 bytes"
  pass "fm-x-reply followup dry-run keeps endpoint marker and compact image metadata"
}

# --- fm-x-dismiss: drop a mention at the relay without replying ---------------

test_dismiss_success_posts_request_only() {
  local home fakebin log out rc data keys
  home="$TMP_ROOT/dismiss-ok"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-d\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_CURL_LOG="$log" FAKE_DISMISS_CODE=200 \
    "$ROOT/bin/fm-x-dismiss.sh" "req-9"); rc=$?
  expect_code 0 "$rc" "dismiss success exit"
  [ "$out" = "req-9" ] || fail "dismiss must echo only the request_id (got: $out)"
  assert_grep "url=https://relay.test/connector/dismiss" "$log" "dismiss must POST /connector/dismiss"
  assert_grep "method=POST" "$log" "dismiss must use POST"
  assert_grep "auth=Authorization: Bearer tok-d" "$log" "dismiss must send the bearer token"
  grep '^argv=' "$log" | grep -F 'tok-d' >/dev/null 2>&1 \
    && fail "dismiss must not expose the bearer token in curl argv"
  # The body must be exactly {request_id} - no text, no tweet id.
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r .request_id)" = "req-9" ] || fail "dismiss body request_id"
  keys=$(printf '%s' "$data" | jq -r 'keys|join(",")')
  [ "$keys" = "request_id" ] || fail "dismiss body must carry only request_id (got: $keys)"
  pass "fm-x-dismiss posts a request-bound dismiss and echoes only the request_id"
}

test_dismiss_dry_run_records_not_posts() {
  local home fakebin log out rc
  home="$TMP_ROOT/dismiss-dry"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-d\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_DRY_RUN=1 FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-x-dismiss.sh" "req-1" 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "dry-run dismiss exit"
  [ "$out" = "req-1" ] || fail "dry-run dismiss must still echo the request_id (got: $out)"
  # It must NOT have posted: the fake curl is never invoked, so no POST is logged.
  [ -f "$log" ] && grep -q "method=POST" "$log" && fail "dry-run dismiss must not POST to the relay"
  assert_present "$home/state/x-outbox/req-1.json" "dry-run dismiss must record the would-be body"
  [ "$(jq -r .request_id "$home/state/x-outbox/req-1.json")" = "req-1" ] \
    || fail "dismiss outbox record must hold the request_id"
  [ "$(jq -r '.endpoint' "$home/state/x-outbox/req-1.json")" = "dismiss" ] \
    || fail "dismiss dry-run preview must carry the endpoint marker"
  assert_grep "DRY RUN" "$home/err" "dry-run dismiss must surface a DRY RUN summary on stderr"
  assert_grep "/connector/dismiss" "$home/err" "dry-run dismiss summary must name the dismiss endpoint"
  pass "fm-x-dismiss dry-run records the would-be body and never posts"
}

test_dismiss_dry_run_needs_no_token() {
  local home out rc
  home="$TMP_ROOT/dismiss-dry-notoken"; mkdir -p "$home"
  # No token at all: dry-run still previews (it neither authenticates nor posts).
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-dismiss.sh" "req-2" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "dry-run no-token dismiss exit"
  [ "$out" = "req-2" ] || fail "dry-run dismiss without a token must still echo the request_id (got: $out)"
  assert_present "$home/state/x-outbox/req-2.json" "dry-run dismiss without a token must still record the preview"
  pass "fm-x-dismiss dry-run works without a token"
}

test_dismiss_non_2xx_fails() {
  local home fakebin out rc err
  home="$TMP_ROOT/dismiss-500"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  printf 'FMX_PAIRING_TOKEN=tok-d\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FAKE_DISMISS_CODE=500 \
    "$ROOT/bin/fm-x-dismiss.sh" "req-9" 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "dismiss must exit non-zero on a non-2xx response"
  [ -z "$out" ] || fail "a failed dismiss must not echo the request_id (got: $out)"
  assert_grep "HTTP 500" "$err" "dismiss must report the failing status"
  pass "fm-x-dismiss exits non-zero on a non-2xx relay response"
}

test_dismiss_transport_failure_fails() {
  local home fakebin err out rc
  home="$TMP_ROOT/dismiss-transport"; mkdir -p "$home"
  fakebin=$(fm_fakebin "$home")
  # A curl that fails to reach the relay (non-zero exit, no HTTP code).
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$fakebin/curl"
  err="$home/err.txt"
  printf 'FMX_PAIRING_TOKEN=tok-d\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    "$ROOT/bin/fm-x-dismiss.sh" "req-9" 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "dismiss must exit non-zero on a transport failure"
  [ -z "$out" ] || fail "a transport-failed dismiss must not echo the request_id (got: $out)"
  assert_grep "request to relay failed" "$err" "dismiss must report the transport failure"
  pass "fm-x-dismiss exits non-zero on a transport failure"
}

test_dismiss_unsafe_request_id_rejected() {
  local home err out rc
  home="$TMP_ROOT/dismiss-unsafe"; mkdir -p "$home"
  err="$home/err.txt"
  # Path-traversal-shaped id must be refused before it becomes an outbox filename.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FMX_DRY_RUN=1 \
    "$ROOT/bin/fm-x-dismiss.sh" "../evil" 2>"$err"); rc=$?
  expect_code 2 "$rc" "dismiss unsafe id exit"
  [ -z "$out" ] || fail "dismiss must not echo an unsafe request_id (got: $out)"
  assert_grep "unsafe request_id" "$err" "dismiss must reject an unsafe request_id"
  assert_absent "$home/state/../evil.json" "dismiss must not touch a path for an unsafe id"
  pass "fm-x-dismiss rejects an unsafe request_id (path-traversal guard)"
}

test_dismiss_usage_error() {
  local home rc
  home="$TMP_ROOT/dismiss-usage"; mkdir -p "$home"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-dismiss.sh" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "dismiss missing-arg usage exit"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-dismiss.sh" req-1 extra >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "dismiss extra-arg usage exit"
  pass "fm-x-dismiss rejects missing or extra arguments with a usage error"
}

# --- fm-x-link: task <-> X-request association in meta -----------------------

test_link_records_request_and_timestamp() {
  local home meta out rc
  home="$TMP_ROOT/link-ok"; mkdir -p "$home/state"
  meta="$home/state/fix-login-k3.meta"
  printf 'window=w\nworktree=/wt\nkind=ship\nmode=no-mistakes\nyolo=off\n' > "$meta"
  out=$(FM_HOME="$home" FMX_NOW_OVERRIDE=1700000000 \
    "$ROOT/bin/fm-x-link.sh" fix-login-k3 req-42); rc=$?
  expect_code 0 "$rc" "link exit"
  assert_grep "x_request=req-42" "$meta" "link must record the request_id"
  assert_grep "x_request_ts=1700000000" "$meta" "link must record the timestamp"
  assert_grep "x_followups=0" "$meta" "a fresh link must start the follow-up counter at 0"
  assert_grep "kind=ship" "$meta" "link must preserve other meta lines"
  assert_grep "yolo=off" "$meta" "link must preserve other meta lines"
  # Re-linking replaces the prior link rather than appending a duplicate.
  FM_HOME="$home" FMX_NOW_OVERRIDE=1700009999 "$ROOT/bin/fm-x-link.sh" fix-login-k3 req-99 >/dev/null
  [ "$(grep -c '^x_request=' "$meta")" = "1" ] || fail "re-link must not duplicate x_request"
  [ "$(grep -c '^x_request_ts=' "$meta")" = "1" ] || fail "re-link must not duplicate x_request_ts"
  [ "$(grep -c '^x_followups=' "$meta")" = "1" ] || fail "re-link must not duplicate x_followups"
  assert_grep "x_request=req-99" "$meta" "re-link must replace the request_id"
  assert_grep "x_request_ts=1700009999" "$meta" "re-link must refresh the timestamp"
  assert_grep "x_followups=0" "$meta" "a plain re-link must reset the follow-up counter to 0"
  pass "fm-x-link records and refreshes the X-request link without disturbing meta"
}

test_link_records_discord_platform_for_followups() {
  local home meta out rc reply
  home="$TMP_ROOT/link-discord-platform"; mkdir -p "$home/state/x-inbox"
  meta="$home/state/fix-discord.meta"
  printf 'window=w\nworktree=/wt\nkind=ship\nmode=no-mistakes\nyolo=off\n' > "$meta"
  jq -cn '{request_id:"req-discord-follow",tweet_id:"discord:channel:message",text:"question"}' \
    > "$home/state/x-inbox/req-discord-follow.json"
  FM_HOME="$home" FMX_NOW_OVERRIDE=1700000000 \
    "$ROOT/bin/fm-x-link.sh" fix-discord req-discord-follow >/dev/null; rc=$?
  expect_code 0 "$rc" "Discord link exit"
  assert_grep "x_platform=discord" "$meta" "link must record Discord platform context"
  assert_grep "x_reply_max_chars=1900" "$meta" "link must record the Discord split budget for follow-ups"
  rm -f "$home/state/x-inbox/req-discord-follow.json"
  reply=$(cat <<'TXT'
The follow-up is longer than an X tweet but should stay in one Discord message because the linked task meta recorded the platform before the inbox was drained.

```bash
printf '%s\n' "this fenced block should stay whole"
```

The final sentence confirms that the follow-up path did not fall back to the X budget after the inbox file disappeared.
TXT
)
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" fix-discord - <<<"$reply" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "Discord follow-up dry-run exit"
  [ "$out" = "req-discord-follow" ] || fail "Discord follow-up must echo the request_id (got: $out)"
  jq -e 'has("texts")|not' "$home/state/x-outbox/req-discord-follow.json" >/dev/null \
    || fail "Discord follow-up below its message budget must not split after inbox drain"
  pass "fm-x-link records Discord platform context so follow-ups keep the Discord budget"
}

test_link_carry_count_and_ts_preserve_followup_binding() {
  local home meta rc
  home="$TMP_ROOT/link-carry"; mkdir -p "$home/state"
  meta="$home/state/successor-task.meta"
  printf 'window=w\nkind=ship\n' > "$meta"
  FM_HOME="$home" FMX_NOW_OVERRIDE=1700999999 \
    "$ROOT/bin/fm-x-link.sh" successor-task req-carry \
      --carry-count 2 --carry-ts 1700000000 --carry-platform x --carry-max 280 >/dev/null; rc=$?
  expect_code 0 "$rc" "link paired carry flags exit"
  assert_grep "x_request=req-carry" "$meta" "carried link must record the request_id"
  assert_grep "x_request_ts=1700000000" "$meta" "--carry-ts must preserve the original timestamp, not the current time"
  assert_grep "x_followups=2" "$meta" "--carry-count must seed the follow-up counter, not reset it"
  assert_grep "x_platform=x" "$meta" "--carry-platform must preserve the prior reply platform"
  assert_grep "x_reply_max_chars=280" "$meta" "--carry-max must preserve the prior split budget"
  pass "fm-x-link paired carry flags preserve a prior task's follow-up binding onto a successor"
}

test_link_recovery_relink_carries_discord_context_after_inbox_drain() {
  local home meta out rc reply
  home="$TMP_ROOT/link-carry-discord"; mkdir -p "$home/state"
  meta="$home/state/successor-discord.meta"
  printf 'window=w\nkind=ship\n' > "$meta"
  FM_HOME="$home" FMX_NOW_OVERRIDE=1700999999 \
    "$ROOT/bin/fm-x-link.sh" successor-discord req-discord-recovery \
      --carry-count 1 --carry-ts 1700000000 --carry-platform discord --carry-max 1900 >/dev/null; rc=$?
  expect_code 0 "$rc" "Discord recovery relink exit"
  assert_grep "x_platform=discord" "$meta" "Discord recovery relink must preserve the platform after inbox drain"
  assert_grep "x_reply_max_chars=1900" "$meta" "Discord recovery relink must preserve the split budget after inbox drain"
  reply=$(cat <<'TXT'
The recovered task is reporting back with enough text to exceed an X tweet, but it is still comfortably within the Discord budget carried over from the prior task.

```bash
printf '%s\n' "the code fence should not force an unnecessary Discord split"
```

The successor task must post this as one Discord follow-up even though the original inbox payload has already been drained.
TXT
)
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" successor-discord - <<<"$reply" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "Discord recovery follow-up dry-run exit"
  [ "$out" = "req-discord-recovery" ] || fail "Discord recovery follow-up must echo the request_id (got: $out)"
  jq -e 'has("texts")|not' "$home/state/x-outbox/req-discord-recovery.json" >/dev/null \
    || fail "Discord recovery follow-up below its message budget must not fall back to X splitting"
  assert_grep "x_followups=2" "$meta" "Discord recovery follow-up must increment the carried count"
  pass "fm-x-link recovery relink preserves Discord platform context after inbox drain"
}

test_link_carry_count_validation() {
  local home rc err
  home="$TMP_ROOT/link-carry-bad"; mkdir -p "$home/state"
  err="$home/err.txt"
  printf 'window=w\nkind=ship\n' > "$home/state/ok.meta"
  PATH="$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-x-link.sh" ok req-1 --carry-count abc >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "link --carry-count non-numeric exit"
  assert_grep "non-negative integer" "$err" "link must explain a bad --carry-count value"
  PATH="$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-x-link.sh" ok req-1 --carry-ts abc >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "link --carry-ts non-numeric exit"
  assert_grep "non-negative epoch integer" "$err" "link must explain a bad --carry-ts value"
  PATH="$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-x-link.sh" ok req-1 --carry-count >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "link --carry-count missing value exit"
  PATH="$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-x-link.sh" ok req-1 --carry-count 1 >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "link --carry-count without --carry-ts exit"
  assert_grep "--carry-count requires --carry-ts" "$err" "link must require --carry-ts when carrying count"
  PATH="$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-x-link.sh" ok req-1 --carry-ts 1700000000 >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "link --carry-ts without --carry-count exit"
  assert_grep "--carry-ts requires --carry-count" "$err" "link must require --carry-count when carrying timestamp"
  PATH="$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-x-link.sh" ok req-1 --carry-count 1 --carry-ts 1700000000 >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "link carry without reply context exit"
  assert_grep "relink requires carried reply context" "$err" "link must not silently drop reply context on relink"
  PATH="$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-x-link.sh" ok req-1 --carry-platform discord >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "link --carry-platform without paired carry flags exit"
  assert_grep "--carry-platform and --carry-max require --carry-count and --carry-ts" "$err" \
    "link must require the paired carry binding when carrying reply context"
  PATH="$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-x-link.sh" ok req-1 --carry-count 1 --carry-ts 1700000000 --carry-max 49 >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "link --carry-max below floor exit"
  assert_grep "--carry-max needs an integer of at least 50" "$err" "link must reject an unusable carried split budget"
  pass "fm-x-link rejects malformed or unpaired carry flags"
}

test_meta_rewrites_do_not_depend_on_tmpdir() {
  local home badtmp meta out rc
  home="$TMP_ROOT/link-local-tmp"; mkdir -p "$home/state"
  badtmp="$home/missing-tmp"
  meta="$home/state/fix-meta-k4.meta"
  printf 'window=w\nkind=ship\n' > "$meta"
  out=$(TMPDIR="$badtmp" FM_HOME="$home" FMX_NOW_OVERRIDE=1700000000 \
    "$ROOT/bin/fm-x-link.sh" fix-meta-k4 req-local); rc=$?
  expect_code 0 "$rc" "link with unusable TMPDIR exit"
  [ "$out" = "linked fix-meta-k4 to X request req-local" ] \
    || fail "link with unusable TMPDIR must still succeed (got: $out)"
  assert_grep "x_request=req-local" "$meta" "link must record request with an unusable TMPDIR"
  out=$(TMPDIR="$badtmp" FM_HOME="$home" FMX_NOW_OVERRIDE=1700000001 FMX_FOLLOWUP_MAX_AGE_SECS=0 \
    "$ROOT/bin/fm-x-followup.sh" --check fix-meta-k4 2>/dev/null); rc=$?
  expect_code 1 "$rc" "expired check with unusable TMPDIR exit"
  [ -z "$out" ] || fail "expired check must stay silent (got: $out)"
  assert_no_grep "x_request=" "$meta" "clear must remove request with an unusable TMPDIR"
  assert_no_grep "x_followups=" "$meta" "clear must remove the follow-up counter with an unusable TMPDIR"
  assert_grep "kind=ship" "$meta" "clear must preserve other meta lines"
  pass "meta rewrites are independent of TMPDIR"
}

test_link_rejects_unsafe_and_missing() {
  local home rc
  home="$TMP_ROOT/link-bad"; mkdir -p "$home/state"
  printf 'kind=ship\n' > "$home/state/ok.meta"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-link.sh" "../evil" req-1 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "link unsafe task id exit"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-link.sh" ok "../../etc/x" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "link unsafe request_id exit"
  assert_absent "$home/state/../evil.meta" "link must not touch meta for an unsafe id"
  # Missing meta is a hard error, not a silent create.
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-link.sh" no-such req-1 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "link missing meta exit"
  assert_absent "$home/state/no-such.meta" "link must not create meta for a non-existent task"
  # Missing arguments are a usage error.
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-link.sh" ok >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "link missing arg exit"
  pass "fm-x-link rejects unsafe ids, missing meta, and missing arguments"
}

# --- fm-x-followup: detect, post up to 3 follow-ups, manage the link --------

mk_linked_task() { # <home> <id> <request_id> <link-epoch> [starting-count]
  local home=$1 id=$2 rid=$3 ts=$4 count=${5:-} meta
  mkdir -p "$home/state"
  meta="$home/state/$id.meta"
  printf 'window=w\nworktree=/wt\nkind=ship\nmode=no-mistakes\nyolo=off\n' > "$meta"
  if [ -n "$count" ]; then
    FM_HOME="$home" FMX_NOW_OVERRIDE="$ts" "$ROOT/bin/fm-x-link.sh" "$id" "$rid" \
      --carry-count "$count" --carry-ts "$ts" --carry-platform x --carry-max 280 >/dev/null
  else
    FM_HOME="$home" FMX_NOW_OVERRIDE="$ts" "$ROOT/bin/fm-x-link.sh" "$id" "$rid" >/dev/null
  fi
}

test_followup_check_states() {
  local home out rc
  home="$TMP_ROOT/fu-check"; mkdir -p "$home/state"
  mk_linked_task "$home" task-a req-a 1700000000
  # Within window -> exit 0, prints the request_id.
  out=$(FM_HOME="$home" FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" --check task-a); rc=$?
  expect_code 0 "$rc" "check within-window exit"
  [ "$out" = "req-a" ] || fail "check within window must print the request_id (got: $out)"
  # Not linked -> exit 1, silent.
  printf 'kind=ship\n' > "$home/state/plain.meta"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" --check plain 2>/dev/null); rc=$?
  expect_code 1 "$rc" "check not-linked exit"
  [ -z "$out" ] || fail "check on a non-linked task must be silent (got: $out)"
  # Missing meta -> exit 1, silent.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" --check nope 2>/dev/null); rc=$?
  expect_code 1 "$rc" "check missing-meta exit"
  pass "fm-x-followup --check reports postable / not-linked correctly"
}

test_followup_check_expired_prunes_link() {
  local home out rc meta
  home="$TMP_ROOT/fu-check-exp"; mkdir -p "$home/state"
  mk_linked_task "$home" task-e req-e 1700000000
  meta="$home/state/task-e.meta"
  # 8 days later: past the 7-day window -> exit 1, link pruned, other lines intact.
  out=$(FM_HOME="$home" FMX_NOW_OVERRIDE=$((1700000000 + 8*86400)) \
    "$ROOT/bin/fm-x-followup.sh" --check task-e 2>/dev/null); rc=$?
  expect_code 1 "$rc" "check expired exit"
  [ -z "$out" ] || fail "check on an expired link must be silent (got: $out)"
  assert_no_grep "x_request=" "$meta" "expired check must prune the link"
  assert_grep "kind=ship" "$meta" "expired check must preserve other meta lines"
  pass "fm-x-followup --check prunes a link past the 7-day window"
}

test_followup_check_cap_reached_prunes_link() {
  local home out rc meta
  home="$TMP_ROOT/fu-check-cap"; mkdir -p "$home/state"
  # Already at the cap (3 posted) even though well within the window.
  mk_linked_task "$home" task-cap req-cap 1700000000 3
  meta="$home/state/task-cap.meta"
  out=$(FM_HOME="$home" FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" --check task-cap 2>/dev/null); rc=$?
  expect_code 1 "$rc" "check cap-reached exit"
  [ -z "$out" ] || fail "check at the cap must be silent (got: $out)"
  assert_no_grep "x_request=" "$meta" "a cap-reached check must prune the link"
  assert_grep "kind=ship" "$meta" "cap-reached check must preserve other meta lines"
  pass "fm-x-followup --check prunes a link that already reached the follow-up cap"
}

test_followup_post_increments_counter_keeps_link() {
  local home fakebin log out rc meta data
  home="$TMP_ROOT/fu-post"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  mk_linked_task "$home" task-p req-p 1700000000
  meta="$home/state/task-p.meta"
  printf 'Done, captain - build has started.' > "$home/reply.txt"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_NOW_OVERRIDE=1700003600 FAKE_CURL_LOG="$log" FAKE_FOLLOWUP_CODE=200 \
    "$ROOT/bin/fm-x-followup.sh" task-p --text-file "$home/reply.txt"); rc=$?
  expect_code 0 "$rc" "followup post exit"
  [ "$out" = "req-p" ] || fail "followup post must echo the request_id (got: $out)"
  assert_grep "url=https://relay.test/connector/followup" "$log" "post must hit the followup endpoint"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r .text)" = "Done, captain - build has started." ] \
    || fail "post must send the composed follow-up text"
  # One post under the cap must NOT clear the link - it increments the counter
  # so up to two more follow-ups can still land against the same binding.
  assert_grep "x_request=req-p" "$meta" "a post under the cap must keep the link"
  assert_grep "x_followups=1" "$meta" "a successful post must increment the follow-up counter"
  assert_grep "kind=ship" "$meta" "posting must preserve other meta lines"
  pass "fm-x-followup posts a follow-up, increments the counter, and keeps the link under the cap"
}

test_followup_post_final_clears_link_immediately() {
  local home fakebin out rc meta
  home="$TMP_ROOT/fu-post-final"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  mk_linked_task "$home" task-final req-final 1700000000
  meta="$home/state/task-final.meta"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_NOW_OVERRIDE=1700003600 FAKE_FOLLOWUP_CODE=200 \
    "$ROOT/bin/fm-x-followup.sh" task-final --final - <<<"Shipped - all green."); rc=$?
  expect_code 0 "$rc" "followup --final post exit"
  [ "$out" = "req-final" ] || fail "followup --final post must echo the request_id (got: $out)"
  assert_no_grep "x_request=" "$meta" "--final must clear the link even with follow-ups remaining under the cap"
  assert_grep "kind=ship" "$meta" "clearing the link must preserve other meta lines"
  pass "fm-x-followup --final clears the link after one post regardless of the remaining count"
}

test_followup_post_cap_reached_clears_link() {
  local home fakebin out rc meta
  home="$TMP_ROOT/fu-post-cap"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  # Two follow-ups already posted; this third one reaches the cap.
  mk_linked_task "$home" task-cap3 req-cap3 1700000000 2
  meta="$home/state/task-cap3.meta"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_NOW_OVERRIDE=1700003600 FAKE_FOLLOWUP_CODE=200 \
    "$ROOT/bin/fm-x-followup.sh" task-cap3 - <<<"Third and final update."); rc=$?
  expect_code 0 "$rc" "followup cap-reaching post exit"
  [ "$out" = "req-cap3" ] || fail "followup cap-reaching post must echo the request_id (got: $out)"
  assert_no_grep "x_request=" "$meta" "reaching the cap must clear the link even without --final"
  pass "fm-x-followup clears the link once the third follow-up reaches the cap"
}

test_followup_post_forwards_image_to_reply_client() {
  local home fakebin log out rc meta data img expected
  home="$TMP_ROOT/fu-post-image"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  img="$home/followup.png"
  make_sample_image "$img"
  expected=$(base64 < "$img" | tr -d '\n\r')
  printf 'FMX_PAIRING_TOKEN=tok-fu-img\n' > "$home/.env"
  mk_linked_task "$home" task-img req-img 1700000000
  meta="$home/state/task-img.meta"
  printf 'Done - generated image attached.' > "$home/reply.txt"
  # --final keeps this test focused on image forwarding, not counter bookkeeping.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_NOW_OVERRIDE=1700003600 FAKE_CURL_LOG="$log" FAKE_FOLLOWUP_CODE=200 \
    "$ROOT/bin/fm-x-followup.sh" task-img --image "$img" --final --text-file "$home/reply.txt"); rc=$?
  expect_code 0 "$rc" "followup wrapper image post exit"
  [ "$out" = "req-img" ] || fail "followup wrapper image post must echo the request_id (got: $out)"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r '.image.media_type')" = "image/png" ] \
    || fail "followup wrapper must forward image media_type"
  [ "$(printf '%s' "$data" | jq -r '.image.data_base64')" = "$expected" ] \
    || fail "followup wrapper must forward image base64"
  assert_no_grep "x_request=" "$meta" "a --final image followup must clear the link"
  pass "fm-x-followup --image forwards the attachment through fm-x-reply --followup"
}

test_followup_post_failure_keeps_link() {
  local home fakebin out rc meta
  home="$TMP_ROOT/fu-post-fail"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  mk_linked_task "$home" task-f req-f 1700000000
  meta="$home/state/task-f.meta"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_NOW_OVERRIDE=1700003600 FAKE_FOLLOWUP_CODE=500 \
    "$ROOT/bin/fm-x-followup.sh" task-f - <<<"retry me" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed follow-up post must exit non-zero"
  [ -z "$out" ] || fail "a failed post must not echo the request_id (got: $out)"
  assert_grep "x_request=req-f" "$meta" "a failed post must leave the link for a retry"
  assert_grep "x_followups=0" "$meta" "a failed post must not increment the follow-up counter"
  pass "fm-x-followup keeps the link and counter when the post fails"
}

test_followup_post_record_failure_clears_link() {
  local home fakebin out rc meta err flag mvflag
  home="$TMP_ROOT/fu-post-record-fail"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  flag="$home/fail-followups-write"
  mvflag="$home/mv-failed-once"
  err="$home/err.txt"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_MV_FAIL_AFTER_FLAG:-}" ] \
  && [ -f "$FAKE_MV_FAIL_AFTER_FLAG" ] \
  && [ -n "${FAKE_MV_FAILED_ONCE:-}" ] \
  && [ ! -f "$FAKE_MV_FAILED_ONCE" ]; then
  : > "$FAKE_MV_FAILED_ONCE"
  exit 2
fi
exec /bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  mk_linked_task "$home" task-rf req-rf 1700000000
  meta="$home/state/task-rf.meta"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_NOW_OVERRIDE=1700003600 FAKE_FOLLOWUP_CODE=200 FAKE_CURL_TOUCH_AFTER_POST="$flag" \
    FAKE_MV_FAIL_AFTER_FLAG="$flag" FAKE_MV_FAILED_ONCE="$mvflag" \
    "$ROOT/bin/fm-x-followup.sh" task-rf - <<<"posted but local state write fails" 2>"$err"); rc=$?
  expect_code 0 "$rc" "followup post state-record failure exit"
  [ "$out" = "req-rf" ] || fail "posted followup with tombstoned state must echo the request_id (got: $out)"
  assert_no_grep "x_request=" "$meta" "a failed counter write must tombstone the link"
  assert_no_grep "x_followups=" "$meta" "a failed counter write must remove the stale counter"
  assert_grep "cleared the link to avoid duplicate follow-ups" "$err" "state-record failure must explain the tombstone"
  pass "fm-x-followup tombstones the link when a post-success counter write fails"
}

test_followup_post_relay_rejection_degrades_gracefully() {
  local home fakebin out rc meta err
  home="$TMP_ROOT/fu-post-409"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  mk_linked_task "$home" task-409 req-409 1700000000
  meta="$home/state/task-409.meta"
  # The relay's own cap/window rejection (HTTP 409) must be treated exactly like
  # a locally-detected expiry - not a transient failure worth retrying - so an
  # old single-follow-up relay or an already-exhausted binding degrades
  # gracefully instead of leaving a link nothing will ever clear.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_NOW_OVERRIDE=1700003600 FAKE_FOLLOWUP_CODE=409 \
    "$ROOT/bin/fm-x-followup.sh" task-409 - <<<"rejected by relay" 2>"$err"); rc=$?
  expect_code 0 "$rc" "relay-rejected post exit"
  [ -z "$out" ] || fail "a relay-rejected post must echo nothing (got: $out)"
  assert_no_grep "x_request=" "$meta" "a relay rejection must clear the link"
  assert_grep "cap or window" "$err" "a relay rejection must explain itself distinctly from a generic failure"
  pass "fm-x-followup treats a relay cap/window rejection as an already-exhausted link, not a retry"
}

test_followup_post_expired_skips_and_clears() {
  local home fakebin out rc meta
  home="$TMP_ROOT/fu-post-exp"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  printf 'FMX_PAIRING_TOKEN=tok-fu\n' > "$home/.env"
  mk_linked_task "$home" task-x req-x 1700000000
  meta="$home/state/task-x.meta"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FMX_RELAY_URL="https://relay.test" \
    FMX_NOW_OVERRIDE=$((1700000000 + 8*86400)) FAKE_FOLLOWUP_CODE=200 \
    "$ROOT/bin/fm-x-followup.sh" task-x - <<<"too late" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "expired post exit"
  [ -z "$out" ] || fail "an expired post must post nothing and echo nothing (got: $out)"
  assert_no_grep "x_request=" "$meta" "an expired post must clear the link"
  assert_absent "$home/state/x-outbox/req-x.json" "an expired post must not record any reply"
  pass "fm-x-followup skips silently and clears the link past the 7-day window"
}

test_followup_post_not_linked_is_noop() {
  local home out rc
  home="$TMP_ROOT/fu-noop"; mkdir -p "$home/state"
  printf 'kind=ship\n' > "$home/state/plain.meta"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" plain - <<<"nothing to do" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "not-linked post exit"
  [ -z "$out" ] || fail "a not-linked post must be a silent no-op (got: $out)"
  assert_absent "$home/state/x-outbox" "a not-linked post must not record a reply"
  pass "fm-x-followup is a no-op for a task with no X link"
}

test_followup_post_dry_run_increments_counter_keeps_link() {
  local home out rc meta
  home="$TMP_ROOT/fu-dry"; mkdir -p "$home/state"
  mk_linked_task "$home" task-d req-d 1700000000
  meta="$home/state/task-d.meta"
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" task-d - <<<"Shipped in dry run." 2>/dev/null); rc=$?
  expect_code 0 "$rc" "dry-run post exit"
  [ "$out" = "req-d" ] || fail "dry-run post must echo the request_id (got: $out)"
  assert_present "$home/state/x-outbox/req-d.json" "dry-run post must record the would-be follow-up"
  [ "$(jq -r '.endpoint' "$home/state/x-outbox/req-d.json")" = "followup" ] \
    || fail "dry-run post preview must carry the followup endpoint marker"
  # Dry-run must mutate the counter/link exactly as a live post would: keep the
  # link and increment the counter when under the cap and --final is absent.
  assert_grep "x_request=req-d" "$meta" "dry-run under the cap must keep the link just as a live post would"
  assert_grep "x_followups=1" "$meta" "dry-run must increment the follow-up counter just as a live post would"
  pass "fm-x-followup dry-run records the follow-up and increments the counter, keeping the link"
}

test_followup_post_dry_run_final_clears_link() {
  local home out rc meta
  home="$TMP_ROOT/fu-dry-final"; mkdir -p "$home/state"
  mk_linked_task "$home" task-df req-df 1700000000
  meta="$home/state/task-df.meta"
  out=$(FM_HOME="$home" FMX_DRY_RUN=1 FMX_NOW_OVERRIDE=1700003600 \
    "$ROOT/bin/fm-x-followup.sh" task-df --final - <<<"Shipped in dry run, for real this time." 2>/dev/null); rc=$?
  expect_code 0 "$rc" "dry-run --final post exit"
  [ "$out" = "req-df" ] || fail "dry-run --final post must echo the request_id (got: $out)"
  assert_no_grep "x_request=" "$meta" "dry-run --final must clear the link just as a live --final post would"
  pass "fm-x-followup dry-run --final clears the link just as a live post would"
}

test_followup_usage_errors() {
  local home rc err out
  home="$TMP_ROOT/fu-usage"; mkdir -p "$home/state"
  err="$home/err.txt"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "followup no-args exit"
  assert_grep "--image <path>" "$err" "followup usage must mention --image"
  assert_grep "--final" "$err" "followup usage must mention --final"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" --check >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "followup --check no-id exit"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" some-task >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "followup post no-text-source exit"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" --help); rc=$?
  expect_code 0 "$rc" "followup --help exit"
  assert_contains "$out" "--image <path>" "followup help must mention --image"
  assert_contains "$out" "threaded replies attach it to the opener tweet" \
    "followup help must document thread image placement"
  assert_contains "$out" "--final" "followup help must mention --final"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" "../evil" --text-file /dev/null >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "followup unsafe-id exit"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-x-followup.sh" some-task --image >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "followup missing --image argument exit"
  assert_grep "missing --image path" "$err" "followup missing --image argument must explain the error"
  pass "fm-x-followup rejects malformed invocations"
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
test_reply_auth_header_tempfile_cleans_up_on_interrupted_post
test_reply_usage_error
test_reply_help_mentions_image
test_reply_whitespace_text_rejected
test_reply_dry_run_records_not_posts
test_reply_dry_run_needs_no_token
test_reply_dry_run_from_env_file
test_reply_empty_env_dry_run_overrides_env_file
test_reply_dry_run_fails_when_outbox_unwritable
test_split_thread_lib
test_reply_single_no_texts
test_reply_thread_dry_run
test_reply_discord_inbox_uses_discord_budget
test_reply_x_inbox_still_uses_x_budget
test_reply_inbox_explicit_limit_wins
test_reply_max_chars_floor_clamps_to_minimum
test_reply_thread_live_posts_texts
test_reply_image_live_posts_image_object
test_reply_image_live_streams_payload_file
test_reply_image_thread_dry_run_records_compact_marker
test_reply_image_dry_run_cleans_payload_temp_files
test_reply_image_path_errors_are_clear
test_reply_followup_live_posts_to_followup_endpoint
test_reply_followup_409_marker_exits_distinctly
test_reply_followup_409_without_marker_still_exits_distinctly
test_reply_answer_409_is_generic_failure
test_reply_followup_image_live_posts_image_object
test_reply_followup_flag_position_is_flexible
test_reply_followup_dry_run_marks_endpoint
test_reply_followup_thread_dry_run
test_reply_followup_image_dry_run_marks_endpoint_and_compacts_image
test_dismiss_success_posts_request_only
test_dismiss_dry_run_records_not_posts
test_dismiss_dry_run_needs_no_token
test_dismiss_non_2xx_fails
test_dismiss_transport_failure_fails
test_dismiss_unsafe_request_id_rejected
test_dismiss_usage_error
test_link_records_request_and_timestamp
test_link_records_discord_platform_for_followups
test_link_carry_count_and_ts_preserve_followup_binding
test_link_recovery_relink_carries_discord_context_after_inbox_drain
test_link_carry_count_validation
test_meta_rewrites_do_not_depend_on_tmpdir
test_link_rejects_unsafe_and_missing
test_followup_check_states
test_followup_check_expired_prunes_link
test_followup_check_cap_reached_prunes_link
test_followup_post_increments_counter_keeps_link
test_followup_post_final_clears_link_immediately
test_followup_post_cap_reached_clears_link
test_followup_post_forwards_image_to_reply_client
test_followup_post_failure_keeps_link
test_followup_post_record_failure_clears_link
test_followup_post_relay_rejection_degrades_gracefully
test_followup_post_expired_skips_and_clears
test_followup_post_not_linked_is_noop
test_followup_post_dry_run_increments_counter_keeps_link
test_followup_post_dry_run_final_clears_link
test_followup_usage_errors
test_bootstrap_activates_on_env_token
test_bootstrap_reports_missing_x_dependency
test_bootstrap_does_not_announce_when_arm_fails
test_bootstrap_inert_without_token
test_bootstrap_opt_out_cleanup
test_bootstrap_opt_out_reports_cleanup_failure
