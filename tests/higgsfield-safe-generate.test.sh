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
UPLOADED_REQUEST_ALT="$TEST_TMP/uploaded-request-alt.json"
COST_RECEIPT="$TEST_TMP/cost-receipt.json"
COST_RECEIPT_COPY="$TEST_TMP/cost-receipt-copy.json"
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
import hashlib
import os
import sys
import time
from pathlib import Path

args = sys.argv[1:]
with open(os.environ["HF_FAKE_LOG"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(args) + "\\n")

if args[:2] == ["model", "get"]:
    if os.environ.get("HF_MODEL_TYPE_OVERRIDE"):
        model_type = os.environ["HF_MODEL_TYPE_OVERRIDE"]
    elif args[2] == "seed_audio":
        model_type = "audio"
    elif args[2].startswith(("grok_video", "kling", "seedance")):
        model_type = "video"
    else:
        model_type = "image"
    print(json.dumps({"job_type": args[2], "type": model_type}))
elif args[:2] == ["upload", "create"]:
    if os.environ.get("HF_MUTATE_SOURCE"):
        Path(os.environ["HF_MUTATE_SOURCE"]).write_text("mutated during upload\\n", encoding="utf-8")
    expected = os.environ.get("HF_EXPECT_UPLOAD_SHA256")
    if expected and hashlib.sha256(Path(args[2]).read_bytes()).hexdigest() != expected:
        print("upload snapshot did not match approved bytes", file=sys.stderr)
        raise SystemExit(4)
    time.sleep(float(os.environ.get("HF_UPLOAD_DELAY", "0")))
    print(json.dumps({"id": "11111111-1111-4111-8111-111111111111"}))
elif args[:2] == ["generate", "cost"]:
    response = {"adjustments": [], "credits": 2, "credits_exact": 3}
    if "--aspect_ratio=99:99" in args:
        response["adjustments"] = [{"field": "aspect_ratio", "from": "99:99", "to": "1:1"}]
    print(json.dumps(response))
elif args[:2] == ["generate", "create"]:
    time.sleep(float(os.environ.get("HF_CREATE_DELAY", "0")))
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
    "job_type": "seedance_2_0",
    "prompt": f"studio product image $(touch {sys.argv[3]}); --json",
    "parameters": {"aspect_ratio": "1:1", "generate_audio": True, "sound": "on"},
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
assert plan["parameters"] == {"aspect_ratio": "1:1", "generate_audio": "false"}
assert plan["uploads"] == [{
    "bytes": 17,
    "path": os.path.realpath(sys.argv[2]),
    "sha256": __import__("hashlib").sha256(b"fake image bytes\n").hexdigest(),
}]
assert plan["upload_approval_token"].startswith("upload:v1:")
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

python3 - "$TEST_TMP/at-file-request.json" "$TEST_TMP/media.json" <<'PY'
import json
import sys
from pathlib import Path

request = {
    "job_type": "video_explainer",
    "prompt": "attempt an indirect media parameter",
    "parameters": {"medias": f"@{sys.argv[2]}"},
    "media": [],
}
Path(sys.argv[1]).write_text(json.dumps(request), encoding="utf-8")
PY

if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" plan "$TEST_TMP/at-file-request.json" \
  > "$TEST_TMP/at-file.out" 2> "$TEST_TMP/at-file.err"; then
  fail "plan accepted @file parameter indirection"
fi
[ ! -e "$FAKE_LOG" ] || fail "rejected @file indirection contacted the Higgsfield CLI"
pass "generic parameters reject @file indirection"

python3 - "$TEST_TMP/kling-request.json" <<'PY'
import json
import sys
from pathlib import Path

request = {
    "job_type": "kling3_0",
    "prompt": "silent camera move",
    "parameters": {"generate_audio": True, "sound": "on"},
    "media": [],
}
Path(sys.argv[1]).write_text(json.dumps(request), encoding="utf-8")
PY

PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" plan "$TEST_TMP/kling-request.json" > "$TEST_TMP/kling-plan.json"
python3 - "$TEST_TMP/kling-plan.json" <<'PY' || fail "plan did not neutralize sound controls"
import json
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
assert plan["parameters"] == {"sound": "off"}
PY
[ ! -e "$FAKE_LOG" ] || fail "audio-control planning contacted the Higgsfield CLI"
pass "plan neutralizes forwarded audio controls"

python3 - "$TEST_TMP/unvetted-video-upload-request.json" "$REFERENCE" <<'PY'
import json
import sys
from pathlib import Path

request = {
    "job_type": "grok_video_v15",
    "prompt": "animate this image without sound",
    "parameters": {},
    "media": [{"flag": "start-image", "value": sys.argv[2]}],
}
Path(sys.argv[1]).write_text(json.dumps(request), encoding="utf-8")
PY

PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" plan "$TEST_TMP/unvetted-video-upload-request.json" \
  > "$TEST_TMP/unvetted-video-upload-plan.json"
UNVETTED_UPLOAD_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upload_approval_token"])' "$TEST_TMP/unvetted-video-upload-plan.json")
[ ! -e "$FAKE_LOG" ] || fail "unvetted video planning contacted the Higgsfield CLI"

if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" upload "$TEST_TMP/unvetted-video-upload-request.json" \
  --approval-token "$UNVETTED_UPLOAD_TOKEN" --output "$TEST_TMP/unvetted-video-uploaded-request.json" \
  > "$TEST_TMP/unvetted-video-upload.out" 2> "$TEST_TMP/unvetted-video-upload.err"; then
  fail "upload accepted an unvetted video model"
fi
[ ! -e "$TEST_TMP/unvetted-video-uploaded-request.json" ] || fail "rejected video upload wrote an uploaded request"

python3 - "$TEST_TMP/unvetted-video-cost-request.json" <<'PY'
import json
import sys
from pathlib import Path

request = {
    "job_type": "grok_video_v15",
    "prompt": "animate a silent landscape",
    "parameters": {},
    "media": [],
}
Path(sys.argv[1]).write_text(json.dumps(request), encoding="utf-8")
PY

if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" cost "$TEST_TMP/unvetted-video-cost-request.json" \
  --receipt "$TEST_TMP/unvetted-video-cost-receipt.json" \
  > "$TEST_TMP/unvetted-video-cost.out" 2> "$TEST_TMP/unvetted-video-cost.err"; then
  fail "cost accepted an unvetted video model"
fi
[ ! -e "$TEST_TMP/unvetted-video-cost-receipt.json" ] || fail "rejected video model created a cost receipt"
python3 - "$FAKE_LOG" <<'PY' || fail "unvetted video model reached upload or generation"
import json
import sys

commands = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(commands) == 2
assert all(command[:3] == ["model", "get", "grok_video_v15"] for command in commands)
PY
pass "unvetted video models are rejected before upload or generation"
rm -f "$FAKE_LOG"

if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" upload "$REQUEST" --approval-token upload:wrong --output "$UPLOADED_REQUEST" \
  > "$TEST_TMP/bad-upload.out" 2> "$TEST_TMP/bad-upload.err"; then
  fail "upload accepted a mismatched approval token"
fi
[ ! -e "$FAKE_LOG" ] || fail "rejected upload contacted the Higgsfield CLI"
pass "upload fails closed without exact approval"

STALE_UPLOAD_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upload_approval_token"])' "$TEST_TMP/plan.json")
printf 'changed after approval\n' > "$REFERENCE"
if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" upload "$REQUEST" --approval-token "$STALE_UPLOAD_TOKEN" \
  --output "$TEST_TMP/stale-uploaded-request.json" \
  > "$TEST_TMP/stale-upload.out" 2> "$TEST_TMP/stale-upload.err"; then
  fail "upload accepted media changed after approval"
fi
python3 - "$FAKE_LOG" <<'PY' || fail "changed media reached the upload interface"
import json
import sys

commands = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert not any(command[:2] == ["upload", "create"] for command in commands)
PY

printf 'fake image bytes\n' > "$REFERENCE"
STALE_REPLAY_CALLS_BEFORE=$(wc -l < "$FAKE_LOG")
if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" upload "$REQUEST" --approval-token "$STALE_UPLOAD_TOKEN" \
  --output "$TEST_TMP/stale-replay-request.json" \
  > "$TEST_TMP/stale-replay.out" 2> "$TEST_TMP/stale-replay.err"; then
  fail "upload reused a consumed approval after media restoration"
fi
STALE_REPLAY_CALLS_AFTER=$(wc -l < "$FAKE_LOG")
[ "$STALE_REPLAY_CALLS_BEFORE" -eq "$STALE_REPLAY_CALLS_AFTER" ] || fail "consumed upload approval contacted the Higgsfield CLI"
pass "upload approval is content-bound and consumed before upload"

PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" plan "$REQUEST" > "$TEST_TMP/approved-plan.json"
UPLOAD_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upload_approval_token"])' "$TEST_TMP/approved-plan.json")
[ "$UPLOAD_TOKEN" != "$STALE_UPLOAD_TOKEN" ] || fail "new plan reused an old upload approval token"
EXPECTED_UPLOAD_SHA256=$(python3 -c 'import hashlib; print(hashlib.sha256(b"fake image bytes\n").hexdigest())')

set +e
PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" HF_UPLOAD_DELAY=0.2 \
  HF_MUTATE_SOURCE="$REFERENCE" HF_EXPECT_UPLOAD_SHA256="$EXPECTED_UPLOAD_SHA256" \
  python3 "$WRAPPER" upload "$REQUEST" --approval-token "$UPLOAD_TOKEN" --output "$UPLOADED_REQUEST" \
  > "$TEST_TMP/upload-one.out" 2> "$TEST_TMP/upload-one.err" &
UPLOAD_PID_ONE=$!
PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" HF_UPLOAD_DELAY=0.2 \
  HF_MUTATE_SOURCE="$REFERENCE" HF_EXPECT_UPLOAD_SHA256="$EXPECTED_UPLOAD_SHA256" \
  python3 "$WRAPPER" upload "$REQUEST" --approval-token "$UPLOAD_TOKEN" --output "$UPLOADED_REQUEST_ALT" \
  > "$TEST_TMP/upload-two.out" 2> "$TEST_TMP/upload-two.err" &
UPLOAD_PID_TWO=$!
wait "$UPLOAD_PID_ONE"
UPLOAD_STATUS_ONE=$?
wait "$UPLOAD_PID_TWO"
UPLOAD_STATUS_TWO=$?
set -e

if [ "$UPLOAD_STATUS_ONE" -eq 0 ] && [ "$UPLOAD_STATUS_TWO" -ne 0 ]; then
  UPLOADED_REQUEST_RESULT="$UPLOADED_REQUEST"
elif [ "$UPLOAD_STATUS_TWO" -eq 0 ] && [ "$UPLOAD_STATUS_ONE" -ne 0 ]; then
  UPLOADED_REQUEST_RESULT="$UPLOADED_REQUEST_ALT"
else
  fail "upload approval did not authorize exactly one concurrent upload"
fi
UPLOADED_REQUEST="$UPLOADED_REQUEST_RESULT"

python3 - "$FAKE_LOG" "$REFERENCE" <<'PY' || fail "approved upload did not use one private snapshot"
import json
import os
import sys

commands = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
uploads = [command for command in commands if command[:2] == ["upload", "create"]]
assert len(uploads) == 1
assert uploads[0][2] != os.path.realpath(sys.argv[2])
PY

python3 - "$UPLOADED_REQUEST" <<'PY' || fail "approved upload did not replace the local path"
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
assert request["media"] == [{"flag": "image", "value": "11111111-1111-4111-8111-111111111111"}]
assert request["parameters"] == {"aspect_ratio": "1:1", "generate_audio": "false"}
PY
pass "approved local media uploads once from a private snapshot"

UPLOAD_CALLS_BEFORE=$(wc -l < "$FAKE_LOG")
if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" upload "$REQUEST" --approval-token "$UPLOAD_TOKEN" \
  --output "$TEST_TMP/replayed-uploaded-request.json" \
  > "$TEST_TMP/upload-replay.out" 2> "$TEST_TMP/upload-replay.err"; then
  fail "upload replayed a consumed approval with a different output path"
fi
UPLOAD_CALLS_AFTER=$(wc -l < "$FAKE_LOG")
[ "$UPLOAD_CALLS_BEFORE" -eq "$UPLOAD_CALLS_AFTER" ] || fail "upload replay contacted the Higgsfield CLI"
pass "upload approval cannot be replayed"

python3 - "$TEST_TMP/audio-upload-request.json" "$REFERENCE" <<'PY'
import json
import sys
from pathlib import Path

request = {
    "job_type": "seed_audio",
    "prompt": "narrate this image",
    "parameters": {},
    "media": [{"flag": "image", "value": sys.argv[2]}],
}
Path(sys.argv[1]).write_text(json.dumps(request), encoding="utf-8")
PY

PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" plan "$TEST_TMP/audio-upload-request.json" \
  > "$TEST_TMP/audio-upload-plan.json"
AUDIO_UPLOAD_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upload_approval_token"])' "$TEST_TMP/audio-upload-plan.json")
AUDIO_UPLOADS_BEFORE=$(python3 - "$FAKE_LOG" <<'PY'
import json
import sys

commands = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
print(sum(command[:2] == ["upload", "create"] for command in commands))
PY
)
if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" upload "$TEST_TMP/audio-upload-request.json" \
  --approval-token "$AUDIO_UPLOAD_TOKEN" --output "$TEST_TMP/audio-uploaded-request.json" \
  > "$TEST_TMP/audio-upload.out" 2> "$TEST_TMP/audio-upload.err"; then
  fail "upload accepted local media for an audio model"
fi
AUDIO_UPLOADS_AFTER=$(python3 - "$FAKE_LOG" <<'PY'
import json
import sys

commands = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
print(sum(command[:2] == ["upload", "create"] for command in commands))
PY
)
[ "$AUDIO_UPLOADS_BEFORE" -eq "$AUDIO_UPLOADS_AFTER" ] || fail "audio model received local media"
[ ! -e "$TEST_TMP/audio-uploaded-request.json" ] || fail "rejected audio upload wrote an uploaded request"

PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" HF_MODEL_TYPE_OVERRIDE=image \
  python3 "$WRAPPER" upload "$TEST_TMP/audio-upload-request.json" \
  --approval-token "$AUDIO_UPLOAD_TOKEN" --output "$TEST_TMP/audio-uploaded-request.json" \
  > "$TEST_TMP/audio-upload-retry.json"
[ -e "$TEST_TMP/audio-uploaded-request.json" ] || fail "model rejection consumed the upload approval"
pass "model type is validated before upload approval consumption"

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

python3 - "$TEST_TMP/adjusted-cost-request.json" <<'PY'
import json
import sys
from pathlib import Path

request = {
    "job_type": "nano_banana_2",
    "prompt": "square product portrait",
    "parameters": {"aspect_ratio": "99:99"},
    "media": [],
}
Path(sys.argv[1]).write_text(json.dumps(request), encoding="utf-8")
PY

if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" cost "$TEST_TMP/adjusted-cost-request.json" \
  --receipt "$TEST_TMP/adjusted-cost-receipt.json" \
  > "$TEST_TMP/adjusted-cost.out" 2> "$TEST_TMP/adjusted-cost.err"; then
  fail "cost accepted vendor-adjusted parameters"
fi
[ ! -e "$TEST_TMP/adjusted-cost-receipt.json" ] || fail "adjusted cost issued an approval receipt"
python3 - "$FAKE_LOG" <<'PY' || fail "adjusted cost reached generation"
import json
import sys

commands = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
adjusted = [command for command in commands if command[:3] == ["generate", "cost", "nano_banana_2"]]
assert len(adjusted) == 1
assert "--aspect_ratio=99:99" in adjusted[0]
assert not any(command[:3] == ["generate", "create", "nano_banana_2"] for command in commands)
PY
pass "vendor-adjusted parameters cannot issue a cost approval"

PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" cost "$UPLOADED_REQUEST" --receipt "$COST_RECEIPT" > "$TEST_TMP/cost.json"

python3 - "$TEST_TMP/cost.json" "$COST_RECEIPT" <<'PY' || fail "cost did not issue the expected receipt"
import json
import sys

cost = json.load(open(sys.argv[1], encoding="utf-8"))
receipt = json.load(open(sys.argv[2], encoding="utf-8"))
assert cost["credits"] == 2
assert cost["job_count"] == 1
assert cost["parameters"] == {"aspect_ratio": "1:1", "generate_audio": "false"}
assert cost["approval_scope"] == {
    "binds": ["request", "vendor_credits_field"],
    "does_not_bind": ["account", "billing_workspace", "vendor_credits_exact_field"],
    "credits_exact_warning": "The wrapper binds and rechecks the vendor credits field, not credits_exact; a distinct credits_exact value can differ from the approved displayed credits value.",
    "workspace_switch_warning": "Switching the active billing workspace between approval and run can charge a different workspace at the same displayed credits value.",
}
assert set(receipt) == {"cost_approval_capability"}
assert receipt["cost_approval_capability"].startswith("cost:v1:")
PY
pass "cost discloses vendor credit-field and workspace limitations"

cp "$COST_RECEIPT" "$COST_RECEIPT_COPY"

set +e
PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" HF_CREATE_DELAY=0.2 \
  python3 "$WRAPPER" run "$UPLOADED_REQUEST" --cost-receipt "$COST_RECEIPT_COPY" \
  > "$TEST_TMP/run-one.json" 2> "$TEST_TMP/run-one.err" &
RUN_PID_ONE=$!
PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" HF_CREATE_DELAY=0.2 \
  python3 "$WRAPPER" run "$UPLOADED_REQUEST" --cost-receipt "$COST_RECEIPT" \
  > "$TEST_TMP/run-two.json" 2> "$TEST_TMP/run-two.err" &
RUN_PID_TWO=$!
wait "$RUN_PID_ONE"
RUN_STATUS_ONE=$?
wait "$RUN_PID_TWO"
RUN_STATUS_TWO=$?
set -e

if [ "$RUN_STATUS_ONE" -eq 0 ] && [ "$RUN_STATUS_TWO" -ne 0 ]; then
  RUN_RESULT="$TEST_TMP/run-one.json"
elif [ "$RUN_STATUS_TWO" -eq 0 ] && [ "$RUN_STATUS_ONE" -ne 0 ]; then
  RUN_RESULT="$TEST_TMP/run-two.json"
else
  fail "cost receipt did not authorize exactly one concurrent run"
fi

python3 - "$FAKE_LOG" "$SENTINEL" "$COST_RECEIPT" "$COST_RECEIPT_COPY" "$RUN_RESULT" <<'PY' || fail "run did not preserve safety boundaries"
import json
import os
import sys

commands = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
create = [command for command in commands if command[:2] == ["generate", "create"]]
assert len(create) == 1
seedance_generation = [
    command for command in commands
    if command[:3] in (["generate", "cost", "seedance_2_0"], ["generate", "create", "seedance_2_0"])
]
assert len(seedance_generation) == 3
for command in seedance_generation:
    assert "--generate_audio=false" in command
    assert "--generate_audio=true" not in command
    assert not any(argument.startswith("--sound=") for argument in command)
prompt_args = [argument for argument in create[0] if argument.startswith("--prompt=")]
assert len(prompt_args) == 1
assert "$(touch " in prompt_args[0]
assert not os.path.exists(sys.argv[2])
receipt = json.load(open(sys.argv[3], encoding="utf-8"))
receipt_copy = json.load(open(sys.argv[4], encoding="utf-8"))
assert receipt == receipt_copy
assert set(receipt) == {"cost_approval_capability"}
result = json.load(open(sys.argv[5], encoding="utf-8"))
assert result["credits"] == 2
assert result["result"]["status"] == "completed"
PY
pass "copied capabilities share one locked paid-run approval"

CALLS_BEFORE=$(wc -l < "$FAKE_LOG")
if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" run "$UPLOADED_REQUEST" --cost-receipt "$COST_RECEIPT" \
  > "$TEST_TMP/reuse.out" 2> "$TEST_TMP/reuse.err"; then
  fail "run reused a consumed cost receipt"
fi
if PATH="$FAKE_BIN:$PATH" HF_FAKE_LOG="$FAKE_LOG" \
  python3 "$WRAPPER" run "$UPLOADED_REQUEST" --cost-receipt "$COST_RECEIPT_COPY" \
  > "$TEST_TMP/reuse-copy.out" 2> "$TEST_TMP/reuse-copy.err"; then
  fail "run reused a copied cost capability"
fi
CALLS_AFTER=$(wc -l < "$FAKE_LOG")
[ "$CALLS_BEFORE" -eq "$CALLS_AFTER" ] || fail "receipt reuse contacted the Higgsfield CLI"
pass "a cost capability and its copies cannot authorize a retry"

printf 'all higgsfield safe-generation tests passed\n'
