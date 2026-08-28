#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOST="$ROOT/bin/fm-azure-runner.py"
RUNNER="$ROOT/bin/fm-azure-runner.sh"
GUEST="$ROOT/bin/fm-azure-runner-guest.sh"
EXECUTOR="$ROOT/bin/fm-azure-runner-exec.py"
AGENT_FLEET_INSTALLER="$ROOT/bin/fm-azure-runner-agent-fleet-install.py"
TEMPLATE="$ROOT/docs/azure-runner/invocation.json"
SUB=11111111-1111-4111-8111-111111111111
TENANT=22222222-2222-4222-8222-222222222222
PE_GUID=33333333-3333-4333-8333-333333333333

make_repo() {
  local path=$1
  mkdir -p "$path/tools/agent-fleet" "$path/declared"
  git -C "$path" init -q -b topic
  git -C "$path" config user.name fixture
  git -C "$path" config user.email fixture@example.invalid
  cp "$ROOT/tools/agent-fleet/uv.lock" "$path/tools/agent-fleet/uv.lock"
  printf 'locked\n' >"$path/declared/dependency.lock"
  git -C "$path" remote add origin https://github.com/Ruby-Labs/cloud-host-owner.git
  git -C "$path" add . && git -C "$path" commit -qm initial
}

runner() {
  local home=$1; shift
  env FM_HOME="$home" FM_AZURE_TENANT_ID="$TENANT" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_NAMING_PREFIX=fmtest FM_AZURE_STORAGE_NAME=fmteststorage0001 FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_DEPLOYMENT_GENERATION=gen-one FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID="$PE_GUID" "$RUNNER" "$@"
}

python_311() {
  if python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 11))' 2>/dev/null; then
    command -v python3
  elif command -v uv >/dev/null 2>&1; then
    uv python find '>=3.11'
  else
    return 1
  fi
}

environment_mode_defaults() {
  local home
  home=$(mktemp -d)
  env FM_HOME="$home" FM_AZURE_TENANT_ID="$TENANT" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_NAMING_PREFIX=fmtest FM_AZURE_STORAGE_NAME=fmteststorage0001 FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_DEPLOYMENT_GENERATION=gen-one FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID="$PE_GUID" \
    python3 - "$HOST" <<'PY'
import importlib.util,os,sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.environment()["cost_admission_mode"]=="strict"
assert m.environment()["operator_data_plane_ip"]==""
assert m.environment()["capacity_wait_seconds"]==7200
assert m.environment()["capacity_poll_seconds"]==5
os.environ["FM_AZURE_OPERATOR_DATA_PLANE_IP"]="203.0.113.10/32"
assert m.environment()["operator_data_plane_ip"]=="203.0.113.10/32"
os.environ.pop("FM_AZURE_OPERATOR_DATA_PLANE_IP")
os.environ["FM_AZURE_RUNNER_MAX_CONCURRENCY"]="16"; assert m.environment()["max_concurrency"]==16
os.environ["FM_AZURE_RUNNER_COST_ADMISSION_MODE"]="commissioning-bounded"; os.environ["FM_AZURE_RUNNER_CELL_ORDINAL"]="16"
commissioning=m.environment(); assert commissioning["cell_ordinal"]==16 and m.runner_sku_for_environment(commissioning)=="Standard_D4ds_v6"
os.environ["FM_AZURE_RUNNER_SKU"]="Standard_D4as_v6"
try: m.runner_sku_for_environment(commissioning)
except m.RunnerError: pass
else: raise AssertionError("commissioning accepted an SKU override outside its exact cell")
os.environ.pop("FM_AZURE_RUNNER_SKU"); os.environ.pop("FM_AZURE_RUNNER_COST_ADMISSION_MODE")
os.environ.pop("FM_AZURE_RUNNER_CELL_ORDINAL")
os.environ["FM_AZURE_RUNNER_MAX_CONCURRENCY"]="17"
try: m.environment()
except m.RunnerError: pass
else: raise AssertionError("environment accepted concurrency above 16")
os.environ["FM_AZURE_RUNNER_MAX_CONCURRENCY"]="4"
for name,value in (
    ("FM_AZURE_RUNNER_CAPACITY_WAIT_SECONDS","86401"),
    ("FM_AZURE_RUNNER_CAPACITY_POLL_SECONDS","0"),
):
    os.environ[name]=value
    try: m.environment()
    except m.RunnerError: pass
    else: raise AssertionError("environment accepted invalid "+name)
    os.environ.pop(name)
PY
  rm -rf "$home"
  pass "normal environment defaults to strict without commissioning evidence or confirmation variables"
}

