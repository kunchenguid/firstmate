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
  mkdir -p "$path/tools/agent-fleet"
  cp "$ROOT/tools/agent-fleet/uv.lock" "$path/tools/agent-fleet/uv.lock"
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
    FM_AZURE_OWNER_TAG=owner \
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
assert vm["properties"]["storageProfile"]["osDisk"]["deleteOption"] == "Detach"
assert vm["properties"]["networkProfile"]["networkInterfaces"][0]["properties"]["deleteOption"] == "Detach"
assert "shutdown -h now" in safety_shutdown["properties"]["source"]["script"]
assert "expiryUtc" in template["parameters"]
host = Path(sys.argv[2]).read_text(encoding="utf-8")
guest = Path(sys.argv[3]).read_text(encoding="utf-8")
executor = Path(sys.argv[4]).read_text(encoding="utf-8")
for required in ("request_digest", "command_digest", "snapshot_digest", "vm_instance_id", "boot_id", "expected_result_digest"):
    assert required in host
for required in ("MemoryMax", "MemorySwapMax=0", "TasksMax", "CPUQuota", "RuntimeMaxSec", "IPAddressDeny=any", "hidepid=2", "tc qdisc replace", "rate 1mbit", "max-filesize = 536870912", "BOOTSTRAP_NETWORK_BYTE_CEILING", "aggregate trusted-bootstrap network byte ceiling"):
    assert required in guest
assert "bootstrapEgressRateBitsPerSecond" in template["parameters"]
assert "python3 -m pip" not in guest and "run_bootstrap_network pip" not in guest
for required in ("timeout=timeout_seconds", "foundation_gate", "If-Match", "identities", "max_billable_lifetime_hours"):
    assert required in host
for forbidden in ("GITHUB_TOKEN", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "AZURE_CLIENT_SECRET", "SSH_AUTH_SOCK"):
    assert forbidden not in executor
assert '"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' in executor
command_helper = (Path(sys.argv[2]).parent / "fm-azure-runner-command.sh").read_text(encoding="utf-8")
assert "curl" not in command_helper and "pip install" not in command_helper
assert "uv 0.9.10" in command_helper and "0.11.0" in command_helper
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
    assert set(archive.getnames()) == {"request.json", "snapshot.bundle", "runner-exec.py", "shellcheck.tar.xz", "uv.tar.gz", "agent-fleet-wheelhouse.tar"}
