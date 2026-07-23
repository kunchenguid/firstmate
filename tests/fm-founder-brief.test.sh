#!/usr/bin/env bash
# Behavior tests for the optional mandatory founder pre-work brief gate.
#
# Every delivery uses the loopback fake Telegram endpoint below.
# No test can reach or send a real Telegram message.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-founder-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-founder-brief)
SERVER_DIR="$TMP_ROOT/fake-telegram"
SERVER_SCRIPT="$SERVER_DIR/server.py"
SERVER_PORT_FILE="$SERVER_DIR/port"
SERVER_MODE_FILE="$SERVER_DIR/mode"
SERVER_COUNT_FILE="$SERVER_DIR/count"
SERVER_REQUESTS_FILE="$SERVER_DIR/requests.jsonl"
SERVER_UPDATES_FILE="$SERVER_DIR/updates.json"
CHAT_ID=424242
FAKE_TOKEN='test-bot-token'
USER_ID=31337
TEST_NOW=2000000000
SERVER_PID=

mkdir -p "$SERVER_DIR"
chmod 700 "$SERVER_DIR"

cat > "$SERVER_SCRIPT" <<'PY'
import json
import os
import pathlib
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = pathlib.Path(os.environ["FAKE_TELEGRAM_DIR"])
chat_id = int(os.environ["FAKE_TELEGRAM_CHAT_ID"])


def atomic_text(path, text):
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        count_path = root / "count"
        count = int(count_path.read_text().strip() or "0") + 1
        atomic_text(count_path, f"{count}\n")
        recorded = json.loads(body)
        recorded["_telegram_method"] = self.path.rsplit("/", 1)[-1]
        with (root / "requests.jsonl").open("ab") as handle:
            handle.write(json.dumps(recorded, separators=(",", ":")).encode("utf-8") + b"\n")
        mode = (root / "mode").read_text(encoding="utf-8").strip()
        status = 200
        if mode == "timeout":
            time.sleep(0.5)
        if self.path.endswith("/getUpdates"):
            if mode == "malformed-updates":
                payload = {"ok": True, "result": "not-a-list"}
            else:
                payload = {"ok": True, "result": json.loads((root / "updates.json").read_text())}
        elif self.path.endswith("/answerCallbackQuery"):
            if mode == "malformed":
                payload = {"ok": True, "result": "not-boolean"}
            elif mode == "rejected":
                status = 400
                payload = {"ok": False, "description": "fixture callback rejection"}
            else:
                payload = {"ok": True, "result": True}
        elif mode == "wrong-chat":
            payload = {"ok": True, "result": {"message_id": count, "chat": {"id": chat_id + 1}}}
        elif mode == "malformed":
            payload = {"ok": True}
        elif mode == "rejected":
            status = 400
            payload = {"ok": False, "description": "fixture rejection"}
        else:
            payload = {"ok": True, "result": {"message_id": count, "chat": {"id": chat_id}}}
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, _format, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
atomic_text(root / "port", f"{server.server_address[1]}\n")
server.serve_forever()
PY
chmod 700 "$SERVER_SCRIPT"
printf 'success\n' > "$SERVER_MODE_FILE"
printf '0\n' > "$SERVER_COUNT_FILE"
: > "$SERVER_REQUESTS_FILE"
printf '[]\n' > "$SERVER_UPDATES_FILE"
chmod 600 "$SERVER_MODE_FILE" "$SERVER_COUNT_FILE" "$SERVER_REQUESTS_FILE" "$SERVER_UPDATES_FILE"

FAKE_TELEGRAM_DIR="$SERVER_DIR" FAKE_TELEGRAM_CHAT_ID="$CHAT_ID" \
  python3 "$SERVER_SCRIPT" &
SERVER_PID=$!

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

wait_i=0
while [ ! -s "$SERVER_PORT_FILE" ]; do
  wait_i=$((wait_i + 1))
  [ "$wait_i" -lt 100 ] || fail "fake Telegram endpoint did not start"
  sleep 0.02
done
SERVER_ENDPOINT="http://127.0.0.1:$(cat "$SERVER_PORT_FILE")"

file_mode() {
  if stat -f %Lp "$1" >/dev/null 2>&1; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  chmod 700 "$home" "$home/config" "$home/data" "$home/state" "$home/projects"
  printf 'telegram-mandatory\n' > "$home/config/founder-brief"
  chmod 600 "$home/config/founder-brief"
  seed_protocol_green "$home"
  printf '%s\n' "$home"
}

new_conversation_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  chmod 700 "$home" "$home/config" "$home/data" "$home/state" "$home/projects"
  printf 'telegram-conversation\n' > "$home/config/founder-brief"
  chmod 600 "$home/config/founder-brief"
  printf '%s\n' "$home"
}

seed_protocol_green() {
  local home=$1 now=${2:-$TEST_NOW}
  python3 - "$home" "$OWNER" "$ROOT/tests/fm-founder-brief.test.sh" \
    "$CHAT_ID" "$USER_ID" "$now" <<'PY'
import hashlib, json, os, pathlib, sys, tempfile
home = pathlib.Path(sys.argv[1])
owner = pathlib.Path(sys.argv[2])
test = pathlib.Path(sys.argv[3])
chat, user, now = sys.argv[4], sys.argv[5], int(sys.argv[6])
def write(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
write(home / "state" / "telegram-protocol-regression.json", {
    "schema_version": 1,
    "kind": "telegram-protocol-regression",
    "status": "passed",
    "home": str(home.resolve()),
    "owner_sha256": hashlib.sha256(owner.read_bytes()).hexdigest(),
    "test_sha256": hashlib.sha256(test.read_bytes()).hexdigest(),
    "verified_at": now,
})
write(home / "state" / "telegram-conversation-canary.json", {
    "schema_version": 1,
    "kind": "telegram-conversation-canary",
    "protocol_version": "telegram-dual-lane-v1",
    "status": "passed",
    "home": str(home.resolve()),
    "chat_identity_sha256": hashlib.sha256(chat.encode()).hexdigest(),
    "user_identity_sha256": hashlib.sha256(user.encode()).hexdigest(),
    "canary_evidence_sha256": "a" * 64,
    "update_ids": [1, 2, 3],
    "verified_at": now,
})
PY
}

new_optout_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  chmod 700 "$home" "$home/config" "$home/data" "$home/state" "$home/projects"
  printf '%s\n' "$home"
}

write_valid_brief() {
  local home=$1 task=$2
  mkdir -p "$home/data/$task"
  chmod 700 "$home/data/$task"
  cat > "$home/data/$task/founder-brief.md" <<'EOF'
# Founder pre-work brief

## Project and customer context

Firstmate coordinates software work for the founder and keeps assignments visible before they begin.

## Requirement and why now

This phase is starting now because the founder authorized a bounded piece of work.

## Intended capability and outcome

The founder will know what is starting, why it matters, and how completion will be proved.

## Affected product surfaces

The affected surfaces are task intake, worker launch, lifecycle promotion, and delivery records.

## In scope

This phase includes only the assignment described in the task brief.

## Out of scope

This phase does not approve a merge, deployment, destructive action, or broader product change.

## Risks and safety boundaries

Work remains bounded by the task brief, existing delivery gates, and secret-safe messaging.

## Dependencies

The task brief and required local tools must already be available.

## Planned proof

Tests will prove the requested behavior and the worker will report the concrete outcome.
EOF
  chmod 600 "$home/data/$task/founder-brief.md"
}

write_during_brief() {
  local home=$1 task=$2 project=$3 transition=$4 state=$5
  mkdir -p "$home/data/$task"
  chmod 700 "$home/data/$task"
  cat > "$home/data/$task/founder-during.md" <<EOF
# Founder DURING communication

## Project

$project

## Material transition

$transition

## Latest material state

$state

## Risks or blockers

None.

## Proof

- Deterministic fixture proof

## Next step

Continue the bounded phase.
EOF
  chmod 600 "$home/data/$task/founder-during.md"
}

write_post_brief() {
  local home=$1 task=$2 project=$3
  mkdir -p "$home/data/$task"
  chmod 700 "$home/data/$task"
  cat > "$home/data/$task/founder-post.md" <<EOF
# Founder POST communication

## Project

$project

## Outcome

The bounded phase completed with the requested capability.

## Proof

- Focused tests passed
- Durable receipt published

## Remaining limits

The live canary remains firstmate-owned after merge.

## Next step

Continue through the repository delivery path.
EOF
  chmod 600 "$home/data/$task/founder-post.md"
}

write_decision_digest() {
  local home=$1 digest=$2 revision=$3 version=1
  [ "$revision" = v2 ] && version=2
  mkdir -p "$home/data/founder-brief-decisions"
  chmod 700 "$home/data/founder-brief-decisions"
  cat > "$home/data/founder-brief-decisions/$digest.json" <<EOF
{
  "schema_version": 1,
  "digest_id": "$digest",
  "expires_at": 2000003600,
  "summary": "Two bounded project choices need an explicit captain selection.",
  "decisions": [
    {
      "project": "Alpha <Launch>",
      "task": "alpha-task",
      "decision_id": "alpha-release-route",
      "version": $version,
      "decision_key": "release-route",
      "question": "Choose the Alpha release route $revision.",
      "context": "The pilot is ready and the release route remains the only open launch choice.",
      "why_now": "Implementation is complete and release is waiting.",
      "recommendation": "Use the staged route to bound launch risk.",
      "authority_boundary": "Only the authenticated captain selection is recorded; merge authority remains unchanged.",
      "options": [
        {"number": 1, "key": "staged", "label": "Staged", "outcome": "Release to the bounded pilot first."},
        {"number": 2, "key": "hold", "label": "Hold", "outcome": "Keep the release parked."}
      ]
    },
    {
      "project": "Beta & Safety",
      "task": "beta-task",
      "decision_id": "beta-remediation-route",
      "version": 1,
      "decision_key": "remediation-route",
      "question": "Choose the Beta remediation route.",
      "context": "The risk is bounded, but remediation cannot begin without an explicit route.",
      "why_now": "A material risk is blocking the next phase.",
      "recommendation": "Choose Repair to close the verified risk before continuing.",
      "authority_boundary": "Security-sensitive action still requires the captain's exact authenticated choice.",
      "options": [
        {"number": 3, "key": "repair", "label": "Repair", "outcome": "Authorize the bounded repair plan."},
        {"number": 4, "key": "pause", "label": "Pause", "outcome": "Keep remediation paused."}
      ]
    }
  ]
}
EOF
  chmod 600 "$home/data/founder-brief-decisions/$digest.json"
}

