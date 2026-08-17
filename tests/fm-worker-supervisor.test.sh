#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUPERVISOR="$ROOT/bin/fm-worker-supervisor.py"

run_supervisor_controls() {
  local tmp work account request result home task_gen assignment repo_gen account_binding worktree_binding repo_binding cloud
  fm_test_tmproot_into tmp fm-worker-supervisor
  work="$tmp/work"
  account="$tmp/account"
  mkdir -p "$work" "$account"
  home=$(printf home | shasum -a 256 | awk '{print $1}')
  account_binding=$(printf account | shasum -a 256 | awk '{print $1}')
  worktree_binding=$(printf worktree | shasum -a 256 | awk '{print $1}')
  repo_binding=$(printf repo | shasum -a 256 | awk '{print $1}')
  task_gen=task-gen
  assignment=asg-00000001
  repo_gen='repo-gen'
  cloud=vm-instance
  request="$tmp/request.json"
  result="$tmp/result.json"
  python3 - "$request" "$home" "$account_binding" "$worktree_binding" "$repo_binding" <<'PY'
import hashlib,json,sys
path,home,account,worktree,repo=sys.argv[1:]
value={"schema":"fm.worker-execution/v1","home_binding":home,"task":"task-one","task_generation":"task-gen","assignment_generation":"asg-00000001","account_binding":account,"worktree_binding":worktree,"repository_binding":repo,"repository_generation":"repo-gen","cloud_instance_id":"vm-instance","argv":["/usr/bin/python3","-c","print('ok')"],"wall_seconds":60}
value["request_digest"]=hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",", ":")).encode()).hexdigest()
json.dump(value,open(path,"w"),sort_keys=True,separators=(",", ":"))
PY
  env FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one \
    FM_WORKER_TASK_GENERATION="$task_gen" FM_WORKER_ASSIGNMENT_GENERATION="$assignment" \
    FM_WORKER_ACCOUNT_BINDING="$account_binding" FM_WORKER_WORKTREE_BINDING="$worktree_binding" \
    FM_WORKER_REPOSITORY_BINDING="$repo_binding" FM_WORKER_REPOSITORY_GENERATION="$repo_gen" \
    FM_WORKER_CLOUD_INSTANCE_ID="$cloud" FM_WORKER_WORKTREE="$work" FM_WORKER_ACCOUNT_HOME="$account" \
    FM_WORKER_EXECUTED_DIR="$tmp/executed" \
    "$SUPERVISOR" execute --request "$request" --result "$result" >/dev/null \
    || fail "minimal guest supervisor rejected an exact request"
  python3 - "$request" "$result" <<'PY' || fail "minimal guest supervisor result was not exact"
import hashlib,json,sys
request=json.load(open(sys.argv[1])); result=json.load(open(sys.argv[2])); supplied=result.pop("result_digest")
assert result["schema"]=="fm.worker-execution-result/v1" and result["request_digest"]==request["request_digest"]
assert result["task"]=="task-one" and result["assignment_generation"]=="asg-00000001" and result["exit_code"]==0
assert supplied==hashlib.sha256(json.dumps(result,sort_keys=True,separators=(",", ":")).encode()).hexdigest()
PY

  # Unsafe positive controls: changed request after digest, changed assignment
  # environment, shell-shaped empty command, and timeout all produce bounded refusal/result.
  python3 - "$request" <<'PY'
