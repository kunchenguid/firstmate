#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROVIDER="$ROOT/bin/fm-azure-worker-provider.py"

# The controller half of landing v1 (SAS minting, blob download, byte and
# digest verification) is driven here through a FAKE az BINARY rather than a
# stubbed Python seam: the real argv is built, really executed, and its real
# JSON output really parsed, so a rename, a wrong permission set, or a dropped
# verification fails here instead of live.
write_fake_az() {
  cat >"$1" <<'SH'
#!/usr/bin/env bash
# Records every invocation and answers the exact storage calls under test.
printf '%s\n' "$*" >> "$FAKE_AZ_LOG"
mode=""
container=""
name=""
file=""
permissions=""
while [ $# -gt 0 ]; do
  case "$1" in
    storage|blob) shift ;;
    show|download|generate-sas|list|upload|delete) mode=$1; shift ;;
    run-command) mode=run-command; shift ;;
    update) [ "$mode" = run-command ] && mode=run-command-update; shift ;;
    --container-name) container=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --file) file=$2; shift 2 ;;
    --permissions) permissions=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$mode" in
  show)
    # az --output json renders a scalar --query result as a bare number.
    wc -c < "$FAKE_AZ_BLOB" | tr -d ' '
    ;;
  download)
    cp "$FAKE_AZ_BLOB" "$file"
    printf '{}\n'
    ;;
  generate-sas)
    printf '"https://fixture.invalid/%s/%s?sig=fake&sp=%s"\n' "$container" "$name" "$permissions"
    ;;
  run-command-update)
    printf '{}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
SH
  chmod +x "$1"
}

run_outcome_transport() {
  local tmp bin fixture out status
  fm_test_tmproot_into tmp fm-worker-outcome-transport
  bin="$tmp/bin"
  mkdir -p "$bin" "$tmp/outcome"
  write_fake_az "$bin/az"
  fixture="$tmp/fixture.bundle"
  printf 'pretend git bundle bytes\n' > "$fixture"
  cat >"$tmp/driver.py" <<'PY'
import hashlib
import importlib.util
import sys
from pathlib import Path

provider_path, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_provider", provider_path)
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)

root = Path(tmp)
body = (root / "fixture.bundle").read_bytes()
digest = hashlib.sha256(body).hexdigest()
controller = {
    "subscription": "00000000-0000-0000-0000-000000000000",
    "resource_group": "rg-test", "prefix": "fmtest", "owner": "owner",
    "deployment_generation": "dep-one", "home_binding": "a" * 64,
}
request_digest = "b" * 64

# The blob name is bound to the request digest, so a later execute against the
# same worker cannot overwrite an uncollected outcome.
name = provider.outcome_blob_name(request_digest)
assert name == "outcome-" + "b" * 32 + ".bundle", name
try:
    provider.outcome_blob_name("not-a-digest")
    raise AssertionError("a malformed request digest must not name a blob")
except provider.ProviderError:
    pass

# The outcome SAS is create/write on exactly that one name.
uri = provider.blob_sas(controller, "fmteststorage", "state-c", name, 60, permissions="cw")
assert uri.startswith("https://") and "sp=cw" in uri and name in uri, uri
try:
    provider.blob_sas(controller, "fmteststorage", "state-c", name, 60, permissions="racwd")
    raise AssertionError("an unreviewed permission set must be refused")
except provider.ProviderError:
    pass

target = root / "outcome" / "outcome.bundle"
# Happy path: the bytes land only because size and digest match the claim.
landed = provider.download_outcome_bundle(
    controller, "fmteststorage", "state-c", name, digest, len(body), target,
)
assert landed == len(body), landed
assert target.read_bytes() == body, "the downloaded bundle is not the blob"

# A size claim that disagrees with the blob is refused BEFORE the download.
target.unlink()
try:
    provider.download_outcome_bundle(
        controller, "fmteststorage", "state-c", name, digest, len(body) + 1, target,
    )
    raise AssertionError("a size claim that differs from the blob must be refused")
except provider.ProviderError as exc:
    assert "differs from the digest-bound result claim" in str(exc), exc
assert not target.exists(), "a refused download must not leave a file"