assert request["protocol"]["agent_fleet_python"]["lock_digest"].startswith("sha256:")
assert {item["name"] for item in request["protocol"]["agent_fleet_python"]["wheels"]} == {"iniconfig", "packaging", "pluggy", "pygments", "pytest", "ruff"}
PY
  mkdir -p "$tmp/offline-wheelhouse" "$tmp/offline-target"
  tar -xOf "$home/state/azure-runner/payloads/$invocation/input.tar.gz" agent-fleet-wheelhouse.tar >"$tmp/wheelhouse.tar"
  tar -xf "$tmp/wheelhouse.tar" -C "$tmp/offline-wheelhouse"
  UV_CACHE_DIR="$tmp/empty-uv-cache" UV_OFFLINE=1 uv pip install \
    --target "$tmp/offline-target" --python-platform x86_64-manylinux_2_17 \
    --offline --no-index --find-links "$tmp/offline-wheelhouse" pytest==9.1.1 ruff==0.15.21 >/dev/null || \
    fail "fresh empty-cache Linux target could not resolve the staged locked wheel closure offline"
  [ -f "$tmp/offline-target/pytest/__init__.py" ] && [ -d "$tmp/offline-target/ruff-0.15.21.dist-info" ] || \
    fail "fresh offline wheel closure did not install the locked pytest/ruff environment"
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
  "resource show")
    args="$*"
    base="/subscriptions/$FM_AZURE_SUBSCRIPTION_ID/resourceGroups/rg-firstmate-pilot-eastus-001/providers"
    common='"tags":{"workload":"firstmate","deployment-generation":"gen-one","cleanup-owner":"owner"}'
    case "$args" in
      *Microsoft.Storage/storageAccounts/fmteststorage0001*)
        printf '{"id":"%s/Microsoft.Storage/storageAccounts/fmteststorage0001","location":"eastus",%s,"properties":{"publicNetworkAccess":"Disabled","allowSharedKeyAccess":false,"allowBlobPublicAccess":false,"supportsHttpsTrafficOnly":true,"minimumTlsVersion":"TLS1_2","networkAcls":{"defaultAction":"Deny","bypass":"None"}}}\n' "$base" "$common" ;;
      *Microsoft.Network/virtualNetworks/vnet-fmtest-eus/subnets/snet-validation-shards*)
        printf '{"id":"%s/Microsoft.Network/virtualNetworks/vnet-fmtest-eus/subnets/snet-validation-shards","properties":{"addressPrefix":"10.42.7.0/24","networkSecurityGroup":{"id":"%s/Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated"},"natGateway":{"id":"%s/Microsoft.Network/natGateways/nat-fmtest-eus"},"privateEndpointNetworkPolicies":"Enabled"}}\n' "$base" "$base" "$base" ;;
      *Microsoft.Network/virtualNetworks/vnet-fmtest-eus*)
        printf '{"id":"%s/Microsoft.Network/virtualNetworks/vnet-fmtest-eus","location":"eastus",%s,"properties":{}}\n' "$base" "$common" ;;
      *Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated*)
        printf '{"id":"%s/Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated",%s,"properties":{"securityRules":[{"name":"deny-public-inbound","properties":{"direction":"Inbound","access":"Deny","sourceAddressPrefix":"Internet"}},{"name":"deny-vnet-cross-compartment-inbound","properties":{"direction":"Inbound","access":"Deny","sourceAddressPrefix":"VirtualNetwork"}}]}}\n' "$base" "$common" ;;
      *Microsoft.Network/natGateways/nat-fmtest-eus*)
        printf '{"id":"%s/Microsoft.Network/natGateways/nat-fmtest-eus","location":"eastus",%s,"properties":{}}\n' "$base" "$common" ;;
      *Microsoft.Network/privateEndpoints/pe-fmtest-blob/privateDnsZoneGroups/default*)
        printf '{"id":"%s/Microsoft.Network/privateEndpoints/pe-fmtest-blob/privateDnsZoneGroups/default","properties":{"privateDnsZoneConfigs":[{"properties":{"privateDnsZoneId":"%s/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"}}]}}\n' "$base" "$base" ;;
      *Microsoft.Network/privateEndpoints/pe-fmtest-blob*)
        printf '{"id":"%s/Microsoft.Network/privateEndpoints/pe-fmtest-blob",%s,"properties":{"subnet":{"id":"%s/Microsoft.Network/virtualNetworks/vnet-fmtest-eus/subnets/snet-private-endpoints"},"networkInterfaces":[{"id":"%s/Microsoft.Network/networkInterfaces/pe-fmtest-blob.nic"}],"privateLinkServiceConnections":[{"properties":{"privateLinkServiceId":"%s/Microsoft.Storage/storageAccounts/fmteststorage0001","groupIds":["blob"],"privateLinkServiceConnectionState":{"status":"Approved"}}}]}}\n' "$base" "$common" "$base" "$base" "$base" ;;
      *) exit 3 ;;
    esac
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
  "resource show")
    args="$*"
    base="/subscriptions/$FM_AZURE_SUBSCRIPTION_ID/resourceGroups/rg-firstmate-pilot-eastus-001/providers"
    common='"tags":{"workload":"firstmate","deployment-generation":"gen-one","cleanup-owner":"owner"}'
    case "$args" in
      *Microsoft.Storage/storageAccounts/fmteststorage0001*)
        printf '{"id":"%s/Microsoft.Storage/storageAccounts/fmteststorage0001","location":"eastus",%s,"properties":{"publicNetworkAccess":"Disabled","allowSharedKeyAccess":false,"allowBlobPublicAccess":false,"supportsHttpsTrafficOnly":true,"minimumTlsVersion":"TLS1_2","networkAcls":{"defaultAction":"Deny","bypass":"None"}}}\n' "$base" "$common" ;;
      *Microsoft.Network/virtualNetworks/vnet-fmtest-eus/subnets/snet-validation-shards*)
        printf '{"id":"%s/Microsoft.Network/virtualNetworks/vnet-fmtest-eus/subnets/snet-validation-shards","properties":{"addressPrefix":"10.42.7.0/24","networkSecurityGroup":{"id":"%s/Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated"},"natGateway":{"id":"%s/Microsoft.Network/natGateways/nat-fmtest-eus"},"privateEndpointNetworkPolicies":"Enabled"}}\n' "$base" "$base" "$base" ;;
      *Microsoft.Network/virtualNetworks/vnet-fmtest-eus*)
        printf '{"id":"%s/Microsoft.Network/virtualNetworks/vnet-fmtest-eus","location":"eastus",%s,"properties":{}}\n' "$base" "$common" ;;
      *Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated*)
        printf '{"id":"%s/Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated",%s,"properties":{"securityRules":[{"name":"deny-public-inbound","properties":{"direction":"Inbound","access":"Deny","sourceAddressPrefix":"Internet"}},{"name":"deny-vnet-cross-compartment-inbound","properties":{"direction":"Inbound","access":"Deny","sourceAddressPrefix":"VirtualNetwork"}}]}}\n' "$base" "$common" ;;
      *Microsoft.Network/natGateways/nat-fmtest-eus*)
        printf '{"id":"%s/Microsoft.Network/natGateways/nat-fmtest-eus","location":"eastus",%s,"properties":{}}\n' "$base" "$common" ;;
      *Microsoft.Network/privateEndpoints/pe-fmtest-blob/privateDnsZoneGroups/default*)
        printf '{"id":"%s/Microsoft.Network/privateEndpoints/pe-fmtest-blob/privateDnsZoneGroups/default","properties":{"privateDnsZoneConfigs":[{"properties":{"privateDnsZoneId":"%s/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"}}]}}\n' "$base" "$base" ;;
      *Microsoft.Network/privateEndpoints/pe-fmtest-blob*)
        printf '{"id":"%s/Microsoft.Network/privateEndpoints/pe-fmtest-blob",%s,"properties":{"subnet":{"id":"%s/Microsoft.Network/virtualNetworks/vnet-fmtest-eus/subnets/snet-private-endpoints"},"networkInterfaces":[{"id":"%s/Microsoft.Network/networkInterfaces/pe-fmtest-blob.nic"}],"privateLinkServiceConnections":[{"properties":{"privateLinkServiceId":"%s/Microsoft.Storage/storageAccounts/fmteststorage0001","groupIds":["blob"],"privateLinkServiceConnectionState":{"status":"Approved"}}}]}}\n' "$base" "$common" "$base" "$base" "$base" ;;
      *) exit 3 ;;
    esac
    ;;
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

