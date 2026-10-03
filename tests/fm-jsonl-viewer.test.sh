#!/usr/bin/env bash
# Executable HTTP behavior for the read-only agent journal and task document
# viewer, including auth, root confinement, record shapes, append recovery,
# report changes, malformed/long lines, and explicit rotation/truncation signals.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jsonl-viewer)
HOME_FIXTURE="$TMP_ROOT/home"
SHORT_ID=short-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHORT_DIR="$HOME_FIXTURE/state/short-agents/$SHORT_ID"
DENSE_SHORT_ID=short-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
DENSE_SHORT_DIR="$HOME_FIXTURE/state/short-agents/$DENSE_SHORT_ID"
SUPERVISOR_DIR="$HOME_FIXTURE/state/branch-session"
REPORT_DIR="$HOME_FIXTURE/data/task-one"
PREFIXED_REPORT_DIR="$HOME_FIXTURE/data/_task-two"
BRIEF_DIR="$HOME_FIXTURE/data/held-task"
TOKEN=viewer-test-token-value
TOKEN_FILE="$TMP_ROOT/viewer.token"
PORT_FILE="$TMP_ROOT/port"
SERVER_LOG="$TMP_ROOT/server.log"
SERVER_PID=
TIMEOUT_SERVER_PID=
CANDIDATE_SERVER_PID=
cleanup() {
  for pid in "$SERVER_PID" "$TIMEOUT_SERVER_PID" "$CANDIDATE_SERVER_PID"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT INT TERM
mkdir -p "$SHORT_DIR" "$DENSE_SHORT_DIR" "$SUPERVISOR_DIR" "$REPORT_DIR" "$PREFIXED_REPORT_DIR" "$BRIEF_DIR"
cat > "$HOME_FIXTURE/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
cat > "$HOME_FIXTURE/data/backlog.md" <<'MARKDOWN'
## In flight
- [ ] task-one - Processing task (repo: viewer) (kind: ship)

## Queued
- [ ] held-task - Held task blocked-by: upstream-task (blocked-reason: waiting for upstream) (repo: viewer) (kind: ship)

## Done
- [x] completed-task - Accepted completed task (repo: viewer) (kind: ship)
MARKDOWN
cat > "$HOME_FIXTURE/data/done-archive.md" <<'MARKDOWN'
## Archived 2026-09
- [x] archived-task - Archived historical task (repo: viewer) (kind: ship)
MARKDOWN
mkdir -p "$HOME_FIXTURE/data/cancelled-task" "$HOME_FIXTURE/data/invalid-lifecycle-task"
cat > "$HOME_FIXTURE/data/cancelled-task/lifecycle.json" <<'JSON'
{"schema":"fm-task-lifecycle.v2","task_id":"cancelled-task","disposition":"archived","assessment":{"authority_ref":"retained explicit stop"}}
JSON
printf '{"disposition":"archived"}\n' > "$HOME_FIXTURE/data/invalid-lifecycle-task/lifecycle.json"
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

cat > "$SHORT_DIR/journal.jsonl" <<'JSONL'
{"type":"message_end","message":{"role":"assistant","timestamp":1780000000000,"content":[{"type":"text","text":"safe <img src=x onerror=alert(1)>"},{"type":"toolCall","name":"read_material","arguments":{"material":"m1"}}]}}
{"type":"message_end","message":{"role":"toolResult","timestamp":1780000000100,"toolName":"read_material","content":[{"type":"text","text":"nested result"}]}}
{"type":"future_event","payload":{"nested":[1,{"unknown":true}]}}
not-json
JSONL
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"partial' >> "$SHORT_DIR/journal.jsonl"
for index in $(seq 1 201); do
  printf '{"type":"message_end","message":{"role":"assistant","timestamp":%s,"content":[{"type":"text","text":"dense-event-%s"}]}}\n' "$((1780001000000 + index))" "$index"
done > "$DENSE_SHORT_DIR/journal.jsonl"

cat > "$SUPERVISOR_DIR/session-one.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"session-one","timestamp":"2026-09-30T00:00:00.000Z","cwd":"/redacted"}
{"type":"custom_message","id":"custom-1","parentId":null,"timestamp":"2026-09-30T00:00:01.000Z","customType":"fm-main-mirror","content":"captain request"}
{"type":"custom_message","id":"native-response","parentId":"custom-1","timestamp":"2026-09-30T00:00:01.500Z","customType":"openai-codex-compat-native-response","content":"hidden native response"}
{"type":"message","id":"ordinary-text","parentId":"native-response","timestamp":"2026-09-30T00:00:01.750Z","message":{"role":"user","content":[{"type":"text","text":"ordinary text mentions openai-codex-compat-native-response"}]}}
{"type":"message","id":"message-1","parentId":"custom-1","timestamp":"2026-09-30T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"bounded reasoning"},{"type":"toolCall","name":"bash","arguments":{"command":"true"}}]}}
JSONL
{
  printf '{"type":"message","timestamp":1,"content":"old"}\n'
  printf '{"type":"message","timestamp":2,"content":"'
  head -c 2000000 /dev/zero | tr '\0' x
  printf '"}\n'
  printf '{"type":"message","timestamp":3,"content":"newest"}\n'
} > "$SUPERVISOR_DIR/wide-tail.jsonl"
ln -s "$TMP_ROOT/outside.jsonl" "$SUPERVISOR_DIR/escaped.jsonl"
printf '{"secret":true}\n' > "$TMP_ROOT/outside.jsonl"
cat > "$REPORT_DIR/report.md" <<'MARKDOWN'
# Task one

Visible report body.
MARKDOWN
printf '# Superseded task brief\n\nReport selection must take precedence.\n' > "$REPORT_DIR/brief.md"
printf '# Held task instructions\n\nVisible brief body.\n' > "$BRIEF_DIR/brief.md"
printf 'not allowlisted\n' > "$REPORT_DIR/secret.md"
printf '# Prefixed task report\n' > "$PREFIXED_REPORT_DIR/report.md"
mkdir -p "$HOME_FIXTURE/data/escaped"
printf 'outside report\n' > "$TMP_ROOT/outside.md"
ln -s "$TMP_ROOT/outside.md" "$HOME_FIXTURE/data/escaped/report.md"
mkdir -p "$HOME_FIXTURE/data/escaped-brief"
ln -s "$TMP_ROOT/outside.md" "$HOME_FIXTURE/data/escaped-brief/brief.md"
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

# Exercise the fleet-snapshot timeout behavior with an isolated code-root copy.
# The production bound is scaled down here so the genuine hang case stays fast.
TIMEOUT_CODE_ROOT="$TMP_ROOT/timeout-code"
TIMEOUT_HOME="$TMP_ROOT/timeout-home"
TIMEOUT_LOG="$TMP_ROOT/timeout-server.log"
mkdir -p "$TIMEOUT_CODE_ROOT/bin" "$TIMEOUT_CODE_ROOT/web" "$TIMEOUT_HOME/data" "$TIMEOUT_HOME/state"
sed 's/const FLEET_SNAPSHOT_TIMEOUT_MS = 60000;/const FLEET_SNAPSHOT_TIMEOUT_MS = 1000;/' \
  "$ROOT/bin/fm-jsonl-viewer.mjs" > "$TIMEOUT_CODE_ROOT/bin/fm-jsonl-viewer.mjs"
grep -q 'const FLEET_SNAPSHOT_TIMEOUT_MS = 1000;' "$TIMEOUT_CODE_ROOT/bin/fm-jsonl-viewer.mjs" \
  || fail "timeout regression fixture did not scale the production bound"
cat > "$TIMEOUT_CODE_ROOT/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$(cat "$FM_HOME/snapshot-mode")" in
  slow)
    sleep 0.2
    printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","generated":"2026-10-01T00:00:00Z","main_inventory":{"valid":true},"backlog":{"records":[]},"tasks":[]}'
    ;;
  next)
    sleep 0.2
    printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","generated":"2026-10-01T00:01:00Z","main_inventory":{"valid":true},"backlog":{"records":[{"structured":true,"id":"next-task","title":"Next task","state":"in_flight","kind":"ship","repo":"viewer"}]},"tasks":[]}'
    ;;
  hang)
    exec sleep 10
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "$TIMEOUT_CODE_ROOT/bin/fm-fleet-snapshot.sh"
cat > "$TIMEOUT_CODE_ROOT/bin/fm-task-disposition-lib.sh" <<'SH'
fm_task_disposition_snapshot() { :; }
SH
printf 'slow\n' > "$TIMEOUT_HOME/snapshot-mode"
FM_HOME="$TIMEOUT_HOME" FM_JSONL_VIEWER_TOKEN_FILE="$TOKEN_FILE" FM_JSONL_VIEWER_PORT=0 \
  node "$TIMEOUT_CODE_ROOT/bin/fm-jsonl-viewer.mjs" > "$TIMEOUT_LOG" 2>&1 &
