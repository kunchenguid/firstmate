#!/usr/bin/env bash
# Behavior tests for the Telegram bridge: the chat-id allowlist, verbatim
# untrusted message bodies, offset discipline across a restart, credential
# redaction, quiet degradation under an outage, the escalation tier, and the
# inert-until-configured guarantee.
#
# Every case drives the real scripts against a local stand-in for the Telegram
# Bot API, so the request/response path, the note write, and the durable offset
# are all exercised for real rather than asserted about.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
SEND="$ROOT/bin/fm-telegram.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram)
API_ROOT="$TMP_ROOT/api"
TOKEN='123456:AA-test_Token'
mkdir -p "$API_ROOT"

# --- the stand-in API -------------------------------------------------------
#
# It implements the one Telegram behavior the bridge's correctness rests on:
# asking for offset N permanently drops every update below N. Without that, an
# offset bug would still look like it worked.

cat > "$API_ROOT/server.py" <<'PY'
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = sys.argv[1]
LOCK = threading.Lock()

def load(name, default):
    p = os.path.join(ROOT, name)
    if not os.path.exists(p):
        return default
    try:
        with open(p) as f:
            return json.load(f)
    except (ValueError, OSError):
        return default

def save(name, obj):
    with open(os.path.join(ROOT, name), "w") as f:
        json.dump(obj, f)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _reply(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _route(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if len(parts) != 2 or not parts[0].startswith("bot"):
            return None, None
        return parts[0][3:], parts[1]

    def _authed(self, token):
        if token != load("token.json", {"t": ""})["t"]:
            self._reply({"ok": False, "error_code": 401,
                         "description": "Unauthorized"}, 401)
            return False
        return True

    def do_GET(self):
        token, method = self._route()
        if method is None:
            return self._reply({"ok": False, "description": "bad path"}, 404)
        if not self._authed(token):
            return
        with LOCK:
            fail = load("fail.json", {"n": 0})
            if fail["n"] > 0:
                fail["n"] -= 1
                save("fail.json", fail)
                failing = True
            else:
                failing = False
        if failing:
            return self._reply({"ok": False, "error_code": 502,
                                "description": "Bad Gateway"}, 502)
        if method != "getUpdates":
            return self._reply({"ok": False, "description": "no such method"}, 404)
        q = parse_qs(urlparse(self.path).query)
        offset = int(q.get("offset", ["0"])[0])
        timeout = float(q.get("timeout", ["0"])[0])
        with LOCK:
            pend = load("updates.json", [])
            if offset > 0:
                kept = [u for u in pend if u["update_id"] >= offset]
                if len(kept) != len(pend):
                    save("updates.json", kept)
                pend = kept
            ready = list(pend)
        if not ready and timeout > 0:
            deadline = time.time() + min(timeout, 2)
            while time.time() < deadline:
                time.sleep(0.05)
                with LOCK:
                    ready = load("updates.json", [])
                if ready:
                    break
        return self._reply({"ok": True, "result": ready})

    def do_POST(self):
        token, method = self._route()
        if method is None:
            return self._reply({"ok": False, "description": "bad path"}, 404)
        if not self._authed(token):
            return
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode()
        if method == "setMessageReaction":
            with LOCK:
                rfail = load("reactfail.json", {"n": 0})
                if rfail["n"] > 0:
                    rfail["n"] -= 1
                    save("reactfail.json", rfail)
                    failing = True
                else:
                    failing = False
                if not failing:
                    reacted = load("reacted.json", [])
                    reacted.append(json.loads(raw))
                    save("reacted.json", reacted)
            if failing:
                return self._reply({"ok": False, "error_code": 400,
                                    "description": "REACTION_INVALID"}, 400)
            return self._reply({"ok": True, "result": True})
        if method != "sendMessage":
            return self._reply({"ok": False, "description": "no such method"}, 404)
        with LOCK:
            sent = load("sent.json", [])
            sent.append(json.loads(raw))
            save("sent.json", sent)
        return self._reply({"ok": True, "result": {"message_id": len(sent)}})

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(ROOT, "port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY

printf '{"t":"%s"}\n' "$TOKEN" > "$API_ROOT/token.json"
python3 "$API_ROOT/server.py" "$API_ROOT" >"$API_ROOT/server.log" 2>&1 &
API_PID=$!

stop_api() {
  [ -n "${API_PID:-}" ] || return 0
  kill "$API_PID" 2>/dev/null || true
  wait "$API_PID" 2>/dev/null || true
  API_PID=
}
trap 'stop_api; fm_test_cleanup' EXIT
trap 'stop_api; fm_test_cleanup; exit 130' INT
trap 'stop_api; fm_test_cleanup; exit 143' TERM

for _ in $(seq 1 100); do
  [ -s "$API_ROOT/port" ] && break
  sleep 0.1
done
[ -s "$API_ROOT/port" ] || fail "the stand-in Telegram API did not start"
API_BASE="http://127.0.0.1:$(cat "$API_ROOT/port")"

# --- fixture helpers --------------------------------------------------------

set_updates() { printf '%s\n' "$1" > "$API_ROOT/updates.json"; }
set_failures() { printf '{"n":%s}\n' "$1" > "$API_ROOT/fail.json"; }
reset_sent() { rm -f "$API_ROOT/sent.json" "$API_ROOT/reacted.json" "$API_ROOT/reactfail.json"; }
sent_count() {
  [ -f "$API_ROOT/sent.json" ] || { printf '0\n'; return 0; }
  jq 'length' < "$API_ROOT/sent.json"
}
set_reaction_failures() { printf '{"n":%s}\n' "$1" > "$API_ROOT/reactfail.json"; }
reacted_count() {
  [ -f "$API_ROOT/reacted.json" ] || { printf '0\n'; return 0; }
  jq 'length' < "$API_ROOT/reacted.json"
}
reacted_field() {  # <jq-path>
  [ -f "$API_ROOT/reacted.json" ] || return 1
  jq -r ".[0].$1" < "$API_ROOT/reacted.json"
}
note_count() {  # <home>
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}
note_body() {  # <home>
  local f
  f=$(find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | head -n1)
  [ -n "$f" ] || return 1
  sed -n '/^--$/,$p' "$f" | tail -n +2
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  rm -rf "$home"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# Run the inbound collector against the stand-in API. The chat id is passed as
# the caller gave it, including empty, which is the unconfigured case.
run_poll() {  # <home> <allowed-chat> [extra-env...]
  local home=$1 chat=$2
  shift 2
  env "$@" FM_HOME="$home" FM_TELEGRAM_API_BASE="$API_BASE" \
    TELEGRAM_BOT_TOKEN="$TOKEN" TELEGRAM_ALLOWED_CHAT_ID="$chat" \
    FM_TELEGRAM_POLL_TIMEOUT="${POLL_TIMEOUT:-1}" \
    FM_TELEGRAM_POLL_MAX_CYCLES="${POLL_CYCLES:-2}" \
    FM_TELEGRAM_POLL_FAIL_DELAY=1 \
    FM_TELEGRAM_POLL_FAIL_LIMIT="${POLL_FAIL_LIMIT:-3}" \
    "$ADAPTER" "${ADAPTER_CMD:-poll}"
}

run_send() {  # <home> <allowed-chat> <args...>
  local home=$1 chat=$2
  shift 2
  env FM_HOME="$home" FM_TELEGRAM_API_BASE="$API_BASE" \
    TELEGRAM_BOT_TOKEN="$TOKEN" TELEGRAM_ALLOWED_CHAT_ID="$chat" \
    "$SEND" "$@"
}

# The message_id is deliberately NOT the update_id: they are different
# identifiers in the API, and a reaction sent against the wrong one would still
# look correct if the fixture let them share a value.
message_json() {  # <update-id> <chat-id> <text>
  jq -nc --argjson u "$1" --argjson c "$2" --arg t "$3" \
    '[{update_id: $u,
       message: {message_id: ($u + 1000), chat: {id: $c},
                 from: {id: 77}, text: $t}}]'
}

# --- cases ------------------------------------------------------------------

test_allowed_message_becomes_a_note() {
  local home
  home=$(make_home allowed)
  reset_sent
  set_failures 0
  set_updates "$(message_json 10 555 'ship the thing')"
  run_poll "$home" 555 >/dev/null 2>&1

  [ "$(note_count "$home")" = 1 ] || fail "an allowed message did not become a note"
  note_body "$home" | grep -qx 'ship the thing' \
    || fail "the note body is not the message text"
  grep -rqx 'source=telegram' "$home/state/inbox" \
    || fail "the note does not record Telegram as its source"
  grep -q 'check: captain inbox note' "$home/state/.wake-queue" \
    || fail "the note did not wake firstmate"
  # Receipt is a reaction ON the captain's message, never another message in
  # the chat: the text ack it replaced reached him before firstmate had even
  # read the message, and he had to read it as a separate line.
  [ "$(sent_count)" = 0 ] \
    || fail "the collector sent $(sent_count) unprompted message(s) back to the captain"
  [ "$(reacted_count)" = 1 ] \
    || fail "the accepted note was not confirmed with a reaction"
  [ "$(reacted_field 'message_id')" = 1010 ] \
    || fail "the reaction targeted $(reacted_field 'message_id'), not the message it confirms"
  [ "$(reacted_field 'chat_id')" = 555 ] \
    || fail "the reaction went to the wrong chat"
  [ "$(reacted_field 'reaction[0].emoji')" = "👍" ] \
    || fail "the reaction is not the expected emoji"
  [ "$(reacted_field 'reaction[0].type')" = emoji ] \
    || fail "the reaction was not sent as an emoji reaction"
  pass "an allowed message is confirmed by a reaction, not another message"
}

test_a_failed_reaction_never_costs_the_note() {
  local home
  home=$(make_home reactfail)
  reset_sent
  set_failures 0
  # Every reaction attempt is refused, the way Telegram refuses an emoji it
  # does not accept or a message too old to react to.
  set_reaction_failures 99
  set_updates "$(message_json 44 555 'confirm nothing, keep everything')"
  run_poll "$home" 555 >"$TMP_ROOT/reactfail-out" 2>&1

  [ "$(note_count "$home")" = 1 ] \
    || fail "a refused reaction cost the note it was only meant to confirm"
  note_body "$home" | grep -qx 'confirm nothing, keep everything' \
    || fail "the note body did not survive the failed reaction"
  [ "$(reacted_count)" = 0 ] || fail "the stand-in API recorded a refused reaction"
  grep -q '^  status: idle' "$TMP_ROOT/reactfail-out" \
    || fail "a refused reaction was reported as a collection failure: $(cat "$TMP_ROOT/reactfail-out")"
  grep -q '^  notes: 1' "$TMP_ROOT/reactfail-out" \
    || fail "the collector did not report the note it queued"

  # And the message stays confirmed to Telegram, so it is not sent again.
  set_reaction_failures 0
  set_updates '[]'
  run_poll "$home" 555 >/dev/null 2>&1
  [ "$(note_count "$home")" = 1 ] \
    || fail "the message was collected twice after its reaction failed"
  pass "a reaction the API refuses never costs the note or replays the message"
}

test_message_body_is_stored_verbatim() {
  local home hostile
  # Shell metacharacters, both quote styles, a newline, a tab, and unicode. The
  # command substitutions are the payload and must reach the note UNEXPANDED, so
  # they are built with printf rather than written as an expanding literal.
  home=$(make_home verbatim)
  hostile=$(printf '%s(touch %s/PWNED); %sid%s; "q" %ss%s\nsecond\tline; ⚓ ünï 日本語 | & > <' \
    '$' "$TMP_ROOT" '`' '`' "'" "'")
  set_failures 0
  set_updates "$(message_json 20 555 "$hostile")"
  run_poll "$home" 555 >/dev/null 2>&1

  [ -e "$TMP_ROOT/PWNED" ] && fail "message text was executed as a shell command"
  [ "$(note_body "$home")" = "$hostile" ] \
    || fail "the message body was altered on its way into the note"
  pass "a hostile message body is stored verbatim and never interpreted"
}

test_unallowlisted_chat_is_silently_dropped() {
  local home
  home=$(make_home stranger)
  reset_sent
  set_failures 0
  set_updates "$(message_json 30 999 'queue work for me')"
  run_poll "$home" 555 >/dev/null 2>&1

  [ "$(note_count "$home")" = 0 ] || fail "a stranger's message became a note"
  [ -f "$home/state/.wake-queue" ] && fail "a stranger's message woke firstmate"
  [ "$(sent_count)" = 0 ] || fail "the bot replied to a stranger"
  grep -rq 'queue work for me' "$home" 2>/dev/null \
    && fail "a stranger's message text was echoed into this home"
  pass "a message from an unallowlisted chat produces no note, wake, reply, or echo"
}

test_unconfigured_allowlist_reports_the_id_only() {
  local home out
  home=$(make_home discovery)
  reset_sent
  set_failures 0
  set_updates "$(message_json 40 424242 'my first words')"
  out=$(run_poll "$home" '' 2>&1)

  printf '%s' "$out" | grep -q 'status: unconfigured' \
    || fail "a first sender was not reported for confirmation"
  printf '%s' "$out" | grep -q 'chat_id: 424242' \
    || fail "the first sender's chat id was not reported"
  printf '%s' "$out" | grep -q 'my first words' \
    && fail "the first sender's message text was echoed"
  [ "$(note_count "$home")" = 0 ] \
    || fail "an unconfigured bridge queued a note anyway"
  [ "$(sent_count)" = 0 ] || fail "the bot replied to an unconfirmed sender"
  pass "with no allowlist the first sender's id is reported and nothing is trusted"
}

test_an_inbound_message_wakes_firstmate_to_act_on_it() {
  local home out
  home=$(make_home wakes)
  set_failures 0
  set_updates "$(message_json 15 555 'please look at the failing deploy')"
  run_poll "$home" 555 >/dev/null 2>&1

  # A Telegram message must be WORK firstmate is woken to act on, exactly like a
  # note typed at the terminal or handed over by the spoken interface - not
  # something archived for whenever it is next read. The proof is that the real
  # wake drain presents it as an actionable check wake carrying the message.
  # Both streams: the queued rows print on stdout, the acknowledgement contract on stderr.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  printf '%s' "$out" | grep -q "check: captain inbox note" \
    || fail "an inbound message did not reach firstmate as an actionable wake"
  printf '%s' "$out" | grep -q "please look at the failing deploy" \
    || fail "the wake does not carry what the captain actually asked for"
  printf '%s' "$out" | grep -q "WAKE_ACK_REQUIRED" \
    || fail "the wake could be dropped without being handled"

  # And it stays outstanding until it is explicitly acknowledged as handled.
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" list | grep -q 'please look at the failing deploy' \
    || fail "the message stopped counting as waiting for firstmate before it was handled"
  pass "an inbound message wakes firstmate as work to act on, not an archived record"
}

test_offset_advances_only_after_the_note_is_written() {
  local home
  home=$(make_home offset)
  set_failures 0
  set_updates "$(message_json 50 555 'first')"
  run_poll "$home" 555 >/dev/null 2>&1
  [ "$(cat "$home/state/telegram/offset")" = 51 ] \
    || fail "the offset did not advance past a written note"
  [ -f "$home/state/telegram/claim" ] \
    && fail "the in-flight claim outlived a completed message"
  pass "the acknowledgement offset advances only after the note is durably written"
}

test_restart_after_a_written_note_does_not_duplicate_it() {
  local home
  home=$(make_home dup)
  set_failures 0
  set_updates "$(message_json 60 555 'exactly once')"
  run_poll "$home" 555 >/dev/null 2>&1
  [ "$(note_count "$home")" = 1 ] || fail "the first collection did not write the note"

  # Exactly the durable state a crash between the note write and the offset
  # advance leaves behind, with the update still pending server-side because
  # Telegram was never told to drop it.
  printf '60\n' > "$home/state/telegram/claim"
  printf '60\n' > "$home/state/telegram/offset"
  set_updates "$(message_json 60 555 'exactly once')"

  run_poll "$home" 555 >/dev/null 2>&1
  [ "$(note_count "$home")" = 1 ] \
    || fail "restarting after the crash window queued the same message twice"
  [ -f "$home/state/telegram/claim" ] \
    && fail "the outstanding claim was not resolved on restart"
  pass "a restart inside the crash window does not queue the same message twice"
}

test_restart_before_a_written_note_still_collects_it() {
  local home
  home=$(make_home lost)
  mkdir -p "$home/state/telegram"
  # The other side of the same window: the claim was recorded but the note never
  # landed, so the message must still be collected rather than skipped.
  printf '70\n' > "$home/state/telegram/claim"
  printf '70\n' > "$home/state/telegram/offset"
  set_failures 0
  set_updates "$(message_json 70 555 'must not be lost')"

  run_poll "$home" 555 >/dev/null 2>&1
  [ "$(note_count "$home")" = 1 ] \
    || fail "a message whose note never landed was dropped on restart"
  note_body "$home" | grep -qx 'must not be lost' || fail "the recovered note is wrong"
  pass "a restart before the note landed still collects the message"
}

test_an_unwritable_note_is_never_acknowledged() {
  local home out offset_before offset_after
  home=$(make_home unwritable)
  set_failures 0
  # Collect one message normally so the offset has a known starting point.
  set_updates "$(message_json 75 555 'first one')"
  run_poll "$home" 555 >/dev/null 2>&1
  offset_before=$(cat "$home/state/telegram/offset")

  # Now make the note record impossible to write. This is what proves the
  # ORDER rather than just the recovery: the offset must not move past a message
  # whose note did not land, or Telegram drops it and it is gone for good.
  chmod 500 "$home/state/inbox"
  set_updates "$(message_json 76 555 'must not be acknowledged')"
  out=$(run_poll "$home" 555 2>&1) || true
  chmod 700 "$home/state/inbox"

  offset_after=$(cat "$home/state/telegram/offset")
  [ "$offset_after" = "$offset_before" ] \
    || fail "a message was acknowledged even though its note could not be written"
  printf '%s' "$out" | grep -q 'status: error' \
    || fail "a failed note write was not reported"
  # Whether the note landed is ambiguous from here (fm-inbox.sh can still fail
  # after moving the note into place), so the claim is left for the next
  # start's recover_claim() to resolve the same way it resolves a crash,
  # rather than guessed away here and risking a duplicate note.
  [ -f "$home/state/telegram/claim" ] \
    || fail "a failed note write discarded the in-flight claim needed to resolve it safely"

  # With the inbox writable again the message is still there to collect.
  set_updates "$(message_json 76 555 'must not be acknowledged')"
  run_poll "$home" 555 >/dev/null 2>&1
  [ "$(note_count "$home")" = 2 ] \
    || fail "the unacknowledged message was not collected on the next attempt"
  [ -f "$home/state/telegram/claim" ] \
    && fail "the stale claim was not resolved once the message was collected"
  pass "a message whose note cannot be written is never acknowledged to Telegram"
}

test_concurrent_collectors_never_queue_a_message_twice() {
  local home first second declined result
  home=$(make_home serialized)
  reset_sent
  set_failures 0
  set_updates '[]'

  # The window a direct `poll` opens next to the registered collector: both are
  # already blocked in getUpdates on the SAME offset when a message arrives, so
  # the API hands the identical update to each of them. Nothing in the runner
  # can close this, because a direct invocation never asks the runner for the
  # source claim - only the collector itself can refuse to be the second one.
  POLL_TIMEOUT=3 POLL_CYCLES=2 run_poll "$home" 555 >"$TMP_ROOT/serialized-a" 2>&1 &
  first=$!
  POLL_TIMEOUT=3 POLL_CYCLES=2 run_poll "$home" 555 >"$TMP_ROOT/serialized-b" 2>&1 &
  second=$!
  sleep 1
  set_updates "$(message_json 120 555 'say this once')"
  wait "$first" 2>/dev/null || true
  wait "$second" 2>/dev/null || true
  unset POLL_TIMEOUT POLL_CYCLES

  [ "$(note_count "$home")" = 1 ] \
    || fail "concurrent collectors queued one message $(note_count "$home") time(s)"
  [ "$(sent_count)" = 0 ] \
    || fail "a raced collector sent $(sent_count) unprompted message(s) to the captain"

  # And the one that stood down said so, rather than looking like a quiet cycle
  # that had simply found nothing.
  declined=0
  for result in "$TMP_ROOT/serialized-a" "$TMP_ROOT/serialized-b"; do
    grep -q 'status: busy' "$result" || continue
    declined=$((declined + 1))
    [ "$("$ADAPTER" classify "$result")" = busy ] \
      || fail "a collector that stood down was not classified as busy"
    "$ADAPTER" silent "$result" || fail "standing down would wake firstmate"
    "$ADAPTER" terminal "$result" \
      && fail "standing down retired the captain's inbound channel"
  done
  [ "$declined" = 1 ] || fail "no collector stood down; polling was not serialized"
  pass "a second collector stands down instead of collecting the same message twice"
}

test_a_crashed_collector_does_not_wedge_the_bridge() {
  local home poller
  home=$(make_home crashed)
  reset_sent
  set_failures 0
  set_updates '[]'

  # Hold the poll lock, then die the way a crash does: killed outright, so no
  # cleanup of any kind runs and the lock is left behind. A collector that
  # could not tell an abandoned lock from a live one would stop collecting the
  # captain's messages entirely - a silent outage strictly worse than the
  # duplicate the lock was added to prevent. `env` is backgrounded directly so
  # the signal reaches the collector itself rather than a wrapper shell.
  env FM_HOME="$home" FM_TELEGRAM_API_BASE="$API_BASE" \
    TELEGRAM_BOT_TOKEN="$TOKEN" TELEGRAM_ALLOWED_CHAT_ID=555 \
    FM_TELEGRAM_POLL_TIMEOUT=5 FM_TELEGRAM_POLL_MAX_CYCLES=5 \
    "$ADAPTER" poll >/dev/null 2>&1 &
  poller=$!
  sleep 1
  kill -9 "$poller" 2>/dev/null || true
  wait "$poller" 2>/dev/null || true

  set_updates "$(message_json 140 555 'after the crash')"
  run_poll "$home" 555 >/dev/null 2>&1
  [ "$(note_count "$home")" = 1 ] \
    || fail "the bridge stayed wedged behind a crashed collector's lock"
  note_body "$home" | grep -qx 'after the crash' \
    || fail "the message collected after the crash is not the one that was sent"
  pass "a crashed collector's lock is reclaimed rather than wedging the bridge"
}

test_a_message_body_keeps_its_trailing_blank_lines() {
  local home body f
  home=$(make_home trailing)
  reset_sent
  set_failures 0
  # Trailing blank lines are message CONTENT, and the captain writes them: a
  # note that ends mid-thought reads as a different message from one that ends
  # on a deliberate pause. Built with ANSI-C quoting rather than a command
  # substitution, which would strip them from the fixture itself.
  body=$'first line\n\nlast line\n\n\n'
  set_updates "$(message_json 130 555 "$body")"
  run_poll "$home" 555 >/dev/null 2>&1

  f=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | head -n1)
  [ -n "$f" ] || fail "a message ending in blank lines never became a note"
  sed -n '/^--$/,$p' "$f" | tail -n +2 > "$TMP_ROOT/trailing-body"
  printf '%s' "$body" | cmp -s - "$TMP_ROOT/trailing-body" \
    || fail "the note body is not the message byte for byte"
  pass "a message body keeps its trailing blank lines all the way into the note"
}

test_a_message_waiting_while_nothing_polls_is_collected() {
  local home
  home=$(make_home retained)
  set_failures 0
  set_updates '[]'
  run_poll "$home" 555 >/dev/null 2>&1
  [ "$(note_count "$home")" = 0 ] || fail "a note appeared with no message pending"

  # The message arrives while no collector is running.
  set_updates "$(message_json 80 555 'sent while asleep')"
  run_poll "$home" 555 >/dev/null 2>&1
  [ "$(note_count "$home")" = 1 ] \
    || fail "a message sent while nothing polled was never collected"
  pass "a message that arrives while nothing is polling is collected on next start"
}

test_a_transient_outage_is_absorbed() {
  local home
  home=$(make_home flap)
  set_failures 2
  set_updates "$(message_json 90 555 'survived')"
  POLL_CYCLES=8 POLL_FAIL_LIMIT=5 run_poll "$home" 555 >/dev/null 2>&1
  [ "$(note_count "$home")" = 1 ] \
    || fail "a message was lost across a transient outage"
  set_failures 0
  pass "a transient outage is retried through, not reported"
}

test_a_sustained_outage_ends_the_cycle_without_retiring_it() {
  local home out result
  home=$(make_home outage)
  set_failures 999
  set_updates '[]'
  out=$(POLL_CYCLES=8 POLL_FAIL_LIMIT=2 run_poll "$home" 555 2>&1) \
    || fail "a sustained outage crashed the collector instead of ending cleanly"
  set_failures 0

  result="$TMP_ROOT/outage-result"
  printf '%s\n' "$out" > "$result"
  [ "$("$ADAPTER" classify "$result")" = error ] \
    || fail "a sustained outage was not classified as an error"
  "$ADAPTER" silent "$result" && fail "a sustained outage was silently swallowed"
  "$ADAPTER" terminal "$result" && fail "an outage retired the captain's inbound channel"
  pass "a sustained outage ends the cycle, is reported once, and stays armed"
}

test_a_quiet_cycle_is_not_announced() {
  local home out result
  home=$(make_home quiet)
  set_failures 0
  set_updates '[]'
  out=$(run_poll "$home" 555 2>&1)
  result="$TMP_ROOT/quiet-result"
  printf '%s\n' "$out" > "$result"
  [ "$("$ADAPTER" classify "$result")" = idle ] || fail "a quiet cycle was misclassified"
  "$ADAPTER" silent "$result" || fail "a quiet collection cycle would wake firstmate"
  pass "a quiet collection cycle produces no wake"
}

test_the_bot_token_is_never_emitted() {
  local home out
  home=$(make_home redaction)
  set_failures 0
  set_updates '[]'
  # Force a transport failure so curl's own diagnostic - the one output path
  # that can quote the request URL, and the token is a path segment of it -
  # actually runs. That the redaction itself is literal and total is proved
  # separately by test_redaction_survives_an_awkward_token.
  out=$(env FM_HOME="$home" FM_TELEGRAM_API_BASE="http://127.0.0.1:1" \
    TELEGRAM_BOT_TOKEN="$TOKEN" TELEGRAM_ALLOWED_CHAT_ID=555 \
    FM_TELEGRAM_HTTP_TIMEOUT=2 FM_TELEGRAM_POLL_TIMEOUT=1 \
    FM_TELEGRAM_POLL_MAX_CYCLES=2 FM_TELEGRAM_POLL_FAIL_DELAY=1 \
    FM_TELEGRAM_POLL_FAIL_LIMIT=1 "$ADAPTER" poll 2>&1)

  printf '%s' "$out" | grep -qF "$TOKEN" \
    && fail "the bot token was printed in the collector's own output"
  printf '%s' "$out" | grep -q 'status: error' \
    || fail "the failing request did not report an error at all"
  printf '%s' "$out" | grep -Eq '^  detail: .+' \
    || fail "the failing request reported no diagnostic to act on"
  grep -rqF "$TOKEN" "$home" 2>/dev/null \
    && fail "the bot token was written into this home's durable state"
  pass "the bot token never reaches output or durable state, even in a diagnostic"
}

test_redaction_survives_an_awkward_token() {
  # A token carrying regex metacharacters AND a backslash. The backslash is the
  # sharp one: passing the token to awk with -v would process it as an escape,
  # mangle it, match nothing, and pass the credential straight through.
  local awkward out backslash
  # Built with printf so the metacharacters are literal bytes of the token
  # rather than anything this test's own shell interprets.
  backslash=$(printf '%b' '\0134')
  awkward="9:AA.*B[x]C\$D^E${backslash}FG+H"
  out=$(FM_TG_TOKEN="$awkward" FM_TG_ROOT="$ROOT" bash -c '
    . "$FM_TG_ROOT/bin/fm-env-lib.sh"
    . "$FM_TG_ROOT/bin/fm-telegram-lib.sh"
    printf "url=https://api.telegram.org/bot%s/getUpdates\n" "$FM_TG_TOKEN" | fm_telegram_redact')
  printf '%s' "$out" | grep -qF "$awkward" \
    && fail "a token containing regex metacharacters or a backslash was not redacted"
  [ "$out" = 'url=https://api.telegram.org/bot<redacted>/getUpdates' ] \
    || fail "redaction mangled the surrounding text: $out"
  pass "redaction is literal and survives a token full of metacharacters"
}

test_escalation_tier_accepts_only_escalations() {
  local home
  home=$(make_home tier)
  reset_sent
  run_send "$home" 555 notify blocker 'needs a credential' >/dev/null 2>&1 \
    || fail "a blocker escalation was refused"
  run_send "$home" 555 notify review-ready 'PR is green' >/dev/null 2>&1 \
    || fail "a review-ready escalation was refused"
  run_send "$home" 555 notify failure 'the build broke' >/dev/null 2>&1 \
    || fail "a failure escalation was refused"
  [ "$(sent_count)" = 3 ] || fail "the three escalation kinds did not all send"

  run_send "$home" 555 notify progress 'still working' >/dev/null 2>&1 \
    && fail "routine progress was accepted as an escalation"
  run_send "$home" 555 notify digest 'hourly summary' >/dev/null 2>&1 \
    && fail "a periodic digest was accepted as an escalation"
  [ "$(sent_count)" = 3 ] || fail "a refused kind was sent anyway"
  jq -r '.[0].text' < "$API_ROOT/sent.json" | grep -q '^Blocked: ' \
    || fail "an escalation did not carry its kind"
  pass "only blockers, review-ready work, and failures can be sent outward"
}

test_the_bridge_is_inert_with_no_token() {
  local home rc
  home=$(make_home inert)
  set_failures 0
  set_updates "$(message_json 100 555 'hello')"
  reset_sent

  rc=0
  env FM_HOME="$home" FM_TELEGRAM_API_BASE="$API_BASE" \
    TELEGRAM_BOT_TOKEN= TELEGRAM_ALLOWED_CHAT_ID= \
    "$ADAPTER" poll >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "an unconfigured collector failed instead of reporting itself off"

  rc=0
  env FM_HOME="$home" TELEGRAM_BOT_TOKEN= "$SEND" send 'nothing' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 3 ] || fail "an unconfigured send did not report itself unconfigured (got $rc)"

  rc=0
  env FM_HOME="$home" TELEGRAM_BOT_TOKEN= "$ADAPTER" arm >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && fail "an unconfigured bridge registered a collector anyway"

  [ "$(note_count "$home")" = 0 ] || fail "an unconfigured bridge queued a note"
  [ "$(sent_count)" = 0 ] || fail "an unconfigured bridge sent a message"
  [ -d "$home/state/telegram" ] && fail "an unconfigured bridge wrote durable state"
  pass "with no token nothing polls, sends, registers, or is written"
}

test_a_removed_token_retires_the_source() {
  local home out result
  home=$(make_home removed)
  out=$(env FM_HOME="$home" TELEGRAM_BOT_TOKEN= "$ADAPTER" poll 2>&1)
  result="$TMP_ROOT/removed-result"
  printf '%s\n' "$out" > "$result"
  [ "$("$ADAPTER" classify "$result")" = disabled ] \
    || fail "a removed token was not classified as disabled"
  "$ADAPTER" terminal "$result" \
    || fail "removing the token left a dead collector registered"
  pass "removing the token retires the collector instead of leaving it dead"
}

test_an_invalid_allowed_chat_id_refuses_everything() {
  local home
  home=$(make_home badchat)
  reset_sent
  set_failures 0
  set_updates "$(message_json 110 555 'should not land')"
  # An allowlist that is not a chat id must never half-match.
  run_poll "$home" 'not-a-chat-id' >/dev/null 2>&1
  [ "$(note_count "$home")" = 0 ] \
    || fail "a malformed allowlist accepted a message"
  [ "$(sent_count)" = 0 ] || fail "a malformed allowlist still replied"
  pass "a malformed allowed chat id refuses every message rather than half-matching"
}

test_note_metadata_options_are_validated() {
  local home rc
  home=$(make_home meta)
  rc=0
  env FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note --source 'bad source' body >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && fail "an invalid note source was accepted"
  rc=0
  env FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note --meta $'x=1\nsource=forged' body >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && fail "note metadata could forge a second record field"
  rc=0
  env FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note --meta 'source=forged' body >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && fail "note metadata could overwrite the record's own source field"
  env FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note plain body >/dev/null 2>&1 \
    || fail "the note contract stopped accepting a plain body"
  grep -rqx 'source=text' "$home/state/inbox" \
    || fail "a note with no --source stopped defaulting to text"
  pass "note metadata is validated and the original note contract still holds"
}

test_allowed_message_becomes_a_note
test_a_failed_reaction_never_costs_the_note
test_message_body_is_stored_verbatim
test_unallowlisted_chat_is_silently_dropped
test_unconfigured_allowlist_reports_the_id_only
test_an_inbound_message_wakes_firstmate_to_act_on_it
test_offset_advances_only_after_the_note_is_written
test_restart_after_a_written_note_does_not_duplicate_it
test_restart_before_a_written_note_still_collects_it
test_an_unwritable_note_is_never_acknowledged
test_concurrent_collectors_never_queue_a_message_twice
test_a_crashed_collector_does_not_wedge_the_bridge
test_a_message_body_keeps_its_trailing_blank_lines
test_a_message_waiting_while_nothing_polls_is_collected
test_a_transient_outage_is_absorbed
test_a_sustained_outage_ends_the_cycle_without_retiring_it
test_a_quiet_cycle_is_not_announced
test_the_bot_token_is_never_emitted
test_redaction_survives_an_awkward_token
test_escalation_tier_accepts_only_escalations
test_the_bridge_is_inert_with_no_token
test_a_removed_token_retires_the_source
test_an_invalid_allowed_chat_id_refuses_everything
test_note_metadata_options_are_validated
