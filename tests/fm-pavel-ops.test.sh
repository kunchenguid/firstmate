#!/usr/bin/env bash
# Behavior-level regressions for Pavel intake, authority, delivery, and notification.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OPS="$ROOT/bin/fm-pavel-ops.sh"
TMP_ROOT=$(fm_test_tmproot fm-pavel-ops)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
TASK_DB="$TMP_ROOT/tasks"
HTTP_LOG="$TMP_ROOT/http.log"
UPDATES_FILE="$TMP_ROOT/getUpdates.json"
PAVEL_STATUS_FILE="$TMP_ROOT/pavel-status.json"
HTTP_PID=

cleanup() {
  if [ -n "$HTTP_PID" ]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects/aln/.git" "$FAKEBIN" "$TASK_DB"
printf 'TERENTYEV_BOT_TOKEN=test-token\n' > "$HOME_DIR/telegram.env"

cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -eu
cmd=$1
shift
case "$cmd" in
  add)
    id=$1
    shift
    count="$TASK_DB/.add-count"
    n=$(cat "$count" 2>/dev/null || printf '0')
    printf '%s\n' $((n + 1)) > "$count"
    printf '%s\n' "$*" > "$TASK_DB/$id"
    ;;
  show)
    id=$1
    [ -f "$TASK_DB/$id" ] || exit 1
    cat "$TASK_DB/$id"
    ;;
  hold)
    id=$1
    shift
    printf '%s\n' "$*" >> "$TASK_DB/$id.holds"
    ;;
  unhold)
    id=$1
    printf 'unheld\n' >> "$TASK_DB/$id.holds"
    ;;
  list)
    for path in "$TASK_DB"/pavel-*; do
      [ -f "$path" ] || continue
      basename "$path"
    done
    ;;
  *)
    printf 'unexpected tasks-axi command: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
SH
chmod 0755 "$FAKEBIN/tasks-axi"

cat > "$FAKEBIN/captain-hold" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TASK_DB/.captain-holds"
SH
chmod 0755 "$FAKEBIN/captain-hold"

cat > "$FAKEBIN/fm-brief" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
project=$2
[ "$project" = "$FM_HOME/projects/aln" ] || { printf 'wrong project path: %s\n' "$project" >&2; exit 1; }
printf 'brief %s %s\n' "$id" "$project" >> "$TASK_DB/.owners"
mkdir -p "$FM_HOME/data/$id"
printf 'Delivery contract: mode=no-mistakes\nPavel autonomous brief\n' > "$FM_HOME/data/$id/brief.md"
SH
chmod 0755 "$FAKEBIN/fm-brief"

cat > "$FAKEBIN/fm-spawn" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
project=$2
[ "$project" = "$FM_HOME/projects/aln" ] || { printf 'wrong project path: %s\n' "$project" >&2; exit 1; }
mkdir -p "$FM_HOME/state" "$FM_HOME/worktrees/$id"
printf 'kind=ship\nharness=pi\nmode=no-mistakes\nyolo=on\nworktree=%s\n' "$FM_HOME/worktrees/$id" > "$FM_HOME/state/$id.meta"
SH
chmod 0755 "$FAKEBIN/fm-spawn"

cat > "$FAKEBIN/fm-status" <<'SH'
#!/usr/bin/env bash
set -eu
cat "$PAVEL_STATUS_FILE"
SH
chmod 0755 "$FAKEBIN/fm-status"

cat > "$FAKEBIN/fm-crew-state" <<'SH'
#!/usr/bin/env bash
set -eu
cat "$PAVEL_STATUS_FILE"
SH
chmod 0755 "$FAKEBIN/fm-crew-state"

cat > "$FAKEBIN/fm-pr-check" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
pr=$2
printf 'pr-check %s %s\n' "$id" "$pr" >> "$TASK_DB/.owners"
printf 'pr=%s\n' "$pr" >> "$FM_HOME/state/$id.meta"
if [ -f "$TASK_DB/.pr-check-head-change" ]; then
  printf 'pr_head=%s\n' "$(cat "$TASK_DB/.pr-check-head-change")" >> "$FM_HOME/state/$id.meta"
fi
SH
chmod 0755 "$FAKEBIN/fm-pr-check"

cat > "$FAKEBIN/fm-pr-merge" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
pr=$2
printf 'pr-merge %s %s\n' "$id" "$pr" >> "$TASK_DB/.owners"
if [ ! -f "$TASK_DB/.merge-unconfirmed" ]; then
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\no/r\n%s\n' "${pr##*/}" > "$FM_HOME/state/$id.pr-poll-merge-notified"
  chmod 0600 "$FM_HOME/state/$id.pr-poll-merge-notified"
fi
printf 'forge reports PR merged at verified head\n'
SH
chmod 0755 "$FAKEBIN/fm-pr-merge"

cat > "$FAKEBIN/fm-merge-confirm" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
pr=$2
head=$3
if [ -f "$TASK_DB/.merge-confirm-head" ]; then
  head=$(cat "$TASK_DB/.merge-confirm-head")
fi
printf '{"state":"merged","merged":true,"pr_url":"%s","pr_head":"%s","task_id":"%s"}\n' "$pr" "$head" "$id"
SH
chmod 0755 "$FAKEBIN/fm-merge-confirm"

cat > "$FAKEBIN/fm-live-check" <<'SH'
#!/usr/bin/env bash
set -eu
payload=$1
python3 - "$payload" "$TASK_DB" <<'PY'
import json
import os
import sys

payload_path, task_db = sys.argv[1:3]
with open(payload_path, encoding="utf-8") as handle:
    contract = json.load(handle)
for key in ("schema", "event_id", "task_id", "accepted_intent", "source", "pr_url", "live_url", "intent_digest"):
    if not contract.get(key):
        raise SystemExit(f"missing {key}")
expected_path = os.path.join(task_db, f"live-{contract['event_id']}.expected")
with open(expected_path, encoding="utf-8") as handle:
    actual_expected = handle.read().strip()
if contract.get("expected") != actual_expected:
    raise SystemExit("event-specific live expectation did not match")
if contract.get("absent") not in ("", "old-price"):
    raise SystemExit("unexpected absent text")
requires_answer = os.path.join(task_db, f"live-{contract['event_id']}.requires-answer")
if os.path.exists(requires_answer):
    with open(requires_answer, encoding="utf-8") as handle:
        answer = handle.read().strip()
    accepted = contract.get("accepted_contract") or {}
    clarifications = accepted.get("clarifications") or []
    if not any(item.get("answer") == answer and (item.get("reply_source") or {}).get("text") == answer for item in clarifications):
        raise SystemExit("clarification answer missing from live payload")
with open(os.path.join(task_db, ".owners"), "a", encoding="utf-8") as handle:
    handle.write(f"live-check {contract['event_id']} {contract['task_id']} {contract['expected']}\n")
print(json.dumps({
    "schema": "fm-pavel-ops-live-proof.v1",
    "verified": True,
    "event_id": contract["event_id"],
    "task_id": contract["task_id"],
    "live_url": contract["live_url"],
    "intent_digest": contract["intent_digest"],
    "evidence": "task-bound live proof",
}))
PY
SH
chmod 0755 "$FAKEBIN/fm-live-check"

cat > "$FAKEBIN/fm-deploy" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'deploy %s\n' "$1" >> "$TASK_DB/.owners"
SH
chmod 0755 "$FAKEBIN/fm-deploy"

cat > "$TMP_ROOT/server.py" <<'PY'
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.environ["HTTP_LOG"], "a", encoding="utf-8") as handle:
            handle.write(self.path + "\n")
        with open(os.environ["UPDATES_FILE"], encoding="utf-8") as handle:
            payload = handle.read().encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length).decode("utf-8", "replace")
        with open(os.environ["HTTP_LOG"], "a", encoding="utf-8") as handle:
            handle.write(self.path + "\t" + body + "\n")
        payload = json.dumps({"ok": True, "result": {"message_id": 777}}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *_args):
        pass

HTTPServer(("127.0.0.1", int(os.environ["HTTP_PORT"])), Handler).serve_forever()
PY
HTTP_PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
printf '{"ok": true, "result": []}\n' > "$UPDATES_FILE"
HTTP_LOG="$HTTP_LOG" UPDATES_FILE="$UPDATES_FILE" HTTP_PORT="$HTTP_PORT" python3 "$TMP_ROOT/server.py" &
HTTP_PID=$!

cat > "$HOME_DIR/config/pavel-ops.json" <<JSON
{
  "version": 1,
  "enabled": true,
  "principal": "Pavel",
  "project": "aln",
  "sender_ids": ["pavel"],
  "chat_ids": ["group"],
  "worker": {"harness": "pi", "mode": "no-mistakes", "yolo": "on"},
  "budget": {"per_action_rub": 0, "per_day_rub": 0},
  "delivery": {
    "live_url": "https://example.test/product",
    "expected_text": "139000",
    "absent_text": "old-price",
    "deploy_command": "$FAKEBIN/fm-deploy",
    "live_check_command": "$FAKEBIN/fm-live-check",
    "completion_text": "Готово: цена уже на сайте."
  },
  "telegram": {
    "env_file": "$HOME_DIR/telegram.env",
    "token_key": "TERENTYEV_BOT_TOKEN",
    "outbound_chat_id": "group",
    "api_base": "http://127.0.0.1:$HTTP_PORT"
  }
}
JSON

