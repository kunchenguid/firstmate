#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-no-mistakes-worker"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-worker)
HOME_DIR="$TMP_ROOT/home"
SOURCE="$TMP_ROOT/source"
PAYLOAD="$TMP_ROOT/payload"
FAKE="$TMP_ROOT/fake-lifecycle"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/accounts" "$SOURCE" "$PAYLOAD" "$TMP_ROOT/account"
chmod 700 "$HOME_DIR" "$HOME_DIR/state" "$HOME_DIR/accounts" "$TMP_ROOT/account"

git -C "$SOURCE" init -q
git -C "$SOURCE" config user.name fixture
git -C "$SOURCE" config user.email fixture@example.invalid
printf 'base\n' > "$SOURCE/file.txt"
git -C "$SOURCE" add file.txt
git -C "$SOURCE" commit -qm base
HEAD_SHA=$(git -C "$SOURCE" rev-parse HEAD)
git -C "$SOURCE" bundle create "$PAYLOAD/repo.bundle" HEAD
printf 'review this exact head\n' > "$PAYLOAD/brief.md"
chmod 600 "$PAYLOAD"/*
printf 'sealed-runtime-fixture\n' > "$TMP_ROOT/runtime.tar.gz"
chmod 600 "$TMP_ROOT/runtime.tar.gz"

cat > "$FAKE" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).parent
state_path = root / "fake-state.json"
complete = root / "complete"
log = root / "calls.log"
with log.open("a") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")
args = sys.argv[1:]
command = args[0]
def value(name):
    return args[args.index(name) + 1]
def canonical(item):
    return json.dumps(item, sort_keys=True, separators=(",", ":")).encode()
def run(*argv, input=None, env=None):
    result = subprocess.run(argv, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if result.returncode:
        raise SystemExit(result.stderr.decode())
    return result.stdout.decode().strip()
if command == "request":
    state = {"task": value("--task"), "generation": value("--task-generation")}
    state_path.write_text(json.dumps(state))
    complete.unlink(missing_ok=True)
    print("queued")
elif command == "reconcile":
    print("converged")
elif command == "status":
    state = json.loads(state_path.read_text())
    placements = [] if complete.exists() else [{
        "task": state["task"], "task_generation": state["generation"],
        "status": "assigned", "assignment_generation": "asg-00000001",
        "account_home": str(root / "account"),
    }]
    print(json.dumps({"account_placements": placements}, separators=(",", ":")))
elif command == "execute":
    request_digest = "d" * 64
    payload = Path(value("--payload-dir"))
    outcome_dir = Path(value("--outcome-dir"))
    outcome_dir.mkdir(exist_ok=True)
    if (root / "mode").read_text().strip() == "missing":
        result = {
            "request_digest": request_digest, "result_digest": "e" * 64,
            "service_return_present": False, "step_outcome_sha256": "",
            "exit_code": 125,
        }
        print(json.dumps(result, separators=(",", ":")))
        raise SystemExit(0)
    repo = root / "guest-repo"
    if repo.exists():
        subprocess.run(["rm", "-rf", str(repo)], check=True)
    run("git", "clone", "--quiet", str(payload / "repo.bundle"), str(repo))
    head = run("git", "-C", str(repo), "rev-parse", "HEAD")
    mode = (root / "mode").read_text().strip()
    output_head = head
    outcome_commits = 0
    if mode == "test-repair":
        (repo / "repair.txt").write_text("repair\n")
        run("git", "-C", str(repo), "add", "repair.txt")
        author = dict(os.environ)
        author.update({
            "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        })
        run("git", "-C", str(repo), "commit", "-m", "fix: fixture", env=author)
        output_head = run("git", "-C", str(repo), "rev-parse", "HEAD")
        outcome_commits = 1
    step = {
        "schema": "no-mistakes.worker-step-outcome/v1",
        "step": "test" if mode == "test-repair" else "review",
        "needs_approval": False, "auto_fixable": False, "exit_code": 0,
        "skipped": False, "skip_remaining": False,
    }
    if mode != "test-repair":
        step["review_approved_head_sha"] = output_head
    step_body = canonical(step) + b"\n"
    manifest = {
        "schema": "fm.no-mistakes-worker-return/v1",
        "task": value("--task"), "task_generation": value("--task-generation"),
        "assignment_generation": value("--assignment-generation"),
        "request_digest": request_digest, "repository_generation": head,
        "outcome_commits": outcome_commits, "outcome_tip": output_head,
        "step_outcome_sha256": hashlib.sha256(step_body).hexdigest(),
    }
    manifest_body = canonical(manifest) + b"\n"
    step_blob = run("git", "-C", str(repo), "hash-object", "-w", "--stdin", input=step_body).strip()
    manifest_blob = run("git", "-C", str(repo), "hash-object", "-w", "--stdin", input=manifest_body).strip()
    tree = run(
        "git", "-C", str(repo), "mktree",
        input=("100644 blob {}\tmanifest.json\n100644 blob {}\tstep-outcome.json\n".format(
            manifest_blob, step_blob)).encode(),
    )
    author = dict(os.environ)
    author.update({
        "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
        "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
    })
    commit = run(
        "git", "-C", str(repo), "commit-tree", tree, "-p", head,
        input=b"return\n", env=author,
    )
    return_ref = "refs/fm-return/" + request_digest[:32]
    run("git", "-C", str(repo), "update-ref", return_ref, commit)
    bundle_refs = [return_ref]
    if outcome_commits:
        outcome_ref = "refs/fm-outcome/" + request_digest[:32]
        run("git", "-C", str(repo), "update-ref", outcome_ref, output_head)
        bundle_refs.append(outcome_ref)
    run(
        "git", "-C", str(repo), "bundle", "create", str(outcome_dir / "outcome.bundle"),
        *bundle_refs, "^" + head,
    )
    outcome_sha = hashlib.sha256((outcome_dir / "outcome.bundle").read_bytes()).hexdigest()
    result = {
        "request_digest": request_digest, "result_digest": "e" * 64,
        "service_return_present": True, "return_present": True,
        "return_ref": return_ref, "return_commit": commit,
        "return_manifest_sha256": hashlib.sha256(manifest_body).hexdigest(),
        "step_outcome_sha256": hashlib.sha256(step_body).hexdigest(),
        "outcome_sha256": outcome_sha, "outcome_tip": output_head, "exit_code": 0,
    }
    print(json.dumps(result, separators=(",", ":")))
elif command == "service-complete":
    complete.touch()
    print("released")
else:
    raise SystemExit("unsupported fake lifecycle command " + command)
PY
chmod 755 "$FAKE"
mkdir -p "$TMP_ROOT/account"

python3 - "$ROOT" <<'PY' || fail "no-mistakes role is not wired into the real lifecycle contract"
import contextlib
import importlib.util
import pathlib
import sys
from types import SimpleNamespace
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("lifecycle", root / "bin/fm-worker-lifecycle.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
bounds, required = module.payload_contract("no-mistakes")
assert set(bounds) == {"repo.bundle", "brief.md", "runtime.tar.gz"}
assert required == ("repo.bundle", "brief.md", "runtime.tar.gz")
bindings = {
    "home_binding": "1" * 64, "task": "service-task", "task_generation": "service-gen",
    "account_binding": "2" * 64, "worktree_binding": "3" * 64,
    "repository_binding": "4" * 64, "repository_generation": "5" * 40,
}
execution = {
    "request_digest": "6" * 64, "result_digest": "7" * 64,
    "assignment_generation": "asg-1",
}
state = module.FencedState({
    "queue": {"service-task@service-gen": {
        "task": "service-task", "task_generation": "service-gen", "status": "assigned",
        "role": "no-mistakes", "slot": 1,
    }},
    "workers": {"1": {
        "role": "no-mistakes", "assignment_generation": "asg-1", "bindings": bindings,
        "cloud_instance_id": "vm-1", "resources": {name: {"id": name, "immutable_id": name + "-id"}
            for name in module.REQUIRED_RESOURCE_KINDS}, "last_execution_digest": "7" * 64,
        "release_proof": None,
    }},
    "executions": {"6" * 64: execution},
})
@contextlib.contextmanager
def unlocked(_env):
    yield
module.controller_lock = unlocked
module.load_state = lambda _env: state
module.save_state = lambda _env, _state: None
module.command_service_complete(
    {"subscription": "sub"},
    SimpleNamespace(
        confirm_subscription="sub", request_digest="6" * 64, task="service-task",
        task_generation="service-gen", assignment_generation="asg-1",
    ),
)
proof = state["workers"]["1"]["release_proof"]
unsigned = dict(proof)
assert unsigned.pop("proof_digest") == module.digest_value(unsigned)
assert state["queue"]["service-task@service-gen"]["status"] == "releasing"
PY
pass "lifecycle assigns a bounded role and releases only from its exact stored execution"

python3 - "$ROOT" "$TMP_ROOT" <<'PY' \
  || fail "guest supervisor did not re-verify the sealed no-mistakes runtime"
import hashlib
import importlib.util
import io
import json
import pathlib
import sys
import tarfile
root, temporary = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("supervisor", root / "bin/fm-worker-supervisor.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
binary = b"#!/bin/sh\nexit 0\n"
files = {
    "bin/no-mistakes": binary, "bin/node": binary, "bin/pi": binary,
    "lib/pi/dist/cli.js": b"export {};\n",
    "extensions/pi-openai-fast-mode/src/index.ts": b"export default () => {};\n",
    "extensions/fast-mode-all-codex-accounts.ts": b"export default () => {};\n",
    "extensions/pi-ketch/src/index.ts": b"export default () => {};\n",
}
manifest = {
    "schema": "fm.azure-validation-runtime/v1", "provider": "pi",
    "no_mistakes_version": "test-1", "no_mistakes_source_commit": "1" * 40,
    "owner_decision_protocol": "fm.azure-validation-owner-decision/v1",
    "no_mistakes_path": "bin/no-mistakes", "provider_path": "bin/pi",
    "gh_path": "", "node_path": "bin/node", "gh_axi_path": "",
    "gh_axi_entrypoint": "", "gh_axi_closure": [],
    "files": [{"path": name, "digest": "sha256:" + hashlib.sha256(body).hexdigest()}
              for name, body in sorted(files.items())],
}
manifest_body = json.dumps(manifest, separators=(",", ":")).encode() + b"\n"
archive_path = temporary / "verified-runtime.tar.gz"
with tarfile.open(archive_path, "w:gz") as archive:
    entries = [("runtime.json", manifest_body, 0o644)] + [
        (name, body, 0o755 if name in ("bin/no-mistakes", "bin/node", "bin/pi") else 0o644)
        for name, body in sorted(files.items())
    ]
    for name, body, mode in entries:
        info = tarfile.TarInfo(name)
        info.size = len(body)
        info.mode = mode
        archive.addfile(info, io.BytesIO(body))
target = temporary / "verified-runtime"
module.stage_no_mistakes_runtime(archive_path, target, enforce_linux=False)
assert (target / "bin/no-mistakes").read_bytes() == binary
assert (target / "bin/no-mistakes").stat().st_mode & 0o111
PY
pass "guest supervisor re-verifies the sealed runtime inventory and executable"

RUNTIME_SHA=$(shasum -a 256 "$TMP_ROOT/runtime.tar.gz" | awk '{print $1}')
cat > "$TMP_ROOT/config.json" <<JSON
{"schema":"fm.no-mistakes-worker-wrapper-config/v1","fm_home":"$HOME_DIR","account_pool_home":"$HOME_DIR/accounts","runtime_bundle":"$TMP_ROOT/runtime.tar.gz","runtime_bundle_sha256":"$RUNTIME_SHA","lifecycle_path":"$FAKE","lifecycle_env":{"FM_AZURE_SUBSCRIPTION_ID":"11111111-1111-4111-8111-111111111111","FM_AZURE_DEPLOYMENT_GENERATION":"dep-fixture","FM_AZURE_OWNER_TAG":"owner","FM_AZURE_NAMING_PREFIX":"fixture","FM_AZURE_STORAGE_NAME":"fixturestorage"},"assignment_timeout_seconds":30,"cleanup_timeout_seconds":30,"poll_seconds":1,"wall_seconds":60}
JSON
chmod 600 "$TMP_ROOT/config.json"

write_request() {
  python3 - "$1" "$PAYLOAD" "$HEAD_SHA" "$2" "${3:-review}" "${4:-review}" <<'PY'
import hashlib, json, pathlib, sys
target, payload = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
head, job, step, kind = sys.argv[3:7]
bundle = (payload / "repo.bundle").read_bytes()
brief = (payload / "brief.md").read_bytes()
request = {
  "schema":"no-mistakes.firstmate-worker-request/v1", "job_id":job,
  "run_id":"run-1", "step_result_id":"step-1", "step":step, "kind":kind, "round":0,
  "desired_head_sha":head, "input_digest":hashlib.sha256(brief).hexdigest(),
  "owner_decision_head":"", "desired_generation":1, "attempt":1, "lease_fence":1,
  "lease_owner":"owner-1", "source_ref":"HEAD",
  "source_bundle_sha256":hashlib.sha256(bundle).hexdigest(), "source_bundle_size":len(bundle),
  "guest_argv":["no-mistakes","worker","run","--role",kind,"--brief","brief.md","--result","outcome.json"],
  "expected_result_schema":"no-mistakes.firstmate-worker-result/v1",
  "expected_firstmate_return":"fm.worker-return-contract/v1"
}
target.write_text(json.dumps(request, separators=(",", ":")))
PY
  chmod 600 "$1"
}

printf 'ok\n' > "$TMP_ROOT/mode"
write_request "$TMP_ROOT/request.json" job-success
"$WRAPPER" --config "$TMP_ROOT/config.json" execute \
  --request "$TMP_ROOT/request.json" --payload "$PAYLOAD" \
  --result "$TMP_ROOT/result.json" --outcome "$TMP_ROOT/outcome.bundle" \
  --step-outcome "$TMP_ROOT/step-outcome.json" \
  || fail "the high-level worker wrapper rejected a complete semantic return"
python3 - "$TMP_ROOT/result.json" "$TMP_ROOT/step-outcome.json" "$HEAD_SHA" <<'PY' \
  || fail "the wrapper did not emit the closed digest-bound success"
import hashlib, json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
step = pathlib.Path(sys.argv[2]).read_bytes()
assert result["schema"] == "no-mistakes.firstmate-worker-result/v1"
assert result["step"] == "review"
assert result["outcome"] == "succeeded" and result["output_head_sha"] == sys.argv[3]
assert result["step_outcome_sha256"] == hashlib.sha256(step).hexdigest()
assert "return_ref" not in result and "return_bundle_sha256" not in result
assert json.loads(step)["review_approved_head_sha"] == sys.argv[3]
PY
assert_contains "$(cat "$TMP_ROOT/calls.log")" "request --task" "wrapper bypassed lifecycle request"
assert_contains "$(cat "$TMP_ROOT/calls.log")" "--role no-mistakes" "wrapper did not request the service role"
assert_contains "$(cat "$TMP_ROOT/calls.log")" "service-complete" "wrapper did not release from execution evidence"
pass "wrapper allocates, executes, returns semantic evidence, and cleans through lifecycle"

printf 'test-repair\n' > "$TMP_ROOT/mode"
write_request "$TMP_ROOT/request-test-repair.json" job-test-repair test repair
"$WRAPPER" --config "$TMP_ROOT/config.json" execute \
  --request "$TMP_ROOT/request-test-repair.json" --payload "$PAYLOAD" \
  --result "$TMP_ROOT/result-test-repair.json" --outcome "$TMP_ROOT/outcome-test-repair.bundle" \
  --step-outcome "$TMP_ROOT/step-outcome-test-repair.json" \
  || fail "a test repair was not transported as repair kind plus test step"
python3 - "$TMP_ROOT/result-test-repair.json" "$TMP_ROOT/step-outcome-test-repair.json" \
  "$TMP_ROOT/outcome-test-repair.bundle" "$HEAD_SHA" <<'PY' \
  || fail "test repair lost its canonical step or descendant bundle"
import hashlib, json, pathlib, subprocess, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
step = json.loads(pathlib.Path(sys.argv[2]).read_text())
bundle = pathlib.Path(sys.argv[3])
assert result["kind"] == "repair" and result["step"] == "test"
assert step["step"] == "test" and step.get("review_approved_head_sha", "") == ""
assert result["output_head_sha"] != sys.argv[4]
assert result["return_bundle_sha256"] == hashlib.sha256(bundle.read_bytes()).hexdigest()
heads = subprocess.check_output(["git", "bundle", "list-heads", str(bundle)], text=True).splitlines()
assert heads == [result["output_head_sha"] + " " + result["return_ref"]], heads
PY
pass "repair kind preserves canonical test-step semantics and returns one descendant ref"

printf 'missing\n' > "$TMP_ROOT/mode"
write_request "$TMP_ROOT/request-failure.json" job-failure
"$WRAPPER" --config "$TMP_ROOT/config.json" execute \
  --request "$TMP_ROOT/request-failure.json" --payload "$PAYLOAD" \
  --result "$TMP_ROOT/result-failure.json" --outcome "$TMP_ROOT/outcome-failure.bundle" \
  --step-outcome "$TMP_ROOT/step-outcome-failure.json" \
  || fail "a guest executor failure did not return its structured transport failure"
python3 - "$TMP_ROOT/result-failure.json" <<'PY' \
  || fail "missing guest semantic evidence was not failed closed"
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["outcome"] == "failed"
assert result["error_category"] == "guest_execution" and result["retryable"] is True
assert result["output_head_sha"] == ""
assert "step_outcome_sha256" not in result
PY
[ ! -e "$TMP_ROOT/step-outcome-failure.json" ] \
  || fail "a failed guest fabricated a semantic step outcome"
pass "guest failure returns a closed retryable result instead of disappearing as exit 125"

fm_assert_no_cloud_reach "fm-no-mistakes-worker tests reached real cloud tooling"
echo "all fm-no-mistakes-worker tests passed"
