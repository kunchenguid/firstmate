#!/usr/bin/env bash
# Focused concurrency and descriptor-safety tests for the Discord workspace core:
# serialized receipt/artifact/task-link writes and descriptor-bound file reads.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-concurrency-tests)
HOME1="$TMP_ROOT/home"
mkdir -p "$HOME1/state" "$HOME1/data" "$HOME1/config"
FM_HOME="$HOME1"
export FM_HOME
LIB="$ROOT/bin/fm_discord_workspace_lib.py"

worker() { # worker <mode> <key> <payload-json>
  python3 - "$LIB" "$1" "$2" "$3" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("fwl", sys.argv[1])
fwl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fwl)
mode, key, payload = sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
env = fwl.Env(sys.argv[1])
try:
    if mode == "receipt":
        print(fwl.record_receipt(env, key, payload, "mid-" + key))
    elif mode == "artifact":
        print(fwl.write_artifact_record(env, key, payload))
    elif mode == "tasklink":
        print(fwl.write_same_or_refuse(fwl.task_link_path(env, key), payload, "task link"))
except fwl.FMError as exc:
    print("FMError:", exc)
PY
}

run_parallel() { # run_parallel <mode> <key> <payload-json> [<count>]
  local mode=$1 key=$2 payload=$3 count=${4:-8} out_file
  out_file=$(mktemp)
  for _ in $(seq 1 "$count"); do
    worker "$mode" "$key" "$payload" >> "$out_file" 2>&1 &
  done
  wait
  sort "$out_file"
  rm -f "$out_file"
}

# --- concurrent identical receipt writes: exactly one durable record ----
receipt_payload='{"kind":"reply","profile":"proapplis","text_digest":"deadbeef"}'
results=$(run_parallel receipt n1 "$receipt_payload")
[ "$(printf '%s\n' "$results" | grep -c 'receipt recorded')" -eq 1 ] \
  || fail "expected exactly one receipt recorded, got: $results"
[ "$(printf '%s\n' "$results" | grep -c 'receipt exists')" -eq 7 ] \
  || fail "expected seven idempotent receipt exists results, got: $results"
[ -f "$HOME1/state/discord-workspace/receipts/$(python3 -c "import hashlib,sys;print(hashlib.sha256(b'n1').hexdigest())").json" ] \
  || fail "receipt file missing after concurrent writes"
pass "concurrent identical receipt writes serialize to one durable receipt"

# --- conflicting receipt for the same nonce is refused ------------------
results=$(run_parallel receipt n1 '{"kind":"reply","profile":"proapplis","text_digest":"cafebabe"}' 4)
printf '%s\n' "$results" | grep -q 'FMError: refusing to overwrite a different Discord outbound receipt' \
  || fail "conflicting receipt payload was not refused: $results"
pass "conflicting receipt payload for the same nonce is refused"

# --- concurrent identical artifact writes: one canonical record ---------
artifact_payload='{"schema":"fw-artifact.v1","artifact_id":"art1","profile":"proapplis","purpose":"exchange"}'
results=$(run_parallel artifact art1 "$artifact_payload")
[ "$(printf '%s\n' "$results" | grep -c 'artifact record written')" -eq 1 ] \
  || fail "expected exactly one artifact record written, got: $results"
[ "$(printf '%s\n' "$results" | grep -c 'artifact record exists')" -eq 7 ] \
  || fail "expected seven idempotent artifact exists results, got: $results"
pass "concurrent identical artifact writes produce one canonical artifact record"

# --- conflicting artifact record for the same id is refused -------------
results=$(run_parallel artifact art1 '{"schema":"fw-artifact.v1","artifact_id":"art1","profile":"proapplis","purpose":"other"}' 4)
printf '%s\n' "$results" | grep -q 'FMError: refusing to overwrite a different artifact record' \
  || fail "conflicting artifact record was not refused: $results"
pass "conflicting artifact record for the same id is refused"

