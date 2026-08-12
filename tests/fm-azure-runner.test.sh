#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Contract, fake-Azure failure, restart, integrity, dispatch, and exact-cleanup
# coverage for the private disposable Azure command runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-azure-runner.sh"
DISPATCH="$ROOT/bin/fm-azure-runner-dispatch.sh"
HOST="$ROOT/bin/fm-azure-runner.py"
GUEST="$ROOT/bin/fm-azure-runner-guest.sh"
EXECUTOR="$ROOT/bin/fm-azure-runner-exec.py"
TEMPLATE="$ROOT/docs/azure-runner/invocation.json"
SUB=11111111-1111-4111-8111-111111111111
TENANT=22222222-2222-4222-8222-222222222222

make_repo() {
  local path=$1
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" config user.name fixture
  git -C "$path" config user.email fixture@example.invalid
  mkdir -p "$path/declared"
  printf 'locked\n' >"$path/declared/dependency.lock"
  printf '# fixture\n' >"$path/README.md"
  git -C "$path" add .
  git -C "$path" commit -qm initial
}

runner() {
  local home=$1 fakebin=$2
  shift 2
  env \
    PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_AZURE_TENANT_ID="$TENANT" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_STORAGE_NAME=fmteststorage0001 \
    FM_AZURE_DEPLOYMENT_GENERATION=gen-one \
    "$RUNNER" "$@"
}

invocation_from() {
  printf '%s\n' "$1" | awk -F'[ =]' '{for (i=1;i<=NF;i++) if ($i=="invocation") {print $(i+1); exit}}'
}

static_contract() {
  python3 - "$TEMPLATE" "$HOST" "$GUEST" "$EXECUTOR" <<'PY'
import json
from pathlib import Path
import sys

template = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
text = Path(sys.argv[1]).read_text(encoding="utf-8").lower()
resources = template["resources"]
assert len(resources) == 3
nic = next(item for item in resources if item["type"] == "Microsoft.Network/networkInterfaces")
vm = next(item for item in resources if item["type"] == "Microsoft.Compute/virtualMachines")
safety_shutdown = next(item for item in resources if item["type"] == "Microsoft.Compute/virtualMachines/runCommands")
assert "publicipaddress" not in json.dumps(nic).lower()
assert "identity" not in vm
assert "ssh" not in json.dumps(vm["properties"]["osProfile"]).lower()
assert "customdata" not in text
assert "authorized_keys" not in text
assert vm["properties"]["securityProfile"]["securityType"] == "TrustedLaunch"
assert vm["properties"]["securityProfile"]["encryptionAtHost"] is True
assert vm["properties"]["storageProfile"]["osDisk"]["deleteOption"] == "Delete"
assert vm["properties"]["networkProfile"]["networkInterfaces"][0]["properties"]["deleteOption"] == "Delete"
assert "shutdown -h now" in safety_shutdown["properties"]["source"]["script"]
assert "expiryUtc" in template["parameters"]
host = Path(sys.argv[2]).read_text(encoding="utf-8")
guest = Path(sys.argv[3]).read_text(encoding="utf-8")
executor = Path(sys.argv[4]).read_text(encoding="utf-8")
for required in ("request_digest", "command_digest", "snapshot_digest", "vm_instance_id", "boot_id", "expected_result_digest"):
    assert required in host
for required in ("MemoryMax", "MemorySwapMax=0", "TasksMax", "CPUQuota", "RuntimeMaxSec", "IPAddressDeny=any", "hidepid=2"):
    assert required in guest
for required in ("timeout=timeout_seconds", "foundation_gate", "If-Match", "identities", "max_billable_lifetime_hours"):
    assert required in host
for forbidden in ("GITHUB_TOKEN", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "AZURE_CLIENT_SECRET", "SSH_AUTH_SOCK"):
    assert forbidden not in executor
assert '"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' in executor
PY
  pass "invocation template and guest protocol preserve private identity-less bounded execution"
}