public_git_askpass_is_host_portable() {
  python3 - "$HOST" <<'PY' || fail "public Git askpass portability contract failed"
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("runner", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
observed = {}

def fake_run(command, **kwargs):
    observed["command"] = command
    observed["env"] = kwargs["env"]

m.run = fake_run
m.shutil.which = lambda name, path=None: (
    "/usr/bin/false" if (name, path) == ("false", "/usr/bin:/bin") else None
)
m.public_git(pathlib.Path("/proof"), "ls-remote", "https://github.com/example/repo.git")
assert observed["command"][0] == "git"
assert observed["env"]["GIT_ASKPASS"] == "/usr/bin/false"
assert observed["env"]["SSH_ASKPASS"] == "/usr/bin/false"

m.shutil.which = lambda _name, path=None: None
try:
    m.public_git(pathlib.Path("/proof"), "ls-remote", "https://github.com/example/repo.git")
except m.RunnerError as exc:
    assert "executable false command" in str(exc)
else:
    raise AssertionError("public Git proof accepted a host with no prompt refuser")
PY
  pass "public Git proof resolves a host-portable noninteractive askpass executable"
}

storage_network_access_contract() {
  python3 - "$HOST" <<'PY' || fail "runner storage network-access contract failed"
import importlib.util,inspect,sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
main={"properties":{"publicNetworkAccess":"Disabled","networkAcls":{"ipRules":[]}}}
control={"properties":{"publicNetworkAccess":"Disabled","networkAcls":{}}}
assert m.storage_network_access_is_exact(main,"")
assert m.storage_network_access_is_exact(control,"")
operator_ip="203.0.113.10/32"
for resource in (main,control):
 resource["properties"]["publicNetworkAccess"]="Enabled"
 resource["properties"]["networkAcls"]["ipRules"]=[{"value":operator_ip,"action":"Allow"}]
 assert m.storage_network_access_is_exact(resource,operator_ip)
 resource["properties"]["networkAcls"]["ipRules"].append({"value":"203.0.113.11/32","action":"Allow"})
 assert not m.storage_network_access_is_exact(resource,operator_ip)
source=inspect.getsource(m.foundation_gate)
assert 'storage_network_access_is_exact(storage, env["operator_data_plane_ip"])' in source
assert 'storage_network_access_is_exact(control, env["operator_data_plane_ip"])' in source
PY
  pass "runner gates main and control storage to disabled or one exact operator /32 rule"
}

static_private_controller_contract() {
  python3 - "$TEMPLATE" "$HOST" "$GUEST" <<'PY' || fail "private controller static contract failed"
import json, pathlib, sys
template=json.loads(pathlib.Path(sys.argv[1]).read_text()); host=pathlib.Path(sys.argv[2]).read_text(); guest=pathlib.Path(sys.argv[3]).read_text()
vm=next(r for r in template["resources"] if r["type"]=="Microsoft.Compute/virtualMachines")
nic=next(r for r in template["resources"] if r["type"]=="Microsoft.Network/networkInterfaces")
assert template["parameters"]["controllerIdentityId"]["type"] == "string"
assert set(template["parameters"]["vmSize"]["allowedValues"]) >= {"Standard_D4as_v7","Standard_D4as_v6","Standard_D4s_v6","Standard_D4ads_v7","Standard_D4ads_v6","Standard_E4as_v7","Standard_E4as_v6","Standard_D4ds_v6"}
assert vm["identity"]["type"] == "UserAssigned"
assert "controllerIdentityId" in json.dumps(vm["identity"])
assert "publicipaddress" not in json.dumps(nic).lower()
linux=vm["properties"]["osProfile"]["linuxConfiguration"]
assert linux["disablePasswordAuthentication"] is True
runner_key=linux["ssh"]["publicKeys"][0]
assert runner_key["path"]=="/home/fmbootstrap/.ssh/authorized_keys"
assert runner_key["keyData"].startswith("ssh-rsa ") and runner_key["keyData"].endswith(" firstmate-runner-blackhole")
assert "adminPassword" not in json.dumps(vm["properties"]["osProfile"])
assert "customdata" not in json.dumps(template).lower()
for value in ("PrivateNetwork=yes","RestrictAddressFamilies=AF_UNIX","IPAddressDeny=any","CapabilityBoundingSet=CAP_SETUID CAP_SETGID","AmbientCapabilities=","NoNewPrivileges=yes"):
    assert value in guest
for value in ("positional parameters are forbidden","REQUEST_B64=${request_b64:-}","EXECUTOR_B64=${executor_b64:-}","unset request_b64 vm_resource_id"):
    assert value in guest
assert 'install -m 0400 -o fmrunner -g fmrunner "$SNAPSHOT" /work/snapshot.bundle' in guest
assert "git -C /work/repo fetch /work/snapshot.bundle" in guest
assert 'fetch "$SNAPSHOT"' not in guest
assert "GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/work/repo" in guest
assert guest.index("runuser -u fmrunner -- git -C /work/repo init") < guest.index("GIT_CONFIG_KEY_0=safe.directory")
assert guest.index("cd /work/repo") < guest.index("uv venv --python")
executor_text=open("bin/fm-azure-runner-exec.py").read()
assert "output directory is not a fresh root-owned staging area" in executor_text
assert 'open(stdout_path, "xb"' in executor_text
assert "def enter_repo_as_runner():" in executor_text
assert "preexec_fn=enter_repo_as_runner," in executor_text
assert "cwd=str(repo)," not in executor_text
assert executor_text.index("drop_privileges(uid, gid,") < executor_text.index("os.chdir(str(repo))")
assert "x-ms-meta-result_digest" in guest and "x-ms-meta-result-digest" not in guest
assert 'SAFE_INVOCATION = re.compile(r"^azr-[a-z0-9]{12}(?:-a(?:[2-9]|[1-9][0-9]+))?$")' in host
assert '[ -s "$OUTPUT/result.json" ] || { echo "guest bootstrap: isolated executor failed"' in guest
assert "TimeoutStopSec=15" in guest
assert guest.index('[ "$NETWORK_BYTES" -eq 0 ] ||') < guest.index('if [ "$EXECUTOR_STATUS" -ne 0 ]; then')
assert "$#\" -eq 10" not in guest
run_at=guest.index("systemd-run --quiet")
input_token_at=guest.index("metadata/identity/oauth2/token")
output_token_at=guest.rindex("metadata/identity/oauth2/token")
assert input_token_at < guest.index('rm -f "$TOKEN_FILE"',input_token_at) < run_at < output_token_at
assert '/usr/bin/python3 "$EXECUTOR"' in guest
assert "https://files.pythonhosted.org/packages/*.whl" in guest
assert 'repository"].get("source_ancestors", [])' in guest
assert 'fetch_exact "$url"' in guest and '--location' not in guest[guest.index('while IFS=$\'\\t\' read -r url'):guest.index('done <"$BASE/wheels.tsv"')]
assert "protectedParameters" not in host
assert "generate-sas" not in host
assert "controller_identity_client_id" in host
assert "runner-cost-reservation" not in host
assert "fm.azure-spend-ledger/v1" in host
assert "def spend_ledger_reserve" in host and "def spend_ledger_mark_cleaned" in host
assert "def admission_lock" in host and "ManagementAdmissionLease" not in host
assert 'command_env.setdefault("FM_HOME", str(ROOT))' in host
assert 'command_env["FM_HOME"] = str(ROOT)' not in host
assert 'str(Path(command_env["FM_HOME"]) / "state" / "azure-workers")' in host
assert "cleanup-verified-at" not in host
assert 'binding_keys = ("remote", "source_ref", "source_head", "source_ancestors")' in host
assert '"default_head": default_head,' in host
schedule=next(r for r in template["resources"] if r["type"]=="Microsoft.DevTestLab/schedules")
assert schedule["name"]=="[format('shutdown-computevm-{0}', parameters('vmName'))]"
safety=next(r for r in template["resources"] if r["type"]=="Microsoft.Compute/virtualMachines/runCommands")
safety_script=safety["properties"]["source"]["script"]
assert "uriComponentToString('%0A')" in safety_script and "\\n" not in safety_script
assert "residual_ids - expected_ids" in host
assert 'parent_managed = bool(state.get("request", {}).get("capacity_parent"))' in host
assert host.count("itemized_cost_bound(rate, MAX_BILLABLE_LIFETIME_HOURS, limits, parent_managed=parent_managed)") >= 1
assert host.count('identity["etag"] = identity["etag"] or identity["unique_id"]') == 1
assert 'label not in ("run-command", "ttl-schedule") and not identity["etag"]' in host
assert 'if resource.get("etag"):' in host
assert "stable_only=True," in host
assert "require_vm_relation=False," in host
assert '"nic": "resource_guid", "disk": "unique_id",' in host
assert 'if kind == "run-command":' in host
assert "elif stable_only:" in host
assert host.index('if kind == "run-command":') < host.index("elif stable_only:")
assert "still exists after conditional delete" in host
assert host.index("deadline = time.monotonic() + 90") < host.index("still exists after conditional delete")
assert 'if phase in ("result-collected", "cleanup-retained", "compute-removed"):' in host
assert '("result-collected", "cleanup-retained", "compute-removed", "complete")' in host
assert "except FileNotFoundError:" in host[host.index("payload_dir = Path"):host.index("payload_dir = Path")+700]
provider_text=open("bin/fm-azure-worker-provider.py").read()
assert 'SAFE_INVOCATION = re.compile(r"^azr-[0-9a-f]{12}(?:-a(?:[2-9]|[1-9][0-9]+))?$")' in provider_text
assert '"ttl_schedule_name": "shutdown-computevm-{}".format(vm_name)' in host
assert "schedules/shutdown-computevm-{}" in host
assert "DEPLOYMENT_TIMEOUT_SECONDS = 900" in host
assert "LEASE_ACQUIRE_ATTEMPTS" not in host
assert "timeout_seconds=DEPLOYMENT_TIMEOUT_SECONDS" in host
assert "AZURE_SCHEDULE_MINIMUM_LEAD_SECONDS + DEPLOYMENT_TIMEOUT_SECONDS" in host
start=host.index("def dispatch_prepared")
assert host.index("shared_capacity_reserve(env, state, cost)", start) < host.index("create_vm(env, state)", start)
# Per-invocation staging and read-only proofs run before the local
# admission lock, and compute creation runs after it: the ledger entry is
# the durable spend claim, so concurrent transports no longer serialize
# their snapshot uploads and multi-minute VM creations behind one holder.
assert host.index("stage_private_snapshot(env, state)", start) < host.index("with admission_lock(env):", start)
assert host.index("with admission_lock(env):", start) < host.index("create_vm(env, state)", start)
assert host.index("spend_ledger_reserve(env, state, cost[\"max_increment\"])", start) < host.index("create_vm(env, state)", start)
cleanup=host[host.index("def cleanup(env, state):"):start]
assert cleanup.index('"run-command-execute"') < cleanup.index('if "vm" in by_key') < cleanup.index('"ttl-schedule" in by_key') < cleanup.index("shared_capacity_release(env, state)")
PY
  pass "private controller has exact UAMI, no public ingress/SAS, isolated command, trusted post-command uploader, and safe cleanup order"
}

prepare_contract() {
  python3 - "$HOST" <<'PY'
import importlib.util, pathlib, types, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
remote="https://github.com/Ruby-Labs/cloud-host-owner.git"; head="a"*40; candidate="b"*40; tree="c"*40; ancestor="d"*40
class Result:
    def __init__(self,stdout="",returncode=0): self.stdout=stdout; self.returncode=returncode
calls=[]
pr_ref="refs/pull/130/head"
def public_git(_repo,*args,check=True):
    calls.append(args)
    if args[:2]==("init","--bare"): return Result()
    if args[:2]==("ls-remote","--symref"): return Result("ref: refs/heads/main\tHEAD\n{}\tHEAD\n".format(head))
    if args[:1]==("ls-remote",):
        ref=args[-1]
        if ref=="refs/heads/main": return Result("{}\t{}\n".format(head,ref))
        if ref in ("refs/heads/fm/feature",pr_ref): return Result("{}\t{}\n".format(candidate,ref))
        return Result("{}\t{}\n".format(head,ref))
    if args[:1]==("fetch",): return Result()
    if args[:2]==("rev-parse","--verify"):
        return Result((candidate if args[-1].endswith("public-source") else head)+"\n")
    if args[:2]==("merge-base","--is-ancestor"):
        return Result(returncode=0 if args[2:]==(ancestor,candidate) else 1)
    if args[:2]==("cat-file","-t"):
        return Result("commit\n" if args[2] in {candidate,ancestor} else "tree\n")
    if args[:1]==("rev-parse",) and args[1].endswith("^{tree}"): return Result(tree+"\n")
    raise AssertionError(args)
m.public_git=public_git
try: m.public_origin_proof(pathlib.Path("/repo"),remote,candidate)
except m.RunnerError as exc: assert "not reachable" in str(exc)
else: raise AssertionError("unmerged branch accepted without an exact source ref")
proof=m.public_origin_proof(pathlib.Path("/repo"),remote,candidate,source_ref="refs/heads/fm/feature")
assert proof["source_ref"]=="refs/heads/fm/feature" and proof["source_head"]==candidate and proof["tree"]==tree
# An advertised PR-head ref admits the exact candidate with bound ancestors.
pr_proof=m.public_origin_proof(pathlib.Path("/repo"),remote,candidate,source_ref=pr_ref,source_ancestors=(ancestor,))
assert pr_proof["source_ref"]==pr_ref and pr_proof["source_head"]==candidate
assert pr_proof["source_ancestors"]==[ancestor] and pr_proof["tree"]==tree
# A mutable pull merge ref and unsafe shapes refuse before any network use.
for bad in ("refs/pull/130/merge","refs/heads/a..b","refs/heads/x.lock"):
    try: m.validate_public_source_ref(bad)
    except m.RunnerError: pass
    else: raise AssertionError("unsafe source ref accepted: "+bad)
try: m.public_origin_proof(pathlib.Path("/repo"),remote,candidate,source_ref=pr_ref,source_ancestors=("e"*40,))
except m.RunnerError as exc: assert "fetched commit" in str(exc)
else: raise AssertionError("unfetched source ancestor accepted")
def local_git(_repo,*args,check=True):
    if args[:2]==("cat-file","-t"): return Result(("commit" if args[-1]==candidate else "tree")+"\n")
    if args[:1]==("rev-parse",): return Result(tree+"\n")
    raise AssertionError(args)
m.git=local_git
private=m.public_origin_proof(pathlib.Path("/repo"),remote,candidate,source_ref="refs/heads/fm/unpushed",private_source=True)
assert private["source_ref"]=="refs/heads/fm/unpushed" and private["source_head"]==candidate and private["tree"]==tree
assert ("fetch","--no-tags","--force",remote,"+refs/heads/main:refs/fm-azure-runner/public-main") in calls
assert ("fetch","--no-tags","--force",remote,"+refs/heads/fm/feature:refs/fm-azure-runner/public-source") in calls
assert ("fetch","--no-tags","--force",remote,"+{}:refs/fm-azure-runner/public-source".format(pr_ref)) in calls
# A stale tracking ref is irrelevant; proof uses fresh advertisement/fetch.
assert not any("origin/main" in part for call in calls for part in call)
PY
  pass "prepare binds fresh public main and admits only an exact advertised branch or PR-head ref with bound ancestors"
}

private_snapshot_prepare_contract() {
  local tmp repo bundle
  fm_test_tmproot_into tmp fm-azure-private-snapshot
  repo="$tmp/repo"
  make_repo "$repo"
  bundle="$tmp/snapshot.bundle"
  git -C "$repo" bundle create "$bundle" refs/heads/topic
  python3 - "$HOST" "$repo" "$bundle" "$tmp/state" <<'PY' || fail "private parent snapshot prepare failed"
import argparse,importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
repo=pathlib.Path(sys.argv[2]); bundle=pathlib.Path(sys.argv[3]); state_dir=pathlib.Path(sys.argv[4])
env={"state_dir":state_dir,"home_binding":"sha256:"+"a"*64,"deployment_generation":"gen","prefix":"fmtest","subscription":"11111111-1111-4111-8111-111111111111","resource_group":"rg","owner":"owner","cost_admission_mode":m.STRICT_COST_ADMISSION_MODE,"cell_ordinal":None}
m.ensure_state_dirs(env)
head=m.git(repo,"rev-parse","HEAD").stdout.strip(); tree=m.git(repo,"rev-parse","HEAD^{tree}").stdout.strip()
m.public_origin_proof=lambda *_a,**k:{"remote":"https://github.com/Ruby-Labs/cloud-host-owner.git","default_ref":"refs/heads/main","default_head":"d"*40,"source_ref":k.get("source_ref") or "refs/heads/main","source_head":head,"tree":tree}
args=argparse.Namespace(repo=str(repo),task="azv-aaaaaaaaaaaa-s1",generation="round-aaaaaaaaaaaa",resource_class="behavior-heavy",source_ref="refs/heads/topic",public_ref=None,public_ancestor=[],private_snapshot_bundle=str(bundle),private_snapshot_from_head=False,capacity_parent="azv-aaaaaaaaaaaa",capacity_reservation_vcpus=40,wall_seconds=None,dependency=[],artifact=[],command=["true"],invocation="azr-aaaaaaaaaaaa")
state=m.prepare(env,args)
r=state["request"]["repository"]
assert r["source_mode"]=="private-parent-bundle" and r["source_head"]==head and r["tree"]==tree
assert r["snapshot_bytes"]==bundle.stat().st_size and r["input_blob"].endswith("/snapshot.bundle")
assert pathlib.Path(state["input_path"]).parent.joinpath("snapshot.bundle").read_bytes()==bundle.read_bytes()
# A bundle with any source ref other than the exact declared one refuses.
bad=repo.parent/"bad.bundle"; m.run(["git","-C",str(repo),"branch","extra","HEAD"]); m.run(["git","-C",str(repo),"bundle","create",str(bad),"refs/heads/topic","refs/heads/extra"])
args.invocation="azr-bbbbbbbbbbbb"; args.private_snapshot_bundle=str(bad)
try: m.prepare(env,args)
except m.RunnerError as exc: assert "only the exact source head" in str(exc)
else: raise AssertionError("multi-ref private snapshot accepted")
# Crosscheck evidence uses the same private transport without a validation
# parent. Its authenticated exact PR checkout is the authority, so preparation
# must not try to reach a private GitHub remote without credentials.
m.public_origin_proof=lambda *_a,**_k: (_ for _ in ()).throw(AssertionError("private Crosscheck bundle attempted public Git proof"))
args.invocation="azr-cccccccccccc"
args.private_snapshot_bundle=str(bundle)
args.capacity_parent=None
args.capacity_reservation_vcpus=None
private=m.prepare(env,args)
private_repo=private["request"]["repository"]
assert private_repo["source_mode"]=="private-exact-bundle"
assert private_repo["source_ref"]=="refs/heads/topic" and private_repo["source_head"]==head
assert private_repo["default_ref"] is None and private_repo["default_head"] is None
m.reprove_public_request(private)
# An arbitrary private repository need not carry Firstmate's Agent Fleet lock.
# The evidence class records an empty closure and keeps every other class on
# the existing locked path.
plain=repo.parent/"plain"; plain.mkdir()
m.run(["git","-C",str(plain),"init","-q","-b","main"])
m.run(["git","-C",str(plain),"config","user.name","fixture"])
m.run(["git","-C",str(plain),"config","user.email","fixture@example.invalid"])
(plain/"value.txt").write_text("value\n")
m.run(["git","-C",str(plain),"add","value.txt"])
m.run(["git","-C",str(plain),"commit","-qm","fixture"])
m.run(["git","-C",str(plain),"remote","add","origin","https://github.com/example/private.git"])
plain_head=m.git(plain,"rev-parse","HEAD").stdout.strip()
plain_bundle=plain.parent/"plain.bundle"
m.run(["git","-C",str(plain),"bundle","create",str(plain_bundle),"HEAD"])
args.repo=str(plain)
args.source_ref="refs/pull/7/head"
args.public_ancestor=[]
args.resource_class="crosscheck-tool"
args.command=["true"]
args.invocation="azr-dddddddddddd"
args.private_snapshot_bundle=str(plain_bundle)
plain_state=m.prepare(env,args)
assert plain_state["request"]["repository"]["source_head"]==plain_head
assert plain_state["request"]["protocol"]["agent_fleet_python"]=={"lock_digest":None,"wheels":[]}
# The direct no-mistakes route seals a detached, unpushed HEAD without a
# validation parent. Its deterministic private ref is identity, not a guessed
# task branch, and the bundle must carry complete ancestry into an empty repo.
args.repo=str(repo); args.resource_class="behavior-heavy"; args.command=["true"]
args.private_snapshot_bundle=None; args.private_snapshot_from_head=True
args.capacity_parent=None; args.capacity_reservation_vcpus=None
args.source_ref="refs/heads/fm-no-mistakes/01BX5ZZKBKACTAV9WEVGEMMVRZ"
args.invocation="azr-eeeeeeeeeeee"; args.task="nm-01BX5ZZKBKACTAV9WEVGEMMVRZ"
(repo/"second").write_text("second\n"); m.run(["git","-C",str(repo),"add","second"]); m.run(["git","-C",str(repo),"commit","-qm","second"])
head=m.git(repo,"rev-parse","HEAD").stdout.strip(); parent=m.git(repo,"rev-parse","HEAD^1").stdout.strip()
proof_calls=[]
def direct_origin_proof(*_a,**k):
    proof_calls.append(k)
    return {"remote":"https://github.com/Ruby-Labs/cloud-host-owner.git","default_ref":"refs/heads/main","default_head":"d"*40,"source_ref":k.get("source_ref"),"source_head":head,"tree":m.git(repo,"rev-parse","HEAD^{tree}").stdout.strip()}
m.public_origin_proof=direct_origin_proof
m.run(["git","-C",str(repo),"checkout","-q","--detach",head])
direct=m.prepare(env,args); direct_repo=direct["request"]["repository"]
assert len(proof_calls)==1 and proof_calls[0].get("private_source") is True, proof_calls
assert direct_repo["source_mode"]=="private-direct-bundle"
assert direct_repo["source_ref"]==args.source_ref and direct_repo["source_head"]==head
assert direct["request"]["capacity_parent"] is None
assert direct["request"]["capacity_fence"] is None
sealed=pathlib.Path(direct["input_path"]).parent/"snapshot.bundle"
assert m.git(repo,"bundle","list-heads",str(sealed)).stdout.splitlines()==[head+" "+args.source_ref]
verify=repo.parent/"verify.git"; m.run(["git","init","--bare",str(verify)]); m.run(["git","-C",str(verify),"bundle","verify",str(sealed)]); m.run(["git","-C",str(verify),"fetch",str(sealed),args.source_ref])
assert m.git(verify,"rev-parse","FETCH_HEAD").stdout.strip()==head
assert m.git(verify,"rev-parse","FETCH_HEAD^1").stdout.strip()==parent
assert m.git(verify,"rev-parse","--is-shallow-repository").stdout.strip()=="false"
PY
  pass "private prepare binds parent, exact-checkout, and detached direct source graphs"
}

private_snapshot_ancestor_verification() {
  local tmp repo clone request ancestor head marker helper
  fm_test_tmproot_into tmp fm-azure-private-ancestor
  repo="$tmp/repo"
  make_repo "$repo"
  printf 'child\n' >"$repo/declared/child.txt"
  git -C "$repo" add declared/child.txt
  git -C "$repo" commit -qm child
  ancestor=$(git -C "$repo" rev-parse HEAD^)
  head=$(git -C "$repo" rev-parse HEAD)
  clone="$tmp/clone"
  git clone -q --no-local "$repo" "$clone"
  marker="$tmp/network-used"
  helper="$tmp/remote-helper"
  printf '#!/usr/bin/env bash\nprintf used >"%s"\nexit 91\n' "$marker" >"$helper"
  chmod +x "$helper"
  git -C "$clone" remote set-url origin "ext::$helper"
  request="$tmp/request.json"
  python3 - "$request" "$ancestor" "$head" <<'PY'
import json,sys
path,ancestor,head=sys.argv[1:]
with open(path,"w",encoding="utf-8") as handle:
    json.dump({"repository":{"source_mode":"private-exact-bundle","commit":head,"source_ancestors":[ancestor]}},handle)
PY
  for mode in private-parent-bundle private-exact-bundle private-direct-bundle; do
    python3 - "$request" "$mode" <<'PY'
import json,sys
path,mode=sys.argv[1:]
request=json.load(open(path,encoding="utf-8"))
request["repository"]["source_mode"]=mode
with open(path,"w",encoding="utf-8") as handle: json.dump(request,handle)
PY
    python3 "$EXECUTOR" --verify-private-source-ancestors "$request" "$clone" || \
      fail "$mode ancestor verification rejected bundled ancestry"
  done
  [ ! -e "$marker" ] || fail "private snapshot ancestor verification contacted origin"
  python3 - "$request" <<'PY'
import json,subprocess,sys
path=sys.argv[1]
request=json.load(open(path,encoding="utf-8"))
request["repository"]["source_ancestors"]=[subprocess.run(["git","-C",path.rsplit("/",1)[0]+"/repo","rev-parse","HEAD"],check=True,text=True,stdout=subprocess.PIPE).stdout.strip()]
request["repository"]["commit"]=subprocess.run(["git","-C",path.rsplit("/",1)[0]+"/repo","rev-parse","HEAD^"],check=True,text=True,stdout=subprocess.PIPE).stdout.strip()
with open(path,"w",encoding="utf-8") as handle: json.dump(request,handle)
PY
  if python3 "$EXECUTOR" --verify-private-source-ancestors "$request" "$clone" >/dev/null 2>&1; then
    fail "private snapshot ancestor verification accepted a descendant"
  fi
  pass "all private bundle modes verify ancestors locally without contacting origin"
}

agent_fleet_offline_install_contract() {
  local tmp project python out rc
  fm_test_tmproot_into tmp fm-azure-agent-fleet-install
  project="$tmp/project"
  mkdir -p "$project/src"
  cp "$ROOT/tools/agent-fleet/pyproject.toml" "$ROOT/tools/agent-fleet/uv.lock" "$project/"
  cp -R "$ROOT/tools/agent-fleet/src/agent_fleet" "$project/src/"
  python=$(python_311) \
    || fail "could not resolve Python 3.11+ for the hermetic Agent Fleet installer"
  "$python" -m venv --without-pip "$project/.venv" \
    || fail "could not create the hermetic Agent Fleet installer venv"
  "$project/.venv/bin/python" "$AGENT_FLEET_INSTALLER" "$project" "$project/.venv" >/dev/null \
    || fail "the locked Agent Fleet project could not be installed offline"
  "$project/.venv/bin/agent-fleet" --help >/dev/null \
    || fail "the offline Agent Fleet console entrypoint is not runnable"
  "$project/.venv/bin/python" - "$project/.venv/bin/agent-fleet" <<'PY' \
    || fail "the offline Agent Fleet project is not release-local"
import pathlib, stat, sys
from agent_fleet.providers import agent_fleet_entrypoint_path
expected = pathlib.Path(sys.argv[1]).absolute()
actual = agent_fleet_entrypoint_path()
assert actual == expected, (actual, expected)
metadata = expected.lstat()
assert stat.S_ISREG(metadata.st_mode) and metadata.st_mode & 0o111
PY
  sed 's/^dependencies = \[\]$/dependencies = ["requests"]/' "$project/pyproject.toml" \
    >"$project/pyproject.changed"
  mv "$project/pyproject.changed" "$project/pyproject.toml"
  "$python" -m venv --without-pip "$project/changed-venv" >/dev/null
  rc=0
  out=$("$project/changed-venv/bin/python" "$AGENT_FLEET_INSTALLER" \
    "$project" "$project/changed-venv" 2>&1) || rc=$?
  [ "$rc" -eq 125 ] \
    || fail "the offline Agent Fleet installer accepted an unsealed runtime dependency"
  assert_contains "$out" "gained runtime dependencies" \
    "the offline Agent Fleet refusal did not name its closure change"
  cp "$ROOT/tools/agent-fleet/pyproject.toml" "$project/pyproject.toml"
  mkdir -p "$tmp/linked-source"
  cp -R "$ROOT/tools/agent-fleet/src/agent_fleet" "$tmp/linked-source/"
  rm -rf "$project/src"
  ln -s "$tmp/linked-source" "$project/src"
  "$python" -m venv --without-pip "$project/linked-venv" >/dev/null
  rc=0
  out=$("$project/linked-venv/bin/python" "$AGENT_FLEET_INSTALLER" \
    "$project" "$project/linked-venv" 2>&1) || rc=$?
  [ "$rc" -eq 125 ] \
    || fail "the offline Agent Fleet installer followed linked source ancestry"
  assert_contains "$out" "real directory ancestry" \
    "the linked Agent Fleet source refusal did not name its ancestry defect"
  pass "the locked Agent Fleet project and console entrypoint are installed into the offline venv before execution"
}

executor_credential_adversary() {
  local tmp repo request output uid gid
  fm_test_tmproot_into tmp fm-azure-exec-adversary
  repo="$tmp/repo"; make_repo "$repo"; request="$tmp/request.json"; output="$tmp/output"; uid=$(id -u); gid=$(id -g)
  python3 - "$request" <<'PY'
import hashlib,json,sys
command={"argv":["python3","-c","import os,pathlib; forbidden=[k for k in os.environ if any(x in k for x in ('TOKEN','SAS','SECRET','CREDENTIAL','CLIENT_ID','SUBSCRIPTION','TENANT'))]; targets=[]\nfor p in pathlib.Path('/dev/fd').iterdir():\n try: targets.append(os.readlink(p))\n except OSError: pass\nraise SystemExit(0 if not forbidden and not any(any(x in t.lower() for x in ('token','sas','credential','secret')) for t in targets) else 91)"]}
r={"invocation":"azr-aaaaaaaaaaaa","attempt":1,"fence":"sha256:"+"1"*64,"repository":{"snapshot_digest":"sha256:"+"2"*64,"commit":"a"*40,"tree":"b"*40},"command":command,"limits":{"cpu_cores":1,"memory_bytes":2**30,"pid_max":64,"disk_bytes":2**30,"log_bytes":1024,"artifact_bytes":0,"network_bytes":0,"wall_seconds":10}}
canon=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode(); r["command_digest"]="sha256:"+hashlib.sha256(canon(command)).hexdigest(); r["request_digest"]="sha256:"+hashlib.sha256(canon(r)).hexdigest(); open(sys.argv[1],"wb").write(canon(r)+b"\n")
PY
  printf '44444444-4444-4444-8444-444444444444\n' >"$tmp/boot"
  env AZURE_CLIENT_SECRET=must-not-pass FM_AZURE_RUNNER_TEST_NO_DROP=1 FM_AZURE_RUNNER_BOOT_ID_PATH="$tmp/boot" \
    /usr/bin/python3 "$EXECUTOR" "$request" "$repo" "$output" "$uid" "$gid" /vm/id vm-instance >/dev/null || \
    fail "credential adversary escaped sanitized executor"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["exit_code"])' "$output/result.json")" = 0 ] || fail "credential/fd adversary observed inherited authority"
  pass "repository command receives no Azure/token/SAS/secret environment or inherited credential descriptor"
}

