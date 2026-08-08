#!/usr/bin/env bash
# Exercise the hardened Higgsfield wrapper through its command-line interface.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRAPPER="$ROOT/.agents/skills/higgsfield-generate/scripts/safe_generate.py"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/higgsfield-safe-generate.XXXXXX")
FAKE_BIN="$TEST_TMP/bin"
FAKE_LOG="$TEST_TMP/higgsfield.log"
REQUEST="$TEST_TMP/request.json"
UPLOADED_REQUEST="$TEST_TMP/uploaded-request.json"
COST_RECEIPT="$TEST_TMP/cost-receipt.json"
SENTINEL="$TEST_TMP/shell-injection-ran"
REFERENCE="$TEST_TMP/reference.png"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

mkdir -p "$FAKE_BIN"
printf 'fake image bytes\n' > "$REFERENCE"

python3 - "$FAKE_BIN/higgsfield" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    """#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["HF_FAKE_LOG"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(args) + "\\n")

if args[:2] == ["model", "get"]:
    model_type = "audio" if args[2] == "seed_audio" else "image"
    print(json.dumps({"job_type": args[2], "type": model_type}))
elif args[:2] == ["upload", "create"]:
    print(json.dumps({"id": "11111111-1111-4111-8111-111111111111"}))
elif args[:2] == ["generate", "cost"]:
    print(json.dumps({"credits": 2}))
elif args[:2] == ["generate", "create"]:
    print(json.dumps({"id": "22222222-2222-4222-8222-222222222222", "status": "completed", "url": "https://example.invalid/result.png"}))
else:
    print("unexpected fake command", file=sys.stderr)
    raise SystemExit(3)
""",
    encoding="utf-8",
)
PY
chmod +x "$FAKE_BIN/higgsfield"

python3 - "$REQUEST" "$REFERENCE" "$SENTINEL" <<'PY'
import json
import sys
from pathlib import Path

request = {
    "job_type": "nano_banana_2",
    "prompt": f"studio product image $(touch {sys.argv[3]}); --json",
    "parameters": {"aspect_ratio": "1:1"},
    "media": [{"flag": "image", "value": sys.argv[2]}],
}
Path(sys.argv[1]).write_text(json.dumps(request), encoding="utf-8")
PY

PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" plan "$REQUEST" > "$TEST_TMP/plan.json"

python3 - "$TEST_TMP/plan.json" "$REFERENCE" <<'PY' || fail "plan did not disclose the exact upload"
import json
import os
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
assert plan["job_count"] == 1
assert plan["uploads"] == [{"bytes": 17, "path": os.path.realpath(sys.argv[2])}]
assert plan["upload_approval_token"].startswith("upload:")
PY
[ ! -e "$FAKE_LOG" ] || fail "plan contacted the Higgsfield CLI"
[ ! -e "$SENTINEL" ] || fail "plan executed prompt text"
pass "plan validates locally and discloses uploads"

python3 - "$TEST_TMP/bypass-request.json" "$REFERENCE" <<'PY'
import json
import sys
from pathlib import Path

request = {
    "job_type": "nano_banana_2",
    "prompt": "attempt a hidden media parameter",
    "parameters": {"image_references": sys.argv[2]},
    "media": [],
}
Path(sys.argv[1]).write_text(json.dumps(request), encoding="utf-8")
PY

if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" plan "$TEST_TMP/bypass-request.json" \
  > "$TEST_TMP/bypass.out" 2> "$TEST_TMP/bypass.err"; then
  fail "plan accepted media hidden in a generic parameter"
fi
[ ! -e "$FAKE_LOG" ] || fail "rejected media bypass contacted the Higgsfield CLI"
pass "generic parameters cannot bypass the media approval path"

if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" upload "$REQUEST" --approval-token upload:wrong --output "$UPLOADED_REQUEST" \
  > "$TEST_TMP/bad-upload.out" 2> "$TEST_TMP/bad-upload.err"; then
  fail "upload accepted a mismatched approval token"
