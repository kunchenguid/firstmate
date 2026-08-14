#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Focused queue, identity, security-negative, recovery, cost-admission, and
# static Azure contract tests for isolated no-mistakes validation cells.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VALIDATION="$ROOT/bin/fm-azure-validation.sh"
HOST="$ROOT/bin/fm-azure-validation.py"
GUEST="$ROOT/bin/fm-azure-validation-guest.sh"
BRIDGE="$ROOT/bin/fm-azure-validation-shard-bridge.py"
TEMPLATE="$ROOT/docs/azure-validation/cell.json"
DOC="$ROOT/docs/azure-validation.md"
SUB=11111111-1111-4111-8111-111111111111

make_repo() {
  local root=$1
  mkdir -p "$root/remote.git" "$root/repo"
  git -C "$root/remote.git" init -q --bare
  git -C "$root/repo" init -q -b main
  git -C "$root/repo" config user.name fixture
  git -C "$root/repo" config user.email fixture@example.invalid
  printf '# fixture\n' >"$root/repo/README.md"
  git -C "$root/repo" add README.md
  git -C "$root/repo" commit -qm initial
  git -C "$root/repo" remote add origin "file://$root/remote.git"
  git -C "$root/repo" switch -qc fm/fixture
  git -C "$root/repo" push -q -u origin fm/fixture
}

make_runtime() {
  local root=$1 provider=${2:-codex}
  mkdir -p "$root/runtime/bin"
  for executable in no-mistakes "$provider" gh gh-axi; do
    printf '#!/bin/sh\nexit 0\n' >"$root/runtime/bin/$executable"
    chmod +x "$root/runtime/bin/$executable"
  done
  python3 - "$root/runtime" "$provider" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
files=[]
for relative in ("bin/no-mistakes", "bin/"+sys.argv[2], "bin/gh", "bin/gh-axi"):
    path=root/relative
    files.append({"path":relative,"digest":"sha256:"+hashlib.sha256(path.read_bytes()).hexdigest()})
manifest={
    "schema":"fm.azure-validation-runtime/v1",
    "provider":sys.argv[2],
    "no_mistakes_version":"1.41.2",
    "no_mistakes_path":"bin/no-mistakes",
    "provider_path":"bin/"+sys.argv[2],
    "gh_path":"bin/gh",
    "gh_axi_path":"bin/gh-axi",
    "files":files,
}
(root/"runtime.json").write_text(json.dumps(manifest,separators=(",",":"))+"\n")
PY
  COPYFILE_DISABLE=1 tar -czf "$root/runtime.tar.gz" -C "$root/runtime" runtime.json bin
}

make_lease() {
  local path=$1 task=$2 generation=$3 repo_slug=$4
  cat >"$path" <<JSON
{"schema":"fm.azure-credential-lease/v1","lease_id":"lease-${task}","task":"${task}","task_generation":"${generation}","provider":"codex","provider_account_binding":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","disk_content_binding":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","disk":{"id":"/subscriptions/${SUB}/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Compute/disks/credential-${task}","etag":"etag-${task}","luks_uuid":"33333333-3333-4333-8333-333333333333","zone":"1"},"paths":{"provider_home":"provider","account_binding":"provider/.firstmate-account-binding","github_token":"github/token"},"github_authority":{"kind":"fine-grained-token","repository":"${repo_slug}","permissions":["contents:write","pull_requests:write","checks:read"]},"expires_at":"2099-08-13T12:00:00Z"}
JSON
  chmod 600 "$path"
}

validation() {
  local home=$1
  shift
  FM_HOME="$home" FM_AZURE_DEPLOYMENT_GENERATION=gen-one \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_NAMING_PREFIX=fmtest "$VALIDATION" "$@"
}

cell_from() {
  printf '%s\n' "$1" | sed -n 's/.*cell=\(azv-[a-z0-9]*\).*/\1/p'
}

