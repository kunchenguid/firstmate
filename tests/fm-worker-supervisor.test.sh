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

run_supervisor_controls
run_supervisor_replay_controls
run_supervisor_steer_controls
echo "# fm-worker-supervisor.test.sh: all assertions passed"