dispatch_contract() {
  local tmp marker out rc
  fm_test_tmproot_into tmp fm-azure-dispatch
  marker="$tmp/local"
  FM_AZURE_RUNNER_REMOTE_CLASSES='' "$DISPATCH" lint -- bash -c "printf local >'${marker}'"
  [ "$(<"$marker")" = local ] || fail "dispatch did not preserve local default"
  rm -f "$marker"
  FM_AZURE_RUNNER_REMOTE_CLASSES=lint=validation-standard \
    FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES=lint \
    "$DISPATCH" lint -- bash -c "printf recovery >'${marker}'" >/dev/null 2>&1
  [ "$(<"$marker")" = recovery ] || fail "explicit local recovery did not run"
  rm -f "$marker"
  rc=0
  out=$(FM_AZURE_RUNNER_REMOTE_CLASSES=lint=validation-standard \
    "$DISPATCH" lint -- bash -c "printf forbidden >'${marker}'" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "remote selection ran without required fencing identity"
  [ ! -e "$marker" ] || fail "remote dispatch failure silently reran the command locally"
  assert_contains "$out" "FM_AZURE_RUNNER_TASK" "remote dispatch did not fail closed on missing task binding"
  assert_grep "  test: 'bin/fm-no-mistakes-test-command.sh'" "$ROOT/.no-mistakes.yaml" "no-mistakes test must use the local/Azure split owner"
  assert_grep 'tests/run.sh --skip-herdr' "$ROOT/bin/fm-no-mistakes-test-command.sh" "Azure test shard must select the sealed non-Herdr path"
  assert_grep 'herdr-lab|herdr-mixed' "$ROOT/bin/fm-no-mistakes-test-command.sh" "local complement must select every Herdr declaration"
  pass "command dispatch is local by default, explicit for recovery, and never falls back after remote selection"
}

prepare_contract() {
  local tmp repo home fakebin out invocation state
  fm_test_tmproot_into tmp fm-azure-prepare
  repo="$tmp/repo"
  home="$tmp/home"
  fakebin=$(fm_fakebin "$tmp")
  make_repo "$repo"
  mkdir -p "$home"
  out=$(cd "$repo" && runner "$home" "$fakebin" prepare \
    --task task-one --generation generation-one --resource-class behavior-heavy \
    --dependency declared/dependency.lock --artifact build/report.json -- bash -lc 'printf ok') || fail "prepare failed: $out"
  invocation=$(invocation_from "$out")
  [ -n "$invocation" ] || fail "prepare did not print invocation"
  state="$home/state/azure-runner/$invocation.json"
  [ -f "$state" ] || fail "prepare did not persist state"
  python3 - "$state" "$repo" <<'PY' || fail "prepared request identity assertions failed"
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
repo = Path(sys.argv[2])
request = state["request"]
unsigned = dict(request)
supplied = unsigned.pop("request_digest")
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
assert supplied == "sha256:" + hashlib.sha256(canonical).hexdigest()
assert request["repository"]["commit"] == subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
assert request["repository"]["tree"] == subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD^{tree}"], text=True).strip()
assert request["command"]["argv"] == ["bash", "-lc", "printf ok"]
assert request["dependencies"][0]["path"] == "declared/dependency.lock"
assert request["artifacts"] == ["build/report.json"]
assert request["limits"]["memory_bytes"] == 14 * 1024**3
assert request["limits"]["network_bytes"] == 0
assert request["limits"]["sku"] == "Standard_D4as_v6"
assert request["limits"]["sku_family"] == "standardDav6Family"
assert "FM_AZURE_SUBSCRIPTION_ID" not in json.dumps(request)
assert state["resources"]["vm_id"].endswith("/" + state["resources"]["vm_name"])
assert state["resources"]["nic_id"].endswith("/" + state["resources"]["nic_name"])
assert state["resources"]["os_disk_id"].endswith("/" + state["resources"]["os_disk_name"])
input_path = Path(state["input_path"])
assert state["input_digest"] == "sha256:" + hashlib.sha256(input_path.read_bytes()).hexdigest()
with tarfile.open(input_path, "r:gz") as archive:
    assert set(archive.getnames()) == {"request.json", "snapshot.bundle", "runner-exec.py"}
PY
  printf 'dirty\n' >"$repo/untracked"
  if (cd "$repo" && runner "$home" "$fakebin" prepare --task task-two --generation generation-two -- echo no) >/dev/null 2>&1; then
    fail "prepare accepted an untracked file"
  fi
  [ "$(find "$home/state/azure-runner" -name 'azr-*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "dirty refusal created invocation state"
  pass "prepare binds a clean commit/tree/bundle/command/dependency request and refuses dirty snapshots"
}

executor_semantics_unit() {
  local tmp repo request output uid gid rc
  fm_test_tmproot_into tmp fm-azure-executor
  repo="$tmp/repo"
  make_repo "$repo"
  uid=$(id -u)
  gid=$(id -g)
  request="$tmp/request.json"
  python3 - "$request" <<'PY'
import hashlib
import json
import sys

request = {
    "invocation": "azr-aaaaaaaaaaaa",
    "attempt": 1,
    "fence": "sha256:" + "1" * 64,
    "repository": {"snapshot_digest": "sha256:" + "2" * 64, "commit": "a" * 40, "tree": "b" * 40},
    "command": {"argv": ["python3", "-c", "import sys; print('out'); print('err', file=sys.stderr); raise SystemExit(7)"]},
    "limits": {
        "cpu_cores": 1, "memory_bytes": 1024**3, "pid_max": 64,
        "disk_bytes": 1024**3, "log_bytes": 1024, "artifact_bytes": 0,
        "network_bytes": 0, "wall_seconds": 10,
    },
}
canonical=lambda value: json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()
request["command_digest"]="sha256:"+hashlib.sha256(canonical(request["command"])).hexdigest()
request["request_digest"]="sha256:"+hashlib.sha256(canonical(request)).hexdigest()
open(sys.argv[1],"wb").write(canonical(request)+b"\n")
PY
  output="$tmp/output"
  printf '44444444-4444-4444-8444-444444444444\n' >"$tmp/boot-id"
  FM_AZURE_RUNNER_TEST_NO_DROP=1 FM_AZURE_RUNNER_BOOT_ID_PATH="$tmp/boot-id" "$EXECUTOR" "$request" "$repo" "$output" "$uid" "$gid" /vm/id vm-instance >/dev/null || fail "executor did not publish an ordinary command failure"
  python3 - "$output/result.json" "$output/stdout.log" "$output/stderr.log" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r["exit_code"] == 7 and r["timed_out"] is False and r["signal"] is None
assert open(sys.argv[2]).read()=="out\n"
assert open(sys.argv[3]).read()=="err\n"
PY
  rm -rf "$output"
  python3 - "$request" <<'PY'
import hashlib,json,sys
p=sys.argv[1]; r=json.load(open(p)); r["command"]={"argv":["python3","-c","import time; time.sleep(30)"]}; r["limits"]["wall_seconds"]=1
canon=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()
r["command_digest"]="sha256:"+hashlib.sha256(canon(r["command"])).hexdigest(); r.pop("request_digest",None); r["request_digest"]="sha256:"+hashlib.sha256(canon(r)).hexdigest(); open(p,"wb").write(canon(r)+b"\n")
PY
  FM_AZURE_RUNNER_TEST_NO_DROP=1 FM_AZURE_RUNNER_BOOT_ID_PATH="$tmp/boot-id" "$EXECUTOR" "$request" "$repo" "$output" "$uid" "$gid" /vm/id vm-instance >/dev/null || fail "executor did not publish timeout semantics"
  python3 - "$output/result.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r["exit_code"]==124 and r["timed_out"] is True and r["signal"] in (15,9)
PY
  pass "trusted executor preserves ordinary failure logs/exit and explicit timeout/signal semantics"
}

request_integrity_unit() {
  python3 - "$EXECUTOR" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("runner_exec", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
request = {
    "command": {"argv": ["sh", "-c", "exit 7"]},
    "limits": {
        "cpu_cores": 1, "memory_bytes": 1024**3, "pid_max": 16,
        "disk_bytes": 1024**3, "log_bytes": 1024, "artifact_bytes": 0,
        "network_bytes": 0, "wall_seconds": 1,
    },
}
request["command_digest"] = "sha256:" + module.hashlib.sha256(module.canonical_bytes(request["command"])).hexdigest()
request["request_digest"] = "sha256:" + module.hashlib.sha256(module.canonical_bytes(request)).hexdigest()
argv, limits = module.verify_request(request)
assert argv[-1] == "exit 7" and limits["pid_max"] == 16
request["command"]["argv"][-1] = "exit 0"
try:
    module.verify_request(request)
except ValueError as exc:
    assert "request digest mismatch" in str(exc)
else:
    raise AssertionError("tampered command was accepted")
PY
  pass "guest executor rejects a command changed after request digest binding"
}

write_fake_az_admission() {
  local fakebin=$1 mode=$2 log=$3
  cat >"$fakebin/az" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AZ_LOG"
case "$1 $2" in
  "account show")
    printf '{"id":"%s","tenantId":"%s","state":"Enabled"}\n' "$FM_AZURE_SUBSCRIPTION_ID" "$FM_AZURE_TENANT_ID"
    ;;
  "storage account")
    printf '{"id":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Storage/storageAccounts/fmteststorage0001","location":"eastus","publicNetworkAccess":"Disabled","allowSharedKeyAccess":false,"allowBlobPublicAccess":false,"tags":{"workload":"firstmate","deployment-generation":"gen-one"}}\n' "$FM_AZURE_SUBSCRIPTION_ID"
    ;;
  "network vnet")
    printf '{"location":"eastus","tags":{"workload":"firstmate","deployment-generation":"gen-one"},"subnets":[{"name":"snet-validation-shards","networkSecurityGroup":{"id":"/subscriptions/%s/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated"},"natGateway":{"id":"/subscriptions/%s/resourceGroups/rg/providers/Microsoft.Network/natGateways/nat-fmtest-eus"}}]}\n' "$FM_AZURE_SUBSCRIPTION_ID" "$FM_AZURE_SUBSCRIPTION_ID"
    ;;
  "network private-endpoint")
    printf '[{"privateLinkServiceConnections":[{"privateLinkServiceId":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Storage/storageAccounts/fmteststorage0001","groupIds":["blob"]}]}]\n' "$FM_AZURE_SUBSCRIPTION_ID"
    ;;
  "vm list-skus")
    if [ "$AZ_MODE" = restricted ]; then
      printf '[{"name":"Standard_D4as_v6","restrictions":[{"reasonCode":"NotAvailableForSubscription"}],"capabilities":[]}]\n'
    else
      printf '[{"name":"Standard_D4as_v6","restrictions":[],"capabilities":[{"name":"vCPUsAvailable","value":"4"},{"name":"MemoryGB","value":"16"},{"name":"CpuArchitectureType","value":"x64"},{"name":"HyperVGenerations","value":"V1,V2"},{"name":"TrustedLaunchDisabled","value":"False"},{"name":"EncryptionAtHostSupported","value":"True"}]}]\n'
    fi
    ;;
  "vm list-usage")
    printf '[{"name":{"value":"cores"},"limit":128,"currentValue":0},{"name":{"value":"standardDav6Family"},"limit":10,"currentValue":0}]\n'
    ;;
  "vm list") printf '[]\n' ;;
  "rest --method")
    if printf '%s' "$*" | grep -q 'prices.azure.com'; then
      printf '{"Items":[{"unitOfMeasure":"1 Hour","productName":"Linux","meterName":"Standard","retailPrice":0.477}]}\n'
    elif [ "$AZ_MODE" = budget ]; then
      printf '{"properties":{"columns":[{"name":"PreTaxCost"}],"rows":[[1001.0]]}}\n'
    else
      printf '{"properties":{"columns":[{"name":"PreTaxCost"}],"rows":[[0.0]]}}\n'
    fi
    ;;
  *)
    echo "unexpected fake az call: $*" >&2
    exit 88
    ;;
