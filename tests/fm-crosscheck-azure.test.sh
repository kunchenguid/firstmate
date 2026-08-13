#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-crosscheck-azure.py"
CORE="$ROOT/bin/fm-crosscheck.py"
MODEL_GUEST="$ROOT/bin/fm-crosscheck-azure-model-guest.sh"
BRIDGE="$ROOT/bin/fm-crosscheck-azure-tool-bridge.py"
REPLAY="$ROOT/bin/fm-crosscheck-azure-replay.py"
TEMPLATE="$ROOT/docs/azure-crosscheck/compartment.json"
DOC="$ROOT/docs/azure-crosscheck.md"
EVIDENCE="$ROOT/docs/azure-crosscheck-evidence-2026-08-12.md"

static_contract() {
  python3 - "$ADAPTER" "$CORE" "$MODEL_GUEST" "$BRIDGE" "$REPLAY" "$TEMPLATE" "$DOC" <<'PY' || fail "Azure Crosscheck static contract failed"
import ast
import json
from pathlib import Path
import sys

adapter, core, guest, bridge, replay, template, doc = map(Path, sys.argv[1:])
for path in (adapter, core, bridge, replay):
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
value = json.loads(template.read_text(encoding="utf-8"))
resources = value["resources"]
assert len(resources) == 3
nic = next(item for item in resources if item["type"] == "Microsoft.Network/networkInterfaces")
vm = next(item for item in resources if item["type"] == "Microsoft.Compute/virtualMachines")
assert "publicipaddress" not in json.dumps(nic).lower()
assert "identity" not in vm
assert "ssh" not in json.dumps(vm["properties"]["osProfile"]).lower()
assert vm["properties"]["securityProfile"]["securityType"] == "TrustedLaunch"
assert vm["properties"]["storageProfile"]["imageReference"] == {"id": "[parameters('modelImageId')]"}
source = adapter.read_text(encoding="utf-8")
for marker in (
    "azure-compartment-v1",
    "review_generation",
    "claims_sha256",
    "ledger_digest",
    "vm_instance_id",
    "boot_id",
    "network_bytes",
    "credential_present",
    "If-Match=",
):
    assert marker in source
core_source = core.read_text(encoding="utf-8")
assert "load_azure_crosscheck_adapter" in core_source
assert "validate_azure_reviewer_record" in core_source
assert "verify_azure_reviewer_record" in core_source
bridge_source = bridge.read_text(encoding="utf-8")
for marker in (
    "RemoteEvidenceExecutor",
    "crosscheck-tool",
    "tool_identity",
    "verifier_identity",
    "vm_instance_id",
    "--public-ref",
):
    assert marker in bridge_source
guest_source = guest.read_text(encoding="utf-8")
assert "--disable shell_tool" in guest_source
assert '--tools ""' in guest_source
assert "--no-tools" in guest_source
assert "AZURE_CLIENT_SECRET" in guest_source
assert "DOCKER_HOST" in guest_source
assert "credential manifest identity mismatch" in guest_source
assert 'rm -rf "$ACCOUNT"' in guest_source
assert "--max-filesize 131072" in guest_source
for forbidden in (
    "ssh ",
    "docker ",
    "az login",
    "fm-crosscheck-tool-client",
    "--dangerously-bypass-approvals-and-sandbox",
):
    assert forbidden not in guest_source
text = doc.read_text(encoding="utf-8")
for phrase in (
    "fresh private-controller `crosscheck-tool` runner",
    "second newly created `crosscheck-tool` runner",
    "A single VM containing both provider credentials and repository commands is not accepted",
    "force-push",
    "Two admitted reviews",
    "Cloud-default acceptance",
):
    assert phrase in text
PY
  pass "Azure Crosscheck static contracts separate model, tool, verifier, identity, and cleanup"
}

