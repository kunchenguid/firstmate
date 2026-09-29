#!/usr/bin/env bash
# Exercise goal CAS, explicit stop/reopen, evidence, action replay and budgets.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-lifecycle)
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/data/a" "$FM_HOME/data/b" "$FM_HOME/data/c" "$FM_HOME/state"
printf 'outcome: deliver the full result\n' > "$FM_HOME/data/a/brief.md"
cp "$FM_HOME/data/a/brief.md" "$FM_HOME/data/b/brief.md"
cp "$FM_HOME/data/a/brief.md" "$FM_HOME/data/c/brief.md"
printf 'spawn_gen=s1\nkind=scout\n' > "$FM_HOME/state/a.meta"
printf 'spawn_gen=s2\nkind=scout\n' > "$FM_HOME/state/b.meta"
printf 'spawn_gen=s3\nkind=scout\n' > "$FM_HOME/state/c.meta"
CLI="$ROOT/bin/fm-task-state.sh"
LIB="$ROOT/bin/fm-task-lifecycle.py"
python3 "$LIB" init a >/dev/null
python3 "$LIB" init b >/dev/null
python3 "$LIB" init c >/dev/null
"$CLI" lifecycle a > "$TMP_ROOT/input.json"
chmod 600 "$TMP_ROOT/input.json"
python3 - "$TMP_ROOT/input.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p));d['assessment']['outcome']='Partial milestone'
d['assessment']['remaining_gap']='Full CSV still absent'
json.dump(d,open(p,'w'))
PY
"$CLI" reconcile a --expected-revision 1 --record "$TMP_ROOT/input.json" >/dev/null
"$CLI" lifecycle a | jq -e '.revision==2 and .disposition=="open" and .assessment.remaining_gap=="Full CSV still absent"' >/dev/null
"$CLI" lifecycle b | jq -e '.revision==1 and .task_id=="b"' >/dev/null
if "$CLI" reconcile a --expected-revision 1 --record "$TMP_ROOT/input.json" >/dev/null 2>&1; then fail 'stale CAS accepted'; fi
pass 'new topic preserves prior unfinished goal; stale reconciliation refuses'

"$CLI" lifecycle a > "$TMP_ROOT/input.json"
python3 - "$TMP_ROOT/input.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));a=d['assessment'];d['next_action']={
'id':'a.g1.a1','kind':'steer','phase':'prepared','expected_execution_generation':'s1',
'payload_ref':a['evidence'][0]['ref'],'payload_sha256':a['evidence'][0]['sha256'],
'receipt_ref':None,'attempts':0,'attempt_limit':2,'recheck_at':'2000-01-01T00:00:00Z','deadline':'2099-01-01T00:00:00Z'}
d['next_action_seq']=2;json.dump(d,open(p,'w'))
PY
"$CLI" reconcile a --expected-revision 2 --record "$TMP_ROOT/input.json" >/dev/null
"$CLI" action a --action-id a.g1.a1 --phase attempted >/dev/null
"$CLI" action a --action-id a.g1.a1 --phase attempted >/dev/null
"$CLI" lifecycle a | jq -e '.next_action.attempts==1 and .revision==4' >/dev/null
"$CLI" lifecycle a > "$TMP_ROOT/input.json"
jq '.next_action.payload_sha256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' "$TMP_ROOT/input.json" > "$TMP_ROOT/bad.json"
chmod 600 "$TMP_ROOT/bad.json"
if "$CLI" reconcile a --expected-revision 4 --record "$TMP_ROOT/bad.json" >/dev/null 2>&1; then fail 'unconfirmed action overwritten'; fi
pass 'attempt replay is idempotent and payload mutation is rejected'

