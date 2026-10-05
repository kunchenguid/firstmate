#!/usr/bin/env bash
# Credential-free installed Codex config/read guard for frozen native counts.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_WORKFORCE_POLICY_NATIVE_LIVE codex python3
TMP_ROOT=$(fm_test_tmproot fm-workforce-policy-native)
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME"
for concurrent in 0 2; do
  python3 - "$concurrent" <<'PY' | python3 "$ROOT/bin/fm-workforce-policy.py" probe > "$TMP_ROOT/result.json"
import json,sys
print(json.dumps(dict(schema='fm-workforce-policy.v1',allocation_id='native-proof',crew=1,
    descendants=dict(concurrent=int(sys.argv[1])),route='host',
    revisions={k:'a'*64 for k in ['global','project','job']})))
PY
  python3 - "$TMP_ROOT/result.json" "$concurrent" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));n=int(sys.argv[2]);c=r['controls']
assert r['version']=='codex-cli 0.159.3' and r['credential_free']
assert c['features.multi_agent_v2'] is False
assert c['agents.enabled']==bool(n) and c['features.multi_agent']==bool(n)
if n: assert c['agents.max_concurrent_threads_per_session']==n
print('PASS: installed native config/read concurrent='+str(n)+' version='+r['version'])
PY
done
export POLICY_NATIVE_ROOT="$ROOT"
python3 - <<'PY'
import json,os,pathlib,subprocess,select,time
root=pathlib.Path(os.environ['POLICY_NATIVE_ROOT']);home=pathlib.Path(os.environ['FM_HOME'])
(home/'data').mkdir();(home/'projects/demo').mkdir(parents=True)
(home/'data/projects.md').write_text('- demo [direct-PR] - native fixture (added 2026-10-05)\n')
env={k:v for k,v in os.environ.items() if not any(s in k.upper() for s in ['TOKEN','SECRET','PASSWORD','API_KEY'])}
env['CODEX_HOME']=str(home/'native-home')
pathlib.Path(env['CODEX_HOME']).mkdir()
policy=dict(schema='fm-workforce-policy.v1',allocation_id='actual-native-process',crew=1,
 descendants=dict(concurrent=2),route='host',revisions={k:'b'*64 for k in ['global','project','job']})
request=dict(schema='fm-workforce-request.v1',request_id='native-runtime',action='job-request',scope=dict(project='demo'),
 payload=dict(kind='ship',text='credential-free runtime fixture',posture='assistant',delivery_mode='direct-PR',merge_autonomy=False,execution_policy=policy))
def run(script,*args,value=None,ok=True):
 p=subprocess.run(['python3' if script.endswith('.py') else 'bash',str(root/'bin'/script),*args],env=env,
  input=json.dumps(value) if value else '',text=True,capture_output=True,timeout=30)
 assert (p.returncode==0)==ok,(p.stdout,p.stderr)
 return json.loads(p.stdout) if ok and p.stdout else None
note=run('fm-workforce.py','submit',value=request)['id']
run('fm-inbox.sh','prepare-admission',note,'native-runtime',str(home/'projects/demo'),'ship')
allocation=run('fm-workforce-policy.py','allocation',note)
origin=run('fm_inbox_admission.py','origin',note,'native-runtime','s-native-fixture')
meta=dict(harness='codex',spawn_gen='s-native-fixture',workforce_allocation=json.dumps(allocation),admission_origin=json.dumps(origin))
(home/'state/native-runtime.meta').write_text(''.join(k+'='+v+'\n' for k,v in meta.items()))
p=subprocess.Popen(['python3',str(root/'bin/fm-workforce-policy.py'),'launch','native-runtime','--','codex','app-server','--strict-config'],
 env=env,cwd=env['CODEX_HOME'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
try:
 p.stdin.write(json.dumps(dict(id=1,method='initialize',params=dict(clientInfo=dict(name='native-runtime-proof',version='1'))))+'\n');p.stdin.flush()
 deadline=time.monotonic()+20
 while time.monotonic()<deadline:
  if select.select([p.stdout],[],[],max(0,deadline-time.monotonic()))[0]:
   line=p.stdout.readline()
   assert line, 'native process exited before initialization'
   if json.loads(line).get('id')==1: break
 else: raise AssertionError('native initialization timed out')
 observed=run('fm-workforce-policy.py','observe','native-runtime')
 assert observed['state']=='running' and observed['occupied'] is True and not observed['attested'],observed
 assert observed['native']['controls']['agents.max_concurrent_threads_per_session']==2
 run('fm-workforce-policy.py','launch','native-runtime','--','codex','app-server',ok=False)
 meta['spawn_gen']='s-replacement-fixture'
 (home/'state/native-runtime.meta').write_text(''.join(k+'='+v+'\n' for k,v in meta.items()))
 assert run('fm-workforce-policy.py','observe','native-runtime')['state']=='unknown'
finally:
 p.terminate();p.wait(timeout=5)
print('PASS: actual credential-free native process, exact generation/argv, duplicate launch refusal and stale generation')
PY
pass 'Native descendant controls read back without credentials or inference'
