#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_return_case() {  # <name> <id> <kind> <report yes|no|empty> <scratch yes|no> <commit yes|no>
  local name=$1 id=$2 kind=$3 report=$4 scratch=$5 commit=$6
  local visuals=${7:-no}
  local root home repo worker state
  root=$(fm_test_tmproot "fm-cloud-result-$name")
  home="$root/home"
  repo="$root/repo"
  worker="$root/worker"
  state="$home/state"
  mkdir -p "$state/$id.cloud-outcome" "$home/data/$id" "$worker/task" "$worker/account"
  fm_git_init_commit "$repo"
  git clone --quiet "$repo" "$worker/task/repo"
  fm_git_identity "$worker/task/repo"
  git -C "$worker/task/repo" checkout --quiet --detach
  python3 - "$ROOT/bin/fm-worker-supervisor.py" "$root" "$id" "$kind" "$report" "$scratch" "$commit" "$visuals" <<'PY'
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

supervisor_path, root_text, task, kind, with_report, with_scratch, with_commit, with_visuals = sys.argv[1:]
root = Path(root_text)
spec = importlib.util.spec_from_file_location("worker_supervisor", supervisor_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
repo = root / "worker" / "task" / "repo"
base = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
if with_commit == "yes":
    (repo / "cloud-change.txt").write_text("returned ship change\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "cloud-change.txt"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "--quiet", "-m", "returned ship change"], check=True)
if with_scratch == "yes":
    (repo / "scratch.txt").write_text("uncommitted scout scratch\n", encoding="utf-8")
return_root = root / "worker" / "task" / ".fm-return"
report_name = "completion.md" if kind == "ship" else "report.md"
report_path = return_root / "data" / task / report_name
status_path = return_root / "state" / (task + ".status")
status_path.parent.mkdir(parents=True, exist_ok=True)
status_path.write_text("working: remote task ran\n", encoding="utf-8")
if with_report == "yes":
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        "## Summary\n\nReturned task outcome.\n\n"
        "## What changed\n\nThe requested work ran.\n\n"
        "## Verification\n\nThe fixture exercised the return path.\n\n"
        "## Visual evidence\n\nNone.\n\n"
        "## Artifacts\n\nThe return bundle is retained.\n\n"
        "## Follow-ups\n\nNone.\n",
        encoding="utf-8",
    )
elif with_report == "empty":
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        "## Summary\n\n"
        "## What changed\n\nThe requested work ran.\n\n"
        "## Verification\n\nThe fixture exercised the return path.\n\n"
        "## Visual evidence\n\nNone.\n\n"
        "## Artifacts\n\nThe return bundle is retained.\n\n"
        "## Follow-ups\n\nNone.\n",
        encoding="utf-8",
    )
if with_visuals == "yes":
    visual_path = return_root / "data" / task / "visuals" / "nested" / "proof.txt"
    visual_path.parent.mkdir(parents=True, exist_ok=True)
    visual_path.write_text("returned visual evidence\n", encoding="utf-8")
