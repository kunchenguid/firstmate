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
  mkdir -p "$root/runtime/bin" "$root/runtime/gh-axi/dist/bin" \
    "$root/runtime/gh-axi/dist/src"
  for executable in no-mistakes "$provider" gh node gh-axi; do
    printf '#!/bin/sh\nexit 0\n' >"$root/runtime/bin/$executable"
    chmod +x "$root/runtime/bin/$executable"
  done
  printf '%s\n' \
    '{"name":"gh-axi","version":"1.0.0","type":"module","bin":{"gh-axi":"./dist/bin/gh-axi.js"}}' \
    >"$root/runtime/gh-axi/package.json"
  printf '%s\n' '#!/usr/bin/env node' \
    'import { main } from "../src/cli.js";' 'main();' \
    >"$root/runtime/gh-axi/dist/bin/gh-axi.js"
  printf '%s\n' 'export function main() { return true; }' \
    >"$root/runtime/gh-axi/dist/src/cli.js"
  python3 - "$root/runtime" "$provider" <<'PY'
import hashlib
import json
from pathlib import Path
import struct
import sys
root = Path(sys.argv[1])
header = bytearray(64)
header[:16] = b"\x7fELF\x02\x01\x01\x00" + b"\x00" * 8
struct.pack_into("<HHIQQQIHHHHHH", header, 16, 2, 62, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
(root/"bin/node").write_bytes(header + b"fixture-linux-node\n")
(root/"bin/gh-axi").write_bytes(
    b"#!/usr/bin/env bash\n"
    b"# Runtime-bundle wrapper: bind gh-axi to the bundled Node interpreter.\n"
    b"set -euo pipefail\n"
    b'runtime_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)\n'
    b'exec "$runtime_root/bin/node" "$runtime_root/gh-axi/dist/bin/gh-axi.js" "$@"\n'
)
files=[]
for relative in (
    "bin/no-mistakes", "bin/"+sys.argv[2], "bin/gh", "bin/node", "bin/gh-axi",
    "gh-axi/package.json", "gh-axi/dist/bin/gh-axi.js", "gh-axi/dist/src/cli.js",
):
    path=root/relative
    files.append({"path":relative,"digest":"sha256:"+hashlib.sha256(path.read_bytes()).hexdigest()})
manifest={
    "schema":"fm.azure-validation-runtime/v1",
    "provider":sys.argv[2],
    "no_mistakes_version":"1.41.2",
    "no_mistakes_path":"bin/no-mistakes",
    "provider_path":"bin/"+sys.argv[2],
    "gh_path":"bin/gh",
    "node_path":"bin/node",
    "gh_axi_path":"bin/gh-axi",
    "gh_axi_entrypoint":"gh-axi/dist/bin/gh-axi.js",
    "gh_axi_closure":[
        "gh-axi/dist/bin/gh-axi.js",
        "gh-axi/dist/src/cli.js",
        "gh-axi/package.json",
    ],
    "files":files,
}
(root/"runtime.json").write_text(json.dumps(manifest,separators=(",",":"))+"\n")
PY
  COPYFILE_DISABLE=1 tar -czf "$root/runtime.tar.gz" -C "$root/runtime" runtime.json bin gh-axi
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
assert 'TRUSTED_ROOT=/opt/fm-azure-validation' in guest
assert 'install -d -m 0755 -o root -g root "$TRUSTED_ROOT" "$RUNTIME"' in guest
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
  COPYFILE_DISABLE=1 tar -czf "$tmp/tampered-runtime.tar.gz" -C "$tmp/runtime-tampered" runtime.json bin gh-axi
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
  COPYFILE_DISABLE=1 tar -czf "$tmp/bad-runtime.tar.gz" -C "$tmp/runtime" runtime.json auth.json bin gh-axi
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


replacement_runtime_hydration_contract() {
  python3 - "$HOST" <<'PY' || fail "replacement runtime hydration contract failed"
import contextlib
import copy
import hashlib
import importlib.util
import os
import pathlib
import sys
import tempfile
import types

spec=importlib.util.spec_from_file_location("validation",sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cell="azv-aaaaaaaaaaaa"
fence="sha256:"+"f"*64
input_digest="sha256:"+"1"*64
request_digest="sha256:"+"2"*64
runtime_digest="sha256:"+"3"*64
bridge_digest="sha256:"+"4"*64
env={
  "subscription":"sub","resource_group":"rg","storage":"storage","owner":"owner",
  "prefix":"fmtest","deployment_generation":"gen",
}

def seed():
    return {
      "cell":cell,"phase":"failed-retained","attempt":3,
      "run_id":"01AAAAAAAAAAAAAAAAAAAAAAAA",
      "input_digest":input_digest,"request_digest":request_digest,
      "allocation":{"sku":"Standard_D8as_v6","sku_family":"standardDav6Family"},
      "request":{
        "fence":fence,"runtime_digest":runtime_digest,
        "protocol":{
          "guest_digest":m.sha256_file(m.GUEST),
          "shard_bridge_digest":bridge_digest,
        },
        "limits":{"wall_seconds":60},
      },
      "resources":{
        "vm_id":"/old/vm","vm_instance_id":"old-instance",
        "worktree_disk_id":"/work","worktree_disk_name":"work",
        "identity_name":"identity","identity_id":"/identity",
        "identity_client_id":"client","identity_principal_id":"principal",
        "identities":{"worktree":{"id":"/work"},"identity":{"id":"/identity"}},
        "run_commands":[],
      },
      "staging":{
        "container":"private-cell","input_blob":"control/input.tar.gz",
        "result_blob":"control/result.tar.gz",
      },
      "events":[],
    }

# Admit-red regression: drive the real replacement operation with a retained
# run id. The pre-fix controller calls reattach directly, so this exact test is
# red there; the fixed controller must prove hydration completed first and must
# never route the retained run through start.
state=seed()
calls=[]
real_hydrate=getattr(m,"create_runtime_hydration_command",None)
m.lock=lambda *_a,**_k:contextlib.nullcontext()
m.require_cell=lambda value:value
m.load_state=lambda *_a:state
m.read_resource=lambda _env,rid,kind:(False,{}) if kind=="vm" else (True,{"id":rid})
m.cleanup_compute=lambda *_a:None
m.wait_exact_disk_detached=lambda *_a:{"id":"/work","etag":"work-etag"}
m.resource_names=lambda *_a:{
  "vm_id":"/new/vm","vm_instance_id":"new-instance","worktree_disk_id":"/new/work",
  "worktree_disk_name":"new-work","identity_name":"new-identity","identity_id":"/new/identity",
  "identity_client_id":"new-client","identity_principal_id":"new-principal",
  "identities":{},"run_commands":[],
}
def create_cell(_env,value,_selected,replacement=False):
    assert replacement is True
    value["resources"]["vm_instance_id"]="new-instance"
    calls.append(("create-cell",value["attempt"]))
m.create_cell=create_cell
m.blob_sas=lambda _env,blob,permission,**_kw:"https://exact.example/"+blob+"?"+permission
m.create_runtime_hydration_command=lambda _env,_state,url:calls.append(("hydrate",url))
m.create_run_command=lambda _env,_state,mode,**kwargs:calls.append((mode,kwargs))
def transition(_env,value,phase,note,**_kw):
    value["phase"]=phase
    calls.append(("phase",phase,note))
m.transition=transition
args=types.SimpleNamespace(confirm_replace=True,confirm_subscription="sub",cell=cell)
m.replace(env,args)
hydrate_index=next(i for i,item in enumerate(calls) if item[0]=="hydrate")
reattach_index=next(i for i,item in enumerate(calls) if item[0]=="reattach")
assert hydrate_index < reattach_index, calls
assert not any(item[0]=="start" for item in calls), calls
assert calls[hydrate_index][1]=="https://exact.example/control/input.tar.gz?r"
assert calls[reattach_index][1]=={
  "output_url":"https://exact.example/control/result.tar.gz?cw"
}
assert real_hydrate is not None
m.create_runtime_hydration_command=real_hydrate

# The real hydration command is separately current-controller trusted, carries
# only an exact-object read capability, records the one-read source digest, and
# refuses to authorize reattach unless its digest-complete marker is unique.
state=seed()
state["attempt"]=4
state["resources"].update({
  "vm_id":"/new/vm","vm_instance_id":"new-instance",
  "identity_client_id":"client","run_commands":[],
})
captured={}
def write_private_json(_env,_prefix,value):
    captured.clear(); captured.update(copy.deepcopy(value))
    handle,name=tempfile.mkstemp(); os.close(handle); pathlib.Path(name).write_text("{}\n"); return pathlib.Path(name)
m.write_private_json=write_private_json
m.az_command=lambda *_a,**_k:({},0,"")
m.read_resource=lambda _env,rid,_kind:(True,{
  "id":rid,"etag":"etag","tags":{"validation-cell":cell,"fence":fence},
  "properties":copy.deepcopy(captured["properties"]),
})
m.immutable_identity=lambda resource,_kind:{"id":resource["id"],"etag":resource["etag"]}
m.expected_tags=lambda *_a:{"validation-cell":cell,"fence":fence}
m.save_state=lambda *_a:None
text,hydrator_digest=m.trusted_hydrator_text()
m.wait_run_command_terminal=lambda *_a:(
  "Succeeded",{"output":m.hydration_marker(state,hydrator_digest)+"\n"}
)
m.create_runtime_hydration_command(env,state,"https://exact.example/input?sig=secret")
properties=captured["properties"]
arguments={item["name"]:item["value"] for item in properties["parameters"]}
protected={item["name"]:item["value"] for item in properties["protectedParameters"]}
assert properties["source"]["script"]==text
assert arguments["mode"]=="hydrate" and arguments["hydrator_digest"]==hydrator_digest
assert arguments["input_digest"]==input_digest
assert arguments["request_digest"]==request_digest
assert arguments["vm_resource_id"]=="/new/vm"
assert arguments["vm_instance_id"]=="new-instance"
assert arguments["worktree_disk_id"]=="/work"
assert protected=={"input_url":"https://exact.example/input?sig=secret"}
assert "github_token" not in protected and "output_url" not in protected
assert state["runtime_hydrations"][-1]["runtime_digest"]==runtime_digest
assert state["runtime_hydrations"][-1]["shard_bridge_digest"]==bridge_digest
assert state["runtime_hydrations"][-1]["hydrator_digest"]==hydrator_digest

missing=seed()
missing["attempt"]=4
missing["resources"].update({
  "vm_id":"/new/vm","vm_instance_id":"new-instance",
  "identity_client_id":"client","run_commands":[],
})
m.wait_run_command_terminal=lambda *_a:("Succeeded",{"output":"hydration claimed success\n"})
try:
    m.create_runtime_hydration_command(env,missing,"https://exact.example/input?sig=secret")
except m.ValidationError as exc:
    assert "no unique exact digest marker" in str(exc), str(exc)
else:
    raise AssertionError("reattach was authorized without an exact hydration marker")
assert "runtime_hydrations" not in missing

changed=seed()
changed["attempt"]=4
changed["resources"].update({
  "vm_id":"/new/vm","vm_instance_id":"new-instance",
  "identity_client_id":"client","run_commands":[],
})
reads=[]
def replaced_command(_env,rid,_kind):
    reads.append(rid)
    properties=copy.deepcopy(captured["properties"])
    if len(reads)>1:
        properties["source"]["script"]="#!/bin/sh\necho forged hydration\n"
    return True,{
      "id":rid,"etag":"etag","tags":{"validation-cell":cell,"fence":fence},
      "properties":properties,
    }
m.read_resource=replaced_command
m.wait_run_command_terminal=lambda *_a:(
  "Succeeded",{"output":m.hydration_marker(changed,hydrator_digest)+"\n"}
)
try:
    m.create_runtime_hydration_command(env,changed,"https://exact.example/input?sig=secret")
except m.ValidationError as exc:
    assert "identity changed" in str(exc), str(exc)
else:
    raise AssertionError("a same-id source replacement authorized reattach")
assert "runtime_hydrations" not in changed

# Source mutation between hashing and submission cannot substitute bytes: the
# helper returns the digest of the same single read it returns as executable text.
assert hydrator_digest=="sha256:"+hashlib.sha256(text.encode()).hexdigest()
PY
  local work block output rc
  work=$(fm_test_tmproot fm-azure-validation-runtime-hydration)
  make_runtime "$work"
  # If hydration crosses into no-mistakes at all, leave an observable failure;
  # a retained run must only be reattached later by the unchanged sealed guest.
  cat >"$work/runtime/bin/no-mistakes" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >"$FM_FORBIDDEN_AXI"
exit 99
SH
  chmod +x "$work/runtime/bin/no-mistakes"
  python3 - "$work/runtime" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root=Path(sys.argv[1])
manifest=json.loads((root/"runtime.json").read_text())
for record in manifest["files"]:
    if record["path"]=="bin/no-mistakes":
        record["digest"]="sha256:"+hashlib.sha256((root/record["path"]).read_bytes()).hexdigest()
(root/"runtime.json").write_text(json.dumps(manifest,separators=(",",":"))+"\n")
PY
  COPYFILE_DISABLE=1 tar -czf "$work/runtime.tar.gz" -C "$work/runtime" runtime.json bin gh-axi
  printf 'sealed snapshot\n' >"$work/snapshot.bundle"
  mkdir -p "$work/credentials"
  printf 'sealed credential fixture\n' >"$work/credentials/auth"
  COPYFILE_DISABLE=1 tar -czf "$work/credentials.tar.gz" -C "$work/credentials" auth
  printf '#!/usr/bin/env python3\nprint("sealed bridge")\n' >"$work/shard-bridge.py"
  chmod +x "$work/shard-bridge.py"
  python3 - "$work" <<'PY'
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
root=Path(sys.argv[1])
def digest(path):
    return "sha256:"+hashlib.sha256(path.read_bytes()).hexdigest()
runtime=json.loads((root/"runtime/runtime.json").read_text())
request={
  "cell":"azv-aaaaaaaaaaaa",
  "resource_bindings":{"worktree_disk_id":"/work"},
  "repository":{
    "snapshot_digest":digest(root/"snapshot.bundle"),
    "branch":"fm/fixture","head":"a"*40,"slug":"o/r",
  },
  "runtime":runtime,
  "runtime_digest":digest(root/"runtime.tar.gz"),
  "credentials":{"provider":"codex","bundle_digest":digest(root/"credentials.tar.gz")},
  "protocol":{"shard_bridge_digest":digest(root/"shard-bridge.py")},
}
canonical=json.dumps(request,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()
request["request_digest"]="sha256:"+hashlib.sha256(canonical).hexdigest()
(root/"request.json").write_text(json.dumps(request,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n")
with tarfile.open(root/"input.tar.gz","w:gz") as archive:
    for name in ("request.json","snapshot.bundle","runtime.tar.gz","credentials.tar.gz","shard-bridge.py"):
        archive.add(root/name,arcname=name,recursive=False)
(root/"input.digest").write_text(digest(root/"input.tar.gz"))
(root/"request.digest").write_text(request["request_digest"])
PY
  mkdir -p "$work/cell/state" "$work/cell/repo" "$work/cell/home" "$work/bootstrap" "$work/fakebin"
  cp "$work/request.json" "$work/cell/state/request.json"
  printf 'retained repo\n' >"$work/cell/repo/sentinel"
  printf 'retained home\n' >"$work/cell/home/sentinel"
  block="$work/hydrate.sh"
  awk '/^# BEGIN SEALED INPUT HYDRATION/{copy=1;next} /^# END SEALED INPUT HYDRATION/{exit} copy{print}' \
    "$GUEST" >"$block"
  [ -s "$block" ] || fail "the guest hydration region was not found"
  cat >"$work/fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --config ]
output=$(sed -n 's/^output = "\(.*\)"$/\1/p' "$2")
[ -n "$output" ]
cp "$FM_HYDRATE_INPUT" "$output"
SH
  cat >"$work/fakebin/install" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-g) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/install "${args[@]}"
SH
  cat >"$work/fakebin/tar" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=()
for value in "$@"; do
  case "$value" in --no-same-owner|--no-same-permissions) ;; *) args+=("$value") ;; esac
done
exec /usr/bin/tar "${args[@]}"
SH
  chmod +x "$work/fakebin/curl" "$work/fakebin/install" "$work/fakebin/tar"
  rc=0
  # shellcheck disable=SC2016 # $1 belongs to the isolated bash, not this test shell.
  output=$(env \
    PATH="$work/fakebin:$PATH" \
    MODE=hydrate BOOTSTRAP="$work/bootstrap" TRUSTED_ROOT="$work/trusted" \
    INPUT_URL='https://exact.example/input?sig=fixture' FM_HYDRATE_INPUT="$work/input.tar.gz" \
    INPUT_DIGEST="$(cat "$work/input.digest")" REQUEST_DIGEST="$(cat "$work/request.digest")" \
    CELL=azv-aaaaaaaaaaaa WORKTREE_DISK_ID=/work STATE="$work/cell/state" \
    HOME_DIR="$work/cell/home" REPO="$work/cell/repo" ATTEMPT=4 \
    HYDRATOR_DIGEST="sha256:$(sha256sum "$GUEST" | awk '{print $1}')" \
    FM_FORBIDDEN_AXI="$work/forbidden-axi" \
    bash -c '. "$1"' hydrate "$block" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the real guest hydrate path failed: $output"
  assert_contains "$output" 'FM_AZURE_VALIDATION_HYDRATED' \
    "the real guest hydrate path emitted no completion marker"
  [ ! -e "$work/forbidden-axi" ] || fail "hydration invoked no-mistakes instead of returning to reattach"
  python3 - "$work" <<'PY' || fail "hydration did not restore only the exact sealed tools"
import hashlib
import json
import os
from pathlib import Path
import sys
root=Path(sys.argv[1])
request=json.loads((root/"request.json").read_text())
runtime=root/"trusted/runtime"
actual={path.relative_to(runtime).as_posix() for path in runtime.rglob("*") if path.is_file()}
expected={record["path"] for record in request["runtime"]["files"]}|{"runtime.json"}
assert actual==expected,(actual,expected)
for record in request["runtime"]["files"]:
    path=runtime/record["path"]
    assert "sha256:"+hashlib.sha256(path.read_bytes()).hexdigest()==record["digest"]
for field in ("no_mistakes_path","provider_path","gh_path","node_path","gh_axi_path"):
    assert os.access(runtime/request["runtime"][field],os.X_OK),field
bridge=root/"trusted/shard-bridge.py"
assert "sha256:"+hashlib.sha256(bridge.read_bytes()).hexdigest()==request["protocol"]["shard_bridge_digest"]
assert (root/"cell/state/request.json").read_bytes()==(root/"request.json").read_bytes()
assert [path.relative_to(root/"cell/repo").as_posix() for path in (root/"cell/repo").rglob("*")]==["sentinel"]
assert [path.relative_to(root/"cell/home").as_posix() for path in (root/"cell/home").rglob("*")]==["sentinel"]
assert (root/"cell/repo/sentinel").read_text()=="retained repo\n"
assert (root/"cell/home/sentinel").read_text()=="retained home\n"
PY
  pass "replacement hydrates the exact sealed runtime and bridge before reattaching the retained run"
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
# The controller's own dispatch ledger: receipts must correspond to the shard
# round this cell actually created, not merely be well-formed.
state["shard_runs"]={item["request_digest"]:{"round":item["round"],"shard":item["shard"],"head":item["head"],"command_digest":item["command_digest"],"invocation":item["invocation"]} for item in receipts}
result={
 "schema":"fm.azure-validation-result/v1","request_digest":state["request_digest"],"cell":state["cell"],"home_binding":state["request"]["home_binding"],"task":"task","task_generation":"gen","validation_generation":"val","fence":state["request"]["fence"],"branch":"fm/task","submitted_head":head,"current_head":head,"current_tree":tree,"remote_head":head,"worktree_disk_id":"/work","run_id":"01HZX7YQ7EJQH8C9G3N4M5P6R7","vm_resource_id":"/vm","vm_instance_id":"vm-instance","boot_id":state["expected_boot_id"],"attempt":state["attempt"],"outcome":"checks-passed","checks_green":True,"pr_url":"https://github.com/o/r/pull/1","behavior_shards":receipts
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
reject("another attempt of the same run",lambda r:r.__setitem__("attempt",1 if r["attempt"]!=1 else 2))
reject("result declaring no attempt",lambda r:r.pop("attempt"))
reject("attempt declared as a bare boolean",lambda r:r.__setitem__("attempt",True))
reject("stale shard head",lambda r:r["behavior_shards"][0].__setitem__("head","c"*40))
reject("stale shard tree",lambda r:r["behavior_shards"][0].__setitem__("tree","c"*40))
reject("alien shard round",lambda r:[item.__setitem__("round","round-ffffffffffff") for item in r["behavior_shards"]])
reject("undispatched receipt digest",lambda r:r["behavior_shards"][0].__setitem__("request_digest","sha256:"+"e"*64))
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

shard_receipt_demotion_contract() {
  local work block full
  work=$(fm_test_tmproot fm-azure-validation-shard-demotion)

  # Drive the guest's real text from the demotion through the result assembly,
  # so the assertions land on the artifact the controller reads rather than on
  # shell variables. A unit that only checks $OUTCOME cannot see a demotion that
  # runs after the result was already written, which is the ordering this whole
  # change depends on.
  block=$work/emit.sh
  awk '/^SHARD_RECEIPTS=\$SHARD_EXCHANGE/,/^RESULT_ARCHIVE=/' "$GUEST" \
    | grep -v '^install -d\|^cp \|^RESULT_ARCHIVE=' >"$block"
  [ -s "$block" ] || fail "the guest result-emission region was not found"
  grep -q 'OUTCOME=failed' "$block" || fail "the extracted region does not demote the outcome"
  grep -q 'behavior_shards' "$block" || fail "the extracted region does not assemble the result"
  grep -q 'Behavior shards:' "$block" || fail "the extracted region does not write the operator report"
  # The guest reads its boot id from procfs, which the extracted region cannot.
  # shellcheck disable=SC2016  # The pattern is literal guest text, not an expansion.
  sed -i.bak 's#\$(cat /proc/sys/kernel/random/boot_id)#boot-id#' "$block" && rm -f "$block.bak"

  mkdir -p "$work/exchange" "$work/state" "$work/evidence/attempt-1"
  # Only the shard count varies; pass it as a value so the JSON braces are
  # not shell literals. "none" omits the field entirely.
  write_request() {
    local limits=""
    [ "$1" = none ] || limits="\"behavior_shards\":$1"
    {
      printf '{"limits":{%s},"protocol":{"result_schema":"fm.test/v1"},' "$limits"
      printf '"request_digest":"d","cell":"c","home_binding":"h","task":"t",'
      printf '"task_generation":"g","validation_generation":"v","fence":"f",'
      printf '"repository":{"branch":"b","head":"hh"}}\n'
    } >"$work/request.json"
  }
  write_request 8
  printf '{"worktree_disk_id":"wd","run_id":"nm-run"}\n' >"$work/identity.json"

  cat >"$work/drive.sh" <<'DRIVER'
set -euo pipefail
SHARD_EXCHANGE=$FM_TEST_WORK/exchange
REQUEST=$FM_TEST_WORK/request.json
IDENTITY=$FM_TEST_WORK/identity.json
STATE=$FM_TEST_WORK/state
EVIDENCE=$FM_TEST_WORK/evidence
ATTEMPT=1
CELL=c
OUTCOME=$FM_TEST_OUTCOME
CURRENT_HEAD=hh
CURRENT_TREE=tt
REMOTE_HEAD=hh
RUN_ID=nm-run
VM_RESOURCE_ID=/vm
VM_INSTANCE_ID=vmi
START_EPOCH=1 END_EPOCH=2 START_LOAD=0 END_LOAD=0
START_MEM_AVAILABLE_KIB=1 END_MEM_AVAILABLE_KIB=1
PR=https://github.com/o/r/pull/1
CHECKS_GREEN=false
case "$OUTCOME" in passed|checks-passed) CHECKS_GREEN=true ;; esac
. "$FM_TEST_BLOCK"
DRIVER

  emit() {
    rm -f "$work/state/result-a1.json" "$work/state/report.md" "$work/exchange/receipts.json"
    [ "$2" = ABSENT ] || printf '%s\n' "$2" >"$work/exchange/receipts.json"
    env FM_TEST_BLOCK="$block" FM_TEST_WORK="$work" FM_TEST_OUTCOME="$1" bash "$work/drive.sh"
  }
  assert_result() {
    grep -q "$1" "$work/state/result-a1.json" || fail "$2"
  }

  full=$(python3 -c 'import json;print(json.dumps([{"shard":i} for i in range(1,9)]))')

  emit passed "$full" >/dev/null 2>&1 || fail "emitting a complete result failed"
  assert_result '"outcome":"passed"' "a complete receipt set did not keep its passed outcome"
  assert_result '"checks_green":true' "a complete receipt set lost its CI-green marker"

  # The stranding case, asserted on the emitted result rather than a shell
  # variable: if the demotion runs after the result is assembled, this file
  # still says passed and the cell strands exactly as before.
  emit passed '[]' >/dev/null 2>&1 || fail "emitting a shortfall result failed"
  assert_result '"outcome":"failed"' "a passed result with no shard receipts was emitted undemoted"
  assert_result '"checks_green":false' "a demoted result kept its CI-green marker"
  assert_grep "Behavior shards:" "$work/state/report.md" "the report omitted the shard shortfall"
  assert_grep "found 0" "$work/state/report.md" "the report omitted the observed receipt count"

  emit checks-passed "$(python3 -c 'import json;print(json.dumps([{"shard":i} for i in range(1,4)]))')" >/dev/null 2>&1
  assert_result '"outcome":"failed"' "a partial receipt set was emitted undemoted"

  # An unreadable count must fail closed. The obvious numeric default, zero, is
  # exactly the observed value here, so a plain count comparison would wave this
  # through at the moment the check matters most.
  write_request none
  emit passed '[]' >/dev/null 2>&1
  assert_result '"outcome":"failed"' "an unreadable shard count was treated as zero expected"
  assert_grep "unreadable" "$work/state/report.md" "the report did not name the unreadable shard count"

  write_request 8
  emit passed '{"not":"an array"}' >/dev/null 2>&1
  assert_result '"outcome":"failed"' "a malformed receipt file was treated as a count"
  emit passed ABSENT >/dev/null 2>&1
  assert_result '"outcome":"failed"' "an absent receipt file was treated as a count"

  # Receipts that jq itself cannot parse take the shell fallback rather than the
  # jq else-branch, so a fallback that reuses the expected count would match it.
  emit passed 'this is not json at all {' >/dev/null 2>&1
  assert_result '"outcome":"failed"' "an unparseable receipt file was treated as a matching count"

  # A count that is a number but not an integer cannot be compared numerically;
  # without an explicit guard the arithmetic test errors, and an errored test in
  # an if-condition reads as false, so the shortfall passes silently.
  write_request 8.0
  emit passed "$full" >/dev/null 2>&1
  assert_result '"outcome":"failed"' "a non-integer shard count was compared instead of refused"
  write_request 8

  # An already-failed run is untouched, so the check cannot invent a second
  # reason for a failure that already has one.
  emit failed '[]' >/dev/null 2>&1
  assert_result '"outcome":"failed"' "an already-failed outcome was rewritten"
  if grep -q "Behavior shards:" "$work/state/report.md"; then
    fail "an already-failed outcome gained a spurious shard shortfall"
  fi

  # A request that asks for no shards is satisfied by no receipts.
  write_request 0
  emit passed '[]' >/dev/null 2>&1
  assert_result '"outcome":"passed"' "a zero-shard request was demoted"

  # Receipts are cleared at run boundaries only; the run-scope contract below
  # owns the behavioral proof for both directions.
  grep -q 'rm -f ..SHARD_EXCHANGE/receipts.json' "$GUEST" \
    || fail "the guest does not clear a stale receipt set at a run boundary"

  pass "a passed cell result without its complete shard receipt set is demoted in the emitted result, not refused after the spend"
}

receipt_run_scope_contract() {
  local work block
  work=$(fm_test_tmproot fm-azure-validation-receipt-scope)

  # Drive the guest's real receipt-wipe text. no-mistakes does not re-execute
  # an already-green test step when a resumed attempt continues the same run,
  # so the round's receipts on the durable shard exchange are the final
  # attempt's only proof that sharding happened; a per-attempt wipe therefore
  # demotes every multi-attempt run and the cell can never close. Only a
  # start boot (a fresh run) begins from no receipts.
  block=$work/wipe.sh
  awk '/^# Receipts are run-scoped/{f=1} f{print; if($0=="fi") exit}' "$GUEST" >"$block"
  [ -s "$block" ] || fail "the guest receipt-wipe region was not found"
  # shellcheck disable=SC2016  # The pattern is literal guest text, not an expansion.
  grep -q 'rm -f "$SHARD_EXCHANGE/receipts.json"' "$block" \
    || fail "the extracted region does not clear receipts"

  run_wipe() {  # <mode>
    mkdir -p "$work/exchange"
    printf '[]\n' >"$work/exchange/receipts.json"
    # shellcheck disable=SC2016  # The inner shell reads its own environment.
    env MODE="$1" SHARD_EXCHANGE="$work/exchange" \
      bash -c 'set -euo pipefail; MODE=$MODE; SHARD_EXCHANGE=$SHARD_EXCHANGE; . "$1"' wipe "$block"
  }

  run_wipe start || fail "the wipe region failed under start mode"
  [ ! -e "$work/exchange/receipts.json" ] \
    || fail "a start boot (fresh run) inherited a previous run's receipts"

  for mode in reattach respond; do
    run_wipe "$mode" || fail "the wipe region failed under $mode mode"
    [ -e "$work/exchange/receipts.json" ] \
      || fail "a resumed $mode attempt destroyed the run's own shard receipts"
  done

  pass "shard receipts survive resumed attempts of the same run and never cross a run boundary"
}

terminal_classifier_optional_matches_contract() {
  local work snippet output
  work=$(fm_test_tmproot fm-azure-validation-terminal-classifier)
  snippet=$work/classify.sh

  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
      "RUN_LOG=\$1" "STATUS_LOG=\$2" "STATUS_RC=\$3" "RUN_EXIT=\$4"
    awk '/^OUTCOME=failed$/{found=1} found{if(/^SHARD_RECEIPTS=/) exit; print}' "$GUEST"
    printf '%s\n' "printf '%s\\t%s\\t%s\\n' \"\$OUTCOME\" \"\$CHECKS_GREEN\" \"\$PR\""
  } >"$snippet"
  [ "$(grep -c '^OUTCOME=failed$' "$snippet")" -ge 1 ] \
    || fail "the real terminal classifier region was not extracted"

  printf '%s\n' 'outcome: failed' >"$work/status.log"
  printf '%s\n' 'review,completed,0' >"$work/no-outcome.log"
  output=$(bash "$snippet" "$work/no-outcome.log" "$work/status.log" 0 1) \
    || fail "a failed status with no rendered run outcome aborted before result assembly"
  [ "$output" = "failed"$'\t'"false"$'\t' ] \
    || fail "a failed status with no rendered run outcome was misclassified: $output"

  printf '%s\n' 'outcome: failed' >"$work/no-gate.log"
  output=$(bash "$snippet" "$work/no-gate.log" "$work/status.log" 0 1) \
    || fail "a terminal run with no awaiting gate aborted before result assembly"
  [ "$output" = "failed"$'\t'"false"$'\t' ] \
    || fail "a terminal run with no awaiting gate invented a decision: $output"

  printf '%s\n' 'status: awaiting_approval' >"$work/gate.log"
  output=$(bash "$snippet" "$work/gate.log" "$work/status.log" 0 1) \
    || fail "the terminal classifier aborted on an actual awaiting gate"
  [ "$output" = "needs-decision"$'\t'"false"$'\t' ] \
    || fail "the terminal classifier did not preserve an actual awaiting gate: $output"

  pass "terminal result classification tolerates optional no-match fields and still finds a real gate"
}

receipt_chain_close_contract() {
  local tmp work exchange head tree block
  fm_test_tmproot_into tmp fm-azure-validation-receipt-chain
  work=$tmp/work
  exchange=$work/exchange
  mkdir -p "$work" "$exchange" "$tmp/home"
  make_repo "$tmp/project"
  head=$(git -C "$tmp/project/repo" rev-parse HEAD)
  tree=$(git -C "$tmp/project/repo" rev-parse 'HEAD^{tree}')
  # A later pipeline commit (documentation) publishes a head whose receipts
  # legitimately prove an exact ancestor - the multi-attempt shape R4 fixes.
  git -C "$tmp/project/repo" commit -q --allow-empty -m docs
  git -C "$tmp/project/repo" push -q origin fm/fixture
  published_head=$(git -C "$tmp/project/repo" rev-parse HEAD)
  published_tree=$(git -C "$tmp/project/repo" rev-parse 'HEAD^{tree}')

  # 1. The REAL in-cell bridge emits the receipt set from a completed shard
  # round: verify_behavior against the repository's own trusted plan.
  (cd "$ROOT" && python3 - "$BRIDGE" "$work" "$exchange" "$head" "$tree" <<'PY') \
    || fail "the real bridge did not emit the receipts close requires"
import hashlib,importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
work=pathlib.Path(sys.argv[2]); exchange=pathlib.Path(sys.argv[3])
head,tree=sys.argv[4],sys.argv[5]
count=8
plan=m.trusted_behavior_plan(pathlib.Path.cwd(),count)
environment={"cell":"azv-aaaaaaaaaaaa","exchange":exchange}
round_dir=work/"round"; round_dir.mkdir()
results={}
for shard in range(1,count+1):
    directory=round_dir/"response-{}".format(shard); directory.mkdir()
    manifest="".join("{}\t{}\t0\t1\n".format(shard,path) for path in plan[shard])
    source=directory/"executed.tsv"; source.write_text(manifest)
    digest="sha256:"+hashlib.sha256(source.read_bytes()).hexdigest()
    results[shard]={"directory":directory,"result":{
        "round":"round-aaaaaaaaaaaa","kind":"behavior","shard":shard,"shard_count":count,
        "head":head,"tree":tree,
        "request_digest":"sha256:"+format(shard,"064x"),
        "command_digest":"sha256:"+format(shard+8,"064x"),
        "invocation":"azr-"+format(shard,"012x"),
        "vm_instance_id":"vm-{}".format(shard),"boot_id":"boot-{}".format(shard),
        "artifact":{"path":"results/executed-{}.tsv".format(shard),"digest":digest,"bytes":source.stat().st_size},
        "duration_seconds":10,"cost_usd":0.01,
    }}
m.verify_behavior(environment,round_dir,results,count)
receipts=json.loads((exchange/"receipts.json").read_text())
assert isinstance(receipts,list) and len(receipts)==count, "bridge emitted an incomplete receipt set"
for item in receipts:
    for key in ("round","kind","shard","shard_count","head","tree","request_digest","command_digest","invocation","vm_instance_id","boot_id","artifact"):
        assert key in item, "receipt lacks "+key
PY

  # 2. The REAL guest result assembly carries that receipt set into the
  # emitted result without demotion.
  block=$work/emit.sh
  awk '/^SHARD_RECEIPTS=\$SHARD_EXCHANGE/,/^RESULT_ARCHIVE=/' "$GUEST" \
    | grep -v '^install -d\|^cp \|^RESULT_ARCHIVE=' >"$block"
  [ -s "$block" ] || fail "the guest result-emission region was not found"
  # shellcheck disable=SC2016  # The pattern is literal guest text, not an expansion.
  sed -i.bak 's#\$(cat /proc/sys/kernel/random/boot_id)#44444444-4444-4444-8444-444444444444#' "$block" && rm -f "$block.bak"
  mkdir -p "$work/state" "$work/evidence/attempt-2"
  python3 - "$work/request.json" "$head" <<'PY'
import json,sys
request={
  "limits":{"behavior_shards":8},
  "protocol":{"result_schema":"fm.azure-validation-result/v1"},
  "request_digest":"sha256:"+"1"*64,"cell":"azv-aaaaaaaaaaaa",
  "home_binding":"sha256:"+"2"*64,"task":"task","task_generation":"gen",
  "validation_generation":"val","fence":"sha256:"+"3"*64,
  "repository":{"branch":"fm/fixture","head":sys.argv[2],"slug":"o/r"},
}
open(sys.argv[1],"w").write(json.dumps(request)+"\n")
PY
  printf '{"worktree_disk_id":"/work","run_id":"01HZX7YQ7EJQH8C9G3N4M5P6R7"}\n' >"$work/identity.json"
  cat >"$work/drive.sh" <<'DRIVER'
set -euo pipefail
SHARD_EXCHANGE=$FM_TEST_WORK/exchange
REQUEST=$FM_TEST_WORK/request.json
IDENTITY=$FM_TEST_WORK/identity.json
STATE=$FM_TEST_WORK/state
EVIDENCE=$FM_TEST_WORK/evidence
ATTEMPT=2
CELL=azv-aaaaaaaaaaaa
OUTCOME=checks-passed
CURRENT_HEAD=$FM_TEST_HEAD
CURRENT_TREE=$FM_TEST_TREE
REMOTE_HEAD=$FM_TEST_HEAD
RUN_ID=01HZX7YQ7EJQH8C9G3N4M5P6R7
VM_RESOURCE_ID=/vm
VM_INSTANCE_ID=vm-instance
START_EPOCH=1 END_EPOCH=2 START_LOAD=0 END_LOAD=0
START_MEM_AVAILABLE_KIB=1 END_MEM_AVAILABLE_KIB=1
PR=https://github.com/o/r/pull/7
CHECKS_GREEN=true
. "$FM_TEST_BLOCK"
DRIVER
  env FM_TEST_BLOCK="$block" FM_TEST_WORK="$work" FM_TEST_HEAD="$head" FM_TEST_TREE="$tree" \
    bash "$work/drive.sh" >/dev/null 2>&1 || fail "guest result assembly failed on a complete receipt set"
  python3 - "$work/state/result-a2.json" <<'PY' || fail "the emitted result lost the run's receipt set"
import json,sys
result=json.load(open(sys.argv[1]))
assert result["outcome"]=="checks-passed", "a resumed attempt carrying the round's receipts was demoted: "+result["outcome"]
assert result["checks_green"] is True
assert len(result["behavior_shards"])==8, "the emitted result dropped receipts"
PY

  # 3+4. The REAL controller receipt gate accepts exactly that emitted result
  # bound to this cell's own dispatched shard round, accepts the receipts as
  # proof of an exact ancestor of the published head, refuses an alien round
  # at that same valid ancestor head, refuses an empty set, and the REAL
  # close gate closes the cell on the ancestor-proved result while a demoted
  # (failed) result still cannot close.
  python3 - "$HOST" "$work/state/result-a2.json" "$tmp/home" "$tmp/project/repo" \
    "$published_head" "$published_tree" <<'PY' \
    || fail "collect/close did not accept the receipts the bridge produced"
import copy,importlib.util,json,pathlib,sys,types
spec=importlib.util.spec_from_file_location("validation",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
result=json.load(open(sys.argv[2]))
home=pathlib.Path(sys.argv[3]); repo=sys.argv[4]
published_head,published_tree=sys.argv[5],sys.argv[6]
state={
  "schema":m.SCHEMA,"cell":"azv-aaaaaaaaaaaa","phase":"collected","attempt":2,
  "request_digest":result["request_digest"],
  "repository_root":repo,
  "started_at":"2026-08-20T00:00:00Z",
  "request":{
    "home_binding":result["home_binding"],"task":"task","task_generation":"gen",
    "validation_generation":"val","fence":result["fence"],
    "repository":{"slug":"o/r","branch":"fm/fixture","head":result["submitted_head"]},
    "limits":{"behavior_shards":8},
  },
  "resources":{"worktree_disk_id":"/work","vm_id":"/vm","vm_instance_id":"vm-instance"},
  "expected_boot_id":"44444444-4444-4444-8444-444444444444",
  # The controller's own dispatch ledger for this cell's shard round, exactly
  # as drive() records it when it serves the bridge's requests.
  "shard_runs":{item["request_digest"]:{
      "round":item["round"],"shard":item["shard"],"head":item["head"],
      "command_digest":item["command_digest"],"invocation":item["invocation"],
  } for item in result["behavior_shards"]},
  "result":result,
}
# The controller's own receipt gate accepts the exact emitted result.
m.verify_result_identity(state,result)
# The multi-attempt shape: a later pipeline commit published a descendant
# head, and the round's receipts legitimately prove the exact ancestor.
ancestor=copy.deepcopy(result)
ancestor["current_head"]=published_head; ancestor["current_tree"]=published_tree
ancestor["remote_head"]=published_head
m.verify_result_identity(state,ancestor)
# An alien round at that same valid ancestor head does not correspond to
# this cell's own dispatched shard round and is refused.
alien=copy.deepcopy(ancestor)
for item in alien["behavior_shards"]:
    item["round"]="round-ffffffffffff"
try:
    m.verify_result_identity(state,alien)
except m.ValidationError as exc:
    assert "own dispatched shard round" in str(exc), str(exc)
else:
    raise AssertionError("an alien shard round at a valid ancestor head was accepted")
# An empty receipt set on the same otherwise-successful result is refused.
empty=copy.deepcopy(result); empty["behavior_shards"]=[]
try:
    m.verify_result_identity(state,empty)
except m.ValidationError as exc:
    assert "receipt set" in str(exc)
else:
    raise AssertionError("a successful result with no receipts was accepted")
# The REAL close path on the ancestor-proved result: compute/storage teardown
# is faked, every gate is real, and the remote-branch proof runs real git.
env={"home":home,"state_dir":home/"state"/"azure-validation","subscription":"sub"}
m.ensure_dirs(env)
state["result"]=ancestor
(env["state_dir"]/"azv-aaaaaaaaaaaa.json").write_text(json.dumps(state))
m.cleanup_compute=lambda _env,_state:None
m.delete_resource=lambda *_args,**_kwargs:None
m.delete_cell_storage_scope=lambda _env,_state:None
args=types.SimpleNamespace(cell="azv-aaaaaaaaaaaa",confirm_close=True,confirm_subscription="sub",confirm_head=published_head)
m.close(env,args)
closed=json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())
assert closed["phase"]=="closed", "close did not reach the closed phase: "+closed["phase"]
# A demoted cell still cannot close: the failed outcome retains storage.
failed=copy.deepcopy(state); failed["phase"]="collected"
failed["result"]=copy.deepcopy(ancestor); failed["result"]["outcome"]="failed"; failed["result"]["checks_green"]=False
(env["state_dir"]/"azv-aaaaaaaaaaaa.json").write_text(json.dumps(failed))
try:
    m.close(env,args)
except m.ValidationError as exc:
    assert "retains durable storage" in str(exc)
else:
    raise AssertionError("a demoted failed result was closed")
PY

  pass "the real bridge emits the receipt set, the guest carries it, and the real collect and close gates accept it end to end, bound to this cell's own shard round"
}

gate_answer_binding_contract() {
  local tmp work head tree block marker_block
  fm_test_tmproot_into tmp fm-azure-validation-gate-answer
  work=$tmp/work
  mkdir -p "$work/exchange" "$work/state" "$work/evidence/attempt-1" "$work/evidence/attempt-2" "$tmp/home"
  make_repo "$tmp/project"
  head=$(git -C "$tmp/project/repo" rev-parse HEAD)
  tree=$(git -C "$tmp/project/repo" rev-parse 'HEAD^{tree}')
  printf '[]\n' >"$work/exchange/receipts.json"

  # 1. The REAL guest result-assembly region must stamp the attempt that
  # produced the result, and the REAL marker line must name it too. Without
  # both, nothing a control-plane read can see separates one attempt of a
  # resumed run from another: same VM, same boot id, same run id.
  block=$work/emit.sh
  awk '/^SHARD_RECEIPTS=\$SHARD_EXCHANGE/,/^RESULT_ARCHIVE=/' "$GUEST" \
    | grep -v '^install -d\|^cp \|^RESULT_ARCHIVE=' >"$block"
  [ -s "$block" ] || fail "the guest result-emission region was not found"
  # shellcheck disable=SC2016  # The pattern is literal guest text, not an expansion.
  sed -i.bak 's#\$(cat /proc/sys/kernel/random/boot_id)#44444444-4444-4444-8444-444444444444#' "$block" && rm -f "$block.bak"
  marker_block=$work/marker.sh
  grep '^printf .FM_AZURE_VALIDATION_RESULT' "$GUEST" >"$marker_block"
  [ -s "$marker_block" ] || fail "the guest result marker line was not found"

  python3 - "$work/request.json" "$head" <<'PY'
import json,sys
request={
  "limits":{"behavior_shards":0},
  "protocol":{"result_schema":"fm.azure-validation-result/v1"},
  "request_digest":"sha256:"+"1"*64,"cell":"azv-aaaaaaaaaaaa",
  "home_binding":"sha256:"+"2"*64,"task":"task","task_generation":"gen",
  "validation_generation":"val","fence":"sha256:"+"3"*64,
  "repository":{"branch":"fm/fixture","head":sys.argv[2],"slug":"o/r"},
}
open(sys.argv[1],"w").write(json.dumps(request)+"\n")
PY
  printf '{"worktree_disk_id":"/work","run_id":"01HZX7YQ7EJQH8C9G3N4M5P6R7"}\n' >"$work/identity.json"
  cat >"$work/drive.sh" <<'DRIVER'
set -euo pipefail
SHARD_EXCHANGE=$FM_TEST_WORK/exchange
REQUEST=$FM_TEST_WORK/request.json
IDENTITY=$FM_TEST_WORK/identity.json
STATE=$FM_TEST_WORK/state
EVIDENCE=$FM_TEST_WORK/evidence
ATTEMPT=$FM_TEST_ATTEMPT
CELL=azv-aaaaaaaaaaaa
OUTCOME=needs-decision
CURRENT_HEAD=$FM_TEST_HEAD
CURRENT_TREE=$FM_TEST_TREE
REMOTE_HEAD=$FM_TEST_HEAD
RUN_ID=01HZX7YQ7EJQH8C9G3N4M5P6R7
VM_RESOURCE_ID=/vm
VM_INSTANCE_ID=vm-instance
START_EPOCH=1 END_EPOCH=2 START_LOAD=0 END_LOAD=0
START_MEM_AVAILABLE_KIB=1 END_MEM_AVAILABLE_KIB=1
PR=
CHECKS_GREEN=false
. "$FM_TEST_BLOCK"
RESULT_DIGEST=sha256:$(printf '%064d' "$FM_TEST_DIGEST_SEED")
BOOT_ID=44444444-4444-4444-8444-444444444444
. "$FM_TEST_MARKER" >"$STATE/marker-a$ATTEMPT.txt"
DRIVER
  for attempt in 1 2; do
    env FM_TEST_BLOCK="$block" FM_TEST_MARKER="$marker_block" FM_TEST_WORK="$work" \
      FM_TEST_HEAD="$head" FM_TEST_TREE="$tree" FM_TEST_ATTEMPT="$attempt" FM_TEST_DIGEST_SEED=7 \
      bash "$work/drive.sh" >/dev/null 2>&1 \
      || fail "guest result assembly failed for attempt $attempt"
  done

  # The two attempts differ ONLY in the attempt field, which is exactly the
  # live shape: same run id, same outcome, same gate, same heads.
  python3 - "$work/state/result-a1.json" "$work/state/result-a2.json" \
    "$work/state/marker-a1.txt" "$work/state/marker-a2.txt" "$HOST" <<'PY' \
    || fail "the guest does not bind its published result and marker to the attempt"
import importlib.util,json,pathlib,sys
one=json.load(open(sys.argv[1])); two=json.load(open(sys.argv[2]))
assert one.get("attempt")==1, "result.json does not carry its attempt: "+repr(one.get("attempt"))
assert two.get("attempt")==2, "result.json does not carry its attempt: "+repr(two.get("attempt"))
stripped_one=dict(one); stripped_one.pop("attempt")
stripped_two=dict(two); stripped_two.pop("attempt")
assert stripped_one==stripped_two, "the fixture must differ only by attempt to prove the binding is load-bearing"
spec=importlib.util.spec_from_file_location("validation",sys.argv[5])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for index,expected in ((3,1),(4,2)):
    line=pathlib.Path(sys.argv[index]).read_text()
    found=m.MARKER.search(line)
    assert found, "the guest marker is not accepted by the controller reader: "+line
    assert int(found.group(4))==expected, "the marker names attempt "+found.group(4)
PY

  # 2. The REAL observe gate against the exact live shapes.
  python3 - "$HOST" "$tmp/home" "$work/state/result-a1.json" "$work/state/result-a2.json" <<'PY' \
    || fail "observe did not bind the control view to the attempt it is observing"
import importlib.util,json,pathlib,sys,types
spec=importlib.util.spec_from_file_location("validation",sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home=pathlib.Path(sys.argv[2])
env={"home":home,"state_dir":home/"state"/"azure-validation","subscription":"sub"}
m.ensure_dirs(env)
args=types.SimpleNamespace(cell="azv-aaaaaaaaaaaa")
digest_one="sha256:"+"a"*64
digest_two="sha256:"+"b"*64
boot="44444444-4444-4444-8444-444444444444"

def marker(digest,attempt,outcome="needs-decision"):
    return "FM_AZURE_VALIDATION_RESULT {} boot={} outcome={} attempt={}\n".format(digest,boot,outcome,attempt)

def seed(phase="responding",attempt=2,**extra):
    state={
      "schema":m.SCHEMA,"cell":"azv-aaaaaaaaaaaa","phase":phase,"attempt":attempt,
      "request_digest":"sha256:"+"1"*64,
      "request":{"repository":{"head":"0"*40,"branch":"fm/fixture","slug":"o/r"},
                 "task":"task","task_generation":"gen","validation_generation":"val",
                 "limits":{"behavior_shards":0}},
      "resources":{"run_command_id":"/vm/runCommands/respond-a2"},
      "guest_stamps_attempt":True,
      "events":[],
    }
    state.update(extra)
    if state.get("guest_stamps_attempt") is None:
        state.pop("guest_stamps_attempt",None)
    (env["state_dir"]/"azv-aaaaaaaaaaaa.json").write_text(json.dumps(state))
    return state

def view(output="",error="",execution="Failed"):
    m.run_command_status=lambda _env,_state:(execution,{"output":output,"error":error})

def phase():
    return json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())["phase"]

# 2a. Terminal control state with NO marker: the live azv-36b2 shape, read
# nine seconds after the respond Run Command was created while the attempt
# was still executing. It must not strand the cell on the first read.
seed()
view(error="validation guest: auth-home push failed\n")
m.observe(env,args)
assert phase()=="responding", "an unbound terminal view stranded the cell on its first read: "+phase()

# The same ambiguity, persisted past the settling window, IS believed: the
# guard delays a destructive decision, it never abandons it.
import os
os.environ["FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS"]="0"
seed()
view(error="validation guest: auth-home push failed\n")
try:
    m.observe(env,args)
except m.ValidationError as exc:
    assert "authenticated result" in str(exc), str(exc)
else:
    raise AssertionError("a settled unbound terminal view was never believed")
assert phase()=="failed-retained", phase()
os.environ.pop("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS")

# 2b. The previous attempt's own marker is not this attempt's answer. Every
# other field it carries (digest, boot, outcome) is legitimate.
seed()
view(output=marker(digest_one,1))
m.observe(env,args)
assert phase()=="responding", "attempt 1's marker was accepted as attempt 2's answer"

# 2c. This attempt's marker republishing the previous attempt's exact bytes
# is a NON-ANSWER and must say so, not surface as a generic failure.
os.environ["FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS"]="0"
seed(attempt_result_digests={"1":digest_one})
view(output=marker(digest_one,2))
try:
    m.observe(env,args)
except m.ValidationError as exc:
    assert "non-answer" in str(exc) and "byte-identical" in str(exc), str(exc)
else:
    raise AssertionError("an unchanged republished result was accepted as a verdict")
assert phase()=="failed-retained", phase()
recorded=json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())
assert "republished" in recorded["events"][-1]["note"], recorded["events"][-1]["note"]
os.environ.pop("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS")

# 2d. A genuinely new attempt result is accepted and recorded per attempt.
seed(attempt_result_digests={"1":digest_one})
view(output=marker(digest_two,2))
m.observe(env,args)
assert phase()=="needs-decision", phase()
recorded=json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())
assert recorded["attempt_result_digests"]=={"1":digest_one,"2":digest_two}, recorded["attempt_result_digests"]
assert recorded["expected_result_digest"]==digest_two
# The NORMAL path must record the strict binding. Pinning only the legacy case
# leaves "every observation binds legacy" green while disabling the attempt
# check for every modern cell.
assert recorded["result_binding"]=="attempt", recorded.get("result_binding")
observed_binding=recorded["result_binding"]

# 2e. TWO markers in one output: the current attempt's is accepted wherever it
# sits, and the FIRST marker no longer wins.
seed(attempt_result_digests={"1":digest_one})
view(output=marker(digest_one,1)+"noise\n"+marker(digest_two,2))
m.observe(env,args)
assert phase()=="needs-decision", "a later marker naming this attempt was not accepted: "+phase()
assert json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())["expected_result_digest"]==digest_two

# 2f. Two DIFFERENT results claiming one attempt is not an answer.
os.environ["FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS"]="0"
seed()
view(output=marker(digest_one,2)+marker(digest_two,2))
try:
    m.observe(env,args)
except m.ValidationError:
    pass
else:
    raise AssertionError("two conflicting results for one attempt were accepted")
os.environ.pop("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS")

# 2g. LEGACY: a cell whose sealed guest predates the attempt stamp publishes an
# UNSTAMPED marker. The request is digest-sealed so that guest can never be
# changed; refusing to read it would retain a cell on a fully published result
# and leave expected_result_digest unset, making the result unreachable.
os.environ["FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS"]="0"
seed(guest_stamps_attempt=False)
view(output="FM_AZURE_VALIDATION_RESULT {} boot={} outcome=needs-decision\n".format(digest_two,boot))
m.observe(env,args)
recorded=json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())
assert phase()=="needs-decision", "a legacy cell was stranded by the attempt binding: "+phase()
assert recorded["expected_result_digest"]==digest_two, "legacy result is unreachable"
assert recorded["result_binding"]=="legacy", recorded.get("result_binding")
# A STAMPED marker naming another attempt must NOT take the legacy path.
seed()
view(output=marker(digest_two,1))
try:
    m.observe(env,args)