adapter_mode_unit() {
  python3 - "$ADAPTER" <<'PY' || fail "Azure selection contract failed"
import importlib.util
import json
import os
import re
from pathlib import Path
import tempfile
import sys

spec = importlib.util.spec_from_file_location("azure_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
path_pattern = module.azure_review_schema({})["properties"]["evidence_files"]["propertyNames"]["pattern"]
assert re.fullmatch(path_pattern, ".crosscheck/reproductions/proof.sh")
assert not re.fullmatch(path_pattern, "x.crosscheck/reproductions/proof.sh")
with tempfile.TemporaryDirectory() as temporary:
    home = Path(temporary)
    (home / "config").mkdir()
    assert module.azure_review_enabled(home) is False
    os.environ["FM_CROSSCHECK_EXECUTION_MODE"] = "azure"
    assert module.azure_review_enabled(home) is True
    os.environ["FM_CROSSCHECK_EXECUTION_MODE"] = "local"
    assert module.azure_review_enabled(home) is False
    os.environ["FM_CROSSCHECK_EXECUTION_MODE"] = "bad"
    try:
        module.azure_review_enabled(home)
    except module.AzureCrosscheckError as exc:
        assert "exactly local or azure" in str(exc)
    else:
        raise AssertionError("invalid execution mode did not fail")
    del os.environ["FM_CROSSCHECK_EXECUTION_MODE"]
    path = home / "config" / "crosscheck-azure.json"
    path.write_text(json.dumps({"enabled": True}), encoding="utf-8")
    os.chmod(path, 0o600)
    assert module.azure_review_enabled(home) is True
    os.chmod(path, 0o666)
    try:
        module.azure_review_enabled(home)
    except module.AzureCrosscheckError as exc:
        assert "non-group/world-writable" in str(exc)
    else:
        raise AssertionError("unsafe config mode did not fail")
PY
  pass "Azure selection is explicit, local-default, and unsafe config fails closed"
}

identity_outcome_unit() {
  python3 - "$ADAPTER" <<'PY' || fail "Azure ledger identity contract failed"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("azure_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
identity = {
    "home_binding": "sha256:" + "1" * 64,
    "task_id": "task-one",
    "pull_request": "https://github.com/example/repo/pull/1",
    "head_sha": "a" * 40,
    "base_sha": "b" * 40,
    "base_branch_sha": "d" * 40,
    "claims_sha256": "c" * 64,
    "deployment_generation": "deploy-1",
    "model_image_id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/images/model",
    "reviewer_sku": "Standard_D4as_v6",
    "provider_host": "api.example.com",
    "provider_port": "443",
    "reviewer_harness": "pi",
    "reviewer_model": "gpt-5.6-sol",
    "reviewer_effort": "xhigh",
    "reviewer_account_digest": "sha256:" + "2" * 64,
    "ledger_digest": "sha256:" + "f" * 64,
}
identity["review_generation"] = module.digest_bytes(module.canonical_bytes(identity)).split(":", 1)[1][:24]
generation = identity["review_generation"]
def child(label):
    return {
        "invocation": label, "resource_id": "/" + label,
        "vm_instance_id": label, "boot_id": "boot-" + label,
        "request_digest": "sha256:" + "3" * 64,
        "result_digest": "sha256:" + "4" * 64,
        "deployment_generation": "deploy-1",
        "review_generation": generation, "source_ref": "refs/pull/1/head",
        "head_sha": "a" * 40, "base_sha": "b" * 40, "network_bytes": 0,
        "credential_present": False, "cleanup_phase": "complete",
    }
tool = child("tool")
verifier = child("verifier")
result = {
    "exit_code": 0, "timed_out": False, "signal": None,
    "stdout_bytes": 8, "stderr_bytes": 0,
    "stdout_truncated": False, "stderr_truncated": False,
    "stdout_digest": "sha256:" + "5" * 64,
    "stderr_digest": "sha256:" + "6" * 64,
}
attempts = [{"tool": tool, "verifier": verifier, "result": result}]
identity.update({
    "request_digest": "sha256:" + "0" * 64,
    "credential_archive_digest": "sha256:" + "7" * 64,
    "credential_digest": "sha256:" + "8" * 64,
    "model": {
        "resource_id": "/model", "vm_instance_id": "model",
        "boot_id": "boot-model", "cleanup_phase": "complete",
        "request_digest": "sha256:" + "0" * 64,
        "result_digest": "sha256:" + "9" * 64,
        "deployment_generation": "deploy-1",
        "image_id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/images/model",
    },
    "tool": tool,
    "verifier": verifier,
    "evidence_attempts": attempts,
    "evidence_attempts_digest": module.digest_bytes(module.canonical_bytes(attempts)),
    "staging_cleanup_phase": "complete",
})
base = {
    "execution_mode": "azure-compartment-v1",
    "harness": "pi",
    "model": "gpt-5.6-sol",
    "effort": "xhigh",
    "account_home": "/independent/pi",
    "reviewer_account_identity_sha256": "2" * 64,
    "azure_identity": identity,
}
run = {"head_sha": "a" * 40, "base_sha": "b" * 40, "claims_sha256": "c" * 64}
module.validate_azure_reviewer_record(base, run, "run")
for mutation, expected in (
    (("head_sha", "9" * 40), "generation"),
    (("tool.vm_instance_id", "model"), "immutable identity"),
    (("verifier.network_bytes", 1), "boundary or cleanup"),
    (("verifier.credential_present", True), "boundary or cleanup"),
    (("verifier.cleanup_phase", "pending"), "boundary or cleanup"),
    (("verifier.source_ref", "refs/pull/2/head"), "source ref"),
    (("verifier.review_generation", "wrong"), "generation"),
):
    import copy
    candidate = copy.deepcopy(base)
    path, value = mutation
    if "." in path:
        first, second = path.split(".")
        candidate["azure_identity"][first][second] = value
        if first in {"tool", "verifier"}:
            candidate["azure_identity"]["evidence_attempts"][0][first][second] = value
            candidate["azure_identity"]["evidence_attempts_digest"] = module.digest_bytes(
                module.canonical_bytes(candidate["azure_identity"]["evidence_attempts"])
            )
    else:
        candidate["azure_identity"][path] = value
    try:
        module.validate_azure_reviewer_record(candidate, run, "run")
    except RuntimeError as exc:
        assert expected in str(exc), (expected, str(exc))
    else:
        raise AssertionError("identity mismatch did not fail: " + path)
PY
  pass "wrong head, stale endpoint, shared VM, network, credential, and generation outcomes fail closed"
}

account_and_cleanup_identity_unit() {
  python3 - "$ADAPTER" <<'PY' || fail "Azure account and cleanup identity contract failed"
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("azure_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
common = {
    "home": Path("/home/firstmate"),
    "task_id": "review-one",
    "pr_url": "https://github.com/example/repo/pull/1",
    "snapshot_value": {
        "head_sha": "a" * 40,
        "base_sha": "b" * 40,
        "base_branch_sha": "c" * 40,
        "claims_sha256": "d" * 64,
    },
    "config": {
        "harness": "pi",
        "model": "gpt-5.6-sol",
        "effort": "xhigh",
        "account_home": "/same/path",
    },
    "azure": {
        "deployment_generation": "deploy-1",
        "model_image_id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/images/model",
        "reviewer_sku": "Standard_D4as_v6",
        "provider_host": "api.example.com",
        "provider_port": 443,
    },
    "ledger": {"schema": "firstmate.crosscheck-ledger.v2", "findings": [], "runs": []},
}
first = module.review_identity(**common, reviewer_account_identity="account-one")
second = module.review_identity(**common, reviewer_account_identity="account-two")
assert first["reviewer_account_digest"] != second["reviewer_account_digest"]
assert first["review_generation"] != second["review_generation"]
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    credential = root / "auth.json"
    credential.write_text(json.dumps({"openai-codex":{"accountId":"account-one"}}), encoding="utf-8")
    archive_digest, credential_digest = module.create_credential_archive(
        root / "credential.tar.gz", credential, first, common["config"], "account-one"
    )
    assert archive_digest.startswith("sha256:") and credential_digest.startswith("sha256:")
    try:
        module.create_credential_archive(
            root / "wrong.tar.gz", credential, first, common["config"], "account-two"
        )
    except module.AzureCrosscheckError as exc:
        assert "differs" in str(exc)
    else:
        raise AssertionError("wrong archived reviewer account became admissible")
    linked = root / "linked.json"
    linked.symlink_to(credential)
    try:
        module.create_credential_archive(
            root / "linked.tar.gz", linked, first, common["config"], "account-one"
        )
    except module.AzureCrosscheckError as exc:
        assert "symlink" in str(exc)
    else:
        raise AssertionError("symlink credential became admissible")

original = module.az
module.az = lambda *_args, **_kwargs: (None, 1, "AuthorizationFailed")
try:
    module.delete_exact_resource({}, "/resource", "1", {}, "fixture")
except module.AzureCrosscheckError as exc:
    assert "ambiguous" in str(exc)
else:
    raise AssertionError("an unreadable resource became cleanup absence")
module.az = lambda *_args, **_kwargs: (None, 1, "ResourceNotFound")
module.delete_exact_resource({}, "/resource", "1", {}, "fixture")
module.az = original
PY
  pass "review generation binds the executing account and ambiguous cleanup never becomes absence"
}

bridge_security_unit() {
  python3 - "$BRIDGE" <<'PY' || fail "Azure host bridge security contract failed"
import importlib.util
from pathlib import Path
import sys
import time

spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
files = module.validate_evidence_files({
    ".crosscheck/reproductions/proof.sh": "#!/usr/bin/env bash\nprintf 'marker\\n'\nprintf 'receipt\\n' > .crosscheck/reproductions/receipt.txt\n",
    ".crosscheck/mutations/proof.patch": "diff --git a/value.py b/value.py\n",
})
assert files[".crosscheck/reproductions/proof.sh"].startswith(b"#!/")
for malicious in (
    {"../../control-home": "x"},
    {"/etc/passwd": "x"},
    {".crosscheck/reproductions/linked/../../token": "x"},
    {".crosscheck/reproductions/large.sh": "x" * (12 * 1024 + 1)},
):
    try:
        module.validate_evidence_files(malicious)
    except module.BridgeError:
        pass
    else:
        raise AssertionError("malicious evidence manifest did not fail")
sequence = []
def dispatch(_runner, request, suffix, _command, wall_seconds):
    assert 60 <= wall_seconds <= 900
    sequence.append(suffix)
    reused = suffix.startswith("verify") and request.get("reuse")
    matching_tool = "tool-" + suffix.split("-", 1)[1] + "-vm"
    identity = {
        "invocation": suffix, "resource_id": "/" + suffix,
        "vm_instance_id": matching_tool if reused else suffix + "-vm",
        "boot_id": suffix + "-boot", "request_digest": "sha256:" + "1" * 64,
        "deployment_generation": "deploy-1",
        "review_generation": request["review_generation"], "source_ref": request["source_ref"],
        "head_sha": request["head_sha"], "base_sha": request["base_sha"], "network_bytes": 0,
        "credential_present": False, "cleanup_phase": "complete",
        "result_digest": "sha256:" + "2" * 64,
    }
    result = {
        "exit_code": 0, "timed_out": False, "signal": None,
        "stdout_bytes": 8, "stderr_bytes": 0, "stdout_truncated": False,
        "stderr_truncated": False, "stdout_digest": "sha256:" + "3" * 64,
        "stderr_digest": "sha256:" + "4" * 64,
    }
    return identity, result
module.dispatch_once = dispatch
module.load_runner = lambda: object()
executor = module.RemoteEvidenceExecutor(
    repository_root=Path("."), remote="https://github.com/example/repo.git",
    source_ref="refs/pull/7/head", head_sha="a" * 40, base_sha="b" * 40,
    review_generation="c" * 24, evidence_files=files,
)
executor.validate_declared_paths(
    {".crosscheck/reproductions/proof.sh", ".crosscheck/mutations/proof.patch"},
    receipt_path=".crosscheck/reproductions/receipt.txt",
)
try:
    executor.validate_declared_paths(
        {".crosscheck/reproductions/proof.sh"},
        receipt_path=".crosscheck/reproductions/receipt.txt",
    )
except module.BridgeError as exc:
    assert "exactly match" in str(exc)
else:
    raise AssertionError("unreferenced reviewer evidence became admissible")
try:
    executor(
        {"test_path":".crosscheck/reproductions/proof.sh","command":"bash --noprofile --norc .crosscheck/reproductions/proof.sh " + "b"*40 + " " + "a"*40 + "; id","expected_exit":0,"output_contains":"marker"},
        Path("."), "injected", time.monotonic() + 300,
    )
except module.BridgeError as exc:
    assert "exact bounded" in str(exc)
else:
    raise AssertionError("command suffix injection became accepted evidence")
proof = executor(
    {"test_path":".crosscheck/reproductions/proof.sh","command":"bash --noprofile --norc .crosscheck/reproductions/proof.sh " + "b"*40 + " " + "a"*40,"expected_exit":0,"output_contains":"marker"},
    Path("."), "proof", time.monotonic() + 300,
    receipt={"path":".crosscheck/reproductions/receipt.txt","contains":["receipt"]},
)
assert proof["actual_exit"] == 0 and len(executor.attempts) == 1
mutation = executor.execute_mutation(
    {
        "test_path":"tests/test_value.py",
        "test_invocation":{"runner":"pytest","arguments":[]},
        "mutation_patch_path":".crosscheck/mutations/proof.patch",
    },
    ["value.py"],
    time.monotonic() + 300,
)
assert mutation["baseline_exit"] == 0 and mutation["mutated_exit"] == 1
assert sequence == ["tool-1", "verify-1", "tool-2", "verify-2"]
executor.request["reuse"] = True
try:
    executor(
        {"test_path":".crosscheck/reproductions/proof.sh","command":"bash --noprofile --norc .crosscheck/reproductions/proof.sh " + "b"*40 + " " + "a"*40,"expected_exit":0,"output_contains":"marker"},
        Path("."), "reuse", time.monotonic() + 300,
    )
except module.BridgeError as exc:
    assert "reused" in str(exc)
else:
    raise AssertionError("stale tool endpoint reuse became accepted evidence")
PY
  pass "host bridge rejects hostile evidence and requires distinct cleaned exact-head tool/verifier attempts"
}

replay_positive_and_failure_unit() {
  local tmp mutation_tmp evidence patch_evidence head
  fm_test_tmproot_into tmp fm-crosscheck-azure-replay
  evidence=$(python3 - <<'PY'
import base64,json
body=b"#!/usr/bin/env bash\nprintf 'allowed-positive-control\\n'\nprintf 'receipt base head home account\\n' > .crosscheck/reproductions/receipt.txt\n"
value={".crosscheck/reproductions/pass.sh":base64.b64encode(body).decode(),".crosscheck/reproductions/receipt.txt":base64.b64encode(b"placeholder").decode()}
# The helper owns the receipt, so do not pre-stage its output path.
del value[".crosscheck/reproductions/receipt.txt"]
print(base64.b64encode(json.dumps(value,sort_keys=True,separators=(",",":")).encode()).decode())
PY
)
  (
    cd "$tmp" || exit
    "$REPLAY" --manifest "$evidence" --test-path .crosscheck/reproductions/pass.sh \
      --base-sha "$(printf 'b%.0s' {1..40})" --head-sha "$(printf 'a%.0s' {1..40})" \
      --expected-exit 0 --output-contains allowed-positive-control \
      --receipt-path .crosscheck/reproductions/receipt.txt \
      --receipt-contains receipt --receipt-contains base --receipt-contains head \
      --receipt-contains home --receipt-contains account
  ) >"$tmp/out"
  assert_grep 'receipt base head home account' "$tmp/out" "allowed receipt positive control was not observable"
  rm -rf "$tmp/.crosscheck"
  mkdir -p "$tmp/.crosscheck/reproductions"
  ln -s /etc/passwd "$tmp/.crosscheck/reproductions/linked"
  if (
    cd "$tmp" || exit
    "$REPLAY" --manifest "$evidence" --test-path .crosscheck/reproductions/linked \
      --base-sha "$(printf 'b%.0s' {1..40})" --head-sha "$(printf 'a%.0s' {1..40})" \
      --expected-exit 0 --output-contains root
  ) >"$tmp/symlink.out" 2>&1; then
    fail "symlink evidence path became executable"
  fi
  if (
    cd "$tmp" || exit
    rm -rf .crosscheck .crosscheck-home
    "$REPLAY" --manifest "$evidence" --test-path .crosscheck/reproductions/pass.sh \
      --base-sha "$(printf 'b%.0s' {1..40})" --head-sha "$(printf 'a%.0s' {1..40})" \
      --expected-exit 0 --output-contains missing-marker
  ) >"$tmp/marker.out" 2>&1; then
    fail "missing evidence marker became a pass"
  fi
  assert_grep 'required marker' "$tmp/marker.out" "marker refusal was not named"
  rm -rf "$tmp/.crosscheck"
  mkdir "$tmp/outside"
  ln -s "$tmp/outside" "$tmp/.crosscheck"
  if (
    cd "$tmp" || exit
    "$REPLAY" --manifest "$evidence" --test-path .crosscheck/reproductions/pass.sh \
      --base-sha "$(printf 'b%.0s' {1..40})" --head-sha "$(printf 'a%.0s' {1..40})" \
      --expected-exit 0 --output-contains allowed-positive-control
  ) >"$tmp/parent-symlink.out" 2>&1; then
    fail "symlinked evidence parent became writable"
  fi
  assert_grep 'parent is not a real directory' "$tmp/parent-symlink.out" "parent-symlink refusal was not named"

  fm_test_tmproot_into mutation_tmp fm-crosscheck-azure-mutation
  mkdir -p "$mutation_tmp/tests" "$mutation_tmp/tools/agent-fleet/.venv/bin"
  printf 'def value():\n    return 1\n' >"$mutation_tmp/value.py"
  printf 'from value import value\n\ndef test_value():\n    assert value() == 1\n' >"$mutation_tmp/tests/test_value.py"
  cat >"$mutation_tmp/tools/agent-fleet/.venv/bin/python" <<'SH'
#!/usr/bin/env bash
[ "$1" = -m ] && [ "$2" = pytest ] && [ "$3" = tests/test_value.py ] || exit 4
grep -q 'return 1' value.py
SH
  chmod +x "$mutation_tmp/tools/agent-fleet/.venv/bin/python"
  git -C "$mutation_tmp" init -q -b main
  git -C "$mutation_tmp" -c user.name=test -c user.email=test@example.invalid add value.py tests/test_value.py
  git -C "$mutation_tmp" -c user.name=test -c user.email=test@example.invalid commit -qm base
  head=$(git -C "$mutation_tmp" rev-parse HEAD)
  printf 'def value():\n    return 2\n' >"$mutation_tmp/value.py"
  git -C "$mutation_tmp" diff >"$mutation_tmp/proof.patch"
  git -C "$mutation_tmp" checkout -q -- value.py
  patch_evidence=$(python3 - "$mutation_tmp/proof.patch" <<'PY'
import base64,json,sys
body=base64.b64encode(open(sys.argv[1],"rb").read()).decode()
print(base64.b64encode(json.dumps({".crosscheck/mutations/proof.patch":body},sort_keys=True,separators=(",",":")).encode()).decode())
PY
)
  (
    cd "$mutation_tmp" || exit
    "$REPLAY" --mode mutation --manifest "$patch_evidence" \
      --test-path tests/test_value.py --base-sha "$head" --head-sha "$head" \
      --mutation-path .crosscheck/mutations/proof.patch --test-runner pytest \
      --changed-path value.py
  ) >"$mutation_tmp/mutation.out"
  assert_grep 'remote-mutation-ok' "$mutation_tmp/mutation.out" "allowed remote mutation proof was not observable"
  pass "networkless replay proves exact pytest mutations and denies command, symlink, marker, and parent substitution"
}

documented_acceptance_contract() {
  for required in \
    'reviewer-token reads' \
    'cloud metadata' \
    'symlink swaps' \
    'fork, daemon, detached descendant' \
    'wrong reviewer account' \
    'Run two real reviews concurrently' \
    'Kill one model compartment' \
    'Force-push' \
    'Cloud-default acceptance'; do
    assert_grep "$required" "$DOC" "operator acceptance omits $required"
  done
  assert_grep '2026-08-12' "$EVIDENCE" "dated Linux evidence is missing"
  pass "operator documentation enumerates malicious, concurrency, fault, force-push, and cloud-default acceptance"
}

shared_capacity_unit() {
  python3 - "$ROOT/bin/fm-crosscheck-azure.py" <<'PY' || fail "shared model capacity binding failed"
import importlib.util,json,os,sys,tempfile,types
spec=importlib.util.spec_from_file_location("azure_adapter",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
stub_dir=tempfile.mkdtemp()
stub=os.path.join(stub_dir,"lifecycle-stub.sh"); capture=os.path.join(stub_dir,"arguments.txt")
open(stub,"w").write("#!/bin/sh\nprintf '%s\\n' \"$@\" > "+capture+"\ncat "+os.path.join(stub_dir,"reply.json")+"\n")
os.chmod(stub,0o755)
os.environ["FM_CROSSCHECK_AZURE_LIFECYCLE"]=stub
runner=types.SimpleNamespace(
    SKU_FAMILY={"Standard_D4as_v6":"standardDav6Family"},
    SKU_VCPUS={"Standard_D4as_v6":4},
    retail_rate=lambda _env,_sku:0.2,
    environment=lambda:{},
)
config={"subscription":"5f0f9efb-723c-4bd8-a2e2-ba13625ea014","reviewer_sku":"Standard_D4as_v6"}
identity={"review_generation":"abcdefabcdefabcdefabcdef"}
reservation_id="ccm-abcdefabcdef"
reply={"reservation_id":reservation_id,"status":"queued","reason":"specialized envelope is saturated"}
open(os.path.join(stub_dir,"reply.json"),"w").write(json.dumps(reply))
try: m.reserve_model_capacity(config,identity,runner)
except m.AzureCrosscheckError as exc: assert "queued the model compartment" in str(exc)
else: raise AssertionError("queued reservation was treated as reserved")
reply["status"]="reserved"
open(os.path.join(stub_dir,"reply.json"),"w").write(json.dumps(reply))
value=m.reserve_model_capacity(config,identity,runner)
assert value["reservation_id"]==reservation_id and value["sku"]=="Standard_D4as_v6"
arguments=open(capture).read().splitlines()
assert arguments[0]=="capacity-reserve" and "--role" in arguments
assert arguments[arguments.index("--role")+1]=="crosscheck"
assert arguments[arguments.index("--vcpus")+1]=="4"
reply["reservation_id"]="ccm-000000000000"
open(os.path.join(stub_dir,"reply.json"),"w").write(json.dumps(reply))
try: m.reserve_model_capacity(config,identity,runner)
except m.AzureCrosscheckError as exc: assert "wrong identity" in str(exc)
else: raise AssertionError("foreign reservation identity accepted")
m.release_model_capacity(config,value)
release_arguments=open(capture).read().splitlines()
assert release_arguments[0]=="capacity-release"
assert release_arguments[release_arguments.index("--reservation-id")+1]==reservation_id
del os.environ["FM_CROSSCHECK_AZURE_LIFECYCLE"]
PY
  pass "the model compartment reserves and releases exact shared allocator capacity and honors queued refusals"
}

image_and_policy_contract() {
  local params
  python3 - "$ROOT/docs/azure-crosscheck/model-image.json" "$ROOT/docs/azure-crosscheck/network-policy.json" <<'PY' || fail "image/policy declarations are not exact"
import json,sys
image=json.load(open(sys.argv[1]))
policy=json.load(open(sys.argv[2]))
parameters=image["parameters"]
assert "ubuntuExactVersion" in parameters and "defaultValue" not in parameters["ubuntuExactVersion"]
for name in (
    "codexCliUrl","codexCliSha256","codexCliBytes",
    "claudeCliUrl","claudeCliSha256","claudeCliBytes",
    "modelGuestSha256","modelGuestBase64",
):
    assert name in parameters, name
inline="\n".join(image["resources"][0]["properties"]["customize"][0]["inline"])
for marker in (
    "mcp=disabled","skills=disabled","extensions=disabled","sessions=disabled","sha256sum -c",
    "/usr/local/bin/codex","/usr/local/bin/claude",
):
    assert marker in inline, marker
assert image["resources"][0]["properties"]["distribute"][0]["type"]=="ManagedImage"
rules={rule["name"]:rule["properties"] for rule in policy["resources"][0]["properties"]["securityRules"]}
assert rules["deny-all-inbound"]["access"]=="Deny" and rules["deny-all-inbound"]["direction"]=="Inbound"
assert rules["deny-metadata-outbound"]["destinationAddressPrefix"]=="169.254.169.254/32"
assert rules["deny-metadata-outbound"]["priority"]<rules["allow-azure-dns-outbound"]["priority"]
assert rules["allow-azure-dns-outbound"]["destinationAddressPrefix"]=="168.63.129.16/32"
assert rules["allow-provider-endpoint-outbound"]["access"]=="Allow"
assert rules["deny-vnet-outbound"]["destinationAddressPrefix"]=="VirtualNetwork"
assert rules["deny-all-outbound"]["priority"]==4096
allows=[name for name,rule in rules.items() if rule["access"]=="Allow"]
assert sorted(allows)==["allow-azure-dns-outbound","allow-provider-endpoint-outbound"]
PY
  params=$(mktemp)
  printf '{"parameters":{}}\n' >"$params"
  if "$ROOT/bin/fm-crosscheck-azure-image.sh" image-build --subscription s --resource-group g --parameters "$params" >/dev/null 2>&1; then
    fail "image-build ran without --confirm-build"
  fi
  if "$ROOT/bin/fm-crosscheck-azure-image.sh" policy-apply --subscription s --resource-group g --parameters "$params" >/dev/null 2>&1; then
    fail "policy-apply ran without --confirm-apply"
  fi
  if "$ROOT/bin/fm-crosscheck-azure-image.sh" image-build --subscription s --resource-group g --parameters "$params" --confirm-build --confirm-subscription other >/dev/null 2>&1; then
    fail "image-build accepted a mismatched subscription confirmation"
  fi
  rm -f "$params"
  pass "image and network-policy mutations are declaration-owned and refuse without exact confirmations"
}

static_contract
adapter_mode_unit
identity_outcome_unit
account_and_cleanup_identity_unit
bridge_security_unit
replay_positive_and_failure_unit
shared_capacity_unit
image_and_policy_contract
documented_acceptance_contract
printf 'Azure Crosscheck tests passed.\n'