linux_systemd_drop_integration() {
  [ "$(uname -s)" = Linux ] || { pass "Linux systemd uid/capability integration is CI-owned"; return; }
  fm_require_host_capability passwordless-root-escalation "linux_systemd_drop_integration" || return 0
  # Still a REQUIRED condition on every Linux host that has not declared the
  # absence by name: an unprivileged CI runner must go red here, not skip.
  if ! command -v systemd-run >/dev/null || ! sudo -n true >/dev/null 2>&1; then
    fail "Linux systemd integration requires passwordless sudo"
  fi
  local tmp repo controller_base work_base request output uid gid tracked_digest staged_digest systemd_rc
  fm_test_tmproot_into tmp fm-azure-systemd-drop
  repo="$tmp/repo"; make_repo "$repo"
  controller_base=$(sudo -n mktemp -d /var/lib/fm-azure-runner-test.XXXXXXXX)
  work_base=$(sudo -n mktemp -d /var/lib/fm-azure-runner-work.XXXXXXXX)
  request="$controller_base/request.json"; output="$controller_base/output"
  uid=$(id -u nobody); gid=$(id -g nobody)
  sudo -n install -d -m 0700 -o root -g root "$controller_base"
  sudo -n chmod 0755 "$work_base"
  sudo -n install -d -m 0755 -o "$uid" -g "$gid" "$work_base/repo"
  sudo -n cp -R "$repo/." "$work_base/repo/"
  sudo -n chown -R "$uid:$gid" "$work_base/repo"
  sudo -n install -m 0600 -o root -g root "$EXECUTOR" "$controller_base/runner-exec.py"
  tracked_digest=$(sha256sum "$EXECUTOR" | awk '{print $1}')
  staged_digest=$(sudo -n sha256sum "$controller_base/runner-exec.py" | awk '{print $1}')
  [ "$tracked_digest" = "$staged_digest" ] || fail "root-staged executor digest differs from tracked executor"
  python3 - "$tmp/request.json" "$uid" "$gid" <<'PY'
import hashlib,json,sys
uid=int(sys.argv[2]); gid=int(sys.argv[3])
code="""import os,pathlib
s={}
for line in pathlib.Path('/proc/self/status').read_text().splitlines():
    if ':' in line:
        k,v=line.split(':',1); s[k]=v.strip()
assert os.getuid()==%d and os.getgid()==%d and os.getgroups()==[]
assert all(int(s[k],16)==0 for k in ('CapEff','CapPrm','CapAmb'))
assert s['NoNewPrivs']=='1'
"""%(uid,gid)
command={"argv":["python3","-c",code]}
r={"invocation":"azr-aaaaaaaaaaaa","attempt":1,"fence":"sha256:"+"1"*64,"repository":{"snapshot_digest":"sha256:"+"2"*64,"commit":"a"*40,"tree":"b"*40},"command":command,"limits":{"cpu_cores":1,"memory_bytes":2**30,"pid_max":64,"disk_bytes":2**30,"log_bytes":1024,"artifact_bytes":0,"network_bytes":0,"wall_seconds":10}}
canon=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode(); r["command_digest"]="sha256:"+hashlib.sha256(canon(command)).hexdigest(); r["request_digest"]="sha256:"+hashlib.sha256(canon(r)).hexdigest(); open(sys.argv[1],"wb").write(canon(r)+b"\n")
PY
  printf '44444444-4444-4444-8444-444444444444\n' >"$tmp/boot"
  sudo -n install -m 0600 -o root -g root "$tmp/request.json" "$request"
  sudo -n install -m 0600 -o root -g root "$tmp/boot" "$controller_base/boot"
  chmod 0755 "$tmp" "$repo"
  # The broker intentionally lacks CAP_DAC_OVERRIDE. Pinned Python reads the
  # staged executor and request as root inside the root-traversable BASE; only
  # the child needs access to the repository and its already-open log pipes.
  systemd_rc=0
  sudo -n systemd-run --quiet --wait --collect --pipe \
    --property=NoNewPrivileges=yes --property=PrivateNetwork=yes --property=RestrictAddressFamilies=AF_UNIX \
    --property=IPAddressDeny=any --property='CapabilityBoundingSet=CAP_SETUID CAP_SETGID' \
    --property=AmbientCapabilities= --property=RestrictSUIDSGID=yes \
    env FM_AZURE_RUNNER_BOOT_ID_PATH="$controller_base/boot" /usr/bin/python3 "$controller_base/runner-exec.py" \
    "$request" "$work_base/repo" "$output" "$uid" "$gid" /vm/id vm-instance >/dev/null || systemd_rc=$?
  [ "$systemd_rc" -eq 0 ] && \
    [ "$(sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["exit_code"])' "$output/result.json")" = 0 ] || \
    systemd_rc=1
  sudo -n find "$controller_base" -xdev -mindepth 1 -delete
  sudo -n rmdir "$controller_base"
  sudo -n find "$work_base" -xdev -mindepth 1 -delete
  sudo -n rmdir "$work_base"
  [ "$systemd_rc" -eq 0 ] || fail "actual Linux/systemd broker could not run the secured child"
  pass "actual Linux/systemd broker drops uid/gid/groups and repository child has empty capabilities/no-new-privileges/networkless"
}

spend_ledger_unit() {
  python3 - "$HOST" <<'PY2' || fail "local spend ledger unit failed"
import importlib.util, json, pathlib, tempfile, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"state_dir":pathlib.Path(tempfile.mkdtemp())}
state_a={"invocation":"azr-aaaaaaaaaaaa"}
state_b={"invocation":"azr-bbbbbbbbbbbb"}
entry=m.spend_ledger_reserve(env,state_a,25.5)
assert entry["amount_usd"]==25.5 and entry["cleaned_at"] is None and entry["reserved_at"]
# Idempotent: a resumed dispatch never double-counts itself.
again=m.spend_ledger_reserve(env,state_a,99.0)
assert again["amount_usd"]==25.5
assert m.spend_ledger_outstanding(env)==25.5
m.spend_ledger_reserve(env,state_b,10.0)
assert m.spend_ledger_outstanding(env)==35.5
# Outstanding excludes the requesting invocation so re-admission fits.
assert m.spend_ledger_outstanding(env,exclude_invocation="azr-aaaaaaaaaaaa")==10.0
assert m.spend_ledger_entry(env,"azr-aaaaaaaaaaaa")["invocation"]=="azr-aaaaaaaaaaaa"
# Cleanup stamps cleaned_at; outstanding drops; stamping twice is harmless.
m.spend_ledger_mark_cleaned(env,state_a)
m.spend_ledger_mark_cleaned(env,state_a)
assert m.spend_ledger_outstanding(env)==10.0
assert m.spend_ledger_entry(env,"azr-aaaaaaaaaaaa") is None
ledger=json.loads(m.spend_ledger_path(env).read_text())
assert ledger["schema"]=="fm.azure-spend-ledger/v1"
assert [e["invocation"] for e in ledger["entries"]]==["azr-aaaaaaaaaaaa","azr-bbbbbbbbbbbb"]
cleaned=[e for e in ledger["entries"] if e["invocation"]=="azr-aaaaaaaaaaaa"][0]
assert cleaned["cleaned_at"] is not None
# A corrupt ledger fails closed instead of admitting unbounded spend.
m.spend_ledger_path(env).write_text('{"schema":"wrong"}')
try: m.spend_ledger_outstanding(env)
except m.RunnerError: pass
else: raise AssertionError("corrupt ledger was accepted")
PY2
  pass "local spend ledger reserves idempotently, excludes self, survives double cleanup, and fails closed on corruption"
}


foundation_rbac_read_unit() {
  python3 - "$HOST" <<'PY2' || fail "foundation RBAC read unit failed"
import importlib.util, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","prefix":"prefix"}
seen=[]
def az(_env,args,**kwargs):
    seen.append(args)
    return ([{"scope":"/subscriptions/sub","roleDefinitionId":"/role/owner","principalId":"group"}],0,"")
m.az_command=az
assignments=m.effective_role_assignments(env,"principal")
assert len(assignments)==1
assert all("--include-inherited" in args and "--include-groups" in args and "--all" in args for args in seen)
m.az_command=lambda *_a,**_k: ({"not":"a list"},0,"")
try: m.effective_role_assignments(env,"principal")
except m.RunnerError: pass
else: raise AssertionError("unreadable effective RBAC accepted")
PY2
  pass "foundation RBAC expansion stays effective-scope-complete and fails closed on unreadable output"
}


validation_parent_capacity_contract() {
  python3 - "$HOST" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","deployment_generation":"gen","owner":"owner"}
state={"request":{"capacity_parent":"azv-aaaaaaaaaaaa","capacity_reservation_vcpus":40,"home_binding":"sha256:"+"a"*64}}
parent={"powerState":"VM running","tags":{"workload":"firstmate","firstmate-role":"validation-cell","lifecycle":"elastic-scale-to-zero","deployment-generation":"gen","cleanup-owner":"owner","home-binding":"sha256:"+"a"*64,"validation-cell":"azv-aaaaaaaaaaaa","reserved-vcpus":"40"}}
children=[{"powerState":"VM running","tags":{"firstmate-role":"validation-shard","capacity-parent":"azv-aaaaaaaaaaaa"}} for _ in range(7)]
m.az_command=lambda *_a,**_k: ([parent]+children,0,"")
m.validation_capacity_parent_gate(env,state)
children.append({"powerState":"VM running","tags":{"firstmate-role":"validation-shard","capacity-parent":"azv-aaaaaaaaaaaa"}})
try: m.validation_capacity_parent_gate(env,state)
except m.RunnerError as exc: assert "no reserved processor slot" in str(exc)
else: raise AssertionError("ninth child exceeded the exact 40-vCPU parent shape")
base=m.itemized_cost_bound(.25,24,m.RESOURCE_CLASSES["behavior-heavy"])
child=m.itemized_cost_bound(.25,24,m.RESOURCE_CLASSES["behavior-heavy"],parent_managed=True)
assert base["categories"]["foundation_shared_meter_reserve"]==210.0
assert child["categories"]["foundation_shared_meter_reserve"]==0.0
assert base["total"]-child["total"]==210.0
PY
  pass "validation parent proof bounds child count and removes only the already-reserved shared meter"
}

cost_retry_unit() {
  python3 - "$HOST" <<'PY'
import datetime as dt, email.message, importlib.util, io, json, pathlib, tempfile, types, urllib.error, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","state_dir":pathlib.Path(tempfile.mkdtemp()),"azure_operation_count":0,"home_binding":"sha256:"+"a"*64,"deployment_generation":"gen"}
m.record_azure_operation=lambda *_:None; m.run=lambda *a,**k:types.SimpleNamespace(stdout="token\n")
headers=email.message.Message(); headers["x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after"]="2"
throttle=urllib.error.HTTPError("https://management.azure.com/x",429,"throttle",headers,io.BytesIO())
class Response:
    headers={"Date":__import__('email').utils.format_datetime(m.now_utc())}
    def __enter__(self): return self
    def __exit__(self,*_): pass
    def read(self): return b'{"properties":{"columns":[],"rows":[]}}'
calls=[throttle,Response()]; sleeps=[]
def urlopen(*_a,**_k):
    item=calls.pop(0)
    if isinstance(item,Exception): raise item
    return item
m.urllib.request.urlopen=urlopen; m.time.sleep=lambda seconds:sleeps.append(seconds)
result=m.cost_http_query(env,"query","https://management.azure.com/x",{"type":"Usage"})
assert result["properties"]["rows"]==[] and sleeps==[2]
# The clienttype bucket communicates its retry-after through its own
# extension header (observed live at DefaultQuota:0) and is honored too.
ct_headers=email.message.Message(); ct_headers["x-ms-ratelimit-microsoft.costmanagement-clienttype-retry-after"]="6"
ct_throttle=urllib.error.HTTPError("https://management.azure.com/y",429,"throttle",ct_headers,io.BytesIO())
calls[:]=[ct_throttle,Response()]; sleeps[:]=[]
result=m.cost_http_query(env,"query","https://management.azure.com/y",{"type":"Usage-ct"})
assert result["properties"]["rows"]==[] and sleeps==[6]
assert m.retry_after_seconds(ct_headers)==6
# Only exact body/endpoint bindings can read the authoritative success cache.
body=m.canonical_bytes({"type":"Usage"}); digest="sha256:"+m.sha256_bytes(body); key=m.sha256_bytes(("query\0https://management.azure.com/x\0"+digest).encode())
assert m.load_cost_cache(env,key,"query",digest) is not None
assert m.load_cost_cache(env,key,"forecast",digest) is None
assert m.COST_RETRY_DEADLINE_SECONDS==900 and m.COST_CACHE_MAX_AGE_SECONDS==14400
PY
  pass "Cost Management retry is bounded, honors both Azure guidance headers, and only permits a short exact authoritative cache"
}

retail_rate_unit() {
  python3 - "$HOST" <<'PY'
import copy, importlib.util, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"azure_operation_count":0}
on_demand={"currencyCode":"USD","tierMinimumUnits":0,"retailPrice":0.182,"unitPrice":0.182,"armRegionName":"eastus","armSkuName":"Standard_D4as_v6","productName":"Virtual Machines Dasv6 Series","skuName":"D4as v6","meterName":"D4as v6","serviceName":"Virtual Machines","serviceFamily":"Compute","unitOfMeasure":"1 Hour","type":"Consumption","isPrimaryMeterRegion":True}
low_priority={**on_demand,"retailPrice":0.0363,"unitPrice":0.0363,"meterName":"D4as v6 Low Priority"}
spot={**on_demand,"retailPrice":0.041,"unitPrice":0.041,"meterName":"D4as v6 Spot"}
windows={**on_demand,"retailPrice":0.31,"unitPrice":0.31,"productName":"Virtual Machines Dasv6 Series Windows"}
dev_test={**on_demand,"retailPrice":0.15,"unitPrice":0.15,"productName":"Virtual Machines Dasv6 Series Dev/Test"}
reservation={**on_demand,"retailPrice":0.09,"unitPrice":0.09,"type":"Reservation","reservationTerm":"1 Year"}
savings={**on_demand,"retailPrice":0.08,"unitPrice":0.08,"productName":"Virtual Machines Dasv6 Series Savings Plan"}
rows=[low_priority,spot,windows,dev_test,reservation,savings,on_demand]
m.az_command=lambda *_a,**_k:({"Items":copy.deepcopy(rows)},0,"")
assert m.retail_rate(env,"Standard_D4as_v6")==0.182
# Every audited mixed-family SKU binds its own exact Linux on-demand meter/product.
rates={"Standard_D4as_v7":0.182,"Standard_D4as_v6":0.182,"Standard_D4s_v6":0.202,"Standard_D4ads_v7":0.228,"Standard_D4ads_v6":0.228,"Standard_E4as_v7":0.238,"Standard_E4as_v6":0.238,"Standard_D4ds_v6":0.249}
for sku,rate in rates.items():
    shape=__import__('re').fullmatch(r"Standard_([DE])(\d+)([a-z]+)_v(\d+)",sku); meter=sku.removeprefix("Standard_").replace("_"," "); product="Virtual Machines {}{}v{} Series".format(shape.group(1),shape.group(3),shape.group(4))
    exact={**on_demand,"armSkuName":sku,"skuName":meter,"meterName":meter,"productName":product,"retailPrice":rate,"unitPrice":rate}
    m.az_command=lambda *_a,_exact=exact,**_k:({"Items":[copy.deepcopy(_exact)]},0,"")
    assert m.retail_rate(env,sku)==rate
m.az_command=lambda *_a,**_k:({"Items":[copy.deepcopy(low_priority)]},0,"")
try: m.retail_rate(env,"Standard_D4as_v6")
except m.RunnerError as exc: assert "on-demand" in str(exc) and "unreadable" in str(exc)
else: raise AssertionError("Low Priority meter was accepted as on-demand")
ambiguous={**on_demand,"retailPrice":0.183,"unitPrice":0.183,"meterId":"different-current-meter"}
m.az_command=lambda *_a,**_k:({"Items":[copy.deepcopy(on_demand),ambiguous]},0,"")
try: m.retail_rate(env,"Standard_D4as_v6")
except m.RunnerError as exc: assert "ambiguous" in str(exc)
else: raise AssertionError("distinct eligible on-demand prices were minimized instead of refused")
PY
  pass "retail pricing selects exact Linux on-demand consumption and refuses Low Priority or ambiguity"
}