except m.ValidationError:
    pass
else:
    raise AssertionError("a stamped marker for another attempt fell through to the legacy path")
os.environ.pop("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS")

# 2h. A guest that CAN stamp never buys the pre-stamp contract with a malformed
# marker. LEGACY_MARKER is MARKER minus the attempt group, so every one of these
# satisfies "no stamped marker matched"; the binding must come from the sealed
# guest instead. The marker is the guest's LAST line by design, which is exactly
# where an output cap lands, so this is a live shape rather than a theoretical one.
os.environ["FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS"]="0"
malformed={
  "truncated inside the attempt word":
    "FM_AZURE_VALIDATION_RESULT {} boot={} outcome=needs-decision attem".format(digest_two,boot),
  "truncated right after attempt=":
    "FM_AZURE_VALIDATION_RESULT {} boot={} outcome=needs-decision attempt=".format(digest_two,boot),
  "empty attempt value":
    "FM_AZURE_VALIDATION_RESULT {} boot={} outcome=needs-decision attempt=\n".format(digest_two,boot),
  "non-numeric attempt value":
    "FM_AZURE_VALIDATION_RESULT {} boot={} outcome=needs-decision attempt=two\n".format(digest_two,boot),
}
for label,output in malformed.items():
    seed()
    view(output=output)
    try:
        m.observe(env,args)
    except m.ValidationError:
        pass
    else:
        raise AssertionError("a stamping guest fell back to the legacy contract on "+label)
    after=json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())
    assert after.get("expected_result_digest") is None, \
        "a malformed marker still published a digest on "+label
    assert after.get("result_binding")!="legacy", \
        "a stamping guest was bound legacy on "+label