static_contract() {
  python3 - "$TEMPLATE" "$HOST" "$GUEST" "$BRIDGE" "$ROOT/.no-mistakes.yaml" <<'PY' || fail "static validation-cell contract failed"
import json
from pathlib import Path
import sys

template=json.loads(Path(sys.argv[1]).read_text())
text=Path(sys.argv[1]).read_text().lower()
resources=template["resources"]
vm=next(item for item in resources if item["type"]=="Microsoft.Compute/virtualMachines")
nic=next(item for item in resources if item["type"]=="Microsoft.Network/networkInterfaces")
work=next(item for item in resources if item["type"]=="Microsoft.Compute/disks")
identity=next(item for item in resources if item["type"]=="Microsoft.ManagedIdentity/userAssignedIdentities")
assert "publicipaddress" not in json.dumps(nic).lower()
assert "customdata" not in text
assert vm["identity"]["type"]=="UserAssigned"
assert vm["properties"]["securityProfile"]["securityType"]=="TrustedLaunch"
assert vm["properties"]["securityProfile"]["encryptionAtHost"] is True
linux=vm["properties"]["osProfile"]["linuxConfiguration"]
assert linux["disablePasswordAuthentication"] is True
key=linux["ssh"]["publicKeys"][0]
assert key["path"]=="/home/fmbootstrap/.ssh/authorized_keys"
assert key["keyData"].startswith("ssh-rsa ") and key["keyData"].endswith(" firstmate-validation-blackhole")
assert vm["properties"]["storageProfile"]["osDisk"]["deleteOption"]=="Detach"
data=vm["properties"]["storageProfile"]["dataDisks"]
assert len(data)==2 and {item["lun"] for item in data}=={0,1}
assert all(item["deleteOption"]=="Detach" for item in data)
credential=next(item for item in data if item["lun"]==1)
assert credential["name"]=="[last(split(parameters('credentialDiskId'), '/'))]"
schedule=next(item for item in resources if item["type"]=="Microsoft.DevTestLab/schedules")
assert schedule["name"]=="[format('shutdown-computevm-{0}', parameters('vmName'))]"
assert schedule["properties"]["taskType"]=="ComputeVmShutdownTask"
assert schedule["properties"]["status"]=="Enabled"
safety=next(item for item in resources if item["type"]=="Microsoft.Compute/virtualMachines/runCommands")
script=safety["properties"]["source"]["script"]
assert "uriComponentToString('%0A')" in script and "\\n" not in script
assert work["properties"]["networkAccessPolicy"]=="DenyAll"
assert work["properties"]["publicNetworkAccess"]=="Disabled"
assert template["parameters"]["vmSize"]["allowedValues"]==[
    "Standard_D8as_v6","Standard_D8s_v6","Standard_D8ads_v6","Standard_D8ds_v6"
]
assert identity["tags"].find("one-validation-container")!=-1
host=Path(sys.argv[2]).read_text()
guest=Path(sys.argv[3]).read_text()
bridge=Path(sys.argv[4]).read_text()
nm=Path(sys.argv[5]).read_text()
for value in ("capacity-reserve-shape","compose_shard_plan","shared_shape_reserve","release_shape_constituent","capacity_parent","reserved_vcpus","--capacity-fence","bin/fm-lint.sh && uv run --directory tools/agent-fleet --locked ruff check ."):
    assert value in host
assert "VALIDATION_RESERVED_VCPUS =" not in host
assert "AUTHOR_RESERVED_VCPUS" not in host
assert "def admission_decision" not in host
assert "def shared_capacity_demand" not in host
assert '"ttl_schedule_id": base + "/Microsoft.DevTestLab/schedules/shutdown-computevm-{}".format(vm)' in host
for value in ("MemoryMax","MemorySwapMax=0","TasksMax","CPUQuota=700%","PrivateTmp=yes","ProtectSystem=strict","CapabilityBoundingSet=","cryptsetup luksUUID","provider account-binding marker mismatch","credential disk content binding mismatch","FM_AZURE_VALIDATION_RUNTIME_PATH","axi status","/dev/disk/azure/scsi1/lun","/dev/disk/azure/data/by-lun/"):
    assert value in guest
for value in ("fm.azure-validation-shard/v1","storage_token","vm_instance_id","boot_id","trusted_verify_manifests"):
    assert value in bridge
assert '"$FM_AZURE_VALIDATION_SHARD_BRIDGE" behavior' in nm
assert '"$FM_AZURE_VALIDATION_SHARD_BRIDGE" lint' in nm
assert "no-mistakes daemon start" not in host
assert "no-mistakes daemon stop" not in host
assert "no-mistakes daemon restart" not in host
PY
  pass "cell template and trusted bridge preserve private per-run compute, disks, identity, and cgroup isolation"
}

submit_contract() {
  local tmp home repo out cell state marker rc
  fm_test_tmproot_into tmp fm-azure-validation-submit
  home="$tmp/home"
  mkdir -p "$home"
  make_repo "$tmp/project"
  repo="$tmp/project/repo"
  make_runtime "$tmp"
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  printf 'validate exact fixture\n' >"$tmp/intent.txt"
  marker="$tmp/az-called"
  mkdir -p "$tmp/fakebin"
  cat >"$tmp/fakebin/az" <<SH
#!/bin/sh
touch '$marker'
exit 99
SH
  cat >"$tmp/fakebin/git" <<SH
#!/bin/sh
case "\$*" in
  *' remote get-url origin') printf '%s\n' 'https://github.com/fixture/repository.git' ;;
  *) exec '$(command -v git)' "\$@" ;;
esac
SH
  chmod +x "$tmp/fakebin/az" "$tmp/fakebin/git"
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-one --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/lease.json" \
    --runtime-bundle "$tmp/runtime.tar.gz" --repo "$repo") || fail "queue submit failed: $out"
  cell=$(cell_from "$out")
  [ -n "$cell" ] || fail "submit returned no cell id"
  [ ! -e "$marker" ] || fail "non-billable submit contacted Azure"
  state="$home/state/azure-validation/$cell.json"
  [ -f "$state" ] || fail "submit did not persist cell state"
  python3 - "$state" "$repo" <<'PY' || fail "submitted request identity assertions failed"