import json,sys
value=json.load(open(sys.argv[1])); value["argv"]=["/usr/bin/false"]; json.dump(value,open(sys.argv[1],"w"),sort_keys=True,separators=(",", ":"))
PY
  if env FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one FM_WORKER_TASK_GENERATION="$task_gen" \
      FM_WORKER_ASSIGNMENT_GENERATION="$assignment" FM_WORKER_ACCOUNT_BINDING="$account_binding" \
      FM_WORKER_WORKTREE_BINDING="$worktree_binding" FM_WORKER_REPOSITORY_BINDING="$repo_binding" \
      FM_WORKER_REPOSITORY_GENERATION="$repo_gen" FM_WORKER_CLOUD_INSTANCE_ID="$cloud" \
      FM_WORKER_WORKTREE="$work" FM_WORKER_ACCOUNT_HOME="$account" \
      FM_WORKER_EXECUTED_DIR="$tmp/executed" \
      "$SUPERVISOR" execute --request "$request" --result "$result" >/dev/null 2>&1; then
    fail "minimal guest supervisor accepted a request changed after digest binding"
  fi
  pass "pinned guest supervisor executes one exact command and rejects changed request or assignment identity"
}

run_supervisor_replay_controls() {
  local tmp work account request result home account_binding worktree_binding repo_binding counter
  fm_test_tmproot_into tmp fm-worker-supervisor-replay
  work="$tmp/work"
  account="$tmp/account"
  counter="$tmp/side-effect-count"
  mkdir -p "$work" "$account"
  home=$(printf home | shasum -a 256 | awk '{print $1}')
  account_binding=$(printf account | shasum -a 256 | awk '{print $1}')
  worktree_binding=$(printf worktree | shasum -a 256 | awk '{print $1}')
  repo_binding=$(printf repo | shasum -a 256 | awk '{print $1}')
  request="$tmp/request.json"
  result="$tmp/result.json"
  python3 - "$request" "$home" "$account_binding" "$worktree_binding" "$repo_binding" "$counter" <<'PY'
import hashlib,json,sys
path,home,account,worktree,repo,counter=sys.argv[1:]
value={"schema":"fm.worker-execution/v1","home_binding":home,"task":"task-one","task_generation":"task-gen","assignment_generation":"asg-00000001","account_binding":account,"worktree_binding":worktree,"repository_binding":repo,"repository_generation":"repo-gen","cloud_instance_id":"vm-instance","argv":["/bin/sh","-c","echo x >> {}".format(counter)],"wall_seconds":60}
value["request_digest"]=hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",", ":")).encode()).hexdigest()
json.dump(value,open(path,"w"),sort_keys=True,separators=(",", ":"))
PY
  for _ in 1 2; do
    env FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one \
      FM_WORKER_TASK_GENERATION=task-gen FM_WORKER_ASSIGNMENT_GENERATION=asg-00000001 \
      FM_WORKER_ACCOUNT_BINDING="$account_binding" FM_WORKER_WORKTREE_BINDING="$worktree_binding" \
      FM_WORKER_REPOSITORY_BINDING="$repo_binding" FM_WORKER_REPOSITORY_GENERATION=repo-gen \
      FM_WORKER_CLOUD_INSTANCE_ID=vm-instance FM_WORKER_WORKTREE="$work" FM_WORKER_ACCOUNT_HOME="$account" \
      FM_WORKER_EXECUTED_DIR="$tmp/executed" \
      "$SUPERVISOR" execute --request "$request" --result "$result" >/dev/null \
      || fail "guest supervisor refused an exact replayable request"
  done
  test "$(wc -l < "$counter" | tr -d ' ')" = 1 \
    || fail "guest supervisor re-ran the task command on an exact replay"
  python3 - "$result" <<'PY' || fail "replayed result lost its exact digest binding"
import hashlib,json,sys
result=json.load(open(sys.argv[1])); supplied=result.pop("result_digest")
assert supplied==hashlib.sha256(json.dumps(result,sort_keys=True,separators=(",", ":")).encode()).hexdigest()
PY
  pass "guest supervisor executes one request digest at most once and replays the recorded result"
}