foundation_binding_matrix() {
  python3 - "$HOST" <<'PY' || fail "complete foundation identity/private-network matrix failed"
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("runner_host_foundation", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
env = {
    "subscription": "sub", "resource_group": "rg", "prefix": "prefix", "storage": "store", "vnet": "vnet-prefix-eus",
    "subnet": "snet-validation-shards", "elastic_nsg": "nsg-prefix-elastic-isolated", "nat": "nat-prefix-eus",
    "blob_private_endpoint": "pe-prefix-blob", "blob_private_dns_zone": "privatelink.blob.core.windows.net",
    "deployment_generation": "gen-one", "owner": "owner", "azure_operation_count": 0,
}
def rid(provider, kind, name):
    return "/subscriptions/sub/resourceGroups/rg/providers/{}/{}/{}".format(provider, kind, name)
common = {"workload": "firstmate", "deployment-generation": "gen-one", "cleanup-owner": "owner"}
store_id = rid("Microsoft.Storage", "storageAccounts", "store")
vnet_id = rid("Microsoft.Network", "virtualNetworks", "vnet-prefix-eus")
subnet_id = vnet_id + "/subnets/snet-validation-shards"
nsg_id = rid("Microsoft.Network", "networkSecurityGroups", "nsg-prefix-elastic-isolated")
nat_id = rid("Microsoft.Network", "natGateways", "nat-prefix-eus")
pip_id = rid("Microsoft.Network", "publicIPAddresses", "pip-prefix-nat-eus")
pe_id = rid("Microsoft.Network", "privateEndpoints", "pe-prefix-blob")
dns_id = "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
dns_link_id = dns_id + "/virtualNetworkLinks/firstmate-vnet"
pe_nic_id = rid("Microsoft.Network", "networkInterfaces", "pe-prefix-blob.nic")
resources = {
    store_id.lower(): {"id": store_id, "location": "eastus", "kind": "StorageV2", "sku": {"name": "Standard_ZRS"}, "tags": common, "properties": {"accessTier": "Hot", "defaultToOAuthAuthentication": True, "publicNetworkAccess": "Disabled", "allowSharedKeyAccess": False, "allowBlobPublicAccess": False, "supportsHttpsTrafficOnly": True, "minimumTlsVersion": "TLS1_2", "networkAcls": {"defaultAction": "Deny", "bypass": "None"}}},
    vnet_id.lower(): {"id": vnet_id, "location": "eastus", "tags": common, "properties": {"addressSpace": {"addressPrefixes": ["10.42.0.0/16"]}}},
    subnet_id.lower(): {"id": subnet_id, "properties": {"addressPrefix": "10.42.7.0/24", "networkSecurityGroup": {"id": nsg_id}, "natGateway": {"id": nat_id}, "privateEndpointNetworkPolicies": "Enabled"}},
    (vnet_id + "/subnets/snet-private-endpoints").lower(): {"id": vnet_id + "/subnets/snet-private-endpoints", "properties": {"addressPrefix": "10.42.3.0/27", "privateEndpointNetworkPolicies": "Disabled"}},
    nsg_id.lower(): {"id": nsg_id, "location": "eastus", "tags": common, "properties": {"securityRules": [{"name": "deny-public-inbound", "properties": {"priority": 100, "direction": "Inbound", "access": "Deny", "protocol": "*", "sourcePortRange": "*", "destinationPortRange": "*", "sourceAddressPrefix": "Internet", "destinationAddressPrefix": "*"}}, {"name": "deny-vnet-cross-compartment-inbound", "properties": {"priority": 110, "direction": "Inbound", "access": "Deny", "protocol": "*", "sourcePortRange": "*", "destinationPortRange": "*", "sourceAddressPrefix": "VirtualNetwork", "destinationAddressPrefix": "*"}}]}},
    pip_id.lower(): {"id": pip_id, "location": "eastus", "sku": {"name": "Standard"}, "tags": common, "properties": {"publicIPAllocationMethod": "Static", "publicIPAddressVersion": "IPv4", "idleTimeoutInMinutes": 4}},
    nat_id.lower(): {"id": nat_id, "location": "eastus", "sku": {"name": "Standard"}, "tags": common, "properties": {"idleTimeoutInMinutes": 10, "publicIpAddresses": [{"id": pip_id}]}},
    pe_id.lower(): {"id": pe_id, "location": "eastus", "tags": common, "properties": {"subnet": {"id": vnet_id + "/subnets/snet-private-endpoints"}, "networkInterfaces": [{"id": pe_nic_id}], "privateLinkServiceConnections": [{"name": "blob", "properties": {"privateLinkServiceId": store_id, "groupIds": ["blob"], "privateLinkServiceConnectionState": {"status": "Approved"}}}]}},
    pe_nic_id.lower(): {"id": pe_nic_id, "properties": {"resourceGuid": "pe-nic-guid", "privateEndpoint": {"id": pe_id}, "ipConfigurations": [{"properties": {"subnet": {"id": vnet_id + "/subnets/snet-private-endpoints"}}}]}},
    dns_id.lower(): {"id": dns_id, "location": "global", "tags": common},
    dns_link_id.lower(): {"id": dns_link_id, "location": "global", "properties": {"registrationEnabled": False, "virtualNetwork": {"id": vnet_id}}},
    (pe_id + "/privateDnsZoneGroups/default").lower(): {"id": pe_id + "/privateDnsZoneGroups/default", "properties": {"privateDnsZoneConfigs": [{"name": "blob", "properties": {"privateDnsZoneId": dns_id}}]}},
}
def run_gate(values):
    def fake_az(env_arg, args, **kwargs):
        resource_id = args[args.index("--ids") + 1].lower()
        return json.loads(json.dumps(values[resource_id])), 0, ""
    module.az_command = fake_az
    module.foundation_gate(env)
run_gate(resources)
for resource_id, mutation in (
    (store_id, lambda r: r["tags"].update({"cleanup-owner": "foreign"})),
    (store_id, lambda r: r["properties"].update({"publicNetworkAccess": "Enabled"})),
    (vnet_id, lambda r: r.update({"id": vnet_id + "-foreign"})),
    (vnet_id, lambda r: r["properties"]["addressSpace"].update({"addressPrefixes": ["10.99.0.0/16"]})),
    (subnet_id, lambda r: r["properties"]["networkSecurityGroup"].update({"id": nsg_id + "-foreign"})),
    (subnet_id, lambda r: r["properties"]["natGateway"].update({"id": nat_id + "-foreign"})),
    (vnet_id + "/subnets/snet-private-endpoints", lambda r: r["properties"].update({"privateEndpointNetworkPolicies": "Enabled"})),
    (nsg_id, lambda r: r["properties"].update({"securityRules": []})),
    (nsg_id, lambda r: r["properties"]["securityRules"].append({"name": "allow-public", "properties": {"priority": 90, "direction": "Inbound", "access": "Allow", "protocol": "*", "sourcePortRange": "*", "destinationPortRange": "*", "sourceAddressPrefix": "Internet", "destinationAddressPrefix": "*"}})),
    (pip_id, lambda r: r["sku"].update({"name": "Basic"})),
    (nat_id, lambda r: r["tags"].update({"deployment-generation": "foreign"})),
    (nat_id, lambda r: r["properties"]["publicIpAddresses"][0].update({"id": "/foreign"})),
    (pe_id, lambda r: r["properties"]["subnet"].update({"id": "/foreign"})),
    (pe_id, lambda r: r["properties"]["privateLinkServiceConnections"][0].update({"name": "foreign"})),
    (pe_id, lambda r: r["properties"]["privateLinkServiceConnections"][0]["properties"]["privateLinkServiceConnectionState"].update({"status": "Rejected"})),
    (pe_id, lambda r: r["properties"].update({"networkInterfaces": []})),
    (pe_nic_id, lambda r: r["properties"]["privateEndpoint"].update({"id": "/foreign"})),
    (dns_id, lambda r: r.update({"id": dns_id + "-foreign"})),
    (dns_link_id, lambda r: r["properties"]["virtualNetwork"].update({"id": "/foreign"})),
    (pe_id + "/privateDnsZoneGroups/default", lambda r: r["properties"]["privateDnsZoneConfigs"][0].update({"name": "foreign"})),
    (pe_id + "/privateDnsZoneGroups/default", lambda r: r["properties"]["privateDnsZoneConfigs"][0]["properties"].update({"privateDnsZoneId": "/foreign"})),
):
    changed = json.loads(json.dumps(resources))
    mutation(changed[resource_id.lower()])
    try:
        run_gate(changed)
    except module.RunnerError:
        pass
    else:
        raise AssertionError("foreign foundation binding accepted: {}".format(resource_id))

# Dispatch proves immediately before staging and again immediately before compute create.
sequence = []
module.scope_gate = lambda e: None
module.sku_quota_gate = lambda e, limits: None
module.budget_gate = lambda e, limits: {"max_increment": 1}
module.foundation_gate = lambda e: sequence.append("foundation")
module.active_runner_vms = lambda e: []
module.storage_upload = lambda *args, **kwargs: sequence.append("stage")
module.blob_sas = lambda *args, **kwargs: "https://capability"
module.create_vm = lambda e, s: sequence.append("create-vm")
module.create_run_command = lambda *args, **kwargs: (_ for _ in ()).throw(module.RunnerError("stop after create"))
module.transition = lambda e, s, phase, note=None, **updates: s.update({"phase": phase, **updates})
class FakeLease:
    def __init__(self, *args): pass
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def assert_held(self): pass
module.AdmissionLease = FakeLease
state = {"request": {"limits": {"wall_seconds": 3600}}, "phase": "prepared", "input_path": "/input", "staging": {"input_blob": "in", "output_blob": "out"}}
try:
    module.dispatch_prepared({"subscription": "sub", "max_concurrency": 1}, state, "sub")
except module.RunnerError as exc:
    assert "stop after create" in str(exc)
else:
    raise AssertionError("dispatch fixture did not stop")
assert sequence[-4:] == ["foundation", "stage", "foundation", "create-vm"]
PY
  pass "foundation exact owner/resource/subnet/NSG/NAT/private-endpoint/DNS matrix and mutation-boundary reproof pass"
}

audit_blocker_regressions() {
  python3 - "$HOST" <<'PY' || fail "complete audit-blocker adversarial matrix failed"
import importlib.util
import json
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
        "home_binding": "sha256:" + "0" * 64,
        "task": "task-one",
        "generation": "gen-one",
        "fence": "sha256:" + "1" * 64,
        "repository": {"snapshot_digest": "sha256:" + "2" * 64},
        "command_digest": "sha256:" + "3" * 64,
        "resource_class": "behavior-heavy",
        "limits": {"sku": "Standard_D4as_v6", "sku_family": "standardDav6Family", "wall_seconds": 3600},
    },
    "resources": {
        "vm_id": "/vm/exact",
        "nic_id": "/nic/exact",
        "os_disk_id": "/disk/exact",
        "run_command_name": "execute",
        "safety_run_command_name": "safety-shutdown",
        "identities": {},
    },
    "attempt": 1,
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
module.az_command = lambda *args, **kwargs: ([], 0, "") if args[1][0:2] == ["resource", "list"] else (_ for _ in ()).throw(AssertionError("foreign resource reached delete"))
try:
    module.cleanup_partial_capacity({"deployment_generation": "gen-one", "owner": "owner", "resource_group": "rg"}, state)
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
assert cost["max_increment"] >= 210
assert set(cost["first_hour"]["categories"]) == {
    "vm_compute", "os_disk_storage_capacity", "nat_gateway", "public_ip", "private_endpoints",
    "private_dns", "monitoring", "boot_diagnostics", "storage_capacity", "storage_operations",
    "control_operations", "provisioning_control_interval", "nat_data_processing", "internet_egress",
    "trusted_bootstrap_traffic", "foundation_shared_meter_reserve", "repository_command_egress",
}
assert cost["first_day"]["total"] > cost["first_hour"]["total"]
assert cost["first_day"]["vm_network_bytes"] <= module.MAX_BOOTSTRAP_NETWORK_BYTES
assert cost["first_hour"]["vm_network_bytes"] < cost["first_day"]["vm_network_bytes"]
assert cost["first_day"]["control_operation_ceiling"] == module.RUNNER_CONTROL_OPERATION_CEILING

# Complete one-property-at-a-time disposable-resource identity matrix.
env = {"deployment_generation": "gen-one", "owner": "owner", "resource_group": "rg"}
expected_tags = module.ownership_tags(env, state)
resources = {
    "vm": {"id": "/vm/exact", "etag": '"vm-etag"', "tags": dict(expected_tags), "properties": {"vmId": "vm-instance"}},
    "nic": {"id": "/nic/exact", "etag": '"nic-etag"', "tags": dict(expected_tags), "properties": {"resourceGuid": "nic-guid", "virtualMachine": {"id": "/vm/exact"}}},
    "disk": {"id": "/disk/exact", "etag": '"disk-etag"', "tags": dict(expected_tags), "managedBy": "/vm/exact", "properties": {"uniqueId": "disk-unique"}},
    "run-command": {"id": "/vm/exact/runCommands/execute", "etag": '"run-etag"', "tags": dict(expected_tags), "properties": {"provisioningState": "Succeeded"}},
    "run-command-safety": {"id": "/vm/exact/runCommands/safety-shutdown", "etag": '"safety-etag"', "tags": dict(expected_tags), "properties": {"provisioningState": "Succeeded"}},
}
state["resources"].update({
    "vm_instance_id": "vm-instance",
    "run_command_id": resources["run-command"]["id"],
    "safety_run_command_id": resources["run-command-safety"]["id"],
    "identities": {
        "vm": module.immutable_identity(resources["vm"], "vm"),
        "nic": module.immutable_identity(resources["nic"], "nic"),
        "disk": module.immutable_identity(resources["disk"], "disk"),
        "run-command": module.immutable_identity(resources["run-command"], "run-command"),
        "run-command-execute": module.immutable_identity(resources["run-command"], "run-command"),
        "run-command-safety": module.immutable_identity(resources["run-command-safety"], "run-command"),
    },
})
original_reader = module.read_exact_resource
for kind, resource in {key: value for key, value in resources.items() if key != "run-command-safety"}.items():
    resource_id = resource["id"]
    for tag in (
        "workload", "firstmate-role", "lifecycle", "deployment-generation", "cleanup-owner",
        "home-binding", "task-binding", "task-generation", "invocation-binding", "attempt", "fence",
        "snapshot-digest", "command-digest", "resource-class", "selected-sku", "sku-family",
        "cost-attribution", "cleanup-token",
    ):
        changed = json.loads(json.dumps(resource))
        changed["tags"][tag] = "foreign"
        module.read_exact_resource = lambda env_arg, id_arg, kind_arg, changed=changed: (True, changed)
        try:
            module.verify_live_resource_identity(env, state, kind, resource_id)
        except module.RunnerError:
            pass
        else:
            raise AssertionError("foreign {} {} was accepted".format(kind, tag))
for kind, field, container in (
    ("vm", "vmId", "properties"),
    ("nic", "resourceGuid", "properties"),
    ("disk", "uniqueId", "properties"),
    ("run-command", "provisioningState", "properties"),
):
    changed = json.loads(json.dumps(resources[kind]))
    changed[container][field] = "foreign"
    module.read_exact_resource = lambda env_arg, id_arg, kind_arg, changed=changed: (True, changed)
    try:
        module.verify_live_resource_identity(env, state, kind, resources[kind]["id"])
    except module.RunnerError:
        pass
    else:
        raise AssertionError("foreign {} immutable {} was accepted".format(kind, field))
for kind, changed in (
    ("nic", {"virtualMachine": {"id": "/vm/foreign"}, "resourceGuid": "nic-guid"}),
    ("disk", {"uniqueId": "disk-unique"}),
):
    resource = json.loads(json.dumps(resources[kind]))
    if kind == "nic":
        resource["properties"].update(changed)
    else:
        resource["managedBy"] = "/vm/foreign"
    module.read_exact_resource = lambda env_arg, id_arg, kind_arg, resource=resource: (True, resource)
    try:
        module.verify_live_resource_identity(env, state, kind, resources[kind]["id"])
    except module.RunnerError:
        pass
    else:
        raise AssertionError("foreign {} VM ownership was accepted".format(kind))
module.read_exact_resource = original_reader

# VM-absent cleanup inventories residual Run Commands and refuses an unplanned one.
module.az_command = lambda env_arg, args, **kwargs: ([{"id": "/vm/exact/runCommands/foreign", "tags": {}}], 0, "")
try:
    module.cleanup_partial_capacity(env, state)
except module.RunnerError as exc:
    assert "unplanned residual" in str(exc)
else:
    raise AssertionError("tagless residual Run Command was not inventoried")

# A complete classify-before-delete pass must discover a later foreign NIC
# before deleting either exact Run Command, both with and without a live VM.
exact_by_id = {
    resources["run-command"]["id"].lower(): resources["run-command"],
    resources["run-command-safety"]["id"].lower(): resources["run-command-safety"],
    resources["vm"]["id"].lower(): resources["vm"],
    resources["disk"]["id"].lower(): resources["disk"],
}
foreign_nic = json.loads(json.dumps(resources["nic"]))
foreign_nic["tags"]["cleanup-token"] = "foreign"
def classify_reader(env_arg, resource_id, kind):
    if resource_id.lower() == resources["nic"]["id"].lower():
        return True, foreign_nic
    value = exact_by_id.get(resource_id.lower())
    return (value is not None), value
listed = [{"id": value["id"], "tags": value.get("tags", {})} for value in resources.values()]
delete_calls = []
current_listing = [item for item in listed if item["id"].lower() != resources["vm"]["id"].lower()]
module.read_exact_resource = classify_reader
module.az_command = lambda env_arg, args, **kwargs: (current_listing, 0, "") if args[0:2] == ["resource", "list"] else delete_calls.append(args)
module.transition = lambda env_arg, state_arg, phase, note=None, **updates: state_arg.update({"phase": phase, **updates})
for operation, listing in (
    (lambda: module.cleanup_partial_capacity(env, state), [item for item in listed if item["id"].lower() != resources["vm"]["id"].lower()]),
    (lambda: module.cleanup(env, dict(state, phase="result-collected")), listed),
):
    current_listing[:] = listing
    delete_calls.clear()
    try:
        operation()
    except module.RunnerError as exc:
        assert "cleanup tag mismatch" in str(exc)
    else:
        raise AssertionError("foreign NIC was accepted by complete cleanup classification")
    assert not delete_calls, "cleanup mutated an exact resource before classifying the later foreign NIC"

# Exact positive cleanup deletes both commands before the VM and records the
# only allowed NIC/disk ETag transition after Azure detaches them.
import tempfile
from pathlib import Path
positive = json.loads(json.dumps(state))
positive["phase"] = "result-collected"
positive["staging"] = {"input_blob": "input", "output_blob": "output"}
live = {
    resources["run-command"]["id"].lower(): json.loads(json.dumps(resources["run-command"])),
    resources["run-command-safety"]["id"].lower(): json.loads(json.dumps(resources["run-command-safety"])),
    resources["vm"]["id"].lower(): json.loads(json.dumps(resources["vm"])),
    resources["nic"]["id"].lower(): json.loads(json.dumps(resources["nic"])),
    resources["disk"]["id"].lower(): json.loads(json.dumps(resources["disk"])),
}
deleted = []
def positive_reader(env_arg, resource_id, kind):
    value = live.get(resource_id.lower())
    return (value is not None), value
def positive_az(env_arg, args, **kwargs):
    if args[0:2] == ["resource", "list"]:
        return ([{"id": value["id"], "tags": value.get("tags", {})} for value in live.values()], 0, "")
    if args[0:3] == ["rest", "--method", "delete"]:
        resource_id = args[args.index("--url") + 1].split("https://management.azure.com", 1)[1].split("?", 1)[0]
        value = live.pop(resource_id.lower())
        deleted.append(value["id"])
        if resource_id.lower() == resources["vm"]["id"].lower():
            live[resources["nic"]["id"].lower()]["properties"].pop("virtualMachine", None)
            live[resources["nic"]["id"].lower()]["etag"] = '"nic-detached"'
            live[resources["disk"]["id"].lower()].pop("managedBy", None)
            live[resources["disk"]["id"].lower()]["etag"] = '"disk-detached"'
        return ({}, 0, "")
    raise AssertionError("unexpected positive cleanup Azure call: {}".format(args))
with tempfile.TemporaryDirectory() as tmp:
    positive_env = dict(env, state_dir=Path(tmp))
    payload = Path(tmp) / "payloads" / positive["invocation"]
    payload.mkdir(parents=True)
    positive["input_path"] = str(payload / "input.tar.gz")
    module.read_exact_resource = positive_reader
    module.az_command = positive_az
    module.save_state = lambda *args, **kwargs: None
    module.storage_delete = lambda *args, **kwargs: None
    module.transition = lambda env_arg, state_arg, phase, note=None, **updates: state_arg.update({"phase": phase, **updates})
    module.cleanup(positive_env, positive)
assert deleted == [
    resources["run-command"]["id"], resources["run-command-safety"]["id"], resources["vm"]["id"],
    resources["nic"]["id"], resources["disk"]["id"],
]
assert positive["phase"] == "complete"

# create_run_command publishes the complete ownership tags and records immutable identity.
with tempfile.TemporaryDirectory() as tmp:
    create_env = dict(env, state_dir=Path(tmp), subscription="sub")
    module.ensure_state_dirs(create_env)
    create_state = json.loads(json.dumps(state))
    create_state["phase"] = "vm-created"
    create_state["request"]["protocol"] = {"guest_digest": "sha256:" + module.sha256_file(module.GUEST)}
    create_state["input_digest"] = "sha256:" + "4" * 64
    create_state["resources"]["identities"].pop("run-command-execute", None)
    vm_for_adoption = json.loads(json.dumps(resources["vm"]))
    vm_for_adoption["properties"].update({
        "networkProfile": {"networkInterfaces": [{"id": resources["nic"]["id"]}]},
        "storageProfile": {"osDisk": {"managedDisk": {"id": resources["disk"]["id"]}}},
    })
    adoption = {
        resources["vm"]["id"].lower(): vm_for_adoption,
        resources["nic"]["id"].lower(): resources["nic"],
        resources["disk"]["id"].lower(): resources["disk"],
        resources["run-command-safety"]["id"].lower(): resources["run-command-safety"],
    }
    module.read_exact_resource = lambda env_arg, resource_id, kind: (True, adoption[resource_id.lower()])
    module.adopt_vm_identity(create_env, create_state, vm_for_adoption)
    assert create_state["resources"]["identities"]["run-command-safety"]["provisioning_state"] == "Succeeded"
    captured = {}
    def fake_az(env_arg, args, **kwargs):
        if args[0:3] == ["rest", "--method", "put"]:
            body_path = Path(args[args.index("--body") + 1][1:])
            body = json.loads(body_path.read_text())
            captured["tags"] = body["tags"]
            return ({}, 0, "")
        raise AssertionError("unexpected create Run Command call: {}".format(args))
    run_resource = json.loads(json.dumps(resources["run-command"]))
    run_resource["tags"] = module.ownership_tags(create_env, create_state)
    module.az_command = fake_az
    module.read_exact_resource = lambda env_arg, resource_id, kind: (True, run_resource)
    module.transition = lambda env_arg, state_arg, phase, note=None, **updates: state_arg.update({"phase": phase, **updates})
    module.create_run_command(create_env, create_state, "https://input", "https://output")
    assert captured["tags"] == module.ownership_tags(create_env, create_state)
    assert create_state["resources"]["identities"]["run-command-execute"]["provisioning_state"] == "Succeeded"
PY
  pass "audit blockers stay fixed: complete ownership/immutable matrix, residual inventory, Run Command creation tags, deadlines, networkless command, and itemized cost bounds"
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
  "resource show")
    args="$*"
    base="/subscriptions/$FM_AZURE_SUBSCRIPTION_ID/resourceGroups/rg-firstmate-pilot-eastus-001/providers"
    common='"tags":{"workload":"firstmate","deployment-generation":"gen-one","cleanup-owner":"owner"}'
    case "$args" in
      *Microsoft.Storage/storageAccounts/fmteststorage0001*)
        printf '{"id":"%s/Microsoft.Storage/storageAccounts/fmteststorage0001","location":"eastus",%s,"properties":{"publicNetworkAccess":"Disabled","allowSharedKeyAccess":false,"allowBlobPublicAccess":false,"supportsHttpsTrafficOnly":true,"minimumTlsVersion":"TLS1_2","networkAcls":{"defaultAction":"Deny","bypass":"None"}}}\n' "$base" "$common" ;;
      *Microsoft.Network/virtualNetworks/vnet-fmtest-eus/subnets/snet-validation-shards*)
        printf '{"id":"%s/Microsoft.Network/virtualNetworks/vnet-fmtest-eus/subnets/snet-validation-shards","properties":{"addressPrefix":"10.42.7.0/24","networkSecurityGroup":{"id":"%s/Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated"},"natGateway":{"id":"%s/Microsoft.Network/natGateways/nat-fmtest-eus"},"privateEndpointNetworkPolicies":"Enabled"}}\n' "$base" "$base" "$base" ;;
      *Microsoft.Network/virtualNetworks/vnet-fmtest-eus*)
        printf '{"id":"%s/Microsoft.Network/virtualNetworks/vnet-fmtest-eus","location":"eastus",%s,"properties":{}}\n' "$base" "$common" ;;
      *Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated*)
        printf '{"id":"%s/Microsoft.Network/networkSecurityGroups/nsg-fmtest-elastic-isolated",%s,"properties":{"securityRules":[{"name":"deny-public-inbound","properties":{"direction":"Inbound","access":"Deny","sourceAddressPrefix":"Internet"}},{"name":"deny-vnet-cross-compartment-inbound","properties":{"direction":"Inbound","access":"Deny","sourceAddressPrefix":"VirtualNetwork"}}]}}\n' "$base" "$common" ;;
      *Microsoft.Network/natGateways/nat-fmtest-eus*)
        printf '{"id":"%s/Microsoft.Network/natGateways/nat-fmtest-eus","location":"eastus",%s,"properties":{}}\n' "$base" "$common" ;;
      *Microsoft.Network/privateEndpoints/pe-fmtest-blob/privateDnsZoneGroups/default*)
        printf '{"id":"%s/Microsoft.Network/privateEndpoints/pe-fmtest-blob/privateDnsZoneGroups/default","properties":{"privateDnsZoneConfigs":[{"properties":{"privateDnsZoneId":"%s/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"}}]}}\n' "$base" "$base" ;;
      *Microsoft.Network/privateEndpoints/pe-fmtest-blob*)
        printf '{"id":"%s/Microsoft.Network/privateEndpoints/pe-fmtest-blob",%s,"properties":{"subnet":{"id":"%s/Microsoft.Network/virtualNetworks/vnet-fmtest-eus/subnets/snet-private-endpoints"},"networkInterfaces":[{"id":"%s/Microsoft.Network/networkInterfaces/pe-fmtest-blob.nic"}],"privateLinkServiceConnections":[{"properties":{"privateLinkServiceId":"%s/Microsoft.Storage/storageAccounts/fmteststorage0001","groupIds":["blob"],"privateLinkServiceConnectionState":{"status":"Approved"}}}]}}\n' "$base" "$common" "$base" "$base" "$base" ;;
      *) exit 3 ;;
    esac
    ;;
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
foundation_binding_matrix
audit_blocker_regressions
result_digest_rejection

echo "# fm-azure-runner.test.sh: all assertions passed"