# 2h-bis. A state that cannot answer "can this guest stamp" - no recorded flag,
# no staged payload to derive it from - takes the STRICT contract. Falling back
# to the weaker one would let exactly the states we know least about skip the
# attempt check.
seed(guest_stamps_attempt=None)
view(output="FM_AZURE_VALIDATION_RESULT {} boot={} outcome=needs-decision\n".format(digest_two,boot))
try:
    m.observe(env,args)
except m.ValidationError:
    pass
else:
    raise AssertionError("an underivable stamping answer bought the weaker legacy contract")
after=json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())
assert after.get("result_binding")!="legacy", after.get("result_binding")

# 2i. The composed shape, which is the silent false verdict this PR exists to
# close, re-entered through the parse-failure path: observing attempt 2, the
# output carries attempt 1's own marker truncated inside its attempt field. If
# legacy bound here, the expected digest would become attempt 1's, the blob
# still holds attempt 1's archive so the digest check passes, and the attempt
# check is skipped.
seed(attempt_result_digests={"1":digest_one})
view(output="FM_AZURE_VALIDATION_RESULT {} boot={} outcome=needs-decision attempt=".format(digest_one,boot))
try:
    m.observe(env,args)
except m.ValidationError:
    pass
else:
    raise AssertionError("a truncated stale attempt-1 marker was accepted as attempt 2's answer")