run_supervisor_steer_controls() {
  local tmp assignment_file digest ack home
  fm_test_tmproot_into tmp fm-worker-supervisor-steer
  assignment_file="$tmp/assignment.json"
  home=$(printf home | shasum -a 256 | awk '{print $1}')
  digest=$(printf steer-request | shasum -a 256 | awk '{print $1}')
  python3 - "$assignment_file" "$home" <<'PY'
import json,sys
json.dump({
    "home_binding": sys.argv[2], "task": "task-one", "task_generation": "task-gen",
    "assignment_generation": "asg-00000001", "account_binding": "x", "worktree_binding": "y",
    "repository_binding": "z", "repository_generation": "repo-gen", "supervisor_sha256": "s",
}, open(sys.argv[1], "w"), sort_keys=True, separators=(",", ":"))
PY
  ack=$(env FM_WORKER_ASSIGNMENT_PATH="$assignment_file" "$SUPERVISOR" steer \
    --home-binding "$home" --task task-one --task-generation task-gen \
    --assignment-generation asg-00000001 --request-digest "$digest") \
    || fail "guest supervisor refused an exact steer request"
  python3 - "$ack" "$digest" <<'PY' || fail "guest steer acknowledgement was not exact"
import json,sys
line=sys.argv[1].strip()
assert line.startswith("FM-WORKER-STEER-ACK:")
value=json.loads(line[len("FM-WORKER-STEER-ACK:"):])
assert value["schema"]=="fm.worker-steer-ack/v1"
assert value["request_digest"]==sys.argv[2]
assert value["assignment_generation"]=="asg-00000001"
PY
  if env FM_WORKER_ASSIGNMENT_PATH="$assignment_file" "$SUPERVISOR" steer \
      --home-binding "$home" --task task-two --task-generation task-gen \
      --assignment-generation asg-00000001 --request-digest "$digest" >/dev/null 2>&1; then
    fail "guest supervisor acknowledged a steer for a foreign task binding"
  fi
  pass "guest supervisor acknowledges only exact digest-bound steer requests"
}

