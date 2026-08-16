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

make_credentials() {
  local root=$1 provider=${2:-codex}
  mkdir -p "$root/auth-home/.$provider" "$root/auth-home/.claude"
  printf 'fixture-session\n' >"$root/auth-home/.$provider/auth.json"
  printf 'fixture-claude\n' >"$root/auth-home/.claude/settings.json"
  printf 'fixture-github-token\n' >"$root/github-token"
  chmod 600 "$root/github-token"
  cat >"$root/credentials.json" <<JSON
{"schema":"fm.azure-validation-credentials/v1","provider":"${provider}","auth_home":"${root}/auth-home","github_token_file":"${root}/github-token"}
JSON
  chmod 600 "$root/credentials.json"
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
# Isolation-only stack: no TrustedLaunch/securityProfile ceremony remains.
assert "securityprofile" not in text
assert "trustedlaunch" not in text
assert "cryptsetup" not in text and "luks" not in text
linux=vm["properties"]["osProfile"]["linuxConfiguration"]
assert linux["disablePasswordAuthentication"] is True
key=linux["ssh"]["publicKeys"][0]
assert key["path"]=="/home/fmbootstrap/.ssh/authorized_keys"
assert key["keyData"].startswith("ssh-rsa ") and key["keyData"].endswith(" firstmate-validation-blackhole")
assert vm["properties"]["storageProfile"]["osDisk"]["deleteOption"]=="Detach"
data=vm["properties"]["storageProfile"]["dataDisks"]
assert len(data)==1 and data[0]["lun"]==0 and data[0]["deleteOption"]=="Detach"
assert "credentialdiskid" not in text
# The baked golden image is preferred when supplied; stock Ubuntu otherwise.
assert template["parameters"]["imageId"]["defaultValue"]==""
assert "if(empty(parameters('imageId'))" in vm["properties"]["storageProfile"]["imageReference"]
# The dispatch deployment grants the fresh per-cell UAMI its auth-share
# file-data role in the same lane as the blob-container role assignments;
# a manual grant would evaporate with each cell.
assert template["parameters"]["authShareName"]["defaultValue"]=="fm-auth-home"
assert template["variables"]["fileDataPrivilegedContributorRoleId"]=="69566ab7-960f-475b-8e7c-b3118f30c6bd"
file_grant=next(item for item in resources if item["type"]=="Microsoft.Storage/storageAccounts/providers/roleAssignments")
assert file_grant["condition"]=="[not(empty(parameters('authShareName')))]"
assert "fileDataPrivilegedContributorRoleId" in file_grant["properties"]["roleDefinitionId"]
assert "auth-share-file-data" in file_grant["name"]
assert file_grant["properties"]["principalType"]=="ServicePrincipal"
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
assert 'run_mode = replacement_run_mode(state)' in host
assert 'command_env.setdefault("FM_HOME", str(ROOT))' in host
assert 'command_env["FM_HOME"] = str(ROOT)' not in host
assert 'def follow_shard_lineage' in host
assert host.count('followed = follow_shard_lineage(env, record)') == 2
assert 'value.get("phase") == "absent-fenced"' in host
assert "old_lease_absent" not in host
assert host.index('"retry",') < host.index('"--confirm-run",')
assert 'value.get("parent_invocation") == current' in host
assert 'def materialize_shard_repo' in host
assert 'if not Path(existing["repo"]).is_dir():' in host
assert host.count('materialize_shard_repo(request, extracted)') == 3
assert 'value.get("invocation") == invocation' in host
assert 'invocation = "azr-" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]' in host
assert '"snapshot_bundle": str(extracted / "snapshot.bundle"),' in host
assert '"invocation": plan["invocation"],' not in host[host.index('def prepare_shard_runner'):host.index('def run_shard_invocations')]
assert host.index('save_state(env, state)', host.index('runner_stderr_tail"] = stderr')) < host.index('one or more shard transports retained ambiguous state')
assert "parent_managed=True," in host
assert 'round(bound["total"] + 1.0, 6)' in host
assert host.count('* 24.0 * 1.5 + 5.0') == 1
assert 'create_run_command(env, state, "start", input_url=input_url, output_url=output_url)' in host
assert '"running", "reattaching", "collected")' in host
# Credential machinery is gone from the host: no LUKS keys, no lease disks,
# no custody digests. Boot-time injection carries the GitHub token only.
for absent in ("cryptsetup","luks","LEASE_SCHEMA","credential_lease_digest","credential_disk","CloudAdmissionLease","ensure_secret_file","disk_content_binding","verify_credential_disk"):
    assert absent not in host, absent
assert 'protected.append({"name": "github_token", "value": read_github_token(state)})' in host
assert "FM_AZURE_GITHUB_TOKEN_FILE" in host
assert '"auth_share", "value": auth_share_name()' in host
assert 'FILE_DATA_PRIVILEGED_CONTRIBUTOR_ROLE = "69566ab7-960f-475b-8e7c-b3118f30c6bd"' in host
assert "def delete_auth_share_role" in host
assert host.index("delete_auth_share_role(env, state)", host.index("def delete_cell_storage_scope")) < host.index('delete_resource(env, state, state["resources"]["identity_id"], "identity")')
assert "container and auth-share grants" in host
assert '"imageId": {"value": os.environ.get("FM_AZURE_VM_IMAGE_ID", "")}' in host
for value in ("MemoryMax","MemorySwapMax=0","TasksMax","CPUQuota=700%","PrivateTmp=yes","ProtectSystem=strict","CapabilityBoundingSet=","FM_AZURE_VALIDATION_RUNTIME_PATH","axi status","/dev/disk/azure/scsi1/lun","/dev/disk/azure/data/by-lun/"):
    assert value in guest
for value in ('MODE=${mode:-}','VM_RESOURCE_ID=${vm_resource_id:-}','INPUT_URL=${input_url:-}','GITHUB_TOKEN_VALUE=${github_token:-}','AUTH_SHARE=${auth_share:-fm-auth-home}','unset input_url output_url response github_token'):
    assert value in guest
# Plain ext4 worktree: format only a fresh start-mode disk, mount everything
# else, refuse foreign filesystems. No encryption layer remains.
for value in ('WORKTREE_FS_TYPE=$(blkid -p -s TYPE -o value "$WORK_DEVICE"','mkfs.ext4 -q -F -L fm-validation-work','0:ext4)','worktree disk has a foreign filesystem','worktree filesystem identity is unreadable','mount -o nodev,nosuid "$WORK_DEVICE" "$WORK_MOUNT"'):
    assert value in guest
for absent in ("cryptsetup","luks","LEASE_BINDING_HELPER","credential_disk_id","fm_azure_validation_worktree_key_file","disk_content_binding"):
    assert absent not in guest, absent
# Persistent auth home: pull the fm-auth-home share over the seeded bundle
# before the run, push refreshed tokens back after, and leave a marker when
# the share is empty on a first-ever boot.
for value in ("auth_home_pull","auth_home_push","auth-sync.py","x-ms-file-request-intent","file.core.windows.net","auth-needed","interactive provider auth is needed once","credentials.tar.gz"):
    assert value in guest
assert guest.index("auth_home_pull\n", guest.index("# Overlay")) < guest.index("useradd --system")
assert guest.index("auth_home_push") < guest.index("OUTCOME=failed")
assert 'GH_TOKEN_FILE=%s' in guest and 'printf \'%s\' "$GITHUB_TOKEN_VALUE" >"$GITHUB_TOKEN_FILE"' in guest
assert "GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=$REPO" in guest
assert guest.index("chown -R fmvalidate:fmvalidate") < guest.index("GIT_CONFIG_KEY_0=safe.directory")
assert '[ "$REPORT" -ef report.md ] || cp "$REPORT" report.md' in guest
assert '[ "$RUN_LOG" -ef run.log ] || cp "$RUN_LOG" run.log' in guest
assert "0o755 if member.mode & 0o111 else 0o644" in guest
assert 'for path in root.rglob("*"):' in guest
assert "launch diagnostics (exit" in guest
assert "code: recover_custody" in guest
assert guest.count('cd "$3" && exec "$2" axi status') == 2
assert "FM_AZURE_VALIDATION_BRANCH" in guest and "FM_AZURE_VALIDATION_BRANCH" in bridge
assert "awaiting[_ -]approval" in guest
assert "status:[[:space:]]*awaiting[_ -](approval|user)" in guest
assert 'tail -n +"$((last_awaiting + 1))" "$RUN_LOG"' in guest
assert guest.index("status:[[:space:]]*awaiting[_ -](approval|user)") < guest.index('"$STATUS_RC" -eq 0 ] && grep -Eiq')
assert "cell worktree is detached and no declared branch identity is present" in bridge
assert "refusing to move it" not in bridge
assert "does not fast-forward to the snapshot HEAD" in bridge
assert bridge.index("does not fast-forward") < bridge.index('"branch", "-f"')
assert '"branch", "-f", branch, "HEAD"' in bridge
assert '"bundle", "create", str(bundle), ref' in bridge
assert bridge.index("merge-base") < bridge.index('"branch", "-f"')
assert '"$NM_BIN" axi sync --recover' in guest
assert 'cp "$STATUS_LOG" "$EVIDENCE/attempt-$ATTEMPT/status.log"' in guest
assert '"reattaching", "collected")' in host
assert "retain-failure owns only failed outcomes" in host
assert '"$NM_BIN" axi respond <"$RESPONSE_FILE"' not in guest
assert '"$NM_BIN" axi respond "$@"' in guest
respond_block=guest[guest.index("    respond)"):guest.index('*) exit 125 ;;')]
assert respond_block.index('"$NM_BIN" axi run') < respond_block.index('axi respond "$@"')
assert '|| true' in respond_block
assert "adjudicate_gates() {" in guest
assert "fetch_gate_response() {" in guest
assert "control/gate-response-a" in guest
assert guest.index("esac") < guest.index("  adjudicate_gates")
assert '"$gates" -gt "$responded"' in guest
assert "FM_AZURE_VALIDATION_GATE_WAIT_SECONDS" in guest
assert 'while IFS= read -r respond_arg || [ -n "$respond_arg" ]; do' in guest
assert guest.index("set --") < guest.index('"$NM_BIN" axi respond "$@"')
assert '"$NM_BIN" init >"$RUN_LOG" 2>&1' in guest
assert guest.index('"$NM_BIN" init >"$RUN_LOG"') < guest.index('start) "$NM_BIN" axi run')
assert 'runuser -u fmvalidate -- git -C "$REPO" config credential.helper "$GIT_HELPER"' in guest
assert 'runuser -u fmvalidate -- git -C "$REPO" config user.name' in guest
assert 'runuser -u fmvalidate -- git -C "$REPO" config user.email' in guest
assert '"$LAUNCH" "$GIT_HELPER"' in guest
assert 'install -d -m 0755 -o root -g root /opt/fm-azure-validation "$RUNTIME"' in guest
assert guest.index("--no-same-permissions") < guest.index("0o755 if member.mode & 0o111")
for value in ("fm.azure-validation-shard/v1","storage_token","vm_instance_id","boot_id","trusted_verify_manifests"):
    assert value in bridge
assert '"$FM_AZURE_VALIDATION_SHARD_BRIDGE" behavior' in nm
assert '"$FM_AZURE_VALIDATION_SHARD_BRIDGE" lint' in nm
assert "no-mistakes daemon start" not in host
assert "no-mistakes daemon stop" not in host
assert "no-mistakes daemon restart" not in host
PY
  pass "cell template and trusted bridge preserve private per-run compute, plain-disk isolation, auth-home sync, and cgroup limits"
}

