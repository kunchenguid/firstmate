#!/usr/bin/env bash
# Executable HTTP behavior for the read-only agent journal and task report
# viewer, including auth, root confinement, record shapes, append recovery,
# report changes, malformed/long lines, and explicit rotation/truncation signals.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jsonl-viewer)
HOME_FIXTURE="$TMP_ROOT/home"
SHORT_ID=short-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHORT_DIR="$HOME_FIXTURE/state/short-agents/$SHORT_ID"
SUPERVISOR_DIR="$HOME_FIXTURE/state/branch-session"
REPORT_DIR="$HOME_FIXTURE/data/task-one"
PREFIXED_REPORT_DIR="$HOME_FIXTURE/data/_task-two"
TOKEN=viewer-test-token-value
TOKEN_FILE="$TMP_ROOT/viewer.token"
PORT_FILE="$TMP_ROOT/port"
SERVER_LOG="$TMP_ROOT/server.log"
mkdir -p "$SHORT_DIR" "$SUPERVISOR_DIR" "$REPORT_DIR" "$PREFIXED_REPORT_DIR"
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

cat > "$SHORT_DIR/journal.jsonl" <<'JSONL'
{"type":"message_end","message":{"role":"assistant","timestamp":1780000000000,"content":[{"type":"text","text":"safe <img src=x onerror=alert(1)>"},{"type":"toolCall","name":"read_material","arguments":{"material":"m1"}}]}}
{"type":"message_end","message":{"role":"toolResult","timestamp":1780000000100,"toolName":"read_material","content":[{"type":"text","text":"nested result"}]}}
{"type":"future_event","payload":{"nested":[1,{"unknown":true}]}}
not-json
JSONL
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"partial' >> "$SHORT_DIR/journal.jsonl"

cat > "$SUPERVISOR_DIR/session-one.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"session-one","timestamp":"2026-09-30T00:00:00.000Z","cwd":"/redacted"}
{"type":"custom_message","id":"custom-1","parentId":null,"timestamp":"2026-09-30T00:00:01.000Z","customType":"fm-main-mirror","content":"captain request"}
{"type":"message","id":"message-1","parentId":"custom-1","timestamp":"2026-09-30T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"bounded reasoning"},{"type":"toolCall","name":"bash","arguments":{"command":"true"}}]}}
JSONL
ln -s "$TMP_ROOT/outside.jsonl" "$SUPERVISOR_DIR/escaped.jsonl"
printf '{"secret":true}\n' > "$TMP_ROOT/outside.jsonl"
cat > "$REPORT_DIR/report.md" <<'MARKDOWN'
# Task one

Visible report body.
MARKDOWN
printf 'not allowlisted\n' > "$REPORT_DIR/secret.md"
printf '# Prefixed task report\n' > "$PREFIXED_REPORT_DIR/report.md"
mkdir -p "$HOME_FIXTURE/data/escaped"
printf 'outside report\n' > "$TMP_ROOT/outside.md"
ln -s "$TMP_ROOT/outside.md" "$HOME_FIXTURE/data/escaped/report.md"
ln -s "$TMP_ROOT" "$HOME_FIXTURE/data/linked-task"

node - "$SUPERVISOR_DIR/long.jsonl" <<'NODE'
import fs from "node:fs";
fs.writeFileSync(process.argv[2], `${JSON.stringify({ type: "message", message: { role: "user", content: [{ type: "text", text: "x".repeat(1200000) }] } })}\n`);
NODE

cp "$TOKEN_FILE" "$TMP_ROOT/insecure.token"
chmod 644 "$TMP_ROOT/insecure.token"
if FM_HOME="$HOME_FIXTURE" FM_JSONL_VIEWER_TOKEN_FILE="$TMP_ROOT/insecure.token" \
  node "$ROOT/bin/fm-jsonl-viewer.mjs" --host 127.0.0.1 --port 0 > "$TMP_ROOT/insecure.out" 2>&1; then
  fail "viewer accepted a group/world-readable token file"
fi

FM_HOME="$HOME_FIXTURE" FM_JSONL_VIEWER_TOKEN_FILE="$TOKEN_FILE" FM_JSONL_VIEWER_PORT=0 \
  node "$ROOT/bin/fm-jsonl-viewer.mjs" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 100); do
  sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' "$SERVER_LOG" > "$PORT_FILE"
  [ -s "$PORT_FILE" ] && break
  sleep 0.05