esac
SH
  chmod +x "$fakebin/az"
  export AZ_MODE=$mode AZ_LOG=$log
}

admission_failures() {
  local mode tmp repo home fakebin log out rc
  for mode in restricted budget; do
    fm_test_tmproot_into tmp "fm-azure-$mode"
    repo="$tmp/repo"
    home="$tmp/home"
    fakebin=$(fm_fakebin "$tmp")
    log="$tmp/az.log"
    make_repo "$repo"
    mkdir -p "$home"
    : >"$log"
    write_fake_az_admission "$fakebin" "$mode" "$log"
    rc=0
    out=$(cd "$repo" && runner "$home" "$fakebin" run --confirm-run --confirm-subscription "$SUB" \
      --task task-one --generation gen-one --resource-class validation-standard -- true 2>&1) || rc=$?
    [ "$rc" -eq 125 ] || fail "$mode admission failure returned $rc: $out"
    if [ "$mode" = restricted ]; then
      assert_contains "$out" "SKU is unavailable or restricted" "restricted SKU did not fail closed"
    else
      assert_contains "$out" "budget pressure stops new invocations" "budget pressure did not fail closed"
    fi
    assert_not_contains "$(<"$log")" "deployment group create" "$mode failure created compute"
    assert_not_contains "$(<"$log")" "storage blob upload" "$mode failure staged input"
  done
  unset AZ_MODE AZ_LOG
  pass "fake Azure SKU and budget failures refuse before staging or compute"
}