quota_snapshot_unit() {
  python3 - "$HOST" <<'PY2' || fail "runner quota snapshot unit failed"
import importlib.util, pathlib, tempfile, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","max_concurrency":16,"state_dir":pathlib.Path(tempfile.mkdtemp()),"azure_operation_count":0}
caps=lambda memory:[{"name":"vCPUsAvailable","value":"4"},{"name":"MemoryGB","value":str(memory)},{"name":"CpuArchitectureType","value":"x64"},{"name":"HyperVGenerations","value":"V1,V2"}]
skus=[{"name":sku,"restrictions":[],"capabilities":caps(m.SKU_MEMORY_GIB[sku])} for sku in m.COMMISSIONING_SKU_POOL]
usage=[{"name":{"value":"cores"},"limit":128,"currentValue":0}]+[{"name":{"value":m.SKU_FAMILY[sku]},"limit":10,"currentValue":0} for sku in m.COMMISSIONING_SKU_POOL]
def az(_env,args,**_kwargs):
    if args[1]=="list-skus": return skus,0,""
    if args[1]=="list-usage": return usage,0,""
    raise AssertionError(args)
m.az_command=az
snapshot=m.runner_quota_snapshot(env,m.COMMISSIONING_SKU_POOL)
assert snapshot["regional"]=={"limit":128,"current":0,"free":128}
assert all(snapshot["families"][sku]["limit"]==10 for sku in m.COMMISSIONING_SKU_POOL)
# The deterministic cell-ordinal pool spreads consecutive cells across
# families two-per-SKU; that spread is the remaining quota-contention seam.
assert len(set(m.COMMISSIONING_SKU_POOL))==8
assert m.COMMISSIONING_SKU_POOL[(1-1)//2]==m.COMMISSIONING_SKU_POOL[(2-1)//2]
assert m.COMMISSIONING_SKU_POOL[(3-1)//2]!=m.COMMISSIONING_SKU_POOL[(1-1)//2]
# A restricted SKU refuses.
skus[0]["restrictions"]=[{"reasonCode":"NotAvailableForSubscription"}]
try: m.runner_quota_snapshot(env,m.COMMISSIONING_SKU_POOL)
except m.RunnerError: pass
else: raise AssertionError("restricted SKU was accepted")
PY2
  pass "quota snapshot binds exact regional/family limits and the deterministic pool spreads families"
}


shared_allocator_bridge_unit() {
  python3 - "$HOST" <<'PY' || fail "shared allocator runner bridge failed"
import contextlib, importlib.util, json, pathlib, subprocess, tempfile, sys
spec=importlib.util.spec_from_file_location("runner_shared",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fixture_home=pathlib.Path(tempfile.mkdtemp())
env={"subscription":"sub","resource_group":"rg","prefix":"prefix","budget_limit":1500,"state_dir":pathlib.Path(tempfile.mkdtemp()),"azure_operation_count":0,"capacity_wait_seconds":10,"capacity_poll_seconds":1}
limits={**m.RESOURCE_CLASSES["behavior-heavy"],"sku":"Standard_D4as_v7","sku_family":"StandardDasv7Family"}
state={"schema":m.SCHEMA,"invocation":"azr-aaaaaaaaaaaa","resources":{},"request":{"fence":"sha256:"+"a"*64,"resource_class":"behavior-heavy","limits":limits}}
m.save_state=lambda *_a,**_k:None
calls=[]
def completed(value):
    stdout=value if isinstance(value,str) else json.dumps(value)
    return subprocess.CompletedProcess(["python"],0,stdout=stdout,stderr="")
def response(status="reserved",reason="",actual=100.0,forecast=200.0):
    return {"reservation_id":"azr-aaaaaaaaaaaa","status":status,"reason":reason,"actual_usd":actual,"forecast_usd":forecast,"admission_limit_usd":1500.0}
sequence=[
    response("queued","exact selected-family observed-plus-reserved capacity is exhausted"),
    response(),
]
sleeps=[]
def allocator_run(command,**kwargs):
    assert kwargs["env"]["FM_HOME"]==str(fixture_home)
    assert kwargs["env"]["FM_AZURE_WORKER_STATE_DIR"]==str((fixture_home/"state"/"azure-workers").resolve())
    calls.append(command)
    if "capacity-release" in command:return completed({})
    return completed(sequence.pop(0))
old_home=m.os.environ.get("FM_HOME")
m.os.environ["FM_HOME"]=str(fixture_home)
m.run=allocator_run
m.time.sleep=lambda seconds:sleeps.append(seconds)
cost={"max_increment":25.0}
result=m.shared_capacity_reserve(env,state,cost)
assert result["actual"]==100.0 and result["forecast"]==200.0
reserve_calls=[command for command in calls if "capacity-reserve" in command]
assert len(reserve_calls)==2 and sleeps
assert all(command[command.index("--reservation-id")+1]=="azr-aaaaaaaaaaaa" for command in reserve_calls)
assert len({command[command.index("--fence-binding")+1] for command in reserve_calls})==1
assert reserve_calls[-1][reserve_calls[-1].index("--sku-family")+1]=="StandardDasv7Family"
assert reserve_calls[-1][reserve_calls[-1].index("--role")+1]=="validation"
assert state["shared_capacity_reservation"]["status"]=="reserved"
# A non-capacity queue refusal is immediate and releases its exact row.
state.pop("shared_capacity_reservation")
calls.clear()
def non_capacity(command,**_kwargs):
    calls.append(command)
    if "capacity-release" in command:return completed({})
    return completed(response("queued","shared actual or forecast spend is unreadable"))
m.run=non_capacity
try:m.shared_capacity_reserve(env,state,{"max_increment":25.0})
except m.RunnerError as exc:assert "shared actual or forecast" in str(exc)
else:raise AssertionError("non-capacity allocator refusal entered the wait loop")
assert state["shared_capacity_reservation"]["status"]=="released"
assert sum("capacity-release" in command for command in calls)==1
# A zero-second bounded wait releases a transient queue row before failing.
state.pop("shared_capacity_reservation")
calls.clear()
def always_queued(command,**_kwargs):
    calls.append(command)
    if "capacity-release" in command:return completed({})
    return completed(response("queued","exact selected-family observed-plus-reserved capacity is exhausted"))
m.run=always_queued
try:m.shared_capacity_reserve({**env,"capacity_wait_seconds":0},state,{"max_increment":25.0})
except m.RunnerError as exc:assert "timed out after 0 seconds" in str(exc)
else:raise AssertionError("transient capacity timeout was bypassed")
assert state["shared_capacity_reservation"]["status"]=="released"
assert sum("capacity-release" in command for command in calls)==1
# A malformed retry response after a queue also releases before failing.
state.pop("shared_capacity_reservation")
calls.clear()
sequence=[
    response("queued","exact selected-family observed-plus-reserved capacity is exhausted"),
    "not-json",
]
def malformed_after_queue(command,**_kwargs):
    calls.append(command)
    if "capacity-release" in command:return completed({})
    return completed(sequence.pop(0))
m.run=malformed_after_queue
try:m.shared_capacity_reserve(env,state,{"max_increment":25.0})
except m.RunnerError as exc:assert "malformed" in str(exc)
else:raise AssertionError("malformed allocator retry was bypassed")
assert state["shared_capacity_reservation"]["status"]=="released"
# Unreadable telemetry and shared actual/forecast pressure release admitted capacity.
for payload,text in ((response(actual=None),"readable"),(response(forecast=1490.0),"pressure")):
    state.pop("shared_capacity_reservation")
    calls.clear()
    def reserved_then_release(command,**_kwargs):
        calls.append(command)
        return completed({} if "capacity-release" in command else payload)
    m.run=reserved_then_release
    try:m.shared_capacity_reserve(env,state,{"max_increment":25.0})
    except m.RunnerError as exc:assert text in str(exc)
    else:raise AssertionError("shared allocator failure was bypassed: "+text)
    assert state["shared_capacity_reservation"]["status"]=="released"
# Release is sent only from the post-cleanup bridge with one digest-bound receipt.
m.run=lambda command,**_kwargs:calls.append(command) or completed({})
state["shared_capacity_reservation"]={"status":"reserved"}
m.shared_capacity_release(env,state)
assert "capacity-release" in calls[-1] and len(calls[-1][calls[-1].index("--cleanup-receipt")+1])==64
assert state["shared_capacity_reservation"]["status"]=="released"
# A refusal after shared admission but before VM creation releases rather than
# retaining an idle reservation behind the local concurrency safety cap.
precompute={
    "phase":"prepared","invocation":"azr-aaaaaaaaaaaa","parent_invocation":None,
    "request":{
        "fence":"sha256:"+"a"*64,
        "lineage_root_invocation":"azr-aaaaaaaaaaaa",
        "cost_admission_mode":m.STRICT_COST_ADMISSION_MODE,
        "compute_deallocation_deadline":m.iso_utc(m.now_utc()+m.dt.timedelta(hours=1)),
        "limits":limits,
    },
}
dispatch_env={**env,"cost_admission_mode":m.STRICT_COST_ADMISSION_MODE,"max_concurrency":4,"cell_ordinal":None}
released=[]
m.bind_operation_context=lambda *_a:None
m.scope_gate=lambda *_a:None
m.validation_capacity_parent_gate=lambda *_a:None
m.budget_gate=lambda *_a,**_k:{"max_increment":25.0}
m.foundation_gate=lambda *_a:None
def reserve(_env,got_state,cost):
    got_state["shared_capacity_reservation"]={"status":"reserved"}
    return cost
m.shared_capacity_reserve=reserve
m.reprove_public_request=lambda *_a:None
m.stage_private_snapshot=lambda *_a:None
m.admission_lock=lambda *_a:contextlib.nullcontext()
m.active_runner_vms=lambda *_a:[{}]*4
m.shared_capacity_release=lambda _env,got_state:released.append(got_state["invocation"]) or got_state["shared_capacity_reservation"].update(status="released")
m.transition=lambda _env,got_state,phase,note=None,**updates:got_state.update({"phase":phase,**updates})
try:m.dispatch_prepared(dispatch_env,precompute,"sub",None)
except m.RunnerError as exc:assert "bounded concurrency limit" in str(exc)
else:raise AssertionError("pre-compute local concurrency refusal was bypassed")
assert released==["azr-aaaaaaaaaaaa"] and precompute["phase"]=="failed-retained"
# A restarted command re-enters the same queued invocation instead of fencing it.
queued={"phase":"prepared","invocation":"azr-aaaaaaaaaaaa","shared_capacity_reservation":{"status":"queued"},"request":{"cost_admission_mode":m.STRICT_COST_ADMISSION_MODE}}
seen=[]
m.dispatch_prepared=lambda got_env,got_state,subscription,confirmation:seen.append((got_state["invocation"],subscription,confirmation)) or 7
assert m.resume({"subscription":"sub"},queued)==7
assert seen==[("azr-aaaaaaaaaaaa","sub",None)]
if old_home is None:m.os.environ.pop("FM_HOME",None)
else:m.os.environ["FM_HOME"]=old_home
PY
  pass "runner durably waits only on transient shared capacity and releases every pre-compute refusal"
}

commissioning_admission_unit() {
  python3 - "$HOST" <<'PY2' || fail "commissioning admission adversaries failed"
import importlib.util, math, pathlib, tempfile, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","prefix":"prefix","max_concurrency":16,"budget_limit":1500,"cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE,"state_dir":pathlib.Path(tempfile.mkdtemp()),"azure_operation_count":0}
m.ensure_state_dirs(env)
limits=dict(m.RESOURCE_CLASSES["behavior-heavy"]); limits.update({"sku":"Standard_D4ds_v6","sku_family":"StandardDdsv6Family"})
state={"schema":m.SCHEMA,"invocation":"azr-aaaaaaaaaaaa","request":{"fence":"sha256:"+"a"*64,"lineage_root_invocation":"azr-aaaaaaaaaaaa","cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE,"cell_ordinal":16,"limits":limits,"compute_deallocation_deadline":"2026-01-02T00:00:00Z"}}
seen=[]
m.cost_query=lambda *_a,**_k: (_ for _ in ()).throw(AssertionError("commissioning queried Cost Management"))
real_commissioning_budget=m.exact_commissioning_budget
m.exact_commissioning_budget=lambda _env:seen.append("budget") or {"id":"budget","etag":"E"}
m.active_runner_vms=lambda _env:[]
m.retail_rate=lambda _env,_sku:0.10
cost=m.commissioning_cost_gate(env,state,limits)
assert seen==["budget"] and cost["actual"] is None and cost["forecast"] is None
assert cost["cost_admission_mode"]==m.COMMISSIONING_COST_ADMISSION_MODE
assert cost["max_increment"]==cost["first_day"]["total"] and cost["max_billable_lifetime_hours"]==24
assert cost["outstanding_reservations"]==0.0
# The live Budget contract stays exact: $1500 Monthly RG filter and all eight alerts.
notifications={}
for prefix,kind in (("Actual","Actual"),("Forecast","Forecasted")):
    for label,threshold in (("750",50),("1000",66.67),("1250",83.33),("1500",100)):
        notifications[(prefix+label).lower()]={"enabled":True,"operator":"GreaterThanOrEqualTo","threshold":threshold,"thresholdType":kind,"contactEmails":["operator@example.invalid"]}
budget={"id":"/subscriptions/sub/providers/Microsoft.Consumption/budgets/bud-prefix-monthly","name":"bud-prefix-monthly","type":"Microsoft.Consumption/budgets","eTag":"E","properties":{"category":"Cost","amount":1500,"timeGrain":"Monthly","filter":{"dimensions":{"name":"ResourceGroupName","operator":"In","values":["rg"]}},"notifications":notifications}}
m.az_command=lambda *_a,**_k:(budget,0,"")
m.exact_commissioning_budget=real_commissioning_budget
assert m.exact_commissioning_budget(env)["etag"]=="E"
notifications["actual750"]["enabled"]=False
try: m.exact_commissioning_budget(env)
except m.RunnerError: pass
else: raise AssertionError("commissioning accepted a disabled budget alert")
notifications["actual750"]["enabled"]=True
m.exact_commissioning_budget=lambda _env:{"id":"budget","etag":"E"}
for change,text in (({"max_concurrency":17},"1..16"),({"budget_limit":1000},"$1500")):
    changed=dict(env); changed.update(change)
    try: m.commissioning_cost_gate(changed,state,limits)
    except m.RunnerError as exc: assert text in str(exc)
    else: raise AssertionError("invalid commissioning policy accepted")
# Ledger-backed concurrency: fifteen outstanding entries admit the sixteenth;
# once this invocation is itself reserved it stays admitted; a seventeenth
# stranger refuses at the bounded limit.
for i in range(1,16):
    m.spend_ledger_reserve(env,{"invocation":"azr-{:012x}".format(i)},cost["max_increment"])
sixteenth=m.commissioning_cost_gate(env,state,limits)
assert sixteenth["reserved_invocations"]==15+1-1 or sixteenth["reserved_invocations"]==15
assert math.isclose(sixteenth["outstanding_reservations"],15*cost["max_increment"])
m.spend_ledger_reserve(env,state,cost["max_increment"])
assert m.commissioning_cost_gate(env,state,limits)["reserved_invocations"]==16
seventeenth={"schema":m.SCHEMA,"invocation":"azr-bbbbbbbbbbbb","request":{"fence":"sha256:"+"b"*64,"cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE,"cell_ordinal":1,"limits":limits}}
seventeenth_limits=limits
try: m.commissioning_cost_gate(env,seventeenth,seventeenth_limits)
except m.RunnerError as exc: assert "bounded concurrency limit" in str(exc)
else: raise AssertionError("seventeenth commissioning runner was admitted")
# A cleaned entry releases its slot.
m.spend_ledger_mark_cleaned(env,{"invocation":"azr-{:012x}".format(1)})
assert m.commissioning_cost_gate(env,seventeenth,seventeenth_limits)["outstanding_reservations"]>0
# Default strict mode calls actual and forecast and propagates an unavailable forecast.
strict_env=dict(env,cost_admission_mode=m.STRICT_COST_ADMISSION_MODE,budget_limit=1000,max_concurrency=4,state_dir=pathlib.Path(tempfile.mkdtemp()))
m.ensure_state_dirs(strict_env)
calls=[]
def cost_query(_env,forecast=False,**_kwargs):
    calls.append(forecast)
    if forecast: raise m.RunnerError("429")
    return 0.0
m.cost_query=cost_query
try: m.budget_gate(strict_env,limits)
except m.RunnerError: pass
else: raise AssertionError("strict admission bypassed unavailable Cost Management")
assert calls==[False,True]
# The untrained-forecast seam: strict mode substitutes the readable actual for
# a forecast HTTP 424 only under the operator's explicit
# FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST=1, and never for other failures.
import os as _os
m.retail_rate=lambda _env,_sku:0.1
def untrained_query(_env,forecast=False,**_kwargs):
    if forecast: raise m.RunnerError("Cost Management forecast failed with HTTP 424")
    return 1.5
m.cost_query=untrained_query
_os.environ.pop("FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST",None)
try: m.budget_gate(strict_env,limits)
except m.RunnerError as exc: assert "HTTP 424" in str(exc)
else: raise AssertionError("strict admission accepted an untrained forecast without operator confirmation")
_os.environ["FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST"]="1"
admitted=m.budget_gate(strict_env,limits)
assert admitted["forecast"]==1.5 and admitted["actual"]==1.5
def throttled_query(_env,forecast=False,**_kwargs):
    if forecast: raise m.RunnerError("Cost Management forecast remained throttled with no exact authoritative cache (missing server retry guidance)")
    return 1.5
m.cost_query=throttled_query
admitted=m.budget_gate(strict_env,limits)
assert admitted["forecast"]==1.5
_os.environ.pop("FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST",None)
try: m.budget_gate(strict_env,limits)
except m.RunnerError as exc: assert "remained throttled" in str(exc)
else: raise AssertionError("throttled forecast substituted without operator confirmation")
_os.environ["FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST"]="1"
m.cost_query=cost_query
try: m.budget_gate(strict_env,limits)
except m.RunnerError as exc: assert "HTTP 424" not in str(exc)
else: raise AssertionError("operator confirmation leaked beyond the untrained-forecast case")
_os.environ.pop("FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST",None)
# Ledger outstanding pressure feeds the strict ceiling.
m.cost_query=lambda _env,forecast=False,**_kwargs:100.0
m.spend_ledger_reserve(strict_env,{"invocation":"azr-cccccccccccc"},900.0)
try: m.budget_gate(strict_env,limits,outstanding_reservations=m.spend_ledger_outstanding(strict_env))
except m.RunnerError as exc: assert "budget pressure" in str(exc)
else: raise AssertionError("outstanding ledger spend did not pressure the ceiling")
# Dispatch requires exact explicit confirmation only for commissioning mode.
minimal={"invocation":"azr-aaaaaaaaaaaa","parent_invocation":None,"request":{"fence":"sha256:"+"a"*64,"lineage_root_invocation":"azr-aaaaaaaaaaaa","cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE}}
try: m.dispatch_prepared(env,minimal,"sub",None)
except m.RunnerError as exc: assert "--confirm-cost-admission-mode" in str(exc)
else: raise AssertionError("commissioning ran without exact confirmation")
minimal["request"]["cost_admission_mode"]=m.STRICT_COST_ADMISSION_MODE
try: m.dispatch_prepared(strict_env,minimal,"sub",m.COMMISSIONING_COST_ADMISSION_MODE)
except m.RunnerError as exc: assert "accepted only" in str(exc)
else: raise AssertionError("strict mode accepted commissioning confirmation")
PY2
  pass "runner-local strict and commissioning defenses keep the budget-alert proof, itemized bound, and ledger concurrency"
}

# One ULID whose 26 characters all sit in the Crockford alphabet the gate
# worktree probe accepts (no I/L/O/U).
NM_RUN_FIXTURE=01BX5ZZKBKACTAV9WEVGEMMVRZ

make_dispatch_fixture() {  # <root>: real dispatch + step code, capturing runner
  local root=$1
  mkdir -p "$root/bin" "$root/tests"
  cp "$ROOT/bin/fm-azure-runner-dispatch.sh" "$root/bin/fm-azure-runner-dispatch.sh"
  cp "$ROOT/bin/fm-no-mistakes-test-command.sh" "$root/bin/fm-no-mistakes-test-command.sh"
  cp "$ROOT/bin/fm-azure-service-test-scope.py" "$root/bin/fm-azure-service-test-scope.py"
  cp "$ROOT/bin/fm-azure-runner-command.sh" "$root/bin/fm-azure-runner-command.sh"
  cp "$ROOT/bin/fm-azure-runner-routing.py" "$root/bin/fm-azure-runner-routing.py"
  cp "$ROOT/bin/fm-azure-runner.py" "$root/bin/fm-azure-runner.py"
  cat >"$root/bin/fm-azure-runner.sh" <<SH
#!/bin/sh
printf '%s\n' "\$@" >"$root/captured"
{
  printf 'FM_HOME=%s\n' "\${FM_HOME:-}"
  printf 'FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION=%s\n' "\${FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION:-}"
  printf 'FM_AZURE_TENANT_ID=%s\n' "\${FM_AZURE_TENANT_ID:-}"
  printf 'FM_AZURE_SUBSCRIPTION_ID=%s\n' "\${FM_AZURE_SUBSCRIPTION_ID:-}"
  printf 'FM_AZURE_NAMING_PREFIX=%s\n' "\${FM_AZURE_NAMING_PREFIX:-}"
  printf 'FM_AZURE_STORAGE_NAME=%s\n' "\${FM_AZURE_STORAGE_NAME:-}"
  printf 'FM_AZURE_OWNER_TAG=%s\n' "\${FM_AZURE_OWNER_TAG:-}"
  printf 'FM_AZURE_DEPLOYMENT_GENERATION=%s\n' "\${FM_AZURE_DEPLOYMENT_GENERATION:-}"
  printf 'FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID=%s\n' "\${FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID:-}"
  printf 'FM_AZURE_RESOURCE_GROUP=%s\n' "\${FM_AZURE_RESOURCE_GROUP:-}"
  printf 'FM_AZURE_RUNNER_TASK=%s\n' "\${FM_AZURE_RUNNER_TASK:-}"
  printf 'FM_AZURE_RUNNER_GENERATION=%s\n' "\${FM_AZURE_RUNNER_GENERATION:-}"
  printf 'FM_AZURE_RUNNER_STATE_DIR=%s\n' "\${FM_AZURE_RUNNER_STATE_DIR:-}"
  printf 'FM_AZURE_SHARED_CAPACITY_STATE_DIR=%s\n' "\${FM_AZURE_SHARED_CAPACITY_STATE_DIR:-}"
} >"$root/captured-env"
if [ "\${FM_TEST_FIXTURE_EXECUTE_REMOTE:-0}" = 1 ]; then
  while [ "\$#" -gt 0 ] && [ "\${1:-}" != -- ]; do shift; done
  [ "\${1:-}" = -- ] || exit 98
  shift
  ( cd "$root" && HOME="\${FM_TEST_FIXTURE_REMOTE_HOME:?}" FM_AZURE_RUNNER=1 "\$@" )
  exit \$?
fi
exit 0
SH
  cat >"$root/tests/run.sh" <<SH
#!/bin/sh
if [ -n "\${FM_TEST_CONCURRENCY_DIR:-}" ]; then
  touch "\$FM_TEST_CONCURRENCY_DIR/herdr.started"
  i=0
  while [ ! -e "\$FM_TEST_CONCURRENCY_DIR/agent-fleet.started" ]; do
    i=\$((i + 1)); [ "\$i" -lt 100 ] || exit 95
    sleep 0.05
  done
fi
{
  printf 'call'
  for arg do printf '\t%s' "\$arg"; done
  printf '\n'
} >>"$root/local-runs"
printf '%s\n' "\${FM_TEST_HOST_CAPABILITIES_ABSENT:-}" >"$root/local-capabilities"
if [ "\${1:-}" = --skip-herdr ]; then
  [ "\${FM_TEST_HOST_CAPABILITIES_ABSENT:-}" = real-tmux-server,passwordless-root-escalation,system-openat-binding,origin-egress ] || exit 96
  printf 'FM_HOST_CAPABILITY_DECLARATION absent=%s\n' "\$FM_TEST_HOST_CAPABILITIES_ABSENT" >>"$root/remote-runs"
fi
exit 0
SH
  cat >"$root/tests/test-capabilities.tsv" <<'TSV'
fm-fixture-hermetic.test.sh	hermetic
fm-fixture-herdr.test.sh	herdr-lab
fm-fixture-mixed.test.sh	herdr-mixed
TSV
  chmod +x "$root/bin/"* "$root/tests/run.sh"
}

make_ambient_worktree() {  # <path>: a committed git worktree
  mkdir -p "$1"
  git -C "$1" init -q -b fm/ambient
  git -C "$1" config user.name fixture
  git -C "$1" config user.email fixture@example.invalid
  printf 'ambient\n' >"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -qm ambient
}

dispatch_ambient_binding_contract() {
  local tmp fixture home taskwt gatewt gate_head dispatch out rc
  fm_test_tmproot_into tmp fm-azure-runner-ambient-bindings
  fixture="$tmp/fixture"
  make_dispatch_fixture "$fixture"
  dispatch="$fixture/bin/fm-azure-runner-dispatch.sh"
  home="$tmp/home"
  mkdir -p "$home/state"
  make_ambient_worktree "$tmp/taskwt"
  taskwt=$(cd "$tmp/taskwt" && pwd -P)
  mkdir -p "$taskwt/sub"
  fm_write_meta "$home/state/task-fixture.meta" \
    "worktree=$taskwt" \
    "generation_id=spawn:fixture123" \
    "kind=ship" "mode=no-mistakes"

  # 1. Ambient task-worktree derivation, exact bindings, from a subdirectory.
  rm -f "$fixture/captured"
  (cd "$taskwt/sub" && env FM_HOME="$home" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    "$dispatch" lint -- sh -c 'exit 0') || fail "ambient task-worktree dispatch failed"
  [ -f "$fixture/captured" ] || fail "the fixture runner captured no invocation"
  python3 - "$fixture/captured" "$SUB" <<'PY' || fail "task-worktree bindings were not derived exactly"
import sys
argv=open(sys.argv[1]).read().splitlines()
def value(flag): return argv[argv.index(flag)+1]
assert argv[0]=="run" and "--confirm-run" in argv
assert value("--confirm-subscription")==sys.argv[2]
assert value("--task")=="task-fixture"
assert value("--generation")=="spawn:fixture123"
assert value("--resource-class")=="validation-standard"
assert argv[argv.index("--")+1:]==["sh","-c","exit 0"]
PY

  # 2. Gate-worktree derivation: the no-mistakes run's own identity.
  gatewt="$tmp/nm-home/worktrees/19543ae8611e/$NM_RUN_FIXTURE"
  make_ambient_worktree "$gatewt"
  gate_head=$(git -C "$gatewt" rev-parse HEAD)
  rm -f "$fixture/captured"
  (cd "$gatewt" && env FM_HOME="$home" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    "$dispatch" lint -- sh -c 'exit 0') || fail "gate-worktree dispatch failed"
  python3 - "$fixture/captured" "nm-$NM_RUN_FIXTURE" "$gate_head" <<'PY' || fail "gate-worktree bindings were not derived exactly"
import sys
argv=open(sys.argv[1]).read().splitlines()
def value(flag): return argv[argv.index(flag)+1]
assert value("--task")==sys.argv[2]
assert value("--generation")==sys.argv[3]
PY

  # 3. No ambient identity fails CLOSED: loud, exact, and the command runs
  # NOWHERE - no runner dispatch and no silent local execution.
  make_ambient_worktree "$tmp/unrecorded"
  rm -f "$fixture/captured" "$tmp/ran-locally"
  rc=0
  out=$(cd "$tmp/unrecorded" && env FM_HOME="$home" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an underivable task identity did not refuse"
  assert_contains "$out" "cannot derive FM_AZURE_RUNNER_TASK" "the refusal did not name the missing binding"
  assert_contains "$out" "$home/state" "the refusal did not name the searched state directory"
  [ ! -e "$fixture/captured" ] || fail "an underivable identity still dispatched to Azure"
  [ ! -e "$tmp/ran-locally" ] || fail "an underivable identity fell back to silent local execution"

  # 4. An ambiguous worktree refuses rather than guessing.
  fm_write_meta "$home/state/task-second.meta" \
    "worktree=$taskwt" "generation_id=spawn:second456"
  rm -f "$fixture/captured" "$tmp/ran-locally"
  rc=0
  out=$(cd "$taskwt" && env FM_HOME="$home" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an ambiguous worktree recording did not refuse"
  assert_contains "$out" "more than one task metadata" "the ambiguity refusal was not explicit"
  assert_contains "$out" "task-fixture" "the ambiguity refusal did not name the first candidate"
  assert_contains "$out" "task-second" "the ambiguity refusal did not name the second candidate"
  [ ! -e "$fixture/captured" ] && [ ! -e "$tmp/ran-locally" ] || fail "an ambiguous identity still executed"
  rm -f "$home/state/task-second.meta"

  # 5. A matched task whose metadata lacks generation_id refuses by name.
  make_ambient_worktree "$tmp/nogen"
  fm_write_meta "$home/state/task-nogen.meta" "worktree=$(cd "$tmp/nogen" && pwd -P)"
  rc=0
  out=$(cd "$tmp/nogen" && env FM_HOME="$home" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    "$dispatch" lint -- sh -c 'exit 0' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a metadata record without generation_id did not refuse"
  assert_contains "$out" "records no generation_id" "the generation refusal was not explicit"

  # 6. The subscription confirmation is pass-through only, never invented.
  rm -f "$fixture/captured" "$tmp/ran-locally"
  rc=0
  out=$(cd "$taskwt" && env FM_HOME="$home" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an absent operator subscription did not refuse"
  assert_contains "$out" "FM_AZURE_SUBSCRIPTION_ID is not set" "the subscription refusal did not name its source"
  [ ! -e "$fixture/captured" ] && [ ! -e "$tmp/ran-locally" ] || fail "a missing subscription confirm still executed"

  # 7. Explicit operator bindings pass through verbatim, without any git or
  # metadata requirement.
  rm -f "$fixture/captured"
  (cd "$tmp" && env FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    FM_AZURE_RUNNER_TASK=operator-task FM_AZURE_RUNNER_GENERATION=operator-gen \
    FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION="$SUB" \
    "$dispatch" lint -- sh -c 'exit 0') || fail "explicit operator bindings failed to dispatch"
  python3 - "$fixture/captured" <<'PY' || fail "explicit operator bindings were not passed through verbatim"
import sys
argv=open(sys.argv[1]).read().splitlines()
def value(flag): return argv[argv.index(flag)+1]
assert value("--task")=="operator-task" and value("--generation")=="operator-gen"
PY

  # 8. Half an explicit identity refuses instead of silently mixing sources.
  rc=0
  out=$(cd "$taskwt" && env FM_HOME="$home" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    FM_AZURE_RUNNER_TASK=operator-task \
    "$dispatch" lint -- sh -c 'exit 0' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a half-explicit identity was accepted"
  assert_contains "$out" "export both or neither" "the half-explicit refusal was not explicit"
  rc=0
  out=$(cd "$taskwt" && env FM_HOME="$home" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    FM_AZURE_RUNNER_GENERATION=operator-gen \
    "$dispatch" lint -- sh -c 'exit 0' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a generation-only explicit identity was accepted"
  assert_contains "$out" "export both or neither" "the generation-only refusal was not explicit"

  # 8b. A directory under worktrees/ whose name is not a ULID run id is not a
  # gate worktree and refuses rather than minting a fake run identity.
  make_ambient_worktree "$tmp/nm-home/worktrees/19543ae8611e/not-a-run-id"
  rm -f "$fixture/captured" "$tmp/ran-locally"
  rc=0
  out=$(cd "$tmp/nm-home/worktrees/19543ae8611e/not-a-run-id" && env FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-ULID worktrees directory minted a run identity"
  assert_contains "$out" "not a no-mistakes gate worktree" "the non-ULID refusal was not explicit"
  [ ! -e "$fixture/captured" ] && [ ! -e "$tmp/ran-locally" ] || fail "a non-ULID worktrees directory still executed"

  # 9. A class that is not remote-selected stays local and needs no identity.
  rm -f "$fixture/captured" "$tmp/ran-locally"
  (cd "$tmp/unrecorded" && "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'") \
    || fail "unselected class failed to execute locally"
  [ -e "$tmp/ran-locally" ] || fail "unselected class did not run locally"
  [ ! -e "$fixture/captured" ] || fail "unselected class reached the runner"

  # 10. Explicit local recovery still wins over the remote selection.
  rm -f "$fixture/captured" "$tmp/ran-locally"
  (cd "$tmp/unrecorded" && env FM_AZURE_RUNNER_REMOTE_CLASSES='lint=validation-standard' \
    FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES=lint \
    "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>/dev/null) \
    || fail "local recovery class failed to execute locally"
  [ -e "$tmp/ran-locally" ] || fail "local recovery did not run locally"
  [ ! -e "$fixture/captured" ] || fail "local recovery reached the runner"

  pass "the dispatch caller derives task/generation from the ambient run, passes the operator subscription through, and fails closed with exact refusals"
}

no_mistakes_test_step_offload_contract() {
  local tmp fixture gatewt gate_head fakebin anchor fmhome routing expires rc out
  local mutation mutation_action replacement remote_home project python
  fm_test_tmproot_into tmp fm-azure-runner-test-step-offload
  fixture="$tmp/fixture"
  make_dispatch_fixture "$fixture"
  gatewt="$tmp/nm-home/worktrees/19543ae8611e/$NM_RUN_FIXTURE"
  make_ambient_worktree "$gatewt"
  gate_head=$(git -C "$gatewt" rev-parse HEAD)
  git -C "$gatewt" checkout -q --detach "$gate_head"
  fakebin="$tmp/fakebin"
  mkdir -p "$fakebin"
  cat >"$fakebin/tmux" <<'SH'
#!/bin/sh
[ "${1:-}" = -V ] && echo "tmux 3.4"
exit 0
SH
  cat >"$fakebin/uv" <<'SH'
#!/bin/sh
if [ -n "${FM_TEST_CONCURRENCY_DIR:-}" ] && [ "${5:-}" = pytest ]; then
  touch "$FM_TEST_CONCURRENCY_DIR/agent-fleet.started"
  i=0
  while [ ! -e "$FM_TEST_CONCURRENCY_DIR/herdr.started" ]; do
    i=$((i + 1)); [ "$i" -lt 100 ] || exit 95
    sleep 0.05
  done
fi
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/uv"

  anchor="$tmp/operator-home"
  fmhome="$anchor/firstmate-home"
  routing="$anchor/.fm-azure/runner-routing"
  mkdir -p "$fmhome/state" "$routing"
  cat >"$anchor/.fm-azure/fleet.env" <<ENV
FM_AZURE_TENANT_ID=$SUB
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_NAMING_PREFIX=fmfixture
FM_AZURE_STORAGE_NAME=stfixture001
FM_AZURE_OWNER_TAG=fixture-owner
FM_AZURE_DEPLOYMENT_GENERATION=fixture-generation
FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID=$SUB
FM_AZURE_RESOURCE_GROUP=rg-fixture
ENV
  chmod 600 "$anchor/.fm-azure/fleet.env"
  expires=$(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)+d.timedelta(hours=6)).strftime("%Y-%m-%dT%H:%M:%SZ"))')

  write_test_routing() {  # <python-dict-overrides>
    python3 - "$routing/$NM_RUN_FIXTURE.json" "$fmhome" "$SUB" "$expires" "$NM_RUN_FIXTURE" "$1" <<'PY'
import json,sys
value={
  "schema":"fm.azure-runner-routing/v1","run_id":sys.argv[5],
  "classes":{"test":"behavior-heavy"},"fm_home":sys.argv[2],
  "subscription":sys.argv[3],"expires_at":sys.argv[4],"max_dispatches":1,
}
value.update(json.loads(sys.argv[6]))
open(sys.argv[1],"w").write(json.dumps(value,indent=2)+"\n")
PY
    chmod 600 "$routing/$NM_RUN_FIXTURE.json"
  }

  routing_dispatch_count() {
    python3 - "$routing/$NM_RUN_FIXTURE.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("dispatched", 0))
PY
  }

  assert_capability_derived_local_host_set() {
    local log=$1
    [ -s "$log" ] || fail "the capability-derived local host set did not cross tests/run.sh"
    [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] \
      || fail "the local host set did not run in one serial tests/run.sh invocation"
    grep -q 'fm-fixture-herdr.test.sh' "$log" \
      || fail "the local host set omitted a herdr-lab registry row"
    grep -q 'fm-fixture-mixed.test.sh' "$log" \
      || fail "the local host set omitted a herdr-mixed registry row"
    ! grep -q 'fm-fixture-hermetic.test.sh' "$log" \
      || fail "the local host set duplicated a hermetic-only registry row before CI"
    ! grep -q -- '--skip-herdr' "$log" \
      || fail "the local host set selected the non-Herdr path"
  }

  # A no-mistakes Azure guest is already the isolated execution boundary.
  # It runs only the service transport/lifecycle regression set in that worker
  # and must never recurse through the general Azure dispatcher or Herdr lane.
  rm -f "$fixture/captured" "$fixture/local-runs" "$fixture/local-capabilities"
  out=$(cd "$gatewt" && env HOME="$anchor" PATH="$fakebin:$PATH" \
    FM_NO_MISTAKES_AZURE_WORKER=1 FM_TEST_HOST_CAPABILITIES_ABSENT=must-not-pass \
    "$fixture/bin/fm-no-mistakes-test-command.sh" 2>&1) \
    || fail "the no-mistakes Azure worker focused suite failed"
  [ ! -e "$fixture/captured" ] \
    || fail "the no-mistakes Azure worker recursively dispatched another Azure runner"
  assert_contains "$out" "Azure worker focused suite files=10" \
    "the no-mistakes Azure worker did not identify its focused suite"
  [ "$(wc -l < "$fixture/local-runs" | tr -d ' ')" -eq 1 ] \
    || fail "the no-mistakes Azure worker did not run one focused suite invocation"
  [ "$(cat "$fixture/local-capabilities")" = passwordless-root-escalation ] \
    || fail "the no-mistakes Azure worker did not bind its exact absent host capability"
  for required in \
    fm-azure-pilot.test.sh fm-azure-runner.test.sh fm-cloud-provider-seal.test.sh \
    fm-no-mistakes-reattach.test.sh fm-no-mistakes-runtime.test.sh \
    fm-no-mistakes-worker.test.sh fm-worker-lifecycle.test.sh \
    fm-worker-outcome-transport.test.sh fm-worker-placement.test.sh \
    fm-worker-supervisor.test.sh; do
    grep -q "$required" "$fixture/local-runs" \
      || fail "the no-mistakes Azure worker focused suite omitted $required"
  done
  ! grep -q 'fm-fixture-herdr.test.sh' "$fixture/local-runs" \
    || fail "the no-mistakes Azure worker entered the unrelated Herdr suite"
  pass "the no-mistakes Azure worker runs its focused service suite without nested Azure or Herdr"

  # The daemon-owned production path has no FM_AZURE_RUNNER_REMOTE_CLASSES.
  # A valid per-run selection must still choose the split lane, and inspection
  # must not spend a second budget slot before the real dispatch consumes one.
  write_test_routing '{}'
  rm -f "$fixture/captured" "$fixture/local-runs"
  out=$(cd "$gatewt" && env HOME="$anchor" PATH="$fakebin:$PATH" \
    "$fixture/bin/fm-no-mistakes-test-command.sh" 2>&1) \
    || fail "a per-run test selection did not choose the split lane"
  [ -f "$fixture/captured" ] || fail "a per-run test selection never reached the fixture runner"
  assert_contains "$out" "selected REMOTE resource-class=behavior-heavy" \
    "the per-run test selection emitted no remote-selection proof"
  assert_capability_derived_local_host_set "$fixture/local-runs"
  [ "$(routing_dispatch_count)" -eq 1 ] \
    || fail "non-consuming test inspection did not leave exactly one durable dispatch spend"
  grep -qx -- '--private-snapshot-from-head' "$fixture/captured" \
    || fail "the detached per-run gate did not select an exact private HEAD snapshot"
  grep -qx -- "refs/heads/fm-no-mistakes/$NM_RUN_FIXTURE" "$fixture/captured" \
    || fail "the detached per-run gate did not bind its deterministic private source ref"
  ! grep -qx -- '--capacity-parent' "$fixture/captured" \
    || fail "the direct per-run gate incorrectly required a validation-cell parent"

  # Execute the exact production remote argv in a hermetic fixture. The fake uv
  # keeps this focused on orchestration while requiring the release-local Agent
  # Fleet entrypoint that all 416 incident setup errors could not find.
  remote_home="$tmp/remote-home"
  mkdir -p "$remote_home/.fm-runner-tools/bin" "$remote_home/.fm-runner-tools/uv" \
    "$remote_home/.fm-runner-tools/wheelhouse" "$fixture/tools/agent-fleet/src"
  cp "$ROOT/tools/agent-fleet/pyproject.toml" "$ROOT/tools/agent-fleet/uv.lock" \
    "$fixture/tools/agent-fleet/"
  cp -R "$ROOT/tools/agent-fleet/src/agent_fleet" "$fixture/tools/agent-fleet/src/"
  python=$(python_311) \
    || fail "could not resolve Python 3.11+ for the remote-command fixture"
  "$python" -m venv --without-pip "$fixture/tools/agent-fleet/.venv" >/dev/null \
    || fail "the remote-command fixture could not create its Agent Fleet venv"
  "$fixture/tools/agent-fleet/.venv/bin/python" "$AGENT_FLEET_INSTALLER" \
    "$fixture/tools/agent-fleet" "$fixture/tools/agent-fleet/.venv" >/dev/null \
    || fail "the remote-command fixture could not install Agent Fleet offline"
  cat >"$remote_home/.fm-runner-tools/bin/shellcheck" <<'SH'
#!/bin/sh
printf '%s\n' 'ShellCheck - shell script analysis tool' 'version: 0.11.0'
SH
  cat >"$remote_home/.fm-runner-tools/uv/uv" <<SH
#!/bin/sh
if [ "\${1:-}" = --version ]; then echo 'uv 0.9.10'; exit 0; fi
[ "\${UV_OFFLINE:-}" = 1 ] && [ "\${UV_NO_INDEX:-}" = 1 ] && [ "\${UV_NO_SYNC:-}" = 1 ] || exit 94
printf '%s\n' "\$*" >>"$fixture/remote-uv-runs"
[ "\${1:-}" = run ] && [ "\${2:-}" = --directory ] && [ "\${4:-}" = --locked ] || exit 95
case "\${5:-}" in
  pytest)
    [ -x "\$3/.venv/bin/agent-fleet" ] || exit 93
    "\$3/.venv/bin/agent-fleet" --help >/dev/null
    "\$3/.venv/bin/python" -c 'from agent_fleet.providers import agent_fleet_entrypoint_path; assert agent_fleet_entrypoint_path().is_file()'
    ;;
  python)
    shift 5
    "tools/agent-fleet/.venv/bin/python" "\$@"
    ;;
  *) exit 92 ;;
esac
SH
  chmod +x "$remote_home/.fm-runner-tools/bin/shellcheck" \
    "$remote_home/.fm-runner-tools/uv/uv"
  write_test_routing '{}'
  rm -f "$fixture/captured" "$fixture/local-runs" "$fixture/remote-runs" "$fixture/remote-uv-runs"
  out=$(cd "$gatewt" && env HOME="$anchor" PATH="$fakebin:$PATH" \
    FM_TEST_FIXTURE_EXECUTE_REMOTE=1 FM_TEST_FIXTURE_REMOTE_HOME="$remote_home" \
    "$fixture/bin/fm-no-mistakes-test-command.sh" 2>&1) \
    || fail "the full remote no-mistakes command failed in its hermetic fixture"
  assert_contains "$out" "selected REMOTE resource-class=behavior-heavy" \
    "the hermetic full command lost its remote routing selection"
  grep -Fqx \
    "FM_HOST_CAPABILITY_DECLARATION absent=real-tmux-server,passwordless-root-escalation,system-openat-binding,origin-egress" \
    "$fixture/remote-runs" \
    || fail "the production remote command lost the exact four-name capability declaration"
  grep -Fqx "run --directory tools/agent-fleet --locked pytest" \
    "$fixture/remote-uv-runs" \
    || fail "the production remote command did not run locked Agent Fleet pytest"
  grep -Fqx "run --directory tools/agent-fleet --locked python -m compileall -q src" \
    "$fixture/remote-uv-runs" \
    || fail "the production remote command did not run locked Agent Fleet compileall"
  pass "the full production remote command runs hermetically with four named absences and the offline Agent Fleet entrypoint"

  # Inspection is only a planning read. The real heavy dispatch must carry an
  # exact binding from that read so deletion, unselection, or replacement in
  # the interval can never turn the Azure payload into an ordinary local
  # command or silently dispatch a different selection.
  cat >"$fakebin/grep" <<'SH'
#!/bin/sh
case " $* " in
  *test-capabilities.tsv*)
    if [ ! -e "$FM_TEST_ROUTING_MUTATED" ]; then
      : >"$FM_TEST_ROUTING_MUTATED"
      case "$FM_TEST_ROUTING_MUTATION" in
        delete) rm -f "$FM_TEST_ROUTING_PATH" ;;
        replace) mv "$FM_TEST_ROUTING_REPLACEMENT" "$FM_TEST_ROUTING_PATH" ;;
        *) exit 97 ;;
      esac
    fi
    ;;
esac
exec /usr/bin/grep "$@"
SH
  chmod +x "$fakebin/grep"
  for mutation in delete unselect replace; do
    write_test_routing '{}'
    replacement="$tmp/$mutation-routing.json"
    case "$mutation" in
      delete) : >"$replacement" ;;
      unselect)
        write_test_routing '{"classes":{"lint":"validation-standard"}}'
        cp "$routing/$NM_RUN_FIXTURE.json" "$replacement"
        write_test_routing '{}'
        ;;
      replace)
        write_test_routing '{"classes":{"test":"validation-standard"}}'
        cp "$routing/$NM_RUN_FIXTURE.json" "$replacement"
        write_test_routing '{}'
        ;;
    esac
    mutation_action=$mutation
    [ "$mutation_action" != unselect ] || mutation_action=replace
    rm -f "$fixture/captured" "$fixture/local-runs" "$tmp/heavy-local" "$tmp/routing-mutated"
    rc=0
    out=$(cd "$gatewt" && env HOME="$anchor" PATH="$fakebin:$PATH" \
      FM_TEST_ROUTING_MUTATION="$mutation_action" \
      FM_TEST_ROUTING_PATH="$routing/$NM_RUN_FIXTURE.json" \
      FM_TEST_ROUTING_REPLACEMENT="$replacement" \
      FM_TEST_ROUTING_MUTATED="$tmp/routing-mutated" \
      "$fixture/bin/fm-no-mistakes-test-command.sh" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] \
      || fail "a routing $mutation after inspection did not refuse the bound heavy dispatch"
    assert_contains "$out" "selection binding" \
      "a routing $mutation after inspection did not name the stale selection binding"
    [ ! -e "$fixture/captured" ] \
      || fail "a routing $mutation after inspection dispatched a different remote selection"
    ! grep -q -- '--skip-herdr' "$fixture/local-runs" 2>/dev/null \
      || fail "a routing $mutation after inspection downgraded the heavy shard to local execution"
    if [ "$mutation" != delete ]; then
      [ "$(routing_dispatch_count)" -eq 0 ] \
        || fail "a routing $mutation after inspection spent a dispatch slot before refusing"
    fi
  done
  rm -f "$fakebin/grep"

  # A present malformed authority runs nothing, even when explicit local
  # recovery is also requested. Recovery may override a valid selection only.
  write_test_routing '{"schema":"fm.azure-runner-routing/v99"}'
  rm -f "$fixture/captured" "$fixture/local-runs"
  rc=0
  out=$(cd "$gatewt" && env HOME="$anchor" PATH="$fakebin:$PATH" \
    FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES=test \
    "$fixture/bin/fm-no-mistakes-test-command.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the real test owner bypassed a malformed per-run routing authority"
  assert_contains "$out" "declares schema" \
    "the real test owner's malformed-routing refusal did not name the defect"
  [ ! -e "$fixture/captured" ] && [ ! -e "$fixture/local-runs" ] \
    || fail "the real test owner executed after a malformed-routing refusal"

  # A valid document that does not select test preserves the ordinary
  # capability-derived host set and records why the class ran locally.
  write_test_routing '{"classes":{"lint":"validation-standard"}}'
  rm -f "$fixture/captured" "$fixture/local-runs"
  concurrency_dir="$tmp/local-concurrency"
  mkdir -p "$concurrency_dir"
  out=$(cd "$gatewt" && env HOME="$anchor" PATH="$fakebin:$PATH" \
    FM_TEST_CONCURRENCY_DIR="$concurrency_dir" \
    "$fixture/bin/fm-no-mistakes-test-command.sh" 2>&1) \
    || fail "an unselected per-run test class did not preserve local host execution"
  [ ! -e "$fixture/captured" ] || fail "an unselected per-run test class reached the runner"
  assert_capability_derived_local_host_set "$fixture/local-runs"
  assert_contains "$out" "executed LOCALLY (routing=present-not-selected, env=absent)" \
    "an unselected per-run test class emitted no local-execution proof"
  [ -e "$concurrency_dir/herdr.started" ] && [ -e "$concurrency_dir/agent-fleet.started" ] \
    || fail "the local Herdr and Agent Fleet lanes did not overlap"
  [ "$(routing_dispatch_count)" -eq 0 ] \
    || fail "an unselected per-run test class spent a dispatch budget slot"

  # Explicit recovery over a valid selected document runs the ordinary local
  # host set, says so, and consumes no remote budget.
  write_test_routing '{}'
  rm -f "$fixture/captured" "$fixture/local-runs"
  out=$(cd "$gatewt" && env HOME="$anchor" PATH="$fakebin:$PATH" \
    FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES=test \
    "$fixture/bin/fm-no-mistakes-test-command.sh" 2>&1) \
    || fail "explicit per-run test recovery did not preserve local host execution"
  [ ! -e "$fixture/captured" ] || fail "explicit per-run test recovery reached the runner"
  assert_capability_derived_local_host_set "$fixture/local-runs"
  assert_contains "$out" "executed LOCALLY (explicit local recovery)" \
    "explicit per-run test recovery emitted no local-execution proof"
  [ "$(routing_dispatch_count)" -eq 0 ] \
    || fail "explicit per-run test recovery spent a dispatch budget slot"

  # The REAL no-mistakes test step machinery: the remote-selected test class
  # dispatches the non-Herdr suite through the REAL caller with bindings
  # derived from the ambient gate worktree, while the local Herdr shard runs.
  rm -f "$fixture/captured" "$fixture/local-runs"
  (cd "$gatewt" && env PATH="$fakebin:$PATH" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='test=behavior-heavy' \
    "$fixture/bin/fm-no-mistakes-test-command.sh") \
    || fail "the remote-selected test step failed with derivable bindings"
  [ -f "$fixture/captured" ] || fail "the test step never reached the fixture runner"
  python3 - "$fixture/captured" "nm-$NM_RUN_FIXTURE" "$gate_head" "$SUB" <<'PY' || fail "the test step did not derive the ambient run bindings"
import sys
argv=open(sys.argv[1]).read().splitlines()
def value(flag): return argv[argv.index(flag)+1]
assert value("--task")==sys.argv[2]
assert value("--generation")==sys.argv[3]
assert value("--confirm-subscription")==sys.argv[4]
assert value("--resource-class")=="behavior-heavy"
assert "bin/fm-azure-runner-command.sh" in argv, "the Azure command lost its guest-relative wrapper"
assert not any(item.endswith("/bin/fm-azure-runner-command.sh") for item in argv), (
    "the Azure payload serialized a host-absolute wrapper", argv
)
declaration="FM_TEST_HOST_CAPABILITIES_ABSENT=real-tmux-server,passwordless-root-escalation,system-openat-binding,origin-egress"
assert declaration in argv, "the Azure shard lost its reviewed Linux host-capability declaration"
assert any("tests/run.sh --skip-herdr" in item for item in argv), "the Azure shard lost the non-Herdr suite"
PY
  assert_capability_derived_local_host_set "$fixture/local-runs"

  # An underivable subscription fails the step closed: exit 1, exact refusal,
  # no host fallback for the non-Herdr suite.
  rm -f "$fixture/captured" "$fixture/local-runs"
  rc=0
  out=$(cd "$gatewt" && env PATH="$fakebin:$PATH" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='test=behavior-heavy' \
    "$fixture/bin/fm-no-mistakes-test-command.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the test step passed while its Azure shard could not dispatch"
  assert_contains "$out" "cannot derive FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION" "the step did not surface the exact refusal"
  [ ! -e "$fixture/captured" ] || fail "a refused derivation still reached the runner"
  grep -q -- "--skip-herdr" "$fixture/local-runs" 2>/dev/null \
    && fail "a refused Azure dispatch fell back to running the non-Herdr suite locally"

  pass "the real test step offloads the non-Herdr suite with derived ambient bindings and fails closed without host fallback"
}

static_private_controller_contract
environment_mode_defaults
public_git_askpass_is_host_portable
storage_network_access_contract
prepare_contract
private_snapshot_prepare_contract
private_snapshot_ancestor_verification
agent_fleet_offline_install_contract
executor_credential_adversary
linux_systemd_drop_integration
spend_ledger_unit
foundation_rbac_read_unit
validation_parent_capacity_contract
cost_retry_unit
retail_rate_unit
quota_snapshot_unit
shared_allocator_bridge_unit
commissioning_admission_unit
run_owned_execution_proof_contract() {
  python3 - "$ROOT/bin/fm-azure-runner.py" <<'PY' \
    || fail "the verified Azure execution identity was not emitted into the run-owned step log"
import contextlib
import importlib.util
import io
import sys

spec = importlib.util.spec_from_file_location("fm_azure_runner", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
state = {
    "invocation": "inv-proof",
    "staging": {"output_blob": "private-proof.tar"},
    "cost": {"max_increment": 1.25},
    "resources": {"vm_instance_id": "11111111-1111-1111-1111-111111111111"},
    "expected_boot_id": "22222222-2222-2222-2222-222222222222",
}
result = {
    "exit_code": 0,
    "timed_out": False,
    "signal": None,
    "stdout_truncated": False,
    "stderr_truncated": False,
}
captured = io.StringIO()
with contextlib.redirect_stderr(captured):
    module.print_logs_and_summary(state, result)
line = captured.getvalue()
assert "invocation=inv-proof" in line, line
assert "exit=0" in line, line
assert "vm_instance_id=11111111-1111-1111-1111-111111111111" in line, line
assert "boot_id=22222222-2222-2222-2222-222222222222" in line, line
assert "unrecorded" not in line, line
PY
  pass "the run-owned step log carries the verified Azure VM instance and boot identities beside the verdict"
}

run_owned_execution_proof_contract
runner_document_contract() {
  python3 - "$ROOT/docs/azure-runner.md" <<'PY' \
    || fail "the runner document no longer pins the per-run routing and execution-proof contract"
import sys

document = open(sys.argv[1], encoding="utf-8").read()
required = (
    "~/.fm-azure/runner-routing/<run-id>.json",
    "does not rely on `FM_HOME`",
    "An absent per-run file executes the class locally",
    "runs the command nowhere",
    "`fm_home` becomes `FM_HOME`",
    "`~/.fm-azure/fleet.env`",
    "FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID",
    "immutable Azure `vm_instance_id`",
    "verified guest `boot_id`",
    "The earlier `selected REMOTE ... (dispatching)` line proves only selection",
)
missing = [needle for needle in required if needle not in document]
assert not missing, missing
obsolete = (
    "export FM_AZURE_RUNNER_REMOTE_CLASSES="
    "'test=behavior-heavy,lint=validation-standard'\n"
    "no-mistakes axi run"
)
assert obsolete not in document, "the disproven env-only no-mistakes recipe returned"
PY
  pass "the runner document owns the per-run file, HOME-owned environment admission, visible local path, and run-owned Azure proof"
}

runner_document_contract
routing_file_contract() {
  local tmp fixture dispatch gatewt routing anchor fmhome expires out rc watcher assignment
  fm_test_tmproot_into tmp fm-azure-runner-routing
  fixture="$tmp/fixture"
  make_dispatch_fixture "$fixture"
  dispatch="$fixture/bin/fm-azure-runner-dispatch.sh"
  gatewt="$tmp/nm-home/worktrees/19543ae8611e/$NM_RUN_FIXTURE"
  make_ambient_worktree "$gatewt"
  routing="$tmp/routing"
  anchor="$tmp/home-anchor"
  fmhome="$anchor/firstmate-home"
  mkdir -p "$routing" "$fmhome/state" "$anchor/.fm-azure"
  cat >"$anchor/.fm-azure/fleet.env" <<ENV
FM_AZURE_TENANT_ID=$SUB
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_NAMING_PREFIX=fmfixture
FM_AZURE_STORAGE_NAME=stfixture001
FM_AZURE_OWNER_TAG=fixture-owner
FM_AZURE_DEPLOYMENT_GENERATION=fixture-generation
FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID=$SUB
FM_AZURE_RESOURCE_GROUP=rg-fixture
ENV
  chmod 600 "$anchor/.fm-azure/fleet.env"
  expires=$(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)+d.timedelta(hours=6)).strftime("%Y-%m-%dT%H:%M:%SZ"))')

  write_routing() {  # <python-dict-overrides>
    python3 - "$routing/$NM_RUN_FIXTURE.json" "$fmhome" "$SUB" "$expires" "$NM_RUN_FIXTURE" "$1" <<'PY'
import json,sys
value={
  "schema":"fm.azure-runner-routing/v1","run_id":sys.argv[5],
  "classes":{"lint":"validation-standard"},"fm_home":sys.argv[2],
  "subscription":sys.argv[3],"expires_at":sys.argv[4],"max_dispatches":3,
}
value.update(json.loads(sys.argv[6]))
for key in [k for k,v in value.items() if v is None]:
    del value[key]
open(sys.argv[1],"w").write(json.dumps(value,indent=2)+"\n")
PY
    chmod 600 "$routing/$NM_RUN_FIXTURE.json"
  }

  dispatch_here() {  # runs the real dispatch in the gate worktree
    (cd "$gatewt" && env HOME="$anchor" FM_AZURE_RUNNER_ROUTING_ROOT="$routing" \
      FM_AZURE_RUNNER_STATE_DIR="$tmp/ambient-runner-state" \
      FM_AZURE_SHARED_CAPACITY_STATE_DIR="$tmp/ambient-shared-state" \
      "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1)
  }

  expect_refusal() {  # <needle> <what>
    rm -f "$fixture/captured" "$tmp/ran-locally"
    local rc=0 out
    out=$(dispatch_here) || rc=$?
    [ "$rc" -ne 0 ] || fail "$2: a broken routing file did not refuse"
    assert_contains "$out" "$1" "$2: the refusal did not name the reason"
    [ ! -e "$fixture/captured" ] || fail "$2: a broken routing file still dispatched to Azure"
    [ ! -e "$tmp/ran-locally" ] || fail "$2: a broken routing file fell back to silent local execution"
  }

  write_raw_routing() {  # <exact-json>
    printf '%s\n' "$1" >"$routing/$NM_RUN_FIXTURE.json"
    chmod 600 "$routing/$NM_RUN_FIXTURE.json"
  }

  # R1. ABSENT is safe: local execution, exactly today's default, and it SAYS SO.
  # The line is what turns a routing file written too late - the run id cannot
  # exist before the run starts - into a visible fact instead of a silent
  # fallback, so it is asserted, not assumed.
  rm -f "$fixture/captured" "$tmp/ran-locally"
  out=$(dispatch_here) || fail "an absent routing file did not execute locally"
  [ -e "$tmp/ran-locally" ] || fail "an absent routing file did not run the command locally"
  [ ! -e "$fixture/captured" ] || fail "an absent routing file reached the runner"
  assert_contains "$out" "executed LOCALLY (routing=absent, env=absent)" \
    "a local execution did not announce itself distinguishably"

  # R2. A valid selection dispatches with the file's OWN bindings. fm_home and
  # the subscription come from the file rather than the environment, because the
  # step has neither and fm_home selects which spend ledger the run writes to.
  write_routing '{}'
  rm -f "$fixture/captured" "$tmp/ran-locally" "$fixture/captured-env"
  out=$(dispatch_here) || fail "a valid routing selection failed to dispatch"
  [ -e "$fixture/captured" ] || fail "a valid routing selection never reached the runner"
  [ ! -e "$tmp/ran-locally" ] || fail "a dispatched class also ran locally"
  assert_contains "$out" "selected REMOTE resource-class=validation-standard" \
    "the dispatch did not announce its remote selection"
  python3 - "$fixture/captured" "$fixture/captured-env" "$fmhome" "$SUB" <<'PY' \
    || fail "the routing file's own bindings were not passed to the runner"
import sys
argv=open(sys.argv[1]).read().splitlines()
env=dict(line.split("=",1) for line in open(sys.argv[2]).read().splitlines())
def value(flag): return argv[argv.index(flag)+1]
assert value("--resource-class")=="validation-standard", argv
assert value("--confirm-subscription")==sys.argv[4], argv
assert env["FM_HOME"]==sys.argv[3], env
assert env["FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION"]==sys.argv[4], env
assert env["FM_AZURE_TENANT_ID"]==sys.argv[4], env
assert env["FM_AZURE_SUBSCRIPTION_ID"]==sys.argv[4], env
assert env["FM_AZURE_NAMING_PREFIX"]=="fmfixture", env
assert env["FM_AZURE_STORAGE_NAME"]=="stfixture001", env
assert env["FM_AZURE_OWNER_TAG"]=="fixture-owner", env
assert env["FM_AZURE_DEPLOYMENT_GENERATION"]=="fixture-generation", env
assert env["FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID"]==sys.argv[4], env
assert env["FM_AZURE_RESOURCE_GROUP"]=="rg-fixture", env
assert env["FM_AZURE_RUNNER_TASK"]=="", env
assert env["FM_AZURE_RUNNER_GENERATION"]=="", env
assert env["FM_AZURE_RUNNER_STATE_DIR"]=="", env
assert env["FM_AZURE_SHARED_CAPACITY_STATE_DIR"]=="", env
PY

  # The real runner requires more than FM_HOME and a confirmation. A selected
  # daemon step has only HOME/PATH, so the operator-owned Azure environment is
  # part of remote admission rather than an ambient assumption.
  write_routing '{}'
  mv "$anchor/.fm-azure/fleet.env" "$anchor/.fm-azure/fleet.env.off"
  expect_refusal "operator Azure environment file" "a missing operator Azure environment"
  mv "$anchor/.fm-azure/fleet.env.off" "$anchor/.fm-azure/fleet.env"

  write_routing '{}'
  sed 's/^FM_AZURE_SUBSCRIPTION_ID=.*/FM_AZURE_SUBSCRIPTION_ID=11111111-1111-1111-1111-111111111111/' \
    "$anchor/.fm-azure/fleet.env" >"$anchor/.fm-azure/fleet.env.mismatch"
  mv "$anchor/.fm-azure/fleet.env.mismatch" "$anchor/.fm-azure/fleet.env"
  chmod 600 "$anchor/.fm-azure/fleet.env"
  expect_refusal "does not match the operator Azure environment subscription" \
    "a mismatched subscription confirmation"
  sed 's/^FM_AZURE_SUBSCRIPTION_ID=.*/FM_AZURE_SUBSCRIPTION_ID='"$SUB"'/' \
    "$anchor/.fm-azure/fleet.env" >"$anchor/.fm-azure/fleet.env.restored"
  mv "$anchor/.fm-azure/fleet.env.restored" "$anchor/.fm-azure/fleet.env"
  chmod 600 "$anchor/.fm-azure/fleet.env"

  # fleet.env may carry only the explicit infrastructure allowlist. Per-run
  # selectors, identity, confirmation, and any state-directory control are
  # categorically not inputs to a routing-file dispatch.
  cp "$anchor/.fm-azure/fleet.env" "$anchor/.fm-azure/fleet.env.base"
  for assignment in \
    "FM_AZURE_RUNNER_REMOTE_CLASSES=lint=validation-standard" \
    "FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES=lint" \
    "FM_AZURE_RUNNER_ROUTING_ROOT=$routing" \
    "FM_AZURE_RUNNER_TASK=foreign-task" \
    "FM_AZURE_RUNNER_GENERATION=foreign-generation" \
    "FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION=$SUB" \
    "FM_AZURE_RUNNER_STATE_DIR=$tmp/foreign-runner-state" \
    "FM_AZURE_SHARED_CAPACITY_STATE_DIR=$tmp/foreign-shared-state" \
    "FM_AZURE_WORKER_STATE_DIR=$tmp/foreign-worker-state"; do
    cp "$anchor/.fm-azure/fleet.env.base" "$anchor/.fm-azure/fleet.env"
    printf '%s\n' "$assignment" >>"$anchor/.fm-azure/fleet.env"
    chmod 600 "$anchor/.fm-azure/fleet.env"
    write_routing '{}'
    expect_refusal "may not declare per-run control ${assignment%%=*}" \
      "a fleet environment carrying ${assignment%%=*}"
  done
  mv "$anchor/.fm-azure/fleet.env.base" "$anchor/.fm-azure/fleet.env"
  chmod 600 "$anchor/.fm-azure/fleet.env"

  # Non-control Azure names outside the fixed infrastructure allowlist are
  # ignored rather than exported into the runner environment.
  printf '%s\n' 'FM_AZURE_FUTURE_DIAGNOSTIC=ignored' >>"$anchor/.fm-azure/fleet.env"
  write_routing '{}'
  dispatch_here >/dev/null \
    || fail "an unknown non-control fleet value disrupted the infrastructure allowlist"
  sed '/^FM_AZURE_FUTURE_DIAGNOSTIC=/d' "$anchor/.fm-azure/fleet.env" \
    >"$anchor/.fm-azure/fleet.env.restored"
  mv "$anchor/.fm-azure/fleet.env.restored" "$anchor/.fm-azure/fleet.env"
  chmod 600 "$anchor/.fm-azure/fleet.env"

  # The resolver must hand the dispatch exact values read from the validated
  # fleet.env inode, not return its pathname for a later check-then-source.
  # Replacing that pathname as soon as the durable spend lands must therefore
  # neither inject replacement values nor invalidate the admitted dispatch.
  write_routing '{"max_dispatches": 1}'
  sed 's/^FM_AZURE_SUBSCRIPTION_ID=.*/FM_AZURE_SUBSCRIPTION_ID=11111111-1111-1111-1111-111111111111/' \
    "$anchor/.fm-azure/fleet.env" >"$anchor/.fm-azure/fleet.env.replacement"
  chmod 600 "$anchor/.fm-azure/fleet.env.replacement"
  python3 - "$routing/$NM_RUN_FIXTURE.json" "$anchor/.fm-azure/fleet.env.replacement" \
    "$anchor/.fm-azure/fleet.env" <<'PY' &
import json, os, pathlib, sys, time
route, replacement, live = map(pathlib.Path, sys.argv[1:])
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    try:
        if json.loads(route.read_text()).get("dispatched") == 1:
            os.replace(replacement, live)
            raise SystemExit(0)
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    time.sleep(0.001)
raise SystemExit(91)
PY
  watcher=$!
  rm -f "$fixture/captured" "$tmp/ran-locally" "$fixture/captured-env"
  dispatch_here >/dev/null \
    || fail "a pathname replacement after fleet environment admission changed the dispatch"
  wait "$watcher" \
    || fail "the fleet environment race fixture never observed the durable dispatch spend"
  python3 - "$fixture/captured-env" "$SUB" <<'PY' \
    || fail "the dispatch did not retain values from the exact admitted fleet environment inode"
import sys
env=dict(line.split("=",1) for line in open(sys.argv[1]).read().splitlines())
assert env["FM_AZURE_SUBSCRIPTION_ID"] == sys.argv[2], env
PY
  sed 's/^FM_AZURE_SUBSCRIPTION_ID=.*/FM_AZURE_SUBSCRIPTION_ID='"$SUB"'/' \
    "$anchor/.fm-azure/fleet.env" >"$anchor/.fm-azure/fleet.env.restored"
  mv "$anchor/.fm-azure/fleet.env.restored" "$anchor/.fm-azure/fleet.env"
  chmod 600 "$anchor/.fm-azure/fleet.env"

  # R3. The budget is durable: max_dispatches=1 spends once, then refuses.
  write_routing '{"max_dispatches": 1}'
  rm -f "$fixture/captured"
  dispatch_here >/dev/null || fail "the first dispatch inside budget failed"
  [ -e "$fixture/captured" ] || fail "the first dispatch never reached the runner"
  expect_refusal "spent its dispatch budget" "an exhausted budget"

  # The budget is also atomic across the parallel steps of one no-mistakes
  # run. A lock on the routing-file inode is insufficient because consuming a
  # dispatch replaces that inode: every resolver must serialize on one stable
  # authority and re-read the budget while it owns that lock.
  write_routing '{"max_dispatches": 1}'
  mkdir -p "$tmp/concurrent-results"
  for index in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    (
      set +e
      env HOME="$anchor" FM_AZURE_RUNNER_ROUTING_ROOT="$routing" \
        "$fixture/bin/fm-azure-runner-routing.py" resolve \
        --run-id "$NM_RUN_FIXTURE" --class lint \
        >"$tmp/concurrent-results/$index.out" 2>"$tmp/concurrent-results/$index.err"
      printf '%s\n' "$?" >"$tmp/concurrent-results/$index.rc"
    ) &
  done
  wait
  selected=$(grep -l '^0$' "$tmp/concurrent-results"/*.rc | wc -l | tr -d ' ')
  [ "$selected" -eq 1 ] \
    || fail "one dispatch slot was consumed by $selected parallel resolvers instead of exactly one"

  # R4. A file that exists but does not select this class is a SELECTION, not a
  # fault: local, and distinguishable from absent.
  write_routing '{"classes": {"test": "behavior-heavy"}}'
  rm -f "$fixture/captured" "$tmp/ran-locally"
  out=$(dispatch_here) || fail "an unselected class did not execute locally"
  [ -e "$tmp/ran-locally" ] || fail "an unselected class did not run locally"
  assert_contains "$out" "routing=present-not-selected" \
    "a present-but-unselected file was not distinguishable from an absent one"

  # R5. PRESENT-BUT-BROKEN never falls back to local. Every shape refuses BY NAME
  # and the command runs NOWHERE.
  write_routing '{"schema": "fm.azure-runner-routing/v99"}'
  expect_refusal "declares schema" "a wrong schema"
  write_routing '{"subscription": null}'
  expect_refusal "missing required field" "a missing field"
  write_routing '{"expires_at": "2020-01-01T00:00:00Z"}'
  expect_refusal "expired at" "an expired window"
  write_routing '{"run_id": "01ZZZZZZZZZZZZZZZZZZZZZZZZ"}'
  expect_refusal "is bound to run" "a file bound to another run"
  write_routing '{"fm_home": "/nonexistent/ledger"}'
  expect_refusal "not an existing directory" "an unusable fm_home"
  write_routing "{\"fm_home\": \"$tmp/outside-home\"}"
  mkdir -p "$tmp/outside-home"
  expect_refusal "outside" "an fm_home outside the user home"
  mkdir -p "$tmp/escaped-home"
  write_routing "{\"fm_home\": \"$anchor/../escaped-home\"}"
  expect_refusal "parent traversal" "an fm_home that lexically escapes through a parent"
  write_routing '{"classes": {"lint": "not-a-real-class"}}'
  expect_refusal "unknown resource class" "an unknown resource class"
  write_routing '{"classes": {"test": "not-a-real-class"}}'
  expect_refusal "unknown resource class" "an unknown resource class on an unselected command"
  write_routing '{"max_dispatches": 0}'
  expect_refusal "positive whole number" "a non-positive budget"
  write_raw_routing "{\"schema\":\"fm.azure-runner-routing/v1\",\"schema\":\"fm.azure-runner-routing/v1\",\"run_id\":\"$NM_RUN_FIXTURE\",\"classes\":{\"lint\":\"validation-standard\"},\"fm_home\":\"$fmhome\",\"subscription\":\"$SUB\",\"expires_at\":\"$expires\",\"max_dispatches\":3}"
  expect_refusal "duplicate JSON key" "a duplicate top-level key"
  write_raw_routing "{\"schema\":\"fm.azure-runner-routing/v1\",\"run_id\":\"$NM_RUN_FIXTURE\",\"classes\":{\"lint\":\"validation-standard\",\"lint\":\"behavior-heavy\"},\"fm_home\":\"$fmhome\",\"subscription\":\"$SUB\",\"expires_at\":\"$expires\",\"max_dispatches\":3}"
  expect_refusal "duplicate JSON key" "a duplicate nested class key"
  write_routing '{"unexpected_authority":"silently-ignored"}'
  expect_refusal "unknown top-level field" "an undeclared top-level field"
  write_routing '{"expires_at":"2999-01-01T01:00:00+01:00"}'
  expect_refusal "literal UTC Z" "a non-Z UTC offset"
  write_routing '{"expires_at":"2999-01-01T00:00:00.001Z"}'
  expect_refusal "literal UTC Z" "a fractional non-schema UTC timestamp"
  printf '{"schema": "fm.azure-runner-rout' >"$routing/$NM_RUN_FIXTURE.json"
  expect_refusal "not valid JSON" "a torn write"
  : >"$routing/$NM_RUN_FIXTURE.json"
  expect_refusal "torn write" "an empty file"
  write_routing '{}'
  chmod 000 "$routing/$NM_RUN_FIXTURE.json"
  expect_refusal "unreadable" "an unreadable file"
  chmod 600 "$routing/$NM_RUN_FIXTURE.json"
  chmod 666 "$routing/$NM_RUN_FIXTURE.json"
  expect_refusal "group- or world-writable" "a world-writable file"
  rm -f "$routing/$NM_RUN_FIXTURE.json"
  ln -s /dev/null "$routing/$NM_RUN_FIXTURE.json"
  expect_refusal "is a symlink" "a symlinked routing file"
  rm -f "$routing/$NM_RUN_FIXTURE.json"
  mkfifo "$routing/$NM_RUN_FIXTURE.json"
  chmod 600 "$routing/$NM_RUN_FIXTURE.json"
  expect_refusal "is not a regular file" "a FIFO routing path"
  rm -f "$routing/$NM_RUN_FIXTURE.json"
  python3 - "$routing/$NM_RUN_FIXTURE.json" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(b"x" * (64 * 1024 + 1))
PY
  chmod 600 "$routing/$NM_RUN_FIXTURE.json"
  expect_refusal "exceeds the 65536-byte bound" "an oversized routing file"

  # Replacing a checked regular file just before open must not switch the
  # resolver onto a different inode, even when the replacement is also safe.
  write_routing '{}'
  python3 - "$fixture/bin/fm-azure-runner-routing.py" \
    "$routing/$NM_RUN_FIXTURE.json" <<'PY' \
    || fail "a routing pathname replacement was not identity-pinned"
import contextlib
import importlib.util
import io
import os
import pathlib
import sys

spec = importlib.util.spec_from_file_location("routing_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
route = pathlib.Path(sys.argv[2])
replacement = route.with_name(route.name + ".replacement")
replacement.write_text(route.read_text())
replacement.chmod(0o600)
expected = route.lstat()
real_open = module.os.open

def replacing_open(path, flags, *args):
    if pathlib.Path(path) == route:
        os.replace(replacement, route)
    return real_open(path, flags, *args)

module.os.open = replacing_open
stderr = io.StringIO()
try:
    with contextlib.redirect_stderr(stderr):
        module.load_document(route, expected)
except SystemExit as exc:
    assert exc.code == module.EXIT_REFUSED, exc.code
else:
    raise AssertionError("a replacement inode was accepted")
finally:
    module.os.open = real_open
assert "changed while it was opened" in stderr.getvalue(), stderr.getvalue()
PY
  rm -f "$routing/$NM_RUN_FIXTURE.json"

  # Explicit local recovery may override a valid remote selection, but it may
  # not turn a present malformed authority into local execution. Present and
  # broken always means NOWHERE.
  write_routing '{"schema": "fm.azure-runner-routing/v99"}'
  rm -f "$fixture/captured" "$tmp/ran-locally"
  rc=0
  out=$(cd "$gatewt" && env HOME="$anchor" FM_AZURE_RUNNER_ROUTING_ROOT="$routing" \
    FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES=lint \
    "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "explicit local recovery bypassed a malformed routing file"
  assert_contains "$out" "declares schema" \
    "local-recovery refusal did not name the malformed routing file"
  [ ! -e "$fixture/captured" ] && [ ! -e "$tmp/ran-locally" ] \
    || fail "a malformed routing file executed under explicit local recovery"

  # R6. Two authorities that disagree are never silently reconciled.
  write_routing '{}'
  rm -f "$fixture/captured" "$tmp/ran-locally"
  rc=0
  out=$(cd "$gatewt" && env HOME="$anchor" FM_AZURE_RUNNER_ROUTING_ROOT="$routing" \
    FM_AZURE_RUNNER_REMOTE_CLASSES='lint=behavior-heavy' \
    "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a routing/environment disagreement was silently reconciled"
  assert_contains "$out" "disagree on class lint" "the disagreement refusal was not explicit"
  [ ! -e "$fixture/captured" ] && [ ! -e "$tmp/ran-locally" ] \
    || fail "a routing/environment disagreement still executed"

  # R7. THE LOOKUP PATH IS NEVER DERIVED FROM REPOSITORY CONTENT. This is the
  # whole answer to "what stops a checkout carrying one", so it is an asserted
  # invariant rather than a property of today's code: a later refactor that
  # anchors on the worktree or the working directory turns this red.
  rm -f "$routing/$NM_RUN_FIXTURE.json"
  mkdir -p "$gatewt/.fm-azure/runner-routing"
  python3 - "$gatewt/.fm-azure/runner-routing/$NM_RUN_FIXTURE.json" "$fmhome" "$SUB" "$expires" \
    "$NM_RUN_FIXTURE" <<'PY'
import json,sys
open(sys.argv[1],"w").write(json.dumps({
  "schema":"fm.azure-runner-routing/v1","run_id":sys.argv[5],
  "classes":{"lint":"validation-standard"},"fm_home":sys.argv[2],
  "subscription":sys.argv[3],"expires_at":sys.argv[4],"max_dispatches":9,
})+"\n")
PY
  cp "$gatewt/.fm-azure/runner-routing/$NM_RUN_FIXTURE.json" "$gatewt/$NM_RUN_FIXTURE.json"
  mkdir -p "$anchor/.fm-azure/runner-routing"
  rm -f "$fixture/captured" "$tmp/ran-locally"
  # No FM_AZURE_RUNNER_ROUTING_ROOT: the DEFAULT lookup must anchor on $HOME.
  out=$(cd "$gatewt" && env HOME="$anchor" "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1) \
    || fail "the default routing lookup failed"
  [ -e "$tmp/ran-locally" ] || fail "a repository-carried routing file was not ignored"
  [ ! -e "$fixture/captured" ] \
    || fail "a routing file carried inside the checkout selected remote execution"
  assert_contains "$out" "routing=absent" "a repository-carried routing file was consulted"

  # The HOME anchor itself must be lexical, not merely resolved. Otherwise a
  # checkout can carry the authority by replacing $HOME/.fm-azure with a
  # symlink even though the final routing file and directory are both owned and
  # mode-safe.
  symlink_anchor="$tmp/symlink-anchor"
  checkout_authority="$tmp/checkout-authority"
  mkdir -p "$symlink_anchor/firstmate-home/state" \
    "$checkout_authority/.fm-azure/runner-routing"
  ln -s "$checkout_authority/.fm-azure" "$symlink_anchor/.fm-azure"
  python3 - "$checkout_authority/.fm-azure/runner-routing/$NM_RUN_FIXTURE.json" \
    "$symlink_anchor/firstmate-home" "$SUB" "$expires" "$NM_RUN_FIXTURE" <<'PY'
import json,sys
open(sys.argv[1],"w").write(json.dumps({
  "schema":"fm.azure-runner-routing/v1","run_id":sys.argv[5],
  "classes":{"lint":"validation-standard"},"fm_home":sys.argv[2],
  "subscription":sys.argv[3],"expires_at":sys.argv[4],"max_dispatches":1,
})+"\n")
PY
  chmod 600 "$checkout_authority/.fm-azure/runner-routing/$NM_RUN_FIXTURE.json"
  rm -f "$fixture/captured" "$tmp/ran-locally"
  rc=0
  out=$(cd "$gatewt" && env HOME="$symlink_anchor" \
    "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a checkout-carried authority was followed through a HOME symlink"
  assert_contains "$out" "is a symlink" \
    "a checkout-carried authority did not name the symlinked HOME path"
  [ ! -e "$fixture/captured" ] && [ ! -e "$tmp/ran-locally" ] \
    || fail "a checkout-carried authority still executed"

  # R8. ...and the default DOES read $HOME, so R7 proves indifference to the
  # checkout rather than a lookup that never resolves anything at all.
  cp "$gatewt/.fm-azure/runner-routing/$NM_RUN_FIXTURE.json" \
    "$anchor/.fm-azure/runner-routing/$NM_RUN_FIXTURE.json"
  chmod 600 "$anchor/.fm-azure/runner-routing/$NM_RUN_FIXTURE.json"
  rm -f "$fixture/captured" "$tmp/ran-locally"
  (cd "$gatewt" && env HOME="$anchor" "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" >/dev/null 2>&1) \
    || fail "the default HOME-anchored routing lookup failed to dispatch"
  [ -e "$fixture/captured" ] || fail "the default routing root does not resolve under \$HOME"

  # R9. Outside a gate worktree there is no run identity, so routing cannot
  # apply and the environment variable remains the only selector.
  make_ambient_worktree "$tmp/plain"
  rm -f "$fixture/captured" "$tmp/ran-locally"
  out=$(cd "$tmp/plain" && env HOME="$anchor" "$dispatch" lint -- sh -c "touch '$tmp/ran-locally'" 2>&1) \
    || fail "a non-gate worktree failed to execute locally"
  [ -e "$tmp/ran-locally" ] || fail "a non-gate worktree did not run locally"
  assert_contains "$out" "routing=absent" "a non-gate worktree did not report an absent routing"

  pass "per-run routing selects a class from a file the run can carry, an absent file stays local and says so, and every present-but-broken file refuses by name and runs the command nowhere"
}

apt_lock_wait_contract() {
  local tmp helpers lock ready release holder_pid release_pid out rc call_log attempts
  tmp=$(mktemp -d)
  helpers="$tmp/apt-lock-helpers.sh"
  awk '
    /BEGIN FM_AZURE_RUNNER_APT_LOCK_HELPERS/ {emit=1; next}
    /END FM_AZURE_RUNNER_APT_LOCK_HELPERS/ {emit=0}
    emit
  ' "$GUEST" >"$helpers"
  bash -n "$helpers" || fail "the extracted Azure runner apt-lock helpers are invalid"
  # shellcheck source=/dev/null
  . "$helpers"

  lock="$tmp/lock-frontend"
  ready="$tmp/ready"
  release="$tmp/release"
  python3 - "$lock" "$ready" "$release" <<'PY' &
import fcntl
import os
from pathlib import Path
import sys
import time

descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
fcntl.lockf(descriptor, fcntl.LOCK_EX)
Path(sys.argv[2]).touch()
while not Path(sys.argv[3]).exists():
    time.sleep(0.01)
os.close(descriptor)
PY
  holder_pid=$!
  fm_test_wait_for_file "$ready" "$holder_pid" 0.02 \
    || fail "the apt-lock release regression did not acquire its fixture lock"
  (sleep 0.15; touch "$release") &
  release_pid=$!
  wait_for_apt_locks 2 0.02 "$lock" \
    || fail "the guest bootstrap did not continue after a normal apt lock released"
  wait "$release_pid" || fail "the apt-lock release fixture failed"
  wait "$holder_pid" || fail "the apt-lock holder failed"
  call_log="$tmp/apt-call"
  APT_LOCK_WAIT_SECONDS=1
  APT_LOCK_PATHS=("$lock")
  wait_for_apt_locks "$APT_LOCK_WAIT_SECONDS" 0.02 "${APT_LOCK_PATHS[@]}" \
    || fail "the test apt lock set was not available for wrapper execution"
  # shellcheck disable=SC2329 # Invoked indirectly by the extracted run_bootstrap_apt helper.
  run_bootstrap_network() { printf '%s\n' "$*" >"$call_log"; }
  run_bootstrap_apt install -y fixture-package \
    || fail "the bounded apt wrapper did not reach apt-get after lock admission"
  [ "$(<"$call_log")" = \
    "apt-get -o DPkg::Lock::Timeout=1 install -y fixture-package" ] \
    || fail "the executable apt wrapper lost its dpkg timeout or package arguments"

  attempts="$tmp/apt-attempts"
  printf '0\n' >"$attempts"
  run_bootstrap_network() {
    local count
    count=$(<"$attempts")
    count=$((count + 1))
    printf '%s\n' "$count" >"$attempts"
    if [ "$count" -eq 1 ]; then
      echo "E: Could not get lock $lock. It is held by process 42" >&2
      return 100
    fi
    return 0
  }
  APT_LOCK_WAIT_SECONDS=2
  run_bootstrap_apt update -qq \
    || fail "the apt wrapper did not retry an invocation-boundary lock race"
  [ "$(<"$attempts")" -eq 2 ] \
    || fail "the apt wrapper did not perform exactly one lock-race retry"

  ready="$tmp/ready-timeout"
  release="$tmp/release-timeout"
  python3 - "$lock" "$ready" "$release" <<'PY' &
import fcntl
import os
from pathlib import Path
import sys
import time

descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
fcntl.lockf(descriptor, fcntl.LOCK_EX)
Path(sys.argv[2]).touch()
while not Path(sys.argv[3]).exists():
    time.sleep(0.01)
os.close(descriptor)
PY
  holder_pid=$!
  fm_test_wait_for_file "$ready" "$holder_pid" 0.02 \
    || fail "the apt-lock timeout regression did not acquire its fixture lock"
  set +e
  out=$(wait_for_apt_locks 0.1 0.02 "$lock" 2>&1)
  rc=$?
  set -e
  touch "$release"
  wait "$holder_pid" || fail "the timed-out apt-lock holder failed"
  [ "$rc" -ne 0 ] || fail "the guest bootstrap waited forever on an apt lock"
  assert_contains "$out" "timed out waiting for apt/dpkg lock(s): $lock" \
    "the bounded apt-lock refusal did not name the held lock"

  pass "Azure runner bootstrap waits for apt/dpkg maintenance races and times out deterministically"
}

no_mistakes_yaml_test_route_contract() {
  local tmp fixture command local_marker shard_marker
  tmp=$(mktemp -d)
  fixture="$tmp/repo"
  local_marker="$tmp/local-route"
  shard_marker="$tmp/shard-route"
  mkdir -p "$fixture/bin"
  command=$(python3 - "$ROOT/.no-mistakes.yaml" <<'PY'
from pathlib import Path
import sys

prefix = "  test: '"
values = [
    line[len(prefix):-1].replace("''", "'")
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.startswith(prefix) and line.endswith("'")
]
if len(values) != 1:
    raise SystemExit("expected one single-line commands.test scalar")
print(values[0])
PY
  ) \
    || fail "the no-mistakes test command could not be loaded from YAML"
  [ -n "$command" ] || fail "the no-mistakes YAML has no test command"

  printf '#!/usr/bin/env bash\nprintf "local\\n" >%q\n' "$local_marker" \
    >"$fixture/bin/fm-no-mistakes-test-command.sh"
  printf '#!/usr/bin/env bash\nprintf "shard\\n" >%q\n' "$shard_marker" \
    >"$fixture/shard-bridge"
  chmod +x "$fixture/bin/fm-no-mistakes-test-command.sh" "$fixture/shard-bridge"

  (cd "$fixture" && env -u FM_AZURE_VALIDATION_CELL \
    FM_AZURE_VALIDATION_SHARD_BRIDGE="$fixture/shard-bridge" bash -c "$command") \
    || fail "the no-mistakes YAML local test route failed"
  [ -e "$local_marker" ] || fail "the no-mistakes YAML local test route bypassed its wrapper"
  [ ! -e "$shard_marker" ] || fail "the no-mistakes YAML local test route invoked the shard bridge"

  rm -f "$local_marker" "$shard_marker"
  (cd "$fixture" && env FM_AZURE_VALIDATION_CELL=1 \
    FM_AZURE_VALIDATION_SHARD_BRIDGE="$fixture/shard-bridge" bash -c "$command") \
    || fail "the no-mistakes YAML validation-cell test route failed"
  [ -e "$shard_marker" ] || fail "the no-mistakes YAML validation-cell route bypassed the shard bridge"
  [ ! -e "$local_marker" ] || fail "the no-mistakes YAML validation-cell route invoked the local wrapper"

  rm -rf "$tmp"
  pass "no-mistakes YAML test routing executes the local wrapper and validation shard bridge exclusively"
}

apt_lock_wait_contract
dispatch_ambient_binding_contract
no_mistakes_test_step_offload_contract
routing_file_contract
no_mistakes_yaml_test_route_contract

echo "# fm-azure-runner.test.sh: all assertions passed"