after=json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())
assert after.get("expected_result_digest")!=digest_one, \
    "attempt 1's digest became attempt 2's expected result"
os.environ.pop("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS")

# 3. The REAL result-identity gate refuses a result from another attempt and
# refuses one that does not declare its attempt at all.
result=json.load(open(sys.argv[4]))
state={
  "schema":m.SCHEMA,"cell":"azv-aaaaaaaaaaaa","phase":"needs-decision","attempt":2,
  "request_digest":result["request_digest"],
  "request":{
    "home_binding":result["home_binding"],"task":"task","task_generation":"gen",
    "validation_generation":"val","fence":result["fence"],
    "repository":{"slug":"o/r","branch":"fm/fixture","head":result["submitted_head"]},
    "limits":{"behavior_shards":0},
  },
  "resources":{"worktree_disk_id":"/work","vm_id":"/vm","vm_instance_id":"vm-instance"},
  "expected_boot_id":boot,
  # Taken from what observe RECORDED, not asserted by hand: producer and
  # consumer of this binding have to be pinned together or neither is pinned.
  "result_binding":observed_binding,
}
assert state["result_binding"]=="attempt"
m.verify_result_identity(state,result)
older=json.load(open(sys.argv[3]))
try:
    m.verify_result_identity(state,older)
except m.ValidationError as exc:
    assert "produced by attempt 1" in str(exc), str(exc)