write_fake_az_absence() {
  local fakebin=$1 log=$2
  cat >"$fakebin/az" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AZ_LOG"
case "$1 $2" in
  "account show") printf '{"id":"%s","tenantId":"%s","state":"Enabled"}\n' "$FM_AZURE_SUBSCRIPTION_ID" "$FM_AZURE_TENANT_ID" ;;
  "storage account") printf '{"id":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Storage/storageAccounts/fmteststorage0001","location":"eastus","publicNetworkAccess":"Disabled","allowSharedKeyAccess":false,"allowBlobPublicAccess":false,"tags":{"workload":"firstmate","deployment-generation":"gen-one"}}\n' "$FM_AZURE_SUBSCRIPTION_ID" ;;
  "network vnet") printf '{"location":"eastus","tags":{"workload":"firstmate","deployment-generation":"gen-one"},"subnets":[{"name":"snet-validation-shards","networkSecurityGroup":{"id":"/nsg/nsg-fmtest-elastic-isolated"},"natGateway":{"id":"/nat/nat-fmtest-eus"}}]}\n' ;;
  "network private-endpoint") printf '[{"privateLinkServiceConnections":[{"privateLinkServiceId":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Storage/storageAccounts/fmteststorage0001","groupIds":["blob"]}]}]\n' "$FM_AZURE_SUBSCRIPTION_ID" ;;
  "storage blob") printf '{"exists":false}\n' ;;
  "vm show") exit 3 ;;
  "vm list") printf '[]\n' ;;
  "resource show") exit 3 ;;
  "resource list") printf '[]\n' ;;
  *) echo "unexpected absence fake: $*" >&2; exit 89 ;;