done
[ -s "$PORT_FILE" ] || fail "viewer did not report its bound port"
PORT=$(cat "$PORT_FILE")
BASE="http://127.0.0.1:$PORT"

status=$(curl -sS -o "$TMP_ROOT/denied.json" -w '%{http_code}' "$BASE/api/sessions")
[ "$status" = 401 ] || fail "unauthenticated discovery returned HTTP $status"
status=$(curl -sS -o "$TMP_ROOT/wrong.json" -w '%{http_code}' -H 'Authorization: Bearer definitely-wrong' "$BASE/api/sessions")
[ "$status" = 401 ] || fail "wrong-token discovery returned HTTP $status"
status=$(curl -sS -o "$TMP_ROOT/report-denied.json" -w '%{http_code}' "$BASE/api/report?id=task-one")
[ "$status" = 401 ] || fail "unauthenticated report read returned HTTP $status"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/sessions" > "$TMP_ROOT/sessions.json"
jq -e --arg id "$SHORT_ID" '.sessions | any(.source == "short" and .id == $id)' "$TMP_ROOT/sessions.json" >/dev/null || fail "ShortTask journal was not discovered"
jq -e '.sessions | any(.source == "supervisor" and .id == "session-one.jsonl")' "$TMP_ROOT/sessions.json" >/dev/null || fail "supervisor session was not discovered"
jq -e '.sessions | all(.id != "escaped.jsonl")' "$TMP_ROOT/sessions.json" >/dev/null || fail "symlink escape was discovered"
jq -e '.reports | any(.source == "report" and .id == "task-one" and .label == "task-one")' "$TMP_ROOT/sessions.json" >/dev/null || fail "canonical task report was not discovered"
jq -e '.reports | any(.source == "report" and .id == "_task-two" and .label == "_task-two")' "$TMP_ROOT/sessions.json" >/dev/null || fail "canonical report for a valid prefixed task id was not discovered"
jq -e '.reports | all(.id != "escaped" and .id != "linked-task")' "$TMP_ROOT/sessions.json" >/dev/null || fail "symlinked report path was discovered"