submit_contract() {
  local tmp home repo out cell state marker rc
  fm_test_tmproot_into tmp fm-azure-validation-submit
  home="$tmp/home"
  mkdir -p "$home"
  make_repo "$tmp/project"
  repo="$tmp/project/repo"
  make_runtime "$tmp"
  make_credentials "$tmp"
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
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
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
assert state["request"]["credentials"]["provider"]=="codex"
assert state["request"]["credentials"]["bundle_digest"].startswith("sha256:")
with tarfile.open(state["input_path"],"r:gz") as archive:
    assert set(archive.getnames())=={"request.json","snapshot.bundle","runtime.tar.gz","credentials.tar.gz","shard-bridge.py"}
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
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/credentials.json" \
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
  make_credentials "$tmp"
  printf 'validate fixture\n' >"$tmp/intent.txt"
  # An unverified provider name refuses before any packaging.
  python3 - "$tmp/credentials.json" <<'PY2'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["provider"]="mystery"; open(p,"w").write(json.dumps(value)+"\n")
PY2
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/credentials.json" --runtime-bundle "$tmp/runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted an unverified provider"
  assert_contains "$out" "not a verified Firstmate adapter" "unverified provider refusal was not explicit"
  # An absent auth home refuses.
  make_credentials "$tmp"
  python3 - "$tmp/credentials.json" <<'PY2'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["auth_home"]=value["auth_home"]+"-absent"; open(p,"w").write(json.dumps(value)+"\n")
PY2
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/credentials.json" --runtime-bundle "$tmp/runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted an absent auth home"
  assert_contains "$out" "auth_home must be an existing" "absent auth home refusal was not explicit"
  # A modified file whose stale manifest digest remains otherwise structurally
  # valid is refused before any cell can execute the runtime.
  rm -rf "$tmp/runtime-tampered"
  mkdir "$tmp/runtime-tampered"
  COPYFILE_DISABLE=1 tar -xzf "$tmp/runtime.tar.gz" -C "$tmp/runtime-tampered"
  printf '#!/bin/sh\nexit 7\n' >"$tmp/runtime-tampered/bin/codex"
  chmod +x "$tmp/runtime-tampered/bin/codex"
  COPYFILE_DISABLE=1 tar -czf "$tmp/tampered-runtime.tar.gz" -C "$tmp/runtime-tampered" runtime.json bin
  make_credentials "$tmp"
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/credentials.json" --runtime-bundle "$tmp/tampered-runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted stale runtime file digests"
  assert_contains "$out" "runtime bundle file digest mismatch" "runtime digest refusal was not explicit"
  COPYFILE_DISABLE=1 tar -xzf "$tmp/runtime.tar.gz" -C "$tmp"
  printf 'secret\n' >"$tmp/runtime/auth.json"
  COPYFILE_DISABLE=1 tar -czf "$tmp/bad-runtime.tar.gz" -C "$tmp/runtime" runtime.json auth.json bin
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/credentials.json" --runtime-bundle "$tmp/bad-runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted a credential-like runtime path"
  assert_contains "$out" "credential-like path" "credential-like runtime refusal was not explicit"
  pass "unverified providers, absent auth homes, and credential-like runtime bundles fail before admission"
}