esac
SH
  chmod +x "$fakebin/az"
  export AZ_LOG=$log
}

missing_vm_fences_attempt() {
  local tmp repo home fakebin log out invocation state rc
  fm_test_tmproot_into tmp fm-azure-absent
  repo="$tmp/repo"
  home="$tmp/home"
  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/az.log"
  make_repo "$repo"
  mkdir -p "$home"
  out=$(cd "$repo" && runner "$home" "$fakebin" prepare --task task-one --generation gen-one -- true)
  invocation=$(invocation_from "$out")
  state="$home/state/azure-runner/$invocation.json"
  python3 - "$state" "$SUB" <<'PY'
import json
import sys
p=sys.argv[1]
s=json.load(open(p))
s["phase"]="command-submitted"
s["resources"].update({
 "vm_id":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Compute/virtualMachines/vm-one"%sys.argv[2],
 "vm_instance_id":"33333333-3333-4333-8333-333333333333",
 "nic_id":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Network/networkInterfaces/nic-one"%sys.argv[2],
 "os_disk_id":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Compute/disks/disk-one"%sys.argv[2],
})
json.dump(s,open(p,"w"),separators=(",",":"))
PY
  : >"$log"
  write_fake_az_absence "$fakebin" "$log"
  rc=0
  out=$(runner "$home" "$fakebin" resume --invocation "$invocation" 2>&1) || rc=$?
  [ "$rc" -eq 125 ] || fail "missing VM resume returned $rc: $out"
  assert_contains "$out" "retry requires a new fenced attempt" "missing VM did not fence duplicate execution"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["phase"])' "$state")" = absent-fenced ] || fail "missing VM was not recorded absent-fenced"
  assert_not_contains "$(<"$log")" "deployment group create" "resume duplicated an absent command"
  unset AZ_LOG
  pass "missing VM is fenced absent and cannot create a duplicate invocation"
}