status=$(curl -sS -o "$TMP_ROOT/traversal.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=..%2Foutside.jsonl&cursor=0")
[ "$status" = 404 ] || fail "traversal selection returned HTTP $status"
status=$(curl -sS -o "$TMP_ROOT/symlink.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=escaped.jsonl&cursor=0")
[ "$status" = 404 ] || fail "symlink selection returned HTTP $status"
status=$(curl -sS -o "$TMP_ROOT/report-traversal.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=..%2F..%2Foutside")
[ "$status" = 404 ] || fail "report traversal selection returned HTTP $status"
status=$(curl -sS -o "$TMP_ROOT/report-symlink.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=escaped")
[ "$status" = 404 ] || fail "symlinked report selection returned HTTP $status"
status=$(curl -sS -o "$TMP_ROOT/report-arbitrary.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=task-one%2Fsecret.md")
[ "$status" = 404 ] || fail "non-canonical report file selection returned HTTP $status"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=task-one" > "$TMP_ROOT/report.json"
jq -e '.source == "report" and .id == "task-one" and (.content | contains("Visible report body.")) and .size > 0 and (.identity | length) > 0' "$TMP_ROOT/report.json" >/dev/null || fail "canonical task report was not read intact"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=_task-two" > "$TMP_ROOT/prefixed-report.json"
jq -e '.source == "report" and .id == "_task-two" and (.content | contains("Prefixed task report"))' "$TMP_ROOT/prefixed-report.json" >/dev/null || fail "canonical report for a valid prefixed task id was not read intact"
printf '\nChanged report body.\n' >> "$REPORT_DIR/report.md"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=task-one" > "$TMP_ROOT/report-changed.json"
jq -e '(.content | contains("Changed report body.")) and .size > 0' "$TMP_ROOT/report-changed.json" >/dev/null || fail "changed task report was not refreshed"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=short&id=$SHORT_ID&cursor=0" > "$TMP_ROOT/short-page.json"
jq -e '.events | any(.value.message.role == "assistant" and (.value.message.content | any(.type == "toolCall")))' "$TMP_ROOT/short-page.json" >/dev/null || fail "nested ShortTask tool call was not preserved"
jq -e '.events | any(.value.message.role == "toolResult")' "$TMP_ROOT/short-page.json" >/dev/null || fail "ShortTask tool result was not preserved"
jq -e '.events | any(.value.type == "future_event")' "$TMP_ROOT/short-page.json" >/dev/null || fail "unknown event type was not preserved"
jq -e '.events | any(.error == "malformed_json")' "$TMP_ROOT/short-page.json" >/dev/null || fail "malformed line was not surfaced"
jq -e '.partialBytes > 0 and .eof == false' "$TMP_ROOT/short-page.json" >/dev/null || fail "partial final line was presented as complete"
cursor=$(jq -r '.nextCursor' "$TMP_ROOT/short-page.json")
identity=$(jq -r '.identity' "$TMP_ROOT/short-page.json")

printf ' text"}]}}\n' >> "$SHORT_DIR/journal.jsonl"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=short&id=$SHORT_ID&cursor=$cursor&identity=$identity" > "$TMP_ROOT/appended.json"
jq -e '(.events | length) == 1 and .events[0].value.message.content[0].text == "partial text" and .eof == true' "$TMP_ROOT/appended.json" >/dev/null || fail "completed partial line did not recover on append"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=long.jsonl&cursor=0" > "$TMP_ROOT/long.json"
jq -e '(.events | length) == 1 and .events[0].bytes > 1000000 and .events[0].value.message.role == "user"' "$TMP_ROOT/long.json" >/dev/null || fail "long valid line was clipped or omitted"

supervisor_identity=$(curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=session-one.jsonl&cursor=0" | jq -r '.identity')
mv "$SUPERVISOR_DIR/session-one.jsonl" "$SUPERVISOR_DIR/session-one.old"
printf '{"type":"session","id":"replacement"}\n' > "$SUPERVISOR_DIR/session-one.jsonl"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=session-one.jsonl&cursor=1&identity=$supervisor_identity" > "$TMP_ROOT/rotated.json"
jq -e '.reset == "rotated" and .nextCursor > 0 and ((.events | length) == 1)' "$TMP_ROOT/rotated.json" >/dev/null || fail "rotation was not signalled with replacement events"

truncate -s 0 "$SUPERVISOR_DIR/session-one.jsonl"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=session-one.jsonl&cursor=999999" > "$TMP_ROOT/truncated.json"
jq -e '.reset == "truncated" and .nextCursor == 0 and .size == 0' "$TMP_ROOT/truncated.json" >/dev/null || fail "truncation was not signalled"

curl -sS "$BASE/" > "$TMP_ROOT/index.html"
if grep -q 'onerror=alert' "$TMP_ROOT/index.html"; then fail "private log-derived markup reached the static HTML response"; fi
content_type=$(curl -sS -D - -o /dev/null "$BASE/app.js" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type" {print $2}')
case "$content_type" in text/javascript*) ;; *) fail "browser script has unsafe content type $content_type" ;; esac

pass 'token-protected agent viewer confines journal and report roots and preserves existing JSONL behavior'
