#!/usr/bin/env python3
"""Same-input v1/v2 comparison through isolated real Pi RPC hosts, no Herdr."""
import subprocess,os,pathlib,json,time,threading,shutil
root=pathlib.Path(os.environ['FM_REAL_ROOT']);base=pathlib.Path(os.environ['FM_DELEGATION_HOST_DIR']);base.mkdir(parents=True,exist_ok=True)
results=[]
for mode in ('before','after'):
 home=base/mode;home.mkdir(exist_ok=True)
 for d in ('state','data','config','agent'): (home/d).mkdir(exist_ok=True)
 (home/'agent/settings.json').write_text('{"packages":[],"compaction":{"enabled":false},"retry":{"enabled":false}}')
 env=dict(os.environ,FM_HOME=str(home),FM_ROOT_OVERRIDE=str(root),FM_HOST_VARIANT=mode,FM_PERIODIC_STOW_TICK_MS='1000',PI_CODING_AGENT_DIR=str(home/'agent'))
 for key in ('FM_TASK_ID','FIRSTMATE_OP','FM_SUPERVISION_ACTOR','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE'):env.pop(key,None)
 cmd=['pi','--mode','rpc','--no-extensions','--no-context-files','-e',str(root/'tests/delegation-host-fixture.ts'),'-e',str(root/'.pi/extensions/fm-branch-supervision.ts'),'-e',str(root/'.pi/extensions/fm-periodic-stow.ts'),'--model','delegation-local/deterministic','--session-dir',str(home/'sessions')]
 out=(home/'rpc.jsonl').open('w');err=(home/'stderr').open('w')
 p=subprocess.Popen(cmd,cwd=home,env=env,stdin=subprocess.PIPE,stdout=out,stderr=err,text=True)
 def rows():
  f=home/'events.jsonl';return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []
 def wait(pred,seconds=25):
  deadline=time.monotonic()+seconds
  while time.monotonic()<deadline:
   if pred():return
   if p.poll() is not None:raise AssertionError((p.returncode,(home/'stderr').read_text()))
   time.sleep(.1)
  raise AssertionError(('timeout',mode,rows(),(home/'stderr').read_text()))
 try:
  wait(lambda:any(x['event']=='ready' for x in rows()))
  p.stdin.write(json.dumps(dict(type='prompt',message='/fixture-start'))+'\n');p.stdin.flush()
  if mode=='after':
   wait(lambda:any(x['event']=='provider' and x['branch'] for x in rows()))
   p.stdin.write(json.dumps(dict(type='prompt',message='/fixture-question'))+'\n');p.stdin.flush()
   wait(lambda:sum(x['event']=='provider' and x['branch'] for x in rows())>=3)
  else:wait(lambda:sum(x['event']=='provider' for x in rows())>=2)
  time.sleep(3)
  calls=[x for x in rows() if x['event']=='provider'];routine=[x for x in calls if 'Live task continuation obligations' in x['last']]
  native_receipts=sum(json.loads(line).get('entry',{}).get('customType')=='fm-continuation-receipt' for line in (home/'rpc.jsonl').read_text().splitlines() if line.startswith('{'))
  results.append(dict(variant=mode,native_readback_receipts=native_receipts,main_routine_requests=sum(not x['branch'] and 'Fixture seed' not in x['last'] and 'independent fixture question' not in x['last'] for x in calls),main_routine_turns=len([x for x in routine if not x['branch']]),main_tools=sum(x['event']=='tool' and not x['branch'] for x in rows()),branch_turns=len([x for x in calls if x['branch']]),calls=calls))
 finally:
  p.stdin.close()
  try:p.wait(timeout=15)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=5)
  out.close();err.close()
(base/'metrics.json').write_text(json.dumps(results,indent=2))
assert results[0]['main_routine_turns']>=1,results
assert results[1]['main_routine_turns']==0 and results[1]['main_tools']==0 and results[1]['branch_turns']>=3,results
record=json.loads((base/'after/data/routine/lifecycle.json').read_text())
assert record['precheck']['conclusion']=='needs-evidence' and record['disposition']=='open',record
calls=results[1]['calls'];branch_first=next(x['at'] for x in calls if x['branch']);branch_last=max(x['at'] for x in calls if x['branch'])
question=next(x['at'] for x in calls if not x['branch'] and 'independent fixture question' in x['last'])
assert branch_first<question<branch_last,(branch_first,question,branch_last)
assert results[0]['main_tools']==1,results
print(json.dumps(results,indent=2))