# A digest claim that disagrees with the bytes is refused after the fetch.
try:
    provider.download_outcome_bundle(
        controller, "fmteststorage", "state-c", name, "c" * 64, len(body), target,
    )
    raise AssertionError("a digest claim that differs from the bytes must be refused")
except provider.ProviderError as exc:
    assert "differs from the digest-bound result" in str(exc), exc
assert not target.exists(), "a refused download must not leave a file"
print("OK")
PY
  out=$(PATH="$bin:$PATH" FAKE_AZ_LOG="$tmp/az.log" FAKE_AZ_BLOB="$fixture" \
    FM_AZURE_STORAGE_NAME=fmteststorage \
    python3 "$tmp/driver.py" "$PROVIDER" "$tmp" 2>&1)
  status=$?
  expect_code 0 "$status" "the outcome transport should drive the real provider: $out"
  assert_contains "$out" "OK" "the transport driver did not complete: $out"
  # The size check must really precede the download: prove it from the
  # recorded az calls, not from reading the source.
  assert_grep 'storage blob show' "$tmp/az.log" "the controller never asked the blob its size"
  python3 - "$tmp/az.log" <<'PY' || fail "the size proof does not precede the download"
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
show = next(i for i, line in enumerate(lines) if "blob show" in line)
download = next(i for i, line in enumerate(lines) if "blob download" in line)
assert show < download, lines
# Three attempts asked the blob its size; only the two whose claim matched went
# on to transfer it. The size-mismatch attempt stopped without a download,
# which is the whole point of asking first.
shows = [i for i, line in enumerate(lines) if "blob show" in line]
downloads = [i for i, line in enumerate(lines) if "blob download" in line]
assert len(shows) == 3 and len(downloads) == 2, lines
followed = [i for i in shows if any(i < d < (i + 2) for d in downloads)]
assert len(followed) == 2, ("a refused size claim still transferred the blob", lines)
PY
  assert_grep 'permissions cw' "$tmp/az.log" "the outcome SAS was not create/write scoped"
  assert_no_grep 'permissions racwd' "$tmp/az.log" "an unreviewed permission set reached the CLI"
  pass "the controller mints a scoped outcome SAS and lands only verified bytes"
}

run_outcome_transport

run_outcome_call_sites() {
  # The functions above can be perfect and still never run. This drives the
  # REAL mutate_execute so the production CALL SITES are covered: deleting the
  # download call, or the line that arms FM_WORKER_OUTCOME_URL, must fail here.
  local tmp bin fixture out status
  fm_test_tmproot_into tmp fm-worker-outcome-callsites
  bin="$tmp/bin"
  mkdir -p "$bin" "$tmp/outcome"
  write_fake_az "$bin/az"
  fixture="$tmp/fixture.bundle"
  printf 'pretend git bundle bytes\n' > "$fixture"
  cat >"$tmp/callsites.py" <<'CALLSITES'
import base64
import hashlib
import importlib.util
import json
import sys
from pathlib import Path
from types import SimpleNamespace

provider_path, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_provider", provider_path)
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)