fi
[ ! -e "$FAKE_LOG" ] || fail "rejected upload contacted the Higgsfield CLI"
pass "upload fails closed without exact approval"

UPLOAD_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upload_approval_token"])' "$TEST_TMP/plan.json")
PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" upload "$REQUEST" --approval-token "$UPLOAD_TOKEN" --output "$UPLOADED_REQUEST" \
  > "$TEST_TMP/upload.json"

python3 - "$UPLOADED_REQUEST" <<'PY' || fail "approved upload did not replace the local path"
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
assert request["media"] == [{"flag": "image", "value": "11111111-1111-4111-8111-111111111111"}]
PY
pass "approved local media is uploaded once and replaced by UUID"

if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" cost "$REQUEST" --receipt "$COST_RECEIPT" \
  > "$TEST_TMP/bad-cost.out" 2> "$TEST_TMP/bad-cost.err"; then
  fail "cost accepted a local path that would auto-upload"
fi
pass "cost refuses unapproved automatic uploads"

python3 - "$TEST_TMP/audio-request.json" <<'PY'
import json
import sys
from pathlib import Path

request = {
    "job_type": "seed_audio",
    "prompt": "ocean ambience",
    "parameters": {},
    "media": [],
}
Path(sys.argv[1]).write_text(json.dumps(request), encoding="utf-8")
PY

if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" cost "$TEST_TMP/audio-request.json" --receipt "$TEST_TMP/audio-receipt.json" \
  > "$TEST_TMP/audio.out" 2> "$TEST_TMP/audio.err"; then
  fail "cost accepted an audio-generation model"
fi
[ ! -e "$TEST_TMP/audio-receipt.json" ] || fail "rejected audio model created a cost receipt"
pass "model inspection rejects non-image and non-video generation"

PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" cost "$UPLOADED_REQUEST" --receipt "$COST_RECEIPT" > "$TEST_TMP/cost.json"

python3 - "$TEST_TMP/cost.json" "$COST_RECEIPT" <<'PY' || fail "cost did not issue the expected receipt"
import json
import sys

cost = json.load(open(sys.argv[1], encoding="utf-8"))
receipt = json.load(open(sys.argv[2], encoding="utf-8"))
assert cost["credits"] == 2
assert cost["job_count"] == 1
assert receipt["credits_text"] == "2"
assert receipt["status"] == "pending"
PY
pass "cost discloses credits and writes a pending receipt"

PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" run "$UPLOADED_REQUEST" --cost-receipt "$COST_RECEIPT" > "$TEST_TMP/run.json"

python3 - "$FAKE_LOG" "$SENTINEL" "$COST_RECEIPT" "$TEST_TMP/run.json" <<'PY' || fail "run did not preserve safety boundaries"
import json
import os
import sys

commands = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
create = [command for command in commands if command[:2] == ["generate", "create"]]
assert len(create) == 1
prompt_args = [argument for argument in create[0] if argument.startswith("--prompt=")]
assert len(prompt_args) == 1
assert "$(touch " in prompt_args[0]
assert not os.path.exists(sys.argv[2])
receipt = json.load(open(sys.argv[3], encoding="utf-8"))
assert receipt["status"] == "consumed"
result = json.load(open(sys.argv[4], encoding="utf-8"))
assert result["credits"] == 2
assert result["result"]["status"] == "completed"
PY
pass "prompt remains one argv value and paid run consumes its receipt"

CALLS_BEFORE=$(wc -l < "$FAKE_LOG")
if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" run "$UPLOADED_REQUEST" --cost-receipt "$COST_RECEIPT" \
  > "$TEST_TMP/reuse.out" 2> "$TEST_TMP/reuse.err"; then
  fail "run reused a consumed cost receipt"
fi
CALLS_AFTER=$(wc -l < "$FAKE_LOG")
[ "$CALLS_BEFORE" -eq "$CALLS_AFTER" ] || fail "receipt reuse contacted the Higgsfield CLI"
pass "a cost receipt cannot authorize a retry"

printf 'all higgsfield safe-generation tests passed\n'
