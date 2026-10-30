import os, subprocess, json, time, pathlib, sys
root=pathlib.Path.cwd(); lab=root/'.live-validation'; evidence=pathlib.Path('/Users/kunchen/.no-mistakes/evidence/01M6766N8H82Z1ZJ3TPP8196PX')
env=os.environ.copy()
for k in list(env):
 if k.startswith(('HC_','HERDR_','FM_')) or k in ('TERM_PROGRAM','REX_BLOCK','REX_SESSION'): env.pop(k,None)
env.update(HC_SESSION='fm-lab-osc7501',HC_SOCKET=str(root/'h.sock'),XDG_STATE_HOME=str(lab/'xdg-state'),XDG_CONFIG_HOME=str(lab/'xdg-config'),XDG_RUNTIME_DIR=str(lab/'xdg-run'),XDG_DATA_HOME=str(lab/'xdg-data'),XDG_CACHE_HOME=str(lab/'xdg-cache'),DISABLE_AUTOUPDATER='1',FM_OSC7501_INTERVAL='1')
for k in ['XDG_STATE_HOME','XDG_CONFIG_HOME','XDG_RUNTIME_DIR','XDG_DATA_HOME','XDG_CACHE_HOME']: pathlib.Path(env[k]).mkdir(exist_ok=True,mode=0o700)
hc=str(lab/'herdr-core'); script=str(root/'bin/fm-osc7501.sh'); events=[]; terminals=[]
def cmd(*args):
 p=subprocess.run([hc,*args],env=env,capture_output=True,text=True,timeout=30)
 if p.returncode: raise RuntimeError((args,p.returncode,p.stdout,p.stderr))
 return json.loads(p.stdout)
def record(label,data):
 events.append({'check':label,'observed':data}); print(label,json.dumps(data),flush=True)
def setup(name):
 import shutil
 d=lab/name
 if d.exists():shutil.rmtree(d)
 (d/'state').mkdir(parents=True);(d/'config').mkdir();return d
def busy(d,state):
 (d/'state/task.busy-gen').write_text('g1\n');(d/'state/task.busy-state').write_text(f'v1 gen=g1 seq=1 state={state} source=fm-spawn event=test ts={int(time.time())}\n')
def status(d,line):
 with (d/'state/task.status').open('a') as f:f.write(line+'\n')
def start(d, extra=None, backend='hc', harness='opencode', tail='sleep 240',prefix=''):
 import shlex
 q=shlex.quote
 launch=f'{prefix}bash {q(script)} arm --task task --harness {harness} --backend {backend} --kind ship --state {q(str(d/"state"))} --config {q(str(d/"config"))}; {tail}; bash {q(script)} disarm --state {q(str(d/"state"))}; sleep 240'
 args=['run','--bg','--json','--no-parent','--no-notify','--cwd',str(root),'--','env']
 if extra:args+=extra
 args+=['bash','-c',launch]
 out=cmd(*args);t=out['address'];terminals.append(t);record('terminal '+d.name,out);return t
def wait(t,state,kind=None):
 end=time.time()+20
 while time.time()<end:
  x=cmd('get',t,'--json');s=x.get('status') or {}
  if s.get('state')==state and (kind is None or s.get('kind')==kind):
   record(f'{t} -> {state}'+(' '+kind if kind else ''),{k:x.get(k) for k in ['address','state','status','reported','turn']});return x
  time.sleep(.3)
 raise AssertionError((t,state,kind,x))
def watchers(d):return list((d/'state').glob('.osc7501watch-*'))
try:
 record('verified runtime',cmd('server','status','--json'))
 d=setup('states');busy(d,'busy');t=start(d);wait(t,'working');busy(d,'idle');wait(t,'idle')
 status(d,'needs-decision [at=1] [key=q1]: ship it?');wait(t,'blocked','question')
 status(d,'resolved [at=2] [key=q1]: yes');wait(t,'idle')
 status(d,'blocked [at=3] [key=p1]: allow access to fixture');wait(t,'blocked','permission')
 status(d,'resolved [at=4] [key=p1]: allowed');wait(t,'idle')
 status(d,'blocked [at=5] [key=a1]: API key required');wait(t,'blocked','auth')
 status(d,'resolved [at=6] [key=a1]: supplied');wait(t,'idle')
 status(d,'done [at=7]: PR https://example.test/pr/1');wait(t,'done')
 busy(d,'busy');wait(t,'working');busy(d,'idle');wait(t,'done')
 status(d,'failed [at=8]: fixture failure');wait(t,'error')
 status(d,'paused [at=9]: waiting on CI');wait(t,'idle');busy(d,'busy');wait(t,'working')
 # Retire a running incarnation from inside its own controlling terminal.
 cmd('kill',t,'--json');time.sleep(2)
 # Distinct terminal reporters coexist; a disarm leaves the other running.
 a=setup('pane-a');b=setup('pane-b');busy(a,'busy');busy(b,'busy')
 ta=start(a,tail='sleep 5');tb=start(b);wait(ta,'working');wait(tb,'working');wait(ta,'idle');wait(tb,'working');time.sleep(1)
 assert not watchers(a) and watchers(b)
 record('independent terminal cleanup',{'pane_a_watchers':len(watchers(a)),'pane_b_watchers':len(watchers(b))})
 # Real hc answers the capability query after known-aware markers are removed.
 q=setup('query');busy(q,'busy');tq=start(q,extra=['-u','HC_TERMINAL_ID','-u','HC_TERMINAL_SOCKET','-u','HC_SCOPE']);wait(tq,'working')
 # Config off and legacy Herdr backend refuse even a known-aware terminal.
 for name,backend,config in [('off','hc','off'),('invalid','hc','nonsense'),('legacy','herdr',None)]:
  z=setup(name);busy(z,'busy')
  if config:(z/'config/osc7501-status').write_text(config+'\n')
  tz=start(z,backend=backend);time.sleep(2);out=cmd('get',tz,'--json');assert not out.get('reported') and not watchers(z),out
  record(name+' refuses reporter',{'reported':out.get('reported'),'status':out.get('status'),'watchers':len(watchers(z))})
 # Installed native Claude version gate uses the actual binary, not a fake.
 n=setup('native');busy(n,'busy');tn=start(n,harness='claude');time.sleep(3);out=cmd('get',tn,'--json');assert not out.get('reported') and not watchers(n),out
 record('installed Claude native gate',{'version':subprocess.check_output(['claude','--version'],text=True).strip(),'reported':out.get('reported'),'watchers':len(watchers(n))})
 # An unknown/silent program holds no invented initial idle status.
 u=setup('unknown');tu=start(u);time.sleep(2);out=cmd('get',tu,'--json');assert not out.get('reported'),out;record('unknown activity does not invent state',{'reported':out.get('reported'),'status':out.get('status')})
 # Final disarm preserves the done/error record while stale busy remains set.
 for name,verb,expected in [('final-done','done','done'),('final-error','failed','error')]:
  f=setup(name);busy(f,'busy');status(f,verb+' [at=1]: retained result');tf=start(f,tail='sleep 4');wait(tf,'working');wait(tf,expected);time.sleep(1);assert not watchers(f)
 record('RESULT',{'pass':True})
finally:
 for t in terminals:
  try:cmd('kill',t,'--json')
  except Exception:pass
 try:record('private core teardown',cmd('server','stop','--json'))
 except Exception as e:record('teardown error',str(e))
 (evidence/'core-live-observations.json').write_text(json.dumps(events,indent=2)+'\n')