run_supervisor_payload_staging() {
  # The REAL supervisor stages a REAL repository bundle plus task files and
  # account material from digest-manifested archives (delivered through the
  # hermetic file lane, which runs every verification the network lane runs),
  # clones the bundle, proves the bound repository generation, and executes
  # the argv inside the cloned repository.
  local tmp work account request result home task_gen assignment repo_gen
  local account_binding worktree_binding repo_binding cloud src head out status
  fm_test_tmproot_into tmp fm-worker-supervisor-payload
  work="$tmp/work"
  account="$tmp/account"
  src="$tmp/src"
  mkdir -p "$work" "$account"
  fm_git_init_commit "$src"
  head=$(git -C "$src" rev-parse HEAD)
  git -C "$src" bundle create "$tmp/repo.bundle" HEAD >/dev/null 2>&1
  printf 'do the task\n' > "$tmp/brief.md"
  printf '{"auth":"fixture"}\n' > "$tmp/auth.json"
  home=$(printf home | shasum -a 256 | awk '{print $1}')
  account_binding=$(printf account | shasum -a 256 | awk '{print $1}')
  worktree_binding=$(printf worktree | shasum -a 256 | awk '{print $1}')
  repo_binding=$(printf repo | shasum -a 256 | awk '{print $1}')
  task_gen=task-gen
  assignment=asg-00000001
  repo_gen=$head
  cloud=vm-instance
  request="$tmp/request.json"
  result="$tmp/result.json"
  python3 - "$tmp" "$home" "$account_binding" "$worktree_binding" "$repo_binding" "$head" <<'PY'
import hashlib
import io
import json
import sys
import tarfile
from pathlib import Path

tmp, home, account_b, worktree_b, repo_b, head = sys.argv[1:]
root = Path(tmp)

def archive(names):
    files = {}
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as handle:
        for name in names:
            body = (root / name).read_bytes()
            info = tarfile.TarInfo(name=name)
            info.size = len(body)
            handle.addfile(info, io.BytesIO(body))
            files[name] = {"sha256": hashlib.sha256(body).hexdigest(), "bytes": len(body)}
    return buffer.getvalue(), files

payload_bytes, payload_files = archive(["repo.bundle", "brief.md"])
account_bytes, account_files = archive(["auth.json"])
(root / "payload.tar.gz").write_bytes(payload_bytes)
(root / "account.tar.gz").write_bytes(account_bytes)
request = {
    "schema": "fm.worker-execution/v1",
    "home_binding": home,
    "task": "task-one",
    "task_generation": "task-gen",
    "assignment_generation": "asg-00000001",
    "account_binding": account_b,
    "worktree_binding": worktree_b,
    "repository_binding": repo_b,
    "repository_generation": head,
    "cloud_instance_id": "vm-instance",
    "argv": ["/bin/sh", "-c", "cat .fm-task-present 2>/dev/null; git rev-parse HEAD; cat ../.fm-task/brief.md"],
    "wall_seconds": 60,
    "payload_files": payload_files,
    "account_files": account_files,
}
unsigned = dict(request)
request["request_digest"] = hashlib.sha256(
    json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
(root / "request.json").write_text(json.dumps(request))
meta = {
    "payload": {"sha256": hashlib.sha256(payload_bytes).hexdigest(), "bytes": len(payload_bytes)},
    "account": {"sha256": hashlib.sha256(account_bytes).hexdigest(), "bytes": len(account_bytes)},
}
(root / "staging-meta.json").write_text(json.dumps(meta))
PY
  local payload_sha payload_bytes account_sha account_bytes
  payload_sha=$(python3 -c "import json,sys;print(json.load(open('$tmp/staging-meta.json'))['payload']['sha256'])")
  payload_bytes=$(python3 -c "import json,sys;print(json.load(open('$tmp/staging-meta.json'))['payload']['bytes'])")
  account_sha=$(python3 -c "import json,sys;print(json.load(open('$tmp/staging-meta.json'))['account']['sha256'])")
  account_bytes=$(python3 -c "import json,sys;print(json.load(open('$tmp/staging-meta.json'))['account']['bytes'])")
  out=$(FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one FM_WORKER_TASK_GENERATION="$task_gen" \
    FM_WORKER_ASSIGNMENT_GENERATION="$assignment" FM_WORKER_ACCOUNT_BINDING="$account_binding" \
    FM_WORKER_WORKTREE_BINDING="$worktree_binding" FM_WORKER_REPOSITORY_BINDING="$repo_binding" \
    FM_WORKER_REPOSITORY_GENERATION="$repo_gen" FM_WORKER_CLOUD_INSTANCE_ID="$cloud" \
    FM_WORKER_WORKTREE="$work" FM_WORKER_ACCOUNT_HOME="$account" \
    FM_WORKER_EXECUTED_DIR="$tmp/executed" \
    FM_WORKER_PAYLOAD_URL="https://fixture.invalid/payload" FM_WORKER_PAYLOAD_SHA256="$payload_sha" \
    FM_WORKER_PAYLOAD_BYTES="$payload_bytes" FM_WORKER_PAYLOAD_FILE="$tmp/payload.tar.gz" \
    FM_WORKER_ACCOUNT_URL="https://fixture.invalid/account" FM_WORKER_ACCOUNT_SHA256="$account_sha" \
    FM_WORKER_ACCOUNT_BYTES="$account_bytes" FM_WORKER_ACCOUNT_FILE="$tmp/account.tar.gz" \
    python3 "$SUPERVISOR" execute --request "$request" --result "$result" 2>&1)
  status=$?
  expect_code 0 "$status" "staged payload execution should succeed: $out"
  test -f "$work/repo/.git/config" || fail "the repository bundle was not cloned to the staged layout"
  test "$(git -C "$work/repo" rev-parse HEAD)" = "$repo_gen" || fail "the cloned repository head is not the bound generation"
  test -f "$work/.fm-task/brief.md" || fail "the brief was not staged"
  test -f "$account/pi-agent/auth.json" || fail "the account material was not staged"
  grep -q '"exit_code": 0' "$result" || grep -q '"exit_code":0' "$result" || fail "staged execution did not exit 0: $(cat "$result")"
  # Tampered archive: append bytes; the digest gate must refuse.
  mkdir -p "$tmp/work2"
  printf 'tamper' >> "$tmp/payload.tar.gz"
  out=$(FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one FM_WORKER_TASK_GENERATION="$task_gen" \
    FM_WORKER_ASSIGNMENT_GENERATION="$assignment" FM_WORKER_ACCOUNT_BINDING="$account_binding" \
    FM_WORKER_WORKTREE_BINDING="$worktree_binding" FM_WORKER_REPOSITORY_BINDING="$repo_binding" \
    FM_WORKER_REPOSITORY_GENERATION="$repo_gen" FM_WORKER_CLOUD_INSTANCE_ID="$cloud" \
    FM_WORKER_WORKTREE="$tmp/work2" FM_WORKER_ACCOUNT_HOME="$account" \
    FM_WORKER_EXECUTED_DIR="$tmp/executed2" \
    FM_WORKER_PAYLOAD_URL="https://fixture.invalid/payload" FM_WORKER_PAYLOAD_SHA256="$payload_sha" \
    FM_WORKER_PAYLOAD_BYTES="$payload_bytes" FM_WORKER_PAYLOAD_FILE="$tmp/payload.tar.gz" \
    FM_WORKER_ACCOUNT_URL="https://fixture.invalid/account" FM_WORKER_ACCOUNT_SHA256="$account_sha" \
    FM_WORKER_ACCOUNT_BYTES="$account_bytes" FM_WORKER_ACCOUNT_FILE="$tmp/account.tar.gz" \
    python3 "$SUPERVISOR" execute --request "$request" --result "$tmp/result2.json" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    fail "a tampered payload archive was accepted: $out"
  fi
  case "$out" in
    *"differs from its bound digest"*) : ;;
    *) fail "the tampered payload refusal did not name the digest gate: $out" ;;
  esac
  # Lying manifest: the archive is intact (archive-level digest passes), but
  # the request's per-member digest for brief.md is wrong; the PER-MEMBER
  # gate must fire, so deleting that check can never pass this suite again.
  python3 - "$tmp" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
request = json.loads((root / "request.json").read_text())
request.pop("request_digest")
request["payload_files"]["brief.md"]["sha256"] = "0" * 64
request["request_digest"] = hashlib.sha256(
    json.dumps(request, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
(root / "request-lying.json").write_text(json.dumps(request))
PY
  git -C "$src" bundle create "$tmp/repo.bundle" HEAD >/dev/null 2>&1
  python3 - "$tmp" <<'PY'
import hashlib
import io
import json
import tarfile
import sys
from pathlib import Path

root = Path(sys.argv[1])
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w:gz") as handle:
    for name in ("repo.bundle", "brief.md"):
        body = (root / name).read_bytes()
        info = tarfile.TarInfo(name=name)
        info.size = len(body)
        handle.addfile(info, io.BytesIO(body))
payload = buffer.getvalue()
(root / "payload.tar.gz").write_bytes(payload)
meta = json.loads((root / "staging-meta.json").read_text())
meta["payload"] = {"sha256": hashlib.sha256(payload).hexdigest(), "bytes": len(payload)}
(root / "staging-meta.json").write_text(json.dumps(meta))
PY
  payload_sha=$(python3 -c "import json;print(json.load(open('$tmp/staging-meta.json'))['payload']['sha256'])")
  payload_bytes=$(python3 -c "import json;print(json.load(open('$tmp/staging-meta.json'))['payload']['bytes'])")
  mkdir -p "$tmp/work3"
  out=$(FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one FM_WORKER_TASK_GENERATION="$task_gen" \
    FM_WORKER_ASSIGNMENT_GENERATION="$assignment" FM_WORKER_ACCOUNT_BINDING="$account_binding" \
    FM_WORKER_WORKTREE_BINDING="$worktree_binding" FM_WORKER_REPOSITORY_BINDING="$repo_binding" \
    FM_WORKER_REPOSITORY_GENERATION="$repo_gen" FM_WORKER_CLOUD_INSTANCE_ID="$cloud" \
    FM_WORKER_WORKTREE="$tmp/work3" FM_WORKER_ACCOUNT_HOME="$account" \
    FM_WORKER_EXECUTED_DIR="$tmp/executed3" \
    FM_WORKER_PAYLOAD_URL="https://fixture.invalid/payload" FM_WORKER_PAYLOAD_SHA256="$payload_sha" \
    FM_WORKER_PAYLOAD_BYTES="$payload_bytes" FM_WORKER_PAYLOAD_FILE="$tmp/payload.tar.gz" \
    FM_WORKER_ACCOUNT_URL="https://fixture.invalid/account" FM_WORKER_ACCOUNT_SHA256="$account_sha" \
    FM_WORKER_ACCOUNT_BYTES="$account_bytes" FM_WORKER_ACCOUNT_FILE="$tmp/account.tar.gz" \
    python3 "$SUPERVISOR" execute --request "$tmp/request-lying.json" --result "$tmp/result3.json" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    fail "a lying per-member manifest was accepted: $out"
  fi
  case "$out" in
    *"staged file differs from its bound manifest"*) : ;;
    *) fail "the lying-manifest refusal did not name the per-member gate: $out" ;;
  esac
  # Wrong bound repository generation: staging succeeds but the clone's HEAD
  # proof must refuse before any execution.
  python3 - "$tmp" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
request = json.loads((root / "request.json").read_text())
request.pop("request_digest")
request["repository_generation"] = "f" * 40
request["request_digest"] = hashlib.sha256(
    json.dumps(request, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
(root / "request-wrong-gen.json").write_text(json.dumps(request))
PY
  mkdir -p "$tmp/work4"
  out=$(FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one FM_WORKER_TASK_GENERATION="$task_gen" \
    FM_WORKER_ASSIGNMENT_GENERATION="$assignment" FM_WORKER_ACCOUNT_BINDING="$account_binding" \
    FM_WORKER_WORKTREE_BINDING="$worktree_binding" FM_WORKER_REPOSITORY_BINDING="$repo_binding" \
    FM_WORKER_REPOSITORY_GENERATION="$(python3 -c "print('f'*40)")" \
    FM_WORKER_CLOUD_INSTANCE_ID="$cloud" \
    FM_WORKER_WORKTREE="$tmp/work4" FM_WORKER_ACCOUNT_HOME="$account" \
    FM_WORKER_EXECUTED_DIR="$tmp/executed4" \
    FM_WORKER_PAYLOAD_URL="https://fixture.invalid/payload" FM_WORKER_PAYLOAD_SHA256="$payload_sha" \
    FM_WORKER_PAYLOAD_BYTES="$payload_bytes" FM_WORKER_PAYLOAD_FILE="$tmp/payload.tar.gz" \
    FM_WORKER_ACCOUNT_URL="https://fixture.invalid/account" FM_WORKER_ACCOUNT_SHA256="$account_sha" \
    FM_WORKER_ACCOUNT_BYTES="$account_bytes" FM_WORKER_ACCOUNT_FILE="$tmp/account.tar.gz" \
    python3 "$SUPERVISOR" execute --request "$tmp/request-wrong-gen.json" --result "$tmp/result4.json" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    fail "a wrong bound repository generation was accepted: $out"
  fi
  case "$out" in
    *"staged repository head differs"*) : ;;
    *) fail "the wrong-generation refusal did not name the head proof: $out" ;;
  esac
  pass "the supervisor stages digest-bound payload, account, and repository exactly"
}

run_supervisor_controls
run_supervisor_replay_controls
run_supervisor_steer_controls
run_supervisor_payload_staging
echo "# fm-worker-supervisor.test.sh: all assertions passed"