request = {
    "schema": "fm.worker-execution/v1",
    "home_binding": "a" * 64,
    "task": task,
    "task_generation": "spawn:gen-1",
    "assignment_generation": "asg-00000001",
    "account_binding": "b" * 64,
    "worktree_binding": "c" * 64,
    "repository_binding": "d" * 64,
    "repository_generation": base,
    "cloud_instance_id": "vm-one",
    "argv": ["/bin/true"],
    "wall_seconds": 60,
    "outcome_expected": True,
    "payload_files": {},
    "return_contract": {
        "schema": "fm.worker-return-contract/v1",
        "kind": kind,
        "report_required": True,
        "report_path": "data/{}/{}".format(task, report_name),
        "status_path": "state/{}.status".format(task),
        "visuals_path": "data/{}/visuals".format(task),
        "branch": "fm/{}".format(task) if kind == "ship" else "",
    },
}
request["request_digest"] = hashlib.sha256(
    json.dumps(request, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
(root / "request.json").write_text(json.dumps(request, sort_keys=True, separators=(",", ":")) + "\n")
sink = root / "home" / "state" / (task + ".cloud-outcome") / "outcome.bundle"
os.environ["FM_WORKER_OUTCOME_URL"] = "https://fixture.invalid/outcome"
os.environ["FM_WORKER_OUTCOME_FILE"] = str(sink)
outcome = module.collect_outcome(request, repo, root / "worker" / "task")
result = {
    "schema": "fm.worker-execution-result/v1",
    **outcome,
    "streams_persisted": True,
    "request_digest": request["request_digest"],
    "task": task,
    "task_generation": "spawn:gen-1",
    "assignment_generation": "asg-00000001",
    "cloud_instance_id": "vm-one",
    "repository_binding": "d" * 64,
    "repository_generation": base,
    "exit_code": 0,
    "timed_out": False,
    "stdout_sha256": hashlib.sha256(b"").hexdigest(),
    "stderr_sha256": hashlib.sha256(b"").hexdigest(),
    "stdout_truncated": False,
    "stderr_truncated": False,
}
result["result_digest"] = hashlib.sha256(
    json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
(root / "home" / "state" / (task + ".worker-result.json")).write_text(
    json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8"
)
PY
  printf '%s\n' "$repo" > "$state/$id.cloud-worktree"
  cat > "$state/$id.meta" <<EOF
window=fm-$id
worktree=$repo
kind=$kind
placement=azure
generation_id=spawn:gen-1
report_required=1
EOF
  printf '%s|%s|%s\n' "$root" "$home" "$repo"
}

run_collect() {  # <home> <id>
  python3 "$ROOT/bin/fm-cloud-result.py" collect --state "$1/state" --task "$2" \
    --task-generation spawn:gen-1 --assignment-generation asg-00000001
}

test_ship_success_and_replay() {
  local record root home repo id first_head second_head out
  id=cloud-return-ship
  record=$(make_return_case ship "$id" ship yes no yes)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  out=$(run_collect "$home" "$id" 2>&1) || fail "ship return should localize: $out"
  assert_contains "$out" "done: cloud outcome returned" "ship return did not synthesize done"
  assert_present "$repo/cloud-change.txt" "ship commit was not landed"
  test "$(git -C "$repo" symbolic-ref --quiet HEAD)" = "refs/heads/fm/$id" \
    || fail "ship branch was not reconstructed and checked out"
  assert_grep '## Summary' "$home/data/$id/completion.md" "ship completion report was not transported"
  assert_grep 'working: remote task ran' "$home/state/$id.status" "remote status trail was not transported"
  assert_grep 'done: cloud outcome returned to local custody' "$home/state/$id.status" "local done status was not synthesized"
  printf 'local continuation\n' > "$repo/local-continuation.txt"
  git -C "$repo" add local-continuation.txt
  git -C "$repo" commit --quiet -m "local continuation"
  first_head=$(git -C "$repo" rev-parse HEAD)
  out=$(run_collect "$home" "$id" 2>&1) || fail "duplicate ship return should preserve the continued branch: $out"
  second_head=$(git -C "$repo" rev-parse HEAD)
  test "$first_head" = "$second_head" || fail "duplicate replay moved the task branch"
  test "$(grep -c '^done: cloud outcome returned to local custody$' "$home/state/$id.status")" -eq 1 \
    || fail "duplicate replay appended a second terminal status"
  pass "ship return reconstructs and preserves its continued branch, transports deliverables, synthesizes status, and replays idempotently"
}

test_scout_success_with_uncommitted_scratch() {
  local record root home repo id out
  id=cloud-return-scout
  record=$(make_return_case scout "$id" scout yes yes no)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  out=$(run_collect "$home" "$id" 2>&1) || fail "scout return should localize: $out"
  assert_contains "$out" "done: cloud outcome returned" "valid scout scratch was not a successful return"
  assert_present "$home/data/$id/report.md" "scout report was not transported"
  assert_present "$home/data/$id/cloud-scratch-untracked.tar" "uncommitted scout scratch was not retained"
  assert_grep 'done: cloud outcome returned to local custody' "$home/state/$id.status" "scout terminal status was not synthesized"
  local first_digest
  first_digest=$(shasum -a 256 "$home/state/$id.cloud-outcome/outcome.bundle" | awk '{print $1}')
  rm -f "$home/state/$id.cloud-outcome/outcome.bundle"
  python3 - "$ROOT/bin/fm-worker-supervisor.py" "$root" "$id" <<'PY' \
    || fail "a replay did not re-upload a return-only scout bundle"
import importlib.util
import json
import os
from pathlib import Path
import sys
module_path, root_text, task = sys.argv[1:]
root = Path(root_text)
spec = importlib.util.spec_from_file_location("worker_supervisor", module_path)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
request = json.loads((root / "request.json").read_text())
result = json.loads((root / "home" / "state" / (task + ".worker-result.json")).read_text())
os.environ["FM_WORKER_OUTCOME_URL"] = "https://fixture.invalid/outcome"
os.environ["FM_WORKER_OUTCOME_FILE"] = str(root / "home" / "state" / (task + ".cloud-outcome") / "outcome.bundle")
assert result["outcome_present"] is False and result["return_present"] is True
assert module.replay_outcome_upload(request, root / "worker" / "task", result) is True
PY
  test "$(shasum -a 256 "$home/state/$id.cloud-outcome/outcome.bundle" | awk '{print $1}')" = "$first_digest" \
    || fail "duplicate scout replay uploaded different return bytes"
  pass "scout return preserves uncommitted-only scratch and replays its report bundle exactly"
}

test_absent_report_blocks_collection() {
  local record root home repo id out status
  id=cloud-return-no-report
  record=$(make_return_case absent-report "$id" scout no no no)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  out=$(run_collect "$home" "$id" 2>&1)
  status=$?
  expect_code 2 "$status" "an absent report should block collection: $out"
  assert_contains "$out" "required worker report was absent or invalid" \
    "absent report refusal did not name the missing deliverable"
  assert_absent "$home/state/$id.status" "absent report emitted a local terminal status"
  assert_absent "$home/data/$id/report.md" "absent report fabricated an authoritative report"
  assert_absent "$home/data/$id/cloud-return.json" "absent report published a release manifest"
  pass "an absent required report blocks collection without authoritative local evidence"
}

test_empty_report_section_blocks_collection() {
  local record root home repo id out status
  id=cloud-return-empty-report-section
  record=$(make_return_case empty-report-section "$id" scout empty no no)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  out=$(run_collect "$home" "$id" 2>&1)
  status=$?
  expect_code 2 "$status" "an empty report section should block collection: $out"
  assert_contains "$out" "required worker report was absent or invalid" \
    "empty report section refusal did not identify the invalid report"
  assert_present "$home/data/$id/cloud-return-report.invalid.md" \
    "invalid returned report bytes were not retained as diagnostic evidence"
  assert_absent "$home/state/$id.status" "invalid report emitted a local terminal status"
  assert_absent "$home/data/$id/report.md" "invalid report fabricated an authoritative report"
  assert_absent "$home/data/$id/cloud-return.json" "invalid report published a release manifest"
  pass "an invalid returned report is diagnostic only and cannot authorize release"
}

test_local_divergence_retains_custody() {
  local record root home repo id out status
  id=cloud-return-diverged
  record=$(make_return_case divergence "$id" ship yes no yes)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  printf 'local divergence\n' > "$repo/local-divergence.txt"
  git -C "$repo" add local-divergence.txt
  git -C "$repo" commit --quiet -m "local divergence"
  out=$(run_collect "$home" "$id" 2>&1)
  status=$?
  expect_code 2 "$status" "a diverged local worktree should refuse landing: $out"
  assert_contains "$out" "local worktree diverged" "divergence refusal was not explicit"
  assert_absent "$repo/cloud-change.txt" "divergent local history was overwritten"
  if [ -f "$home/state/$id.status" ] && grep -E '^(done|failed):' "$home/state/$id.status" >/dev/null; then
    fail "divergence emitted a terminal status before branch custody"
  fi
  local request_digest
  request_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_digest"][:32])' \
    "$home/state/$id.worker-result.json")
  git -C "$repo" show-ref --verify --quiet "refs/fm-cloud-return/$id/$request_digest/outcome" \
    || fail "divergence did not retain the returned outcome in a custody ref"
  pass "local divergence is retained without overwrite or premature terminal state"
}

test_corrupt_bundle_refuses_before_artifacts() {
  local record root home repo id out status
  id=cloud-return-corrupt
  record=$(make_return_case corruption "$id" ship yes no yes)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  printf 'truncated' > "$home/state/$id.cloud-outcome/outcome.bundle"
  out=$(run_collect "$home" "$id" 2>&1)
  status=$?
  expect_code 2 "$status" "a corrupt return bundle should refuse: $out"
  assert_contains "$out" "differs from the digest-bound result" "corrupt return refusal did not name the digest"
  assert_absent "$home/data/$id/completion.md" "a corrupt return published a completion report"
  assert_absent "$home/state/$id.status" "a corrupt return emitted terminal status"
  pass "truncated or corrupt return bytes cannot publish artifacts or terminal state"
}

test_task_artifact_root_symlink_is_refused() {
  local record root home repo id out status escaped
  id=cloud-return-task-root-symlink
  record=$(make_return_case task-root-symlink "$id" scout yes no no)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  escaped="$root/escaped-task-root"
  rmdir "$home/data/$id"
  mkdir "$escaped"
  ln -s "$escaped" "$home/data/$id"
  out=$(run_collect "$home" "$id" 2>&1)
  status=$?
  expect_code 2 "$status" "a redirected task artifact root should be refused: $out"
  assert_contains "$out" "local artifact directory is redirected" \
    "task artifact root refusal did not identify the redirected directory"
  assert_absent "$escaped/report.md" "report escaped through the task artifact root symlink"
  assert_absent "$home/state/$id.status" "redirected task artifact root emitted terminal status"
  pass "a task artifact root symlink cannot redirect returned files"
}

test_visual_parent_symlink_is_refused_before_writes() {
  local record root home repo id out status escaped
  id=cloud-return-visual-parent-symlink
  record=$(make_return_case visual-parent-symlink "$id" scout yes no no yes)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  escaped="$root/escaped-visual-root"
  mkdir "$escaped"
  ln -s "$escaped" "$home/data/$id/visuals"
  out=$(run_collect "$home" "$id" 2>&1)
  status=$?
  expect_code 2 "$status" "a redirected visual parent should be refused: $out"
  assert_contains "$out" "local artifact directory is redirected" \
    "visual parent refusal did not identify the redirected directory"
  assert_absent "$escaped/nested/proof.txt" "visual escaped through a parent-directory symlink"
  assert_absent "$home/data/$id/report.md" "visual redirect was detected after artifact writes began"
  assert_absent "$home/data/$id/cloud-return.json" "visual redirect published a release manifest"
  assert_absent "$home/state/$id.status" "redirected visual parent emitted terminal status"
  pass "a visual parent symlink is refused before any artifact is installed"
}

test_cloud_custody_authority_reads_localized_return() {
  local record root home repo id out
  id=cloud-return-authority
  record=$(make_return_case authority "$id" ship yes no yes)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  out=$(run_collect "$home" "$id" 2>&1) || fail "authority fixture should localize: $out"
  python3 - "$ROOT/bin/fm-worker-authority.py" "$home" "$repo" "$id" <<'PY' \
    || fail "cloud landing authority did not prove localized custody"
import importlib.util
import json
from pathlib import Path
import sys

module_path, home_text, repo_text, task = sys.argv[1:]
spec = importlib.util.spec_from_file_location("worker_authority", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = Path(home_text)
result = json.loads((home / "state" / (task + ".worker-result.json")).read_text())
evidence = module.cloud_return_evidence(
    home, task, "spawn:gen-1", "asg-00000001", "ship", Path(repo_text),
    result["repository_generation"],
)
assert evidence and b'"outcome_commits":1' in evidence, evidence
PY
  pass "release authority proves exact local bundle, report, status, and task-branch custody"
}

test_lifecycle_accepts_only_exact_return_identity() {
  local record root home repo id
  id=cloud-return-lifecycle
  record=$(make_return_case lifecycle "$id" ship yes no yes)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  python3 - "$ROOT/bin/fm-worker-lifecycle.py" "$home" "$id" <<'PY' \
    || fail "lifecycle did not enforce the exact return identity"
import copy
import importlib.util
import json
from pathlib import Path
import sys

module_path, home_text, task = sys.argv[1:]
spec = importlib.util.spec_from_file_location("worker_lifecycle", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
result = json.loads((Path(home_text) / "state" / (task + ".worker-result.json")).read_text())
action = {
    "type": "execute",
    "slot": 1,
    "request_digest": result["request_digest"],
    "request": {"outcome_expected": True, "return_contract": {"schema": "fm.worker-return-contract/v1"}},
}
worker = {
    "assignment_generation": result["assignment_generation"],
    "cloud_instance_id": result["cloud_instance_id"],
    "bindings": {
        "task": result["task"],
        "task_generation": result["task_generation"],
        "repository_binding": result["repository_binding"],
        "repository_generation": result["repository_generation"],
    },
}
state = {"workers": {"1": copy.deepcopy(worker)}, "executions": {}}
module.apply_action_result({}, state, action, {"execution": result})
assert result["request_digest"] in state["executions"]
changed = dict(result)
changed["return_ref"] += ":refs/heads/injected"
changed.pop("result_digest")
changed["result_digest"] = module.digest_value(changed)
try:
    module.apply_action_result(
        {}, {"workers": {"1": copy.deepcopy(worker)}, "executions": {}},
        action, {"execution": changed},
    )
except module.LifecycleError as exc:
    assert "return ref is not exact" in str(exc), exc
else:
    raise AssertionError("an inexact return ref was durably accepted")
PY
  pass "lifecycle records the exact return and refuses a guest-selected refspec"
}

test_release_authority_requires_retained_scout_scratch() {
  local record root home repo id out
  id=cloud-return-scratch-authority
  record=$(make_return_case scratch-authority "$id" scout yes yes no)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  out=$(run_collect "$home" "$id" 2>&1) || fail "scratch authority fixture should localize: $out"
  rm "$home/data/$id/cloud-scratch-untracked.tar"
  python3 - "$ROOT/bin/fm-worker-authority.py" "$home" "$repo" "$id" <<'PY' \
    || fail "release authority did not refuse missing scout scratch custody"
import importlib.util
import json
from pathlib import Path
import sys

module_path, home_text, repo_text, task = sys.argv[1:]
spec = importlib.util.spec_from_file_location("worker_authority", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = Path(home_text)
result = json.loads((home / "state" / (task + ".worker-result.json")).read_text())
try:
    module.cloud_return_evidence(
        home, task, "spawn:gen-1", "asg-00000001", "scout", Path(repo_text),
        result["repository_generation"],
    )
except module.AuthorityError as exc:
    assert "scratch custody is absent" in str(exc), exc
else:
    raise AssertionError("missing scout scratch custody was accepted")
PY
  pass "release authority retains the worker when localized scout scratch is missing"
}

test_monitor_retries_release_and_removes_credentials() {
  local record root home repo id out
  id=cloud-return-release
  record=$(make_return_case release-retry "$id" ship yes no yes)
  IFS='|' read -r root home repo <<EOF
$record
EOF
  mkdir -p "$home/state/azure-workers" "$home/state/$id.cloud-account"
  printf '{"openai-codex":{"access":"secret"}}\n' > "$home/state/$id.cloud-account/auth.json"
  printf '{"queue":{"%s@spawn:gen-1":{"status":"assigned","assignment_generation":"asg-00000001"}}}\n' "$id" \
    > "$home/state/azure-workers/controller.json"
  cat > "$root/fake-lifecycle" <<'SH'
#!/usr/bin/env bash
set -eu
command=$1
shift
printf '%s\n' "$command" >> "$FAKE_LIFECYCLE_LOG"
case "$command" in
  authority-receipt)
    while [ $# -gt 0 ]; do
      case "$1" in --output) printf '{}\n' > "$2"; exit 0 ;; *) shift ;; esac
    done
    exit 2
    ;;
  release)
    count=$(grep -c '^release$' "$FAKE_LIFECYCLE_LOG" || true)
    [ "$count" -gt 1 ] || exit 9
    python3 - "$FM_HOME/state/azure-workers/controller.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); next(iter(s["queue"].values()))["status"]="releasing"; json.dump(s,open(p,"w"))
PY
    ;;
  reconcile)
    python3 - "$FM_HOME/state/azure-workers/controller.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); next(iter(s["queue"].values()))["status"]="complete"; json.dump(s,open(p,"w"))
PY
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$root/fake-lifecycle"
  out=$(FM_HOME="$home" FM_CLOUD_RETURN_LIFECYCLE_COMMAND="$root/fake-lifecycle" \
    FAKE_LIFECYCLE_LOG="$root/lifecycle.log" FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" "$id" spawn:gen-1 2>&1) \
    || fail "monitor should retry release to completion: $out"
  test "$(grep -c '^release$' "$root/lifecycle.log")" -eq 2 \
    || fail "monitor did not retry the failed release exactly once"
  assert_contains "$out" "release recording failed; retrying" "release retry was not visible"
  assert_contains "$out" "assignment is released" "release did not converge to complete"
  assert_absent "$home/state/$id.cloud-account/auth.json" "released return leaked its staged credential"
  assert_absent "$home/state/$id.worker-result.json" "released return kept stale convergence state"
  pass "release retries idempotently and frees the account state after local custody"
}

test_ship_success_and_replay
test_scout_success_with_uncommitted_scratch
test_absent_report_blocks_collection
test_empty_report_section_blocks_collection
test_local_divergence_retains_custody
test_corrupt_bundle_refuses_before_artifacts
test_task_artifact_root_symlink_is_refused
test_visual_parent_symlink_is_refused_before_writes
test_cloud_custody_authority_reads_localized_return
test_lifecycle_accepts_only_exact_return_identity
test_release_authority_requires_retained_scout_scratch
test_monitor_retries_release_and_removes_credentials

echo "# fm-cloud-result.test.sh: all assertions passed"