TIMEOUT_SERVER_PID=$!
for _ in $(seq 1 100); do
  timeout_port=$(sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' "$TIMEOUT_LOG")
  [ -n "$timeout_port" ] && break
  sleep 0.05
done
[ -n "${timeout_port:-}" ] || fail "timeout regression viewer did not report its bound port"
timeout_base="http://127.0.0.1:$timeout_port"
status=$(curl -sS -o "$TMP_ROOT/timeout-slow.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$timeout_base/api/tasks")
[ "$status" = 200 ] || fail "slow fleet snapshot returned HTTP $status"
jq -e '.generatedAt == "2026-10-01T00:00:00Z" and .tasks == []' "$TMP_ROOT/timeout-slow.json" >/dev/null \
  || fail "slow fleet snapshot response was not preserved"
printf 'next\n' > "$TIMEOUT_HOME/snapshot-mode"
sleep 2.1
started_at=$(date +%s)
status=$(curl --max-time 2 -sS -o "$TMP_ROOT/timeout-stale.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$timeout_base/api/tasks")
elapsed=$(( $(date +%s) - started_at ))
[ "$status" = 200 ] || fail "expired successful snapshot returned HTTP $status"
[ "$elapsed" -lt 2 ] || fail "expired successful snapshot blocked on its background refresh"
jq -e '.generatedAt == "2026-10-01T00:00:00Z" and .tasks == [] and .cacheHit == true and .refreshing == true and .cacheAgeMs > 0' "$TMP_ROOT/timeout-stale.json" >/dev/null \
  || fail "expired successful snapshot was not returned with truthful stale freshness"
for _ in $(seq 1 50); do
  curl -sS -H "Authorization: Bearer $TOKEN" "$timeout_base/api/tasks" > "$TMP_ROOT/timeout-next.json"
  jq -e '.generatedAt == "2026-10-01T00:01:00Z" and (.tasks | any(.id == "next-task"))' "$TMP_ROOT/timeout-next.json" >/dev/null && break
  sleep 0.05
done
jq -e '.generatedAt == "2026-10-01T00:01:00Z" and (.tasks | any(.id == "next-task"))' "$TMP_ROOT/timeout-next.json" >/dev/null \
  || fail "completed background refresh did not atomically publish its new generation"
printf 'hang\n' > "$TIMEOUT_HOME/snapshot-mode"
sleep 2.1
started_at=$(date +%s)
status=$(curl --max-time 4 -sS -o "$TMP_ROOT/timeout-hang.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$timeout_base/api/tasks")
elapsed=$(( $(date +%s) - started_at ))
[ "$status" = 200 ] || fail "hanging background refresh hid the last successful snapshot with HTTP $status"
[ "$elapsed" -lt 4 ] || fail "hanging fleet snapshot exceeded its finite timeout"
jq -e '.generatedAt == "2026-10-01T00:01:00Z" and (.tasks | any(.id == "next-task")) and .cacheHit == true and .refreshing == true' "$TMP_ROOT/timeout-hang.json" >/dev/null \
  || fail "hanging background refresh did not preserve and label the last successful generation"
sleep 1.1
curl -sS -H "Authorization: Bearer $TOKEN" "$timeout_base/api/tasks" > "$TMP_ROOT/timeout-failed-stale.json"
jq -e '.generatedAt == "2026-10-01T00:01:00Z" and .cacheHit == true and .refreshing == true and (.refreshError | contains("refresh failed"))' "$TMP_ROOT/timeout-failed-stale.json" >/dev/null \
  || fail "failed background refresh was not disclosed alongside the preserved snapshot"
kill "$TIMEOUT_SERVER_PID" 2>/dev/null || true
wait "$TIMEOUT_SERVER_PID" 2>/dev/null || true
TIMEOUT_SERVER_PID=

# A process with no successful snapshot must still fail closed instead of
# presenting an unavailable generation as cached data.
FM_HOME="$TIMEOUT_HOME" FM_JSONL_VIEWER_TOKEN_FILE="$TOKEN_FILE" FM_JSONL_VIEWER_PORT=0 \
  node "$TIMEOUT_CODE_ROOT/bin/fm-jsonl-viewer.mjs" > "$TIMEOUT_LOG" 2>&1 &
TIMEOUT_SERVER_PID=$!
for _ in $(seq 1 100); do
  timeout_port=$(sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' "$TIMEOUT_LOG")
  [ -n "$timeout_port" ] && break
  sleep 0.05
done
[ -n "${timeout_port:-}" ] || fail "cold-timeout viewer did not report its bound port"
timeout_base="http://127.0.0.1:$timeout_port"
status=$(curl --max-time 4 -sS -o "$TMP_ROOT/timeout-cold-hang.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$timeout_base/api/tasks")
[ "$status" = 503 ] || fail "cold hanging fleet snapshot returned HTTP $status"
jq -e '.error == "task overview is temporarily unavailable"' "$TMP_ROOT/timeout-cold-hang.json" >/dev/null \
  || fail "cold hanging fleet snapshot did not return the honest unavailable response"
kill "$TIMEOUT_SERVER_PID" 2>/dev/null || true
wait "$TIMEOUT_SERVER_PID" 2>/dev/null || true
TIMEOUT_SERVER_PID=

# Exercise the candidate classification through its public HTTP API with
# retained nonterminal or ambiguous observations and disconfirming controls.
CANDIDATE_CODE_ROOT="$TMP_ROOT/candidate-code"
CANDIDATE_HOME="$TMP_ROOT/candidate-home"
CANDIDATE_LOG="$TMP_ROOT/candidate-server.log"
mkdir -p "$CANDIDATE_CODE_ROOT/bin" "$CANDIDATE_CODE_ROOT/web" "$CANDIDATE_HOME/data" "$CANDIDATE_HOME/state"
cp "$ROOT/bin/fm-jsonl-viewer.mjs" "$CANDIDATE_CODE_ROOT/bin/fm-jsonl-viewer.mjs"
cp "$ROOT/web/jsonl-viewer/"* "$CANDIDATE_CODE_ROOT/web/"
cat > "$CANDIDATE_CODE_ROOT/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
set -eu
cat <<'JSON'
{"schema":"fm-fleet-snapshot.v1","generated":"2026-10-03T00:00:00Z","main_inventory":{"valid":true},"backlog":{"records":[
{"structured":true,"id":"archive-working","title":"Archived while remote works","state":"in_flight","kind":"ship","repo":"viewer"},
{"structured":true,"id":"archive-ambiguous","title":"Archived with unknown remote","state":"queued","kind":"ship","repo":"viewer"},
{"structured":true,"id":"accepted-working","title":"Accepted while remote works","state":"in_flight","kind":"ship","repo":"viewer"},
{"structured":true,"id":"record-archive-working","title":"Record archive while remote works","state":"in_flight","kind":"ship","repo":"viewer"},
{"structured":true,"id":"invalid-archive","title":"Invalid archive authority","state":"in_flight","kind":"ship","repo":"viewer"},
{"structured":true,"id":"active-working","title":"Active work","state":"in_flight","kind":"ship","repo":"viewer"},
{"structured":true,"id":"done-open-gap","title":"Done with unfinished goal","state":"done","kind":"ship","repo":"viewer","compact_progress":{"remaining_gap":"Acceptance is not met","next_step":"Continue the authorized work"}}]},"tasks":[
{"id":"archive-working","record_disposition":"archive_done","current_state":{"state":"working"}},
{"id":"archive-ambiguous","record_disposition":"archive_done","current_state":{"state":"unknown"}},
{"id":"accepted-working","record_disposition":"done","current_state":{"state":"working"}},
{"id":"record-archive-working","record_disposition":"archive_done","current_state":{"state":"working"}},
{"id":"invalid-archive","record_disposition":"active","current_state":{"state":"working"}},
{"id":"active-working","record_disposition":"active","current_state":{"state":"working"}},
{"id":"done-open-gap","record_disposition":"done","current_state":{"state":"unknown"}}]}
JSON
SH
chmod +x "$CANDIDATE_CODE_ROOT/bin/fm-fleet-snapshot.sh"
cat > "$CANDIDATE_CODE_ROOT/bin/fm-task-disposition-lib.sh" <<'SH'
fm_task_disposition_snapshot() { :; }
SH
FM_HOME="$CANDIDATE_HOME" FM_JSONL_VIEWER_TOKEN="$TOKEN" FM_JSONL_VIEWER_PORT=0 \
  node "$CANDIDATE_CODE_ROOT/bin/fm-jsonl-viewer.mjs" > "$CANDIDATE_LOG" 2>&1 &
CANDIDATE_SERVER_PID=$!
for _ in $(seq 1 100); do
  CANDIDATE_PORT=$(sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' "$CANDIDATE_LOG")
  [ -n "${CANDIDATE_PORT:-}" ] && break
  sleep 0.05
done
[ -n "${CANDIDATE_PORT:-}" ] || fail "candidate viewer did not report its bound port"
CANDIDATE_BASE="http://127.0.0.1:$CANDIDATE_PORT"
curl -sS -H "Authorization: Bearer $TOKEN" "$CANDIDATE_BASE/api/tasks" > "$TMP_ROOT/candidate-tasks.json"
jq -e '
  (.tasks | any(.id == "archive-working" and .category == "history" and .status == "Archived"
    and .warning == "Remote status unconfirmed; archive reflects business disposition only."))
  and (.tasks | any(.id == "archive-ambiguous" and .category == "history" and (.warning | contains("Remote status unconfirmed"))))
  and (.tasks | any(.id == "accepted-working" and .category == "held" and .status == "Completion conflict" and .warning == null))
  and (.tasks | any(.id == "record-archive-working" and .category == "history" and .status == "Archived"))
  and (.tasks | any(.id == "invalid-archive" and .category == "processing" and .warning == null))
  and (.tasks | any(.id == "active-working" and .category == "processing"))
  and (.tasks | any(.id == "done-open-gap" and .category == "held" and .status == "Unresolved goal gap"))
  and ([.tasks[] | .category] | sort | group_by(.) | map({(.[0]): length}) | add == {held:2,history:3,processing:2})
' "$TMP_ROOT/candidate-tasks.json" >/dev/null || fail "candidate archive classification or controls were incorrect"
kill "$CANDIDATE_SERVER_PID" 2>/dev/null || true
wait "$CANDIDATE_SERVER_PID" 2>/dev/null || true
CANDIDATE_SERVER_PID=

FM_HOME="$HOME_FIXTURE" FM_JSONL_VIEWER_TOKEN_FILE="$TOKEN_FILE" FM_JSONL_VIEWER_PORT=0 \
  node "$ROOT/bin/fm-jsonl-viewer.mjs" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

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
status=$(curl -sS -o "$TMP_ROOT/tasks-denied.json" -w '%{http_code}' "$BASE/api/tasks")
[ "$status" = 401 ] || fail "unauthenticated task discovery returned HTTP $status"
status=$(curl -sS -o "$TMP_ROOT/task-document-denied.json" -w '%{http_code}' "$BASE/api/task-document?id=held-task")
[ "$status" = 401 ] || fail "unauthenticated task document read returned HTTP $status"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/sessions" > "$TMP_ROOT/sessions.json"
jq -e --arg id "$SHORT_ID" '.sessions | any(.source == "short" and .id == $id)' "$TMP_ROOT/sessions.json" >/dev/null || fail "ShortTask journal was not discovered"
jq -e '.sessions | any(.source == "supervisor" and .id == "session-one.jsonl")' "$TMP_ROOT/sessions.json" >/dev/null || fail "supervisor session was not discovered"
jq -e '.sessions | all(.id != "escaped.jsonl")' "$TMP_ROOT/sessions.json" >/dev/null || fail "symlink escape was discovered"
jq -e '.reports | any(.source == "report" and .id == "task-one" and .label == "task-one")' "$TMP_ROOT/sessions.json" >/dev/null || fail "canonical task report was not discovered"
jq -e '.reports | any(.source == "report" and .id == "_task-two" and .label == "_task-two")' "$TMP_ROOT/sessions.json" >/dev/null || fail "canonical report for a valid prefixed task id was not discovered"
jq -e '.reports | all(.id != "escaped" and .id != "linked-task")' "$TMP_ROOT/sessions.json" >/dev/null || fail "symlinked report path was discovered"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/tasks" > "$TMP_ROOT/tasks.json"
# Explicit archived rows remain visible without consulting a second task record.
jq -e '
  (.tasks | any(.id == "task-one" and .category == "processing" and .status == "Processing" and .hasDocument == true and .documentType == "report" and .documentTypes == ["report","brief"]))
    and (.tasks | any(.id == "completed-task" and .category == "completed" and .status == "Completed" and .hasDocument == false and .documentType == null and .documentTypes == []))
    and (.tasks | any(.id == "held-task" and .category == "held" and (.wait | contains("upstream-task")) and .hasDocument == true and .documentType == "brief" and .documentTypes == ["brief"]))
    and (.tasks | any(.id == "archived-task" and .category == "history" and .status == "Archived"))
    and (.tasks | any(.id == "cancelled-task" and .category == "history" and .status == "Cancelled" and (.warning | contains("Remote status unconfirmed"))))
    and (.tasks | all(.id != "invalid-lifecycle-task"))
    and (.tasks | all((keys | sort) == ["category","documentModifiedAt","documentType","documentTypes","hasDocument","id","kind","project","status","title","wait","warning"]))
' "$TMP_ROOT/tasks.json" >/dev/null || fail "task overview did not preserve authoritative processing, completed, held, archived, and document states"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/tasks" > "$TMP_ROOT/tasks-cached.json"
jq -e '.cacheHit == true and (.cacheAgeMs | type) == "number"' "$TMP_ROOT/tasks-cached.json" >/dev/null \
  || fail "repeated task overview did not use the bounded cache"

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
status=$(curl -sS -o "$TMP_ROOT/report-brief-only.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=held-task")
[ "$status" = 404 ] || fail "standalone report API exposed a task brief"
status=$(curl -sS -o "$TMP_ROOT/task-document-traversal.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/task-document?id=..%2F..%2Foutside")
[ "$status" = 404 ] || fail "task document traversal selection returned HTTP $status"
status=$(curl -sS -o "$TMP_ROOT/task-document-symlink.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/task-document?id=escaped-brief")
[ "$status" = 404 ] || fail "symlinked task brief selection returned HTTP $status"
status=$(curl -sS -o "$TMP_ROOT/task-document-missing.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/task-document?id=completed-task")
[ "$status" = 404 ] || fail "task without a canonical document returned HTTP $status"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=task-one" > "$TMP_ROOT/report.json"
jq -e '.source == "report" and .id == "task-one" and (.content | contains("Visible report body.")) and .size > 0 and (.identity | length) > 0' "$TMP_ROOT/report.json" >/dev/null || fail "canonical task report was not read intact"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=_task-two" > "$TMP_ROOT/prefixed-report.json"
jq -e '.source == "report" and .id == "_task-two" and (.content | contains("Prefixed task report"))' "$TMP_ROOT/prefixed-report.json" >/dev/null || fail "canonical report for a valid prefixed task id was not read intact"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/task-document?id=task-one" > "$TMP_ROOT/task-report-document.json"
jq -e '.source == "report" and (.content | contains("Visible report body.")) and (.content | contains("Superseded task brief") | not)' "$TMP_ROOT/task-report-document.json" >/dev/null || fail "task document did not prefer the canonical report"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/task-document?id=task-one&type=brief" > "$TMP_ROOT/task-explicit-brief-document.json"
jq -e '.source == "brief" and (.content | contains("Superseded task brief")) and (.content | contains("Visible report body.") | not)' "$TMP_ROOT/task-explicit-brief-document.json" >/dev/null || fail "explicit task brief selection did not read the allowlisted brief"
status=$(curl -sS -o "$TMP_ROOT/task-document-invalid-type.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/task-document?id=task-one&type=secret")
[ "$status" = 404 ] || fail "non-allowlisted task document type returned HTTP $status"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/task-document?id=held-task" > "$TMP_ROOT/task-brief-document.json"
jq -e '.source == "brief" and .id == "held-task" and (.content | contains("Visible brief body."))' "$TMP_ROOT/task-brief-document.json" >/dev/null || fail "task document did not fall back to the canonical brief"
printf '\nChanged report body.\n' >> "$REPORT_DIR/report.md"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/report?id=task-one" > "$TMP_ROOT/report-changed.json"
jq -e '(.content | contains("Changed report body.")) and .size > 0' "$TMP_ROOT/report-changed.json" >/dev/null || fail "changed task report was not refreshed"

sed -i 's/## In flight/## In flight\n\n## Done/; /task-one - Processing task/d' "$HOME_FIXTURE/data/backlog.md"
sed -i '/Accepted completed task/a\- [x] task-one - Processing task (repo: viewer) (kind: ship)' "$HOME_FIXTURE/data/backlog.md"
sleep 6
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/tasks" > "$TMP_ROOT/tasks-refreshed.json"
jq -e '.cacheHit == true and .refreshing == true and (.tasks | any(.id == "task-one" and .category == "processing"))' "$TMP_ROOT/tasks-refreshed.json" >/dev/null \
  || fail "expired task snapshot did not remain useful while its refresh started"
for _ in $(seq 1 100); do
  curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/tasks" > "$TMP_ROOT/tasks-refreshed.json"
  jq -e '.tasks | any(.id == "task-one" and .category == "completed" and .status == "Completed")' "$TMP_ROOT/tasks-refreshed.json" >/dev/null && break
  sleep 0.05
done
jq -e '.tasks | any(.id == "task-one" and .category == "completed" and .status == "Completed")' "$TMP_ROOT/tasks-refreshed.json" >/dev/null || fail "task status refresh did not replace processing with accepted completion"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=short&id=$SHORT_ID&cursor=0" > "$TMP_ROOT/short-page.json"
jq -e '.events | any(.value.message.role == "assistant" and (.value.message.content | any(.type == "toolCall")))' "$TMP_ROOT/short-page.json" >/dev/null || fail "nested ShortTask tool call was not preserved"
jq -e '.events | any(.value.message.role == "toolResult")' "$TMP_ROOT/short-page.json" >/dev/null || fail "ShortTask tool result was not preserved"
jq -e '.events | any(.value.type == "future_event")' "$TMP_ROOT/short-page.json" >/dev/null || fail "unknown event type was not preserved"
jq -e '.events | any(.error == "malformed_json")' "$TMP_ROOT/short-page.json" >/dev/null || fail "malformed line was not surfaced"
jq -e '.partialBytes > 0 and .eof == false' "$TMP_ROOT/short-page.json" >/dev/null || fail "partial final line was presented as complete"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=short&id=$DENSE_SHORT_ID&cursor=tail" > "$TMP_ROOT/dense-tail.json"
jq -e '(.events | length) == 200 and .eof == true and .events[0].value.message.content[0].text == "dense-event-2" and .events[-1].value.message.content[0].text == "dense-event-201"' "$TMP_ROOT/dense-tail.json" >/dev/null \
  || fail "dense tail did not return the actual newest records"
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"dense-partial' >> "$DENSE_SHORT_DIR/journal.jsonl"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=short&id=$DENSE_SHORT_ID&cursor=tail" > "$TMP_ROOT/dense-partial-tail.json"
jq -e '(.events | length) == 200 and .eof == false and .partialBytes > 0 and .events[0].value.message.content[0].text == "dense-event-2" and .events[-1].value.message.content[0].text == "dense-event-201"' "$TMP_ROOT/dense-partial-tail.json" >/dev/null \
  || fail "dense tail charged an incomplete line against the newest record quota"
head -c 600000 /dev/zero | tr '\0' x >> "$DENSE_SHORT_DIR/journal.jsonl"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=short&id=$DENSE_SHORT_ID&cursor=tail" > "$TMP_ROOT/dense-large-partial-tail.json"
jq -e '(.events | length) == 200 and .eof == false and .partialBytes > 600000 and .events[0].value.message.content[0].text == "dense-event-2" and .events[-1].value.message.content[0].text == "dense-event-201"' "$TMP_ROOT/dense-large-partial-tail.json" >/dev/null \
  || fail "large incomplete append displaced the actual newest complete records"
cursor=$(jq -r '.nextCursor' "$TMP_ROOT/short-page.json")
identity=$(jq -r '.identity' "$TMP_ROOT/short-page.json")

printf ' text"}]}}\n' >> "$SHORT_DIR/journal.jsonl"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=short&id=$SHORT_ID&cursor=$cursor&identity=$identity" > "$TMP_ROOT/appended.json"
jq -e '(.events | length) == 1 and .events[0].value.message.content[0].text == "partial text" and .eof == true' "$TMP_ROOT/appended.json" >/dev/null || fail "completed partial line did not recover on append"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=long.jsonl&cursor=0" > "$TMP_ROOT/long.json"
jq -e '(.events | length) == 1 and .events[0].bytes > 1000000 and .events[0].value.message.role == "user"' "$TMP_ROOT/long.json" >/dev/null || fail "long valid line was clipped or omitted"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=wide-tail.jsonl&cursor=tail" > "$TMP_ROOT/wide-tail.json"
jq -e '(.events | length) == 2 and .eof == true and .events[0].value.timestamp == 2 and (.events[0].value.content | length) == 2000000 and .events[1].value.timestamp == 3 and .events[1].value.content == "newest"' "$TMP_ROOT/wide-tail.json" >/dev/null \
  || fail "wide tail-crossing record prevented the actual newest record from loading"

supervisor_identity=$(curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=session-one.jsonl&cursor=0" | jq -r '.identity')
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/api/events?source=supervisor&id=session-one.jsonl&cursor=0" > "$TMP_ROOT/supervisor-native-response.json"
jq -e '(.events | any(.value.customType == "openai-codex-compat-native-response")) and (.events | any(.value.message.content[0].text == "ordinary text mentions openai-codex-compat-native-response"))' "$TMP_ROOT/supervisor-native-response.json" >/dev/null || fail "supervisor API did not preserve the native response and neighboring ordinary text"
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
