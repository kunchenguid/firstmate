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
HTTP_PID=

cleanup() {
  if [ -n "$HTTP_PID" ]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$FAKEBIN" "$TASK_DB"
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

cat > "$TMP_ROOT/server.py" <<'PY'
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
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
HTTP_LOG="$HTTP_LOG" HTTP_PORT="$HTTP_PORT" python3 "$TMP_ROOT/server.py" &
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
    FM_PAVEL_CAPTAIN_HOLD="$FAKEBIN/captain-hold" FM_PAVEL_OPS_TESTING=1 "$OPS" "$@"
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

# Intake publishes once and a replay neither creates a second event nor a second wake.
out=$(ingest 100 10 'Поменять цену') || fail "first Pavel intake failed"
event=$(printf '%s' "$out" | json_field "['event']")
[ "$(printf '%s' "$out" | json_field "['duplicate']")" = False ] || fail "first intake was marked duplicate"
out=$(ingest 100 10 'Поменять цену') || fail "duplicate Pavel intake failed"
[ "$(printf '%s' "$out" | json_field "['duplicate']")" = True ] || fail "replayed intake was not deduplicated"
[ "$(find "$HOME_DIR/state/pavel-ops/events" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "duplicate intake created another event"
[ "$(grep -c . "$HOME_DIR/state/.wake-queue")" -eq 1 ] || fail "duplicate intake published another wake"
pass "Pavel Telegram intake is durable and deduplicated"

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
answer_event=$(ingest 104 14 'Белый, фото выше' | json_field "['event']")
run_ops resolve-pavel "$ambiguous" --reply-event "$answer_event" --answer 'Белый, фото выше' >/dev/null
[ "$(run_ops inspect "$ambiguous" | json_field "['state']")" = ready ] || fail "Pavel answer did not resume the original task"
assert_grep 'unheld' "$TASK_DB/$ambiguous_task.holds" "Pavel answer did not lift the external wait"
pass "genuine business ambiguity routes to Pavel and resumes automatically"

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
run_ops transition "$event" dispatched --evidence 'Pi worker exists in isolated copy' >/dev/null
run_ops transition "$event" validating --evidence 'no-mistakes run owns current head' >/dev/null
run_ops transition "$event" delivery_ready --evidence 'checks green on exact PR head' >/dev/null
run_ops transition "$event" merge_queued --evidence 'guarded merge accepted by forge' --pr-url 'https://github.com/o/r/pull/1' >/dev/null
run_ops transition "$event" merge_queued --evidence 'guarded merge accepted by forge' --pr-url 'https://github.com/o/r/pull/1' >/dev/null
if run_ops transition "$event" merge_queued --evidence 'guarded merge accepted by forge' --pr-url 'https://github.com/o/r/pull/99' >/dev/null 2>&1; then
  fail "merge_queued replay accepted a changed PR URL"
fi
if run_ops transition "$event" merge_queued --evidence 'different merge evidence' --pr-url 'https://github.com/o/r/pull/1' >/dev/null 2>&1; then
  fail "merge_queued replay accepted changed evidence"
fi
if run_ops transition "$event" merge_queued --evidence 'guarded merge accepted by forge' --pr-url 'https://github.com/o/r/pull/1' --live-url 'https://example.test/product' >/dev/null 2>&1; then
  fail "merge_queued replay accepted an unrelated live URL"
fi
run_ops transition "$event" landed --evidence 'forge reports PR merged at verified head' >/dev/null
if run_ops transition "$event" live --evidence 'deploy succeeded' >/dev/null 2>&1; then
  fail "live transition accepted no customer URL"
fi
run_ops transition "$event" live --evidence 'requested price is visible on the customer page' --live-url 'https://example.test/product' >/dev/null
run_ops transition "$event" live --evidence 'requested price is visible on the customer page' --live-url 'https://example.test/product' >/dev/null
if run_ops transition "$event" live --evidence 'requested price is visible on the customer page' --live-url 'https://example.test/other' >/dev/null 2>&1; then
  fail "live replay accepted a changed live URL"
fi
if run_ops transition "$event" live --evidence 'different live evidence' --live-url 'https://example.test/product' >/dev/null 2>&1; then
  fail "live replay accepted changed evidence"
fi
run_ops send "$event" --purpose live-completion --text 'Готово: цена уже на сайте.' >/dev/null || fail "live completion notification failed"
run_ops send "$event" --purpose live-completion --text 'Готово: цена уже на сайте.' >/dev/null || fail "completion notification replay failed"
if run_ops send "$event" --purpose live-completion --text 'Готово: другой текст.' >/dev/null 2>&1; then
  fail "delivered completion replay accepted changed text"
fi
[ "$(grep -c . "$HTTP_LOG")" -eq 1 ] || fail "completion notification replay sent twice"
[ "$(run_ops inspect "$event" | json_field "['state']")" = notified ] || fail "confirmed Telegram receipt did not complete notification"
assert_grep 'chat_id=group' "$HTTP_LOG" "Telegram completion used the wrong chat"
assert_grep 'message' "$HOME_DIR/state/pavel-ops/outbox/$event-live-completion.json" "completion receipt was not retained"
pass "validated delivery stays linear and Pavel is notified exactly once after live proof"

# A delivered completion receipt after a crash reconciles the event without sending again.
crashed=$(ingest 108 18 'Поменять SEO заголовок' | json_field "['event']")
run_ops classify "$crashed" --as task --title 'Change SEO title' --intent 'Set the requested SEO title' \
  --reason 'ordinary SEO change' --authority ordinary >/dev/null
run_ops transition "$crashed" dispatched --evidence 'Pi worker exists in isolated copy' >/dev/null
run_ops transition "$crashed" validating --evidence 'no-mistakes run owns current head' >/dev/null
run_ops transition "$crashed" delivery_ready --evidence 'checks green on exact PR head' >/dev/null
run_ops transition "$crashed" merge_queued --evidence 'guarded merge accepted by forge' --pr-url 'https://github.com/o/r/pull/2' >/dev/null
run_ops transition "$crashed" landed --evidence 'forge reports PR merged at verified head' >/dev/null
run_ops transition "$crashed" live --evidence 'requested SEO title is visible on the customer page' --live-url 'https://example.test/seo' >/dev/null
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
[ "$(grep -c . "$HTTP_LOG")" -eq 1 ] || fail "unknown Telegram delivery reached the API again"
recovery=$(run_ops recover --startup) || fail "Pavel startup recovery failed"
printf '%s' "$recovery" | grep -F "unknown outbound $unknown-qa surfaced" >/dev/null \
  || fail "unknown Telegram delivery was not made visible during recovery"
run_ops reconcile-outbound "$unknown-qa" --sent-message-id 888 >/dev/null
[ "$(run_ops inspect "$unknown" | json_field "['state']")" = conversation ] || fail "outbound reconciliation changed a conversation into work"
assert_grep '"status": "delivered"' "$HOME_DIR/state/pavel-ops/outbox/$unknown-qa.json" "reconciled Telegram receipt was not retained"
pass "interrupted Telegram sends stop for visible reconciliation instead of duplicating"

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