run_ops() {
  PATH="$FAKEBIN:$PATH" TASK_DB="$TASK_DB" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    PAVEL_STATUS_FILE="$PAVEL_STATUS_FILE" \
    FM_PAVEL_CAPTAIN_HOLD="$FAKEBIN/captain-hold" \
    FM_PAVEL_OPS_BRIEF="$FAKEBIN/fm-brief" FM_PAVEL_OPS_SPAWN="$FAKEBIN/fm-spawn" \
    FM_PAVEL_OPS_STATUS="$FAKEBIN/fm-status" FM_PAVEL_OPS_PR_CHECK="$FAKEBIN/fm-pr-check" \
    FM_PAVEL_OPS_PR_MERGE="$FAKEBIN/fm-pr-merge" FM_PAVEL_OPS_MERGE_CONFIRM="$FAKEBIN/fm-merge-confirm" \
    FM_PAVEL_OPS_LIVE_CHECK="$FAKEBIN/fm-live-check" \
    FM_PAVEL_OPS_CREW_STATE="$FAKEBIN/fm-crew-state" \
    FM_PAVEL_OPS_TESTING=1 "$OPS" "$@"
}

run_ops_default_status() {
  PATH="$FAKEBIN:$PATH" TASK_DB="$TASK_DB" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    PAVEL_STATUS_FILE="$PAVEL_STATUS_FILE" \
    FM_PAVEL_CAPTAIN_HOLD="$FAKEBIN/captain-hold" \
    FM_PAVEL_OPS_BRIEF="$FAKEBIN/fm-brief" FM_PAVEL_OPS_SPAWN="$FAKEBIN/fm-spawn" \
    FM_PAVEL_OPS_PR_CHECK="$FAKEBIN/fm-pr-check" \
    FM_PAVEL_OPS_PR_MERGE="$FAKEBIN/fm-pr-merge" FM_PAVEL_OPS_MERGE_CONFIRM="$FAKEBIN/fm-merge-confirm" \
    FM_PAVEL_OPS_LIVE_CHECK="$FAKEBIN/fm-live-check" \
    FM_PAVEL_OPS_CREW_STATE="$FAKEBIN/fm-crew-state" \
    FM_PAVEL_OPS_TESTING=1 "$OPS" "$@"
}

ingest() {
  local update=$1 message=$2 text=$3
  printf '{"transport":"telegram","chat_id":"group","update_id":"%s","message_id":"%s","sender_id":"pavel","date":1,"text":"%s"}\n' \
    "$update" "$message" "$text" | run_ops ingest
}

json_field() {
  local field=$1
  python3 -c "import json,sys; print(json.load(sys.stdin)$field)"
}

