import subprocess,os,time,pathlib,json
root=pathlib.Path.cwd(); app=str(root/'.live/app/Herdr.app/Contents/MacOS/Herdr'); ev=pathlib.Path(os.environ['EVIDENCE'])
log=[]
def call(*args):
 r=subprocess.run([app,*args],text=True,capture_output=True,timeout=25)
 log.append({'command':['Herdr',*args],'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
 if r.returncode: raise RuntimeError(log[-1])
 return json.loads(r.stdout) if r.stdout.startswith('{') or r.stdout.startswith('[') else r.stdout
with open(ev/'real-app-startup.log','a') as f:
 p=subprocess.Popen([app],stdout=f,stderr=f)
 try:
  for i in range(30):
   time.sleep(.5)
   r=subprocess.run([app,'ls'],text=True,capture_output=True,timeout=20)
   if r.returncode==0 and 't1' in r.stdout: break
  else: raise RuntimeError('app did not project live lab primary')
  call('do','space.new',json.dumps({'name':'Live app validation','folder':str(root),'tab':'App-created primary','argv':['bash',str(root/'.live/gui-primary.sh'),str(root)]}))
  for i in range(120):
   if (root/'.live/gui.rc').exists(): break
   time.sleep(1)
  else: raise RuntimeError('app primary spawn did not finish')
  assert (root/'.live/gui.rc').read_text().strip()=='0'
  meta=(root/'.live/home/state/livegui.meta').read_text()
  (ev/'real-app-task.meta').write_text(meta)
  assert '\nbackend=hc\n' in meta and '\nbackend_detect=app-terminal\n' in meta
  terminal=next(x.split('=',1)[1] for x in meta.splitlines() if x.startswith('hc_terminal='))
  for i in range(30):
   listing=call('ls')
   found=[(s,t) for s in listing['spaces'] for t in s['tabs'] if any(q['terminal']==terminal for q in t['terminals'])]
   if found: break
   time.sleep(.5)
  assert found,listing
  s,t=found[0]
  assert s['id'].startswith('fm-') and t['id'].endswith('-fm-livegui'),(s,t)
  (ev/'real-app-worker-projection.json').write_text(json.dumps(listing,indent=2))
  call('do','agent.focus','--terminal',terminal)
  try: call('do','overlay.close')
  except RuntimeError: pass
  time.sleep(2)
  call('shot',str(ev/'herdr-app-worker.png'))
  call('status')
  # Exercise the removed signal while this real window is actually running.
  env=os.environ.copy(); env.pop('HC_TERMINAL_ID',None); env.pop('HC_TERMINAL_SOCKET',None)
  for title,extra in [('running lab core',{}),('unprovisioned core',{'HC_SESSION':'fm-hclab-never','FM_HC_SOCKET':'','.X':'unused'})]:
   e=env|extra; e.pop('.X',None)
   r=subprocess.run(['bash','-c','. bin/fm-backend.sh; fm_backend_resolve; printf "backend=%s\\nsignal=%s\\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"'],env=e,text=True,capture_output=True,timeout=30)
   log.append({'scenario':'marker-less process near real app window; '+title,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
   assert r.returncode==0 and r.stdout=='backend=tmux\nsignal=\n' and not r.stderr
 finally:
  p.terminate()
  try: p.wait(timeout=10)
  except subprocess.TimeoutExpired: p.kill(); p.wait()
  log.append({'app_exit':p.returncode})
  (ev/'real-app-exercise.json').write_text(json.dumps(log,indent=2)+'\n')
print('Real app-created primary spawned hc worker; app ls projected it; marker-less processes stayed silent tmux; app stopped.')