# --- concurrent identical task-link writes ------------------------------
tasklink_payload='{"schema":"fw-task-link.v1","task_id":"tl1","request_id":"discord:1:2:3"}'
results=$(run_parallel tasklink tl1 "$tasklink_payload")
[ "$(printf '%s\n' "$results" | grep -c 'task link written')" -eq 1 ] \
  || fail "expected exactly one task link written, got: $results"
[ "$(printf '%s\n' "$results" | grep -c 'task link exists')" -eq 7 ] \
  || fail "expected seven idempotent task link exists results, got: $results"
pass "concurrent identical task-link writes are idempotent"

# --- conflicting task-link content is refused ---------------------------
results=$(run_parallel tasklink tl1 '{"schema":"fw-task-link.v1","task_id":"tl1","request_id":"discord:1:2:9"}' 4)
printf '%s\n' "$results" | grep -q 'FMError: refusing to overwrite a different task link' \
  || fail "conflicting task link was not refused: $results"
pass "conflicting task-link content is refused"

# --- descriptor-bound reads: symlinks and traversal are refused ----------
target="$TMP_ROOT/plain.txt"
printf 'hello' > "$target"
link="$TMP_ROOT/link.txt"
ln -s "$target" "$link"
descriptor_out=$(python3 - "$LIB" "$target" "$link" "$TMP_ROOT" <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fwl", sys.argv[1])
fwl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fwl)
target, link, root = Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])

def expect_refuse(fn, label):
    try:
        fn()
        print("NO-REFUSE", label)
    except fwl.FMError as exc:
        print("refused", label, "-", exc)

print("read:", fwl.read_text_file(str(target)))
expect_refuse(lambda: fwl.read_text_file(str(link)), "symlinked text file")

def traversal():
    with fwl.open_regular_under_root(root, Path("../escape.txt"), "artifact"):
        pass
expect_refuse(traversal, "root traversal via ..")

def empty_relative():
    with fwl.open_regular_under_root(root, Path(""), "artifact"):
        pass
expect_refuse(empty_relative, "empty relative path")

nested_dir = root / "sub"
nested_dir.mkdir(exist_ok=True)
nested = nested_dir / "artifact.txt"
nested.write_text("artifact body")
with fwl.open_regular_under_root(root, Path("sub/artifact.txt"), "artifact") as (fd, before):
    data = os.read(fd, 1024)
    after = os.fstat(fd)
print("under-root read:", data.decode(), "unchanged:", fwl.descriptor_unchanged(before, after, len(data)))

with fwl.open_regular_readonly(target, "text file") as (fd, before):
    data = os.read(fd, 1024)
    after = os.fstat(fd)
print("readonly unchanged:", fwl.descriptor_unchanged(before, after, len(data)))
print("tampered unchanged:", fwl.descriptor_unchanged(before, after, len(data) + 1))
PY
) || descriptor_out="$descriptor_out (python failed)"
printf '%s\n' "$descriptor_out" | grep -q 'NO-REFUSE' \
  && fail "an unsafe descriptor read was not refused: $descriptor_out"
printf '%s\n' "$descriptor_out" | grep -q 'read: hello' || fail "plain text read failed: $descriptor_out"
printf '%s\n' "$descriptor_out" | grep -q 'refused symlinked text file' || fail "symlinked text read not refused: $descriptor_out"
printf '%s\n' "$descriptor_out" | grep -q 'refused root traversal' || fail "traversal read not refused: $descriptor_out"
printf '%s\n' "$descriptor_out" | grep -q 'refused empty relative path' || fail "empty relative path not refused: $descriptor_out"
printf '%s\n' "$descriptor_out" | grep -q 'under-root read: artifact body unchanged: True' \
  || fail "under-root descriptor read failed: $descriptor_out"
printf '%s\n' "$descriptor_out" | grep -q 'readonly unchanged: True' || fail "readonly descriptor check failed: $descriptor_out"
printf '%s\n' "$descriptor_out" | grep -q 'tampered unchanged: False' || fail "tampered descriptor not detected: $descriptor_out"
pass "descriptor-bound reads refuse symlinks and traversal and verify descriptor stability"