audit_blocker_regressions() {
  python3 - "$HOST" <<'PY'
import importlib.util
import subprocess
import sys

spec = importlib.util.spec_from_file_location("runner_host", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

try:
    module.run([sys.executable, "-c", "import time; time.sleep(2)"], timeout_seconds=0.01)
except module.RunnerError as exc:
    assert "bounded" in str(exc)
else:
    raise AssertionError("host subprocess deadline was not enforced")

state = {
    "invocation": "azr-aaaaaaaaaaaa",
    "request": {
        "fence": "sha256:" + "1" * 64,
        "repository": {"snapshot_digest": "sha256:" + "2" * 64},
        "command_digest": "sha256:" + "3" * 64,
    },
    "resources": {
        "vm_id": "/vm/exact",
        "nic_id": "/nic/exact",
        "os_disk_id": "/disk/exact",
        "identities": {},
    },
}
foreign = {
    "id": "/nic/exact",
    "etag": '"foreign"',
    "tags": {
        "invocation-binding": "foreign",
        "fence": "foreign",
        "snapshot-digest": "foreign",
        "command-digest": "foreign",
    },
    "properties": {"virtualMachine": {"id": "/vm/foreign"}},
}
module.read_exact_resource = lambda env, resource_id, kind: (True, foreign)
module.az_command = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("foreign resource reached delete"))
try:
    module.cleanup_partial_capacity({}, state)
except module.RunnerError as exc:
    assert "tag mismatch" in str(exc)
else:
    raise AssertionError("foreign replacement was accepted for cleanup")

module.cost_query = lambda env, forecast=False: 0.0
module.retail_rate = lambda env, sku: 0.182
limits = {"sku": "Standard_D4as_v6", "network_bytes": 0}
cost = module.budget_gate({"budget_limit": 1000}, limits)
assert cost["max_network_bytes"] == 0
assert cost["max_billable_lifetime_hours"] == 24
assert cost["max_increment"] >= 250
PY
  pass "audit blockers stay fixed: host deadlines, foreign replacement refusal, networkless command, and conservative cost ceiling"
}

