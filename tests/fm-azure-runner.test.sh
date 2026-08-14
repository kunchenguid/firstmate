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
PY
  rm -rf "$home"
  pass "normal environment defaults to strict without commissioning evidence or confirmation variables"
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
assert "ssh" not in json.dumps(vm["properties"]["osProfile"]).lower()
assert "customdata" not in json.dumps(template).lower()
for value in ("PrivateNetwork=yes","RestrictAddressFamilies=AF_UNIX","IPAddressDeny=any","CapabilityBoundingSet=CAP_SETUID CAP_SETGID","AmbientCapabilities=","NoNewPrivileges=yes"):
    assert value in guest
run_at=guest.index("systemd-run --quiet")
input_token_at=guest.index("metadata/identity/oauth2/token")
output_token_at=guest.rindex("metadata/identity/oauth2/token")
assert input_token_at < guest.index('rm -f "$TOKEN_FILE"',input_token_at) < run_at < output_token_at
assert '/usr/bin/python3 "$EXECUTOR"' in guest
assert "https://files.pythonhosted.org/packages/*.whl" in guest
assert 'repository"].get("source_ancestors", [])' in guest
assert 'git -C /work/repo fetch --depth=1 origin "$ancestor"' in guest
assert 'fetch_exact "$url"' in guest and '--location' not in guest[guest.index('while IFS=$\'\\t\' read -r url'):guest.index('done <"$BASE/wheels.tsv"')]
assert "protectedParameters" not in host
assert "generate-sas" not in host
assert "controller_identity_client_id" in host
assert "If-Match=" in host and "runner-cost-reservation" in host
start=host.index("def dispatch_prepared")
assert host.index("shared_capacity_reserve(env, state, cost)", start) < host.index("create_vm(env, state)", start)
assert host.index("lease.renew_and_assert()", start) < host.index("create_vm(env, state)", start)
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
m.public_origin_proof=lambda *_a,**_k:{"remote":"https://github.com/Ruby-Labs/cloud-host-owner.git","default_ref":"refs/heads/main","default_head":"d"*40,"source_ref":"refs/heads/topic","source_head":head,"tree":tree}
args=argparse.Namespace(repo=str(repo),task="azv-aaaaaaaaaaaa-s1",generation="round-aaaaaaaaaaaa",resource_class="behavior-heavy",source_ref="refs/heads/topic",private_snapshot_bundle=str(bundle),capacity_parent="azv-aaaaaaaaaaaa",capacity_reservation_vcpus=40,wall_seconds=None,dependency=[],artifact=[],command=["true"],invocation="azr-aaaaaaaaaaaa")
state=m.prepare(env,args)
r=state["request"]["repository"]
assert r["source_mode"]=="private-parent-bundle" and r["source_head"]==head and r["tree"]==tree
assert r["snapshot_bytes"]==bundle.stat().st_size and r["input_blob"].endswith("/snapshot.bundle")
assert pathlib.Path(state["input_path"]).parent.joinpath("snapshot.bundle").read_bytes()==bundle.read_bytes()
# A bundle with any source ref other than the exact declared one refuses.
bad=repo.parent/"bad.bundle"; m.run(["git","-C",str(repo),"branch","extra","HEAD"]); m.run(["git","-C",str(repo),"bundle","create",str(bad),"refs/heads/topic","refs/heads/extra"])
args.invocation="azr-bbbbbbbbbbbb"; args.private_snapshot_bundle=str(bad)
try: m.prepare(env,args)
except m.RunnerError as exc: assert "only the exact source-ref head" in str(exc)
else: raise AssertionError("multi-ref private snapshot accepted")
PY
  pass "private parent prepare binds one exact source ref/head/tree/bundle/blob without requiring an early push"
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

