#!/usr/bin/env bash
# Behavior tests for the direct Discord integration: OAuth state/callback,
# credential persistence, connection setup, owner-only inbound authorization
# (positive and negative), self-message filtering, dedup, chunking in
# Discord units with Relay-consistent thread numbering, API errors,
# 429 Retry-After send retries, reply payloads, slash-command
# verification enforcement, disconnect/reconnect, gateway honesty
# (--once/--print-intents), watcher shim arming/validation, and
# configuration validation.
#
# Discord API/Gateway are mocked with a fakebin `curl` (no ports, no
# server) plus file:// fixtures for the gateway lookup; live-server proof
# (real OAuth install, Gateway delivery/resume, valid-signature
# interactions, permission bits, 429 shape) is documented in
# docs/discord-integration.md. Interaction `handle` authorization shares
# `discord_authorize_sender` with the tested message path; its own
# signature-positive path needs PyNaCl/a live server and is refusal-tested
# here only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-discord-tests)

make_fake_curl() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" hfile="" ctype="" method="" posted=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -D) hfile=$2; shift 2 ;;
    -H)
      case "$2" in Content-Type:*) ctype=${2#Content-Type: } ;; esac
      shift 2 ;;
    -m|-w) shift 2 ;; -s) shift ;;
    -X) method=$2; shift 2 ;;
    --data-binary)
      case "$2" in @*) posted=$(cat -- "${2#@}") ;; *) posted=$2 ;; esac
      shift 2 ;;
    http://*|https://*|file://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then { printf 'url=%s\n' "$url"; printf 'method=%s\n' "$method"; printf 'ctype=%s\n' "$ctype"; printf 'posted=%s\n' "${posted:-}"; } >> "$FAKE_CURL_LOG"; fi