result_digest_rejection() {
  local tmp repo home fakebin out invocation state blob_source rc log
  fm_test_tmproot_into tmp fm-azure-result
  repo="$tmp/repo"
  home="$tmp/home"
  fakebin=$(fm_fakebin "$tmp")
  make_repo "$repo"
  mkdir -p "$home"
  out=$(cd "$repo" && runner "$home" "$fakebin" prepare --task task-one --generation gen-one -- true)
  invocation=$(invocation_from "$out")
  state="$home/state/azure-runner/$invocation.json"
  blob_source="$tmp/wrong-result.tar.gz"
  printf 'not the expected result\n' >"$blob_source"
  python3 - "$state" "$SUB" <<'PY'
import json
import sys
p=sys.argv[1]
s=json.load(open(p))
s["phase"]="result-published"
s["expected_result_digest"]="sha256:"+"0"*64
s["expected_boot_id"]="44444444-4444-4444-8444-444444444444"
s["resources"].update({
 "vm_id":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Compute/virtualMachines/vm-one"%sys.argv[2],
 "vm_instance_id":"33333333-3333-4333-8333-333333333333",
 "nic_id":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Network/networkInterfaces/nic-one"%sys.argv[2],
 "os_disk_id":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Compute/disks/disk-one"%sys.argv[2],
})
json.dump(s,open(p,"w"),separators=(",",":"))
PY
  log="$tmp/az.log"
  cat >"$fakebin/az" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AZ_LOG"
case "$1 $2" in
  "account show") printf '{"id":"%s","tenantId":"%s","state":"Enabled"}\n' "$FM_AZURE_SUBSCRIPTION_ID" "$FM_AZURE_TENANT_ID" ;;
  "storage account") printf '{"id":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Storage/storageAccounts/fmteststorage0001","location":"eastus","publicNetworkAccess":"Disabled","allowSharedKeyAccess":false,"allowBlobPublicAccess":false,"tags":{"workload":"firstmate","deployment-generation":"gen-one"}}\n' "$FM_AZURE_SUBSCRIPTION_ID" ;;
  "network vnet") printf '{"location":"eastus","tags":{"workload":"firstmate","deployment-generation":"gen-one"},"subnets":[{"name":"snet-validation-shards","networkSecurityGroup":{"id":"/nsg/nsg-fmtest-elastic-isolated"},"natGateway":{"id":"/nat/nat-fmtest-eus"}}]}\n' ;;
  "network private-endpoint") printf '[{"privateLinkServiceConnections":[{"privateLinkServiceId":"/subscriptions/%s/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Storage/storageAccounts/fmteststorage0001","groupIds":["blob"]}]}]\n' "$FM_AZURE_SUBSCRIPTION_ID" ;;
  "storage blob")
    destination=
    previous=
    for arg in "$@"; do
      [ "$previous" != --file ] || destination=$arg
      previous=$arg
    done
    cp "$AZ_BLOB_SOURCE" "$destination"
    printf '{}\n'
    ;;
  *) echo "unexpected result fake: $*" >&2; exit 90 ;;
esac
SH
  chmod +x "$fakebin/az"
  export AZ_LOG=$log AZ_BLOB_SOURCE=$blob_source
  rc=0
  out=$(runner "$home" "$fakebin" resume --invocation "$invocation" 2>&1) || rc=$?
  [ "$rc" -eq 125 ] || fail "wrong result digest returned $rc: $out"
  assert_contains "$out" "retrieved result digest" "wrong result digest was not rejected"
  assert_not_contains "$(<"$log")" "vm delete" "integrity failure deleted runner compute"
  unset AZ_LOG AZ_BLOB_SOURCE
  pass "wrong result digest is rejected before any cleanup"
}

static_contract
dispatch_contract
prepare_contract
executor_semantics_unit
request_integrity_unit
admission_failures
missing_vm_fences_attempt
audit_blocker_regressions
result_digest_rejection

echo "# fm-azure-runner.test.sh: all assertions passed"
