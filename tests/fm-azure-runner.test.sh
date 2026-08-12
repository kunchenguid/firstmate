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

static_private_controller_contract() {
  python3 - "$TEMPLATE" "$HOST" "$GUEST" <<'PY' || fail "private controller static contract failed"
import json, pathlib, sys
template=json.loads(pathlib.Path(sys.argv[1]).read_text()); host=pathlib.Path(sys.argv[2]).read_text(); guest=pathlib.Path(sys.argv[3]).read_text()
vm=next(r for r in template["resources"] if r["type"]=="Microsoft.Compute/virtualMachines")
nic=next(r for r in template["resources"] if r["type"]=="Microsoft.Network/networkInterfaces")
assert template["parameters"]["controllerIdentityId"]["type"] == "string"
assert vm["identity"]["type"] == "UserAssigned"
assert "controllerIdentityId" in json.dumps(vm["identity"])
assert "publicipaddress" not in json.dumps(nic).lower()
assert "ssh" not in json.dumps(vm["properties"]["osProfile"]).lower()
assert "customdata" not in json.dumps(template).lower()
for value in ("PrivateNetwork=yes","RestrictAddressFamilies=AF_UNIX","IPAddressDeny=any","CapabilityBoundingSet=","NoNewPrivileges=yes"):
    assert value in guest
run_at=guest.index("systemd-run --quiet")
token_at=guest.index("metadata/identity/oauth2/token")
assert token_at > run_at
assert "https://files.pythonhosted.org/packages/*.whl" in guest
assert 'fetch_exact "$url"' in guest and '--location' not in guest[guest.index('while IFS=$\'\\t\' read -r url'):guest.index('done <"$BASE/wheels.tsv"')]
assert "protectedParameters" not in host
assert "generate-sas" not in host
assert "controller_identity_client_id" in host
assert "If-Match=" in host and "runner-cost-reservation" in host
assert host.index("lease.renew_and_assert()", host.index("def dispatch_prepared")) < host.index("create_vm(env, state)", host.index("def dispatch_prepared"))
cleanup=host[host.index("def cleanup(env, state):"):host.index("def dispatch_prepared")]
assert cleanup.index('"run-command-execute"') < cleanup.index('if "vm" in by_key') < cleanup.index('"ttl-schedule" in by_key')
PY
  pass "private controller has exact UAMI, no public ingress/SAS, isolated command, trusted post-command uploader, and safe cleanup order"
}

prepare_contract() {
  local tmp repo home out state
  fm_test_tmproot_into tmp fm-azure-private-prepare
  repo="$tmp/repo"; home="$tmp/home"; make_repo "$repo"; mkdir -p "$home"
  out=$(cd "$repo" && runner "$home" prepare --task task-one --generation gen-one --resource-class behavior-heavy --dependency declared/dependency.lock -- true) || fail "prepare failed: $out"
  state=$(find "$home/state/azure-runner" -name 'azr-*.json' -print -quit)
  python3 - "$state" "$repo" <<'PY'
import datetime as dt, hashlib, json, pathlib, subprocess, sys
s=json.loads(pathlib.Path(sys.argv[1]).read_text()); r=s["request"]; repo=pathlib.Path(sys.argv[2])
unsigned=dict(r); supplied=unsigned.pop("request_digest")
assert supplied=="sha256:"+hashlib.sha256(json.dumps(unsigned,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
assert r["repository"]["source_mode"]=="public-github-https"
assert r["repository"]["remote"]=="https://github.com/Ruby-Labs/cloud-host-owner.git"
assert r["repository"]["commit"]==subprocess.check_output(["git","-C",str(repo),"rev-parse","HEAD"],text=True).strip()
assert r["repository"]["snapshot_bytes"]==0 and pathlib.Path(s["input_path"]).name=="request.json"
assert all(item["url"].startswith("https://") and item["digest"].startswith("sha256:") for item in r["protocol"]["agent_fleet_python"]["wheels"])
assert all(item["url"].startswith("https://files.pythonhosted.org/packages/") for item in r["protocol"]["agent_fleet_python"]["wheels"])
created=dt.datetime.fromisoformat(r["created_at"].replace("Z","+00:00")); deadline=dt.datetime.fromisoformat(r["compute_deallocation_deadline"].replace("Z","+00:00"))
assert deadline-created==dt.timedelta(hours=23)
assert "SAS" not in json.dumps(r).upper() and "token" not in json.dumps(r).lower()
PY
  printf dirty >"$repo/dirty"
  if (cd "$repo" && runner "$home" prepare --task x --generation y -- true) >/dev/null 2>&1; then fail "dirty source accepted"; fi
  pass "prepare binds public exact commit/tree and pinned closure without a staged credential or source bundle"
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
  env AZURE_CLIENT_SECRET=must-not-pass FM_AZURE_RUNNER_TEST_NO_DROP=1 FM_AZURE_RUNNER_BOOT_ID_PATH="$tmp/boot" "$EXECUTOR" "$request" "$repo" "$output" "$uid" "$gid" /vm/id vm-instance >/dev/null || fail "credential adversary escaped sanitized executor"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["exit_code"])' "$output/result.json")" = 0 ] || fail "credential/fd adversary observed inherited authority"
  pass "repository command receives no Azure/token/SAS/secret environment or inherited credential descriptor"
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
PY
  pass "management ETag CAS rejects stale successor clobber and a hung renewal permanently closes admission"
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

static_private_controller_contract
prepare_contract
executor_credential_adversary
management_fencing_unit
cost_retry_unit

echo "# fm-azure-runner.test.sh: all assertions passed"