resource_identity_contract() {
  python3 - "$HOST" <<'PY2' || fail "resource identity fallback contract failed"
import importlib.util,inspect,sys
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
disk={"id":"/work","properties":{"uniqueId":"disk-unique-id"},"tags":{}}
identity=m.immutable_identity(disk,"disk")
assert identity["etag"]=="disk-unique-id" and identity["unique_id"]=="disk-unique-id"
assert m.immutable_identity({"id":"/run"},"run-command")=={"id":"/run","etag":None}
assert m.immutable_identity({"id":"/schedule"},"ttl-schedule")=={"id":"/schedule","etag":None}
uami=m.immutable_identity({"id":"/identity","properties":{"clientId":"client","principalId":"principal"}},"identity")
assert uami=={"id":"/identity","etag":None,"client_id":"client","principal_id":"principal"}
source=inspect.getsource(m.dispatch)
assert 'state.get("phase") in ("queued", "starting")' in source
cell_source=inspect.getsource(m.dispatch_cell)
assert 'admission.get("shape_id") != state["cell"]' in cell_source
PY2
  pass "immutable identity fallbacks and starting-phase recovery keep the exact recorded cell"
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

controller_recovery_contract() {
  python3 - "$HOST" <<'PY2' || fail "validation controller recovery contract failed"
import importlib.util,os,pathlib,tempfile,sys
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
captured={}
def write_private_json(_env,_prefix,value):
 captured.update(value); fd,name=tempfile.mkstemp(); os.close(fd); path=pathlib.Path(name); path.write_text("{}\n"); return path
m.write_private_json=write_private_json
token_dir=tempfile.mkdtemp()
token_path=os.path.join(token_dir,"github-token")
open(token_path,"w").write("fixture-injected-token\n")
os.environ["FM_AZURE_GITHUB_TOKEN_FILE"]=token_path
m.az_command=lambda *_args,**_kwargs:(None,0,"")
m.read_resource=lambda _env,rid,_kind:(True,{"id":rid,"tags":{"validation-cell":"azv-aaaaaaaaaaaa","fence":"sha256:"+"f"*64}})
m.save_state=lambda *_args:None
m.expected_tags=lambda *_args:{"validation-cell":"azv-aaaaaaaaaaaa","fence":"sha256:"+"f"*64}
state={"cell":"azv-aaaaaaaaaaaa","attempt":1,"input_digest":"sha256:"+"i"*64,"request_digest":"sha256:"+"r"*64,"allocation":{"sku":"Standard_D8as_v6","sku_family":"standardDav6Family"},"request":{"fence":"sha256:"+"f"*64,"protocol":{"guest_digest":m.sha256_file(m.GUEST)},"limits":{"wall_seconds":60},"credentials":{"provider":"codex","github_token_file":"/nonexistent-descriptor-path","bundle_digest":"sha256:"+"c"*64}},"resources":{"vm_id":"/vm","vm_instance_id":"vm-instance","worktree_disk_id":"/work","identity_client_id":"client","run_commands":[]},"staging":{"container":"container"}}
m.create_run_command({"storage":"storage","owner":"owner"},state,"start")
protected={item["name"]:item["value"] for item in captured["properties"]["protectedParameters"]}
# Boot-time injection: the env-file override wins and the token value flows
# only through the run-command parameter list.
assert protected["github_token"]=="fixture-injected-token"
arguments={item["name"]:item["value"] for item in captured["properties"]["parameters"]}
assert arguments["auth_share"]=="fm-auth-home"
del os.environ["FM_AZURE_GITHUB_TOKEN_FILE"]
# The descriptor's recorded token path is the default source.
state["request"]["credentials"]["github_token_file"]=token_path
captured.clear()
m.create_run_command({"storage":"storage","owner":"owner"},state,"reattach")
protected={item["name"]:item["value"] for item in captured["properties"]["protectedParameters"]}
assert protected["github_token"]=="fixture-injected-token"
# Replacement mode selection is run-id driven only.
assert m.replacement_run_mode({"phase":"failed-retained"})=="start"
assert m.replacement_run_mode({"phase":"running","run_id":"01AAAAAAAAAAAAAAAAAAAAAAAA"})=="reattach"
allowed,reason=m.replacement_allowed({"phase":"running"},"absent-proven")
assert allowed
allowed,reason=m.replacement_allowed({"phase":"running"},"missing-unproven")
assert not allowed and "absence is not proven" in reason
allowed,reason=m.replacement_allowed({"phase":"closed"},"absent-proven")
assert not allowed and "recoverable work" in reason
PY2
  pass "controller injects the boot-time GitHub token and fences replacement on VM absence plus recoverable phase"
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
 "request":{"home_binding":"sha256:"+"2"*64,"task":"task","task_generation":"gen","validation_generation":"val","fence":"sha256:"+"3"*64,"repository":{"slug":"o/r","branch":"fm/task","head":head},"credentials":{"provider":"codex"},"limits":{"behavior_shards":8}},
 "resources":{"worktree_disk_id":"/work","vm_id":"/vm","vm_instance_id":"vm-instance"},
 "expected_boot_id":"44444444-4444-4444-8444-444444444444",
}
receipts=[]
for i in range(1,9):
 receipts.append({"round":"round-aaaaaaaaaaaa","kind":"behavior","shard":i,"shard_count":8,"head":head,"tree":tree,"request_digest":"sha256:"+format(i,"064x"),"command_digest":"sha256:"+format(i+8,"064x"),"invocation":"azr-"+format(i,"012x"),"boot_id":f"boot-{i}","vm_instance_id":f"vm-{i}","artifact":{"path":f"results/executed-{i}.tsv","digest":"sha256:"+format(i+16,"064x"),"bytes":100+i}})
result={
 "schema":"fm.azure-validation-result/v1","request_digest":state["request_digest"],"cell":state["cell"],"home_binding":state["request"]["home_binding"],"task":"task","task_generation":"gen","validation_generation":"val","fence":state["request"]["fence"],"branch":"fm/task","submitted_head":head,"current_head":head,"current_tree":tree,"remote_head":head,"worktree_disk_id":"/work","run_id":"01HZX7YQ7EJQH8C9G3N4M5P6R7","vm_resource_id":"/vm","vm_instance_id":"vm-instance","boot_id":state["expected_boot_id"],"outcome":"checks-passed","checks_green":True,"pr_url":"https://github.com/o/r/pull/1","behavior_shards":receipts
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
state["phase"]="failed-retained"; state["run_id"]="01AAAAAAAAAAAAAAAAAAAAAAAA"
value={"operation":"replacement","state":state,"vm_presence":"absent-proven"}
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
# A dead guest control command ends the wait immediately instead of burning
# the whole wall budget on a shard request that can never appear; the probe
# is throttled and observe stays the sole owner of the state transition.
drive_src=inspect.getsource(m.drive)
assert "run_command_status(env, state)" in drive_src
assert "CONTROL TERMINAL" in drive_src
assert drive_src.index("SHARDS WAITING") < drive_src.index("CONTROL TERMINAL")
assert "control_probe_at = time.monotonic() + 30" in drive_src
assert '("Succeeded", "Failed", "Canceled", "TimedOut")' in drive_src
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
account_scope="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/storage"
role="/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/"+m.BLOB_DATA_CONTRIBUTOR_ROLE
file_role="/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/"+m.FILE_DATA_PRIVILEGED_CONTRIBUTOR_ROLE
roles=[{"id":"/role/one","scope":scope,"principalId":"operator","roleDefinitionId":role},{"id":"/role/two","scope":scope,"principalId":"cell-principal","roleDefinitionId":role},{"id":"/role/file","scope":account_scope,"principalId":"cell-principal","roleDefinitionId":file_role}]
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
# The account-scoped auth-share file grant is removed through the same lane.
assert not any(item["id"]=="/role/file" for item in roles)
# A retry after both child assignments, the file grant, and the container are
# already absent is idempotent from the persisted exact plan.
m.delete_cell_storage_scope(env,state)
PY
  pass "partial container/role cleanup resumes idempotently from its exact persisted plan"
}

multi_lane_queue_contract() {
  local tmp home out rc
  fm_test_tmproot_into tmp fm-azure-validation-lanes
  home="$tmp/home"
  mkdir -p "$home/state/azure-validation"
  python3 - "$HOST" "$home/state/azure-validation" <<'PY2' || fail "multi-lane dispatch contract failed"
import importlib.util,inspect,json,pathlib,sys
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# Deterministic lane -> SKU spread across four distinct reviewed families.
assert m.COORDINATOR_SKU_POOL==m.VALIDATION_SKUS and len(set(m.COORDINATOR_SKU_POOL))==4
assert [m.lane_sku(i) for i in range(4)]==list(m.COORDINATOR_SKU_POOL)
assert m.lane_sku(4)==m.COORDINATOR_SKU_POOL[0]
# Lane assignment fills the lowest free index and refuses when saturated.
assert m.next_free_lane(set(),4)==0
assert m.next_free_lane({0,2},4)==1
assert m.next_free_lane({0,1,2},4)==3
try: m.next_free_lane({0,1,2,3},4)
except m.ValidationError: pass
else: raise AssertionError("saturated lanes still assigned")
# Occupancy phases: queued/collected/closed cells never hold a lane.
assert "queued" not in m.LANE_PHASES and "collected" not in m.LANE_PHASES and "closed" not in m.LANE_PHASES
for phase in ("starting","running","needs-decision","result-published"):
    assert phase in m.LANE_PHASES
# FIFO dispatch: starting cells recover first, queued admit oldest-first up
# to the lane cap, and an allocator-queued shape stops younger admissions.
source=inspect.getsource(m.dispatch)
assert '0 if item.get("phase") == "starting" else 1' in source
assert 'len(occupied) >= env["lanes"]' in source
assert "AZURE VALIDATION LANES FULL" in source
assert source.index('if outcome != "started":') < source.index("started += 1")
assert "AZURE VALIDATION DISPATCH started=" in source
cell_source=inspect.getsource(m.dispatch_cell)
assert "preferred = lane_sku(lane)" in cell_source
assert 'next((item for item in candidates if item["sku"] == preferred), candidates[0])' in cell_source
# Queue listing surfaces lanes: seed one running lane-0 cell and one queued.
state_dir=pathlib.Path(sys.argv[2])
def seed(cell,phase,lane,created):
    value={"schema":m.SCHEMA,"cell":cell,"phase":phase,"created_at":created,"attempt":1,
           "request":{"task":"task-"+cell,"repository":{"head":"a"*40},"resource_class":"validation-heavy"}}
    if lane is not None: value["lane"]=lane
    (state_dir/(cell+".json")).write_text(json.dumps(value))
seed("azv-aaaaaaaaaaaa","running",0,"2026-08-15T00:00:00Z")
seed("azv-bbbbbbbbbbbb","queued",None,"2026-08-15T00:00:01Z")
PY2
  out=$(validation "$home" queue) || fail "multi-lane queue read failed: $out"
  assert_contains "$out" "AZURE VALIDATION LANES used=1/4 queued=1" "queue did not summarize lanes"
  assert_contains "$out" "cell=azv-aaaaaaaaaaaa phase=running lane=0" "queue did not report the running lane"
  assert_contains "$out" "cell=azv-bbbbbbbbbbbb phase=queued lane=-" "queue did not report the queued cell"
  rc=0
  out=$(FM_AZURE_VALIDATION_LANES=9 validation "$home" queue 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "lane cap above the bounded maximum was accepted"
  assert_contains "$out" "FM_AZURE_VALIDATION_LANES must be between 1 and 8" "lane bound refusal was not explicit"
  pass "four FIFO lanes admit queued generations oldest-first with deterministic family spread and a lane-aware queue view"
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
resource_identity_contract
storage_network_access_contract
controller_recovery_contract
retail_price_transport_contract
admission_contract
identity_and_recovery_contract
trusted_manifest_verifier_contract
shard_runner_integration_contract
cleanup_recovery_contract
multi_lane_queue_contract
operator_documentation_contract