else:
    raise AssertionError("attempt 1's result passed the identity gate for attempt 2")
undeclared=dict(result); undeclared.pop("attempt")
try:
    m.verify_result_identity(state,undeclared)
except m.ValidationError as exc:
    assert "does not declare the attempt" in str(exc), str(exc)
else:
    raise AssertionError("a result that declares no attempt was assumed to be the current one")
# ...but a LEGACY-bound observation holds that same result to the pre-stamp
# contract instead of refusing it, or the sealed cell can never collect.
legacy_state=dict(state); legacy_state["result_binding"]="legacy"
m.verify_result_identity(legacy_state,undeclared)
PY

  # 4. The REAL create_run_command: a guest edit must never brick a cell that is
  # already in flight, and every new attempt must re-arm its own settle window.
  python3 - "$HOST" "$tmp/home2" <<'PY' \
    || fail "create_run_command did not preserve resume across a guest edit and re-arm the window"
import hashlib,importlib.util,json,pathlib,sys,types
spec=importlib.util.spec_from_file_location("validation",sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home=pathlib.Path(sys.argv[2])
env={"home":home,"state_dir":home/"state"/"azure-validation","subscription":"sub",
     "storage":"stor","resource_group":"rg","owner":"owner","deployment_generation":"gen-1"}
m.ensure_dirs(env)

# The sealed guest is the one staged beside the request at submit. Its bytes
# deliberately DIFFER from the working tree, which is the shape this PR creates:
# the tree's guest is edited while cells sealed on the old one are still live.
sealed_text="#!/usr/bin/env bash\n# sealed guest for this cell\nexit 0\n"
sealed_digest="sha256:"+hashlib.sha256(sealed_text.encode()).hexdigest()
assert sealed_digest != m.sha256_file(m.GUEST), "fixture must differ from the working tree"
payload=env["state_dir"]/"payloads"/"azv-aaaaaaaaaaaa"
payload.mkdir(parents=True,exist_ok=True)
(payload/"guest.sh").write_text(sealed_text)

fence="sha256:"+"3"*64
def seed(**extra):
    state={
      "schema":m.SCHEMA,"cell":"azv-aaaaaaaaaaaa","phase":"needs-decision","attempt":2,
      "input_digest":"sha256:"+"4"*64,"request_digest":"sha256:"+"5"*64,
      "staging":{"container":"c","result_blob":"control/result.tar.gz"},
      "allocation":{"sku":"Standard_D8as_v6","sku_family":"standardDav6Family"},
      "request":{
        "protocol":{"guest_digest":sealed_digest},
        "deployment_generation":"gen-1","home_binding":"sha256:"+"2"*64,
        "task":"task","task_generation":"tg","validation_generation":"vg","fence":fence,
        "resource_class":"validation-standard",
        "repository":{"branch":"fm/fixture","head":"a"*40,"slug":"o/r"},
        "limits":{"behavior_shards":4,"wall_seconds":10800,"reserved_vcpus":24},
      },
      "resources":{"vm_id":"/subs/x/vm","vm_instance_id":"vm-i","worktree_disk_id":"/disk",
                   "identity_client_id":"cid"},
      "events":[],
    }
    state.update(extra)
    (env["state_dir"]/"azv-aaaaaaaaaaaa.json").write_text(json.dumps(state))
    return state

sent={}
def fake_az(env_,argv,**kw):
    for index,item in enumerate(argv):
        if item=="--body":
            sent["body"]=json.loads(pathlib.Path(argv[index+1][1:]).read_text())
    return {}
m.az_command=fake_az
m.read_github_token=lambda state:"gh-token"
m.read_resource=lambda env_,rid,kind:(True,{"id":rid,"tags":{"validation-cell":"azv-aaaaaaaaaaaa","fence":fence}})
m.immutable_identity=lambda resource,kind:{"id":resource.get("id","")}

# F1: the sealed cell resumes, and it runs the SEALED bytes, not the tree's.
state=seed(unbound_view_since="2020-01-01T00:00:00Z")
m.create_run_command(env,state,"respond",output_url="https://o",response="--action\napprove")
assert sent["body"]["properties"]["source"]["script"]==sealed_text, \
    "a resumed attempt did not run the guest its request was sealed with"

# F3: the settle window is re-armed per attempt. Without this the window is
# keyed per CELL: a stamp written on attempt 1 makes attempt 2 look ancient the
# moment it is observed, and a one-second-old attempt is retained.
saved=json.loads((env["state_dir"]/"azv-aaaaaaaaaaaa.json").read_text())
assert "unbound_view_since" not in saved, \
    "a new attempt inherited the previous attempt's settle stamp"

# N-2: the bytes VERIFIED must be the bytes RETURNED. Digesting one read and
# returning a second read is a TOCTOU: a writer landing between them passes the
# check while different content is handed back, and that content is uploaded as
# the Run Command script and executes as root on the cell. A race cannot be
# observed by waiting for it, so the second read is instrumented to differ - if
# the implementation reads twice, it returns the instrumented bytes.
saved_read_text=m.Path.read_text
m.Path.read_text=lambda self,*a,**k:"#!/bin/sh\nEVIL\n"
try:
    returned=m.sealed_guest_text(env,seed())
finally:
    m.Path.read_text=saved_read_text
assert returned==sealed_text, \
    "sealed_guest_text returned bytes it never verified: "+repr(returned)

# The recorded stamping flag comes from the bytes that are about to run.
assert saved["guest_stamps_attempt"] is False, saved.get("guest_stamps_attempt")
stamping=sealed_text+"printf 'FM_AZURE_VALIDATION_RESULT %s boot=%s outcome=%s attempt=%s\\n'\n"
assert m.guest_text_stamps_attempt(stamping) is True
assert m.guest_text_stamps_attempt(sealed_text) is False

# A symlinked payload copy is refused even when it points at correct bytes:
# the guest is uploaded and executed as root, so its supply path is held to the
# same standard as credential material.
real=payload/"real-guest.sh"; real.write_text(sealed_text)
(payload/"guest.sh").unlink()
(payload/"guest.sh").symlink_to(real)
state=seed()
try:
    m.create_run_command(env,state,"respond",output_url="https://o",response="x")
except m.ValidationError as exc:
    assert "sealed request digest" in str(exc), str(exc)
else:
    raise AssertionError("a symlinked guest supply path was accepted")
(payload/"guest.sh").unlink()

# The seal itself still binds: no source carrying the sealed digest refuses.
(payload/"guest.sh").write_text("#!/usr/bin/env bash\ntampered\n")
state=seed()
try:
    m.create_run_command(env,state,"respond",output_url="https://o",response="x")
except m.ValidationError as exc:
    assert "sealed request digest" in str(exc), str(exc)
else:
    raise AssertionError("a guest that matches no sealed digest was executed")
PY

  pass "an attempt's published result is bound to that attempt, a guest edit never bricks a sealed in-flight cell, an unbound control view never strands a running cell, and an unchanged republished result is refused as a non-answer"
}

static_contract
submit_contract
security_negative_contract
resource_identity_contract
storage_network_access_contract
controller_recovery_contract
replacement_runtime_hydration_contract
retail_price_transport_contract
admission_contract
identity_and_recovery_contract
trusted_manifest_verifier_contract
shard_runner_integration_contract
cleanup_recovery_contract
multi_lane_queue_contract
operator_documentation_contract
shard_receipt_demotion_contract
receipt_run_scope_contract
terminal_classifier_optional_matches_contract
receipt_chain_close_contract
gate_answer_binding_contract