import hashlib,json,subprocess,sys,tarfile
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
request=state["request"]
unsigned=dict(request); supplied=unsigned.pop("request_digest")
canonical=json.dumps(unsigned,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()
assert supplied=="sha256:"+hashlib.sha256(canonical).hexdigest()
head=subprocess.check_output(["git","-C",sys.argv[2],"rev-parse","HEAD"],text=True).strip()
assert request["repository"]["head"]==head
assert request["deployment_generation"]=="gen-one"
assert request["limits"]["vcpus"]==8 and request["limits"]["memory_gib"]==32
assert request["limits"]["behavior_shards"]==8 and request["limits"]["reserved_vcpus"]==40
assert state["phase"]=="queued"
assert state["staging"]["container"].startswith("fmval")
serialized=Path(sys.argv[1]).read_text().lower()
for forbidden in ("ghp_","github_pat_","access_token","refresh_token","private_key"):
    assert forbidden not in serialized
with tarfile.open(state["input_path"],"r:gz") as archive:
    assert set(archive.getnames())=={"request.json","snapshot.bundle","runtime.tar.gz","shard-bridge.py"}
PY
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" queue) || fail "queue read failed: $out"
  assert_contains "$out" "cell=$cell phase=queued" "queue did not report the exact cell"
  rc=0
  out=$(FM_AZURE_VALIDATION_RESERVED_VCPUS=64 PATH="$tmp/fakebin:$PATH" validation "$home" queue 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "obsolete fixed validation-pool configuration was accepted"
  assert_contains "$out" "author and review demand share the fixed East US 128-vCPU admission ceiling" "obsolete pool refusal did not name the shared ceiling"
  printf 'dirty\n' >"$repo/untracked"
  rc=0
  PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-two --task-generation generation-two --validation-generation validation-two \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/lease.json" \
    --runtime-bundle "$tmp/runtime.tar.gz" --repo "$repo" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted a dirty worktree"
  pass "submit queues a clean pushed exact head without Azure or local validation execution"
}

security_negative_contract() {
  local tmp home repo rc out
  fm_test_tmproot_into tmp fm-azure-validation-security
  home="$tmp/home"
  mkdir -p "$home"
  make_repo "$tmp/project"
  repo="$tmp/project/repo"
  mkdir -p "$tmp/fakebin"
  cat >"$tmp/fakebin/git" <<SH
#!/bin/sh
case "\$*" in
  *' remote get-url origin') printf '%s\n' 'https://github.com/fixture/repository.git' ;;
  *) exec '$(command -v git)' "\$@" ;;
esac
SH
  chmod +x "$tmp/fakebin/git"
  PATH="$tmp/fakebin:$PATH"
  make_runtime "$tmp"
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  printf 'validate fixture\n' >"$tmp/intent.txt"
  python3 - "$tmp/lease.json" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["access_token"]="forbidden-secret"; open(p,"w").write(json.dumps(value)+"\n")
PY
  chmod 600 "$tmp/lease.json"
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/lease.json" --runtime-bundle "$tmp/runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted a secret-bearing lease descriptor"
  assert_contains "$out" "forbidden secret field" "secret-bearing lease refusal was not explicit"
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  python3 - "$tmp/lease.json" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["github_authority"]["permissions"].append("issues:write"); open(p,"w").write(json.dumps(value)+"\n")
PY
  chmod 600 "$tmp/lease.json"
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/lease.json" --runtime-bundle "$tmp/runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted broad GitHub authority"
  assert_contains "$out" "must declare only" "broad GitHub authority refusal was not explicit"
  # The fine-grained UI's successor pair for checks:read is accepted as an
  # equally minimal declaration; validate_credential_lease alone proves it
  # (submit would next require the live disk).
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  python3 - "$tmp/lease.json" "$ROOT/bin/fm-azure-validation.py" <<'PY'
import importlib.util,json,sys
p=sys.argv[1]; value=json.load(open(p))
value["github_authority"]["permissions"]=["contents:write","pull_requests:write","actions:read","statuses:read"]
open(p,"w").write(json.dumps(value)+"\n")
spec=importlib.util.spec_from_file_location("v", sys.argv[2])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import os
os.chmod(p, 0o600)
m.validate_credential_lease(p, "task-one", "generation-one")
print("successor authority pair accepted")
PY
  # A modified file whose stale manifest digest remains otherwise structurally
  # valid is refused before any cell can execute the runtime.
  rm -rf "$tmp/runtime-tampered"
  mkdir "$tmp/runtime-tampered"
  COPYFILE_DISABLE=1 tar -xzf "$tmp/runtime.tar.gz" -C "$tmp/runtime-tampered"
  printf '#!/bin/sh\nexit 7\n' >"$tmp/runtime-tampered/bin/codex"
  chmod +x "$tmp/runtime-tampered/bin/codex"
  COPYFILE_DISABLE=1 tar -czf "$tmp/tampered-runtime.tar.gz" -C "$tmp/runtime-tampered" runtime.json bin
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/lease.json" --runtime-bundle "$tmp/tampered-runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted stale runtime file digests"
  assert_contains "$out" "runtime bundle file digest mismatch" "runtime digest refusal was not explicit"
  COPYFILE_DISABLE=1 tar -xzf "$tmp/runtime.tar.gz" -C "$tmp"
  printf 'secret\n' >"$tmp/runtime/auth.json"
  COPYFILE_DISABLE=1 tar -czf "$tmp/bad-runtime.tar.gz" -C "$tmp/runtime" runtime.json auth.json bin
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/lease.json" --runtime-bundle "$tmp/bad-runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted a credential-like runtime path"
  assert_contains "$out" "credential-like path" "credential-like runtime refusal was not explicit"
  pass "secret-bearing leases, broad GitHub authority, and credential-like runtime bundles fail before admission"
}

