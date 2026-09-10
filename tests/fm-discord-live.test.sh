#!/usr/bin/env bash
# Tests for the bounded live Discord activation layer, driven entirely by a
# fake local HTTP server: no real token is read and no network call leaves
# loopback. Covers health, community preflight, idempotent setup apply with
# partial recovery, live reply receipt idempotency and retries, the live
# inbound source with durable monotonic cursors, and token redaction.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-live-tests)
GUILD=111111111111111111
BOT=333333333333333333
CAPTAIN=444444444444444444
FORUM_F=777777777777777772
FAKE_TOKEN=faketoken-abc123
THREAD=888888888888888881

dl() { FM_HOME="$H" "$ROOT/bin/fm-discord-live.sh" "$@"; }

start_server() { # start_server <world-file> <port-file> <guild-id>
  setsid python3 - "$1" "$2" "$FAKE_TOKEN" "$3" > "/tmp/livekeep/fake-server.log" 2>&1 <<'PY' &
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

WORLD, PORT_FILE, TOKEN, GUILD = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
BOT = "333333333333333333"
LOCK = threading.Lock()

def load():
    with open(WORLD, encoding="utf-8") as f:
        return json.load(f)

def save(world):
    with open(WORLD, "w", encoding="utf-8") as f:
        json.dump(world, f)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self, world):
        return self.headers.get("Authorization") == f"Bot {world.get('token') or TOKEN}"

    def _injected(self, path, method):
        world = load()
        inject = world.get("inject") or {}
        if inject and inject.get("remaining", 0) > 0 and inject.get("path") in path and inject.get("method", method) == method:
            inject["remaining"] -= 1
            world["inject"] = inject
            save(world)
            return inject.get("status", 500), inject.get("body", {"message": "injected"})
        return None

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        query = parse_qs(url.query)
        world = load()
        if not self._authorized(world):
            self._send(401, {"message": "Unauthorized", "note": "leak-attempt " + TOKEN})
            return
        hit = self._injected(url.path, "GET")
        if hit:
            self._send(hit[0], hit[1])
            return
        if parts[:2] == ["guilds", GUILD] and len(parts) == 2:
            self._send(200, {"id": GUILD, "name": "Fake Guild", "features": world.get("features", [])})
        elif parts[:2] == ["guilds", GUILD] and parts[2] == "channels":
            self._send(200, world.get("channels", []))
        elif parts == ["users", "@me"]:
            self._send(200, {"id": world.get("bot_id", BOT), "username": "fake-bot"})
        elif len(parts) == 4 and parts[0] == "guilds" and parts[2] == "threads" and parts[3] == "active":
            all_threads = [t for ts in world.get("threads", {}).values() for t in ts]
            self._send(200, {"threads": all_threads})
        elif len(parts) == 4 and parts[2] == "threads" and parts[3] == "active":
            self._send(404, {"code": 0, "message": "channel-scoped active-thread listing is unsupported"})
        elif len(parts) == 3 and parts[2] == "messages":
            after = int(query.get("after", ["0"])[0])
            limit = int(query.get("limit", ["100"])[0])
            msgs = [m for m in world.get("messages", {}).get(parts[1], []) if int(m["id"]) > after]
            msgs.sort(key=lambda m: int(m["id"]), reverse=True)
            self._send(200, msgs[:limit])
        elif len(parts) == 4 and parts[2] == "messages":
            for m in world.get("messages", {}).get(parts[1], []):
                if m["id"] == parts[3]:
                    self._send(200, m)
                    return
            self._send(404, {"message": "Unknown Message"})
        else:
            self._send(404, {"message": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            body = {}
        world = load()
        if not self._authorized(world):
            self._send(401, {"message": "Unauthorized"})
            return
        hit = self._injected(url.path, "POST")
        if hit:
            self._send(hit[0], hit[1])
            return
        if len(parts) == 3 and parts[2] == "channels":
            for c in world.get("channels", []):
                if c.get("name") == body.get("name"):
                    self._send(500, {"code": 50035, "message": "name already exists"})
                    return
            world["counter"] = int(world.get("counter", 900000000000000000)) + 1
            channel = {"id": str(world["counter"]), "name": body.get("name"), "type": body.get("type"),
                       "parent_id": body.get("parent_id"), "available_tags": body.get("available_tags", [])}
            world.setdefault("channels", []).append(channel)
            world["creates"] = int(world.get("creates", 0)) + 1
            save(world)
            self._send(201, channel)
        elif len(parts) == 3 and parts[2] == "typing":
            world["typing"] = int(world.get("typing", 0)) + 1
            save(world)
            self._send(204, {})
        elif len(parts) == 3 and parts[2] == "messages":
            if body.get("allowed_mentions") != {"parse": []}:
                self._send(400, {"message": "allowed_mentions must be empty parse"})
                return
            if body.get("enforce_nonce") is not True or not isinstance(body.get("nonce"), str):
                self._send(400, {"message": "message nonce must be enforced"})
                return
            with LOCK:
                world = load()
                messages = world.setdefault("messages", {}).setdefault(parts[1], [])
                for message in messages:
                    if message.get("nonce") == body["nonce"]:
                        self._send(200, message)
                        return
                world["counter"] = int(world.get("counter", 900000000000000000)) + 1
                message = {"id": str(world["counter"]), "content": body.get("content"),
                           "author": {"id": BOT, "bot": True}, "channel_id": parts[1],
                           "nonce": body["nonce"]}
                messages.append(message)
                world["posts"] = int(world.get("posts", 0)) + 1
                fail_after_accept = int(world.get("fail_after_accept", 0))
                if fail_after_accept:
                    world["fail_after_accept"] = fail_after_accept - 1
                save(world)
            if fail_after_accept:
                self._send(500, {"message": "accepted before response failure"})
                return
            self._send(200, message)
        else:
            self._send(404, {"message": "not found"})

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
  for _ in $(seq 1 50); do
    [ -s "$2" ] && break
    sleep 0.1
  done
  [ -s "$2" ] || fail "fake Discord server did not start"
}

world_set() { python3 - "$WORLD" "$1" <<'PY'
import json, sys
world, update = json.load(open(sys.argv[1])), json.loads(sys.argv[2])
world.update(update)
json.dump(world, open(sys.argv[1], "w"))
PY
}

new_home() {
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/data" "$H/config"
  FM_HOME="$H" "$ROOT/bin/fm-discord-workspace.sh" sample-config > "$H/config/discord-workspace.json"
  python3 - "$H/config/discord-workspace.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["live"]["posting"] = True
data["live"]["polling"] = True
data["outbound"]["live_posting"] = True
data["profiles"]["proapplis"]["thread_ids"]["exchange"] = ["888888888888888881"]
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
  printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
}

# --- fake sops + fake server -------------------------------------------------
cat > "$TMP_ROOT/fake-sops" <<FAKE
#!/usr/bin/env bash
[ "\$1" = "-d" ] || exit 64
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: $FAKE_TOKEN\n'
FAKE
chmod +x "$TMP_ROOT/fake-sops"

WORLD="$TMP_ROOT/world.json"
PORT_FILE="$TMP_ROOT/port"
printf '{"features":["COMMUNITY"],"channels":[],"threads":{},"messages":{},"creates":0,"posts":0,"counter":900000000000000000}\n' > "$WORLD"
start_server "$WORLD" "$PORT_FILE" "$GUILD"
echo "$$" > /tmp/livekeep/test-pid
PORT=$(cat "$PORT_FILE")
export FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:$PORT"
export FM_DISCORD_LIVE_SOPS="$TMP_ROOT/fake-sops"
export FM_DISCORD_LIVE_RETRY_SLEEP=0

# --- 1. live health verifies exact guild and bot identity --------------------
new_home h1
out=$(dl health --config "$H/config/discord-workspace.json" 2>&1) \
  || fail "health failed against the fake server: $out"
assert_contains "$out" "bot identity ok: fake-bot" "health verifies the configured bot identity"
assert_contains "$out" "operations guild ok: Fake Guild" "health verifies the configured operations guild"
assert_not_contains "$out" "community" "health does not inspect or report Community mode"
pass "live health verifies exact guild and bot identity"

# --- 2. health refuses a bot identity mismatch -------------------------------
new_home h2
world_set '{"bot_id":"999999999999999999"}'
out=$(dl health --config "$H/config/discord-workspace.json" 2>&1) && fail "health accepted a foreign bot identity" || true
assert_contains "$out" "does not match the configured bot user id" "health refuses a bot identity mismatch"
world_set '{"bot_id":"'"$BOT"'"}'
pass "live health refuses a bot identity mismatch"

# --- 3. the token is redacted from every failure path ------------------------
new_home h3
# A sops stub that emits a token the server rejects.
world_set '{"token":"wrong"}'
cat > "$TMP_ROOT/fake-sops-wrong" <<FAKE
#!/usr/bin/env bash
[ "\$1" = "-d" ] || exit 64
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: leakedtoken-xyz\n'
FAKE
out=$(dl health --config "$H/config/discord-workspace.json" 2>&1) && fail "health accepted a wrong token" || true
assert_contains "$out" "401" "a rejected token surfaces the HTTP failure"
printf '%s' "$out" | grep -q "leakedtoken-xyz" && fail "the token leaked into failure output: $out"
pass "the bot token is redacted from failure output"
world_set '{"token":null}'

# --- 4. setup apply creates forums directly without any COMMUNITY dependency -
new_home h4
world_set '{"features":[]}'
out=$(dl setup-apply --config "$H/config/discord-workspace.json" 2>&1) \
  || fail "setup apply failed on a guild without COMMUNITY: $out"
CREATES=$(python3 -c "import json;print(json.load(open('$WORLD'))['creates'])")
[ "$CREATES" = 9 ] || fail "setup apply created $CREATES channels instead of 9"
FORUMS=$(python3 -c "import json;print(sum(1 for c in json.load(open('$WORLD'))['channels'] if c['type']==15))")
[ "$FORUMS" = 6 ] || fail "setup apply created $FORUMS forums instead of 6"
pass "setup apply creates forum channels directly without any COMMUNITY prerequisite"

# --- 5. setup apply is idempotent and tags forums ----------------------------
new_home h5
out=$(dl setup-apply --config "$H/config/discord-workspace.json" 2>&1) \
  || fail "setup apply failed: $out"
CREATES=$(python3 -c "import json;print(json.load(open('$WORLD'))['creates'])")
CFG_IDS=$(python3 - "$H/config/discord-workspace.json" <<'CFGIDS'
import json, sys
data = json.load(open(sys.argv[1]))
p = data["profiles"]["firstmate"]
print(all(str(p[k]).isdigit() for k in ("category_id", "exchange_forum_id", "artifact_forum_id")))
CFGIDS
)
[ "$CFG_IDS" = "True" ] || fail "setup apply did not write non-secret ids into the config"
TAGS_OK=$(python3 - "$WORLD" <<'TAGSOK'
import json, sys
world = json.load(open(sys.argv[1]))
forums = [c for c in world["channels"] if c["type"] == 15]
print(bool(forums) and all(c["available_tags"] for c in forums))
TAGSOK
)
[ "$TAGS_OK" = "True" ] || fail "created forums lack the configured tag vocabulary"
pass "setup apply creates the three categories with exchanges and artifacts forums plus tags"

# --- 6. setup apply rerun reuses everything ---------------------------------
out=$(dl setup-apply --config "$H/config/discord-workspace.json" 2>&1) \
  || fail "second setup apply failed: $out"
CREATES2=$(python3 -c "import json;print(json.load(open('$WORLD'))['creates'])")
[ "$CREATES2" = "$CREATES" ] || fail "second setup apply created $((CREATES2 - CREATES)) duplicate channels"
pass "setup apply reuses exact existing categories and forums on rerun"

# --- 7. setup apply recovers from a partial run ------------------------------
new_home h7
python3 - "$WORLD" <<'RESETW'
import json, sys
world = json.load(open(sys.argv[1]))
world["counter"] = int(world["counter"]) + 1
world["channels"] = [{"id": str(world["counter"]), "name": "System / Firstmate", "type": 4, "parent_id": "", "available_tags": []}]
world["creates"] = 1
json.dump(world, open(sys.argv[1], "w"))
RESETW
out=$(dl setup-apply --config "$H/config/discord-workspace.json" 2>&1) \
  || fail "setup apply failed on a partially provisioned guild: $out"
REUSED=$(python3 - "$H/config/discord-workspace.json" "$WORLD" <<'REUSEOK'
import json, sys
data = json.load(open(sys.argv[1]))
world = json.load(open(sys.argv[2]))
pre = [c for c in world["channels"] if c["name"] == "System / Firstmate" and c["type"] == 4]
print(len(pre) == 1 and data["profiles"]["firstmate"]["category_id"] == pre[0]["id"])
REUSEOK
)
[ "$REUSED" = "True" ] || fail "setup apply did not reuse the pre-created category"
CHANNELS7=$(python3 -c "import json;print(len(json.load(open('$WORLD'))['channels']))")
[ "$CHANNELS7" = 9 ] || fail "partial recovery produced $CHANNELS7 channels instead of 9"
pass "setup apply reuses exact existing channels and recovers from partial runs"

# --- 8. setup apply refuses a wrong-shape name collision ---------------------
new_home h8
python3 - "$WORLD" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
world["counter"] = int(world["counter"]) + 1
# A text channel squatting on a planned forum name must stop the apply.
world["channels"] = [{"id": str(world["counter"]), "name": "firstmate-exchanges", "type": 0, "parent_id": "", "available_tags": []}]
world["creates"] = 0
json.dump(world, open(sys.argv[1], "w"))
PY
out=$(dl setup-apply --config "$H/config/discord-workspace.json" 2>&1) && fail "setup apply accepted a wrong-shape collision" || true
assert_contains "$out" "mismatched shape" "a wrong-shape collision is named as such"
assert_not_contains "$out" "text channel substitute" "no silent substitution is claimed"
pass "setup apply refuses name collisions with a different channel type or parent"

# --- 9. live reply posts once, records a receipt, and replays idempotently ---
new_home h9
printf 'Round-trip reply body.\n' > "$TMP_ROOT/reply.txt"
REQUEST_ID="discord:$GUILD:$THREAD:777777777777777701"
out=$(dl live-reply --config "$H/config/discord-workspace.json" --request-id "$REQUEST_ID" --text-file "$TMP_ROOT/reply.txt" 2>&1) \
  || fail "live reply failed: $out"
POSTS=$(python3 -c "import json;print(json.load(open('$WORLD'))['posts'])")
[ "$POSTS" = 1 ] || fail "live reply posted $POSTS times"
assert_grep "receipt recorded" <(printf '%s\n' "$out") || true
out2=$(dl live-reply --config "$H/config/discord-workspace.json" --request-id "$REQUEST_ID" --text-file "$TMP_ROOT/reply.txt" 2>&1) \
  || fail "live reply replay failed: $out2"
assert_contains "$out2" "no second delivery" "replay reports no second delivery"
POSTS2=$(python3 -c "import json;print(json.load(open('$WORLD'))['posts'])")
[ "$POSTS2" = 1 ] || fail "replay posted again ($POSTS2 posts)"
pass "live reply posts once with empty allowed_mentions and replays through the receipt"

# --- 10. live reply retries transient server errors then records once --------
new_home h10
printf 'Retry reply body.\n' > "$TMP_ROOT/retry-reply.txt"
world_set '{"inject":{"path":"/messages","method":"POST","remaining":2,"status":500}}'
out=$(dl live-reply --config "$H/config/discord-workspace.json" --request-id "$REQUEST_ID" --text-file "$TMP_ROOT/retry-reply.txt" --nonce retry-nonce 2>&1) \
  || fail "live reply did not survive two transient 500s: $out"
POSTS3=$(python3 -c "import json;print(json.load(open('$WORLD'))['posts'])")
[ "$POSTS3" = 2 ] || fail "retried reply produced $POSTS3 posts instead of 1 new post"
assert_contains "$out" "receipt recorded" "the retried reply records its receipt"
pass "live reply retries transient 5xx responses and records the receipt once"

# --- 11. live reply fails without a receipt after sustained errors -----------
new_home h11
world_set '{"inject":{"path":"/messages","method":"POST","remaining":9,"status":500,"body":{"message":"injected faketoken-abc123"}}}'
out=$(dl live-reply --config "$H/config/discord-workspace.json" --request-id "$REQUEST_ID" --text-file "$TMP_ROOT/reply.txt" --nonce fail-nonce 2>&1) \
  && fail "live reply accepted sustained server errors" || true
printf '%s' "$out" | grep -q "faketoken-abc123" && fail "the token leaked through an injected error body: $out"
RECEIPTS=$(find "$H/state/discord-workspace/receipts" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "$RECEIPTS" = 0 ] || fail "a failed reply left a durable receipt"
world_set '{"inject":null}'
pass "sustained API failures record no receipt and never leak the token"

# --- 12. live source ingests only captain messages and advances cursors ------
new_home h12
CFG12="$H/config/discord-workspace.json"
python3 - "$WORLD" <<PY
import json
world = json.load(open("$WORLD"))
world["counter"] = int(world["counter"]) + 1
forum = str(world["counter"])
world["counter"] += 1
thread = str(world["counter"])
world["counter"] += 1
stale = str(world["counter"])
world["threads"] = {"$FORUM_F": [{"id": thread, "parent_id": "$FORUM_F", "name": "tab"}]}
world["messages"] = {thread: [
    {"id": stale, "guild_id": "$GUILD", "channel_id": thread, "author": {"id": "$CAPTAIN"}, "content": "older captain message"},
    {"id": str(int(stale) + 1), "guild_id": "$GUILD", "channel_id": thread, "author": {"id": "333333333333333333", "bot": True}, "content": "bot message"},
    {"id": str(int(stale) + 2), "guild_id": "$GUILD", "channel_id": thread, "author": {"id": "121212121212121212"}, "content": "unknown author"},
    {"id": str(int(stale) + 3), "guild_id": "$GUILD", "channel_id": thread, "author": {"id": "$CAPTAIN"}, "content": "newest captain request"},
]}
world["threads"]["$FORUM_F"] = world["threads"]["$FORUM_F"] + [{"id": "888888888888888999", "parent_id": "wrong-parent", "name": "foreign"}]
world["threads"]["555555555555555553"] = [{"id": "888888888888888998", "parent_id": "555555555555555553", "name": "artifacts tab"}]
world["messages"]["888888888888888998"] = [
    {"id": "888888888888888997", "guild_id": "$GUILD", "channel_id": "888888888888888998", "author": {"id": "$CAPTAIN"}, "content": "artifacts forum child must not ingest"},
]
json.dump(world, open("$WORLD", "w"))
PY
out=$(dl live-source --config "$CFG12" 2>&1) || fail "live source failed: $out"
NOTES=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTES" = 2 ] || fail "live source created $NOTES notes instead of 2 (captain messages only)"
grep -rl "newest captain request" "$H/state/inbox" >/dev/null 2>&1 || fail "the newest captain message was not ingested"
grep -rl "older captain message" "$H/state/inbox" >/dev/null 2>&1 || fail "the older captain message was not ingested"
if grep -rl "bot message" "$H/state/inbox"/*.note >/dev/null 2>&1; then fail "a bot message was ingested"; fi
CURSOR=$(find "$H/state/discord-workspace/cursors" -name '*.cursor' -exec cat {} + | sort -n | tail -1)
EXPECTED=$(python3 -c "import json;w=json.load(open('$WORLD'));print(max(int(m['id']) for ms in w['messages'].values() for m in ms))")
[ "$CURSOR" = "$EXPECTED" ] || fail "the cursor is $CURSOR instead of the newest id $EXPECTED"
# Replay is a no-op: same messages, monotonic cursor, no duplicate notes.
BEFORE_NOTES=$NOTES
out=$(dl live-source --config "$CFG12" 2>&1) || fail "second live source pass failed: $out"
AFTER_NOTES=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$AFTER_NOTES" = "$BEFORE_NOTES" ] || fail "a second source pass duplicated notes"
# A late lower-id message must not move the cursor backwards or re-ingest.
python3 - "$WORLD" <<PY
import json
world = json.load(open("$WORLD"))
thread = next(iter(world["messages"]))
world["messages"][thread].insert(0, {"id": "1", "guild_id": "$GUILD", "channel_id": thread, "author": {"id": "$CAPTAIN"}, "content": "late stale message"})
json.dump(world, open("$WORLD", "w"))
PY
dl live-source --config "$CFG12" >/dev/null 2>&1 || true
CURSOR2=$(find "$H/state/discord-workspace/cursors" -name '*.cursor' -exec cat {} + | sort -n | tail -1)
[ "$CURSOR2" = "$EXPECTED" ] || fail "a stale lower-id message moved the cursor backwards to $CURSOR2"
FINAL_NOTES=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$FINAL_NOTES" = "$BEFORE_NOTES" ] || fail "the stale message was ingested after the cursor advanced"
DYNAMIC_REQUEST=$(python3 - "$H/state/discord-workspace/requests" <<'PY'
import glob, json, os, sys
records = [json.load(open(path)) for path in glob.glob(os.path.join(sys.argv[1], "*.json"))]
print(max(records, key=lambda record: int(record["message_id"]))["request_id"])
PY
)
out=$(dl live-reply --config "$CFG12" --request-id "$DYNAMIC_REQUEST" --text-file "$TMP_ROOT/reply.txt" 2>&1) \
  || fail "reply to an ingested dynamic forum thread failed: $out"
assert_contains "$out" "receipt recorded" "the dynamic forum request resolves through its persisted record"
pass "live source ingests captain messages and preserves dynamic reply routing"

# --- 13. live roundtrip posts and verifies against Discord ------------------
new_home h13
out=$(dl live-roundtrip --config "$H/config/discord-workspace.json" --request-id "$REQUEST_ID" --text-file "$TMP_ROOT/reply.txt" --nonce rt-nonce 2>&1) \
  || fail "live roundtrip failed: $out"
assert_contains "$out" "round-trip verified" "the roundtrip verifies the posted message"
out2=$(dl live-roundtrip --config "$H/config/discord-workspace.json" --request-id "$REQUEST_ID" --text-file "$TMP_ROOT/reply.txt" --nonce rt-nonce 2>&1) \
  || fail "roundtrip replay failed: $out2"
assert_contains "$out2" "round-trip verified against the recorded message id" "roundtrip replay verifies from the receipt"
pass "live roundtrip posts once and verifies in both fresh and replay paths"



# --- 14. process-event arm gates on the live polling flag --------------------
pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
ped() { FM_HOME="$1" "$ROOT/bin/fm-procevent-discord-workspace.sh" "${@:2}"; }
new_home h14
CFG14="$H/config/discord-workspace.json"
python3 - "$CFG14" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["live"]["polling"] = False
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
arm_status=0
arm_out=$(ped "$H" arm --config "$CFG14" 2>&1) || arm_status=$?
[ "$arm_status" -ne 0 ] || fail "arm registered while live polling was disabled"
assert_contains "$arm_out" "live polling is disabled" "arm refusal names the disabled flag"
out=$(ped "$H" arm --dry-run --config "$CFG14")
assert_contains "$out" "register command:" "arm dry-run prints the registration command"
pass "process-event arm refuses while live polling is disabled and prints the registration command"

# --- 15. arm registers, start repeats through the inbox seam, retire clears --
new_home h15
CFG15="$H/config/discord-workspace.json"
out=$(ped "$H" arm --config "$CFG15" 2>&1) || fail "arm failed with live polling enabled: $out"
assert_contains "$out" "live source registered" "arm registers the live source"
assert_grep "discord-workspace" <(pe "$H" list) || fail "the registered source is missing from the list"
out=$(pe "$H" start discord-workspace 2>&1) || fail "first procevent start failed: $out"
NOTES15=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTES15" -ge 1 ] || fail "the registered live source ingested nothing on start: start output: $out; claims: $(ls "$H/state/procevent-inbox" 2>/dev/null); result: $(cat "$H/state/procevent-inbox"/*.result 2>/dev/null | head -5)"
out=$(pe "$H" start discord-workspace 2>&1) || fail "second procevent start failed: $out"
NOTES15B=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTES15B" = "$NOTES15" ] || fail "a repeated start duplicated notes ($NOTES15 -> $NOTES15B)"
pe "$H" retire discord-workspace >/dev/null 2>&1 || fail "retire failed"
if pe "$H" list | grep -q discord-workspace; then fail "retire left the registration in place"; fi
pass "process-event arm registers, repeated starts stay idempotent, and retire clears the source"
# --- 16. registered source: empty scans are silent no-results ----------------
new_home h16
CFG16="$H/config/discord-workspace.json"
python3 - "$WORLD" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
world["threads"] = {}
world["messages"] = {}
json.dump(world, open(sys.argv[1], "w"))
PY
ped() { FM_HOME="$1" "$ROOT/bin/fm-procevent-discord-workspace.sh" "${@:2}"; }
ped "$H" arm --config "$CFG16" >/dev/null || fail "arm failed for the empty-scan case"
out=$(pe "$H" start discord-workspace 2>&1) || fail "empty-scan start failed: $out"
assert_contains "$out" "no-result" "an empty scan records no-result: files: $(find "$H/state/procevent-inbox" -type f 2>/dev/null | head -2 | xargs -r head -c 500)"
CAPTURES=$(find "$H/state/procevent-inbox" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$CAPTURES" = 0 ] || fail "an empty scan captured $CAPTURES result files: $(head -c 400 "$H/state/procevent-inbox"/* 2>/dev/null)"
out=$(pe "$H" start discord-workspace 2>&1) || fail "repeated empty scan failed: $out"
CAPTURES=$(find "$H/state/procevent-inbox" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$CAPTURES" = 0 ] || fail "repeated empty scans captured results"
pass "registered source: repeated empty scans create zero unhandled captures"

# --- 17. one captain message makes exactly one note; a repeat makes none -----
python3 - "$WORLD" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
world["counter"] = int(world["counter"]) + 1
thread = str(world["counter"])
world["threads"] = {"777777777777777772": [{"id": thread, "parent_id": "777777777777777772", "name": "control"}]}
world["messages"] = {thread: [
    {"id": str(world["counter"] + 1), "guild_id": "111111111111111111", "channel_id": thread,
     "author": {"id": "444444444444444444"}, "content": "one real captain message"},
]}
json.dump(world, open(sys.argv[1], "w"))
PY
out=$(pe "$H" start discord-workspace 2>&1) || fail "captain-message start failed: $out"
NOTES=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTES" = 1 ] || fail "one captain message produced $NOTES notes instead of 1"
out=$(pe "$H" start discord-workspace 2>&1) || fail "repeat after captain message failed: $out"
NOTES2=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTES2" = 1 ] || fail "a repeat produced $((NOTES2 - NOTES)) extra notes"
pass "one captain message makes exactly one inbox note and a repeat makes none"

# --- 18. a genuine failure is captured as bounded redacted evidence ----------
world_set '{"inject":{"path":"/threads/active","method":"GET","remaining":9,"status":500,"body":{"message":"threads listing down faketoken-abc123"}}}'
BEFORE_NOTES=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
BEFORE_CURSORS=$(find "$H/state/discord-workspace/cursors" -type f 2>/dev/null | wc -l | tr -d ' ')
out=$(pe "$H" start discord-workspace 2>&1) || fail "failing start crashed the runner: $out"
assert_contains "$out" "captured" "a genuine failure is captured as a result"
grep -rl "discord live source failed" "$H/state/procevent-inbox" >/dev/null 2>&1 \
  || fail "the captured result lacks actionable failure evidence"
grep -rl "faketoken-abc123" "$H/state/procevent-inbox" >/dev/null 2>&1 && fail "a captured result leaked the token"
NOTES3=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTES3" = "$BEFORE_NOTES" ] || fail "a failed pass changed durable notes"
CURSORS=$(find "$H/state/discord-workspace/cursors" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$CURSORS" = "$BEFORE_CURSORS" ] || fail "a failed pass advanced cursors ($BEFORE_CURSORS -> $CURSORS)"
world_set '{"inject":null}'
pass "genuine failures stay visible, redacted, and retryable without advancing cursors"

# --- 19. deployment shape: installed main runner without the task adapter ----
new_home h19
MAINBIN="$TMP_ROOT/mainbin"
mkdir -p "$MAINBIN"
for f in fm-procevent.sh fm-pr-lib.sh fm-wake-lib.sh fm-procevent-lib.sh fm-classify-lib.sh fm-timeout-lib.sh fm-lock-lib.sh fm-harness.sh; do
  cp "$ROOT/bin/$f" "$MAINBIN/$f"
done
# The emulated installed runner runs from MAINBIN while FM_ROOT points at
# the checkout whose bin owns the Discord adapter - the real deployment shape.
pe19() { FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$MAINBIN/fm-procevent.sh" "${@:2}"; }
pe19 "$H" register discord-workspace discord-workspace -- \
  "$ROOT/bin/fm-procevent-discord-workspace.sh" source --config "$H/config/discord-workspace.json" >/dev/null \
  || fail "registration through the emulated installed runner failed"
out=$(pe19 "$H" start discord-workspace 2>&1) || fail "installed-runner start failed: $out"
NOTES19=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTES19" = 1 ] || fail "installed-runner start produced $NOTES19 notes instead of 1"
out=$(pe19 "$H" start discord-workspace 2>&1) || fail "installed-runner repeat failed: $out"
NOTES19B=$(find "$H/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTES19B" = 1 ] || fail "installed-runner repeat duplicated notes"
probeR1=$(python3 -c "import socket;s=socket.socket();s.settimeout(1);print(s.connect_ex(('127.0.0.1',$PORT)))")
echo "PROBE_pre_retire=$probeR1"
pe19 "$H" retire discord-workspace >/dev/null 2>&1 || fail "installed-runner retire failed"
probeR2=$(python3 -c "import socket;s=socket.socket();s.settimeout(1);print(s.connect_ex(('127.0.0.1',$PORT)))")
echo "PROBE_post_retire=$probeR2"
pass "registered argv to the task copy works under a main runner from a different code root"
probeS1=$(python3 -c "import socket;s=socket.socket();s.settimeout(1);print(s.connect_ex(('127.0.0.1',$PORT)))")
echo "PROBE_S1=$probeS1"
sleep 2
probeS2=$(python3 -c "import socket;s=socket.socket();s.settimeout(1);print(s.connect_ex(('127.0.0.1',$PORT)))")
echo "PROBE_S2=$probeS2"


# --- 20. live mirror posts once, converges with replies, fires typing --------
new_home h20
CFG20="$H/config/discord-workspace.json"
printf 'Mirrored conversational text.\n' > "$TMP_ROOT/mirror.txt"
out=$(FM_DISCORD_LIVE_API_BASE="$FM_DISCORD_LIVE_API_BASE" dl live-post --config "$CFG20" --thread "$THREAD" --tag main --text-file "$TMP_ROOT/mirror.txt" 2>&1) \
  || fail "mirror post failed: base=$FM_DISCORD_LIVE_API_BASE out=$out probe=$(python3 -c "import socket;s=socket.socket();s.settimeout(1);print(s.connect_ex(('127.0.0.1',$PORT)))")"
assert_contains "$out" "receipt recorded" "the mirror records its receipt"
POSTS=$(python3 -c "import json;print(json.load(open('$WORLD'))['posts'])")
TYPING=$(python3 -c "import json;print(json.load(open('$WORLD')).get('typing',0))")
[ "$TYPING" -ge 1 ] || fail "no typing marker fired around the mirror post"
out=$(dl live-post --config "$CFG20" --thread "$THREAD" --tag main --text-file "$TMP_ROOT/mirror.txt" 2>&1) \
  || fail "mirror replay failed: $out"
assert_contains "$out" "no second post" "mirror replay reports convergence"
POSTS2=$(python3 -c "import json;print(json.load(open('$WORLD'))['posts'])")
[ "$POSTS2" = "$POSTS" ] || fail "mirror replay posted again"
# An explicit reply with the same text converges on the mirror's delivery.
out=$(dl live-reply --config "$CFG20" --request-id "discord:$GUILD:$THREAD:777777777777777701" --text-file "$TMP_ROOT/mirror.txt" --nonce converge-nonce 2>&1) \
  || fail "converging reply failed: $out"
assert_contains "$out" "no second delivery" "an explicit reply with identical text converges on the mirror"
# Operational text never mirrors.
printf 'FIRSTMATE WATCHER WAKE: stale\n' > "$TMP_ROOT/op.txt"
op_status=0
op_out=$(dl live-post --config "$CFG20" --thread "$THREAD" --tag main --text-file "$TMP_ROOT/op.txt" 2>&1) || op_status=$?
[ "$op_status" -ne 0 ] || fail "operational text was mirrored"
assert_contains "$op_out" "refusing to mirror operational text" "operational markers are refused before any post"
CURSOR_ENTRIES=$(python3 -c "import json;print(len(json.load(open('$H/state/discord-workspace/mirror-cursor.json'))))")
[ "$CURSOR_ENTRIES" = 1 ] || fail "the mirror cursor logged $CURSOR_ENTRIES deliveries instead of 1"
# Mirror refuses a thread outside the configured allowlist.
out=$(dl live-post --config "$CFG20" --thread 123456789012345678 --tag main --text-file "$TMP_ROOT/mirror.txt" 2>&1) \
  && fail "mirror accepted a non-allowlisted thread" || true
assert_contains "$out" "outside the configured allowlist" "the mirror stays bounded to allowlisted threads"
out=$(dl live-post --config "$CFG20" --thread "$FORUM_F" --tag main --text-file "$TMP_ROOT/mirror.txt" 2>&1) \
  && fail "mirror accepted a forum channel as a message target" || true
assert_contains "$out" "outside the configured allowlist" "forum channels are not accepted as message targets"
pass "live mirror posts once, fires typing, converges with replies, and stays allowlist-bounded"

new_home h21
world_set '{"messages":{},"posts":0,"typing":0,"fail_after_accept":0}'
printf 'Concurrent outbound body.\n' > "$TMP_ROOT/concurrent.txt"
pids=""
for i in $(seq 1 8); do
  dl live-post --config "$H/config/discord-workspace.json" --thread "$THREAD" --tag main --text-file "$TMP_ROOT/concurrent.txt" > "$TMP_ROOT/concurrent-$i.out" 2>&1 &
  pids="$pids $!"
done
for pid in $pids; do
  wait "$pid" || fail "concurrent live post failed"
done
POSTS=$(python3 -c "import json;print(json.load(open('$WORLD'))['posts'])")
[ "$POSTS" = 1 ] || fail "concurrent live posts produced $POSTS Discord messages"
pass "concurrent outbound delivery serializes before posting"

new_home h22
world_set '{"messages":{},"posts":0,"typing":0,"fail_after_accept":1}'
out=$(dl live-reply --config "$H/config/discord-workspace.json" --request-id "$REQUEST_ID" --text-file "$TMP_ROOT/reply.txt" 2>&1) \
  || fail "accepted-before-response retry failed: $out"
POSTS=$(python3 -c "import json;print(json.load(open('$WORLD'))['posts'])")
[ "$POSTS" = 1 ] || fail "accepted-before-response retry produced $POSTS Discord messages"
assert_contains "$out" "receipt recorded" "the accepted message retry records its receipt"
pass "Discord nonce converges the post-before-receipt retry window"

# --- cleanup -----------------------------------------------------------------
kill %1 2>/dev/null || true