management_fencing_unit() {
  python3 - "$HOST" <<'PY'
import datetime as dt, importlib.util, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","control_storage":"stctl","deployment_generation":"gen","state_dir":__import__('pathlib').Path('/tmp'),"azure_operation_count":0}
state={"invocation":"azr-aaaaaaaaaaaa","request":{"fence":"sha256:"+"a"*64}}
metadata={"schema":"fm-azure-runner-control-v1","deploymentgeneration":"gen","lockowner":"","lockfence":"","lockexpiry":""}; etag=['E1']
def az(_env,args,**kwargs):
    if args[:2]==["resource","show"]: return {"etag":etag[0],"properties":{"metadata":dict(metadata)}},0,""
    if args[:2]==["rest","--method"]:
        header=next(x for x in args if x.startswith("If-Match="))
        if header != "If-Match="+etag[0]: return None,1,"412"
        body=__import__('json').loads(args[args.index("--body")+1]); metadata.clear(); metadata.update(body["properties"]["metadata"]); etag[0]="E"+str(int(etag[0][1:])+1); return {"etag":etag[0]},0,""
    raise AssertionError(args)
m.az_command=az; m.time.sleep=lambda _:None
a=m.ManagementAdmissionLease(env,state); a.__enter__()
metadata.update({"lockowner":"azr-bbbbbbbbbbbb","lockfence":"b"*64,"lockexpiry":m.iso_utc(m.now_utc()+dt.timedelta(seconds=60))}); etag[0]="E99"
try: a.renew_and_assert()
except m.RunnerError: pass
else: raise AssertionError("stale writer renewed successor lock")
assert a.failed.is_set()
# A hung/throwing renewal is sticky and admission cannot locally outlive it.
b=m.ManagementAdmissionLease(env,state); b.expires_at=m.time.monotonic()+1
b._read=lambda: (_ for _ in ()).throw(m.RunnerError("timeout"))
try: b.renew_and_assert()
except m.RunnerError: pass
else: raise AssertionError("timeout renewal passed")
assert b.failed.is_set()
try: b.assert_held()
except m.RunnerError: pass
else: raise AssertionError("failed renewal was forgotten")
# Eight contenders may read one free ETag, but exactly one stale snapshot can win the ARM CAS.
metadata.clear(); metadata.update({"schema":"fm-azure-runner-control-v1","deploymentgeneration":"gen","lockowner":"","lockfence":"","lockexpiry":""}); etag[0]="E200"
contenders=[]
for i in range(8):
    invocation="azr-{:012x}".format(i+1); fence=("{:x}".format(i+1))*64
    contender=m.ManagementAdmissionLease(env,{"invocation":invocation,"request":{"fence":"sha256:"+fence}})
    snapshot,snapshot_etag=contender._read(); snapshot.update({"lockowner":invocation,"lockfence":fence,"lockexpiry":m.iso_utc(m.now_utc()+dt.timedelta(seconds=60))})
    contenders.append((contender,snapshot_etag,snapshot))
winners=[]
for contender,snapshot_etag,snapshot in contenders:
    try: contender._cas(snapshot_etag,snapshot); winners.append(contender.state["invocation"])
    except m.RunnerError: pass
assert len(winners)==1 and metadata["lockowner"]==winners[0]
PY
  pass "management ETag CAS rejects stale successor clobber, admits one of eight interleaved writers, and fails hung renewal sticky"
}