credential_disk_identity_contract() {
  python3 - "$HOST" <<'PY' || fail "credential disk uniqueId fallback failed"
import importlib.util,inspect,sys
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
disk_id="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/disks/credential-task"
env={"subscription":"sub","resource_group":"rg"}
vm_id="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-task"
state={"resources":{"vm_id":vm_id},"request":{"credential_lease":{"lease_id":"lease-task","disk":{"id":disk_id,"etag":"disk-unique-id"}}}}
disk={"id":disk_id,"properties":{"uniqueId":"disk-unique-id"},"tags":{"credential-lease":"lease-task"}}
m.read_resource=lambda *_:(True,disk)
m.verify_credential_disk(env,state)
identity=m.immutable_identity(disk,"disk")
assert identity["etag"]=="disk-unique-id" and identity["unique_id"]=="disk-unique-id"
assert m.immutable_identity({"id":"/run"},"run-command")=={"id":"/run","etag":None}
assert m.immutable_identity({"id":"/schedule"},"ttl-schedule")=={"id":"/schedule","etag":None}
disk["managedBy"]=vm_id
m.verify_credential_disk(env,state,allow_expected_vm=True)
try: m.verify_credential_disk(env,state)
except m.ValidationError: pass
else: raise AssertionError("queued admission accepted an attached credential disk")
disk["managedBy"]=vm_id+"-foreign"
try: m.verify_credential_disk(env,state,allow_expected_vm=True)
except m.ValidationError: pass
else: raise AssertionError("starting recovery accepted a foreign credential-disk attachment")
source=inspect.getsource(m.dispatch)
assert 'value.get("phase") in ("queued", "starting")' in source
assert 'admission.get("shape_id") != state["cell"]' in source
PY
  pass "credential disk identity and starting-phase recovery accept only the exact recorded cell"
}

storage_network_access_contract() {
  python3 - "$HOST" <<'PY' || fail "validation storage network-access contract failed"
import importlib.util,inspect,sys
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
runner=m.runner_module(); operator_ip="203.0.113.10/32"
disabled={"publicNetworkAccess":"Disabled","networkRuleSet":{"ipRules":[]}}
enabled={"publicNetworkAccess":"Enabled","networkRuleSet":{"ipRules":[{"ipAddressOrRange":operator_ip,"action":"Allow"}]}}
assert runner.storage_network_access_is_exact(disabled,"","ipAddressOrRange")
assert runner.storage_network_access_is_exact(enabled,operator_ip,"ipAddressOrRange")
assert not runner.storage_network_access_is_exact(enabled,"203.0.113.11/32","ipAddressOrRange")
source=inspect.getsource(m.foundation_gate)
assert 'storage, env["operator_data_plane_ip"], "ipAddressOrRange"' in source
PY
  pass "validation accepts Azure CLI's exact operator /32 ipAddressOrRange shape"
}

retail_price_transport_contract() {
  python3 - "$HOST" <<'PY' || fail "validation retail-price transport contract failed"
import importlib.util,io,json,sys
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
payload={"Items":[{"productName":"Virtual Machines Dasv6 Series","meterName":"D8as v6","unitOfMeasure":"1 Hour","retailPrice":0.4}]}
class Reply(io.BytesIO):
 def __enter__(self): return self
 def __exit__(self,*_args): return False
seen=[]
def urlopen(request,timeout):
 seen.append((request.full_url,request.headers,timeout)); return Reply(json.dumps(payload).encode())
m.urllib.request.urlopen=urlopen
m.az_command=lambda *_args,**_kwargs: (_ for _ in ()).throw(AssertionError("Azure CLI must not proxy the public retail API"))
assert m.retail_rate({},"Standard_D8as_v6")==0.4
assert seen[0][2]==20 and seen[0][1]["User-agent"]=="firstmate-azure-validation/1"
PY
  pass "validation reads the public retail API directly with a bounded identified request"
}