root = Path(tmp)
body = (root / "fixture.bundle").read_bytes()
outcome_digest = hashlib.sha256(body).hexdigest()
controller = {
    "subscription": "00000000-0000-0000-0000-000000000000",
    "resource_group": "rg-test", "prefix": "fmtest", "owner": "owner",
    "deployment_generation": "dep-one", "home_binding": "a" * 64,
}
bindings = {
    "home_binding": "a" * 64, "task": "task-one", "task_generation": "gen-1",
    "assignment_generation": "asg-00000001", "account_binding": "b" * 64,
    "worktree_binding": "c" * 64, "repository_binding": "d" * 64,
    "repository_generation": "repo-gen",
}
request = dict(bindings)
request.update({
    "schema": "fm.worker-execution/v1", "cloud_instance_id": "vm-instance",
    "argv": ["/usr/bin/true"], "wall_seconds": 60, "outcome_expected": True,
})
unsigned = dict(request)
request["request_digest"] = hashlib.sha256(
    json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
payload_dir = root / "payload"
account_dir = root / "account"
payload_dir.mkdir(exist_ok=True)
account_dir.mkdir(exist_ok=True)
(payload_dir / "repo.bundle").write_bytes(b"bundle fixture")
(payload_dir / "brief.md").write_text("brief\n")
(account_dir / "auth.json").write_text("{}\n")


def manifest(directory):
    entries = {}
    for entry in sorted(directory.iterdir()):
        blob = entry.read_bytes()
        entries[entry.name] = {
            "sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob),
        }
    return entries


request["payload_files"] = manifest(payload_dir)
request["account_files"] = manifest(account_dir)
unsigned = dict(request)
unsigned.pop("request_digest")
request["request_digest"] = hashlib.sha256(
    json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
action = {
    "type": "execute", "slot": 1, "cloud_instance_id": "vm-instance",
    "bindings": bindings, "request": request,
    "request_digest": request["request_digest"],
    "idempotency_key": "e" * 64, "outcome_dir": str(root / "outcome"),
    "payload_dir": str(payload_dir), "account_dir": str(account_dir),
    "resources": {
        "staging-request": {"id": "/blob/request", "immutable_id": "assignment-request-etag"},
        "staging-result": {"id": "/blob/result", "immutable_id": "assignment-result-etag"},
    },
}

# Recovery of an already-assigned task disk cannot rely on the supervisor that
# assignment originally bootstrapped. The provider binds and embeds the exact
# landed recovery bytes without changing that original executable.
recovery_request = dict(request)
recovery_request.pop("payload_files")
recovery_request.pop("account_files")
supervisor_body = (provider.ROOT / "bin" / "fm-worker-supervisor.py").read_bytes()
recovery_request.update({
    "existing_task_disk": True,
    "supervisor_sha256": hashlib.sha256(supervisor_body).hexdigest(),
    "return_contract": {
        "schema": "fm.worker-return-contract/v1", "kind": "scout",
        "report_required": True, "report_path": "data/task-one/report.md",
        "status_path": "state/task-one.status", "visuals_path": "data/task-one/visuals",
        "branch": "",
    },
})
recovery_request.pop("request_digest")
recovery_request["request_digest"] = hashlib.sha256(
    json.dumps(recovery_request, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
recovery_action = dict(action, request=recovery_request, request_digest=recovery_request["request_digest"])
recovery_action.pop("payload_dir")
recovery_action.pop("account_dir")
recovery_script = provider.build_execute_script(recovery_action)
assert "/usr/bin/base64 --decode" in recovery_script, recovery_script[:500]
assert "recovery-supervisor-{}.py".format(recovery_request["supervisor_sha256"]) in recovery_script
assert "/usr/bin/python3 '/var/lib/firstmate-worker/recovery-supervisor-" in recovery_script

# A request can remain durably pending while public main advances its
# supervisor. Resolve only exact bytes already landed in the default-branch
# history; never rewrite the digest-bound action to the current supervisor.
legacy_body = b"#!/usr/bin/env python3\nprint('landed legacy supervisor')\n"
legacy_digest = hashlib.sha256(legacy_body).hexdigest()
original_run = provider.run
def fake_history(command, **_kwargs):
    if "symbolic-ref" in command:
        return SimpleNamespace(returncode=0, stdout=b"refs/remotes/origin/main\n", stderr=b"")
    if "log" in command:
        return SimpleNamespace(returncode=0, stdout=b"landed-revision\n", stderr=b"")
    if "show" in command:
        return SimpleNamespace(returncode=0, stdout=legacy_body, stderr=b"")
    raise AssertionError(command)
provider.run = fake_history
legacy_request = dict(recovery_request, supervisor_sha256=legacy_digest)
legacy_script = provider.build_execute_script(dict(recovery_action, request=legacy_request))
provider.run = original_run
assert base64.b64encode(legacy_body).decode("ascii") in legacy_script, legacy_script[:500]
assert "recovery-supervisor-{}.py".format(legacy_digest) in legacy_script

changed_recovery = dict(recovery_request, supervisor_sha256="f" * 64)
try:
    provider.build_execute_script(dict(recovery_action, request=changed_recovery))
except provider.ProviderError as exc:
    assert "supervisor binding differs" in str(exc), exc
else:
    raise AssertionError("provider accepted recovery supervisor bytes outside the request binding")

execution = {
    "schema": "fm.worker-execution-result/v1",
    "request_digest": request["request_digest"], "task": "task-one",
    "task_generation": "gen-1", "assignment_generation": "asg-00000001",
    "cloud_instance_id": "vm-instance", "repository_binding": "d" * 64,
    "repository_generation": "repo-gen", "exit_code": 0, "timed_out": False,
    "stdout_sha256": "0" * 64, "stderr_sha256": "1" * 64,
    "stdout_truncated": False, "stderr_truncated": False,
    "outcome_present": True, "outcome_error": "", "outcome_commits": 1,
    "outcome_sha256": outcome_digest, "outcome_bytes": len(body),
    "outcome_sink": "blob",
}
execution["result_digest"] = hashlib.sha256(
    json.dumps(execution, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()

# Only the collaborators that read live Azure state are substituted; every
# line of mutate_execute own body runs for real.
worker = {"slot": 1, "resources": {"vm": {"power_state": "VM running"}}}
provider.inventory = lambda controller, include_metrics=True: {"workers": [worker]}
provider.worker_by_slot = lambda snapshot, slot: worker
provider.recorded_exact = lambda action, worker, **kwargs: worker["resources"]
provider.action_tags = lambda controller, action: {}
provider.upload_json_blob = lambda *a, **k: "0" * 64
provider.run_command_instance_view = lambda controller, vm, name: {
    "executionState": "Succeeded",
    "output": "FM-WORKER-RESULT:" + json.dumps(execution, sort_keys=True, separators=(",", ":")),
    "error": "",
}
captured = {}
real_az = provider.az


def recording_az(controller, args, check=True, timeout=None):
    if "update" in args and "run-command" in args:
        captured["update"] = list(args)
        captured["timeout"] = timeout
    if "generate-sas" in args:
        captured.setdefault("sas", []).append(list(args))
    if timeout is None:
        return real_az(controller, args, check=check)
    return real_az(controller, args, check=check, timeout=timeout)


provider.az = recording_az
_worker, returned = provider.mutate_execute(controller, action)
assert returned["outcome_present"] is True, returned

update = captured.get("update")
assert update, "mutate_execute never issued a run-command update"
joined = " ".join(update)
assert "--protected-parameters" in joined, joined
assert any(item.startswith("FM_WORKER_OUTCOME_URL=https://") for item in update), update

landed = root / "outcome" / "outcome.bundle"
assert landed.is_file(), "mutate_execute never collected the outcome bundle"
assert landed.read_bytes() == body, "the collected bundle is not the blob"

# A scout can return only report/status/scratch artifacts with zero project
# commits. return_present, not outcome_present, must still drive the same
# digest-bound provider collection lane.
landed.unlink()
return_only = dict(execution)
return_only.update({
    "outcome_present": False, "outcome_commits": 0, "return_present": True,
    "return_ref": "refs/fm-return/" + request["request_digest"][:32],
    "return_commit": "2" * 40, "return_manifest_sha256": "3" * 64,
    "outcome_tip": "4" * 40,
})
return_only.pop("result_digest")
return_only["result_digest"] = hashlib.sha256(
    json.dumps(return_only, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
provider.run_command_instance_view = lambda controller, vm, name: {
    "executionState": "Succeeded",
    "output": "FM-WORKER-RESULT:" + json.dumps(return_only, sort_keys=True, separators=(",", ":")),
    "error": "",
}
_worker, returned = provider.mutate_execute(controller, action)
assert returned["return_present"] is True and returned["outcome_present"] is False, returned
assert landed.read_bytes() == body, "the return-only scout bundle was not collected"

# Restore the committed-outcome result for the refusal cases below.
provider.run_command_instance_view = lambda controller, vm, name: {
    "executionState": "Succeeded",
    "output": "FM-WORKER-RESULT:" + json.dumps(execution, sort_keys=True, separators=(",", ":")),
    "error": "",
}

# The blocking call must be bounded by the whole guest run, not the bare wall:
# staging happens before the wall starts and collection after it ends.
assert captured.get("timeout") is not None, "the run-command update carried no explicit bound"
# An absolute floor, not the constant under test: comparing against
# GUEST_RUN_SLACK_SECONDS itself would pass with the constant set to zero.
# Staging alone is two 300s fetches plus a 600s clone, and collection adds a
# 600s bundle and a 600s upload, so the bound must clear the wall by far more
# than the ordinary control-plane timeout.
assert captured["timeout"] >= request["wall_seconds"] + 1800, (
    "the run-command bound does not cover staging and collection", captured["timeout"],
)

# Every staging credential must outlive the whole guest run, not just the
# wall: the guest stages before the wall starts and uploads after it ends, and
# an expired write SAS means the bundle never arrives. Compared against an
# absolute floor, never against the constant under test.
import datetime as _dt

minted = _dt.datetime.now(_dt.timezone.utc)
assert captured.get("sas"), "no staging SAS was minted"
for sas_args in captured["sas"]:
    expiry_text = sas_args[sas_args.index("--expiry") + 1]
    expiry = _dt.datetime.strptime(expiry_text, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=_dt.timezone.utc
    )
    window = (expiry - minted).total_seconds()
    assert window >= request["wall_seconds"] + 1800, (
        "a staging SAS expires before the guest run can finish", sas_args, window,
    )

# A result claiming an outcome written anywhere but the staging blob is a
# diverted upload and must be refused, not collected.
landed.unlink()
diverted = dict(execution)
diverted["outcome_sink"] = "file"
diverted.pop("result_digest")
diverted["result_digest"] = hashlib.sha256(
    json.dumps(diverted, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
provider.run_command_instance_view = lambda controller, vm, name: {
    "executionState": "Succeeded",
    "output": "FM-WORKER-RESULT:" + json.dumps(diverted, sort_keys=True, separators=(",", ":")),
    "error": "",
}
try:
    provider.mutate_execute(controller, action)
    raise AssertionError("a diverted outcome sink was accepted")
except provider.ProviderError as exc:
    assert "rather than the staging blob" in str(exc), exc
assert not landed.exists(), "a refused sink still collected a bundle"

# A result with NO sink at all is what a supervisor predating this contract
# returns; it must be refused too, not treated as a blob upload.
absent = dict(execution)
absent.pop("outcome_sink")
absent.pop("result_digest")
absent["result_digest"] = hashlib.sha256(
    json.dumps(absent, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
).hexdigest()
provider.run_command_instance_view = lambda controller, vm, name: {
    "executionState": "Succeeded",
    "output": "FM-WORKER-RESULT:" + json.dumps(absent, sort_keys=True, separators=(",", ":")),
    "error": "",
}
try:
    provider.mutate_execute(controller, action)
    raise AssertionError("an outcome with no recorded sink was accepted")
except provider.ProviderError as exc:
    assert "rather than the staging blob" in str(exc), exc
assert not landed.exists(), "a missing sink still collected a bundle"
print("OK")
CALLSITES
  out=$(PATH="$bin:$PATH" FAKE_AZ_LOG="$tmp/az.log" FAKE_AZ_BLOB="$fixture" \
    FM_AZURE_STORAGE_NAME=fmteststorage \
    python3 "$tmp/callsites.py" "$PROVIDER" "$tmp" 2>&1)
  status=$?
  expect_code 0 "$status" "mutate_execute should arm and collect the outcome: $out"
  assert_contains "$out" "OK" "the call-site driver did not complete: $out"
  pass "mutate_execute really arms the outcome lane and really collects the bundle"
}

run_outcome_call_sites

run_initial_stub_adoption_after_source_update() {
  python3 - "$PROVIDER" <<'PY' || fail "fresh source-absent execute stub was not adopted exactly once"
import copy
import hashlib
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_provider", sys.argv[1])
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)
controller = {"prefix": "fmtest", "resource_group": "rg-test"}
bindings = {
    "home_binding": "a" * 64, "task": "fresh-task",
    "task_generation": "spawn:fresh", "assignment_generation": "asg-00000038",
    "account_binding": "b" * 64, "worktree_binding": "c" * 64,
    "repository_binding": "d" * 64, "repository_generation": "e" * 40,
}
action = {
    "type": "execute", "slot": 6, "bindings": bindings,
    "cloud_instance_id": "fresh-vm", "request_digest": "1" * 64,
    "idempotency_key": "2" * 64,
    "request": {**bindings, "request_digest": "1" * 64},
    "resources": {
        "staging-request": {"id": "/blob/request", "immutable_id": "assignment-request-etag"},
        "staging-result": {"id": "/blob/result", "immutable_id": "assignment-result-etag"},
    },
}
resources = {
    "vm": {"id": "/vm/fresh", "power_state": "VM running"},
    "task-command": {"id": "/vm/fresh/task-command"},
    "staging-request": {
        "id": "/blob/request", "immutable_id": "assignment-request-etag",
        "digest": "7" * 64, "length": 901,
    },
    "staging-result": {
        "id": "/blob/result", "immutable_id": "assignment-result-etag",
        "digest": "8" * 64, "length": 117,
    },
}
provider.show_full = lambda *_args, **_kwargs: {
    "properties": {"source": None, "provisioningState": "Succeeded"},
}
provider.run_command_instance_view = lambda *_args, **_kwargs: {
    "executionState": "Failed", "exitCode": -202, "output": "", "error": "",
}
disposition, recovered = provider.execute_terminal_disposition(controller, action, resources)
assert disposition == provider.EXECUTE_DISPOSITION_SUBMIT and recovered is None

upload_calls = []
existing_payload = b"foreign bytes\n"
def conditional_response(_controller, args, **_kwargs):
    upload_calls.append(args)
    if args[:3] == ["storage", "blob", "upload"]:
        return None, 1, "ConditionNotMet"
    if args[:3] == ["storage", "blob", "show"]:
        return {
            "etag": "current-etag",
            "metadata": {"content_digest": hashlib.sha256(request_payload).hexdigest()},
        }, 0, ""
    assert args[:3] == ["storage", "blob", "download"], args
    assert args[-2:] == ["--if-match", "current-etag"], args
    with open(args[args.index("--file") + 1], "wb") as handle:
        handle.write(existing_payload)
    return None, 0, ""
request_payload = provider.canonical_bytes(action["request"]) + b"\n"
provider.az = conditional_response
try:
    provider.upload_json_blob(
        controller, "storage", "container", "request.json", action["request"], {},
        overwrite=True, if_match="assignment-request-etag",
    )
except provider.ProviderError as exc:
    assert "exact worker staging upload failed" in str(exc), exc
else:
    raise AssertionError("a concurrent staging overwrite was accepted")
assert len(upload_calls) == 3, upload_calls
assert upload_calls[0][-2:] == ["--if-match", "assignment-request-etag"], upload_calls[0]

existing_payload = request_payload
existing_digest = hashlib.sha256(existing_payload).hexdigest()
upload_calls = []
assert provider.upload_json_blob(
    controller, "storage", "container", "request.json", action["request"], {},
    overwrite=True, if_match="assignment-request-etag",
) == existing_digest
assert len(upload_calls) == 3, upload_calls

changed = copy.deepcopy(resources)
changed["staging-request"]["immutable_id"] = "post-staging-etag"
try:
    provider.execute_terminal_disposition(controller, action, changed)
except provider.ProviderError as exc:
    assert "outside the exact initial staging state" in str(exc), exc
else:
    raise AssertionError("a post-staging replay passed through the initial stub gate")

claimed = copy.deepcopy(changed)
claimed["staging-request"]["digest"] = existing_digest
claimed["staging-request"]["length"] = len(request_payload)
disposition, recovered = provider.execute_terminal_disposition(controller, action, claimed)
assert disposition == provider.EXECUTE_DISPOSITION_SUBMIT and recovered is None

execution = {
    "schema": provider.EXECUTION_RESULT_SCHEMA,
    "request_digest": action["request_digest"], "exit_code": 0,
}
terminal_payload = provider.canonical_bytes(execution) + b"\n"
terminal_digest = hashlib.sha256(terminal_payload).hexdigest()

existing_payload = b"foreign terminal bytes\n"
upload_calls = []
try:
    provider.persist_execute_result(
        controller, action, provider.expected_names(controller, action["slot"]), {}, execution,
    )
except provider.ProviderError as exc:
    assert "exact worker staging upload failed" in str(exc), exc
else:
    raise AssertionError("a result mutation during guest execution was overwritten")
assert upload_calls[0][-2:] == ["--if-match", "assignment-result-etag"], upload_calls

existing_payload = terminal_payload
upload_calls = []
provider.persist_execute_result(
    controller, action, provider.expected_names(controller, action["slot"]), {}, execution,
)
assert len(upload_calls) == 3, upload_calls
PY
  pass "request/result ETags reject foreign writes and converge only after an exact lost response"
}

run_initial_stub_adoption_after_source_update

run_resume_after_exact_compute_removal() {
  python3 - "$PROVIDER" <<'PY' || fail "retained-disk resume rejected absent deleted compute children"
import copy
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_provider", sys.argv[1])
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)
controller = {
    "subscription": "00000000-0000-0000-0000-000000000000",
    "resource_group": "rg-test", "prefix": "fmtest", "owner": "owner",
    "deployment_generation": "dep-one", "home_binding": "a" * 64,
}
action = {
    "type": "resume", "slot": 1, "reuse_retained": True,
    "sku": "Standard_D4as_v6", "sku_family": "standardDav6Family",
    "cloud_generation": 2, "previous_cloud_generation": 1,
    "deployment_generation": "dep-one", "owner": "owner",
    "cloud_instance_id": "replacement-vm",
    "bindings": {
        "home_binding": "a" * 64, "task": "retained-task",
        "task_generation": "spawn:retained", "assignment_generation": "asg-00000033",
        "account_binding": "b" * 64, "worktree_binding": "c" * 64,
        "repository_binding": "d" * 64, "repository_generation": "e" * 40,
    },
}
prior_action = dict(action, cloud_generation=1)
tags = provider.action_tags(controller, prior_action)
resources = {}
for kind in provider.REQUIRED_RESOURCE_KINDS:
    resources[kind] = {
        "id": "/resource/" + kind, "immutable_id": "immutable-" + kind,
        "tags": dict(tags),
    }
for kind in ("global-reservation", "staging-request", "staging-result"):
    resources[kind].update({"digest": "f" * 64, "length": 1})
action["resources"] = {
    kind: {"id": value["id"], "immutable_id": value["immutable_id"]}
    for kind, value in resources.items()
}
removed_compute = {
    "vm", "nic", "os-disk", "monitor-extension", "bootstrap-command",
    "task-command", "ttl-schedule",
}
retained = {
    kind: copy.deepcopy(value) for kind, value in resources.items()
    if kind not in removed_compute
}
worker = {"slot": 1, "resources": retained}
provider.inventory = lambda *_args, **_kwargs: {
    "workers": [worker], "conflicts": [], "metrics": {},
}
calls = []
provider.run_pilot_create = lambda *_args: calls.append("pilot")
provider.create_lifecycle_children = lambda *_args: calls.append("children")
provider.converge_create_tags = lambda *_args: "resumed"
assert provider.create_or_resume(controller, action) == "resumed"
assert calls == ["pilot", "children"], calls
foreign = copy.deepcopy(worker)
foreign["resources"]["task-disk"]["id"] = "/foreign/task-disk"
provider.inventory = lambda *_args, **_kwargs: {
    "workers": [foreign], "conflicts": [], "metrics": {},
}
try:
    provider.create_or_resume(controller, action)
except provider.ProviderIdentityRefusal as exc:
    assert "task-disk resource ID differs" in str(exc), exc
else:
    raise AssertionError("resume accepted a replaced retained task disk")
PY
  pass "resume accepts exact retained disks after all old compute children are absent and refuses replaced disks"
}

run_resume_after_exact_compute_removal

run_outcome_bound_agreement() {
  # The guest enforces its ceiling before uploading and the controller enforces
  # it on the claim. They are separate literals in separate files, so drift
  # would make the guest write a blob the controller refuses.
  local guest controller_bound
  guest=$(sed -n 's/^MAX_OUTCOME_BYTES = //p' "$ROOT/bin/fm-worker-supervisor.py" | head -1)
  controller_bound=$(sed -n 's/^MAX_OUTCOME_BYTES = //p' "$PROVIDER" | head -1)
  test -n "$guest" || fail "the guest outcome bound is missing"
  test "$guest" = "$controller_bound" \
    || fail "outcome bounds drifted: guest=$guest controller=$controller_bound"
  pass "the guest and controller agree on the outcome byte ceiling"
}

run_outcome_bound_agreement

echo "# fm-worker-outcome-transport.test.sh: all assertions passed"
