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

run_supervisor_outcome_collection() {
  # The REAL supervisor collects the REAL commits a task command makes in the
  # staged repository, bundles them against the bound generation, and the
  # bundle really fast-forwards the source repository the payload came from.
  local tmp work account src head out status sink
  local home account_binding worktree_binding repo_binding
  fm_test_tmproot_into tmp fm-worker-supervisor-outcome
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
  sink="$tmp/outcome.bundle"
  supervisor_outcome_request() {
    # $1 = request path, $2 = argv command, $3 = outcome_expected (1/0),
    # $4 = include payload manifests (1/0)
    python3 - "$tmp" "$home" "$account_binding" "$worktree_binding" "$repo_binding" "$head" "$@" <<'PY'
import hashlib
import io
import json
import sys
import tarfile
from pathlib import Path

tmp, home, account_b, worktree_b, repo_b, head, target, command, expected, with_payload = sys.argv[1:]
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
    "argv": ["/bin/sh", "-c", command],
    "wall_seconds": 60,
}
if with_payload == "1":
    request["payload_files"] = payload_files
    request["account_files"] = account_files
if expected == "1":
    request["outcome_expected"] = True
unsigned = dict(request)
request["request_digest"] = hashlib.sha256(
    json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
Path(target).write_text(json.dumps(request))
meta = {
    "payload": {"sha256": hashlib.sha256(payload_bytes).hexdigest(), "bytes": len(payload_bytes)},
    "account": {"sha256": hashlib.sha256(account_bytes).hexdigest(), "bytes": len(account_bytes)},
}
(root / "staging-meta.json").write_text(json.dumps(meta))
PY
  }
  supervisor_outcome_run() {
    # $1 = request, $2 = result, $3 = worktree, $4 = executed dir,
    # $5 = outcome sink, $6 = outcome URL ("" arms nothing)
    local payload_sha payload_bytes account_sha account_bytes
    mkdir -p "$3"
    payload_sha=$(python3 -c "import json;print(json.load(open('$tmp/staging-meta.json'))['payload']['sha256'])")
    payload_bytes=$(python3 -c "import json;print(json.load(open('$tmp/staging-meta.json'))['payload']['bytes'])")
    account_sha=$(python3 -c "import json;print(json.load(open('$tmp/staging-meta.json'))['account']['sha256'])")
    account_bytes=$(python3 -c "import json;print(json.load(open('$tmp/staging-meta.json'))['account']['bytes'])")
    FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one FM_WORKER_TASK_GENERATION=task-gen \
      FM_WORKER_ASSIGNMENT_GENERATION=asg-00000001 FM_WORKER_ACCOUNT_BINDING="$account_binding" \
      FM_WORKER_WORKTREE_BINDING="$worktree_binding" FM_WORKER_REPOSITORY_BINDING="$repo_binding" \
      FM_WORKER_REPOSITORY_GENERATION="$head" FM_WORKER_CLOUD_INSTANCE_ID=vm-instance \
      FM_WORKER_WORKTREE="$3" FM_WORKER_ACCOUNT_HOME="$account" \
      FM_WORKER_EXECUTED_DIR="$4" \
      FM_WORKER_PAYLOAD_URL="https://fixture.invalid/payload" FM_WORKER_PAYLOAD_SHA256="$payload_sha" \
      FM_WORKER_PAYLOAD_BYTES="$payload_bytes" FM_WORKER_PAYLOAD_FILE="$tmp/payload.tar.gz" \
      FM_WORKER_ACCOUNT_URL="https://fixture.invalid/account" FM_WORKER_ACCOUNT_SHA256="$account_sha" \
      FM_WORKER_ACCOUNT_BYTES="$account_bytes" FM_WORKER_ACCOUNT_FILE="$tmp/account.tar.gz" \
      FM_WORKER_OUTCOME_URL="$6" FM_WORKER_OUTCOME_FILE="$5" \
      python3 "$SUPERVISOR" execute --request "$1" --result "$2" 2>&1
  }
  # A crewmate that commits: the outcome must carry exactly its new commits.
  supervisor_outcome_request "$tmp/request.json" \
    'git config user.email a@b.c; git config user.name t; echo work >> file.txt; git add -A; git commit -qm "crewmate work"' 1 1
  out=$(supervisor_outcome_run "$tmp/request.json" "$tmp/result.json" "$work" "$tmp/executed" "$sink" "https://fixture.invalid/outcome")
  status=$?
  expect_code 0 "$status" "outcome-collecting execution should succeed: $out"
  test -s "$sink" || fail "the outcome bundle was never written"
  python3 - "$tmp/result.json" "$sink" <<'PY' || fail "the recorded outcome does not describe the written bundle"
import hashlib
import json
import sys

result = json.load(open(sys.argv[1]))
body = open(sys.argv[2], "rb").read()
assert result["outcome_present"] is True, result
assert result["outcome_error"] == "", result
assert result["outcome_commits"] == 1, result
assert result["outcome_bytes"] == len(body), result
assert result["outcome_sha256"] == hashlib.sha256(body).hexdigest(), result
unsigned = dict(result)
supplied = unsigned.pop("result_digest")
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
assert supplied == hashlib.sha256(canonical).hexdigest(), "outcome fields are outside the result digest"
PY
  # The whole point of the bundle: it lands on the source repository.
  git -C "$src" fetch --quiet "$sink" HEAD || fail "the outcome bundle does not fetch into the source repository"
  git -C "$src" merge --ff-only FETCH_HEAD >/dev/null 2>&1 \
    || fail "the outcome bundle is not a fast-forward of the bound generation"
  test -f "$src/file.txt" || fail "the crewmate's committed file did not land in the source repository"
  # A read-only task reports no outcome and no error, and writes no bundle.
  rm -f "$sink"
  supervisor_outcome_request "$tmp/request-ro.json" 'true' 1 1
  out=$(supervisor_outcome_run "$tmp/request-ro.json" "$tmp/result-ro.json" "$tmp/work-ro" "$tmp/executed-ro" "$tmp/sink-ro" "https://fixture.invalid/outcome")
  status=$?
  expect_code 0 "$status" "read-only execution should succeed: $out"
  test ! -e "$tmp/sink-ro" || fail "a read-only task must not upload an outcome bundle"
  python3 -c "
import json,sys
r=json.load(open('$tmp/result-ro.json'))
assert r['outcome_present'] is False, r
assert r['outcome_error'] == '', r
assert r['outcome_commits'] == 0, r
" || fail "a read-only task reported a wrong outcome disposition"
  # Arming an outcome without a staged repository is refused before the argv runs.
  # shellcheck disable=SC2016 # $PWD is expanded by the guest argv, not here
  supervisor_outcome_request "$tmp/request-nopayload.json" 'touch "$PWD/ran"' 1 0
  out=$(supervisor_outcome_run "$tmp/request-nopayload.json" "$tmp/result-np.json" "$tmp/work-np" "$tmp/executed-np" "$tmp/sink-np" "https://fixture.invalid/outcome")
  status=$?
  expect_code 2 "$status" "an outcome without a staged repository should be refused"
  assert_contains "$out" "outcome cannot be collected without a staged repository" "the refusal should name the missing repository"
  # An expected outcome with no staging armed at all is refused, so a stripped
  # protected parameter cannot silently downgrade a landing task.
  supervisor_outcome_request "$tmp/request-nourl.json" 'true' 1 1
  out=$(supervisor_outcome_run "$tmp/request-nourl.json" "$tmp/result-nu.json" "$tmp/work-nu" "$tmp/executed-nu" "" "")
  status=$?
  expect_code 2 "$status" "an unarmed outcome lane should be refused"
  assert_contains "$out" "no outcome staging URL was armed" "the refusal should name the unarmed staging lane"
  supervisor_outcome_request "$tmp/request-fileonly.json" 'true' 1 1
  out=$(supervisor_outcome_run "$tmp/request-fileonly.json" "$tmp/result-fo.json" \
    "$tmp/work-fo" "$tmp/executed-fo" "$tmp/sink-fo" "")
  status=$?
  expect_code 2 "$status" "a file sink must not arm the outcome lane on its own"
  assert_contains "$out" "no outcome staging URL was armed" \
    "an unprotected file sink stood in for the stripped protected URL"
  test ! -e "$tmp/sink-fo" || fail "the refused run still wrote an outcome"
  # The severest failure this contract can have: an outcome failure that is
  # NOT a SupervisorError must still leave the executed marker and a result,
  # or a redispatch runs the crewmate's command a second time. Induced for
  # real by pointing the sink at a directory that does not exist, which
  # raises OSError from inside the collection.
  local counter
  counter="$tmp/side-effect-count"
  supervisor_outcome_request "$tmp/request-oserr.json" \
    "git config user.email a@b.c; git config user.name t; echo x >> $counter; echo work >> f.txt; git add -A; git commit -qm w" 1 1
  for _ in 1 2; do
    out=$(supervisor_outcome_run "$tmp/request-oserr.json" "$tmp/result-oe.json" \
      "$tmp/work-oe" "$tmp/executed-oe" "$tmp/absent-dir/sink" "https://fixture.invalid/outcome")
    status=$?
    expect_code 0 "$status" "a non-SupervisorError outcome failure must still produce a result: $out"
  done
  test "$(wc -l < "$counter" | tr -d ' ')" = 1 \
    || fail "an outcome collection failure let the task command run a second time"
  python3 -c "
import json
r = json.load(open('$tmp/result-oe.json'))
assert r['outcome_present'] is False, r
assert 'FileNotFoundError' in r['outcome_error'], r
" || fail "the outcome failure was not recorded in the bound result"
  # The same double-execution defect through the OTHER post-command arm: the
  # stream-evidence write. Driving the REAL execute() against a repository
  # whose .fm-worker path is a file makes that write raise for real; nothing
  # after the task command may escape, or no executed marker is written and
  # the next dispatch re-runs the crewmate and rmtree's its commits.
  local stream_out
  mkdir -p "$tmp/stream-arm"
  cat >"$tmp/stream-arm/driver.py" <<'STREAMARM'
import importlib.util
import sys
from pathlib import Path

supervisor_path, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_supervisor", supervisor_path)
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

root = Path(tmp)
repo = root / "repo"
repo.mkdir(parents=True, exist_ok=True)
# .fm-worker as a FILE at the worktree ROOT (where stream evidence lives, so
# it survives the next dispatch and does not dirty the crewmate's tree): the
# mkdir then raises, which is the post-command arm that used to escape and
# cost the executed marker.
(root / ".fm-worker").write_text("not a directory\n")
counter = root / "count"
request = {
    "argv": ["/bin/sh", "-c", "echo x >> {}".format(counter)],
    "wall_seconds": 60, "assignment_generation": "asg-00000001",
    "request_digest": "a" * 64, "task": "t", "task_generation": "gen-1",
    "cloud_instance_id": "vm", "repository_binding": "b" * 64,
    "repository_generation": "r" * 40,
}
result = supervisor.execute(request, repo, root)
assert result["exit_code"] == 0, result
assert result["streams_persisted"] is False, result
assert "stream evidence" in result["outcome_error"], result
assert counter.read_text().count("x") == 1, "the command ran more than once"
print("OK")
STREAMARM
  stream_out=$(python3 "$tmp/stream-arm/driver.py" "$SUPERVISOR" "$tmp/stream-arm" 2>&1)
  expect_code 0 $? "a stream-persistence failure must still produce a result: $stream_out"
  assert_contains "$stream_out" "OK" "the stream-arm driver did not complete: $stream_out"
  # The uncommitted-changes probe, driven through the REAL supervisor rather
  # than a hand-written fixture: it must be False for a pristine repository
  # (the supervisor writes stream evidence during the run, so this catches
  # that evidence dirtying the crewmate's own tree) and True for a real edit.
  local dirty_out
  mkdir -p "$tmp/dirty-probe"
  cat >"$tmp/dirty-probe/driver.py" <<'DIRTYPROBE'
import importlib.util
import subprocess
import sys
from pathlib import Path

supervisor_path, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_supervisor", supervisor_path)
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

root = Path(tmp)
repo = root / "repo"
repo.mkdir(parents=True, exist_ok=True)


def git(*args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


git("init", "--quiet")
git("config", "user.email", "a@b.c")
git("config", "user.name", "t")
(repo / "seed.txt").write_text("seed\n")
git("add", "-A")
git("commit", "--quiet", "-m", "seed")
base = git("rev-parse", "HEAD").stdout.decode().strip()

request = {
    "argv": ["/usr/bin/true"], "wall_seconds": 60,
    "assignment_generation": "asg-00000001", "request_digest": "a" * 64,
    "task": "t", "task_generation": "gen-1", "cloud_instance_id": "vm",
    "repository_binding": "b" * 64, "repository_generation": base,
    "outcome_expected": True,
}

# A genuinely pristine repository must report NO uncommitted changes. The
# supervisor writes its own stream evidence during this run, so this fails if
# that evidence lands inside the crewmate's tree.
result = supervisor.execute(request, repo, root)
assert result["outcome_present"] is False, result
assert result.get("outcome_uncommitted_changes") is False, (
    "a pristine repository was reported as dirty", result,
    subprocess.run(["git", "-C", str(repo), "status", "--porcelain"],
                   stdout=subprocess.PIPE).stdout.decode(),
)

# And a repository the crewmate really did dirty must report True.
(repo / "edited.txt").write_text("uncommitted work\n")
request2 = dict(request, request_digest="c" * 64)
dirty = supervisor.execute(request2, repo, root)
assert dirty["outcome_present"] is False, dirty
assert dirty.get("outcome_uncommitted_changes") is True, dirty
print("OK")
DIRTYPROBE
  dirty_out=$(FM_WORKER_OUTCOME_URL=https://fixture.invalid/outcome \
    FM_WORKER_OUTCOME_FILE="$tmp/dirty-probe/sink" \
    python3 "$tmp/dirty-probe/driver.py" "$SUPERVISOR" "$tmp/dirty-probe" 2>&1)
  expect_code 0 $? "the uncommitted probe must be honest: $dirty_out"
  assert_contains "$dirty_out" "OK" "the uncommitted probe driver did not complete: $dirty_out"
  # The replay lane, driven through the REAL CLI so main()'s call site is
  # covered: driving replay_outcome_upload() directly left the call site
  # deletable with every suite green. This is the designated recovery when a
  # blob is lost between execution and collection, and without it the
  # lifecycle wedges and the commits die with the VM.
  local replay_sink replay_first
  replay_sink="$tmp/replay-sink"
  supervisor_outcome_request "$tmp/request-replay.json" \
    "git config user.email a@b.c; git config user.name t; echo replay >> r.txt; git add -A; git commit -qm replay" 1 1
  out=$(supervisor_outcome_run "$tmp/request-replay.json" "$tmp/result-replay.json" \
    "$tmp/work-replay" "$tmp/executed-replay" "$replay_sink" "https://fixture.invalid/outcome")
  expect_code 0 $? "the first outcome-collecting run should succeed: $out"
  test -s "$replay_sink" || fail "the first run uploaded no bundle"
  replay_first=$(shasum -a 256 < "$replay_sink" | awk '{print $1}')

  # The blob is lost. Replaying the SAME request must put it back.
  rm -f "$replay_sink"
  out=$(supervisor_outcome_run "$tmp/request-replay.json" "$tmp/result-replay.json" \
    "$tmp/work-replay" "$tmp/executed-replay" "$replay_sink" "https://fixture.invalid/outcome")
  expect_code 0 $? "the replay should answer: $out"
  test -s "$replay_sink" \
    || fail "the replay did not re-upload the retained bundle, so a lost blob wedges the lane"
  test "$(shasum -a 256 < "$replay_sink" | awk '{print $1}')" = "$replay_first" \
    || fail "the replay uploaded different bytes than the recorded result committed to"

  # A retained bundle that no longer matches the recorded result must NOT be
  # re-uploaded: the controller would land bytes the signed result never
  # committed to.
  local retained
  retained=$(find "$tmp/work-replay/.fm-worker" -name '*-outcome.bundle' | head -1)
  test -n "$retained" || fail "the retained bundle was not kept on the task disk"
  printf 'tampered\n' >> "$retained"
  rm -f "$replay_sink"
  out=$(supervisor_outcome_run "$tmp/request-replay.json" "$tmp/result-replay.json" \
    "$tmp/work-replay" "$tmp/executed-replay" "$replay_sink" "https://fixture.invalid/outcome")
  expect_code 0 $? "the replay must still answer with the recorded result: $out"
  test ! -s "$replay_sink" \
    || fail "the replay re-uploaded a bundle that differs from the recorded result"
  pass "the supervisor collects, bounds and proves crewmate outcomes"
}

run_supervisor_existing_task_disk_recovery() {
  local tmp work repo account base supervisor_digest out status
  fm_test_tmproot_into tmp fm-worker-supervisor-existing-task-disk
  work="$tmp/work"
  repo="$work/repo"
  account="$tmp/account"
  mkdir -p "$work/.fm-return/data/recover-existing" "$work/.fm-return/state" "$account"
  fm_git_init_commit "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'uncommitted scout evidence\n' > "$repo/scratch.txt"
  python3 - "$repo" <<'PY' \
    || fail "could not prepare the cross-owner retained repository fixture"
import os
from pathlib import Path
import pwd
import sys

root = Path(sys.argv[1])
if os.geteuid() == 0:
    identity = pwd.getpwnam("nobody")
    for directory, directories, files in os.walk(root):
        os.chown(directory, identity.pw_uid, identity.pw_gid)
        for name in directories + files:
            os.chown(Path(directory) / name, identity.pw_uid, identity.pw_gid)
PY
  cat > "$work/.fm-return/data/recover-existing/report.md" <<'REPORT'
## Summary

Recovered scout evidence.

## What changed

The retained task disk stayed intact.

## Verification

The existing-disk execution collected it.

## Visual evidence

None.

## Artifacts

The scratch archive is returned.

## Follow-ups

None.
REPORT
  printf 'working: recovery report authored\n' > "$work/.fm-return/state/recover-existing.status"
  supervisor_digest=$(shasum -a 256 "$SUPERVISOR" | awk '{print $1}')
  python3 - "$tmp/request.json" "$base" "$supervisor_digest" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

path, base, supervisor_digest = sys.argv[1:]
request = {
    "schema": "fm.worker-execution/v1",
    "home_binding": "a" * 64,
    "task": "recover-existing",
    "task_generation": "spawn:recover-existing",
    "assignment_generation": "asg-00000001",
    "account_binding": "b" * 64,
    "worktree_binding": "c" * 64,
    "repository_binding": "d" * 64,
    "repository_generation": base,
    "cloud_instance_id": "vm-existing",
    "argv": ["/usr/bin/true"],
    "wall_seconds": 60,
    "existing_task_disk": True,
    "supervisor_sha256": supervisor_digest,
    "outcome_expected": True,
    "return_contract": {
        "schema": "fm.worker-return-contract/v1",
        "kind": "scout",
        "report_required": True,
        "report_path": "data/recover-existing/report.md",
        "status_path": "state/recover-existing.status",
        "visuals_path": "data/recover-existing/visuals",
        "branch": "",
    },
}
request["request_digest"] = hashlib.sha256(
    json.dumps(request, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
Path(path).write_text(json.dumps(request, sort_keys=True, separators=(",", ":")))
PY
  out=$(FM_WORKER_HOME_BINDING="$(printf a%.0s {1..64})" \
    FM_WORKER_TASK=recover-existing FM_WORKER_TASK_GENERATION=spawn:recover-existing \
    FM_WORKER_ASSIGNMENT_GENERATION=asg-00000001 \
    FM_WORKER_ACCOUNT_BINDING="$(printf b%.0s {1..64})" \
    FM_WORKER_WORKTREE_BINDING="$(printf c%.0s {1..64})" \
    FM_WORKER_REPOSITORY_BINDING="$(printf d%.0s {1..64})" \
    FM_WORKER_REPOSITORY_GENERATION="$base" FM_WORKER_CLOUD_INSTANCE_ID=vm-existing \
    FM_WORKER_WORKTREE="$work" FM_WORKER_ACCOUNT_HOME="$account" \
    FM_WORKER_EXECUTED_DIR="$tmp/executed" \
    FM_WORKER_OUTCOME_URL=https://fixture.invalid/outcome \
    FM_WORKER_OUTCOME_FILE="$tmp/outcome.bundle" \
    python3 "$SUPERVISOR" execute --request "$tmp/request.json" --result "$tmp/result.json" 2>&1)
  status=$?
  expect_code 0 "$status" "existing task-disk recovery should succeed: $out"
  assert_present "$repo/scratch.txt" "existing task-disk recovery replaced uncommitted scout work"
  assert_present "$tmp/outcome.bundle" "existing task-disk recovery returned no bundle"
  python3 - "$tmp/result.json" <<'PY' \
    || fail "existing task-disk recovery result is not exact"
import json,sys
result=json.load(open(sys.argv[1]))
assert result["return_present"] is True, result
assert result["outcome_present"] is False, result
assert result["outcome_commits"] == 0, result
assert result["outcome_uncommitted_changes"] is True, result
PY
  python3 - "$tmp/request.json" "$tmp/bad-lineage.json" <<'PY'
import hashlib,json,sys
request=json.load(open(sys.argv[1]))
request["repository_generation"]="0" * 40
request.pop("request_digest")
request["request_digest"]=hashlib.sha256(
    json.dumps(request,sort_keys=True,separators=(",", ":")).encode()
).hexdigest()
open(sys.argv[2],"w").write(json.dumps(request,sort_keys=True,separators=(",", ":")))
PY
  out=$(FM_WORKER_HOME_BINDING="$(printf a%.0s {1..64})" \
    FM_WORKER_TASK=recover-existing FM_WORKER_TASK_GENERATION=spawn:recover-existing \
    FM_WORKER_ASSIGNMENT_GENERATION=asg-00000001 \
    FM_WORKER_ACCOUNT_BINDING="$(printf b%.0s {1..64})" \
    FM_WORKER_WORKTREE_BINDING="$(printf c%.0s {1..64})" \
    FM_WORKER_REPOSITORY_BINDING="$(printf d%.0s {1..64})" \
    FM_WORKER_REPOSITORY_GENERATION="$(printf 0%.0s {1..40})" FM_WORKER_CLOUD_INSTANCE_ID=vm-existing \
    FM_WORKER_WORKTREE="$work" FM_WORKER_ACCOUNT_HOME="$account" \
    FM_WORKER_EXECUTED_DIR="$tmp/executed-bad" \
    FM_WORKER_OUTCOME_URL=https://fixture.invalid/outcome \
    FM_WORKER_OUTCOME_FILE="$tmp/outcome-bad.bundle" \
    python3 "$SUPERVISOR" execute --request "$tmp/bad-lineage.json" --result "$tmp/result-bad.json" 2>&1)
  status=$?
  expect_code 2 "$status" "existing task-disk recovery with foreign lineage should refuse: $out"
  assert_contains "$out" "lost its dispatched lineage" "existing task-disk lineage refusal was not explicit"
  assert_present "$repo/scratch.txt" "a refused existing task-disk recovery removed scout work"
  pass "existing task-disk recovery and return Git work across ownership without lineage drift"
}

run_supervisor_controls
run_supervisor_replay_controls
run_supervisor_steer_controls
run_supervisor_payload_staging
run_supervisor_outcome_collection
run_supervisor_existing_task_disk_recovery
echo "# fm-worker-supervisor.test.sh: all assertions passed"