effective_rbac_adversaries() {
  python3 - "$HOST" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","prefix":"prefix"}
seen=[]
def az(_env,args,**kwargs):
    seen.append(args)
    return ([{"scope":"/subscriptions/sub","roleDefinitionId":"/role/owner","principalId":"group"}],0,"")
m.az_command=az
for label in ("direct","parent inherited","group derived"):
    try: m.require_zero_effective_rbac(env,"principal",label)
    except m.RunnerError: pass
    else: raise AssertionError(label+" assignment accepted")
assert all("--include-inherited" in args and "--include-groups" in args and "--all" in args for args in seen)
m.az_command=lambda *_a,**_k: ({"not":"a list"},0,"")
try: m.require_zero_effective_rbac(env,"principal","unreadable")
except m.RunnerError: pass
else: raise AssertionError("unreadable effective RBAC accepted")
reservation_id="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-prefix-rsv-aaaaaaaaaaaa"
identity={"id":reservation_id,"location":"eastus","etag":"E","properties":{"principalId":"p"},"tags":{"workload":"firstmate","firstmate-role":"runner-cost-reservation","deployment-generation":"gen","cleanup-owner":"owner","invocation-binding":"azr-aaaaaaaaaaaa","fence-digest":"a"*64,"lineage-root":"azr-aaaaaaaaaaaa","parent-invocation":"none","amount-microusd":"1","cost-admission-mode":"strict","cell-ordinal":"none","selected-sku":"Standard_D4as_v6","sku-family":"standardDav6Family","reserved-at":"2026-01-01T00:00:00Z","compute-deadline":"2026-01-02T00:00:00Z","cleanup-verified-at":"none","reservation-principal":"p"}}
env.update({"deployment_generation":"gen","owner":"owner"})
calls=[]
def reservation_az(_env,args,**kwargs):
    calls.append(args)
    if args[:2]==["identity","list"]: return ([identity],0,"")
    if args[:2]==["resource","show"]: return (identity,0,"")
    if args[:3]==["role","assignment","list"]: return ([{"scope":"/subscriptions/sub"}],0,"")
    raise AssertionError(args)
m.az_command=reservation_az
try: m.list_management_reservations(env)
except m.RunnerError: pass
else: raise AssertionError("authorized reservation principal accepted")
assert any(args[:3]==["role","assignment","list"] for args in calls)
m.az_command=lambda *_a,**_k: ([{"identity":{"userAssignedIdentities":{"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-prefix-rsv-aaaaaaaaaaaa":{}}},"tags":{},"powerState":"VM running"}],0,"")
try: m.active_runner_vms(env)
except m.RunnerError: pass
else: raise AssertionError("VM-attached reservation identity accepted")
PY
  pass "direct, inherited, group, unreadable, replacement, and VM-attached reservation RBAC adversaries refuse"
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

commissioning_inventory_role_overlap_unit() {
  python3 - "$HOST" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
controller={"id":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-prefix-validation-shards","name":"id-prefix-validation-shards","type":"Microsoft.ManagedIdentity/userAssignedIdentities","tags":{"firstmate-role":"validation-shard"}}
expected={("microsoft.managedidentity/userassignedidentities","id-prefix-validation-shards")}
disposable,reservations=m.partition_commissioning_inventory([controller],expected)
assert disposable==[] and reservations==[]
runner_vm={"id":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-prefix-run-aaaaaaaaaaaa","name":"vm-prefix-run-aaaaaaaaaaaa","type":"Microsoft.Compute/virtualMachines","tags":{"firstmate-role":"validation-shard","invocation-binding":"azr-aaaaaaaaaaaa"}}
disposable,reservations=m.partition_commissioning_inventory([controller,runner_vm],expected)
assert disposable==[runner_vm] and reservations==[]
foreign={"id":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-foreign","name":"id-foreign","type":"Microsoft.ManagedIdentity/userAssignedIdentities","tags":{"firstmate-role":"validation-shard"}}
try: m.partition_commissioning_inventory([controller,foreign],expected)
except m.RunnerError as exc: assert "zero foreign" in str(exc)
else: raise AssertionError("foreign role-tagged managed identity bypassed exact foundation inventory")
foreign_vm={**runner_vm,"type":"Microsoft.Network/publicIPAddresses","name":"pip-foreign"}
try: m.partition_commissioning_inventory([controller,foreign_vm],expected)
except m.RunnerError as exc: assert "zero foreign" in str(exc)
else: raise AssertionError("foreign validation-shard role on an unapproved disposable type bypassed inventory")
PY
  pass "foundation controller UAMI survives overlapping role classification while foreign role-tagged resources refuse"
}

mixed_pool_capacity_unit() {
  python3 - "$HOST" <<'PY'
import importlib.util, pathlib, tempfile, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","max_concurrency":16,"state_dir":pathlib.Path(tempfile.mkdtemp()),"azure_operation_count":0}
caps=lambda memory:[{"name":"vCPUsAvailable","value":"4"},{"name":"MemoryGB","value":str(memory)},{"name":"CpuArchitectureType","value":"x64"},{"name":"HyperVGenerations","value":"V1,V2"},{"name":"TrustedLaunchDisabled","value":"False"},{"name":"EncryptionAtHostSupported","value":"True"}]
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
m.runner_quota_snapshot=lambda *_:snapshot
base=dict(m.RESOURCE_CLASSES["behavior-heavy"])
def state_for(ordinal,invocation=None):
    sku=m.COMMISSIONING_SKU_POOL[(ordinal-1)//2]; invocation=invocation or "azr-{:012x}".format(ordinal)
    limits={**base,"sku":sku,"sku_family":m.SKU_FAMILY[sku]}
    return {"schema":m.SCHEMA,"invocation":invocation,"request":{"cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE,"cell_ordinal":ordinal,"limits":limits}}
def reservation_for(state):
    request=state["request"]; m.save_state(env,state,create=True)
    return {"invocation-binding":state["invocation"],"cell_ordinal":request["cell_ordinal"],"selected-sku":request["limits"]["sku"],"sku-family":request["limits"]["sku_family"]}
reservations=[]; states=[]
# Simulate eight callers serialized from one stale zero-usage snapshot: every exact slot wins once and no family exceeds two.
for ordinal in range(1,9):
    state=state_for(ordinal); m.commissioning_capacity_gate(env,state,reservations,[]); reservations.append(reservation_for(state)); states.append(state)
assert len(reservations)==8 and all(sum(r["selected-sku"]==sku for r in reservations)<=2 for sku in m.COMMISSIONING_SKU_POOL)
for ordinal in range(9,17):
    state=state_for(ordinal); m.commissioning_capacity_gate(env,state,reservations,[]); reservations.append(reservation_for(state)); states.append(state)
assert m.commissioning_capacity_gate(env,states[-1],reservations,[])["reserved_slots"]==16
try: m.commissioning_capacity_gate(env,state_for(1,"azr-bbbbbbbbbbbb"),reservations,[])
except m.RunnerError as exc: assert "already reserved" in str(exc)
else: raise AssertionError("seventeenth caller reused occupied slot 1")
# Live usage that already includes two active VMs is not added to those same VMs again.
active=[]
for state in states:
    request=state["request"]; active.append({"tags":{"invocation-binding":state["invocation"],"cell-ordinal":str(request["cell_ordinal"]),"selected-sku":request["limits"]["sku"],"sku-family":request["limits"]["sku_family"]},"hardwareProfile":{"vmSize":request["limits"]["sku"]}})
used={"regional":{"limit":128,"current":64,"free":64},"families":{sku:{"limit":10,"current":8,"free":2} for sku in m.COMMISSIONING_SKU_POOL}}
m.runner_quota_snapshot=lambda *_:used
assert m.commissioning_capacity_gate(env,states[-1],reservations,active)["active_vcpus"]==64
# One active plus one pending against a live value of eight must refuse at 12, proving max(live, active)+pending.
try: m.commissioning_capacity_gate(env,states[1],reservations[:2],active[:1])
except m.RunnerError as exc: assert "live quota" in str(exc)
else: raise AssertionError("stale/foreign live usage plus a pending reservation overbooked a family")
PY
  pass "mixed pool serializes eight stale callers, caps two per family, admits 16, refuses 17, and avoids active double-count"
}

shared_allocator_bridge_unit() {
  python3 - "$HOST" <<'PY' || fail "shared allocator runner bridge failed"
import importlib.util, json, pathlib, subprocess, tempfile, sys
spec=importlib.util.spec_from_file_location("runner_shared",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","prefix":"prefix","budget_limit":1500,"state_dir":pathlib.Path(tempfile.mkdtemp()),"azure_operation_count":0}
limits={**m.RESOURCE_CLASSES["behavior-heavy"],"sku":"Standard_D4as_v7","sku_family":"StandardDasv7Family"}
state={"schema":m.SCHEMA,"invocation":"azr-aaaaaaaaaaaa","resources":{},"request":{"fence":"sha256:"+"a"*64,"resource_class":"behavior-heavy","limits":limits}}
m.save_state=lambda *_a,**_k:None
calls=[]
def completed(value):
    return subprocess.CompletedProcess(["python"],0,stdout=json.dumps(value),stderr="")
def allocator_run(command,**kwargs):
    assert kwargs["env"]["FM_HOME"]==str(m.ROOT)
    assert kwargs["env"]["FM_AZURE_WORKER_STATE_DIR"]==str(m.ROOT/"state"/"azure-workers")
    calls.append(command)
    return completed({"reservation_id":"azr-aaaaaaaaaaaa","status":"reserved","reason":"","actual_usd":100.0,"forecast_usd":200.0,"admission_limit_usd":1500.0})
m.run=allocator_run
cost={"max_increment":25.0}
result=m.shared_capacity_reserve(env,state,cost)
assert result["actual"]==100.0 and result["forecast"]==200.0
assert "capacity-reserve" in calls[-1] and calls[-1][calls[-1].index("--sku-family")+1]=="StandardDasv7Family"
assert state["shared_capacity_reservation"]["status"]=="reserved"
# Queue, unreadable telemetry, and shared actual/forecast pressure each refuse before compute.
for payload,text in (
    ({"reservation_id":"azr-aaaaaaaaaaaa","status":"queued","reason":"family full","actual_usd":100.0,"forecast_usd":200.0,"admission_limit_usd":1500.0},"queued"),
    ({"reservation_id":"azr-aaaaaaaaaaaa","status":"reserved","reason":"","actual_usd":None,"forecast_usd":200.0,"admission_limit_usd":1500.0},"readable"),
    ({"reservation_id":"azr-aaaaaaaaaaaa","status":"reserved","reason":"","actual_usd":100.0,"forecast_usd":1490.0,"admission_limit_usd":1500.0},"pressure"),
):
    m.run=lambda *_a,payload=payload,**_k:completed(payload)
    try:m.shared_capacity_reserve(env,state,{"max_increment":25.0})
    except m.RunnerError as exc:assert text in str(exc)
    else:raise AssertionError("shared allocator failure was bypassed: "+text)
# Release is sent only from the post-cleanup bridge with one digest-bound receipt.
m.run=lambda command,**_kwargs:calls.append(command) or completed({})
state["shared_capacity_reservation"]={"status":"reserved"}
m.shared_capacity_release(env,state)
assert "capacity-release" in calls[-1] and len(calls[-1][calls[-1].index("--cleanup-receipt")+1])==64
assert state["shared_capacity_reservation"]["status"]=="released"
PY
  pass "runner queues behind the shared allocator and requires actual/forecast evidence before compute"
}

commissioning_admission_unit() {
  python3 - "$HOST" <<'PY' || fail "commissioning admission adversaries failed"
import importlib.util, math, pathlib, tempfile, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","prefix":"prefix","max_concurrency":16,"budget_limit":1500,"cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE,"state_dir":pathlib.Path(tempfile.mkdtemp()),"azure_operation_count":0}
limits=dict(m.RESOURCE_CLASSES["behavior-heavy"]); limits.update({"sku":"Standard_D4ds_v6","sku_family":"StandardDdsv6Family"})
state={"schema":m.SCHEMA,"invocation":"azr-aaaaaaaaaaaa","request":{"fence":"sha256:"+"a"*64,"lineage_root_invocation":"azr-aaaaaaaaaaaa","cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE,"cell_ordinal":16,"limits":limits,"compute_deallocation_deadline":"2026-01-02T00:00:00Z"}}
seen=[]
m.cost_query=lambda *_a,**_k: (_ for _ in ()).throw(AssertionError("commissioning queried Cost Management"))
real_commissioning_budget=m.exact_commissioning_budget
m.exact_commissioning_budget=lambda _env:seen.append("budget") or {"id":"budget","etag":"E"}
m.commissioning_inventory_gate=lambda _env,_state:seen.append("inventory") or set()
m.list_management_reservations=lambda _env:[]
m.active_runner_vms=lambda _env:[]
m.retail_rate=lambda _env,_sku:0.10
m.runner_quota_snapshot=lambda _env,_skus:{"regional":{"limit":128,"current":0,"free":128},"families":{sku:{"limit":10,"current":0,"free":10} for sku in m.COMMISSIONING_SKU_POOL}}
cost=m.commissioning_cost_gate(env,state,limits)
assert seen==["budget","inventory"] and cost["actual"] is None and cost["forecast"] is None
assert cost["cost_admission_mode"]==m.COMMISSIONING_COST_ADMISSION_MODE
assert cost["max_increment"]==cost["first_day"]["total"] and cost["max_billable_lifetime_hours"]==24
tags=m.reservation_tags({**env,"deployment_generation":"gen","owner":"owner"},state,cost["max_increment"],"2026-01-01T00:00:00Z")
assert tags["cost-admission-mode"]==m.COMMISSIONING_COST_ADMISSION_MODE and tags["cell-ordinal"]=="16" and tags["selected-sku"]=="Standard_D4ds_v6"
# The live Budget contract is exact: $1500 Monthly RG filter and all eight alerts.
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
# Fifteen exact mixed-family slots allow the sixteenth; after its reservation the same invocation remains admitted, but a seventeenth cannot collide with slot 1.
def make_reservation(invocation,ordinal):
    sku=m.COMMISSIONING_SKU_POOL[(ordinal-1)//2]; slot_limits={**limits,"sku":sku,"sku_family":m.SKU_FAMILY[sku]}
    record={"schema":m.SCHEMA,"invocation":invocation,"phase":"cost-reserved","cost":{"max_billable_lifetime_hours":24,"max_increment":cost["max_increment"]},"request":{"fence":"sha256:"+"c"*64,"cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE,"cell_ordinal":ordinal,"limits":slot_limits}}
    m.save_state(env,record,create=True)
    return {"id":"/reservations/"+invocation,"invocation-binding":invocation,"amount_usd":cost["max_increment"],"cell_ordinal":ordinal,"selected-sku":sku,"sku-family":m.SKU_FAMILY[sku]}
reservations=[make_reservation("azr-{:012x}".format(i),i) for i in range(1,16)]
m.list_management_reservations=lambda _env:list(reservations)
m.commissioning_inventory_gate=lambda _env,_state:{item["id"].lower() for item in reservations}
sixteenth=m.commissioning_cost_gate(env,state,limits)
assert sixteenth["reserved_invocations"]==15 and math.isclose(sixteenth["outstanding_reservations"],15*cost["max_increment"])
state["cost"]={"max_billable_lifetime_hours":24,"max_increment":cost["max_increment"]}; m.save_state(env,state,create=True)
current={"id":"/reservations/"+state["invocation"],"invocation-binding":state["invocation"],"amount_usd":cost["max_increment"],"cell_ordinal":16,"selected-sku":limits["sku"],"sku-family":limits["sku_family"]}; reservations.append(current)
assert m.commissioning_cost_gate(env,state,limits)["reserved_invocations"]==16
first_limits={**limits,"sku":m.COMMISSIONING_SKU_POOL[0],"sku_family":m.SKU_FAMILY[m.COMMISSIONING_SKU_POOL[0]]}
seventeenth={"schema":m.SCHEMA,"invocation":"azr-bbbbbbbbbbbb","request":{"fence":"sha256:"+"b"*64,"cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE,"cell_ordinal":1,"limits":first_limits}}
try: m.commissioning_cost_gate(env,seventeenth,first_limits)
except m.RunnerError as exc: assert "already reserved" in str(exc)
else: raise AssertionError("seventeenth commissioning runner was admitted")
# Exact completed cleanup releases slot 1 without deleting its retained audit/cost identity.
first_state=m.load_state(env,reservations[0]["invocation-binding"]); first_state["phase"]="complete"; m.save_state(env,first_state)
reservations[0]["cleanup-verified-at"]="2026-01-03T00:00:00Z"
replacement={"schema":m.SCHEMA,"invocation":"azr-cccccccccccc","request":{"fence":"sha256:"+"d"*64,"cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE,"cell_ordinal":1,"limits":first_limits}}
replacement_cost=m.commissioning_cost_gate(env,replacement,first_limits)
assert replacement_cost["reserved_invocations"]==15 and replacement_cost["retained_reservations"]==16
# Default strict mode calls actual and forecast and propagates an unavailable forecast.
strict_env=dict(env,cost_admission_mode=m.STRICT_COST_ADMISSION_MODE,budget_limit=1000,max_concurrency=4)
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
# Dispatch requires exact explicit confirmation only for commissioning mode.
minimal={"invocation":"azr-aaaaaaaaaaaa","parent_invocation":None,"request":{"fence":"sha256:"+"a"*64,"lineage_root_invocation":"azr-aaaaaaaaaaaa","cost_admission_mode":m.COMMISSIONING_COST_ADMISSION_MODE}}
try: m.dispatch_prepared(env,minimal,"sub",None)
except m.RunnerError as exc: assert "--confirm-cost-admission-mode" in str(exc)
else: raise AssertionError("commissioning ran without exact confirmation")
minimal["request"]["cost_admission_mode"]=m.STRICT_COST_ADMISSION_MODE
try: m.dispatch_prepared(strict_env,minimal,"sub",m.COMMISSIONING_COST_ADMISSION_MODE)
except m.RunnerError as exc: assert "accepted only" in str(exc)
else: raise AssertionError("strict mode accepted commissioning confirmation")
PY
  pass "runner-local strict and commissioning defenses retain exact slot, budget-alert, and itemized reservation controls"
}

static_private_controller_contract
environment_mode_defaults
storage_network_access_contract
prepare_contract
private_snapshot_prepare_contract
executor_credential_adversary
linux_systemd_drop_integration
management_fencing_unit
effective_rbac_adversaries
validation_parent_capacity_contract
cost_retry_unit
retail_rate_unit
commissioning_inventory_role_overlap_unit
mixed_pool_capacity_unit
shared_allocator_bridge_unit
commissioning_admission_unit

echo "# fm-azure-runner.test.sh: all assertions passed"