"$CLI" lifecycle a | jq '.disposition="archived"' > "$TMP_ROOT/input.json"
if "$CLI" reconcile a --expected-revision 4 --record "$TMP_ROOT/input.json" >/dev/null 2>&1; then fail 'archive accepted without stop authority'; fi
"$CLI" lifecycle a | jq '.disposition="archived" | .assessment.authority_ref="data/a/brief.md"' > "$TMP_ROOT/input.json"
if "$CLI" reconcile a --expected-revision 4 --record "$TMP_ROOT/input.json" >/dev/null 2>&1; then fail 'archive accepted an alias of the existing authority'; fi
printf 'Explicitly stop this task\n' > "$FM_HOME/data/a/stop.txt"
"$CLI" lifecycle a | jq --arg ref "$FM_HOME/data/a/stop.txt" '.disposition="archived" | .assessment.authority_ref=$ref' > "$TMP_ROOT/input.json"
"$CLI" reconcile a --expected-revision 4 --record "$TMP_ROOT/input.json" >/dev/null
test "$(python3 "$LIB" mode a)" = archived
if "$CLI" action a --action-id a.g1.a1 --phase prepared >/dev/null 2>&1; then fail 'archived action restarted'; fi
mv "$FM_HOME/state/a.meta" "$TMP_ROOT/a.meta"
python3 "$LIB" due a | jq -e '.due==false and .expired==false and .record.next_action.phase=="attempted"' >/dev/null
mv "$TMP_ROOT/a.meta" "$FM_HOME/state/a.meta"
"$CLI" lifecycle a | jq '.disposition="open"' > "$TMP_ROOT/input.json"
if "$CLI" reconcile a --expected-revision 5 --record "$TMP_ROOT/input.json" >/dev/null 2>&1; then fail 'archive reopened without authority'; fi
pass 'explicit archive retains pending effects without authorizing recovery or ordinary supervision'

printf 'spawn_gen=s3\n' > "$FM_HOME/state/a.meta"
if python3 "$LIB" mode a > "$TMP_ROOT/mode" 2>/dev/null; then fail 'old disposition crossed generation'; fi
test "$(cat "$TMP_ROOT/mode")" = unknown
printf 'spawn_gen=s1\n' > "$FM_HOME/state/a.meta"
mv "$FM_HOME/data/a/lifecycle.json" "$TMP_ROOT/preserved.json"
ln -s "$TMP_ROOT/preserved.json" "$FM_HOME/data/a/lifecycle.json"
if "$CLI" lifecycle a >/dev/null 2>&1; then fail 'symlink accepted'; fi
test -f "$TMP_ROOT/preserved.json"
pass 'generation mismatch and unsafe record retain evidence and fail closed'

# Real publication through the existing bounded scan. No endpoint/provider
# command is needed to rediscover an open goal after its notification vanished.
"$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
count=$(wc -l < "$FM_HOME/state/.wake-queue")
"$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
test "$count" = "$(wc -l < "$FM_HOME/state/.wake-queue")"
printf 'New artifact with an unfinished acceptance item\n' > "$FM_HOME/data/b/report.md"
"$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
test "$(wc -l < "$FM_HOME/state/.wake-queue")" -gt "$count"
pass 'lost wake recovers through bounded existing scan; unchanged observations do not duplicate queue rows'

# Repeating an outcome reuses its original delivery sequence, including while
# it is still unprocessed by main. No pending captain outcome is discarded.
OUTCOME="$ROOT/bin/fm-branch-outcome.sh"
one=$("$OUTCOME" append --task b --verdict captain --summary 'Artifact needs completion' --wake 'signal: result-one')
two=$("$OUTCOME" append --task b --verdict captain --summary 'Artifact needs completion' --wake 'signal: result-one')
test "$one" = "$two"
three=$("$OUTCOME" append --task b --verdict captain --summary 'Different late result' --wake 'signal: result-two')
test "$three" -gt "$two"
"$OUTCOME" mark-read --through "$three"
"$OUTCOME" unprocessed | jq -se --argjson one "$one" --argjson three "$three" \
  'map(.seq)==[$one,$three]' >/dev/null
"$OUTCOME" mark-processed --through "$three"
test -z "$("$OUTCOME" unprocessed)"
pass 'exact outcome replay reuses its sequence while a distinct late result is retained independently'