if [ -n "$hfile" ]; then printf '%s\n' "${FAKE_SEND_HEADERS:-}" > "$hfile"; fi
next_code() { # <default> -> prints code, advancing FAKE_SEND_CODES when set
  local def=$1 n=0 code
  if [ -n "${FAKE_SEND_CODES:-}" ] && [ -n "${FAKE_SEQ_FILE:-}" ]; then
    n=$(cat "$FAKE_SEQ_FILE" 2>/dev/null || printf '0')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    code=$(printf '%s' "$FAKE_SEND_CODES" | tr ' ' '\n' | sed -n "$((n + 1))p")
    printf '%s' "$((n + 1))" > "$FAKE_SEQ_FILE"
    [ -n "$code" ] || code="$def"
    printf '%s' "$code"
  else
    printf '%s' "$def"
  fi
}
case "$url" in
  */oauth2/token) printf '%s' "${FAKE_TOKEN_BODY:-{\"guild\":{\"id\":\"g1\"}}}" > "$ofile"; printf '%s' "${FAKE_TOKEN_CODE:-200}" ;;
  */users/@me) printf '%s' "${FAKE_ME_BODY:-{\"id\":\"bot1\",\"username\":\"fm\"}}" > "$ofile"; printf '%s' "${FAKE_ME_CODE:-200}" ;;
  */guilds/g1) printf '%s' "${FAKE_GUILD_BODY:-{\"id\":\"g1\",\"name\":\"Test\"}}" > "$ofile"; printf '%s' "${FAKE_GUILD_CODE:-200}" ;;
  */guilds/*) printf '{}' > "$ofile"; printf '%s' "${FAKE_GUILD_CODE:-404}" ;;
  */applications/*/commands) printf '[]' > "$ofile"; printf '%s' "${FAKE_CMDS_CODE:-200}" ;;
  */channels/*/messages*)
    if [ "${FAKE_SEND_MODE:-}" = record ]; then
      cat "$ofile" >/dev/null 2>&1 || true
      if [ -n "${FAKE_POST_DIR:-}" ]; then
        mkdir -p "$FAKE_POST_DIR" 2>/dev/null || true
        n=$(ls "$FAKE_POST_DIR"/post-*.json 2>/dev/null | wc -l | tr -d ' ')
        printf '%s' "${posted:-}" > "$FAKE_POST_DIR/post-$n.json"
      fi
      printf '%s' "${FAKE_SEND_BODY:-{\"id\":\"m1\"}}" > "$ofile"
      next_code "${FAKE_SEND_CODE:-200}"
    else
      printf '%s' "${FAKE_MSGS_BODY:-[]}" > "$ofile"; printf '%s' "${FAKE_MSGS_CODE:-200}"
    fi ;;
  *) printf '{}' > "$ofile"; printf '200' ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

make_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state"
  printf 'DISCORD_CLIENT_ID=cid\nDISCORD_CLIENT_SECRET=sec\nDISCORD_BOT_TOKEN=tok1234567890\nDISCORD_GUILD_ID=g1\nDISCORD_OWNER_USER_ID=u9\nDISCORD_REDIRECT_URI=http://localhost:8787/discord/callback\n' > "$home/.env"
  printf '%s\n' "$home"
}

# 1. OAuth state validation: single-use, mismatch refused, state never printed
home="$TMP_ROOT/state-home"; make_home "$home" >/dev/null
fakebin=$(make_fake_curl "$home")
s=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-setup.sh" init --redirect http://localhost:8787/discord/callback 2>"$TMP_ROOT/init.err") || fail "init failed"
assert_contains "$s" "discord.com/oauth2/authorize" "init prints OAuth URL"
assert_contains "$s" "scope=bot" "init requests minimal scopes"
assert_contains "$s" "permissions=67584" "init requests minimal permission bits"
assert_no_grep "state=" "$TMP_ROOT/init.err" "state token never printed"
stored=$(cat "$home/state/discord-oauth/state")
[ -n "$stored" ] || fail "state token persisted"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-setup.sh" callback --code c --state bad --guild g1 2>/dev/null && fail "bad state must be refused"
pass "oauth state validation"

# 2. Callback + credential persistence + verify + status + state single-use
export FAKE_TOKEN_BODY='{"access_token":"user-tok","guild":{"id":"g1"}}' FAKE_TOKEN_CODE=200 FAKE_ME_CODE=200 FAKE_GUILD_CODE=200
rm -f "$TMP_ROOT/cb.log"
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" FAKE_CURL_LOG="$TMP_ROOT/cb.log" "$ROOT/bin/fm-discord-setup.sh" callback --code c --state "$stored" --guild g1 2>&1) || fail "callback failed: $out"
assert_contains "$out" "connected" "callback connects"
assert_grep "ctype=application/x-www-form-urlencoded" "$TMP_ROOT/cb.log" "token exchange is form-encoded"
assert_grep "grant_type=authorization_code" "$TMP_ROOT/cb.log" "exchange carries the authorization code grant"
assert_no_grep "tok1234567890" "$TMP_ROOT/cb.log" "bot token never sent to the OAuth endpoint"
assert_no_grep "\"client_secret\"" "$TMP_ROOT/cb.log" "no JSON secret body on the token exchange"
[ "$(stat -c %a "$home/config/discord.json" 2>/dev/null || stat -f %Lp "$home/config/discord.json")" = 600 ] || fail "config is mode 600"
assert_no_grep "tok1234567890" "$home/config/discord.json" "bot token never persisted to config"
assert_grep '"owner_user_id": "u9"' "$home/config/discord.json" "owner persisted from configuration"
assert_grep '"bot_user_id": "bot1"' "$home/config/discord.json" "resolved bot id persisted"
[ -e "$home/state/discord-oauth/state" ] && fail "state must be single-use (consumed by callback)"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-setup.sh" callback --code c --state "$stored" --guild g1 2>/dev/null && fail "replayed state must be refused"
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-setup.sh" status) || fail "status failed"
assert_contains "$out" "connected" "status shows connected"
assert_contains "$out" "owner=set" "status shows owner configured"
pass "callback persistence verify status"

# 3. Incoming routing: owner positive, intruder/guild/self refused, dedup,
#    contentless dropped before claim, unknown-owner and unknown-bot refused
cat > "$TMP_ROOT/evt.json" <<'JSON'
{"t":"MESSAGE_CREATE","d":{"id":"m1","guild_id":"g1","channel_id":"c1","author":{"id":"u9","bot":false},"content":"hello","timestamp":"2026-01-01T00:00:00.000Z","message_reference":{"message_id":"m0","channel_id":"c1"}}}
JSON
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/evt.json") || fail "event routing failed"
assert_contains "$out" "discord-message m1" "owner message wakes"
[ -f "$home/state/discord-inbox/m1.json" ] || fail "inbox stash missing"
assert_grep '"guild_id": "g1"' "$home/state/discord-inbox/m1.json" "guild preserved"
assert_grep '"user_id": "u9"' "$home/state/discord-inbox/m1.json" "author preserved"
assert_grep '"reply_context"' "$home/state/discord-inbox/m1.json" "reply context preserved"
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/evt.json") || fail "dup poll failed"
[ -z "$out" ] || fail "duplicate must be silent"
cat > "$TMP_ROOT/intruder.json" <<'JSON'
{"t":"MESSAGE_CREATE","d":{"id":"m-int","guild_id":"g1","channel_id":"c1","author":{"id":"u666","bot":false},"content":"let me in","timestamp":"2026-01-01T00:00:01.000Z"}}
JSON
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/intruder.json" 2>/dev/null) || fail "intruder poll failed"
[ -z "$out" ] || fail "non-owner must be refused silently"
[ -e "$home/state/discord-inbox/m-int.json" ] && fail "non-owner must never stash"
cat > "$TMP_ROOT/self.json" <<'JSON'
{"t":"MESSAGE_CREATE","d":{"id":"m2","guild_id":"g1","channel_id":"c1","author":{"id":"bot1","bot":true},"content":"mine","timestamp":"2026-01-01T00:00:01.000Z"}}
JSON
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/self.json") || fail "self poll failed"
[ -z "$out" ] || fail "self messages ignored"
cat > "$TMP_ROOT/other.json" <<'JSON'
{"t":"MESSAGE_CREATE","d":{"id":"m3","guild_id":"evil","channel_id":"c1","author":{"id":"u9"},"content":"hi","timestamp":"2026-01-01T00:00:02.000Z"}}
JSON
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/other.json" 2>/dev/null) || fail "guild poll failed"
[ -z "$out" ] || fail "foreign guild refused"
cat > "$TMP_ROOT/empty.json" <<'JSON'
{"t":"MESSAGE_CREATE","d":{"id":"m-empty","guild_id":"g1","channel_id":"c1","author":{"id":"u9"},"content":"","timestamp":"2026-01-01T00:00:03.000Z"}}
JSON
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/empty.json" 2>/dev/null) || fail "empty poll failed"
[ -z "$out" ] || fail "contentless message dropped"
[ -e "$home/state/discord-seen/m-empty" ] && fail "contentless must not claim the dedup marker"
# A home with no owner configured refuses everything, loudly enough to fix.
noowner="$TMP_ROOT/noowner-home"; make_home "$noowner" >/dev/null
sed -i '' '/DISCORD_OWNER_USER_ID/d' "$noowner/.env" 2>/dev/null || sed -i '/DISCORD_OWNER_USER_ID/d' "$noowner/.env"
printf '{"connected":true,"guild_id":"g1","bot_user_id":"bot1","owner_user_id":""}\n' > "$noowner/config/discord.json"
out=$(FM_HOME="$noowner" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/evt.json" 2>"$TMP_ROOT/noowner.err") || fail "no-owner poll failed"
[ -z "$out" ] || fail "unknown owner configuration must refuse"
assert_contains "$(cat "$TMP_ROOT/noowner.err")" "OWNER_USER_ID" "missing owner gets a diagnostic"
# A home whose bot id is still unknown refuses to poll at all.
nobid="$TMP_ROOT/nobid-home"; make_home "$nobid" >/dev/null
out=$(FM_HOME="$nobid" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/evt.json" 2>"$TMP_ROOT/nobid.err") || fail "no-bot-id poll failed"
[ -z "$out" ] || fail "unknown bot id must refuse to poll"
assert_contains "$(cat "$TMP_ROOT/nobid.err")" "bot user id unknown" "missing bot id gets a diagnostic"
pass "incoming routing authorization self-filter guild guard"

# 4. Outbound: send + unit-safe chunking + numbering + reply payload
export FAKE_SEND_MODE=record FAKE_SEND_CODE=200
unset FAKE_SEND_CODES FAKE_SEND_HEADERS
export FAKE_POST_DIR="$TMP_ROOT/posts" FAKE_SEQ_FILE="$TMP_ROOT/seq"
rm -rf "$FAKE_POST_DIR"; mkdir -p "$FAKE_POST_DIR"; printf '0' > "$FAKE_SEQ_FILE"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-send.sh" c1 hello >/dev/null || fail "send failed"
[ "$(find "$FAKE_POST_DIR" -maxdepth 1 -type f -name 'post-*.json' | wc -l | tr -d ' ')" = 1 ] || fail "single send posts once"
python3 - "$FAKE_POST_DIR/post-0.json" <<'PY' || fail "single send must be unnumbered"
import json, sys
body = json.load(open(sys.argv[1]))
assert " (1/1)" not in body["content"], "single message stays unnumbered"
PY
long=$(python3 -c 'print("ab " * 1500)')
rm -rf "$FAKE_POST_DIR"; mkdir -p "$FAKE_POST_DIR"; printf '0' > "$FAKE_SEQ_FILE"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-send.sh" c1 --reply-to m1 "$long" > "$TMP_ROOT/send.out" 2>&1 || fail "long send failed"
assert_contains "$(cat "$TMP_ROOT/send.out")" "message(s)" "chunked send reports count"
n=$(grep -oE 'sent [0-9]+' "$TMP_ROOT/send.out" | grep -oE '[0-9]+')
[ "$n" -gt 1 ] || fail "long response must chunk, not truncate (got $n)"
python3 - "$FAKE_POST_DIR" "$n" <<'PY' || fail "chunk contract violated"
import glob, json, os, re, sys
posts = sorted(glob.glob(os.path.join(sys.argv[1], "post-*.json")))
assert len(posts) == int(sys.argv[2]), "one post per chunk"
first = json.load(open(posts[0]))
assert first["message_reference"]["message_id"] == "m1", "reply-to rides the first chunk"
assert first["allowed_mentions"] == {"replied_user": False}, "reply suppresses the ping"
for i, p in enumerate(posts):
    body = json.load(open(p))
    m = re.search(r" \((\d+)/(\d+)\)$", body["content"])
    assert m and int(m.group(2)) == len(posts) and int(m.group(1)) == i + 1, "Relay-style (k/n) suffix"
    units = len(body["content"]) + sum(ord(c) > 0xFFFF for c in body["content"])
    assert units <= 2000, "chunk exceeds Discord units"
    if i:
        assert body["allowed_mentions"] == {"parse": []}, "follow-ups suppress all mentions"
PY
# Every chunk the splitter emits must fit Discord's 2000-unit limit, in
# units (astral characters count double) and losslessly.
python3 - "$ROOT/bin/fm-discord-lib.sh" <<'PY' || fail "chunk over budget"
import json, subprocess, sys
lib = sys.argv[1]
text = "ab " * 1500 + "\U0001F600" * 200
p = subprocess.run(["bash", "-c", f'. "{lib}" && printf "%s" "$0" | discord_chunk_text 1990', text],
                   capture_output=True, text=True)
chunks = json.loads(p.stdout)
assert len(chunks) > 1, "expected multiple chunks"
for c in chunks:
    units = len(c) + sum(ord(ch) > 0xFFFF for ch in c)
    assert units <= 1990, "chunk over unit budget"
assert " ".join(chunks).split() == text.split(), "chunking lost words"
PY
pass "outbound send chunking numbering reply"

# 5. API errors, permission failures, rate-limit silence, 429 send retry
unset FAKE_SEND_CODES FAKE_SEND_HEADERS
export FAKE_SEND_CODE=403
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-send.sh" c1 hi 2>"$TMP_ROOT/err.log" && fail "403 must fail"
assert_contains "$(cat "$TMP_ROOT/err.log")" "permission failure" "permission surfaced"
export FAKE_MSGS_CODE=403
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --channel c1 --once 2>"$TMP_ROOT/perr.log"; rc=$?
[ "$rc" = 0 ] || fail "poll permission failure must stay silent rc=0"
assert_contains "$(cat "$TMP_ROOT/perr.log")" "permission failure" "poll permission logged"
export FAKE_MSGS_CODE=429
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --channel c1 --once >/dev/null || fail "429 must be silent success"
export FAKE_MSGS_CODE=200 FAKE_SEND_CODE=200 FAKE_SEND_CODES="429 200" FAKE_SEND_HEADERS="Retry-After: 0"
rm -rf "$FAKE_POST_DIR"; mkdir -p "$FAKE_POST_DIR"; printf '0' > "$FAKE_SEQ_FILE"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-send.sh" c1 retry-me >/dev/null 2>"$TMP_ROOT/retry.err" || fail "429-then-200 must succeed: $(cat "$TMP_ROOT/retry.err")"
[ "$(find "$FAKE_POST_DIR" -maxdepth 1 -type f -name 'post-*.json' | wc -l | tr -d ' ')" = 2 ] || fail "rate-limited send retried exactly once"
unset FAKE_SEND_CODES FAKE_SEND_HEADERS
pass "api errors rate-limit permission failures"

# 6. Slash commands: PUT registration, verification enforcement, refusals
export FAKE_CMDS_CODE=200
rm -f "$TMP_ROOT/cmds.log"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" FAKE_CURL_LOG="$TMP_ROOT/cmds.log" "$ROOT/bin/fm-discord-commands.sh" register >/dev/null || fail "register failed"
assert_grep "method=PUT" "$TMP_ROOT/cmds.log" "command registration uses PUT"
jq -n '{id:"i-ping", type:1}' > "$TMP_ROOT/ping.json"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-commands.sh" handle --interaction-file "$TMP_ROOT/ping.json" 2>/dev/null && fail "unverified interaction must be refused"
jq -n '{id:"i1", type:2, guild_id:"g1", member:{user:{id:"u9"}}, data:{name:"firstmate", options:[{name:"ask", options:[{name:"question", value:"hi"}]}]}}' > "$TMP_ROOT/inter.json"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-commands.sh" handle --interaction-file "$TMP_ROOT/inter.json" 2>/dev/null && fail "handle without signature must be refused"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-commands.sh" verify --signature dead --timestamp 1 --body-file "$TMP_ROOT/ping.json" 2>/dev/null && fail "verify without public key must refuse"
export DISCORD_PUBLIC_KEY=deadbeef
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-commands.sh" verify --signature dead --timestamp 1 --body-file "$TMP_ROOT/ping.json" 2>"$TMP_ROOT/stale.err" && fail "stale timestamp must be refused"
assert_contains "$(cat "$TMP_ROOT/stale.err")" "stale" "replay guard names the stale timestamp"
unset DISCORD_PUBLIC_KEY
jq -n '{id:"i-bad", type:2, data:{name:"firstmate", options:[{name:"nuke"}]}}' > "$TMP_ROOT/badsub.json"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-commands.sh" handle --interaction-file "$TMP_ROOT/badsub.json" 2>/dev/null && fail "unverified subcommand probing must be refused"
pass "slash commands verification enforcement"

# 7. Disconnect/reconnect
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-setup.sh" disconnect >/dev/null || fail "disconnect failed"
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-setup.sh" status)
assert_contains "$out" "disconnected" "status shows disconnected"
export FAKE_GUILD_CODE=200
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-setup.sh" verify --guild g1 >/dev/null || fail "reconnect verify failed"
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-setup.sh" status)
assert_contains "$out" "connected" "reconnect restores connected"
pass "disconnect reconnect"

# 8. Gateway honesty: secret hygiene, unconfigured refusal, intents, .env loading
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" env -u DISCORD_BOT_TOKEN python3 "$ROOT/bin/fm-discord-gateway.py" --once 2>&1 || true)
assert_not_contains "$out" "tok1234567890" "gateway never logs token"
empty="$TMP_ROOT/empty-home"; mkdir -p "$empty/config" "$empty/state"; printf '# no discord here\n' > "$empty/.env"
env -u DISCORD_BOT_TOKEN FM_HOME="$empty" python3 "$ROOT/bin/fm-discord-gateway.py" --once 2>"$TMP_ROOT/once.err" && fail "unconfigured --once must not succeed"
assert_contains "$(cat "$TMP_ROOT/once.err")" "not configured" "--once reports not configured instead of inert success"
[ "$(env -u DISCORD_BOT_TOKEN DISCORD_MESSAGE_CONTENT= FM_HOME="$empty" python3 "$ROOT/bin/fm-discord-gateway.py" --print-intents)" = 513 ] || fail "default intents are GUILDS|GUILD_MESSAGES"
[ "$(env -u DISCORD_BOT_TOKEN FM_HOME="$empty" DISCORD_MESSAGE_CONTENT=1 python3 "$ROOT/bin/fm-discord-gateway.py" --print-intents)" = 33281 ] || fail "message-content opt-in adds only 1<<15"
printf 'DISCORD_MESSAGE_CONTENT=1\n' > "$empty/.env"
[ "$(env -u DISCORD_BOT_TOKEN DISCORD_MESSAGE_CONTENT= FM_HOME="$empty" python3 "$ROOT/bin/fm-discord-gateway.py" --print-intents)" = 33281 ] || fail "gateway reads .env with env-wins semantics"
mkdir -p "$TMP_ROOT/api/gateway"
printf '{"session_start_limit":{"remaining":999}}' > "$TMP_ROOT/api/gateway/bot"
out=$(env -u DISCORD_BOT_TOKEN FM_HOME="$home" DISCORD_API_BASE="file://$TMP_ROOT/api" python3 "$ROOT/bin/fm-discord-gateway.py" --once 2>"$TMP_ROOT/fileonce.err") || fail "file-backed gateway lookup failed: $(cat "$TMP_ROOT/fileonce.err")"
assert_contains "$out" "gateway ok" "--once reports a healthy lookup"
assert_not_contains "$out" "tok1234567890" "gateway lookup never logs token"
pass "gateway honesty intents dotenv"

# 9. Watcher arming: shim + cadence gated on the token, validated, removed on opt-out
arm="$TMP_ROOT/arm-home"; make_home "$arm" >/dev/null
FM_HOME="$arm" FM_ROOT="$ROOT" bash -c '. "$0/bin/fm-discord-lib.sh" && discord_mode_setup' "$ROOT" > "$TMP_ROOT/arm.out" || fail "arming failed"
assert_contains "$(cat "$TMP_ROOT/arm.out")" "Discord mode on" "arming confirms"
[ -f "$arm/state/discord-watch.check.sh" ] || fail "shim armed"
[ -f "$arm/config/discord-mode.env" ] || fail "cadence armed"
assert_grep "FM_CHECK_INTERVAL=30" "$arm/config/discord-mode.env" "cadence is 30s"
FM_HOME="$arm" FM_ROOT="$ROOT" bash -c '. "$0/bin/fm-discord-lib.sh" && discord_poll_shim_valid "$1/state/discord-watch.check.sh" "$1" "$0"' "$ROOT" "$arm" || fail "shim must validate"
printf 'tampered' > "$arm/state/discord-watch.check.sh"
FM_HOME="$arm" FM_ROOT="$ROOT" bash -c '. "$0/bin/fm-discord-lib.sh" && discord_poll_shim_valid "$1/state/discord-watch.check.sh" "$1" "$0"' "$ROOT" "$arm" 2>/dev/null && fail "tampered shim must not validate"
noarm="$TMP_ROOT/noarm-home"; mkdir -p "$noarm/config" "$noarm/state"; printf '# empty\n' > "$noarm/.env"
printf 'stale' > "$noarm/state/discord-watch.check.sh"; printf 'stale' > "$noarm/config/discord-mode.env"
FM_HOME="$noarm" FM_ROOT="$ROOT" bash -c '. "$0/bin/fm-discord-lib.sh" && discord_mode_setup' "$ROOT" > "$TMP_ROOT/noarm.out" || fail "opt-out failed"
[ -e "$noarm/state/discord-watch.check.sh" ] && fail "opt-out removes the shim"
[ -e "$noarm/config/discord-mode.env" ] && fail "opt-out removes the cadence"
pass "watcher arming validation opt-out"

# 10. Configuration validation: incomplete refused, complete accepted
FM_HOME="$nobid" FM_ROOT="$ROOT" bash -c '. "$0/bin/fm-discord-lib.sh" && discord_validate_config' "$ROOT" 2>/dev/null && fail "incomplete config must not validate"
FM_HOME="$home" FM_ROOT="$ROOT" bash -c '. "$0/bin/fm-discord-lib.sh" && discord_validate_config' "$ROOT" 2>/dev/null || fail "complete config must validate"
pass "configuration validation"

# 11. Relay-style outbound-only reply path: gateway INTERACTION_CREATE needs
# no signature and answers via the REST callback; !fm message equivalents
# need no interaction delivery; nothing listens on a socket.
unset FAKE_SEND_MODE FAKE_SEND_CODES FAKE_SEND_HEADERS FAKE_MSGS_CODE
jq -n '{t:"INTERACTION_CREATE", d:{id:"gw-i1", token:"gw-tok-1", type:2, guild_id:"g1", member:{user:{id:"u9"}}, data:{name:"firstmate", options:[{name:"ask", options:[{name:"question", value:"gateway hello"}]}]}}}' > "$TMP_ROOT/gw-inter.json"
rm -f "$TMP_ROOT/gw-cb.log"
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" FAKE_CURL_LOG="$TMP_ROOT/gw-cb.log" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/gw-inter.json") || fail "gateway interaction routing failed: $out"
assert_contains "$out" "discord-command gw-i1 ask" "gateway INTERACTION_CREATE wakes without any signature"
[ -f "$home/state/discord-inbox/gw-i1.json" ] || fail "gateway interaction stashed"
assert_grep '"firstmate_command": "ask"' "$home/state/discord-inbox/gw-i1.json" "interaction subcommand preserved"
assert_grep "interactions/gw-i1/gw-tok-1/callback" "$TMP_ROOT/gw-cb.log" "answer goes out through the REST interaction callback"
assert_grep '"type": 4' "$TMP_ROOT/gw-cb.log" "callback answers with a type-4 channel message"
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/gw-inter.json") || fail "dup interaction poll failed"
[ -z "$out" ] || fail "duplicate interaction must be silent"
jq -n '{id:"i-ping", type:1}' > "$TMP_ROOT/gw-ping.json"
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-commands.sh" handle --gateway --interaction-file "$TMP_ROOT/gw-ping.json") || fail "gateway PING failed"
[ -z "$out" ] || fail "gateway PING needs no callback and no wake"
FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-commands.sh" handle --interaction-file "$TMP_ROOT/gw-ping.json" 2>/dev/null && fail "non-gateway handle must stay refused"
jq -n '{t:"INTERACTION_CREATE", d:{id:"gw-evil", token:"t", type:2, guild_id:"evil", member:{user:{id:"u9"}}, data:{name:"firstmate", options:[{name:"status"}]}}}' > "$TMP_ROOT/gw-evil.json"
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-commands.sh" handle --gateway --interaction-file "$TMP_ROOT/gw-evil.json" 2>/dev/null; echo "rc=$?")
# handle --gateway on a foreign guild must refuse (non-zero) with no wake.
case "$out" in *"discord-command"*) fail "foreign-guild interaction must be refused" ;; esac
[ -e "$home/state/discord-inbox/gw-evil.json" ] && fail "foreign-guild interaction must never stash"
cat > "$TMP_ROOT/fm-ask.json" <<'JSON'
{"t":"MESSAGE_CREATE","d":{"id":"m-cmd1","guild_id":"g1","channel_id":"c1","author":{"id":"u9","bot":false},"content":"!fm ask what is the status","timestamp":"2026-01-01T00:00:00.000Z"}}
JSON
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/fm-ask.json") || fail "message command routing failed"
assert_contains "$out" "discord-command cmd-m-cmd1 ask" "!fm ask wakes as a command without interaction delivery"
assert_grep '"question": "what is the status"' "$home/state/discord-inbox/cmd-m-cmd1.json" "message-command question preserved"
[ -e "$home/state/discord-inbox/m-cmd1.json" ] && fail "command message must not also stash as a plain message"
cat > "$TMP_ROOT/fm-status.json" <<'JSON'
{"t":"MESSAGE_CREATE","d":{"id":"m-cmd2","guild_id":"g1","channel_id":"c1","author":{"id":"u9","bot":false},"content":"!fm status","timestamp":"2026-01-01T00:00:01.000Z"}}
JSON
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/fm-status.json") || fail "message status routing failed"
assert_contains "$out" "discord-command cmd-m-cmd2 status" "!fm status wakes as a command"
cat > "$TMP_ROOT/fm-intruder.json" <<'JSON'
{"t":"MESSAGE_CREATE","d":{"id":"m-cmd3","guild_id":"g1","channel_id":"c1","author":{"id":"u666","bot":false},"content":"!fm status","timestamp":"2026-01-01T00:00:02.000Z"}}
JSON
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/fm-intruder.json" 2>/dev/null) || fail "intruder command poll failed"
[ -z "$out" ] || fail "non-owner !fm command must be refused silently"
[ -e "$home/state/discord-inbox/cmd-m-cmd3.json" ] && fail "non-owner command must never stash"
cat > "$TMP_ROOT/plain.json" <<'JSON'
{"t":"MESSAGE_CREATE","d":{"id":"m-plain","guild_id":"g1","channel_id":"c1","author":{"id":"u9","bot":false},"content":"just chatting","timestamp":"2026-01-01T00:00:03.000Z"}}
JSON
out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-poll.sh" --event-file "$TMP_ROOT/plain.json") || fail "plain message poll failed"
assert_contains "$out" "discord-message m-plain" "plain messages still route as messages"
pass "relay-style outbound-only reply path"

# 12. Outbound tap: exactly three classes send, routine stays silent,
# one message per event (send-once dedup), owner mentioned, secrets redacted.
export FAKE_SEND_MODE=record FAKE_SEND_CODE=200
unset FAKE_SEND_CODES FAKE_SEND_HEADERS
taphome="$TMP_ROOT/tap-home"; make_home "$taphome" >/dev/null
printf 'DISCORD_CHANNEL_ID=c1\n' >> "$taphome/.env"
export FAKE_POST_DIR="$TMP_ROOT/tap-posts" FAKE_SEQ_FILE="$TMP_ROOT/tap-seq"
rm -rf "$FAKE_POST_DIR"; mkdir -p "$FAKE_POST_DIR"; printf '0' > "$FAKE_SEQ_FILE"
FM_HOME="$taphome" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-notify.sh" --event tap-dec1 --class decision --text "Need your call on the shape" --decision-key nm-1-x >/dev/null || fail "tap decision send failed"
FM_HOME="$taphome" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-notify.sh" --event tap-dec1 --class decision --text "Need your call on the shape" --decision-key nm-1-x >/dev/null || fail "tap repeat must be silent success"
[ "$(find "$FAKE_POST_DIR" -maxdepth 1 -type f -name 'post-*.json' | wc -l | tr -d ' ')" = 1 ] || fail "re-wake for the same decision must not resend"
python3 - "$FAKE_POST_DIR/post-0.json" <<'PY' || fail "tap message contract violated"
import json, sys
body = json.load(open(sys.argv[1]))
assert "<@u9>" in body["content"], "owner mention pings the phone"
assert "nm-1-x" in body["content"], "decision key rides along"
assert body.get("allowed_mentions", {}).get("users") == ["u9"], "owner mention must parse so the phone pings"
PY
FM_HOME="$taphome" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-notify.sh" --event tap-r1 --wake-line "heartbeat: all quiet" --text "routine progress" >/dev/null || fail "routine wake failed"
[ "$(find "$FAKE_POST_DIR" -maxdepth 1 -type f -name 'post-*.json' | wc -l | tr -d ' ')" = 1 ] || fail "routine progress must stay silent"
FM_HOME="$taphome" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-notify.sh" --event tap-b1 --wake-line "task failed checks" --text "Build broke" --link "https://example.com/pr/5" >/dev/null || fail "tap blocker send failed"
FM_HOME="$taphome" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-notify.sh" --event tap-c1 --wake-line "review ready for PR" --text "Fix ready for review" --link "https://example.com/pr/6" >/dev/null || fail "tap completion send failed"
[ "$(find "$FAKE_POST_DIR" -maxdepth 1 -type f -name 'post-*.json' | wc -l | tr -d ' ')" = 3 ] || fail "blocker and completion classes must each send once"
# Failed sends release the dedup marker so a retry can still deliver.
export FAKE_SEND_CODE=403
FM_HOME="$taphome" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-notify.sh" --event tap-retry --class blocker --text "Outage" 2>/dev/null && fail "failed send must exit non-zero"
[ -e "$taphome/state/discord-notify/tap-retry" ] && fail "failed send must release the dedup marker"
export FAKE_SEND_CODE=200
FM_HOME="$taphome" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-discord-notify.sh" --event tap-retry --class blocker --text "Outage" >/dev/null || fail "retry after failure must send"
pass "outbound tap send-once owner-mention routine-silent"

pass "fm-discord"
