#!/usr/bin/env bash
# Outward Telegram notifications: the properties that make the feature safe to
# add to a home that is already landing work.
#
#   (a) Automatic paths in an unconfigured home are unchanged and silent.
#   (b) Publishers make NO network call, so a Telegram outage cannot block a
#       PR registration, a merge record, or the cleanup gate that refuses to
#       remove a child while its outcome is undelivered.
#   (c) A card is built from typed fields and can never be built by forwarding
#       a parent-channel or status line.
#   (d) A card carrying a credential value is refused, loudly.
#   (e) Internal identifiers AGENTS.md section 9 forbids do not reach a card.
#   (f) The bot sends and never listens: a full drain asks Telegram for nothing.
#   (g) An outage retries silently; a rejected token reports once, not per poll.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

SEND="$ROOT/bin/fm-telegram-send.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
RECONCILE="$ROOT/bin/fm-inactive-reconcile.sh"
MERGE_OUTCOME="$ROOT/bin/fm-merge-outcome-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram)
BASE_PATH=$PATH
# A distinctive value so a card that leaked it is unmistakable in an assertion.
BOT_TOKEN='123456:AA-fixture-bot-token-never-real'

API_PID=
cleanup() {
  [ -z "$API_PID" ] || kill "$API_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- fixtures ---------------------------------------------------------------

make_home() {  # <name> [configured]
  local name=$1 configured=${2:-configured} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" \
    "$dir/wt" "$dir/project" "$dir/fakebin" "$dir/root/bin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/root/bin/fm-guard.sh"
  if [ "$configured" = configured ]; then
    printf '%s\n' "$BOT_TOKEN" > "$dir/token"
    chmod 0600 "$dir/token"
    printf '4242\n' > "$dir/home/config/telegram-chat-id"
    printf '%s\n' "$dir/token" > "$dir/home/config/telegram-token-path"
  fi
  printf '%s\n' "$dir"
}

# The fake Telegram API. Every request is logged with its method and path, so a
# case can assert not only what was sent but that nothing else was ever asked
# for - which is how "the bot never listens" is proven rather than asserted.
start_api() {  # <dir>
  local dir=$1 port
  : > "$dir/api.log"
  printf 'ok\n' > "$dir/api.mode"
  cat > "$dir/api.py" <<'PY'
import http.server
import pathlib
import sys
import threading

root = pathlib.Path(sys.argv[1])
log = root / "api.log"
mode_file = root / "api.mode"
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def _handle(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        with lock:
            with log.open("a", encoding="utf-8") as fh:
                fh.write(f"{method} {self.path} {body}\n")
        mode = mode_file.read_text(encoding="utf-8").strip() or "ok"
        if mode == "401":
            payload, code = b'{"ok":false,"error_code":401}', 401
        elif mode == "500":
            payload, code = b'{"ok":false}', 500
        elif mode == "notok":
            payload, code = b'{"ok":false,"description":"chat not found"}', 200
        elif mode == "spaced":
            payload, code = b'{"ok": true}', 200
        elif mode == "reordered":
            payload, code = b'{"result":{},"ok":true}', 200
        elif mode == "malformed":
            payload, code = b'{"ok":true,', 200
        else:
            payload, code = b'{"ok":true,"result":{"message_id":1}}', 200
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        self._handle("POST")

    def do_GET(self):
        self._handle("GET")

    def log_message(self, *_args):
        return


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
  # The server must not inherit this script's stdout: a runner that pipes the
  # suite would then wait on the server for end-of-input long after the last
  # case passed. It publishes its port to a file instead.
  local waited=0
  : > "$dir/api.port"
  python3 "$dir/api.py" "$dir" > "$dir/api.port" 2> "$dir/api.err" < /dev/null &
  API_PID=$!
  while [ "$waited" -lt 100 ]; do
    port=$(head -1 "$dir/api.port" 2>/dev/null || true)
    [ -z "$port" ] || break
    kill -0 "$API_PID" 2>/dev/null || fail "the fake Telegram API exited: $(cat "$dir/api.err")"
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -n "$port" ] || fail "the fake Telegram API did not report a port"
  printf 'http://127.0.0.1:%s\n' "$port"
}

stop_api() {
  [ -z "$API_PID" ] || kill "$API_PID" 2>/dev/null || true
  [ -z "$API_PID" ] || wait "$API_PID" 2>/dev/null || true
  API_PID=
}

# Publish through the seam exactly as a publisher does, and print nothing but
# what the library wrote to stderr.
report() {  # <dir> <line> [card args...]
  local dir=$1
  shift
  FM_CONFIG_OVERRIDE="$dir/home/config" \
    bash -c '. "$1"; shift; fm_parent_channel_report "$@"' _ \
    "$ROOT/bin/fm-parent-channel-lib.sh" "$dir/home" "$dir/home/state" "$@"
}

render() {  # <class> <name=value>...
  bash -c '. "$1"; shift; fm_telegram_card_render "$@"' _ \
    "$ROOT/bin/fm-telegram-lib.sh" "$@"
}

run_send() {  # <dir> <api-base-or-empty> [args...]
  local dir=$1 base=$2
  shift 2
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TELEGRAM_API_BASE="$base" PATH="$dir/fakebin:$BASE_PATH" \
    "$SEND" "$@"
}

cards_in() {  # <dir>
  local card
  for card in "$1"/home/state/telegram-outbox/*.card; do
    [ -f "$card" ] || continue
    printf '%s\n' "$card"
  done
}

card_count() {  # <dir>
  cards_in "$1" | grep -c . || true
}

only_card() {  # <dir>
  local n
  n=$(card_count "$1")
  [ "$n" = 1 ] || fail "expected exactly one queued card, found $n"
  cards_in "$1" | head -1
}

# --- cases ------------------------------------------------------------------

test_unconfigured_home_is_inert() {
  local dir out rc=0
  dir=$(make_home inert unconfigured)
  out=$(report "$dir" "needs-decision [key=captain-hold-x-1]: captain hold x: pick one" \
    decision captain-hold-x-1 "title=Pick a database" "reason=postgres or sqlite" 2>&1) || rc=$?
  # A main home has no parent channel: rc 1 is exactly today's answer.
  [ "$rc" -eq 1 ] || fail "an unconfigured main home changed its publish result (rc=$rc)"
  [ -z "$out" ] || fail "an unconfigured home produced output: $out"
  [ ! -e "$dir/home/state/telegram-outbox" ] \
    || fail "an unconfigured home created an outbox"

  out=$(run_send "$dir" '' check 2>&1) || fail "the drain failed in an unconfigured home"
  [ -z "$out" ] || fail "the drain spoke in an unconfigured home: $out"

  rc=0
  out=$(run_send "$dir" '' arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arming succeeded in a home with no Telegram configuration"
  case "$out" in
    *"$dir/home/config/telegram-chat-id"*"$dir/home/config/telegram-token-path"*) ;;
    *) fail "arming an unconfigured home did not name its required configuration: $out" ;;
  esac
  [ ! -e "$dir/home/state/telegram-outbox.check.sh" ] \
    || fail "a refused arm still left a check shim behind"
  pass "unconfigured automatic paths are inert and deliberate arm names its requirements"
}

test_an_unusable_token_file_is_inert() {
  local dir out rc=0
  dir=$(make_home bad-token)
  printf 'not a token\n' > "$dir/token"
  out=$(report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a token file that cannot be used changed the publish result (rc=$rc)"
  [ -z "$out" ] || fail "a token file that cannot be used produced output: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "a token file that cannot be used queued a card"
  # Surrounding blanks in a hand-written config item must not read as absence.
  printf '123456:AA-fixture-bot-token-never-real\n' > "$dir/token"
  printf '  4242  \n' > "$dir/home/config/telegram-chat-id"
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "a chat id written with surrounding blanks read as absent"
  pass "a token file that is not one line of credential is the absent feature, and a padded config value is not"
}

test_unsafe_token_permissions_are_a_visible_configuration_error() {
  local dir base out rc=0
  dir=$(make_home unsafe-token)
  chmod 0644 "$dir/token"
  out=$(report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "unsafe token permissions changed the publisher result"
  [ -z "$out" ] || fail "unsafe token permissions made a publisher speak: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "unsafe token permissions allowed a card to queue"

  rc=0
  out=$(run_send "$dir" '' arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arm accepted an over-permissive token file"
  case "$out" in
    *"$dir/token"*"0600"*) ;;
    *) fail "arm did not name the unsafe token and required mode: $out" ;;
  esac
  out=$(run_send "$dir" '' status 2>&1) || fail "status failed for an unsafe token"
  case "$out" in
    *"configured: error"*"$dir/token"*"0600"*) ;;
    *) fail "status hid the unsafe token configuration: $out" ;;
  esac

  chmod 0600 "$dir/token"
  report "$dir" "failed [key=k2]: child t1 failed: x" failed k2 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "repairing token permissions did not allow queueing"
  base=$(start_api "$dir")
  chmod 0644 "$dir/token"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the unsafe-token drain failed"
  case "$out" in
    *"$dir/token"*"0600"*) ;;
    *) fail "the drain did not report unsafe token permissions: $out" ;;
  esac
  [ "$(card_count "$dir")" = 1 ] || fail "unsafe token permissions discarded the queued card"
  [ ! -s "$dir/api.log" ] || fail "unsafe token permissions allowed a send"
  chmod 0600 "$dir/token"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the repaired-token drain failed"
  [ -z "$out" ] || fail "the repaired-token drain spoke: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "the repaired token did not send the queued card"
  stop_api
  pass "unsafe token permissions are visible and prevent queueing and sending"
}

test_configured_token_disappearance_is_visible_and_recovers() {
  local dir base out
  dir=$(make_home missing-token)
  report "$dir" "done [key=pr-t1]: child t1 PR ready: https://example.test/o/r/pull/1" \
    pr-ready pr-t1 "project=alpha" "url=https://example.test/o/r/pull/1" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "the configured home did not queue its card"
  base=$(start_api "$dir")
  rm -f "$dir/token"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the missing-token drain failed"
  case "$out" in
    *"$dir/token"*"missing"*) ;;
    *) fail "the drain did not name the missing configured token: $out" ;;
  esac
  [ "$(card_count "$dir")" = 1 ] || fail "a missing configured token discarded its card"
  [ ! -s "$dir/api.log" ] || fail "a missing configured token still reached the API"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the repeated missing-token drain failed"
  [ -z "$out" ] || fail "a persistent missing token was reported more than once: $out"
  printf '%s\n' "$BOT_TOKEN" > "$dir/token"
  chmod 0600 "$dir/token"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the restored-token drain failed"
  [ -z "$out" ] || fail "the restored-token drain spoke: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "the restored token did not deliver its queued card"
  stop_api
  pass "a disappeared configured token reports once, preserves cards, and recovers"
}

test_invalid_explicit_token_path_never_uses_default() {
  local dir base out default_home setting
  dir=$(make_home explicit-token)
  report "$dir" "failed [key=k-explicit]: child t1 failed: x" failed k-explicit \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "the configured home did not queue its card"
  base=$(start_api "$dir")
  default_home="$dir/default-home"
  mkdir -p "$default_home"
  printf '%s\n' "$BOT_TOKEN" > "$default_home/.mist-telegram-token"
  chmod 0600 "$default_home/.mist-telegram-token"
  setting="$dir/home/config/telegram-token-path"
  : > "$setting"
  out=$(HOME="$default_home" run_send "$dir" "$base" check 2>&1) \
    || fail "the empty-token-path drain failed"
  case "$out" in
    *"$setting"*"must contain"*) ;;
    *) fail "the drain did not name the empty token-path setting: $out" ;;
  esac
  [ "$(card_count "$dir")" = 1 ] || fail "an invalid token-path setting discarded its card"
  [ ! -s "$dir/api.log" ] || fail "an invalid explicit token path fell back to the default token"
  printf '%s\n' "$dir/token" > "$setting"
  : > "$dir/token"
  out=$(HOME="$default_home" run_send "$dir" "$base" check 2>&1) \
    || fail "the empty-token-file drain failed"
  case "$out" in
    *"$dir/token"*"empty"*) ;;
    *) fail "the drain did not name the empty selected token file: $out" ;;
  esac
  [ ! -s "$dir/api.log" ] || fail "an empty selected token fell back to the default token"
  printf '%s\n' "$BOT_TOKEN" > "$dir/token"
  chmod 0600 "$dir/token"
  out=$(HOME="$default_home" run_send "$dir" "$base" check 2>&1) \
    || fail "the repaired explicit-token drain failed"
  [ -z "$out" ] || fail "the repaired explicit-token drain spoke: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "the repaired explicit token did not deliver its card"
  stop_api
  pass "an invalid explicit token path is visible and never falls back"
}

test_invalid_chat_id_is_visible_and_recovers() {
  local dir base out setting
  dir=$(make_home invalid-chat)
  report "$dir" "failed [key=k-chat]: child t1 failed: x" failed k-chat \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "the configured home did not queue its card"
  base=$(start_api "$dir")
  setting="$dir/home/config/telegram-chat-id"
  printf 'not-a-number\n' > "$setting"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the invalid-chat drain failed"
  case "$out" in
    *"$setting"*"numeric chat id"*) ;;
    *) fail "the drain did not name the invalid chat-id setting: $out" ;;
  esac
  [ "$(card_count "$dir")" = 1 ] || fail "an invalid chat id discarded its card"
  [ ! -s "$dir/api.log" ] || fail "an invalid chat id still reached the API"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the repeated invalid-chat drain failed"
  [ -z "$out" ] || fail "a persistent invalid chat id was reported more than once: $out"
  printf '4242\n' > "$setting"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the repaired-chat drain failed"
  [ -z "$out" ] || fail "the repaired-chat drain spoke: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "the repaired chat id did not deliver its card"
  stop_api
  pass "an invalid chat id reports once, preserves cards, and recovers"
}

test_card_is_built_from_typed_fields() {
  local dir card
  dir=$(make_home typed)
  report "$dir" "needs-decision [key=captain-hold-tg-1]: captain hold tg: aged account or age one" \
    decision captain-hold-tg-1 \
    "title=telegram: stand up the session on the office machine" \
    "reason=aged account or age one" >/dev/null 2>&1 || true
  card=$(only_card "$dir")
  [ "$(head -1 "$card")" = "Decision waiting" ] \
    || fail "the decision card lost its heading: $(head -1 "$card")"
  grep -Fq 'telegram: stand up the session on the office machine' "$card" \
    || fail "the decision card lost the captain's own title"
  grep -Fq 'aged account or age one' "$card" || fail "the decision card lost the reason"
  grep -Fq 'key=' "$card" && fail "the decision card carried a decision key"
  grep -Fq 'captain-hold-tg-1' "$card" && fail "the decision card carried a task id"
  [ "$(stat -c %a "$card" 2>/dev/null || stat -f %Lp "$card")" = 600 ] \
    || fail "a queued card is not private"
  pass "a decision card carries the captain's own words and none of the machine line"
}

test_all_four_classes_render() {
  local out
  out=$(render decision "title=Pick one" "reason=a or b") || fail "the decision card would not render"
  [ "$out" = "Decision waiting
Pick one
a or b" ] || fail "unexpected decision card: $out"
  out=$(render pr-ready "project=alpha" "url=https://example.test/o/r/pull/7") \
    || fail "the PR card would not render"
  [ "$out" = "Ready for your review
alpha
https://example.test/o/r/pull/7" ] || fail "unexpected PR card: $out"
  out=$(render failed "project=alpha" "note=the migration step never finished") \
    || fail "the failure card would not render"
  [ "$out" = "Work stopped
alpha
the migration step never finished" ] || fail "unexpected failure card: $out"
  out=$(render landed "project=alpha" "url=https://example.test/o/r/pull/7") \
    || fail "the landed card would not render"
  [ "$out" = "Work landed
alpha
https://example.test/o/r/pull/7" ] || fail "unexpected landed card: $out"

  render decision "reason=a or b" >/dev/null 2>&1 \
    && fail "a decision card rendered with no title"
  render pr-ready "project=alpha" >/dev/null 2>&1 \
    && fail "a PR card rendered with no URL"
  render invented "title=x" >/dev/null 2>&1 \
    && fail "an unknown card class rendered"
  render decision "title=x" "worktree=/tmp/wt" >/dev/null 2>&1 \
    && fail "a card accepted a field outside its own set"
  pass "the four card classes render from their own required fields and refuse anything else"
}

test_multibyte_fields_remain_valid_utf8_when_truncated() {
  local title out file i
  title=
  i=0
  while [ "$i" -lt 299 ]; do
    title="${title}a"
    i=$((i + 1))
  done
  title="${title}é"
  out=$(render decision "title=$title") || fail "the multibyte card would not render"
  file="$TMP_ROOT/multibyte-card"
  printf '%s' "$out" > "$file"
  python3 - "$file" <<'PY' >/dev/null 2>&1 \
    || fail "field truncation produced invalid UTF-8"
import pathlib
import sys

pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
PY
  case "$out" in
    *é) ;;
    *) fail "field truncation split or discarded the boundary character" ;;
  esac
  [ "$(LC_ALL=C wc -c < "$file" | tr -d '[:space:]')" -le 4000 ] \
    || fail "the rendered card exceeded its byte ceiling"
  pass "field and card bounds preserve UTF-8 character boundaries"
}

test_a_raw_status_line_cannot_become_a_card() {
  local dir out line rc=0
  dir=$(make_home rawline)
  line="failed [key=child-outcome-t1-failed-abcd1234]: child t1 failed: the build broke"
  out=$(report "$dir" "$line" failed child-outcome-t1-failed-abcd1234 \
    "project=alpha" "note=$line" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "refusing a forwarded line changed the publish result (rc=$rc)"
  [ "$(card_count "$dir")" = 0 ] || fail "a card was built by forwarding a status line"
  case "$out" in
    *"raw status line"*) ;;
    *) fail "forwarding a status line was refused silently: $out" ;;
  esac
  # The same refusal at the rendering interface, for every shape a channel or
  # crewmate line takes.
  render failed "project=alpha" "note=done: shipped it" >/dev/null 2>&1 \
    && fail "a crewmate status line rendered as a card"
  render decision "title=needs-decision: which database" >/dev/null 2>&1 \
    && fail "a needs-decision status line rendered as a card"
  pass "a card can never be built by forwarding a parent-channel or status line"
}

test_a_credential_value_is_refused_loudly() {
  local dir out rc=0
  dir=$(make_home secret)
  printf '%s\n' "$dir/extra-credential" > "$dir/home/config/telegram-secret-files"
  printf 'first-secret-api-key-value\nSECOND=second-secret-api-key-value\nQUOTED="quoted-secret-api-key-value"\n' > "$dir/extra-credential"
  chmod 0600 "$dir/extra-credential"

  out=$(report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the run died holding $BOT_TOKEN" 2>&1) || rc=$?
  [ "$(card_count "$dir")" = 0 ] || fail "a card carrying the bot token was queued"
  case "$out" in
    *"credential value"*) ;;
    *) fail "a card carrying the bot token was dropped silently: $out" ;;
  esac
  case "$out" in
    *"$BOT_TOKEN"*) fail "the refusal diagnostic printed the credential it refused" ;;
  esac

  out=$(report "$dir" "failed [key=k2]: child t1 failed: x" failed k2 \
    "project=alpha" "note=config said SECOND=second-secret-api-key-value" 2>&1) || rc=$?
  [ "$(card_count "$dir")" = 0 ] \
    || fail "a card carrying the second line of a credential file was queued"

  out=$(report "$dir" "failed [key=k2-value]: child t1 failed: x" failed k2-value \
    "project=alpha" "note=config said second-secret-api-key-value" 2>&1) || rc=$?
  [ "$(card_count "$dir")" = 0 ] \
    || fail "a card carrying only a KEY=value credential value was queued"

  out=$(report "$dir" "failed [key=k2-quoted]: child t1 failed: x" failed k2-quoted \
    "project=alpha" "note=config said quoted-secret-api-key-value" 2>&1) || rc=$?
  [ "$(card_count "$dir")" = 0 ] \
    || fail "a card carrying a bare quoted credential value was queued"

  # A refusal is about real values, not about anything that merely looks secret.
  report "$dir" "failed [key=k3]: child t1 failed: x" failed k3 \
    "project=alpha" "note=the token check failed" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "an ordinary card was refused as a secret"
  pass "a card carrying a real credential value is refused, and the refusal is loud"
}

test_unreadable_configured_secret_file_refuses_queue_and_send() {
  local dir missing card base out
  dir=$(make_home missing-secret)
  missing="$dir/missing-credential"
  printf '%s\n' "$missing" > "$dir/home/config/telegram-secret-files"
  out=$(report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" 2>&1) || true
  [ "$(card_count "$dir")" = 0 ] || fail "an unchecked credential file allowed a card to queue"
  case "$out" in
    *"$missing"*) ;;
    *) fail "queue-time credential refusal did not name the unreadable path: $out" ;;
  esac

  printf 'available-secret-api-key-value\n' > "$missing"
  report "$dir" "failed [key=k2]: child t1 failed: x" failed k2 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  card=$(only_card "$dir")
  rm -f "$missing"
  base=$(start_api "$dir")
  out=$(run_send "$dir" "$base" check 2>&1) || fail "send-time credential refusal failed"
  case "$out" in
    *"$missing"*) ;;
    *) fail "send-time credential refusal did not name the unreadable path: $out" ;;
  esac
  [ -f "$card" ] || fail "an incomplete send-time credential scan discarded the card"
  [ ! -s "$dir/api.log" ] || fail "an incomplete credential scan sent the queued card"
  stop_api
  pass "unreadable configured credential files refuse queueing and sending by exact path"
}

test_internal_identifiers_do_not_reach_a_card() {
  local dir card out
  dir=$(make_home scrub)
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" \
    "note=build failed (/home/captain/wt/alpha) on branch fm/task-x under claude; details https://github.com/codex/repo/issues/1 with harness=claude mode=no-mistakes key=child-outcome-t1 branch=fm/task-x" \
    >/dev/null 2>&1 || true
  card=$(only_card "$dir")
  grep -Fq '/home/captain' "$card" && fail "a card carried an absolute worktree path"
  grep -Fq 'harness=' "$card" && fail "a card carried a harness name"
  grep -Fq 'mode=' "$card" && fail "a card carried a delivery mode"
  grep -Fq 'key=' "$card" && fail "a card carried a decision key"
  grep -Fq 'branch=' "$card" && fail "a card carried a branch name"
  grep -Fq 'fm/task-x' "$card" && fail "a card carried a bare branch ref"
  grep -Fq 'claude' "$card" && fail "a card carried a bare harness name"
  grep -Fq 'build failed on branch' "$card" || fail "scrubbing removed the readable part of the note"
  grep -Fq 'https://github.com/codex/repo/issues/1' "$card" \
    || fail "scrubbing damaged a URL inside prose"
  out=$(render pr-ready "project=alpha" "url=https://github.com/codex/repo/pull/7") \
    || fail "a PR URL containing a harness name would not render"
  grep -Fq 'https://github.com/codex/repo/pull/7' <<< "$out" \
    || fail "the PR-ready card damaged its canonical URL"
  out=$(render landed "project=alpha" "url=https://github.com/codex/repo/pull/7") \
    || fail "a landed URL containing a harness name would not render"
  grep -Fq 'https://github.com/codex/repo/pull/7' <<< "$out" \
    || fail "the landed card damaged its canonical URL"
  pass "internal identifiers are scrubbed while paths and canonical URLs stay safe"
}

test_pr_card_identity_tracks_the_canonical_pr() {
  local dir first_url second_url meta
  dir=$(make_home pr-identity)
  first_url=https://github.com/owner/repo/pull/12
  second_url=https://github.com/owner/repo/pull/13
  meta="$dir/home/state/t1.meta"
  fm_write_meta "$meta" "window=firstmate:fm-t1" "endpoint_task_id=t1" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "mode=no-mistakes"
  chmod 0600 "$meta"

  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" t1 "$first_url" >/dev/null 2>&1 \
    || fail "registering the first PR failed"
  [ "$(card_count "$dir")" = 1 ] || fail "the first PR queued no card"

  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" t1 "$first_url" >/dev/null 2>&1 \
    || fail "retrying the same PR failed"
  [ "$(card_count "$dir")" = 1 ] || fail "an exact PR retry queued another card"

  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" t1 "$second_url" >/dev/null 2>&1 \
    || fail "registering the replacement PR failed"
  [ "$(card_count "$dir")" = 2 ] || fail "the replacement PR did not queue a distinct card"
  grep -R -Fq "$first_url" "$dir/home/state/telegram-outbox" \
    || fail "the first PR card was lost"
  grep -R -Fq "$second_url" "$dir/home/state/telegram-outbox" \
    || fail "the replacement PR card was lost"
  pass "exact PR retries deduplicate while replacement PRs remain distinct"
}

test_pr_registration_survives_card_digest_failure() {
  local dir parent meta out rc=0 real_shasum
  dir=$(make_home pr-digest-failure)
  parent="$dir/parent"
  meta="$dir/home/state/t1.meta"
  real_shasum=$(command -v shasum)
  mkdir -p "$parent/state"
  printf 'mate\n' > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$dir/home/.fm-secondmate-parent"
  fm_write_meta "$meta" "window=firstmate:fm-t1" "endpoint_task_id=t1" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "mode=no-mistakes"
  chmod 0600 "$meta"
  cat > "$dir/fakebin/shasum" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = -a ] && [ "$2" = 256 ]; then
  exit 1
fi
exec "${FM_REAL_SHASUM:?}" "$@"
SH
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/fakebin/shasum" "$dir/fakebin/gh"

  out=$(FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_REAL_SHASUM="$real_shasum" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" t1 https://github.com/owner/repo/pull/12 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "card digest failure changed PR registration status: $out"
  [ "$out" = 'armed: state/t1.check.sh' ] \
    || fail "card digest failure changed PR registration output: $out"
  grep -Fxq 'pr=https://github.com/owner/repo/pull/12' "$meta" \
    || fail "card digest failure lost the registered PR"
  grep -Fq 'child t1 PR ready: https://github.com/owner/repo/pull/12' "$parent/state/mate.status" \
    || fail "card digest failure skipped the parent ready line"
  [ "$(card_count "$dir")" = 0 ] || fail "a failed card digest queued an unsafe card"
  pass "card digest failures cannot alter PR registration or ready publication"
}

test_publishers_make_no_network_call() {
  local dir base url meta
  dir=$(make_home nonetwork)
  base=$(start_api "$dir")
  url=https://github.com/owner/repo/pull/12
  meta="$dir/home/state/t1.meta"
  fm_write_meta "$meta" "window=firstmate:fm-t1" "endpoint_task_id=t1" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "mode=no-mistakes"
  chmod 0600 "$meta"

  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TELEGRAM_API_BASE="$base" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" t1 "$url" >/dev/null 2>&1 \
    || fail "registering a PR failed in a Telegram-configured home"

  grep -q "^pr=$url$" "$meta" || fail "the PR was not recorded"
  [ -s "$dir/home/state/t1.check.sh" ] || fail "the merge poll was not armed"
  [ "$(card_count "$dir")" = 1 ] || fail "registering a PR queued no card"
  [ ! -s "$dir/api.log" ] \
    || fail "a publisher called Telegram on the critical path: $(cat "$dir/api.log")"
  stop_api
  pass "registering a PR records the PR, queues a card, and calls Telegram not at all"
}

test_cleanup_gate_is_unaffected_by_an_unreachable_telegram() {
  local dir parent
  dir=$(make_home cleanup-gate)
  parent="$dir/parent"
  mkdir -p "$parent/state"
  printf 'mate\n' > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$dir/home/.fm-secondmate-parent"
  fm_write_meta "$dir/home/state/c1.meta" "window=firstmate:fm-c1" \
    "endpoint_task_id=c1" "worktree=$dir/wt" "project=$dir/project" "kind=ship"
  printf 'failed: the migration step never finished\n' > "$dir/home/state/c1.status"

  # This is the exact call bin/fm-teardown.sh makes before it will remove a
  # child, and it refuses when the outcome has not reached the parent channel.
  # Telegram is not running at all here.
  timeout 30 env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TELEGRAM_API_BASE="http://127.0.0.1:1" PATH="$dir/fakebin:$BASE_PATH" \
    "$RECONCILE" report c1 >/dev/null 2>&1 \
    || fail "the cleanup gate refused while Telegram was unreachable"
  grep -Fq 'child c1 failed' "$parent/state/mate.status" \
    || fail "the child's outcome did not reach the parent channel"
  [ "$(card_count "$dir")" = 1 ] || fail "the failure queued no card"
  pass "the gate that refuses to remove a child is unaffected by an unreachable Telegram"
}

test_secondmate_failure_cards_track_incarnations() {
  local dir parent meta status
  dir=$(make_home secondmate-incarnations)
  parent="$dir/parent"
  meta="$dir/home/state/c1.meta"
  status="$dir/home/state/c1.status"
  mkdir -p "$parent/state"
  printf 'mate\n' > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$dir/home/.fm-secondmate-parent"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: failed - source: fixture\n'
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"

  fm_write_meta "$meta" "window=firstmate:fm-c1" "endpoint_task_id=c1" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "spawn_gen=spawn-one"
  printf 'working: quiet since\n' > "$status"
  touch -t 200001010000 "$meta" "$status"
  timeout 30 env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" "$RECONCILE" scan --startup >/dev/null 2>&1 \
    || fail "the first failed incarnation was not reconciled"
  [ "$(card_count "$dir")" = 1 ] || fail "the first failed incarnation queued no card"

  timeout 30 env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" "$RECONCILE" scan --startup >/dev/null 2>&1 \
    || fail "retrying the first failed incarnation failed"
  [ "$(card_count "$dir")" = 1 ] || fail "an exact failed-incarnation retry queued another card"

  rm -f "$meta" "$status" "$dir/home/state/c1.turn-ended"
  fm_write_meta "$meta" "window=firstmate:fm-c1" "endpoint_task_id=c1" \
    "worktree=$dir/wt" "project=$dir/project" "kind=ship" "spawn_gen=spawn-two"
  printf 'working: quiet since\n' > "$status"
  touch -t 200001010000 "$meta" "$status"
  timeout 30 env FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" "$RECONCILE" scan --startup >/dev/null 2>&1 \
    || fail "the replacement failed incarnation was not reconciled"
  [ "$(card_count "$dir")" = 2 ] || fail "the replacement failed incarnation queued no distinct card"
  [ "$(grep -Fc '[key=inactive-outcome-mate-c1-failed]' "$parent/state/mate.status")" = 2 ] \
    || fail "card identity changes altered the parent-channel key"
  pass "secondmate failure cards distinguish incarnations without changing channel keys"
}

test_merge_recording_survives_card_digest_failure() {
  local dir state out
  dir=$(make_home merge-digest)
  state="$dir/home/state"
  fm_write_meta "$state/t1.meta" "project=$dir/project"
  out=$(FM_CONFIG_OVERRIDE="$dir/home/config" bash -c '
    . "$1"
    fm_telegram_event_digest() { return 1; }
    fm_merge_outcome_report "$2" "$3" t1 https://github.com/owner/repo/pull/12 self
    fm_merge_outcome_report "$2" "$3" t1 https://github.com/owner/repo/pull/13 self
  ' _ "$MERGE_OUTCOME" "$dir/home" "$state" 2>&1) \
    || fail "merge recording inherited a card digest failure: $out"
  [ ! -e "$state/t1.pr-poll-merge-notified.lock" ] \
    || fail "a card digest failure left the merge lock held"
  [ "$(grep -c 'check: merge landed: t1' "$state/.wake-queue")" = 2 ] \
    || fail "a card digest failure skipped a merge outcome"
  [ "$(card_count "$dir")" = 0 ] || fail "a failed card identity queued an unsafe card"
  pass "card digest failures cannot block or lock merge outcome recording"
}

test_drain_sends_and_never_listens() {
  local dir base card key
  dir=$(make_home drain)
  base=$(start_api "$dir")
  report "$dir" "done [key=merged-t1]: merged t1 https://example.test/o/r/pull/3" \
    landed merged-t1 "project=alpha" "url=https://example.test/o/r/pull/3" >/dev/null 2>&1 || true
  card=$(only_card "$dir")
  key=$(basename "$card" .card)

  run_send "$dir" "$base" check >"$dir/out" 2>&1 || fail "the drain failed"
  [ ! -s "$dir/out" ] || fail "a successful drain spoke: $(cat "$dir/out")"
  [ "$(card_count "$dir")" = 0 ] || fail "a delivered card stayed queued"
  grep -Fq "POST /bot$BOT_TOKEN/sendMessage" "$dir/api.log" \
    || fail "the drain did not send the card: $(cat "$dir/api.log")"
  grep -Fq 'Work+landed' "$dir/api.log" || grep -Fq 'Work%20landed' "$dir/api.log" \
    || fail "the sent body did not carry the card text: $(cat "$dir/api.log")"
  grep -Fq 'getUpdates' "$dir/api.log" \
    && fail "the bot asked Telegram for messages: $(cat "$dir/api.log")"
  [ "$(grep -c . "$dir/api.log")" = 1 ] \
    || fail "the drain made more than the one send: $(cat "$dir/api.log")"
  grep -Fq "${key##*-}" "$dir/home/state/telegram-outbox/.delivered" \
    || fail "the delivered key was not recorded"

  # The same outcome published again must not produce a second card.
  report "$dir" "done [key=merged-t1]: merged t1 https://example.test/o/r/pull/3" \
    landed merged-t1 "project=alpha" "url=https://example.test/o/r/pull/3" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 0 ] || fail "a re-published outcome queued a second card"
  stop_api
  pass "a drain sends each card once, asks Telegram for nothing, and never repeats an outcome"
}

test_semantic_success_response_is_accepted() {
  local dir base out
  dir=$(make_home spaced-response)
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  base=$(start_api "$dir")
  printf 'reordered\n' > "$dir/api.mode"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the reordered success drain failed"
  [ -z "$out" ] || fail "a reordered success response emitted a configuration wake: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "a reordered success response left the card queued"
  [ ! -e "$dir/home/state/telegram-send.error" ] \
    || fail "a reordered success response recorded a false configuration error"
  stop_api
  pass "Telegram success is read semantically independent of field order"
}

test_non_loopback_api_override_is_refused() {
  local dir base out
  dir=$(make_home unsafe-api-base)
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  base=$(start_api "$dir")
  out=$(run_send "$dir" 'https://attacker.example' check 2>&1) \
    || fail "the rejected-endpoint drain failed"
  case "$out" in
    *"https://attacker.example"*) ;;
    *) fail "the rejected API endpoint was not reported: $out" ;;
  esac
  [ "$(card_count "$dir")" = 1 ] || fail "a rejected API endpoint discarded the card"
  [ ! -s "$dir/api.log" ] || fail "a rejected API endpoint sent card data"
  out=$(run_send "$dir" 'https://attacker.example' check 2>&1) \
    || fail "the repeated rejected-endpoint drain failed"
  [ -z "$out" ] || fail "a rejected API endpoint was reported more than once: $out"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the loopback recovery drain failed"
  [ -z "$out" ] || fail "the loopback recovery drain spoke: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "the accepted loopback endpoint did not send the card"
  stop_api
  pass "API overrides are restricted to loopback and rejected without card loss"
}

test_malformed_success_response_is_rejected() {
  local dir base out
  dir=$(make_home malformed-response)
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  base=$(start_api "$dir")
  printf 'malformed\n' > "$dir/api.mode"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the malformed-response drain failed"
  case "$out" in
    *"was refused by Telegram"*) ;;
    *) fail "a malformed response was not reported as rejected: $out" ;;
  esac
  [ "$(card_count "$dir")" = 1 ] || fail "a malformed response discarded the queued card"
  stop_api
  pass "malformed Telegram responses cannot acknowledge queued cards"
}

test_outage_retries_silently_and_a_rejection_reports_once() {
  local dir base out
  dir=$(make_home degrade)
  report "$dir" "failed [key=k1]: child t1 failed: x" failed k1 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  [ "$(card_count "$dir")" = 1 ] || fail "no card to drain"

  # Nothing is listening: the card waits, and the drain says nothing.
  out=$(run_send "$dir" 'http://127.0.0.1:1' check 2>&1) \
    || fail "the drain failed while Telegram was unreachable"
  [ -z "$out" ] || fail "an outage produced a wake: $out"
  [ "$(card_count "$dir")" = 1 ] || fail "an outage lost the card"

  # A rejected token is reported once, not once per poll.
  base=$(start_api "$dir")
  printf '401\n' > "$dir/api.mode"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the drain failed on a rejected token"
  case "$out" in
    *"HTTP 401"*) ;;
    *) fail "a rejected token was not reported: $out" ;;
  esac
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the second drain failed"
  [ -z "$out" ] || fail "a rejected token woke firstmate twice: $out"
  [ "$(card_count "$dir")" = 1 ] || fail "a rejected token discarded the card"

  # Once the token works again the queued card is delivered.
  printf 'ok\n' > "$dir/api.mode"
  out=$(run_send "$dir" "$base" check 2>&1) || fail "the recovery drain failed"
  [ -z "$out" ] || fail "the recovery drain spoke: $out"
  [ "$(card_count "$dir")" = 0 ] || fail "the queued card was not delivered after recovery"
  stop_api
  pass "an outage retries in silence, a rejected token wakes firstmate once, and the card survives both"
}

test_arm_and_disarm() {
  local dir base out
  dir=$(make_home arm)
  base=$(start_api "$dir")
  out=$(run_send "$dir" "$base" arm 2>&1) || fail "arming failed: $out"
  case "$out" in
    'armed: state/telegram-outbox.check.sh') ;;
    *) fail "unexpected arm result: $out" ;;
  esac
  [ -f "$dir/home/state/telegram-outbox.check.sh" ] || fail "arming wrote no check"
  [ -f "$dir/home/state/telegram-outbox.check-trust" ] || fail "arming bound no trust record"
  [ "$(stat -c %a "$dir/home/state/telegram-outbox.check.sh" 2>/dev/null \
    || stat -f %Lp "$dir/home/state/telegram-outbox.check.sh")" = 700 ] \
    || fail "the check shim is not a private executable"

  # The shim the watcher will run is the drain.
  report "$dir" "failed [key=k9]: child t1 failed: x" failed k9 \
    "project=alpha" "note=the build broke" >/dev/null 2>&1 || true
  FM_TELEGRAM_API_BASE="$base" PATH="$dir/fakebin:$BASE_PATH" \
    "$dir/home/state/telegram-outbox.check.sh" >/dev/null 2>&1 \
    || fail "the armed check shim failed"
  [ "$(card_count "$dir")" = 0 ] || fail "the armed check shim did not drain the outbox"

  out=$(run_send "$dir" "$base" status 2>&1) || fail "status failed: $out"
  case "$out" in
    *'armed: yes'*) ;;
    *) fail "status did not report the home as armed: $out" ;;
  esac
  case "$out" in
    *"$BOT_TOKEN"*) fail "status printed the bot token" ;;
  esac

  out=$(run_send "$dir" "$base" disarm 2>&1) || fail "disarming failed: $out"
  [ ! -e "$dir/home/state/telegram-outbox.check.sh" ] || fail "disarming left the check"
  [ ! -e "$dir/home/state/telegram-outbox.check-trust" ] || fail "disarming left the trust record"
  stop_api
  pass "arming registers a drain the watcher can run, and disarming removes it"
}

test_unconfigured_home_is_inert
test_configured_token_disappearance_is_visible_and_recovers
test_invalid_explicit_token_path_never_uses_default
test_invalid_chat_id_is_visible_and_recovers
test_an_unusable_token_file_is_inert
test_unsafe_token_permissions_are_a_visible_configuration_error
test_card_is_built_from_typed_fields
test_all_four_classes_render
test_multibyte_fields_remain_valid_utf8_when_truncated
test_a_raw_status_line_cannot_become_a_card
test_a_credential_value_is_refused_loudly
test_unreadable_configured_secret_file_refuses_queue_and_send
test_internal_identifiers_do_not_reach_a_card
test_pr_card_identity_tracks_the_canonical_pr
test_pr_registration_survives_card_digest_failure
test_publishers_make_no_network_call
test_cleanup_gate_is_unaffected_by_an_unreachable_telegram
test_secondmate_failure_cards_track_incarnations
test_merge_recording_survives_card_digest_failure
test_drain_sends_and_never_listens
test_semantic_success_response_is_accepted
test_non_loopback_api_override_is_refused
test_malformed_success_response_is_rejected
test_outage_retries_silently_and_a_rejection_reports_once
test_arm_and_disarm

echo "all telegram notification tests passed"