# Intake may have a brief and accepted goal before an executor is assigned.
# Discover it through the existing backlog owner, never by scanning data dirs.
mkdir -p "$FM_HOME/data/queued" "$TMP_ROOT/backlog-bin"
printf 'Finish the accepted queued request\n' > "$FM_HOME/data/queued/brief.md"
printf '# Backlog\n' > "$FM_HOME/data/backlog.md"
"$CLI" init queued >/dev/null
cat > "$TMP_ROOT/backlog-bin/tasks-axi" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list) printf 'count: 1\ntasks[1]{id,state,kind,repo,title}:\n  queued,queued,task,"-",Queued goal\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TMP_ROOT/backlog-bin/tasks-axi"
PATH="$TMP_ROOT/backlog-bin:$PATH" "$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
if ! grep -q 'child=queued disposition=open' "$FM_HOME/state/.wake-queue"; then fail 'queued goal without metadata lost'; fi
pending=$(grep -l '^task_id=queued$' "$FM_HOME/state/terminal-outcomes/"*.pending)
fp=${pending##*/}; fp=${fp%.pending}
if "$ROOT/bin/fm-inactive-reconcile.sh" acknowledge "$fp" >/dev/null 2>&1; then fail 'goal wake acknowledged before durable reconciliation'; fi
"$CLI" lifecycle queued | jq '.assessment.remaining_gap="Need an authorized executor"' > "$TMP_ROOT/input.json"
"$CLI" reconcile queued --expected-revision 1 --record "$TMP_ROOT/input.json" >/dev/null
"$ROOT/bin/fm-inactive-reconcile.sh" acknowledge "$fp"
test -f "${pending%.pending}.presented"
pass 'unassigned accepted request survives lost wake; acknowledge follows persisted reconciliation'

# A lifecycle record that cannot be validated must keep its pending recovery
# notification. Presentation alone cannot turn unknown state into reconciliation.
mkdir -p "$FM_HOME/data/broken"
printf 'Recover this damaged lifecycle\n' > "$FM_HOME/data/broken/brief.md"
printf 'spawn_gen=s-broken\nkind=scout\n' > "$FM_HOME/state/broken.meta"
printf '{}\n' > "$FM_HOME/data/broken/lifecycle.json"
chmod 600 "$FM_HOME/data/broken/lifecycle.json"
"$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
broken_pending=$(grep -l '^task_id=broken$' "$FM_HOME/state/terminal-outcomes/"*.pending)
broken_fp=${broken_pending##*/}; broken_fp=${broken_fp%.pending}
if "$ROOT/bin/fm-inactive-reconcile.sh" acknowledge "$broken_fp" >/dev/null 2>&1; then fail 'unknown lifecycle wake was acknowledged'; fi
test -f "$broken_pending"
pass 'unknown lifecycle state keeps its durable recovery notification pending'

"$CLI" lifecycle queued > "$TMP_ROOT/input.json"
python3 - "$TMP_ROOT/input.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); e=d['assessment']['evidence'][0]
d['next_action']={'id':'queued.g1.a1','kind':'readback','phase':'prepared',
 'expected_execution_generation':'unassigned-g1','payload_ref':e['ref'],'payload_sha256':e['sha256'],
 'receipt_ref':None,'attempts':0,'attempt_limit':2,'recheck_at':'2000-01-01T00:00:00Z','deadline':'2099-01-01T00:00:00Z'}
d['next_action_seq']=2; json.dump(d,open(p,'w'))
PY
"$CLI" reconcile queued --expected-revision 2 --record "$TMP_ROOT/input.json" >/dev/null
"$CLI" action queued --action-id queued.g1.a1 --phase attempted >/dev/null
sha=$(python3 - "$FM_HOME/data/queued/brief.md" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)
"$CLI" action queued --action-id queued.g1.a1 --phase confirmed --receipt-ref data/queued/brief.md --receipt-sha256 "$sha" >/dev/null
python3 "$LIB" due queued | jq -e '.due and .record.disposition=="open"' >/dev/null
pass 'confirmed readback keeps unfinished goal supervised'

# Terminal goal cleanup is due while concrete resources remain, and becomes
# quiet only after the complete cleanup owner receipt is durably recorded.
"$CLI" lifecycle c | jq '.disposition="accepted" | .assessment.remaining_gap=""' > "$TMP_ROOT/input.json"
"$CLI" reconcile c --expected-revision 1 --record "$TMP_ROOT/input.json" >/dev/null
python3 "$LIB" due c | jq -e '.due==true' >/dev/null
printf '{"schema":"fm-task-cleanup.v1","task_id":"c"}\n' > "$FM_HOME/state/c.cleanup.json"
chmod 600 "$FM_HOME/state/c.cleanup.json"
python3 "$LIB" link-cleanup c >/dev/null
rm "$FM_HOME/state/c.meta"
python3 "$LIB" owner-receipt c --kind cleanup --execution-generation s3 \
  --facts '{"taskRecordRemoved":true,"endpointConfirmedGone":true,"copyDisposition":"returned-or-already-absent","bookkeepingComplete":true,"diagnostic":"future-compatible"}' >/dev/null
terminal_due=$(python3 "$LIB" due c)
if ! printf '%s\n' "$terminal_due" | jq -e '.due==false' >/dev/null; then
  printf 'terminal cleanup remained due: %s\n' "$terminal_due" >&2
  exit 1
fi
pass 'terminal cleanup is supervised before its complete owner receipt and quiet afterward'
python3 "$LIB" owner-receipt c --kind cleanup --execution-generation s3 \
  --facts '{"taskRecordRemoved":true,"endpointConfirmedGone":true,"copyDisposition":"returned-or-already-absent","bookkeepingComplete":true}' >/dev/null
# An accepted business goal can retain a bounded physical-cleanup dependency.
python3 - "$FM_HOME" "$LIB" <<'PYWAIT'
import copy, json, os, subprocess, sys
from pathlib import Path
home=Path(sys.argv[1]); lib=sys.argv[2]; task='cleanup-wait'
directory=home/'data'/task; directory.mkdir(); (directory/'brief.md').write_bytes((home/'data/c/brief.md').read_bytes())
record=json.loads((home/'data/c/lifecycle.json').read_text()); record.update(task_id=task,cleanup_ref=None,owner_receipts={})
p=directory/'lifecycle.json'; p.write_text(json.dumps(record)); p.chmod(0o600)
meta=home/'state'/f'{task}.meta'; meta.write_text('spawn_gen=s3\n')
release=directory/'release.md'; release.write_text('Upstream repair pending\n')
def call(*args, ok=True):
    result=subprocess.run([sys.executable,lib,*args],capture_output=True,text=True,check=False)
    if ok: assert result.returncode==0, result.stderr
    else: assert result.returncode!=0, 'unsafe terminal transition accepted'
    return json.loads(result.stdout) if result.returncode==0 else None
def assess(kind='wait'):
    basis=call('inspect',task,'--evidence',str(release))['basis']
    return call('assess',task,'--basis',basis,'--judgment',json.dumps({
        'disposition':'accepted','outcome':'Business result accepted; cleanup retained','remaining_gap':'',
        'authority_ref':str(release),'evidence':[str(release)],'next_action':{
            'kind':kind,'payload_ref':str(release),'recheck_at':'2099-01-01T00:00:00Z',
            'deadline':'2099-02-01T00:00:00Z','blocker':{'owner':'repair-task',
            'dependency':'compatible cleanup reader','release_ref':str(release)}}}),ok=(kind=='wait'))
original=p.read_bytes()
assess('steer')
assert p.read_bytes()==original, 'terminal execution refusal mutated record'
assess()
assert call('due',task)['due'] is False, 'bounded terminal cleanup wait was immediately due'
assert call('observe',task)['state']=='accepted', 'cleanup wait reopened business goal'
release.write_text('Repair delivered\n')
assert call('due',task)['due'] is True, 'changed dependency did not wake cleanup'
release.write_text('Upstream repair pending\n')
r=json.loads(p.read_text());r['next_action']['recheck_at']='2000-01-01T00:00:00Z';p.write_text(json.dumps(r))
assert call('due',task)['due'] is True, 'cleanup recheck bound ignored'
r['next_action']['deadline']='2000-01-02T00:00:00Z';p.write_text(json.dumps(r))
assert call('due',task)['expired'] is True, 'cleanup deadline ignored'
print('ok - terminal cleanup waits stay bounded without reopening or granting execution')
PYWAIT
# Additive producer diagnostics stay digest-bound but do not change postconditions.
python3 - "$FM_HOME/data/c/lifecycle.json" <<'PYFACTS'
import json,hashlib,sys
from pathlib import Path
p=Path(sys.argv[1]);record=json.loads(p.read_text());proof=record['owner_receipts']['cleanup'][0]
proof['facts']['diagnostics']={'writer':'future'}
proof['sha256']=hashlib.sha256(json.dumps(proof['facts'],sort_keys=True).encode()).hexdigest()
p.write_text(json.dumps(record))
PYFACTS
python3 "$LIB" due c | jq -e '.due==false' >/dev/null


# Old ShortTask results remain effect evidence when their exact operation chain
# proves this task and generation; model summary prose alone proves nothing.
python3 - "$LIB" "$FM_HOME" <<'PY'
import copy, hashlib, json, os, pathlib, subprocess, sys
lib, home = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
task = 'legacy-cleanup'
directory = home/'data'/task;directory.mkdir()
(directory/'brief.md').write_bytes((home/'data/c/brief.md').read_bytes())
def write(p, value):
    p.write_text(json.dumps(value));p.chmod(0o600)
def due():
    p=subprocess.run(['python3',str(lib),'due',task],capture_output=True,text=True)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)['due']
short='short-'+hashlib.sha256(b'legacy-cleanup').hexdigest()
root=home/'state/short-agents'/short;root.mkdir(parents=True)
result={'id':short,'state':'completed','evidence':str(root),'summary':'Summary is not proof'}
request={'version':1,'id':short,'nonce':'original-nonce','input':{'key':'legacy-cleanup','operations':{'steps':[{'action':'cleanup','task':task}]}},
         'operationBindings':[{'spawn_gen':'s3','endpoint_task_id':task}]}
facts={'taskRecordRemoved':True,'endpointConfirmedGone':True,'copyDisposition':'returned-or-already-absent','bookkeepingComplete':True}
receipt={'id':short,'nonce':request['nonce'],'index':0,'action':'cleanup','state':'completed','evidence':facts}
record=json.loads((home/'data/c/lifecycle.json').read_text())
record.update(task_id=task,cleanup_ref=str(root/'result.json'),owner_receipts={})
record['assessment']['authority_ref']=str(directory/'brief.md')
record['assessment']['evidence']=[{'ref':str(directory/'brief.md'),'sha256':hashlib.sha256((directory/'brief.md').read_bytes()).hexdigest()}]
def reset():
    for name,value in [('request.json',request),('result.json',result),('operation-0.receipt.json',receipt)]:write(root/name,value)
    data=copy.deepcopy(record)
    data['assessment']['evidence'].append({'ref':str(root/'result.json'),'sha256':hashlib.sha256((root/'result.json').read_bytes()).hexdigest()})
    write(directory/'lifecycle.json',data)
reset()
before={p:p.read_bytes() for p in root.iterdir()}
assert due() is False, 'complete historical operation receipt kept cleanup due'
assert before=={p:p.read_bytes() for p in root.iterdir()}, 'readback modified operation evidence'
for version in (1,2,'future-compatible'):
    reset();r=copy.deepcopy(request);r['version']=version;r['diagnostics']={'writer':'future'};write(root/'request.json',r)
    r=copy.deepcopy(receipt);r['evidence']['diagnostics']={'elapsed':3};write(root/'operation-0.receipt.json',r)
    assert due() is False, 'additive receipt fields changed cleanup evidence'
for filename,key,value in [('request.json','nonce','other'),('result.json','state','interrupted'),('operation-0.receipt.json','state','refused'),('operation-0.receipt.json','id','short-'+'f'*64),('operation-0.receipt.json','index',True)]:
    reset();p=root/filename;r=json.loads(p.read_text());r[key]=value;write(p,r)
    assert due() is True,(filename,key)
for field,value in [('spawn_gen','other'),('endpoint_task_id','other')]:
    reset();r=copy.deepcopy(request);r['operationBindings'][0][field]=value;write(root/'request.json',r);assert due() is True,field
reset();r=copy.deepcopy(request);r['input']['operations']['steps'].append(r['input']['operations']['steps'][0]);r['operationBindings'].append(r['operationBindings'][0]);write(root/'request.json',r);assert due() is True,'ambiguous cleanup steps'
for field,value in [('endpointConfirmedGone',False),('bookkeepingComplete',1),('copyDisposition','retained')]:
    reset();r=copy.deepcopy(receipt);r['evidence'][field]=value;write(root/'operation-0.receipt.json',r);assert due() is True,field
reset();(root/'operation-0.receipt.json').unlink();assert due() is True,'model result alone became proof'
reset();p=root/'operation-0.receipt.json';other=home/'state/other.json';other.write_bytes(p.read_bytes());p.unlink();p.symlink_to(other);assert due() is True,'symlink receipt accepted';p.unlink()
reset();meta=home/'state'/f'{task}.meta';meta.write_text('spawn_gen=s3\n');assert due() is True,'remaining resources ignored';meta.unlink()
reset();r=json.loads((directory/'lifecycle.json').read_text());r['disposition']='open';r['assessment']['remaining_gap']='More work';write(directory/'lifecycle.json',r);assert due() is True,'cleanup became goal acceptance'
print('ok - legacy and additive cleanup receipts quiet only verified terminal tasks without replay')
PY

# Exact new authority can reopen a historical Done goal; old status events
# cannot change the structured disposition or inherit its old acceptance.
"$CLI" lifecycle b | jq '.disposition="accepted" | .assessment.remaining_gap=""' > "$TMP_ROOT/input.json"
"$CLI" reconcile b --expected-revision 1 --record "$TMP_ROOT/input.json" >/dev/null
printf 'Explicit new requested outcome\n' > "$FM_HOME/data/b/reopen.txt"
printf 'done: old completion\nready: old awaiting merge\n' > "$FM_HOME/state/b.status"
"$CLI" lifecycle b | jq --arg ref "$FM_HOME/data/b/reopen.txt" '.disposition="open" | .goal_revision=2 | .assessment.authority_ref=$ref | .assessment.remaining_gap="New requested deliverable"' > "$TMP_ROOT/input.json"
"$CLI" reconcile b --expected-revision 2 --record "$TMP_ROOT/input.json" >/dev/null
[ "$(python3 "$LIB" mode b)" = open ] || fail 'old Done closed reopened goal'
pass 'historical completion and old ready events cannot close a newly authorized goal'

# A bounded healthy wait is not execution inactivity. Deadline expiry asks for
# assessment only and cannot spend/restart automatically.
report_sha=$(shasum -a 256 "$FM_HOME/data/b/report.md" | cut -d' ' -f1)
"$CLI" lifecycle b | jq --arg ref "$FM_HOME/data/b/report.md" --arg sha "$report_sha" '.assessment.evidence += [{ref:$ref,sha256:$sha}] | .next_action={id:"b.g2.a1",kind:"wait",phase:"prepared",expected_execution_generation:"s2",payload_ref:.assessment.evidence[0].ref,payload_sha256:.assessment.evidence[0].sha256,receipt_ref:null,attempts:0,attempt_limit:1,recheck_at:"2099-01-01T00:00:00Z",deadline:"2099-01-01T00:00:00Z"} | .next_action_seq=2' > "$TMP_ROOT/input.json"
"$CLI" reconcile b --expected-revision 3 --record "$TMP_ROOT/input.json" >/dev/null
python3 "$LIB" due b | jq -e '.due==false' >/dev/null
"$CLI" action b --action-id b.g2.a1 --phase refused --receipt-ref data/b/report.md --receipt-sha256 "$report_sha" >/dev/null
"$CLI" lifecycle b | jq '.next_action.id="b.g2.a2" | .next_action.phase="prepared" | .next_action.attempts=0 | .next_action_seq=3' > "$TMP_ROOT/input.json"
if "$CLI" reconcile b --expected-revision 5 --record "$TMP_ROOT/input.json" >/dev/null 2>&1; then fail 'same effect evaded refusal budget'; fi
pass 'healthy bounded wait does not restart; refused effect cannot reset its retry budget'

# Scale cannot extend one reconciliation turn indefinitely. Use hundreds of
# private records and the supported one-second scan budget, no backend calls.
python3 - "$FM_HOME" <<'PYBOUNDED'
import pathlib,sys
h=pathlib.Path(sys.argv[1])
for i in range(300):
 t='bounded%04d'%i;(h/'data'/t).mkdir();(h/'data'/t/'brief.md').write_text('pending goal')
 (h/'state'/(t+'.meta')).write_text('kind=scout\nspawn_gen=s1\n')
 (h/'data'/t/'lifecycle.json').write_text('{}');(h/'data'/t/'lifecycle.json').chmod(0o600)
PYBOUNDED
start=$(date +%s)
FM_INACTIVE_RECONCILE_BUDGET_SECS=1 "$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 4 ] || fail "bounded scan exceeded allowance: $elapsed seconds"
printf 'ok - 300-record scan elapsed=%ss with one-second budget and backstop\n' "$elapsed"

# Run the actual Pi routing reader. A stale archived execution goes to main;
# its late result stays deliverable and the queue bytes are never consumed.
mode_home="$TMP_ROOT/routing-home"
mkdir -p "$mode_home/data/stopped" "$mode_home/state"
printf 'Explicitly stopped request\n' > "$mode_home/data/stopped/brief.md"
printf 'spawn_gen=s-stop\nkind=ship\nproject=%s\nwindow=fm-stopped\n' "$ROOT" > "$mode_home/state/stopped.meta"
FM_HOME="$mode_home" "$CLI" init stopped >/dev/null
fm_test_archive_goal "$mode_home" stopped
printf '1\t1\tstale\tfm-stopped\told idle\n2\t2\tsignal\tstopped.status\tlate result\n' > "$mode_home/state/.wake-queue"
NODE_NO_WARNINGS=1 LIFECYCLE_ROOT="$ROOT" LIFECYCLE_HOME="$mode_home" node --input-type=module <<'JS'
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const root=process.env.LIFECYCLE_ROOT, home=process.env.LIFECYCLE_HOME, state=home+'/state';
const lib=await import(pathToFileURL(root+'/.pi/extensions/lib/fm-branch-dispatch.ts'));
const before=readFileSync(state+'/.wake-queue','utf8');
const {modes,scope}=await lib.scopeForUnreadWakeWithLifecycle(root,home,state,false);
if(modes.stopped!=='archived') throw new Error('reader did not validate stopped generation');
if(JSON.stringify(scope.eligibleSeqs)!=='["2"]' || !scope.needsDecisionKeys.includes('fm-stopped')) throw new Error('archive routing lost late result or resumed stale work');
if(readFileSync(state+'/.wake-queue','utf8')!==before) throw new Error('routing consumed a pending result');
JS
pass 'Pi excludes archived stale recovery while preserving late result and every queue row'

# Same task name in a reassigned slot is still a different execution.
mkdir -p "$TMP_ROOT/pool/1/checkout"
ROOT="$ROOT" SLOT="$TMP_ROOT/pool/1/checkout" bash <<'SHSLOT'
set -eu
. "$ROOT/bin/fm-wake-lib.sh"
fm_treehouse_slot_owner_claim "$SLOT" same "$FM_HOME" s-new
fm_treehouse_slot_owner_state "$SLOT" same s-old
[ "$FM_TREEHOUSE_SLOT_OWNER" = unsafe ]
fm_treehouse_slot_owner_release "$SLOT" same s-old
fm_treehouse_slot_owner_state "$SLOT" same s-new
[ "$FM_TREEHOUSE_SLOT_OWNER" = mine ]
fm_treehouse_slot_owner_claim "$SLOT" same "$FM_HOME"
fm_treehouse_slot_owner_state "$SLOT" same s-new
[ "$FM_TREEHOUSE_SLOT_OWNER" = unsafe ]
fm_treehouse_slot_owner_release "$SLOT" same s-new
[ -f "$(fm_treehouse_slot_owner_marker "$SLOT")" ]
fm_treehouse_slot_owner_claim "$SLOT" same "$FM_HOME" s-new
printf 'spawn_gen=s-duplicate\n' >> "$(fm_treehouse_slot_owner_marker "$SLOT")"
fm_treehouse_slot_owner_state "$SLOT" same s-new
[ "$FM_TREEHOUSE_SLOT_OWNER" = unsafe ]
SHSLOT
pass 'missing or old generation cannot release a reused same-task slot; duplicate claim remains unsafe'