set_decision_expiry() {
  local home=$1 digest=$2 expires_at=$3
  python3 - "$home/data/founder-brief-decisions/$digest.json" "$expires_at" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["expires_at"] = int(sys.argv[2])
path.write_text(
    json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  chmod 600 "$home/data/founder-brief-decisions/$digest.json"
}

write_callback_update() {
  local home=$1 name=$2 callback_id=$3 callback_data=$4 message_id=$5 chat_id=$6 user_id=$7
  local path="$home/state/$name.json"
  cat > "$path" <<EOF
{"update_id":9001,"callback_query":{"id":"$callback_id","from":{"id":$user_id},"message":{"message_id":$message_id,"chat":{"id":$chat_id}},"data":"$callback_data"}}
EOF
  chmod 600 "$path"
  printf '%s\n' "$path"
}

write_text_update() {
  local home=$1 name=$2 update_id=$3 message_id=$4 text=$5 reply_to=${6:-}
  local path="$home/state/$name.json"
  if [ -n "$reply_to" ]; then
    cat > "$path" <<EOF
{"update_id":$update_id,"message":{"message_id":$message_id,"date":2000000000,"chat":{"id":$CHAT_ID},"from":{"id":$USER_ID},"reply_to_message":{"message_id":$reply_to},"text":"$text"}}
EOF
  else
    cat > "$path" <<EOF
{"update_id":$update_id,"message":{"message_id":$message_id,"date":2000000000,"chat":{"id":$CHAT_ID},"from":{"id":$USER_ID},"text":"$text"}}
EOF
  fi
  chmod 600 "$path"
  printf '%s\n' "$path"
}

run_owner() {
  local home=$1
  shift
  FM_HOME="$home" \
    TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" \
    TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" \
    FM_FOUNDER_BRIEF_NOW="$TEST_NOW" \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    "$OWNER" "$@"
}

run_owner_at() {
  local home=$1 now=$2
  shift 2
  FM_HOME="$home" \
    TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" \
    TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" \
    FM_FOUNDER_BRIEF_NOW="$now" \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    "$OWNER" "$@"
}

run_owner_timeout() {
  local home=$1
  shift
  FM_HOME="$home" \
    TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" \
    TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" \
    FM_FOUNDER_BRIEF_NOW="$TEST_NOW" \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    FM_FOUNDER_BRIEF_TIMEOUT=0.05 \
    "$OWNER" "$@"
}

server_mode() {
  printf '%s\n' "$1" > "$SERVER_MODE_FILE"
}

server_count() {
  cat "$SERVER_COUNT_FILE"
}

request_count() {
  wc -l < "$SERVER_REQUESTS_FILE" | tr -d ' '
}

receipt_count() {
  local home=$1
  find "$home/state/founder-brief-receipts" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

decision_binding() {
  local home=$1 task=$2 option=$3
  python3 - "$home" "$task" "$option" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
task, option = sys.argv[2:]
pointers = [
    json.loads(path.read_text(encoding="utf-8"))
    for path in (home / "state" / "founder-brief-decision-current").glob("*.json")
]
pointer = next(item for item in pointers if item["task"] == task)
buttons = [
    json.loads(path.read_text(encoding="utf-8"))
    for path in (home / "state" / "founder-brief-buttons").glob("*.json")
]
button = next(
    item for item in buttons
    if item.get("delivery_dedupe_key") == pointer["delivery_dedupe_key"]
    and item.get("option", {}).get("key") == option
)
receipt = json.loads(
    (home / "state" / "founder-brief-receipts" / f"{pointer['delivery_dedupe_key']}.json")
    .read_text(encoding="utf-8")
)
print(button["callback_data"], receipt["telegram_message_ids"][-1])
PY
}

approval_path_for_task() {
  local home=$1 task=$2
  python3 - "$home" "$task" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
task = sys.argv[2]
for path in (home / "state" / "founder-brief-approvals").glob("*.json"):
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("task") == task:
        print(path)
        break
PY
}

conversation_manifest() {
  local home=$1
  python3 - "$home" <<'PY'
import hashlib, json, pathlib, stat, sys
home = pathlib.Path(sys.argv[1])
roots = (
    home / "state" / "telegram-inbox",
    home / "state" / "telegram-conversation-receipts",
    home / "state" / "telegram-conversation-outcomes",
    home / "data" / "telegram-replies",
    home / "data" / "telegram-outcomes",
)
files = []
for root in roots:
    if not root.exists():
        continue
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        payload = path.read_bytes()
        files.append(
            {
                "path": str(path.relative_to(home)),
                "mode": stat.S_IMODE(path.stat().st_mode),
                "bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            }
        )
offset = home / "state" / "telegram-relay.offset"
if offset.exists():
    payload = offset.read_bytes()
    files.append(
        {
            "path": str(offset.relative_to(home)),
            "mode": stat.S_IMODE(offset.stat().st_mode),
            "bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
    )
print(json.dumps({"count": len(files), "files": files}, sort_keys=True, separators=(",", ":")))
PY
}

test_create_and_validation_contract() {
  local home task out rc before path
  home=$(new_home create)
  task=founder-create-a1
  out=$(run_owner "$home" create "$task" assignment 2>&1); rc=$?
  expect_code 0 "$rc" "create should scaffold a private founder brief"
  assert_contains "$out" "scaffolded founder brief" "create did not report its scaffold"
  assert_present "$home/data/$task/founder-brief.md" "create did not publish the brief"
  [ "$(file_mode "$home/data/$task")" = 700 ] || fail "task brief directory must be mode 0700"
  [ "$(file_mode "$home/data/$task/founder-brief.md")" = 600 ] || fail "founder brief must be mode 0600"
  out=$(run_owner "$home" phase "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "placeholder founder brief must be rejected"
  assert_contains "$out" "placeholder text" "placeholder rejection was not actionable"

  before=$(server_count)
  write_valid_brief "$home" "$task"
  perl -0pi -e 's/^## Dependencies$/Dependencies/m' "$home/data/$task/founder-brief.md"
  out=$(run_owner "$home" phase "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "missing required heading must be rejected"
  assert_contains "$out" "exactly one section: Dependencies" "missing-heading rejection was not actionable"

  write_valid_brief "$home" "$task"
  printf '\001' >> "$home/data/$task/founder-brief.md"
  out=$(run_owner "$home" phase "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe control character must be rejected"
  assert_contains "$out" "unsafe control character" "control-character rejection was not actionable"

  write_valid_brief "$home" "$task"
  perl -e 'print "A" x 66000' >> "$home/data/$task/founder-brief.md"
  out=$(run_owner "$home" phase "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "founder brief above the bounded input maximum must be rejected"
  assert_contains "$out" "input is oversized" "input-size rejection was not actionable"
  [ "$(server_count)" -eq "$before" ] || fail "invalid founder brief reached the transport"
  run_owner "$home" during-create founder-create-during implementation >/dev/null 2>&1 \
    || fail "DURING template creation failed"
  run_owner "$home" post-create founder-create-post implementation >/dev/null 2>&1 \
    || fail "POST template creation failed"
  run_owner "$home" decision-create founder-create-decisions >/dev/null 2>&1 \
    || fail "decision template creation failed"
  for path in \
    "$home/data/founder-create-during/founder-during.md" \
    "$home/data/founder-create-post/founder-post.md" \
    "$home/data/founder-brief-decisions/founder-create-decisions.json"; do
    [ "$(file_mode "$path")" = 600 ] || fail "generated lifecycle template must be mode 0600: $path"
  done
  pass "founder brief create: private atomic scaffold and bounded content validation"
}

test_ack_dedupe_hash_and_phase() {
  local home task before after out rc
  home=$(new_home ack)
  task=founder-ack-b1
  write_valid_brief "$home" "$task"
  server_mode success
  before=$(server_count)
  run_owner "$home" phase "$task" assignment >/dev/null 2>&1 \
    || fail "valid Telegram acknowledgment should pass"
  run_owner "$home" verify "$task" assignment >/dev/null 2>&1 \
    || fail "matching receipt should verify"
  run_owner "$home" phase "$task" assignment >/dev/null 2>&1 \
    || fail "acknowledged retry should dedupe"
  after=$(server_count)
  [ "$after" -eq $((before + 1)) ] || fail "acknowledged retry sent a duplicate"
  out=$(run_owner "$home" verify "$task" implementation 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "assignment receipt must not authorize implementation"
  assert_contains "$out" "phase=implementation" "phase mismatch did not require a new receipt"
  printf '\nA harmless content revision changes the exact brief hash.\n' >> "$home/data/$task/founder-brief.md"
  out=$(run_owner "$home" verify "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "changed content hash must require a new delivery"
  assert_contains "$out" "no acknowledged founder brief" "changed hash did not invalidate the old receipt"
  pass "founder brief dedupe: exact home/task/phase/content binding without approval wait"
}

test_canonical_rendering_and_splitting() {
  local home task start after receipt_before receipt_after split_home split_task
  home=$(new_home rendering)
  task=founder-render-b2
  write_valid_brief "$home" "$task"
  perl -0pi -e \
    's/Firstmate coordinates software work for the founder and keeps assignments visible before they begin\./Founder <owner> & builders > hidden markup.\n- First bullet\n- Second bullet\nLiteral <b>injection<\/b> stays text./' \
    "$home/data/$task/founder-brief.md"
  server_mode success
  start=$(request_count)
  run_owner "$home" deliver "$task" assignment >/dev/null 2>&1 \
    || fail "special-character founder brief should render and deliver"
  after=$(request_count)
  [ "$after" -eq $((start + 1)) ] || fail "small rendered brief should use one Telegram message"
  python3 - "$SERVER_REQUESTS_FILE" "$start" "$home" <<'PY' \
    || fail "canonical Telegram rendering escaped or formatted content incorrectly"
import hashlib, html, json, pathlib, re, sys
requests = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
request = json.loads(requests[int(sys.argv[2])])
text = request["text"]
assert request["parse_mode"] == "HTML"
assert "<b>Project and customer context</b>" in text
assert "Founder &lt;owner&gt; &amp; builders &gt; hidden markup." in text
assert "- First bullet\n- Second bullet" in text
assert "Literal &lt;b&gt;injection&lt;/b&gt; stays text." in text
tags = re.findall(r"<[^>]+>", text)
assert tags and set(tags) == {"<b>", "</b>"}
visible = html.unescape(text.replace("<b>", "").replace("</b>", ""))
assert len(visible.encode("utf-8")) <= 4096
outboxes = list(pathlib.Path(sys.argv[3], "state", "founder-brief-outbox").glob("*.json"))
assert len(outboxes) == 1
outbox = json.loads(outboxes[0].read_text(encoding="utf-8"))
canonical = outbox["canonical_rendered_content"]
assert outbox["content_sha256"] == hashlib.sha256(canonical.encode("utf-8")).hexdigest()
assert outbox["dedupe_key"] == outboxes[0].stem
PY
  receipt_before=$(find "$home/state/founder-brief-receipts" -type f -name '*.json' -print)
  perl -0pi -e 's/^# Founder pre-work brief$/# Alternate private draft title/m' \
    "$home/data/$task/founder-brief.md"
  run_owner "$home" verify "$task" assignment >/dev/null 2>&1 \
    || fail "raw Markdown outside canonical rendered sections changed the dedupe identity"
  receipt_after=$(find "$home/state/founder-brief-receipts" -type f -name '*.json' -print)
  [ "$receipt_after" = "$receipt_before" ] \
    || fail "canonical-equivalent source produced a different receipt"

  split_home=$(new_home splitting)
  split_task=founder-split-b3
  write_valid_brief "$split_home" "$split_task"
  {
    printf '\n'
    split_i=0
    while [ "$split_i" -lt 320 ]; do
      printf 'proof-line 🚀 <safe> & evidence > claim '
      split_i=$((split_i + 1))
    done
    printf '\n'
  } >> "$split_home/data/$split_task/founder-brief.md"
  start=$(request_count)
  run_owner "$split_home" deliver "$split_task" assignment >/dev/null 2>&1 \
    || fail "long founder brief should split and deliver deterministically"
  after=$(request_count)
  [ "$after" -ge $((start + 3)) ] || fail "long founder brief did not split across Telegram messages"
  python3 - "$SERVER_REQUESTS_FILE" "$start" "$split_home" <<'PY' \
    || fail "Telegram splitting violated length, ordering, escaping, or receipt binding"
import html, json, pathlib, re, sys
requests = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()[int(sys.argv[2]):]
]
assert 3 <= len(requests) <= 20
total = len(requests)
escaped_fixture_parts = 0
for index, request in enumerate(requests, start=1):
    assert request["parse_mode"] == "HTML"
    text = request["text"]
    assert f"<b>Part:</b> {index}/{total}" in text
    if "&lt;safe&gt; &amp; evidence &gt; claim" in text:
        escaped_fixture_parts += 1
    assert set(re.findall(r"<[^>]+>", text)) == {"<b>", "</b>"}
    visible = html.unescape(text.replace("<b>", "").replace("</b>", ""))
    assert len(visible.encode("utf-8")) <= 4096
assert escaped_fixture_parts >= 2
outboxes = list(pathlib.Path(sys.argv[3], "state", "founder-brief-outbox").glob("*.json"))
assert len(outboxes) == 1
outbox = json.loads(outboxes[0].read_text(encoding="utf-8"))
assert [request["text"] for request in requests] == outbox["messages"]
receipts = list(pathlib.Path(sys.argv[3], "state", "founder-brief-receipts").glob("*.json"))
assert len(receipts) == 1
receipt = json.loads(receipts[0].read_text(encoding="utf-8"))
assert receipt["message_count"] == total
assert len(receipt["telegram_message_ids"]) == total
assert receipt["telegram_message_id"] == receipt["telegram_message_ids"][0]
PY
  run_owner "$split_home" deliver "$split_task" assignment >/dev/null 2>&1 \
    || fail "acknowledged split brief should dedupe"
  [ "$(request_count)" -eq "$after" ] || fail "acknowledged split brief sent duplicate parts"
  start=$(request_count)
  FM_HOME="$split_home" TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" FM_FOUNDER_BRIEF_NOW="$TEST_NOW" \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_RESPONSE=1 \
    "$OWNER" deliver "$split_task" review >/dev/null 2>&1
  [ "$?" -eq 86 ] || fail "split-delivery crash hook did not stop after the first staged part"
  run_owner "$split_home" deliver "$split_task" review >/dev/null 2>&1 \
    || fail "split-delivery retry did not recover and finish remaining parts"
  python3 - "$split_home" "$start" "$SERVER_REQUESTS_FILE" <<'PY' \
    || fail "split-delivery crash recovery duplicated or skipped a Telegram part"
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
start = int(sys.argv[2])
requests = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").splitlines()[start:]
receipts = [
    json.loads(path.read_text(encoding="utf-8"))
    for path in (home / "state" / "founder-brief-receipts").glob("*.json")
]
receipt = next(item for item in receipts if item["phase"] == "review")
assert len(requests) == receipt["message_count"]
assert len(receipt["telegram_message_ids"]) == receipt["message_count"]
PY
  pass "founder brief rendering: fixed bold HTML, escaped content, preserved bullets/newlines, canonical dedupe, and bounded splitting"
}

test_crash_and_timeout_dedupe() {
  local home task before after rc out timeout_home timeout_task
  home=$(new_home crash)
  task=founder-crash-c1
  write_valid_brief "$home" "$task"
  server_mode success
  before=$(server_count)
  FM_HOME="$home" TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" FM_FOUNDER_BRIEF_NOW="$TEST_NOW" \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_RESPONSE=1 \
    "$OWNER" deliver "$task" assignment >/dev/null 2>&1
  rc=$?
  expect_code 86 "$rc" "crash hook should stop after staging the response"
  [ "$(receipt_count "$home")" -eq 0 ] || fail "crash hook published a receipt before recovery"
  run_owner "$home" deliver "$task" assignment >/dev/null 2>&1 \
    || fail "retry should recover the staged acknowledgment"
  after=$(server_count)
  [ "$after" -eq $((before + 1)) ] || fail "crash recovery resent an acknowledged item"

  timeout_home=$(new_home timeout)
  timeout_task=founder-timeout-c2
  write_valid_brief "$timeout_home" "$timeout_task"
  server_mode timeout
  before=$(server_count)
  out=$(run_owner_timeout "$timeout_home" deliver "$timeout_task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "timeout must not publish an acknowledgment"
  assert_contains "$out" "delivery state is unknown" "timeout did not produce a safe unknown state"
  server_mode success
  out=$(run_owner "$timeout_home" deliver "$timeout_task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unknown timeout retry must not resend"
  assert_contains "$out" "refusing to resend" "unknown timeout retry was not fail-closed"
  after=$(server_count)
  [ "$after" -eq $((before + 1)) ] || fail "timeout retry duplicated an uncertain delivery"
  pass "founder brief retry: staged crash recovery and timeout-safe no-resend"
}

test_response_validation_and_retry() {
  local home task out rc before wrong_home malformed_home
  home=$(new_home rejected)
  task=founder-rejected-d1
  write_valid_brief "$home" "$task"
  server_mode rejected
  before=$(server_count)
  out=$(run_owner "$home" deliver "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "Telegram ok=false must be rejected"
  assert_contains "$out" "ok=false" "Telegram rejection was not reported"
  server_mode success
  run_owner "$home" deliver "$task" assignment >/dev/null 2>&1 \
    || fail "a definite ok=false attempt should be retryable"
  [ "$(server_count)" -eq $((before + 2)) ] || fail "definite failure retry count is wrong"

  wrong_home=$(new_home wrong)
  task=founder-wrong-d2
  write_valid_brief "$wrong_home" "$task"
  server_mode wrong-chat
  out=$(run_owner "$wrong_home" deliver "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "wrong Telegram chat must be rejected"
  assert_contains "$out" "chat identity does not match" "wrong-chat rejection was not explicit"
  [ "$(receipt_count "$wrong_home")" -eq 0 ] || fail "wrong-chat response published a receipt"

  malformed_home=$(new_home malformed)
  task=founder-malformed-d3
  write_valid_brief "$malformed_home" "$task"
  server_mode malformed
  out=$(run_owner "$malformed_home" deliver "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "malformed Telegram response must be rejected"
  assert_contains "$out" "missing result" "malformed response rejection was not explicit"
  [ "$(receipt_count "$malformed_home")" -eq 0 ] || fail "malformed response published a receipt"
  pass "founder brief response validation: ok, chat identity, and numeric message id are mandatory"
}

test_secret_safety_limits_and_permissions() {
  local home task secret out rc before path
  home=$(new_home safety)
  task=founder-safety-e1
  write_valid_brief "$home" "$task"
  secret='api_key=THIS_VALUE_MUST_NEVER_APPEAR_IN_OUTPUT'
  printf '\n%s\n' "$secret" >> "$home/data/$task/founder-brief.md"
  before=$(server_count)
  out=$(run_owner "$home" deliver "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "credential-like material must be rejected"
  assert_contains "$out" "credential-like material" "secret rejection lacked its safe reason"
  assert_not_contains "$out" "$secret" "secret value leaked into diagnostics"
  [ "$(server_count)" -eq "$before" ] || fail "secret-bearing brief reached the transport"

  write_valid_brief "$home" "$task"
  server_mode success
  run_owner "$home" deliver "$task" assignment >/dev/null 2>&1 \
    || fail "clean brief should deliver"
  for path in \
    "$home/state/founder-brief-outbox" \
    "$home/state/founder-brief-responses" \
    "$home/state/founder-brief-receipts" \
    "$home/state/founder-brief-locks"; do
    [ "$(file_mode "$path")" = 700 ] || fail "$path must be mode 0700"
  done
  while IFS= read -r path; do
    [ "$(file_mode "$path")" = 600 ] || fail "$path must be mode 0600"
  done < <(find "$home/state"/founder-brief-* -type f)
  [ -z "$(find "$home/state"/founder-brief-* -name '*.tmp' -print -quit)" ] \
    || fail "atomic publication left a temporary file"
  python3 - "$home" "$task" <<'PY' || fail "private founder brief records are incomplete or unbound"
import json, pathlib, sys
home = pathlib.Path(sys.argv[1]).resolve()
task = sys.argv[2]
state = home / "state"
for path in state.glob("founder-brief-*/*.json"):
    json.loads(path.read_text(encoding="utf-8"))
receipts = list((state / "founder-brief-receipts").glob("*.json"))
assert len(receipts) == 1
receipt = json.loads(receipts[0].read_text(encoding="utf-8"))
assert receipt["schema_version"] == 1
assert receipt["rendering_version"] == "telegram-html-v1"
assert receipt["home"] == str(home)
assert receipt["task"] == task
assert receipt["phase"] == "assignment"
assert len(receipt["content_sha256"]) == 64
assert len(receipt["chat_identity_sha256"]) == 64
assert receipt["dedupe_key"] == receipts[0].stem
assert isinstance(receipt["telegram_message_id"], int) and receipt["telegram_message_id"] > 0
assert receipt["message_count"] == 1
assert receipt["telegram_message_ids"] == [receipt["telegram_message_id"]]
PY
  pass "founder brief safety: bounded secret rejection, private modes, and complete atomic records"
}

test_during_digest_and_post_lifecycle() {
  local home before after final_request task out rc
  home=$(new_home lifecycle-digests)
  server_mode success
  write_valid_brief "$home" alpha-one
  run_owner "$home" phase alpha-one implementation >/dev/null 2>&1 \
    || fail "PRE implementation communication should mark the managed phase"
  write_during_brief "$home" alpha-one "Alpha <Launch>" "Milestone reached" \
    "The launch path now passes its bounded proof."
  before=$(request_count)
  run_owner "$home" during alpha-one implementation >/dev/null 2>&1 \
    || fail "first DURING material state should deliver"
  after=$(request_count)
  [ "$after" -eq $((before + 1)) ] || fail "first DURING digest did not send exactly once"
  run_owner "$home" during alpha-one implementation >/dev/null 2>&1 \
    || fail "unchanged DURING state should dedupe"
  [ "$(request_count)" -eq "$after" ] || fail "unchanged DURING state produced no-change chatter"

  write_during_brief "$home" alpha-two "Alpha <Launch>" "Risk changed" \
    "A second active task found a bounded launch risk."
  run_owner "$home" during alpha-two review >/dev/null 2>&1 \
    || fail "same-project DURING state should deliver a combined digest"
  write_during_brief "$home" beta-one "Beta & Safety" "Proof added" \
    "The safety proof now covers the requested boundary."
  run_owner "$home" during beta-one remediation >/dev/null 2>&1 \
    || fail "cross-project DURING state should deliver a grouped digest"
  final_request=$(tail -1 "$SERVER_REQUESTS_FILE")
  python3 - "$final_request" <<'PY' \
    || fail "DURING digest was not compact, grouped, escaped, and complete"
import html, json, re, sys
request = json.loads(sys.argv[1])
text = request["text"]
assert request["_telegram_method"] == "sendMessage"
assert "<b>DURING · Active work digest</b>" in text
assert text.index("Project · Alpha &lt;Launch&gt;") < text.index("Project · Beta &amp; Safety")
assert "alpha-one · implementation" in text
assert "alpha-two · review" in text
assert "beta-one · remediation" in text
assert set(re.findall(r"<[^>]+>", text)) == {"<b>", "</b>"}
visible = html.unescape(text.replace("<b>", "").replace("</b>", ""))
assert len(visible.encode("utf-8")) <= 4096
PY

  task=alpha-one
  out=$(run_owner "$home" verify-complete "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "managed task completion must block before POST acknowledgment"
  assert_contains "$out" "no acknowledged POST communication" \
    "missing POST completion gate was not actionable"
  write_post_brief "$home" "$task" "Alpha <Launch>"
  run_owner "$home" post "$task" implementation >/dev/null 2>&1 \
    || fail "POST completion should deliver"
  run_owner "$home" verify-complete "$task" >/dev/null 2>&1 \
    || fail "matching acknowledged POST should allow completion immediately"
  assert_absent "$home/state/founder-brief-active/$task.json" \
    "acknowledged POST did not retire the completed active task"
  python3 - "$SERVER_REQUESTS_FILE" <<'PY' \
    || fail "POST rendering omitted outcome, proof, limits, or next step"
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()[-1])
text = request["text"]
assert "<b>POST · Completion brief</b>" in text
for heading in ("Outcome", "Proof", "Remaining limits", "Next step"):
    assert f"<b>{heading}</b>" in text
assert "Alpha &lt;Launch&gt;" in text
PY
  pass "founder lifecycle: grouped material-only DURING digest and acknowledged POST retirement"
}

test_two_way_conversation_relay_and_replies() {
  local home start after id path rc send_before send_after
  home=$(new_conversation_home conversation)
  server_mode success
  cat > "$SERVER_UPDATES_FILE" <<EOF
[
  {"update_id":511294429,"message":{"message_id":7001,"date":2000000001,"chat":{"id":$CHAT_ID},"from":{"id":$USER_ID},"message_thread_id":55,"text":"First ordinary request"}},
  {"update_id":511294430,"message":{"message_id":7002,"date":2000000002,"chat":{"id":$CHAT_ID},"from":{"id":$USER_ID},"reply_to_message":{"message_id":6999},"text":"Second ordinary request"}},
  {"update_id":511294431,"message":{"message_id":7003,"date":2000000003,"chat":{"id":$CHAT_ID},"from":{"id":$USER_ID},"text":"Third <unsafe> & ordinary request"}},
  {"update_id":511294432,"edited_message":{"message_id":7003,"date":2000000003,"edit_date":2000000004,"chat":{"id":$CHAT_ID},"from":{"id":$USER_ID},"text":"Third revised request"}},
  {"update_id":511294433,"message":{"message_id":7999,"date":2000000005,"chat":{"id":$CHAT_ID},"from":{"id":99999},"text":"Foreign sender must not route"}}
]
EOF
  chmod 600 "$SERVER_UPDATES_FILE"
  start=$(request_count)
  run_owner "$home" relay-once >/dev/null 2>&1 \
    || fail "tracked conversation relay should accept and acknowledge ordered messages"
  after=$(request_count)
  python3 - "$home" "$SERVER_REQUESTS_FILE" "$start" "$after" <<'PY' \
    || fail "conversation relay lost identity/threading data or failed to bind prompt acknowledgments"
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
requests = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()[
        int(sys.argv[3]):int(sys.argv[4])
    ]
]
assert [item["_telegram_method"] for item in requests].count("getUpdates") == 1
sends = [item for item in requests if item["_telegram_method"] == "sendMessage"]
assert len(sends) == 4
assert [item["reply_parameters"]["message_id"] for item in sends] == [7001, 7002, 7003, 7003]
assert all(item["reply_parameters"]["allow_sending_without_reply"] is False for item in sends)
assert sends[0]["message_thread_id"] == 55
assert all("message_thread_id" not in item for item in sends[1:])
records = {}
for update_id in range(511294429, 511294433):
    path = home / "state" / "telegram-inbox" / f"{update_id}.json"
    assert path.exists()
    value = json.loads(path.read_text(encoding="utf-8"))
    records[update_id] = value
    assert value["update_id"] == update_id
    assert value["chat_id"] == 424242
    assert value["sender_user_id"] == 31337
    assert value["acknowledgment_dedupe_key"]
assert records[511294429]["message_thread_id"] == 55
assert records[511294430]["reply_to_message_id"] == 6999
assert records[511294431]["text"] == "Third <unsafe> & ordinary request"
assert records[511294432]["message_kind"] == "edited_message"
assert records[511294432]["message_id"] == 7003
assert records[511294432]["edit_date"] == 2000000004
assert not (home / "state" / "telegram-inbox" / "511294433.json").exists()
assert (home / "state" / "telegram-relay.offset").read_text().strip() == "511294434"
PY
  send_before=$(python3 - "$SERVER_REQUESTS_FILE" <<'PY'
import json, pathlib, sys
print(sum(
    json.loads(line)["_telegram_method"] == "sendMessage"
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
))
PY
  )
  run_owner "$home" relay-once >/dev/null 2>&1 \
    || fail "relay replay below the durable offset should be harmless"
  send_after=$(python3 - "$SERVER_REQUESTS_FILE" <<'PY'
import json, pathlib, sys
print(sum(
    json.loads(line)["_telegram_method"] == "sendMessage"
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
))
PY
  )
  [ "$send_after" -eq "$send_before" ] || fail "relay replay duplicated a prompt acknowledgment"

  bare_path=$(write_text_update "$home" numeric-ordinary 511294435 7005 7)
  before=$(request_count)
  run_owner "$home" route-update "$bare_path" >/dev/null 2>&1 \
    || fail "bare numeric conversation should stay ordinary when decision automation is off"
  after=$(request_count)
  [ "$after" -eq $((before + 1)) ] || fail "bare numeric conversation did not receive a normal acknowledgment"
  assert_not_contains "$(cat "$home/state/telegram-inbox/511294435.json")" '"handled_as"' \
    "bare numeric conversation was misrouted as decision automation"

  for id in 511294429 511294430 511294431 511294432; do
    run_owner "$home" reply-create "$id" >/dev/null 2>&1 \
      || fail "conversation reply template failed for update $id"
    path="$home/data/telegram-replies/$id.md"
    if [ "$id" = 511294432 ]; then
      {
        printf 'Long revised response with escaped <reply> & proof.\n'
        reply_i=0
        while [ "$reply_i" -lt 500 ]; do
          printf 'Evidence 🚀 line %s remains bound to the edited message.\n' "$reply_i"
          reply_i=$((reply_i + 1))
        done
      } > "$path"
    else
      printf 'Substantive response for update %s with <reply> & proof.\n' "$id" > "$path"
    fi
    chmod 600 "$path"
    run_owner "$home" reply "$id" >/dev/null 2>&1 \
      || fail "substantive Telegram response failed for update $id"
    run_owner "$home" outcome-create "$id" >/dev/null 2>&1 \
      || fail "Telegram outcome template failed for update $id"
    case "$id" in
      511294429) classification=question; outcome=answered; task_id=None ;;
      511294430) classification=work-request; outcome=work-routed; task_id=canary-work ;;
      511294431) classification=correction; outcome=correction-steered; task_id=canary-correction ;;
      *) classification=conversation; outcome=conversation-answered; task_id=None ;;
    esac
    python3 - "$home/data/telegram-outcomes/$id.json" "$id" \
      "$classification" "$outcome" "$task_id" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = {
    "schema_version": 1,
    "update_id": int(sys.argv[2]),
    "classification": sys.argv[3],
    "outcome": sys.argv[4],
    "project": "Firstmate",
    "task_id": sys.argv[5],
    "decision_key": "None",
    "proof": "The originating message has an exact bound substantive reply.",
    "next_step": "Continue normal handling.",
}
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
    chmod 600 "$home/data/telegram-outcomes/$id.json"
    run_owner "$home" outcome "$id" >/dev/null 2>&1 \
      || fail "content-appropriate Telegram outcome failed for update $id"
  done
  python3 - "$home" "$SERVER_REQUESTS_FILE" "$after" <<'PY' \
    || fail "substantive replies were not durably bound to every original Telegram message"
import html, json, pathlib, sys
home = pathlib.Path(sys.argv[1])
requests = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()[int(sys.argv[3]):]
]
sends = [item for item in requests if item["_telegram_method"] == "sendMessage"]
targets = [item["reply_parameters"]["message_id"] for item in sends]
assert 7001 in targets and 7002 in targets and 7003 in targets
assert targets.count(7003) >= 2
assert any("&lt;reply&gt; &amp; proof" in item["text"] for item in sends)
for item in sends:
    visible = html.unescape(item["text"].replace("<b>", "").replace("</b>", ""))
    assert len(visible.encode("utf-8")) <= 4096
for update_id, message_id in (
    (511294429, 7001),
    (511294430, 7002),
    (511294431, 7003),
    (511294432, 7003),
):
    receipt = json.loads(
        (home / "state" / "telegram-conversation-receipts" / f"{update_id}.json")
        .read_text(encoding="utf-8")
    )
    assert receipt["origin_update_id"] == update_id
    assert receipt["origin_message_id"] == message_id
    assert receipt["origin_chat_id"] == 424242
    assert receipt["origin_sender_user_id"] == 31337
    assert receipt["telegram_message_ids"]
PY

  printf 'telegram-mandatory\n' > "$home/config/founder-brief"
  chmod 600 "$home/config/founder-brief"
  seed_protocol_green "$home"
  rm "$home/state/telegram-conversation-canary.json"
  cat > "$home/data/telegram-conversation-canary.json" <<'EOF'
{"schema_version":1,"question_update_id":511294429,"work_request_update_id":511294430,"correction_update_id":511294431}
EOF
  chmod 600 "$home/data/telegram-conversation-canary.json"
  run_owner "$home" conversation-canary-verify >/dev/null 2>&1 \
    || fail "live question/work-request/correction evidence should enable automation"
  assert_present "$home/state/telegram-conversation-canary.json" \
    "conversation canary pass was not durable"

  cat > "$SERVER_UPDATES_FILE" <<EOF
[{"update_id":511294434,"message":{"message_id":7004,"date":2000000006,"chat":{"id":$CHAT_ID},"from":{"id":$USER_ID},"text":"Crash recovery request"}}]
EOF
  chmod 600 "$SERVER_UPDATES_FILE"
  send_before=$(python3 - "$SERVER_REQUESTS_FILE" <<'PY'
import json, pathlib, sys
print(sum(
    json.loads(line)["_telegram_method"] == "sendMessage"
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
))
PY
  )
  FM_HOME="$home" TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" FM_FOUNDER_BRIEF_NOW="$TEST_NOW" \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_RESPONSE=1 \
    "$OWNER" relay-once >/dev/null 2>&1
  rc=$?
  expect_code 86 "$rc" "conversation acknowledgment crash hook should stage before offset advance"
  [ "$(cat "$home/state/telegram-relay.offset")" -eq 511294434 ] \
    || fail "conversation relay advanced offset before durable acknowledgment recovery"
  run_owner "$home" relay-once >/dev/null 2>&1 \
    || fail "conversation relay did not recover its staged acknowledgment"
  send_after=$(python3 - "$SERVER_REQUESTS_FILE" <<'PY'
import json, pathlib, sys
print(sum(
    json.loads(line)["_telegram_method"] == "sendMessage"
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
))
PY
  )
  [ "$send_after" -eq $((send_before + 1)) ] \
    || fail "conversation acknowledgment crash recovery duplicated delivery"
  [ "$(cat "$home/state/telegram-relay.offset")" -eq 511294435 ] \
    || fail "conversation relay did not advance after acknowledgment recovery"
  for path in \
    "$home/state/telegram-inbox" \
    "$home/state/telegram-conversation-receipts" \
    "$home/data/telegram-replies"; do
    [ "$(file_mode "$path")" = 700 ] || fail "conversation directory must be mode 0700: $path"
  done
  while IFS= read -r path; do
    [ "$(file_mode "$path")" = 600 ] || fail "conversation record must be mode 0600: $path"
  done < <(
    find \
      "$home/state/telegram-inbox" \
      "$home/state/telegram-conversation-receipts" \
      "$home/data/telegram-replies" \
      -type f
  )
  [ "$(file_mode "$home/state/telegram-relay.offset")" = 600 ] \
    || fail "conversation relay offset must be mode 0600"
  [ -z "$(find "$home/state/telegram-inbox" "$home/state/telegram-conversation-receipts" \
    "$home/data/telegram-replies" -name '*.tmp' -print -quit)" ] \
    || fail "conversation atomic publication left a temporary file"
  pass "Telegram conversation: ordered authenticated ingest, prompt acknowledgments, edits, bound replies 511294429-432, and crash-safe dedupe"
}

test_decision_buttons_callbacks_and_canaries() {
  local home digest start request old_data old_message new_data new_message other_data other_message
  local beta_old_data beta_old_message beta_new_data beta_new_message numeric_path
  local update out rc approval_path before ordinary hash_before hash_after canary_data canary_message
  local callback_update callback_out callback_rc callback_before callback_after
  local sole_home sole_beta_message sole_path
  home=$(new_home decisions)
  digest=founder-decisions
  server_mode success
  write_decision_digest "$home" "$digest" v1
  perl -0pi -e 's/Two bounded project choices/api_key=DECISION_SECRET_MUST_NOT_LOG Two bounded project choices/' \
    "$home/data/founder-brief-decisions/$digest.json"
  out=$(run_owner "$home" decision-deliver "$digest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "credential-like decision content must be rejected"
  assert_not_contains "$out" "DECISION_SECRET_MUST_NOT_LOG" \
    "decision secret value leaked into diagnostics"
  write_decision_digest "$home" "$digest" v1
  start=$(request_count)
  out=$(run_owner "$home" decision-deliver "$digest" 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    || fail "project-grouped decision digest should deliver: $out"
  request=$(tail -1 "$SERVER_REQUESTS_FILE")
  python3 - "$request" "$home" <<'PY' \
    || fail "decision digest markup or opaque button plan is invalid"
import html, json, pathlib, re, sys
request = json.loads(sys.argv[1])
text = request["text"]
assert request["_telegram_method"] == "sendMessage"
assert request["parse_mode"] == "HTML"
assert "<b>DECISIONS · Captain action</b>" in text
assert text.index("Project · Alpha &lt;Launch&gt;") < text.index("Project · Beta &amp; Safety")
for number, label in ((1, "Staged"), (2, "Hold"), (3, "Repair"), (4, "Pause")):
    assert f"{number}. {label}" in text
keyboard = request["reply_markup"]["inline_keyboard"]
assert len(keyboard) == 2
assert [button["text"] for row in keyboard for button in row] == [
    "1 · Staged", "2 · Hold", "3 · Repair", "4 · Pause"
]
callbacks = [button["callback_data"] for row in keyboard for button in row]
assert len(callbacks) == 4 and len(set(callbacks)) == 4
assert all(value.startswith("fmb1:") and len(value.encode("utf-8")) <= 64 for value in callbacks)
assert all("alpha-task" not in value and "release-route" not in value for value in callbacks)
plans = list(pathlib.Path(sys.argv[2], "state", "founder-brief-decision-plans").glob("*.json"))
assert len(plans) == 1
plan = json.loads(plans[0].read_text(encoding="utf-8"))
assert plan["reply_markup"] == request["reply_markup"]
assert all(button["authority"] == "captain" for button in plan["buttons"])
PY
  run_owner "$home" decision-deliver "$digest" >/dev/null 2>&1 \
    || fail "acknowledged decision digest should dedupe"
  [ "$(request_count)" -eq $((start + 1)) ] || fail "decision digest retry sent a duplicate"
  [ -z "$(find "$home/state/founder-brief-approvals" -type f -print -quit)" ] \
    || fail "decision delivery alone created an approval"

  ordinary_before=$(request_count)
  ordinary_path=$(write_text_update "$home" decision-ordinary 9206 8206 "Please keep this conversation ordinary")
  run_owner "$home" route-update "$ordinary_path" >/dev/null 2>&1 \
    || fail "ordinary conversation should still acknowledge while decisions are open"
  ordinary_after=$(request_count)
  [ "$ordinary_after" -eq $((ordinary_before + 1)) ] \
    || fail "ordinary conversation did not receive a normal acknowledgment while decisions were open"
  reply_path=$(write_text_update "$home" decision-bare-ordinary 9207 8207 7 "$ordinary_after")
  run_owner "$home" route-update "$reply_path" >/dev/null 2>&1 \
    || fail "bare numeric reply to an ordinary message should stay conversational"
  assert_not_contains "$(cat "$home/state/telegram-inbox/9207.json")" '"handled_as"' \
    "bare numeric reply to an ordinary message was misrouted as decision automation"

  read -r old_data old_message < <(decision_binding "$home" alpha-task staged)
  read -r beta_old_data beta_old_message < <(decision_binding "$home" beta-task repair)
  update=$(write_callback_update "$home" wrong-user cb-wrong "$old_data" "$old_message" "$CHAT_ID" 99999)
  out=$(run_owner "$home" ingest-update "$update" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "wrong callback user identity must be rejected"
  assert_contains "$out" "identity is not authorized" "wrong-user callback rejection was not explicit"
  [ -z "$(find "$home/state/founder-brief-approvals" -type f -print -quit)" ] \
    || fail "wrong-user callback created an approval"
  update=$(write_callback_update "$home" wrong-chat cb-wrong-chat "$old_data" "$old_message" 515151 "$USER_ID")
  out=$(run_owner "$home" ingest-update "$update" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "wrong callback chat identity must be rejected"
  assert_contains "$out" "identity is not authorized" "wrong-chat callback rejection was not explicit"

  update=$(write_callback_update "$home" tampered cb-tampered \
    "fmb1:ABCDEFGHIJKLMNOPQRSTUV" "$old_message" "$CHAT_ID" "$USER_ID")
  out=$(run_owner "$home" ingest-update "$update" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unknown opaque callback must be rejected"
  assert_contains "$out" "binding does not exist" "tampered callback rejection was not explicit"

  write_decision_digest "$home" "$digest" v2
  run_owner "$home" decision-deliver "$digest" >/dev/null 2>&1 \
    || fail "changed decision content should deliver a new exact digest"
  read -r new_data new_message < <(decision_binding "$home" alpha-task staged)
  read -r beta_new_data beta_new_message < <(decision_binding "$home" beta-task repair)
  [ "$new_data" != "$old_data" ] || fail "changed decision content reused its old opaque callback"
  [ "$beta_new_data" != "$beta_old_data" ] \
    || fail "changed decision digest reused its old Beta opaque callback"
  update=$(write_callback_update "$home" stale cb-stale "$old_data" "$old_message" "$CHAT_ID" "$USER_ID")
  out=$(run_owner "$home" ingest-update "$update" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "superseded callback must be rejected"
  assert_contains "$out" "callback is stale" "stale callback rejection was not explicit"

  numeric_path=$(write_text_update "$home" numeric-stale 9200 8200 3 "$beta_old_message")
  run_owner "$home" route-update "$numeric_path" >/dev/null 2>&1 \
    || fail "stale numeric decision reply should remain a safely acknowledged conversation"
  [ -z "$(approval_path_for_task "$home" beta-task)" ] \
    || fail "stale numeric reply created an approval"
  assert_contains "$(cat "$home/state/telegram-inbox/9200.json")" '"handled_as":"numbered-stale"' \
    "stale numeric reply was not classified"

  numeric_path=$(write_text_update "$home" numeric-unbound 9201 8201 3)
  run_owner "$home" route-update "$numeric_path" >/dev/null 2>&1 \
    || fail "ambiguous unbound number should receive clarification"
  assert_contains "$(cat "$home/state/telegram-inbox/9201.json")" '"handled_as":"numbered-invalid"' \
    "ambiguous unbound number did not receive clarification"

  numeric_path=$(write_text_update "$home" numeric-ambiguous 9205 8205 "3 please" "$beta_new_message")
  run_owner "$home" route-update "$numeric_path" >/dev/null 2>&1 \
    || fail "prose containing an option number should remain ordinary conversation"
  assert_not_contains "$(cat "$home/state/telegram-inbox/9205.json")" '"handled_as"' \
    "ambiguous numeric prose was incorrectly treated as approval"

  numeric_path=$(write_text_update "$home" numeric-invalid 9202 8202 9 "$beta_new_message")
  run_owner "$home" route-update "$numeric_path" >/dev/null 2>&1 \
    || fail "invalid bound option number should be acknowledged without authority"
  assert_contains "$(cat "$home/state/telegram-inbox/9202.json")" '"handled_as":"numbered-invalid"' \
    "invalid option number was not classified"

  numeric_path=$(write_text_update "$home" numeric-valid 9203 8203 3 "$beta_new_message")
  FM_HOME="$home" TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" FM_FOUNDER_BRIEF_NOW="$TEST_NOW" \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_RESPONSE=1 \
    "$OWNER" route-update "$numeric_path" >/dev/null 2>&1
  rc=$?
  expect_code 86 "$rc" "numeric approval crash hook should stop after its reply is staged"
  approval_path=$(approval_path_for_task "$home" beta-task)
  assert_present "$approval_path" "valid numeric option did not create an approval receipt"
  assert_contains "$(cat "$approval_path")" '"ready_to_act":false' \
    "numeric approval became actionable before its conversation acknowledgment"
  run_owner "$home" route-update "$numeric_path" >/dev/null 2>&1 \
    || fail "numeric approval retry did not recover acknowledgment idempotently"
  python3 - "$approval_path" <<'PY' \
    || fail "numeric approval receipt was not exact, bound, and actionable"
import json, pathlib, sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["source"] == "numbered-reply"
assert receipt["task"] == "beta-task"
assert receipt["decision_key"] == "remediation-route"
assert receipt["option"]["number"] == 3
assert receipt["option"]["key"] == "repair"
assert receipt["telegram_message_binding"]["reply_to_message_id"] > 0
assert receipt["conversation_acknowledged"] is True
assert receipt["ready_to_act"] is True
PY
  numeric_path=$(write_text_update "$home" numeric-replay 9204 8204 3 "$beta_new_message")
  run_owner "$home" route-update "$numeric_path" >/dev/null 2>&1 \
    || fail "numeric replay should be acknowledged without a second action"
  assert_contains "$(cat "$home/state/telegram-inbox/9204.json")" '"handled_as":"numbered-replay"' \
    "numeric replay was not classified"
  [ "$(find "$home/state/founder-brief-approvals" -type f | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "numeric replay created a second approval"

  update=$(write_callback_update "$home" accepted cb-accepted "$new_data" "$new_message" "$CHAT_ID" "$USER_ID")
  FM_HOME="$home" TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" FM_FOUNDER_BRIEF_NOW="$TEST_NOW" \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_APPROVAL=1 \
    "$OWNER" ingest-update "$update" >/dev/null 2>&1
  rc=$?
  expect_code 87 "$rc" "callback crash hook should stop after the atomic approval receipt"
  approval_path=$(approval_path_for_task "$home" alpha-task)
  assert_present "$approval_path" "callback crash did not leave its durable one-use approval"
  python3 - "$approval_path" <<'PY' \
    || fail "pre-ack approval receipt incorrectly became actionable"
import json, pathlib, sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["callback_acknowledged"] is False
assert receipt["ready_to_act"] is False
PY
  run_owner "$home" ingest-update "$update" >/dev/null 2>&1 \
    || fail "callback retry should recover acknowledgment without a second approval"
  python3 - "$approval_path" <<'PY' \
    || fail "acknowledged callback did not become a bound actionable receipt"
import json, pathlib, sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["callback_acknowledged"] is True
assert receipt["ready_to_act"] is True
assert receipt["task"] == "alpha-task"
assert receipt["project"] == "Alpha <Launch>"
assert receipt["decision_key"] == "release-route"
assert receipt["option"]["key"] == "staged"
for key in ("decision_sha256", "digest_sha256", "chat_identity_sha256", "user_identity_sha256"):
    assert len(receipt[key]) == 64
PY
  before=$(request_count)
  run_owner "$home" ingest-update "$update" >/dev/null 2>&1 \
    || fail "exact callback retry should be idempotent"
  [ "$(request_count)" -eq "$before" ] || fail "exact callback retry resent its acknowledgment"
  [ "$(find "$home/state/founder-brief-approvals" -type f | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "exact callback retry created a second approval"

  read -r other_data other_message < <(decision_binding "$home" alpha-task hold)
  update=$(write_callback_update "$home" replay cb-replay "$other_data" "$other_message" "$CHAT_ID" "$USER_ID")
  out=$(run_owner "$home" ingest-update "$update" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "second option replay must be rejected"
  assert_contains "$out" "replay was rejected" "one-use replay rejection was not explicit"

  update=$(write_callback_update "$home" expired cb-expired "$new_data" "$new_message" "$CHAT_ID" "$USER_ID")
  out=$(FM_HOME="$home" TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" FM_FOUNDER_BRIEF_NOW=2000004000 \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    "$OWNER" ingest-update "$update" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "expired callback must be rejected"
  assert_contains "$out" "callback has expired" "expired callback rejection was not explicit"

  ordinary="$home/state/ordinary-message.json"
  printf '%s\n' '{"update_id":9100,"message":{"chat":{"id":424242},"text":"ordinary mention"}}' > "$ordinary"
  chmod 600 "$ordinary"
  hash_before=$(shasum -a 256 "$ordinary" | awk '{print $1}')
  out=$(run_owner "$home" ingest-update "$ordinary" 2>&1); rc=$?
  expect_code 3 "$rc" "ordinary text update should remain unclaimed"
  hash_after=$(shasum -a 256 "$ordinary" | awk '{print $1}')
  [ "$hash_before" = "$hash_after" ] || fail "ordinary text update was modified or consumed"

  run_owner "$home" canary-delivery >/dev/null 2>&1 \
    || fail "safe delivery canary should work through the fake transport"
  run_owner "$home" canary-buttons >/dev/null 2>&1 \
    || fail "safe button canary should work through the fake transport"
  read -r canary_data canary_message < <(
    python3 - "$home" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
button = next(
    json.loads(path.read_text(encoding="utf-8"))
    for path in (home / "state" / "founder-brief-buttons").glob("*.json")
    if json.loads(path.read_text(encoding="utf-8")).get("authority") == "none"
)
receipt = json.loads(
    (home / "state" / "founder-brief-receipts" / f"{button['delivery_dedupe_key']}.json")
    .read_text(encoding="utf-8")
)
print(button["callback_data"], receipt["telegram_message_ids"][-1])
PY
  )
  update=$(write_callback_update "$home" canary-click cb-canary "$canary_data" "$canary_message" "$CHAT_ID" "$USER_ID")
  run_owner "$home" ingest-update "$update" >/dev/null 2>&1 \
    || fail "non-authority button canary callback should acknowledge"
  [ "$(find "$home/state/founder-brief-canary-clicks" -type f | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "button canary did not publish its non-authority receipt"
  [ "$(find "$home/state/founder-brief-approvals" -type f | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "button canary created authority"
  lifecycle_canary="$home/state/telegram-lifecycle-canary.json"
  decision_canary="$home/state/telegram-decision-canary.json"
  assert_present "$lifecycle_canary" "lifecycle canary receipt was not published"
  assert_present "$decision_canary" "decision canary receipt was not published"
  rm "$lifecycle_canary" "$decision_canary"
  canary_before=$(request_count)
  run_owner "$home" canary-delivery >/dev/null 2>&1 \
    || fail "lifecycle canary receipt should be restorable without a resend"
  run_owner "$home" canary-buttons >/dev/null 2>&1 \
    || fail "decision canary receipt should be restorable without a resend"
  [ "$(request_count)" -eq "$canary_before" ] \
    || fail "canary receipt recovery resent a duplicate transport"
  assert_present "$lifecycle_canary" "lifecycle canary receipt was not restored"
  assert_present "$decision_canary" "decision canary receipt was not restored"

  lifecycle_delivery_receipt=$(
    python3 - "$lifecycle_canary" <<'PY'
import json, pathlib, sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(receipt["delivery_dedupe_key"])
PY
  )
  rm -f "$lifecycle_canary"
  mkdir "$lifecycle_canary"
  rm -f "$home/state/founder-brief-receipts/$lifecycle_delivery_receipt.json"
  rm -f "$home/state/founder-brief-outbox/$lifecycle_delivery_receipt.json"
  rm -f "$home/state/founder-brief-responses/$lifecycle_delivery_receipt".*.json
  canary_failure_before=$(request_count)
  out=$(run_owner "$home" canary-delivery 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "lifecycle canary receipt failure should fail safely"
  [ "$(request_count)" -eq $((canary_failure_before + 1)) ] \
    || fail "lifecycle canary receipt failure did not preserve the original send"
  assert_contains "$(cat "$home/state/telegram-protocol-incidents/lifecycle.json")" \
    '"status":"containment"' \
    "lifecycle canary receipt failure did not contain the lifecycle lane"
  rm -rf "$lifecycle_canary"

  server_mode rejected
  callback_before=$(request_count)
  callback_update=$(write_callback_update "$home" canary-failed cb-canary-failed "$canary_data" "$canary_message" "$CHAT_ID" "$USER_ID")
  callback_out=$(run_owner "$home" ingest-update "$callback_update" 2>&1); callback_rc=$?
  [ "$callback_rc" -ne 0 ] || fail "rejected callback should have failed safely"
  assert_contains "$callback_out" "Telegram did not acknowledge the callback" \
    "callback acknowledgment failure was not surfaced"
  assert_contains "$(cat "$home/state/telegram-protocol-incidents/decision.json")" \
    '"status":"containment"' \
    "callback acknowledgment failure did not contain only the decision lane"
  server_mode success
  ordinary_path=$(write_text_update "$home" callback-ordinary 9208 8208 "Conversation remains active")
  run_owner "$home" route-update "$ordinary_path" >/dev/null 2>&1 \
    || fail "decision containment should preserve ordinary conversation"
  cat > "$home/data/telegram-protocol-incidents/decision.md" <<'EOF'
# Telegram protocol incident

## Failed canary and consequence

The decision callback transport was rejected, so only the decision lane remained contained while ordinary conversation continued.

## Bounded diagnostics

The callback transport returned a rejected acknowledgment and no message content or credential was copied.

## Root cause

The fake transport was set to reject callback acknowledgments.

## Repair

The transport was restored to accept callback acknowledgments.

## Next concrete action

Rerun deterministic regression, revalidate the callback path, and restore the decision lane.
EOF
  chmod 600 "$home/data/telegram-protocol-incidents/decision.md"
  run_owner "$home" incident-transition decision diagnosis >/dev/null 2>&1 \
    || fail "decision incident did not transition to diagnosis"
  run_owner "$home" incident-transition decision repair >/dev/null 2>&1 \
    || fail "decision incident did not transition to repair"
  run_owner "$home" incident-transition decision revalidation >/dev/null 2>&1 \
    || fail "decision incident did not transition to revalidation"
  rm -f "$lifecycle_canary" "$decision_canary"
  future=$((TEST_NOW + 10))
  seed_protocol_green "$home" "$future"
  run_owner_at "$home" "$future" canary-delivery >/dev/null 2>&1 \
    || fail "refreshed lifecycle canary did not pass during decision repair"
  run_owner_at "$home" "$future" canary-buttons >/dev/null 2>&1 \
    || fail "refreshed decision canary did not pass during decision repair"
  run_owner "$home" incident-restore decision >/dev/null 2>&1 \
    || fail "decision incident did not restore after repair"
  read -r canary_data canary_message < <(
    python3 - "$home" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
receipt = json.loads((home / "state" / "telegram-decision-canary.json").read_text(encoding="utf-8"))
button = next(
    json.loads(path.read_text(encoding="utf-8"))
    for path in (home / "state" / "founder-brief-buttons").glob("*.json")
    if json.loads(path.read_text(encoding="utf-8")).get("authority") == "none"
    and json.loads(path.read_text(encoding="utf-8")).get("delivery_dedupe_key") == receipt["delivery_dedupe_key"]
)
delivery = json.loads(
    (home / "state" / "founder-brief-receipts" / f"{receipt['delivery_dedupe_key']}.json").read_text(encoding="utf-8")
)
print(button["callback_data"], delivery["telegram_message_ids"][-1])
PY
  )
  callback_update=$(write_callback_update "$home" canary-recovered cb-canary-recovered "$canary_data" "$canary_message" "$CHAT_ID" "$USER_ID")
  callback_after=$(request_count)
  run_owner "$home" ingest-update "$callback_update" >/dev/null 2>&1 \
    || fail "callback retry did not recover after the transport was restored"
  [ "$(request_count)" -eq $((callback_after + 1)) ] \
    || fail "callback retry duplicated the callback acknowledgment"

  sole_home=$(new_home numeric-sole)
  write_decision_digest "$sole_home" "$digest" v2
  run_owner "$sole_home" decision-deliver "$digest" >/dev/null 2>&1 \
    || fail "sole-open numeric fixture digest did not deliver"
  read -r _ sole_beta_message < <(decision_binding "$sole_home" beta-task repair)
  sole_path=$(write_text_update "$sole_home" sole-beta 9300 8300 3 "$sole_beta_message")
  run_owner "$sole_home" route-update "$sole_path" >/dev/null 2>&1 \
    || fail "bound numeric choice did not close one decision"
  sole_path=$(write_text_update "$sole_home" sole-alpha 9301 8301 1)
  run_owner "$sole_home" route-update "$sole_path" >/dev/null 2>&1 \
    || fail "bare number did not resolve the sole open decision"
  assert_contains "$(cat "$sole_home/state/telegram-inbox/9301.json")" \
    '"handled_as":"numbered-approval"' \
    "sole-open bare number was not content-hash-bound as an approval"
  [ "$(find "$sole_home/state/founder-brief-approvals" -type f | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "sole-open numeric routing did not create exactly one receipt per decision"
  pass "founder decisions: grouped opaque buttons, identity/hash/expiry binding, stale/replay rejection, crash recovery, and safe canaries"
}

test_pending_approval_visibility_and_reminders() {
  local home digest task now before after beta_message alpha_message update
  local changed_home changed_digest changed_message approval_count history_count
  local failure_home failure_digest failure_update failure_preupdate
  local conversation_before conversation_after failure_before failure_after
  home=$(new_home reminders)
  digest="pending-decisions"
  task=reminder-work
  now=$TEST_NOW
  server_mode success
  write_decision_digest "$home" "$digest" v1
  set_decision_expiry "$home" "$digest" $((TEST_NOW + 172800))
  run_owner "$home" decision-deliver "$digest" >/dev/null 2>&1 \
    || fail "pending-approval fixture decision digest did not deliver"

  write_during_brief "$home" "$task" "Reminder Project" "milestone" "The first material checkpoint is complete."
  run_owner_at "$home" $((now + 1000)) during "$task" implementation >/dev/null 2>&1 \
    || fail "first lifecycle update with pending approvals did not deliver"
  python3 - "$SERVER_REQUESTS_FILE" <<'PY' \
    || fail "DURING pending-approval section was not compact, grouped, and stable"
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()[-1])
text = request["text"]
assert "<b>Pending approvals</b>" in text
assert "<b>Project · Alpha &lt;Launch&gt;</b>" in text
assert "<b>Project · Beta &amp; Safety</b>" in text
assert "alpha-release-route v1" in text
assert "beta-remediation-route v1" in text
assert "Recommendation · Use the staged route" in text
assert "Options · 1 Staged · 2 Hold" in text
assert "Options · 3 Repair · 4 Pause" in text
PY

  write_during_brief "$home" "$task" "Reminder Project" "proof" "A second material proof checkpoint is complete."
  run_owner_at "$home" $((now + 2000)) during "$task" implementation >/dev/null 2>&1 \
    || fail "repeated material lifecycle update did not retain pending approvals"
  before=$(request_count)
  run_owner_at "$home" $((now + 2000 + 21599)) remind-decisions >/dev/null 2>&1 \
    || fail "not-due pending reminder should be a silent success"
  [ "$(request_count)" -eq "$before" ] \
    || fail "pending reminder ignored the latest lifecycle visibility time"

  FM_HOME="$home" TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" FM_FOUNDER_BRIEF_NOW=$((now + 2000 + 21600)) \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_RESPONSE=1 \
    "$OWNER" remind-decisions >/dev/null 2>&1
  rc=$?
  expect_code 86 "$rc" "pending reminder crash hook should stop after staging its acknowledgment"
  after=$(request_count)
  run_owner_at "$home" $((now + 2000 + 21600)) remind-decisions >/dev/null 2>&1 \
    || fail "pending reminder did not recover its staged acknowledgment after restart"
  [ "$(request_count)" -eq "$after" ] \
    || fail "pending reminder crash recovery resent the acknowledged bundle"
  run_owner_at "$home" $((now + 2000 + 21600)) remind-decisions >/dev/null 2>&1 \
    || fail "same-cycle pending reminder retry should dedupe"
  [ "$(request_count)" -eq "$after" ] \
    || fail "same-cycle pending reminder retry sent a duplicate bundle"
  python3 - "$SERVER_REQUESTS_FILE" <<'PY' \
    || fail "full pending reminder omitted grouped context, age, recommendation, or stable options"
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()[-1])
text = request["text"]
assert "<b>DECISIONS · Captain action</b>" in text
assert "<b>Project · Alpha &lt;Launch&gt;</b>" in text
assert "<b>Project · Beta &amp; Safety</b>" in text
assert "Age · 6h" in text
assert "Context · The pilot is ready" in text
assert "Recommendation · Choose Repair" in text
assert "1. Staged" in text and "2. Hold" in text
assert "3. Repair" in text and "4. Pause" in text
PY

  read -r _ beta_message < <(decision_binding "$home" beta-task repair)
  update=$(write_text_update "$home" reminder-beta 9700 8700 3 "$beta_message")
  run_owner_at "$home" $((now + 23601)) route-update "$update" >/dev/null 2>&1 \
    || fail "partial pending-decision resolution did not record the numbered choice"
  write_during_brief "$home" "$task" "Reminder Project" "risk" "The remaining Alpha choice is now the only open decision."
  run_owner_at "$home" $((now + 23602)) during "$task" implementation >/dev/null 2>&1 \
    || fail "lifecycle update after partial resolution did not deliver"
  python3 - "$SERVER_REQUESTS_FILE" <<'PY' \
    || fail "partial resolution did not remove only the answered pending decision"
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()[-1])
text = request["text"]
assert "alpha-release-route v1" in text
assert "beta-remediation-route" not in text
assert "Options · 1 Staged · 2 Hold" in text
PY
  before=$(request_count)
  run_owner_at "$home" $((now + 23602 + 21600)) remind-decisions >/dev/null 2>&1 \
    || fail "single remaining approval reminder did not deliver"
  [ "$(request_count)" -eq $((before + 1)) ] \
    || fail "single remaining approval reminder was not batched into one message"
  read -r _ alpha_message < <(decision_binding "$home" alpha-task staged)
  update=$(write_text_update "$home" reminder-alpha 9701 8701 1 "$alpha_message")
  run_owner_at "$home" $((now + 45203)) route-update "$update" >/dev/null 2>&1 \
    || fail "final pending-decision resolution did not record the numbered choice"
  before=$(request_count)
  run_owner_at "$home" $((now + 90000)) remind-decisions >/dev/null 2>&1 \
    || fail "all-resolved reminder cancellation should be a silent success"
  [ "$(request_count)" -eq "$before" ] \
    || fail "all-resolved decisions still produced a reminder"

  changed_home=$(new_home changed-decision)
  changed_digest="changed-decision"
  write_decision_digest "$changed_home" "$changed_digest" v1
  set_decision_expiry "$changed_home" "$changed_digest" $((TEST_NOW + 172800))
  run_owner "$changed_home" decision-deliver "$changed_digest" >/dev/null 2>&1 \
    || fail "changed-decision fixture v1 did not deliver"
  read -r _ changed_message < <(decision_binding "$changed_home" alpha-task staged)
  update=$(write_text_update "$changed_home" changed-v1 9750 8750 1 "$changed_message")
  run_owner "$changed_home" route-update "$update" >/dev/null 2>&1 \
    || fail "changed-decision fixture v1 did not record its choice"
  approval_count=$(find "$changed_home/state/founder-brief-approvals" -type f | wc -l | tr -d ' ')
  write_decision_digest "$changed_home" "$changed_digest" v2
  set_decision_expiry "$changed_home" "$changed_digest" $((TEST_NOW + 172800))
  run_owner_at "$changed_home" $((TEST_NOW + 10)) decision-deliver "$changed_digest" >/dev/null 2>&1 \
    || fail "materially changed decision v2 did not require and receive a new delivery"
  python3 - "$changed_home" <<'PY' \
    || fail "changed decision did not expire v1 while preserving stable ids and option numbers"
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
pointers = [
    json.loads(path.read_text(encoding="utf-8"))
    for path in (home / "state" / "founder-brief-decision-current").glob("*.json")
]
alpha = next(item for item in pointers if item["decision_id"] == "alpha-release-route")
assert alpha["version"] == 2
assert [(item["number"], item["key"]) for item in alpha["options"]] == [(1, "staged"), (2, "hold")]
history = list(
    (home / "state" / "founder-brief-decision-history" / alpha["decision_identity_sha256"]).glob("*.json")
)
assert len(history) == 1
old = json.loads(history[0].read_text(encoding="utf-8"))
assert old["version"] == 1 and old["status"] == "superseded"
PY
  history_count=$(find "$changed_home/state/founder-brief-decision-history" -type f | wc -l | tr -d ' ')
  [ "$history_count" -eq 1 ] || fail "changed decision version history was not durable and singular"
  [ "$(find "$changed_home/state/founder-brief-approvals" -type f | wc -l | tr -d ' ')" -eq "$approval_count" ] \
    || fail "delivering a changed decision created authority without a new captain choice"
  conversation_before=$(conversation_manifest "$changed_home")
  assert_not_contains "$conversation_before" '"count":0' \
    "scheduler isolation fixture lacks the intended pre-existing numbered-reply conversation"
  before=$(request_count)
  FM_HOME="$changed_home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$changed_home/state" \
    FM_CONFIG_OVERRIDE="$changed_home/config" \
    FM_DATA_OVERRIDE="$changed_home/data" \
    TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" \
    TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" \
    FM_FOUNDER_BRIEF_NOW=$((TEST_NOW + 21610)) \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    bash -c '
      # shellcheck source=bin/fm-watch.sh
      . "$1"
      founder_reminder_tick
    ' _ "$ROOT/bin/fm-watch.sh" \
    || fail "shared watcher scheduler did not run the due reminder owner"
  [ "$(request_count)" -eq $((before + 1)) ] \
    || fail "watcher scheduler did not send exactly one due reminder bundle"
  conversation_after=$(conversation_manifest "$changed_home")
  [ "$conversation_after" = "$conversation_before" ] \
    || fail "watcher reminder scheduler mutated or consumed pre-existing conversation state"

  failure_home=$(new_home reminder-failure)
  failure_digest=reminder-failure
  write_decision_digest "$failure_home" "$failure_digest" v1
  set_decision_expiry "$failure_home" "$failure_digest" $((TEST_NOW + 172800))
  run_owner "$failure_home" decision-deliver "$failure_digest" >/dev/null 2>&1 \
    || fail "reminder-failure fixture decision digest did not deliver"
  failure_preupdate=$(write_text_update "$failure_home" reminder-before-failure 9789 8789 "Preserve this conversation through reminder containment")
  run_owner "$failure_home" route-update "$failure_preupdate" >/dev/null 2>&1 \
    || fail "reminder-failure fixture could not establish pre-existing conversation"
  failure_before=$(conversation_manifest "$failure_home")
  server_mode wrong-chat
  FM_HOME="$failure_home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$failure_home/state" \
    FM_CONFIG_OVERRIDE="$failure_home/config" \
    FM_DATA_OVERRIDE="$failure_home/data" \
    TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" \
    TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" \
    FM_FOUNDER_BRIEF_NOW=$((TEST_NOW + 21600)) \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    bash -c '
      # shellcheck source=bin/fm-watch.sh
      . "$1"
      ! founder_reminder_tick
      [ -n "$FM_FOUNDER_REMINDER_FAILURE" ]
    ' _ "$ROOT/bin/fm-watch.sh" \
    || fail "failed reminder was not surfaced by the common watcher scheduler"
  failure_after=$(conversation_manifest "$failure_home")
  [ "$failure_after" = "$failure_before" ] \
    || fail "failed reminder containment mutated or consumed pre-existing conversation state"
  server_mode success
  assert_contains "$(cat "$failure_home/state/telegram-protocol-incidents/decision.json")" \
    '"status":"containment"' \
    "failed reminder did not contain only decision automation"
  failure_update=$(write_text_update "$failure_home" reminder-failure-chat 9790 8790 "Conversation must remain active")
  run_owner_at "$failure_home" $((TEST_NOW + 21601)) route-update "$failure_update" >/dev/null 2>&1 \
    || fail "decision-reminder containment disabled ordinary conversation"
  python3 - "$SERVER_REQUESTS_FILE" <<'PY' \
    || fail "ordinary conversation after reminder containment was not promptly acknowledged"
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()[-1])
assert request["_telegram_method"] == "sendMessage"
assert request["reply_parameters"]["message_id"] == 8790
assert request["reply_parameters"]["allow_sending_without_reply"] is False
PY
  [ "$(file_mode "$failure_home/state/.founder-brief-reminder-error")" = 600 ] \
    || fail "reminder failure marker must be mode 0600"
  pass "pending approvals: repeated lifecycle visibility, half-day cadence, crash dedupe, partial/all resolution, version invalidation, stable numbering, and watcher isolation"
}

test_lane_containment_incident_recovery() {
  local home task out rc update crash_home crash_update future digest relay_home
  home=$(new_home containment)
  task=contained-task
  digest=contained-decisions
  write_valid_brief "$home" "$task"
  server_mode wrong-chat
  out=$(run_owner "$home" canary-delivery 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "wrong-chat lifecycle canary must fail"
  server_mode success
  assert_contains "$(cat "$home/state/telegram-protocol-incidents/lifecycle.json")" \
    '"status":"containment"' \
    "failed lifecycle canary did not atomically contain its lane"
  out=$(run_owner "$home" phase "$task" assignment 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "contained lifecycle lane unexpectedly delivered PRE"
  assert_contains "$out" "ordinary Telegram conversation remains active" \
    "containment did not state its lane-isolation guarantee"

  update=$(write_text_update "$home" containment-chat 9400 8400 "Please keep conversation active")
  run_owner "$home" route-update "$update" >/dev/null 2>&1 \
    || fail "lifecycle containment disabled or delayed conversation ingest/ack"
  run_owner "$home" reply-create 9400 >/dev/null 2>&1
  printf 'Conversation remains active while lifecycle repair proceeds.\n' \
    > "$home/data/telegram-replies/9400.md"
  chmod 600 "$home/data/telegram-replies/9400.md"
  run_owner "$home" reply 9400 >/dev/null 2>&1 \
    || fail "lifecycle containment disabled substantive conversation reply"
  run_owner "$home" outcome-create 9400 >/dev/null 2>&1
  cat > "$home/data/telegram-outcomes/9400.json" <<'EOF'
{"classification":"conversation","decision_key":"None","next_step":"Continue incident repair.","outcome":"conversation-answered","project":"Firstmate","proof":"The exact originating message has an acknowledged substantive reply.","schema_version":1,"task_id":"None","update_id":9400}
EOF
  chmod 600 "$home/data/telegram-outcomes/9400.json"
  run_owner "$home" outcome 9400 >/dev/null 2>&1 \
    || fail "lifecycle containment prevented content-appropriate conversation handling"

  write_decision_digest "$home" "$digest" v1
  run_owner "$home" decision-deliver "$digest" >/dev/null 2>&1 \
    || fail "lifecycle incident incorrectly disabled the separate decision lane"

  cat > "$home/data/telegram-protocol-incidents/lifecycle.md" <<'EOF'
# Telegram protocol incident

## Failed canary and consequence

The lifecycle delivery canary returned a response for the wrong chat, so PRE, DURING, and POST stayed contained while conversation remained active.

## Bounded diagnostics

The private staged response showed a chat-identity mismatch and no message content or credential was copied.

## Root cause

The test transport intentionally returned the wrong destination identity.

## Repair

The transport was restored to the expected authenticated chat response.

## Next concrete action

Rerun deterministic regression and all three live canaries, then restore the lifecycle lane.
EOF
  chmod 600 "$home/data/telegram-protocol-incidents/lifecycle.md"
  run_owner "$home" incident-transition lifecycle diagnosis >/dev/null 2>&1 \
    || fail "incident containment-to-diagnosis transition failed"
  out=$(run_owner "$home" incident-transition lifecycle revalidation 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "incident state machine allowed diagnosis to skip repair"
  run_owner "$home" incident-transition lifecycle repair >/dev/null 2>&1 \
    || fail "incident diagnosis-to-repair transition failed"
  run_owner "$home" incident-transition lifecycle revalidation >/dev/null 2>&1 \
    || fail "incident repair-to-revalidation transition failed"
  out=$(run_owner "$home" incident-restore lifecycle 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "incident restore accepted stale pre-incident proofs"

  future=$((TEST_NOW + 10))
  seed_protocol_green "$home" "$future"
  run_owner_at "$home" "$future" canary-delivery >/dev/null 2>&1 \
    || fail "repaired lifecycle canary did not pass"
  run_owner_at "$home" "$future" canary-buttons >/dev/null 2>&1 \
    || fail "repaired decision canary did not pass"
  run_owner_at "$home" "$future" incident-restore lifecycle >/dev/null 2>&1 \
    || fail "fresh all-lane proof did not restore the repaired lifecycle lane"
  assert_contains "$(cat "$home/state/telegram-protocol-incidents/lifecycle.json")" \
    '"status":"resolved"' \
    "restored incident did not publish a durable resolved state"
  run_owner_at "$home" "$future" phase "$task" assignment >/dev/null 2>&1 \
    || fail "resolved lifecycle incident did not restore PRE delivery"

  run_owner_at "$home" "$future" incident-create decision decision-canary >/dev/null 2>&1
  out=$(run_owner_at "$home" "$future" decision-deliver "$digest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "decision incident did not contain decision automation"
  run_owner_at "$home" "$future" phase "$task" remediation >/dev/null 2>&1 \
    || fail "decision incident incorrectly disabled the separate lifecycle lane"
  update=$(write_text_update "$home" decision-contained-chat 9401 8401 "Conversation still works")
  ordinary_before=$(request_count)
  run_owner_at "$home" "$future" route-update "$update" >/dev/null 2>&1
  ordinary_after=$(request_count)
  [ "$ordinary_after" -eq $((ordinary_before + 1)) ] \
    || fail "decision containment disabled ordinary conversation"
  before=$(request_count)
  update=$(write_text_update "$home" decision-contained-number 9402 8402 1)
  run_owner_at "$home" "$future" route-update "$update" >/dev/null 2>&1 \
    || fail "contained decision number should remain an ordinary conversation"
  after=$(request_count)
  [ "$after" -eq $((before + 1)) ] \
    || fail "contained decision number did not receive a normal acknowledgment"
  assert_not_contains "$(cat "$home/state/telegram-inbox/9402.json")" '"handled_as"' \
    "decision containment misrouted a bare number as authority"
  [ -z "$(find "$home/state/founder-brief-approvals" -type f -print -quit)" ] \
    || fail "decision containment created an approval"
  update=$(write_text_update "$home" decision-unclaimed-text 9403 8403 "Ordinary text is not a callback")
  out=$(run_owner_at "$home" "$future" ingest-update "$update" 2>&1); rc=$?
  expect_code 3 "$rc" "direct callback ingestion should leave ordinary text unclaimed"
  assert_absent "$home/state/founder-brief-update-inbox/9403.json" \
    "contained callback ingestion consumed an ordinary conversation update"

  crash_home=$(new_home incident-crash)
  cat > "$crash_home/data/telegram-conversation-canary.json" <<'EOF'
{"schema_version":1,"question_update_id":9600,"work_request_update_id":9601,"correction_update_id":9602}
EOF
  chmod 600 "$crash_home/data/telegram-conversation-canary.json"
  FM_HOME="$crash_home" TELEGRAM_BOT_TOKEN="$FAKE_TOKEN" TELEGRAM_CHAT_ID="$CHAT_ID" \
    TELEGRAM_USER_ID="$USER_ID" FM_FOUNDER_BRIEF_NOW="$TEST_NOW" \
    FM_FOUNDER_BRIEF_ENDPOINT="$SERVER_ENDPOINT" \
    FM_FOUNDER_BRIEF_TEST_CRASH_AFTER_INCIDENT=1 \
    "$OWNER" conversation-canary-verify >/dev/null 2>&1
  rc=$?
  expect_code 88 "$rc" "incident crash hook should fire after atomic containment"
  assert_contains "$(cat "$crash_home/state/telegram-protocol-incidents/conversation.json")" \
    '"status":"containment"' \
    "conversation incident was not restart-safe"
  out=$(run_owner "$crash_home" conversation-canary-verify 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "failed conversation canary became a degraded success on retry"
  assert_contains "$(cat "$crash_home/state/telegram-protocol-incidents/conversation.json")" \
    '"next_action":"capture diagnostics, repair root cause, then revalidate every lane"' \
    "conversation incident retry did not retain the next repair action"
  crash_update=$(write_text_update "$crash_home" crash-conversation 9500 8500 "Retry this conversation")
  run_owner "$crash_home" route-update "$crash_update" >/dev/null 2>&1 \
    || fail "highest-priority conversation incident lost durable inbound/ack retry"

  relay_home=$(new_conversation_home relay-failure)
  server_mode malformed-updates
  out=$(run_owner "$relay_home" relay-once 2>&1); rc=$?
  server_mode success
  [ "$rc" -ne 0 ] || fail "malformed relay response unexpectedly succeeded"
  assert_contains "$(cat "$relay_home/state/telegram-protocol-incidents/conversation.json")" \
    '"status":"containment"' \
    "enabled relay failure did not durably open the highest-priority conversation incident"
  update=$(write_text_update "$relay_home" relay-recovery-chat 9700 8700 "Keep the conversation retryable")
  run_owner "$relay_home" route-update "$update" >/dev/null 2>&1 \
    || fail "conversation incident disabled durable inbound acknowledgment retry"

  [ "$(file_mode "$crash_home/state/telegram-protocol-incidents")" = 700 ] \
    || fail "incident state directory must be mode 0700"
  [ "$(file_mode "$crash_home/state/telegram-protocol-incidents/conversation.json")" = 600 ] \
    || fail "incident state record must be mode 0600"
  [ -z "$(find "$home/state/telegram-protocol-incidents" \
    "$crash_home/state/telegram-protocol-incidents" -name '*.tmp' -print -quit)" ] \
    || fail "incident atomic publication left a temporary file"
  pass "Telegram lane incidents: isolated containment, durable crash recovery, ordered repair/revalidation, and all-green restoration"
}

test_spawn_promotion_optout_and_grandfathering() {
  local home task out rc optout opttask
  home=$(new_home lifecycle)
  task=founder-life-f1
  write_valid_brief "$home" "$task"
  mkdir -p "$home/data/$task"
  printf 'worker brief\n' > "$home/data/$task/brief.md"
  out=$(FM_HOME="$home" TELEGRAM_CHAT_ID="$CHAT_ID" TELEGRAM_USER_ID="$USER_ID" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" "$task" projects/missing codex 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "spawn without assignment receipt must block"
  assert_contains "$out" "no acknowledged founder brief" "spawn did not enforce assignment receipt"
  server_mode success
  run_owner "$home" phase "$task" assignment >/dev/null 2>&1 \
    || fail "assignment delivery should acknowledge"
  out=$(FM_HOME="$home" TELEGRAM_CHAT_ID="$CHAT_ID" TELEGRAM_USER_ID="$USER_ID" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" "$task" projects/missing codex 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fixture spawn should stop at its intentionally missing project"
  assert_not_contains "$out" "no acknowledged founder brief" "acknowledged assignment still blocked spawn"

  printf 'window=fixture\nkind=scout\n' > "$home/state/$task.meta"
  out=$(FM_HOME="$home" TELEGRAM_CHAT_ID="$CHAT_ID" TELEGRAM_USER_ID="$USER_ID" "$PROMOTE" "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "promotion without implementation receipt must block"
  grep -qx 'kind=scout' "$home/state/$task.meta" || fail "blocked promotion mutated scout metadata"
  run_owner "$home" phase "$task" implementation >/dev/null 2>&1 \
    || fail "implementation delivery should acknowledge"
  out=$(FM_HOME="$home" TELEGRAM_CHAT_ID="$CHAT_ID" TELEGRAM_USER_ID="$USER_ID" "$PROMOTE" "$task" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "acknowledged promotion should proceed without a captain response: $out"
  grep -qx 'kind=ship' "$home/state/$task.meta" || fail "acknowledged promotion did not mutate kind=ship"
  assert_absent "$home/state/telegram-inbox" "promotion incorrectly waited for an inbound captain response"

  task=founder-recovery-f2
  printf 'window=fixture\nkind=ship\n' > "$home/state/$task.meta"
  mkdir -p "$home/data/$task"
  printf 'worker brief\n' > "$home/data/$task/brief.md"
  out=$(FM_HOME="$home" TELEGRAM_CHAT_ID="$CHAT_ID" TELEGRAM_USER_ID="$USER_ID" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" "$task" projects/missing codex 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "recovery fixture should stop at its intentionally missing project"
  assert_not_contains "$out" "founder brief" "existing task recovery was not grandfathered"

  optout=$(new_optout_home optout)
  opttask=founder-optout-f3
  mkdir -p "$optout/data/$opttask" "$optout/projects/missing"
  printf 'window=fixture\nkind=scout\n' > "$optout/state/$opttask.meta"
  FM_HOME="$optout" "$PROMOTE" "$opttask" >/dev/null 2>&1 \
    || fail "opt-out promotion compatibility regressed"
  grep -qx 'kind=ship' "$optout/state/$opttask.meta" || fail "opt-out promotion did not preserve prior behavior"
  out=$(FM_HOME="$optout" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" founder-optout-new-f4 projects/missing codex 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "opt-out fixture spawn should fail at the legacy missing brief gate"
  assert_contains "$out" "no brief at" "opt-out spawn did not retain legacy behavior"
  assert_not_contains "$out" "founder brief" "opt-out spawn unexpectedly enabled founder gating"
  pass "founder brief lifecycle: spawn/promotion gates, immediate continuation, grandfathering, and opt-out compatibility"
}

test_destination_postcondition_contract() {
  local agents brief_owner configuration
  agents=$(cat "$ROOT/AGENTS.md")
  brief_owner=$(cat "$ROOT/bin/fm-brief.sh")
  configuration=$(cat "$ROOT/docs/configuration.md")
  assert_contains "$agents" "destination-side postcondition evidence" \
    "always-loaded browser/email success contract is missing"
  assert_contains "$brief_owner" "destination-side postcondition evidence" \
    "generated worker template lacks browser/email postcondition proof"
  assert_contains "$brief_owner" "transient toast" \
    "generated worker template still permits transient UI success evidence"
  assert_contains "$brief_owner" "never replace" \
    "generated worker template does not preserve additive conversation"
  assert_contains "$agents" "Containment is never rollout success" \
    "always-loaded incident contract permits degraded success"
  assert_contains "$configuration" "telegram-conversation" \
    "configuration owner does not document conversation-only opt-in"
  assert_contains "$configuration" "highest-priority communication incident" \
    "configuration owner does not document conversation incident priority"
  assert_contains "$configuration" "founder-brief-reminder-seconds" \
    "configuration owner does not document pending-approval cadence"
  assert_contains "$agents" "Every subsequent DURING or POST" \
    "always-loaded contract does not make pending approvals durable and discoverable"
  pass "generated contracts: destination postconditions, additive conversation, and non-terminal containment"
}

test_create_and_validation_contract
test_ack_dedupe_hash_and_phase
test_canonical_rendering_and_splitting
test_crash_and_timeout_dedupe
test_response_validation_and_retry
test_secret_safety_limits_and_permissions
test_during_digest_and_post_lifecycle
test_two_way_conversation_relay_and_replies
test_decision_buttons_callbacks_and_canaries
test_pending_approval_visibility_and_reminders
test_lane_containment_incident_recovery
test_spawn_promotion_optout_and_grandfathering
test_destination_postcondition_contract

echo "# all fm-founder-brief tests passed"