set_live_probe() {
  local event_id=$1 expected=$2 absent=${3:-}
  EVENT_FILE="$HOME_DIR/state/pavel-ops/events/$event_id.json" EXPECTED="$expected" ABSENT="$absent" python3 - <<'PY'
import json
import os
path = os.environ["EVENT_FILE"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
event["live_probe"] = {"expected": os.environ["EXPECTED"], "absent": os.environ["ABSENT"]}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
PY
}

set_delivery_contracts() {
  local event_id=$1 task_id=$2 pr_url=$3 pr_head=$4
  EVENT_FILE="$HOME_DIR/state/pavel-ops/events/$event_id.json" TASK_ID="$task_id" PR_URL="$pr_url" PR_HEAD="$pr_head" HOME_DIR="$HOME_DIR" python3 - <<'PY'
import json
import os
path = os.environ["EVENT_FILE"]
task_id = os.environ["TASK_ID"]
pr_url = os.environ["PR_URL"]
pr_head = os.environ["PR_HEAD"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
event["pr_url"] = pr_url
event["readiness_contract"] = {
    "schema": "fm-pavel-ops-readiness-contract.v1",
    "event_id": event["id"],
    "task_id": task_id,
    "pr_url": pr_url,
    "pr_head": pr_head,
    "state": "done",
    "source": "fixture",
    "format": "json",
    "evidence": "checks green on exact PR head",
}
provider = "github"
host = "github.com"
repo = "o/r"
number = pr_url.rsplit("/", 1)[1]
event["merge_contract"] = {
    "schema": "fm-pavel-ops-merge-contract.v1",
    "event_id": event["id"],
    "task_id": task_id,
    "pr_url": pr_url,
    "pr_head": pr_head,
    "provider": provider,
    "host": host,
    "repo": repo,
    "number": number,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
with open(os.path.join(os.environ["HOME_DIR"], "state", task_id + ".meta"), "w", encoding="utf-8") as handle:
    handle.write("kind=ship\nharness=pi\nmode=no-mistakes\nyolo=on\n")
    handle.write(f"worktree={os.environ['HOME_DIR']}/worktrees/{task_id}\n")
    handle.write(f"pr={pr_url}\npr_head={pr_head}\n")
PY
}

# Intake publishes once and a replay neither creates a second event nor a second wake.
out=$(ingest 100 10 'Поменять цену') || fail "first Pavel intake failed"
event=$(printf '%s' "$out" | json_field "['event']")
[ "$(printf '%s' "$out" | json_field "['duplicate']")" = False ] || fail "first intake was marked duplicate"
out=$(ingest 100 10 'Поменять цену') || fail "duplicate Pavel intake failed"
[ "$(printf '%s' "$out" | json_field "['duplicate']")" = True ] || fail "replayed intake was not deduplicated"
[ "$(find "$HOME_DIR/state/pavel-ops/events" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "duplicate intake created another event"
[ "$(grep -c . "$HOME_DIR/state/.wake-queue")" -eq 1 ] || fail "duplicate intake published another wake"
pass "Pavel Telegram intake is durable and deduplicated"

cat > "$UPDATES_FILE" <<'JSON'
{"ok": true, "result": [
  {"update_id": 201, "message": {"message_id": 41, "date": 1, "chat": {"id": "group"}, "from": {"id": "pavel"}, "text": "Добавить фото", "reply_to_message": {"message_id": 10}}},
  {"update_id": 202, "edited_message": {"message_id": 41, "edit_date": 2, "chat": {"id": "group"}, "from": {"id": "pavel"}, "caption": "Новое фото", "photo": [{"file_id": "f1", "file_unique_id": "u1", "width": 640, "height": 480}]}}
]}
JSON
collected=$(run_ops collect --limit 10 --timeout 0) || fail "Telegram collector failed"
[ "$(printf '%s' "$collected" | json_field "['ingested']")" -eq 2 ] || fail "collector did not ingest Pavel updates"
[ "$(printf '%s' "$collected" | json_field "['next_update_id']")" -eq 203 ] || fail "collector did not persist the next offset"
last_get=$(grep -F '/bottest-token/getUpdates' "$HTTP_LOG" | tail -1)
printf '%s' "$last_get" | grep -F 'limit=10' >/dev/null || fail "collector did not call Telegram getUpdates"
collected_reply_event=$(run_ops list | python3 -c "import json,sys; rows=json.load(sys.stdin); print([r for r in rows if r['source'].get('update_id')=='201'][0]['source']['reply_to_message_id'])")
[ "$collected_reply_event" = 10 ] || fail "collector did not retain reply metadata"
collected_edit_attachments=$(run_ops list | python3 -c "import json,sys; rows=json.load(sys.stdin); print(len([r for r in rows if r['source'].get('update_id')=='202'][0]['source']['attachments']))")
[ "$collected_edit_attachments" -eq 1 ] || fail "collector did not retain edited caption attachment metadata"
cat > "$UPDATES_FILE" <<'JSON'
{"ok": true, "result": []}
JSON
run_ops collect --limit 10 --timeout 0 >/dev/null || fail "empty collector replay failed"
offset_get=$(grep -F '/bottest-token/getUpdates' "$HTTP_LOG" | tail -1)
printf '%s' "$offset_get" | grep -F 'offset=203' >/dev/null || fail "collector did not resume from durable offset"
pass "Telegram getUpdates collector durably bridges Pavel updates"

armed=$(run_ops arm-collector) || fail "Pavel collector arming failed"
[ "$(printf '%s' "$armed" | json_field "['registered']")" = True ] || fail "collector did not register on first arm"
armed_again=$(run_ops arm-collector) || fail "Pavel collector rearming failed"
[ "$(printf '%s' "$armed_again" | json_field "['registered']")" = False ] || fail "collector arming was not idempotent"
source_id=$(printf '%s' "$armed" | json_field "['source']")
[ -f "$HOME_DIR/state/procevent/$source_id.source" ] || fail "collector was not registered with process-event owner"
pass "Pavel Telegram collector is armed through process-event"

# Ordinary work enters tasks-axi exactly once and becomes dispatchable.
run_ops classify "$event" --as task --title 'Change price' --intent 'Set the requested catalog price' \
  --reason 'explicit reversible price change' --authority ordinary >/dev/null
state=$(run_ops inspect "$event" | json_field "['state']")
[ "$state" = ready ] || fail "ordinary Pavel work did not become ready"
[ "$(cat "$TASK_DB/.add-count")" -eq 1 ] || fail "ordinary task was not added exactly once"
run_ops classify "$event" --as task --title 'Change price' --intent 'Set the requested catalog price' \
  --reason 'explicit reversible price change' --authority ordinary >/dev/null
[ "$(cat "$TASK_DB/.add-count")" -eq 1 ] || fail "classification replay duplicated the backlog task"
if run_ops classify "$event" --as task --title 'Change price' --intent 'Set a different catalog price' \
  --reason 'explicit reversible price change' --authority ordinary >/dev/null 2>&1; then
  fail "classification replay accepted a changed intent"
fi
if run_ops classify "$event" --as task --title 'Change price urgently' --intent 'Set the requested catalog price' \
  --reason 'explicit reversible price change' --authority ordinary >/dev/null 2>&1; then
  fail "classification replay accepted a changed title"
fi
if run_ops classify "$event" --as task --title 'Change price' --intent 'Set the requested catalog price' \
  --reason 'changed classification reason' --authority ordinary >/dev/null 2>&1; then
  fail "classification replay accepted a changed reason"
fi
if run_ops classify "$event" --as task --title 'Change price' --intent 'Set the requested catalog price' \
  --reason 'explicit reversible price change' --authority ordinary --task-id pavel-other >/dev/null 2>&1; then
  fail "classification replay accepted a changed task id"
fi
[ "$(run_ops inspect "$event" | json_field "['classification']['intent']")" = 'Set the requested catalog price' ] \
  || fail "classification mismatch mutated the accepted intent"
[ "$(cat "$TASK_DB/.add-count")" -eq 1 ] || fail "rejected classification replay created another task"
pass "ordinary Pavel authority creates one ready backlog task"

crash_classify=$(ingest 114 24 'Поменять описание' | json_field "['event']")
CRASH_CLASSIFY="$crash_classify" EVENT_FILE="$HOME_DIR/state/pavel-ops/events/$crash_classify.json" TASK_DB="$TASK_DB" python3 - <<'PY'
import json
import os
path = os.environ["EVENT_FILE"]
task_id = "pavel-crash-classify"
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
contract = {
    "as": "task",
    "authority": "ordinary",
    "related_task": None,
    "reason": "ordinary content update",
    "task_id": task_id,
    "title": "Change description",
    "intent": "Set the requested product description",
    "question": "",
    "safety": "",
}
event["pending_classification"] = contract
event["task_id"] = task_id
event["authority"] = "ordinary"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
with open(os.path.join(os.environ["TASK_DB"], task_id), "w", encoding="utf-8") as handle:
    handle.write(f"Pavel event: {os.environ['CRASH_CLASSIFY']}\n")
    handle.write("Accepted Pavel intent: Set the requested product description\n")
PY
before_crash_replay_adds=$(cat "$TASK_DB/.add-count")
if run_ops classify "$crash_classify" --as task --title 'Change description' \
  --intent 'Set another product description' --reason 'ordinary content update' \
  --authority ordinary --task-id pavel-crash-classify >/dev/null 2>&1; then
  fail "pending classification accepted a changed crash replay"
fi
run_ops classify "$crash_classify" --as task --title 'Change description' \
  --intent 'Set the requested product description' --reason 'ordinary content update' \
  --authority ordinary --task-id pavel-crash-classify >/dev/null
[ "$(run_ops inspect "$crash_classify" | json_field "['state']")" = ready ] \
  || fail "pending classification replay did not complete"
[ "$(cat "$TASK_DB/.add-count")" -eq "$before_crash_replay_adds" ] \
  || fail "pending classification replay created a duplicate task"
pass "pending task classification replays keep their contract"

unrelated=$(ingest 115 25 'Поменять блок' | json_field "['event']")
printf 'unrelated backlog row\n' > "$TASK_DB/pavel-existing-unrelated"
if run_ops classify "$unrelated" --as task --title 'Change block' --intent 'Set the requested block' \
  --reason 'ordinary content update' --authority ordinary --task-id pavel-existing-unrelated >/dev/null 2>&1; then
  fail "explicit classification accepted an unrelated existing task"
fi
printf 'Pavel event: tg-related\nAccepted Pavel intent: Existing Pavel task\n' > "$TASK_DB/pavel-existing-corrected"
run_ops classify "$unrelated" --as task --title 'Change block' --intent 'Set the requested block' \
  --reason 'ordinary content update' --authority ordinary --task-id pavel-existing-corrected >/dev/null
[ "$(run_ops inspect "$unrelated" | json_field "['task_id']")" = pavel-existing-corrected ] \
  || fail "explicit classification could not recover after unrelated task rejection"
pavel_linked=$(ingest 116 26 'И еще кнопку' | json_field "['event']")
printf 'Pavel event: tg-older\nAccepted Pavel intent: Existing Pavel task\n' > "$TASK_DB/pavel-existing-linked"
run_ops classify "$pavel_linked" --as task --title 'Change linked button' \
  --intent 'Add the requested button to the existing Pavel task' \
  --reason 'adjacent Pavel message belongs to existing task' --authority ordinary \
  --task-id pavel-existing-linked >/dev/null
[ "$(run_ops inspect "$pavel_linked" | json_field "['task_id']")" = pavel-existing-linked ] \
  || fail "Pavel-owned explicit task link was not retained"
pass "explicit task ids must be Pavel-owned"

# Conversation and reply events stay auditable without creating work.
conversation=$(ingest 101 11 'Ок' | json_field "['event']")
run_ops classify "$conversation" --as conversation --reason 'acknowledgement only' >/dev/null
reply=$(ingest 102 12 'Да, 139000' | json_field "['event']")
task_id=$(run_ops inspect "$event" | json_field "['task_id']")
run_ops classify "$reply" --as reply --related-task "$task_id" --reason 'answer attached to existing task' >/dev/null
[ "$(cat "$TASK_DB/.add-count")" -eq 1 ] || fail "conversation or reply spawned a nonsense task"
[ "$(run_ops inspect "$conversation" | json_field "['state']")" = conversation ] || fail "conversation classification was not retained"
[ "$(run_ops inspect "$reply" | json_field "['related_task']")" = "$task_id" ] || fail "reply audit lost its task link"
pass "conversations and Pavel replies remain auditable without backlog noise"

# Business ambiguity waits on Pavel, then his linked answer releases the same task.
ambiguous=$(ingest 103 13 'Добавить цвет' | json_field "['event']")
run_ops classify "$ambiguous" --as task --title 'Add colour' --intent 'Add Pavel requested colour' \
  --reason 'which colour is commercially material' --authority business-ambiguity \
  --question 'Какой цвет и фото использовать?' >/dev/null
run_ops classify "$ambiguous" --as task --title 'Add colour' --intent 'Add Pavel requested colour' \
  --reason 'which colour is commercially material' --authority business-ambiguity \
  --question 'Какой цвет и фото использовать?' >/dev/null
if run_ops classify "$ambiguous" --as task --title 'Add colour' --intent 'Add Pavel requested colour' \
  --reason 'which colour is commercially material' --authority business-ambiguity \
  --question 'Какой оттенок использовать?' >/dev/null 2>&1; then
  fail "business ambiguity replay accepted a changed question"
fi
ambiguous_task=$(run_ops inspect "$ambiguous" | json_field "['task_id']")
assert_grep '--kind external' "$TASK_DB/$ambiguous_task.holds" "business ambiguity did not wait externally on Pavel"
clarification_recovery=$(run_ops recover --startup) || fail "Pavel clarification recovery failed"
printf '%s' "$clarification_recovery" | grep -F "re-woke $ambiguous at awaiting_pavel" >/dev/null \
  || fail "unsent Pavel clarification was not surfaced during recovery"
run_ops send "$ambiguous" --purpose clarification --text 'Какой цвет и фото использовать?' >/dev/null \
  || fail "Pavel clarification notification failed"
after_clarification_recovery=$(run_ops recover --startup) || fail "Pavel clarification delivered recovery failed"
printf '%s' "$after_clarification_recovery" | grep -F "re-woke $ambiguous at awaiting_pavel" >/dev/null \
  && fail "delivered Pavel clarification kept surfacing as unsent"
answer_event=$(ingest 104 14 'Белый, фото выше' | json_field "['event']")
run_ops resolve-pavel "$ambiguous" --reply-event "$answer_event" --answer 'Белый, фото выше' >/dev/null
run_ops resolve-pavel "$ambiguous" --reply-event "$answer_event" --answer 'Белый, фото выше' >/dev/null
if run_ops resolve-pavel "$ambiguous" --reply-event "$answer_event" --answer 'Черный, фото ниже' >/dev/null 2>&1; then
  fail "resolved Pavel clarification accepted a changed answer"
fi
[ "$(run_ops inspect "$ambiguous" | json_field "['state']")" = ready ] || fail "Pavel answer did not resume the original task"
assert_grep 'unheld' "$TASK_DB/$ambiguous_task.holds" "Pavel answer did not lift the external wait"
pass "genuine business ambiguity routes to Pavel and resumes automatically"

conversation_answer_task=$(ingest 117 27 'Уточнить текст' | json_field "['event']")
run_ops classify "$conversation_answer_task" --as task --title 'Clarify copy' --intent 'Set Pavel requested copy' \
  --reason 'copy choice changes the customer result' --authority business-ambiguity \
  --question 'Какой текст использовать?' >/dev/null
conversation_answer_task_id=$(run_ops inspect "$conversation_answer_task" | json_field "['task_id']")
conversation_answer=$(ingest 118 28 'Когда будет готово?' | json_field "['event']")
run_ops classify "$conversation_answer" --as conversation --related-task "$conversation_answer_task_id" \
  --reason 'status question only' >/dev/null
if run_ops resolve-pavel "$conversation_answer_task" --reply-event "$conversation_answer" \
  --answer 'Когда будет готово?' >/dev/null 2>&1; then
  fail "conversation event resolved a Pavel clarification"
fi
[ "$(run_ops inspect "$conversation_answer_task" | json_field "['state']")" = awaiting_pavel ] \
  || fail "conversation resolution rejection mutated the waiting task"
pass "Pavel clarification resolution rejects conversations"

classified_reply_task=$(ingest 120 30 'Уточнить размер' | json_field "['event']")
run_ops classify "$classified_reply_task" --as task --title 'Clarify size' --intent 'Set Pavel requested size' \
  --reason 'size choice changes the customer result' --authority business-ambiguity \
  --question 'Какой размер использовать?' >/dev/null
classified_reply_task_id=$(run_ops inspect "$classified_reply_task" | json_field "['task_id']")
classified_reply=$(ingest 121 31 'XL' | json_field "['event']")
run_ops classify "$classified_reply" --as reply --related-task "$classified_reply_task_id" \
  --reason 'Pavel clarification answer' >/dev/null
if run_ops resolve-pavel "$classified_reply_task" --reply-event "$classified_reply" \
  --answer 'L' >/dev/null 2>&1; then
  fail "already-classified reply accepted a changed Pavel answer"
fi
run_ops resolve-pavel "$classified_reply_task" --reply-event "$classified_reply" --answer 'XL' >/dev/null
run_ops resolve-pavel "$classified_reply_task" --reply-event "$classified_reply" --answer 'XL' >/dev/null
[ "$(run_ops inspect "$classified_reply_task" | json_field "['state']")" = ready ] \
  || fail "already-classified reply did not resolve the clarification"
pass "already-classified replies resolve with source answer evidence"

unknown_clarification=$(ingest 119 29 'Уточнить фото' | json_field "['event']")
run_ops classify "$unknown_clarification" --as task --title 'Clarify photo' --intent 'Set Pavel requested photo' \
  --reason 'photo choice changes the customer result' --authority business-ambiguity \
  --question 'Какое фото использовать?' >/dev/null
UNKNOWN_CLARIFICATION="$unknown_clarification" OUTBOX="$HOME_DIR/state/pavel-ops/outbox/$unknown_clarification-clarification.json" python3 - <<'PY'
import hashlib
import json
import os
text = "Какое фото использовать?"
with open(os.environ["OUTBOX"], "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "fm-pavel-ops-outbound.v1",
        "id": os.environ["UNKNOWN_CLARIFICATION"] + "-clarification",
        "event_id": os.environ["UNKNOWN_CLARIFICATION"],
        "purpose": "clarification",
        "chat_id": "group",
        "text": text,
        "text_digest": hashlib.sha256(text.encode()).hexdigest(),
        "status": "unknown",
        "attempts": 1,
        "created_at": 1,
        "updated_at": 1,
    }, handle)
PY
unknown_clarification_recovery=$(run_ops recover --startup) || fail "unknown clarification recovery failed"
printf '%s' "$unknown_clarification_recovery" | grep -F "unknown outbound $unknown_clarification-clarification surfaced" >/dev/null \
  || fail "unknown Pavel clarification was not surfaced for reconciliation"
printf '%s' "$unknown_clarification_recovery" | grep -F "re-woke $unknown_clarification at awaiting_pavel" >/dev/null \
  && fail "unknown Pavel clarification was treated as unsent"
pass "unknown Pavel clarification sends require reconciliation"

partial_ambiguity=$(ingest 111 21 'Уточнить баннер' | json_field "['event']")
run_ops classify "$partial_ambiguity" --as task --title 'Clarify banner' --intent 'Set Pavel requested banner' \
  --reason 'banner choice changes the customer result' --authority business-ambiguity \
  --question 'Какой баннер использовать?' >/dev/null
partial_task=$(run_ops inspect "$partial_ambiguity" | json_field "['task_id']")
partial_reply=$(ingest 112 22 'Первый баннер' | json_field "['event']")
PARTIAL_REPLY="$partial_reply" PARTIAL_TASK="$partial_task" EVENT_FILE="$HOME_DIR/state/pavel-ops/events/$partial_reply.json" python3 - <<'PY'
import json
import os
import time
path = os.environ["EVENT_FILE"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
event["classification"] = {
    "as": "reply",
    "authority": None,
    "related_task": os.environ["PARTIAL_TASK"],
    "reason": "Pavel clarification answer",
}
event["related_task"] = os.environ["PARTIAL_TASK"]
event["state"] = "reply"
event["transitions"].append({
    "at": int(time.time()),
    "from": "captured",
    "to": "reply",
    "evidence": "Первый баннер",
})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
PY
if run_ops resolve-pavel "$partial_ambiguity" --reply-event "$partial_reply" --answer 'Второй баннер' >/dev/null 2>&1; then
  fail "partial Pavel clarification accepted changed reply evidence"
fi
run_ops resolve-pavel "$partial_ambiguity" --reply-event "$partial_reply" --answer 'Первый баннер' >/dev/null
[ "$(run_ops inspect "$partial_ambiguity" | json_field "['state']")" = ready ] \
  || fail "partial Pavel clarification replay did not resume"
pass "partial Pavel clarification replays retain their answer contract"

# A hard boundary alone routes to the captain owner.
hard=$(ingest 105 15 'Дайте пароль подрядчику' | json_field "['event']")
run_ops classify "$hard" --as task --title 'Share contractor access' --intent 'Give contractor requested access' \
  --reason 'requires credential disclosure' --authority hard-safety --safety credentials >/dev/null
run_ops classify "$hard" --as task --title 'Share contractor access' --intent 'Give contractor requested access' \
  --reason 'requires credential disclosure' --authority hard-safety --safety credentials >/dev/null
if run_ops classify "$hard" --as task --title 'Share contractor access' --intent 'Give contractor requested access' \
  --reason 'requires credential disclosure' --authority hard-safety --safety legal >/dev/null 2>&1; then
  fail "hard-safety replay accepted a changed safety boundary"
fi
[ "$(run_ops inspect "$hard" | json_field "['state']")" = awaiting_nikita ] || fail "hard safety did not stop for Nikita"
assert_grep 'hard safety boundary credentials' "$TASK_DB/.captain-holds" "hard safety did not register through the captain-hold owner"
if run_ops classify "$(ingest 106 16 'Поменять текст' | json_field "['event']")" --as task \
  --title 'Text' --intent 'Change text' --reason 'ordinary copy' --authority hard-safety --safety routine >/dev/null 2>&1; then
  fail "unknown hard-safety category was accepted"
fi
pass "only named hard-safety boundaries route to Nikita"

# Delivery cannot skip stages, cannot claim live without a URL, and notifies only from live.
if run_ops transition "$event" validating --evidence 'skip' >/dev/null 2>&1; then
  fail "delivery lifecycle allowed ready to skip directly to validating"
fi
if run_ops send "$event" --purpose live-completion --text 'Готово' >/dev/null 2>&1; then
  fail "completion notification was allowed before live proof"
fi
if run_ops transition "$event" dispatched --evidence 'caller supplied evidence' >/dev/null 2>&1; then
  fail "direct caller could advance autonomous delivery"
fi
set_live_probe "$event" '139000' 'old-price'
printf '139000\n' > "$TASK_DB/live-$event.expected"
run_ops drive "$event" >/dev/null
task_meta="$HOME_DIR/state/$task_id.meta"
printf 'pr=%s\npr_head=%s\n' 'https://github.com/o/r/pull/1' 'abc123' >> "$task_meta"
printf '{"state":"done","pr_url":"https://github.com/o/r/pull/1","pr_head":"abc123","evidence":"checks green on exact PR head"}\n' > "$PAVEL_STATUS_FILE"
run_ops drive "$event" >/dev/null
run_ops drive "$event" >/dev/null
run_ops drive "$event" >/dev/null
if FM_PAVEL_OPS_DRIVER=1 run_ops transition "$event" landed --evidence 'forged landed evidence' >/dev/null 2>&1; then
  fail "exported driver marker could forge delivery authority"
fi
touch "$TASK_DB/.merge-unconfirmed"
printf '{"state":"landed","pr_url":"https://github.com/o/r/pull/1","merged":true,"evidence":"stale task status"}\n' > "$PAVEL_STATUS_FILE"
run_ops drive "$event" >/dev/null
[ "$(run_ops inspect "$event" | json_field "['state']")" = merge_queued ] \
  || fail "stale landed status without merge marker advanced past merge_queued"
rm -f "$TASK_DB/.merge-unconfirmed"
printf '{"state":"done","pr_url":"https://github.com/o/r/pull/1","pr_head":"abc123","evidence":"checks green on exact PR head"}\n' > "$PAVEL_STATUS_FILE"
run_ops drive "$event" >/dev/null
if run_ops transition "$event" live --evidence 'deploy succeeded' >/dev/null 2>&1; then
  fail "live transition accepted no customer URL"
fi
before_completion_sends=$(grep -c . "$HTTP_LOG")
run_ops drive "$event" >/dev/null
run_ops send "$event" --purpose live-completion --text 'Готово: цена уже на сайте.' >/dev/null || fail "completion notification replay failed"
if run_ops send "$event" --purpose live-completion --text 'Готово: другой текст.' >/dev/null 2>&1; then
  fail "delivered completion replay accepted changed text"
fi
[ "$(grep -c . "$HTTP_LOG")" -eq $((before_completion_sends + 1)) ] || fail "driver did not send exactly one completion"
[ "$(run_ops inspect "$event" | json_field "['state']")" = notified ] || fail "confirmed Telegram receipt did not complete notification"
assert_grep 'chat_id=group' "$HTTP_LOG" "Telegram completion used the wrong chat"
assert_grep 'message' "$HOME_DIR/state/pavel-ops/outbox/$event-live-completion.json" "completion receipt was not retained"
assert_grep 'pr-check' "$TASK_DB/.owners" "driver did not compose the PR registration owner"
assert_grep 'pr-merge' "$TASK_DB/.owners" "driver did not compose the PR merge owner"
assert_grep 'deploy '"$task_id" "$TASK_DB/.owners" "driver did not compose the deploy owner"
assert_grep 'live-check '"$event"' '"$task_id"' 139000' "$TASK_DB/.owners" "driver did not compose the live verification owner"
pass "validated delivery is driver-owned and Pavel is notified after live proof"

landed_meta_race=$(ingest 132 42 'Проверить смену head перед live' | json_field "['event']")
run_ops classify "$landed_meta_race" --as task --title 'Reject landed PR head race' --intent 'Verify live only for the landed head' \
  --reason 'ordinary delivery' --authority ordinary >/dev/null
set_live_probe "$landed_meta_race" 'landed-head-a' ''
printf 'landed-head-a\n' > "$TASK_DB/live-$landed_meta_race.expected"
run_ops drive "$landed_meta_race" >/dev/null
landed_meta_race_task=$(run_ops inspect "$landed_meta_race" | json_field "['task_id']")
printf 'pr=%s\npr_head=%s\n' 'https://github.com/o/r/pull/18' 'aa18bb' >> "$HOME_DIR/state/$landed_meta_race_task.meta"
printf '{"state":"done","pr_url":"https://github.com/o/r/pull/18","pr_head":"aa18bb","evidence":"checks green on exact PR head"}\n' > "$PAVEL_STATUS_FILE"
run_ops drive "$landed_meta_race" >/dev/null
run_ops drive "$landed_meta_race" >/dev/null
run_ops drive "$landed_meta_race" >/dev/null
run_ops drive "$landed_meta_race" >/dev/null
[ "$(run_ops inspect "$landed_meta_race" | json_field "['state']")" = landed ] \
  || fail "landed head race setup did not reach landed"
owners_before_landed_meta_race=$(grep -c . "$TASK_DB/.owners")
printf 'pr_head=%s\n' 'bb18cc' >> "$HOME_DIR/state/$landed_meta_race_task.meta"
run_ops drive "$landed_meta_race" >/dev/null
[ "$(run_ops inspect "$landed_meta_race" | json_field "['state']")" = validating ] \
  || fail "changed landed PR head did not return to validation"
[ "$(grep -c . "$TASK_DB/.owners")" -eq "$owners_before_landed_meta_race" ] \
  || fail "changed landed PR head still invoked deploy or live owners"
pass "live verification rejects metadata head changes after landing"

stale_prose=$(ingest 122 32 'Проверить PR' | json_field "['event']")
run_ops classify "$stale_prose" --as task --title 'Check stale PR' --intent 'Ship via recorded PR only' \
  --reason 'ordinary delivery' --authority ordinary >/dev/null
run_ops drive "$stale_prose" >/dev/null
stale_task=$(run_ops inspect "$stale_prose" | json_field "['task_id']")
printf '{"state":"validating","evidence":"no-mistakes validation is active"}\n' > "$PAVEL_STATUS_FILE"
run_ops drive "$stale_prose" >/dev/null
printf 'pr=%s\npr_head=%s\n' 'https://github.com/o/r/pull/405' 'abc124' >> "$HOME_DIR/state/$stale_task.meta"
if run_ops drive "$stale_prose" >/dev/null 2>&1; then
  fail "driver accepted a canonical PR URL while validation was still active"
fi
printf 'state: done · source: status-log · checks green for https://github.com/o/r/pull/404\n' > "$PAVEL_STATUS_FILE"
if run_ops drive "$stale_prose" >/dev/null 2>&1; then
  fail "driver accepted a PR URL scraped from non-JSON status prose"
fi
[ "$(run_ops inspect "$stale_prose" | json_field "['state']")" = validating ] \
  || fail "stale prose PR rejection mutated the event"
pass "delivery-ready requires structured validation readiness"

text_status=$(ingest 127 37 'Проверить штатный статус' | json_field "['event']")
run_ops classify "$text_status" --as task --title 'Use crew state status' --intent 'Ship after crew state reports done' \
  --reason 'ordinary delivery' --authority ordinary >/dev/null
run_ops drive "$text_status" >/dev/null
text_status_task=$(run_ops inspect "$text_status" | json_field "['task_id']")
printf 'pr=%s\npr_head=%s\nworktree_head=%s\n' 'https://github.com/o/r/pull/12' 'cc12dd' 'cc12dd' >> "$HOME_DIR/state/$text_status_task.meta"
printf 'state: done · source: run-step · checks green: PR ready for review\n' > "$PAVEL_STATUS_FILE"
run_ops_default_status drive "$text_status" >/dev/null
run_ops_default_status drive "$text_status" >/dev/null
[ "$(run_ops inspect "$text_status" | json_field "['state']")" = delivery_ready ] \
  || fail "structured default status helper did not advance green work"
pass "delivery-ready accepts head-bound default status"

mismatched_run=$(ingest 129 39 'Проверить другой head' | json_field "['event']")
run_ops classify "$mismatched_run" --as task --title 'Reject unbound run head' --intent 'Merge only the run-step head' \
  --reason 'ordinary delivery' --authority ordinary >/dev/null
run_ops drive "$mismatched_run" >/dev/null
mismatched_run_task=$(run_ops inspect "$mismatched_run" | json_field "['task_id']")
printf 'pr=%s\npr_head=%s\nworktree_head=%s\n' 'https://github.com/o/r/pull/15' 'bb15cc' 'aa15bb' >> "$HOME_DIR/state/$mismatched_run_task.meta"
printf 'state: done · source: run-step · checks green: PR ready for review\n' > "$PAVEL_STATUS_FILE"
run_ops_default_status drive "$mismatched_run" >/dev/null
if run_ops_default_status drive "$mismatched_run" >/dev/null 2>&1; then
  fail "default status helper blessed a mismatched PR head"
fi
[ "$(run_ops inspect "$mismatched_run" | json_field "['state']")" = validating ] \
  || fail "mismatched default readiness mutated past validation"
pass "default readiness requires matching current head"

pr_substitution=$(ingest 125 35 'Проверить подмену PR' | json_field "['event']")
run_ops classify "$pr_substitution" --as task --title 'Reject PR substitution' --intent 'Ship only the registered PR' \
  --reason 'ordinary delivery' --authority ordinary >/dev/null
run_ops drive "$pr_substitution" >/dev/null
pr_substitution_task=$(run_ops inspect "$pr_substitution" | json_field "['task_id']")
printf 'pr=%s\npr_head=%s\n' 'https://github.com/o/r/pull/10' 'aa10bb' >> "$HOME_DIR/state/$pr_substitution_task.meta"
printf '{"state":"done","pr_url":"https://github.com/o/r/pull/10","pr_head":"aa10bb","evidence":"checks green on exact PR head"}\n' > "$PAVEL_STATUS_FILE"
run_ops drive "$pr_substitution" >/dev/null
run_ops drive "$pr_substitution" >/dev/null
[ "$(run_ops inspect "$pr_substitution" | json_field "['state']")" = delivery_ready ] \
  || fail "PR substitution setup did not reach delivery_ready"
printf '{"state":"done","pr_url":"https://github.com/o/r/pull/999","pr_head":"aa10bb","evidence":"stale status"}\n' > "$PAVEL_STATUS_FILE"
if run_ops drive "$pr_substitution" >/dev/null 2>&1; then
  fail "delivery_ready accepted a substituted status PR"
fi
if grep -F 'pull/999' "$TASK_DB/.owners" >/dev/null 2>&1; then
  fail "substituted PR reached the PR registration owner"
fi
[ "$(run_ops inspect "$pr_substitution" | json_field "['state']")" = delivery_ready ] \
  || fail "PR substitution rejection mutated the event"
pass "delivery-ready preserves the canonical PR identity"

regressed=$(ingest 126 36 'Проверить регресс CI' | json_field "['event']")
run_ops classify "$regressed" --as task --title 'Reject regressed checks' --intent 'Merge only while checks are green' \
  --reason 'ordinary delivery' --authority ordinary >/dev/null
run_ops drive "$regressed" >/dev/null
regressed_task=$(run_ops inspect "$regressed" | json_field "['task_id']")
printf 'pr=%s\npr_head=%s\n' 'https://github.com/o/r/pull/11' 'bb11cc' >> "$HOME_DIR/state/$regressed_task.meta"
printf '{"state":"done","pr_url":"https://github.com/o/r/pull/11","pr_head":"bb11cc","evidence":"checks green on exact PR head"}\n' > "$PAVEL_STATUS_FILE"
run_ops drive "$regressed" >/dev/null
run_ops drive "$regressed" >/dev/null
[ "$(run_ops inspect "$regressed" | json_field "['state']")" = delivery_ready ] \
  || fail "regressed-check setup did not reach delivery_ready"
owners_before_regressed=$(grep -c . "$TASK_DB/.owners")
printf '{"state":"validating","pr_url":"https://github.com/o/r/pull/11","pr_head":"bb11cc","evidence":"checks running again"}\n' > "$PAVEL_STATUS_FILE"
if run_ops drive "$regressed" >/dev/null 2>&1; then
  fail "delivery_ready merged after checks regressed"
fi
[ "$(grep -c . "$TASK_DB/.owners")" -eq "$owners_before_regressed" ] \
  || fail "regressed checks still invoked a delivery owner"
[ "$(run_ops inspect "$regressed" | json_field "['state']")" = delivery_ready ] \
  || fail "regressed-check rejection mutated the event"
pass "merge queue requires fresh green validation"

head_race=$(ingest 128 38 'Проверить смену head' | json_field "['event']")
run_ops classify "$head_race" --as task --title 'Reject PR head race' --intent 'Merge only the freshly verified PR head' \
  --reason 'ordinary delivery' --authority ordinary >/dev/null
run_ops drive "$head_race" >/dev/null
head_race_task=$(run_ops inspect "$head_race" | json_field "['task_id']")
printf 'pr=%s\npr_head=%s\n' 'https://github.com/o/r/pull/13' 'dd13ee' >> "$HOME_DIR/state/$head_race_task.meta"
printf '{"state":"done","pr_url":"https://github.com/o/r/pull/13","pr_head":"dd13ee","evidence":"checks green on exact PR head"}\n' > "$PAVEL_STATUS_FILE"
run_ops drive "$head_race" >/dev/null
run_ops drive "$head_race" >/dev/null
[ "$(run_ops inspect "$head_race" | json_field "['state']")" = delivery_ready ] \
  || fail "head-race setup did not reach delivery_ready"
printf 'ee14ff\n' > "$TASK_DB/.pr-check-head-change"
if run_ops drive "$head_race" >/dev/null 2>&1; then
  fail "delivery_ready merged after PR check changed the head"
fi
rm -f "$TASK_DB/.pr-check-head-change"
printf 'state: done · source: run-step · checks green: PR ready for review\n' > "$PAVEL_STATUS_FILE"
if run_ops drive "$head_race" >/dev/null 2>&1; then
  fail "unheaded text readiness blessed the changed PR head on retry"
fi
[ "$(run_ops inspect "$head_race" | json_field "['state']")" = delivery_ready ] \
  || fail "head-race rejection mutated the event"
pass "merge queue rejects PR head changes after check"

merge_meta_race=$(ingest 131 41 'Проверить смену head после очереди' | json_field "['event']")
run_ops classify "$merge_meta_race" --as task --title 'Reject queued PR head race' --intent 'Land only the queued PR head' \
  --reason 'ordinary delivery' --authority ordinary >/dev/null
run_ops drive "$merge_meta_race" >/dev/null
merge_meta_race_task=$(run_ops inspect "$merge_meta_race" | json_field "['task_id']")
printf 'pr=%s\npr_head=%s\n' 'https://github.com/o/r/pull/17' 'aa17bb' >> "$HOME_DIR/state/$merge_meta_race_task.meta"
printf '{"state":"done","pr_url":"https://github.com/o/r/pull/17","pr_head":"aa17bb","evidence":"checks green on exact PR head"}\n' > "$PAVEL_STATUS_FILE"
run_ops drive "$merge_meta_race" >/dev/null
run_ops drive "$merge_meta_race" >/dev/null
run_ops drive "$merge_meta_race" >/dev/null
[ "$(run_ops inspect "$merge_meta_race" | json_field "['state']")" = merge_queued ] \
  || fail "merge head race setup did not reach merge_queued"
owners_before_merge_meta_race=$(grep -c . "$TASK_DB/.owners")
printf 'pr_head=%s\n' 'bb17cc' >> "$HOME_DIR/state/$merge_meta_race_task.meta"
printf 'bb17cc\n' > "$TASK_DB/.merge-confirm-head"
run_ops drive "$merge_meta_race" >/dev/null
[ "$(run_ops inspect "$merge_meta_race" | json_field "['state']")" = validating ] \
  || fail "changed queued PR head did not return to validation"
[ "$(grep -c . "$TASK_DB/.owners")" -eq "$owners_before_merge_meta_race" ] \
  || fail "changed queued PR head still invoked the merge owner"
rm -f "$TASK_DB/.merge-confirm-head"
pass "landing rejects metadata head changes after merge queue"

stale_marker=$(ingest 130 40 'Проверить старый маркер merge' | json_field "['event']")
run_ops classify "$stale_marker" --as task --title 'Reject stale merge marker' --intent 'Record landed only for current head' \
  --reason 'ordinary delivery' --authority ordinary >/dev/null
stale_marker_task=$(run_ops inspect "$stale_marker" | json_field "['task_id']")
STALE_MARKER_FILE="$HOME_DIR/state/pavel-ops/events/$stale_marker.json" STALE_MARKER_TASK="$stale_marker_task" HOME_DIR="$HOME_DIR" python3 - <<'PY'
import json
import os
import time
path = os.environ["STALE_MARKER_FILE"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
now = int(time.time())
for state, evidence in [
    ("dispatched", "Pi worker exists in isolated copy"),
    ("validating", "no-mistakes run owns current head"),
    ("delivery_ready", "checks green on exact PR head"),
    ("merge_queued", "guarded merge accepted by forge"),
]:
    event["transitions"].append({"at": now, "from": event["state"], "to": state, "evidence": evidence})
    event["state"] = state
event["pr_url"] = "https://github.com/o/r/pull/16"
event["readiness_contract"] = {
    "schema": "fm-pavel-ops-readiness-contract.v1",
    "event_id": event["id"],
    "task_id": os.environ["STALE_MARKER_TASK"],
    "pr_url": "https://github.com/o/r/pull/16",
    "pr_head": "bb16cc",
    "state": "done",
    "source": "fixture",
    "format": "json",
    "evidence": "checks green on exact PR head",
}
event["merge_contract"] = {
    "schema": "fm-pavel-ops-merge-contract.v1",
    "event_id": event["id"],
    "task_id": os.environ["STALE_MARKER_TASK"],
    "pr_url": "https://github.com/o/r/pull/16",
    "pr_head": "bb16cc",
    "provider": "github",
    "host": "github.com",
    "repo": "o/r",
    "number": "16",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
with open(os.path.join(os.environ["HOME_DIR"], "state", os.environ["STALE_MARKER_TASK"] + ".meta"), "w", encoding="utf-8") as handle:
    handle.write("kind=ship\nharness=pi\nmode=no-mistakes\nyolo=on\n")
    handle.write(f"worktree={os.environ['HOME_DIR']}/worktrees/{os.environ['STALE_MARKER_TASK']}\n")
    handle.write("pr=https://github.com/o/r/pull/16\npr_head=bb16cc\n")
with open(os.path.join(os.environ["HOME_DIR"], "state", os.environ["STALE_MARKER_TASK"] + ".pr-poll-merge-notified"), "w", encoding="utf-8") as handle:
    handle.write("fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\no/r\n16\n")
os.chmod(os.path.join(os.environ["HOME_DIR"], "state", os.environ["STALE_MARKER_TASK"] + ".pr-poll-merge-notified"), 0o600)
PY
touch "$TASK_DB/.merge-unconfirmed"
printf 'aa16bb\n' > "$TASK_DB/.merge-confirm-head"
run_ops drive "$stale_marker" >/dev/null
[ "$(run_ops inspect "$stale_marker" | json_field "['state']")" = merge_queued ] \
  || fail "stale same-PR merge marker advanced to landed"
rm -f "$TASK_DB/.merge-unconfirmed" "$TASK_DB/.merge-confirm-head"
pass "landing requires forge-confirmed current PR head"

set_live_probe "$ambiguous" 'Белый, фото выше' ''
printf 'Белый, фото выше\n' > "$TASK_DB/live-$ambiguous.expected"
printf 'Белый, фото выше\n' > "$TASK_DB/live-$ambiguous.requires-answer"
AMBIGUOUS_FILE="$HOME_DIR/state/pavel-ops/events/$ambiguous.json" AMBIGUOUS_TASK="$ambiguous_task" HOME_DIR="$HOME_DIR" python3 - <<'PY'
import json
import os
import time
path = os.environ["AMBIGUOUS_FILE"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
now = int(time.time())
for state, evidence in [
    ("dispatched", "Pi worker exists in isolated copy"),
    ("validating", "no-mistakes run owns current head"),
    ("delivery_ready", "checks green on exact PR head"),
    ("merge_queued", "guarded merge accepted by forge"),
    ("landed", "forge reports PR merged at verified head"),
]:
    event["transitions"].append({"at": now, "from": event["state"], "to": state, "evidence": evidence})
    event["state"] = state
event["pr_url"] = "https://github.com/o/r/pull/126"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
with open(os.path.join(os.environ["HOME_DIR"], "state", os.environ["AMBIGUOUS_TASK"] + ".meta"), "w", encoding="utf-8") as handle:
    handle.write("kind=ship\nharness=pi\nmode=no-mistakes\nyolo=on\n")
    handle.write(f"worktree={os.environ['HOME_DIR']}/worktrees/{os.environ['AMBIGUOUS_TASK']}\n")
    handle.write("pr=https://github.com/o/r/pull/126\npr_head=ab126c\n")
PY
set_delivery_contracts "$ambiguous" "$ambiguous_task" 'https://github.com/o/r/pull/126' 'ab126c'
run_ops drive "$ambiguous" >/dev/null || fail "resolved clarification did not reach live proof"
[ "$(run_ops inspect "$ambiguous" | json_field "['state']")" = notified ] \
  || fail "resolved clarification was not notified after live proof"
assert_grep 'live-check '"$ambiguous"' '"$ambiguous_task"' Белый, фото выше' "$TASK_DB/.owners" \
  "live verifier did not receive the clarified Pavel contract"
pass "live payload includes Pavel clarification answers"

wrong_live=$(ingest 124 34 'Поменять заголовок SEO' | json_field "['event']")
run_ops classify "$wrong_live" --as task --title 'Change SEO title' --intent 'Show the requested SEO title' \
  --reason 'ordinary SEO update' --authority ordinary >/dev/null
wrong_live_task=$(run_ops inspect "$wrong_live" | json_field "['task_id']")
set_live_probe "$wrong_live" 'new seo title' ''
printf '139000\n' > "$TASK_DB/live-$wrong_live.expected"
WRONG_LIVE_FILE="$HOME_DIR/state/pavel-ops/events/$wrong_live.json" WRONG_LIVE_TASK="$wrong_live_task" HOME_DIR="$HOME_DIR" python3 - <<'PY'
import json
import os
import time
path = os.environ["WRONG_LIVE_FILE"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
now = int(time.time())
for state, evidence in [
    ("dispatched", "Pi worker exists in isolated copy"),
    ("validating", "no-mistakes run owns current head"),
    ("delivery_ready", "checks green on exact PR head"),
    ("merge_queued", "guarded merge accepted by forge"),
    ("landed", "forge reports PR merged at verified head"),
]:
    event["transitions"].append({"at": now, "from": event["state"], "to": state, "evidence": evidence})
    event["state"] = state
event["pr_url"] = "https://github.com/o/r/pull/124"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
with open(os.path.join(os.environ["HOME_DIR"], "state", os.environ["WRONG_LIVE_TASK"] + ".meta"), "w", encoding="utf-8") as handle:
    handle.write("kind=ship\nharness=pi\nmode=no-mistakes\nyolo=on\n")
    handle.write(f"worktree={os.environ['HOME_DIR']}/worktrees/{os.environ['WRONG_LIVE_TASK']}\n")
    handle.write("pr=https://github.com/o/r/pull/124\npr_head=def456\n")
PY
set_delivery_contracts "$wrong_live" "$wrong_live_task" 'https://github.com/o/r/pull/124' 'def456'
if run_ops drive "$wrong_live" >/dev/null 2>&1; then
  fail "global live expectation satisfied a different Pavel task"
fi
[ "$(run_ops inspect "$wrong_live" | json_field "['state']")" = landed ] \
  || fail "task-specific live proof rejection mutated the event"
pass "live verification is bound to each Pavel event"

live_retry=$(ingest 123 33 'Поменять цену доставки' | json_field "['event']")
run_ops classify "$live_retry" --as task --title 'Change shipping price' --intent 'Show the requested shipping price' \
  --reason 'ordinary price change' --authority ordinary >/dev/null
live_retry_task=$(run_ops inspect "$live_retry" | json_field "['task_id']")
set_delivery_contracts "$live_retry" "$live_retry_task" 'https://github.com/o/r/pull/123' 'ab123c'
LIVE_RETRY_FILE="$HOME_DIR/state/pavel-ops/events/$live_retry.json" python3 - <<'PY'
import hashlib
import json
import os
import time
path = os.environ["LIVE_RETRY_FILE"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
now = int(time.time())
event["completion_text"] = "Готово: цена уже на сайте."
event["live_url"] = "https://example.test/product"
for state, evidence in [
    ("dispatched", "Pi worker exists in isolated copy"),
    ("validating", "no-mistakes run owns current head"),
    ("delivery_ready", "checks green on exact PR head"),
    ("merge_queued", "guarded merge accepted by forge"),
    ("landed", "forge reports PR merged at verified head"),
    ("live", "live probe passed for https://example.test/product"),
]:
    event["transitions"].append({"at": now, "from": event["state"], "to": state, "evidence": evidence})
    event["state"] = state
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
outbox = os.path.join(os.path.dirname(path), "..", "outbox", event["id"] + "-live-completion.json")
os.makedirs(os.path.dirname(outbox), exist_ok=True)
text = event["completion_text"]
with open(outbox, "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "fm-pavel-ops-outbound.v1",
        "id": event["id"] + "-live-completion",
        "event_id": event["id"],
        "purpose": "live-completion",
        "chat_id": "group",
        "text": text,
        "text_digest": hashlib.sha256(text.encode()).hexdigest(),
        "status": "retryable",
        "attempts": 1,
        "created_at": now,
        "updated_at": now,
    }, handle)
PY
before_live_retry=$(grep -c . "$HTTP_LOG")
run_ops drive "$live_retry" >/dev/null || fail "live retry did not reuse configured completion text"
[ "$(grep -c . "$HTTP_LOG")" -eq $((before_live_retry + 1)) ] || fail "live retry did not send exactly once"
[ "$(run_ops inspect "$live_retry" | json_field "['state']")" = notified ] \
  || fail "live retry did not reconcile to notified"
pass "live notification retries reuse the durable completion text"

# A delivered completion receipt after a crash reconciles the event without sending again.
crashed=$(ingest 108 18 'Поменять SEO заголовок' | json_field "['event']")
run_ops classify "$crashed" --as task --title 'Change SEO title' --intent 'Set the requested SEO title' \
  --reason 'ordinary SEO change' --authority ordinary >/dev/null
crashed_task=$(run_ops inspect "$crashed" | json_field "['task_id']")
set_delivery_contracts "$crashed" "$crashed_task" 'https://github.com/o/r/pull/2' 'aa22bb'
CRASHED_EVENT_FILE="$HOME_DIR/state/pavel-ops/events/$crashed.json" python3 - <<'PY'
import json
import os
import time
path = os.environ["CRASHED_EVENT_FILE"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
now = int(time.time())
for state, evidence in [
    ("dispatched", "Pi worker exists in isolated copy"),
    ("validating", "no-mistakes run owns current head"),
    ("delivery_ready", "checks green on exact PR head"),
    ("merge_queued", "guarded merge accepted by forge"),
    ("landed", "forge reports PR merged at verified head"),
    ("live", "requested SEO title is visible on the customer page"),
]:
    event["transitions"].append({"at": now, "from": event["state"], "to": state, "evidence": evidence})
    event["state"] = state
event["pr_url"] = "https://github.com/o/r/pull/2"
event["live_url"] = "https://example.test/seo"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
PY
CRASHED_EVENT="$crashed" OUTBOX="$HOME_DIR/state/pavel-ops/outbox/$crashed-live-completion.json" python3 - <<'PY'
import hashlib
import json
import os
text = "Готово: SEO заголовок уже на сайте."
with open(os.environ["OUTBOX"], "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "fm-pavel-ops-outbound.v1",
        "id": os.environ["CRASHED_EVENT"] + "-live-completion",
        "event_id": os.environ["CRASHED_EVENT"],
        "purpose": "live-completion",
        "chat_id": "group",
        "text": text,
        "text_digest": hashlib.sha256(text.encode()).hexdigest(),
        "status": "delivered",
        "attempts": 1,
        "telegram_message_id": "999",
        "delivered_at": 1,
        "created_at": 1,
        "updated_at": 1,
    }, handle)
PY
before_replay_sends=$(grep -c . "$HTTP_LOG")
run_ops send "$crashed" --purpose live-completion --text 'Готово: SEO заголовок уже на сайте.' >/dev/null \
  || fail "delivered completion replay did not reconcile"
[ "$(grep -c . "$HTTP_LOG")" -eq "$before_replay_sends" ] || fail "delivered completion replay sent again"
[ "$(run_ops inspect "$crashed" | json_field "['state']")" = notified ] \
  || fail "delivered completion replay did not mark the event notified"
pass "delivered live-completion replay reconciles notification state"

# A crash after send begins is surfaced and never retried without reconciliation.
unknown=$(ingest 107 17 'Когда будет готово?' | json_field "['event']")
run_ops classify "$unknown" --as conversation --reason 'status question only' >/dev/null
before_unknown_sends=$(grep -c . "$HTTP_LOG")
UNKNOWN_EVENT="$unknown" OUTBOX="$HOME_DIR/state/pavel-ops/outbox/$unknown-qa.json" python3 - <<'PY'
import hashlib
import json
import os
text = "Статус проверяется."
with open(os.environ["OUTBOX"], "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "fm-pavel-ops-outbound.v1",
        "id": os.environ["UNKNOWN_EVENT"] + "-qa",
        "event_id": os.environ["UNKNOWN_EVENT"],
        "purpose": "qa",
        "chat_id": "group",
        "text": text,
        "text_digest": hashlib.sha256(text.encode()).hexdigest(),
        "status": "sending",
        "attempts": 1,
        "created_at": 1,
        "updated_at": 1,
    }, handle)
PY
if run_ops send "$unknown" --purpose qa --text 'Статус проверяется.' >/dev/null 2>&1; then
  fail "unknown Telegram delivery was retried and could duplicate the message"
fi
if run_ops send "$unknown" --purpose qa --text 'Другой статус.' >/dev/null 2>&1; then
  fail "unknown outbound replay accepted changed text"
fi
[ "$(grep -c . "$HTTP_LOG")" -eq "$before_unknown_sends" ] || fail "unknown Telegram delivery reached the API again"
recovery=$(run_ops recover --startup) || fail "Pavel startup recovery failed"
printf '%s' "$recovery" | grep -F "unknown outbound $unknown-qa surfaced" >/dev/null \
  || fail "unknown Telegram delivery was not made visible during recovery"
run_ops reconcile-outbound "$unknown-qa" --sent-message-id 888 >/dev/null
[ "$(run_ops inspect "$unknown" | json_field "['state']")" = conversation ] || fail "outbound reconciliation changed a conversation into work"
assert_grep '"status": "delivered"' "$HOME_DIR/state/pavel-ops/outbox/$unknown-qa.json" "reconciled Telegram receipt was not retained"
pass "interrupted Telegram sends stop for visible reconciliation instead of duplicating"

# Retryable failures remain recoverable even if a crash happens before wake publication.
failed=$(ingest 113 23 'Проверить доставку' | json_field "['event']")
run_ops classify "$failed" --as task --title 'Check delivery' --intent 'Check Pavel requested delivery behavior' \
  --reason 'ordinary site behavior change' --authority ordinary >/dev/null
FAILED_EVENT_FILE="$HOME_DIR/state/pavel-ops/events/$failed.json" python3 - <<'PY'
import json
import os
import time
path = os.environ["FAILED_EVENT_FILE"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
event["transitions"].append({"at": int(time.time()), "from": event["state"], "to": "dispatched", "evidence": "Pi worker exists in isolated copy"})
event["state"] = "dispatched"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
PY
failed_task=$(run_ops inspect "$failed" | json_field "['task_id']")
printf 'harness=pi\n' > "$HOME_DIR/state/$failed_task.meta"
FAILED_FILE="$HOME_DIR/state/pavel-ops/events/$failed.json" python3 - <<'PY'
import json
import os
import time
path = os.environ["FAILED_FILE"]
with open(path, encoding="utf-8") as handle:
    event = json.load(handle)
event["wake_pending"] = False
event["last_error"] = "worker transport timed out"
event["failures"] = [{"at": int(time.time()), "stage": "dispatch", "error": "worker transport timed out"}]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, ensure_ascii=False, sort_keys=True, indent=2)
    handle.write("\n")
PY
failure_recovery=$(run_ops recover --startup) || fail "Pavel failure recovery failed"
printf '%s' "$failure_recovery" | grep -F "re-woke $failed at dispatched" >/dev/null \
  || fail "crash-cut retryable failure was not surfaced during recovery"
pass "retryable failures survive crashes before wake publication"

# Retryable outbound records keep the same immutable send contract.
retryable=$(ingest 109 19 'Статус?' | json_field "['event']")
run_ops classify "$retryable" --as conversation --reason 'status question only' >/dev/null
RETRYABLE_EVENT="$retryable" OUTBOX="$HOME_DIR/state/pavel-ops/outbox/$retryable-qa.json" python3 - <<'PY'
import hashlib
import json
import os
text = "Статус повторяется."
with open(os.environ["OUTBOX"], "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "fm-pavel-ops-outbound.v1",
        "id": os.environ["RETRYABLE_EVENT"] + "-qa",
        "event_id": os.environ["RETRYABLE_EVENT"],
        "purpose": "qa",
        "chat_id": "group",
        "text": text,
        "text_digest": hashlib.sha256(text.encode()).hexdigest(),
        "status": "retryable",
        "attempts": 1,
        "created_at": 1,
        "updated_at": 1,
    }, handle)
PY
before_retryable_sends=$(grep -c . "$HTTP_LOG")
if run_ops send "$retryable" --purpose qa --text 'Другой статус.' >/dev/null 2>&1; then
  fail "retryable outbound replay accepted changed text"
fi
[ "$(grep -c . "$HTTP_LOG")" -eq "$before_retryable_sends" ] || fail "retryable text mismatch reached the API"
run_ops send "$retryable" --purpose qa --text 'Статус повторяется.' >/dev/null \
  || fail "retryable outbound with the same text did not resend"
[ "$(grep -c . "$HTTP_LOG")" -eq $((before_retryable_sends + 1)) ] || fail "retryable outbound did not retry once"
pass "retryable outbound records retain their send contract"

wrong_chat=$(ingest 110 20 'Еще статус?' | json_field "['event']")
run_ops classify "$wrong_chat" --as conversation --reason 'status question only' >/dev/null
WRONG_CHAT_EVENT="$wrong_chat" OUTBOX="$HOME_DIR/state/pavel-ops/outbox/$wrong_chat-qa.json" python3 - <<'PY'
import hashlib
import json
import os
text = "Статус с неверным чатом."
with open(os.environ["OUTBOX"], "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "fm-pavel-ops-outbound.v1",
        "id": os.environ["WRONG_CHAT_EVENT"] + "-qa",
        "event_id": os.environ["WRONG_CHAT_EVENT"],
        "purpose": "qa",
        "chat_id": "another-group",
        "text": text,
        "text_digest": hashlib.sha256(text.encode()).hexdigest(),
        "status": "sending",
        "attempts": 1,
        "created_at": 1,
        "updated_at": 1,
    }, handle)
PY
before_wrong_chat_sends=$(grep -c . "$HTTP_LOG")
if run_ops send "$wrong_chat" --purpose qa --text 'Статус с неверным чатом.' >/dev/null 2>&1; then
  fail "outbound replay accepted a changed chat contract"
fi
[ "$(grep -c . "$HTTP_LOG")" -eq "$before_wrong_chat_sends" ] || fail "chat contract mismatch reached the API"
pass "outbound replays reject immutable contract mismatches"

printf 'adoptable\n' > "$TASK_DB/pavel-adopt"
run_ops adopt-task pavel-adopt --state ready --note 'legacy task is ready' >/dev/null
run_ops adopt-task pavel-adopt --state ready --note 'legacy task is ready' >/dev/null
if run_ops adopt-task pavel-adopt --state live --note 'legacy task is ready' >/dev/null 2>&1; then
  fail "legacy adoption replay accepted a changed state"
fi
if run_ops adopt-task pavel-adopt --state ready --note 'legacy task is live' >/dev/null 2>&1; then
  fail "legacy adoption replay accepted a changed note"
fi
[ "$(run_ops inspect legacy-task-pavel-adopt | json_field "['state']")" = ready ] \
  || fail "legacy adoption mismatch mutated state"
pass "legacy adoption replays validate their contract"

# Migration audit reports legacy work and an ahead clone without changing either.
MIGRATION_CLONE="$TMP_ROOT/aln"
fm_git_init_commit "$MIGRATION_CLONE"
git -C "$MIGRATION_CLONE" branch -M main
fm_git_add_origin "$MIGRATION_CLONE" "$TMP_ROOT/aln-origin.git"
git -C "$MIGRATION_CLONE" fetch -q origin
printf 'local work\n' >> "$MIGRATION_CLONE/README.md"
git -C "$MIGRATION_CLONE" add README.md
git -C "$MIGRATION_CLONE" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'local Pavel work'
migration_head=$(git -C "$MIGRATION_CLONE" rev-parse HEAD)
printf '{"id":475,"text":"legacy Pavel task"}\n' > "$TMP_ROOT/legacy-pending.jsonl"
migration=$(run_ops migration-audit --legacy-pending "$TMP_ROOT/legacy-pending.jsonl" \
  --clone "$MIGRATION_CLONE" --expected-head "$migration_head") || fail "Pavel migration audit failed"
[ "$(printf '%s' "$migration" | json_field "['clone']['head']")" = "$migration_head" ] || fail "migration audit lost the local clone head"
[ "$(printf '%s' "$migration" | json_field "['clone']['ahead_origin_main']")" -eq 1 ] || fail "migration audit did not report the ahead commit"
printf '%s' "$migration" | grep -F 'preserve HEAD on a dedicated branch' >/dev/null \
  || fail "migration audit omitted the non-destructive clone recovery path"
[ "$(git -C "$MIGRATION_CLONE" rev-parse HEAD)" = "$migration_head" ] || fail "migration audit changed the clone"
[ -z "$(git -C "$MIGRATION_CLONE" status --porcelain)" ] || fail "migration audit dirtied the clone"
pass "legacy paused work and an ahead clone have a read-only recovery path"

# The delegated flow refuses a configuration that tries to restore Claude.
python3 - "$HOME_DIR/config/pavel-ops.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)
config["worker"]["harness"] = "claude"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(config, handle)
PY
if run_ops list >/dev/null 2>&1; then
  fail "Pavel operations accepted Claude as a required runtime"
fi
pass "Pavel operations is pinned to the verified Pi adapter"