admission_contract() {
  local tmp fixture out
  fm_test_tmproot_into tmp fm-azure-validation-admission
  fixture="$tmp/shape-plan.json"
  python3 - "$fixture" <<'PY'
import json,sys
rates={
 "Standard_D4as_v6":0.35,"Standard_D4as_v7":0.36,"Standard_D4s_v6":0.37,
 "Standard_D4ads_v7":0.38,"Standard_D4ds_v6":0.39,"Standard_D4s_v7":0.40,
 "Standard_D4ds_v7":0.41,"Standard_D4ads_v6":0.42,
}
value={"operation":"shape-plan","selected_family":"standardDav6Family","behavior_shards":8,"rates":rates}
json.dump(value,open(sys.argv[1],"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "shape plan fixture failed"
  python3 - "$out" <<'PY' || fail "shape plan did not compose the exact allocator constituents"
import json,sys
value=json.loads(sys.argv[1])
plan=value["plan"]
assert value["total_vcpus"]==40
assert value["distinct_invocations"]==8
# The control family never hosts a shard: 8 + 4 would exceed its exact
# 10-vCPU family allowance, so shards spread across the other families.
assert all(entry["sku_family"].lower()!="standarddav6family" for entry in plan)
assert all(entry["amount_usd"]>0 for entry in plan)
assert [entry["shard"] for entry in plan]==list(range(1,9))
PY
  # The shared allocator is the only capacity authority: the dispatcher hands
  # it the complete shape and honors reserved/queued verbatim, and its own
  # parallel admission arithmetic is gone.
  python3 - "$HOST" <<'PY' || fail "shape reservation authority is not the shared allocator"
import importlib.util,json,os,sys,tempfile
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for name in ("admission_decision","shared_capacity_demand","usage_map","consumed_hours","cost_query","active_inventory"):
    assert not hasattr(m,name), name+" still exists as a parallel capacity authority"
stub_dir=tempfile.mkdtemp()
stub=os.path.join(stub_dir,"lifecycle-stub.sh")
capture=os.path.join(stub_dir,"arguments.txt")
open(stub,"w").write("#!/bin/sh\nprintf '%s\\n' \"$@\" > "+capture+"\ncat "+os.path.join(stub_dir,"reply.json")+"\n")
os.chmod(stub,0o755)
reply={"shape_id":"azv-abcdefabcdef","status":"queued","reason":"complete shape exceeds free family capacity","constituents":[],"actual_usd":10.0,"forecast_usd":20.0,"admission_limit_usd":1500.0}
open(os.path.join(stub_dir,"reply.json"),"w").write(json.dumps(reply))
os.environ["FM_AZURE_VALIDATION_LIFECYCLE"]=stub
env={"subscription":"5f0f9efb-723c-4bd8-a2e2-ba13625ea014"}
plan=[{"shard":i,"invocation":"azr-%012d"%i,"sku":"Standard_D4as_v7","sku_family":"StandardDasv7Family","amount_usd":25.0} for i in range(1,9)]
state={"cell":"azv-abcdefabcdef","request":{"fence":"f"*64,"limits":{"behavior_shards":8}},"admission":{"shard_plan":plan}}
selected={"sku":"Standard_D8as_v6","family":"standardDav6Family","rate":0.7}
shape=m.shared_shape_reserve(env,state,selected)
assert shape["status"]=="queued" and "family" in shape["reason"]
arguments=open(capture).read().splitlines()
assert arguments[0]=="capacity-reserve-shape"
constituents=[arguments[i+1] for i,a in enumerate(arguments) if a=="--constituent"]
assert len(constituents)==9
assert sum("vcpus=8" in c for c in constituents)==1
assert sum("vcpus=4" in c for c in constituents)==8
assert any("reservation-id=azv-abcdefabcdef" in c for c in constituents)
assert all("role=validation" in c for c in constituents)
# A reserved reply is honored verbatim and carries the plan for child lineage.
reply["status"]="reserved"; reply["reason"]=""
open(os.path.join(stub_dir,"reply.json"),"w").write(json.dumps(reply))
shape=m.shared_shape_reserve(env,state,selected)
assert shape["status"]=="reserved" and shape["shard_plan"]==plan
# A wrong shape identity from the allocator fails closed.
reply["shape_id"]="azv-000000000000"
open(os.path.join(stub_dir,"reply.json"),"w").write(json.dumps(reply))
try:
    m.shared_shape_reserve(env,state,selected)
except m.ValidationError as exc:
    assert "wrong identity" in str(exc)
else:
    raise AssertionError("foreign shape identity was accepted")
del os.environ["FM_AZURE_VALIDATION_LIFECYCLE"]
PY
  pass "the released shared allocator atomically admits or queues the complete 40-vCPU shape and no parallel authority remains"
}

identity_and_recovery_contract() {
  local tmp fixture out rc
  fm_test_tmproot_into tmp fm-azure-validation-identity
  fixture="$tmp/identity.json"
  python3 - "$fixture" <<'PY'
import json,sys
head="a"*40; tree="b"*40
state={
 "request_digest":"sha256:"+"1"*64,"cell":"azv-aaaaaaaaaaaa","attempt":1,
 "request":{"home_binding":"sha256:"+"2"*64,"task":"task","task_generation":"gen","validation_generation":"val","fence":"sha256:"+"3"*64,"repository":{"slug":"o/r","branch":"fm/task","head":head},"credential_lease":{"lease_id":"lease"},"limits":{"behavior_shards":8}},
 "resources":{"worktree_disk_id":"/work","vm_id":"/vm","vm_instance_id":"vm-instance"},
 "expected_boot_id":"44444444-4444-4444-8444-444444444444",
}
receipts=[]
for i in range(1,9):
 receipts.append({"round":"round-aaaaaaaaaaaa","kind":"behavior","shard":i,"shard_count":8,"head":head,"tree":tree,"request_digest":"sha256:"+format(i,"064x"),"command_digest":"sha256:"+format(i+8,"064x"),"invocation":"azr-"+format(i,"012x"),"boot_id":f"boot-{i}","vm_instance_id":f"vm-{i}","artifact":{"path":f"results/executed-{i}.tsv","digest":"sha256:"+format(i+16,"064x"),"bytes":100+i}})
result={
 "schema":"fm.azure-validation-result/v1","request_digest":state["request_digest"],"cell":state["cell"],"home_binding":state["request"]["home_binding"],"task":"task","task_generation":"gen","validation_generation":"val","fence":state["request"]["fence"],"branch":"fm/task","submitted_head":head,"current_head":head,"current_tree":tree,"remote_head":head,"worktree_disk_id":"/work","worktree_luks_uuid":"55555555-5555-4555-8555-555555555555","credential_lease_id":"lease","run_id":"01HZX7YQ7EJQH8C9G3N4M5P6R7","vm_resource_id":"/vm","vm_instance_id":"vm-instance","boot_id":state["expected_boot_id"],"outcome":"checks-passed","checks_green":True,"pr_url":"https://github.com/o/r/pull/1","behavior_shards":receipts
}
json.dump({"operation":"result-identity","state":state,"result":result},open(sys.argv[1],"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "positive result identity fixture failed"
  assert_contains "$out" '"valid": true' "exact result was not accepted"
  python3 - "$HOST" "$fixture" <<'PY' || fail "result identity adversary matrix failed"
import copy,importlib.util,json,sys
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
base=json.load(open(sys.argv[2]))
def reject(name,mutate):
 value=copy.deepcopy(base); mutate(value["result"])
 try: m.verify_result_identity(value["state"],value["result"])
 except m.ValidationError: return
 raise AssertionError(name+" was accepted")
reject("wrong submitted head",lambda r:r.__setitem__("submitted_head","f"*40))
reject("wrong run",lambda r:r.__setitem__("run_id","not-a-run"))
reject("wrong VM",lambda r:r.__setitem__("vm_instance_id","peer-vm"))
reject("wrong boot",lambda r:r.__setitem__("boot_id","peer-boot"))
reject("stale shard head",lambda r:r["behavior_shards"][0].__setitem__("head","c"*40))
reject("stale shard tree",lambda r:r["behavior_shards"][0].__setitem__("tree","c"*40))
reject("duplicate shard index",lambda r:r["behavior_shards"][7].__setitem__("shard",1))
reject("wrong artifact digest",lambda r:r["behavior_shards"][0]["artifact"].__setitem__("digest","bad"))
reject("cross-repo PR",lambda r:r.__setitem__("pr_url","https://github.com/peer/repo/pull/1"))
PY
  python3 - "$fixture" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["result"]["behavior_shards"][7]["boot_id"]=value["result"]["behavior_shards"][0]["boot_id"]; json.dump(value,open(p,"w"))
PY
  rc=0
  out=$(python3 "$HOST" pure-check --fixture "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "result accepted two shards from one boot"
  assert_contains "$out" "independent Azure machines" "shared-boot result refusal was not explicit"
  python3 - "$fixture" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); state=value["state"]
state["phase"]="failed-retained"; state["resources"]["identities"]={"worktree":{"id":"/work","etag":"etag","unique_id":"unique-work"}}; state["run_id"]="01AAAAAAAAAAAAAAAAAAAAAAAA"
value={"operation":"replacement","state":state,"vm_presence":"absent-proven","worktree_identity":{"id":"/work","etag":"changed-after-detach","unique_id":"unique-work"},"remote_head":state["request"]["repository"]["head"]}
json.dump(value,open(p,"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "positive replacement fixture failed"
  assert_contains "$out" '"allowed": true' "exact replacement was not admitted"
  python3 - "$fixture" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["vm_presence"]="missing-unproven"; json.dump(value,open(p,"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "negative replacement fixture command failed"
  assert_contains "$out" '"allowed": false' "missing VM alone authorized a duplicate"
  assert_contains "$out" "absence is not proven" "replacement refusal did not name absence proof"
  pass "exact result, head/run/disk/VM/boot/shard adversaries, and replacement fencing preserve run identity"
}

trusted_manifest_verifier_contract() {
  python3 - "$BRIDGE" "$ROOT" <<'PY' || fail "trusted manifest verifier parity failed"
import importlib.util,pathlib,subprocess,sys,tempfile
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
repo=pathlib.Path(sys.argv[2]); count=8
trusted=m.trusted_behavior_plan(repo,count)
output=subprocess.check_output([str(repo/"bin/fm-behavior-shards.sh"),"--plan",str(count)],cwd=repo,text=True)
script={}
for line in output.splitlines():
 shard,_duration,path=line.split("\t"); script.setdefault(int(shard),[]).append(path)
assert trusted==script
manifest=pathlib.Path(tempfile.mkdtemp())
for shard,paths in trusted.items():
 (manifest/f"executed-{shard}.tsv").write_text("".join(f"{shard}\t{path}\t0\t1\n" for path in paths))
m.trusted_verify_manifests(repo,manifest,count)
first=manifest/"executed-1.tsv"; original=first.read_text(); fields=original.splitlines()[0].split("\t"); fields[2]="7"; first.write_text("\t".join(fields)+"\n"+"\n".join(original.splitlines()[1:])+"\n")
try: m.trusted_verify_manifests(repo,manifest,count)
except m.BridgeError as exc: assert "failed tests" in str(exc)
else: raise AssertionError("failed manifest passed")
PY
  pass "root-owned data-only completeness verifier matches the existing planner and rejects failed manifests"
}

shard_runner_integration_contract() {
  python3 - "$HOST" <<'PY' || fail "one-shot runner integration contract failed"
import ast,importlib.util,inspect,io,json,pathlib,shutil,sys,tarfile,tempfile,types
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# The hours-long child wait is protected by its own driver lock, not the cell
# state lock used by observe/status/respond.
tree=ast.parse(inspect.getsource(m.drive)); parents={}
for node in ast.walk(tree):
 for child in ast.iter_child_nodes(node): parents[child]=node
run_call=next(node for node in ast.walk(tree) if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id=="run_shard_invocations")
ancestors=[]; current=run_call
while current in parents: current=parents[current]; ancestors.append(current)
with_sources=[ast.dump(node.items[0].context_expr) for node in ancestors if isinstance(node,ast.With)]
assert len(with_sources)==1 and "shards" in with_sources[0]
root=pathlib.Path(tempfile.mkdtemp()); home=root/"home"; state_dir=home/"state"/"azure-validation"; runner_dir=home/"state"/"azure-runner"
env={"home":home,"state_dir":state_dir,"subscription":"sub"}; state={"schema":m.SCHEMA,"cell":"azv-aaaaaaaaaaaa","request":{"task":"task","fence":"sha256:"+"f"*64,"repository":{"head":"a"*40},"limits":{"reserved_vcpus":40}},"shard_runs":{}}
m.ensure_dirs(env)
repo=root/"repo"; repo.mkdir()
record={"invocation":"azr-aaaaaaaaaaaa","sku":"Standard_D4as_v6","repo":str(repo),"snapshot_bundle":str(root/"snapshot.bundle"),"task":"azv-aaaaaaaaaaaa-s1","generation":"round-aaaaaaaaaaaa","resource_class":"behavior-heavy","source_ref":"refs/heads/fm/task","artifacts":["results/executed-1.tsv"],"command":["true"]}
calls=[]
class Process:
 returncode=0
 def __init__(self,argv,**kwargs): calls.append(argv)
 def communicate(self): return ("ok","")
m.subprocess.Popen=Process
m.run_shard_invocations(env,state,[record])
argv=calls.pop()
assert argv[1:3]==["run","--confirm-run"] and "--source-ref" in argv and "--private-snapshot-bundle" in argv and "--capacity-parent" in argv and argv[argv.index("--capacity-reservation-vcpus")+1]=="40"
assert argv[argv.index("--capacity-fence")+1]=="f"*64
runner_dir.mkdir(parents=True); (runner_dir/(record["invocation"]+".json")).write_text(json.dumps({"phase":"running"}))
m.run_shard_invocations(env,state,[record]); assert calls.pop()[1:3]==["resume","--invocation"]
# A collected runner archive is re-read from the private container and every
# artifact byte/digest is rebound into the cell response.
artifact=b"tests/example.test.sh\n"; artifact_digest="sha256:"+__import__('hashlib').sha256(artifact).hexdigest()
runner_result={"vm_instance_id":"vm-1","boot_id":"boot-1","exit_code":0,"duration_seconds":12,"artifacts":[{"path":"results/executed-1.tsv","bytes":len(artifact),"digest":artifact_digest}]}
runner_state={"phase":"complete","request":{"repository":{"source_mode":"private-parent-bundle","commit":"a"*40,"tree":"b"*40,"source_ref":"refs/heads/fm/task","source_head":"a"*40},"command_digest":"sha256:"+"c"*64,"capacity_parent":"azv-aaaaaaaaaaaa","capacity_reservation_vcpus":40},"result":runner_result,"staging":{"output_blob":"private/result.tar.gz"},"cost":{"hourly_rate":.2}}
archive=root/"source.tar.gz"; payload=root/"payload"; (payload/"artifacts"/"results").mkdir(parents=True); (payload/"result.json").write_text(json.dumps(runner_result,separators=(",",":"))+"\n"); (payload/"stdout.log").write_text("ok\n"); (payload/"stderr.log").write_text(""); (payload/"artifacts"/"results"/"executed-1.tsv").write_bytes(artifact)
with tarfile.open(archive,"w:gz") as out:
 for path in sorted(payload.rglob("*")):
  out.add(path,arcname=path.relative_to(payload).as_posix(),recursive=False)
runner_state["result_digest"]=m.sha256_file(archive); (runner_dir/(record["invocation"]+".json")).write_text(json.dumps(runner_state))
m.storage_download=lambda _e,_b,destination,container=None: shutil.copyfile(archive,destination)
request={"round":"round-aaaaaaaaaaaa","kind":"behavior","shard":1,"shard_count":1,"repository":{"branch":"fm/task","head":"a"*40,"tree":"b"*40},"request_digest":"sha256:"+"d"*64,"command_digest":"sha256:"+"c"*64,"artifacts":["results/executed-1.tsv"]}
response=m.package_shard_response(env,state,request,record,root/"package")
with tarfile.open(response,"r:gz") as inp:
 result=json.loads(inp.extractfile("result.json").read())
 assert result["kind"]=="behavior" and result["artifact"]["digest"]==artifact_digest and inp.extractfile("executed.tsv").read()==artifact
PY
  pass "validation dispatch starts exact private-head one-shot runs, resumes only existing invocations, and rebinds private artifacts"
}

cleanup_recovery_contract() {
  python3 - "$HOST" <<'PY' || fail "cleanup recovery contract failed"
import importlib.util,sys
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","storage":"storage","operator_object_id":"operator"}
state={"cell":"azv-aaaaaaaaaaaa","staging":{"container":"fmvalaaaaaaaaaaaa"},"resources":{"identity_principal_id":"cell-principal","identity_id":"/identity"},"request":{"fence":"sha256:"+"a"*64}}
scope="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/storage/blobServices/default/containers/fmvalaaaaaaaaaaaa"
role="/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/"+m.BLOB_DATA_CONTRIBUTOR_ROLE
roles=[{"id":"/role/one","scope":scope,"principalId":"operator","roleDefinitionId":role},{"id":"/role/two","scope":scope,"principalId":"cell-principal","roleDefinitionId":role}]
container=[True]
def read(_env,rid,kind):
 if kind=="container": return (container[0],{"id":scope,"etag":"E1","properties":{"publicAccess":"None"}} if container[0] else None)
 raise AssertionError((rid,kind))
def az(_env,args,**kwargs):
 if args[:3]==["role","assignment","list"]: return (list(roles),0,"")
 if args[:3]==["role","assignment","delete"]:
  wanted=args[-1]; roles[:]=[item for item in roles if item["id"]!=wanted]; return (None,0,"")
 if args[:2]==["rest","--method"]:
  assert "If-Match=E1" in args; container[0]=False; return (None,0,"")
 raise AssertionError(args)
m.read_resource=read; m.az_command=az; m.save_state=lambda *_:None; m.delete_resource=lambda *_:None; m.time.sleep=lambda _n:None
m.delete_cell_storage_scope(env,state)
assert state["storage_cleanup"]=={"scope":scope,"container_etag":"E1","role_ids":["/role/one","/role/two"],"roles_absent":True,"container_absent":True}
# A retry after both child assignments and the container are already absent is
# idempotent from the persisted exact plan rather than permanently wedged.
m.delete_cell_storage_scope(env,state)
PY
  pass "partial container/role cleanup resumes idempotently from its exact persisted plan"
}

operator_documentation_contract() {
  for text in \
    'queue depth' \
    'worker-hour' \
    'There is no fixed 64-vCPU validation pool' \
    'shared East US 128-vCPU admission ceiling' \
    'No behavior test process runs in the credentialed cell or on the Mac.' \
    'No Azure resource was created while implementing this feature.' \
    'Run a real no-mistakes pipeline through review, test' \
    'actual cost' \
    'idle VM count is zero' \
    'Remote Herdr is not part of this path.'; do
    assert_grep "$text" "$DOC" "operator documentation is missing: $text"
  done
  pass "operator documentation records queue, cost, failure, recovery, eight-shard, scale-zero, and real acceptance contracts"
}

static_contract
submit_contract
security_negative_contract
credential_disk_identity_contract
storage_network_access_contract
retail_price_transport_contract
admission_contract
identity_and_recovery_contract
trusted_manifest_verifier_contract
shard_runner_integration_contract
cleanup_recovery_contract
operator_documentation_contract
