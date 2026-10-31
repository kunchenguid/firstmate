import os, pathlib, subprocess as sp, time, signal, shutil, json
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M68ZYG4NJWEWWJCVHC20WWH9'); L=R/'.l'; L.mkdir(exist_ok=True)
base={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ['TMUX','HERDR_ENV','REX_SESSION','REX_BLOCK','NO_MISTAKES_GATE'])}
base['TMUX']=str(L/'s')+',0,0'
children=[]; files=[]; results=[]
def run(cmd,env=None,timeout=30):
 p=sp.run(cmd,env=env or base,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=timeout); return p.returncode,p.stdout
def log(s): print(s,flush=True)
def wait(pred,sec=30):
 end=time.monotonic()+sec
 while time.monotonic()<end:
  if pred(): return
  time.sleep(.05)
 raise AssertionError('wait timeout')
def home(name,**extra):
 h=L/name; rc,out=run([str(R/'bin/fm-lab-home.sh'),'create',str(h)]); assert rc==0,out
 env=base|{'FM_HOME':str(h),'FM_POLL':'0.2','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_SIGNAL_GRACE':'1'}|{k:str(v) for k,v in extra.items()}
 return h,env
def launch(h,env,which='fm-watch-arm.sh',label='arm'):
 f=open(E/(h.name+'-'+label+'.log'),'w'); files.append(f)
 p=sp.Popen([str(R/'bin'/which)],env=env,stdout=f,stderr=sp.STDOUT,start_new_session=True); children.append(p); return p,pathlib.Path(f.name)
def text(p): return p.read_text() if p.exists() else ''
def shell(env,code,args=[]):
 rc,out=run(['bash','-c','. "$1"; '+code,'_',str(R/'bin/fm-wake-lib.sh'),*map(str,args)],env); assert rc==0,(rc,out); return out
def clean(h,foreign=None):
 remains=[str(x.relative_to(h)) for x in (h/'state').glob('.*lock*') if x.name not in ['.watch-cycle-exits.log.lock'] and (not foreign or x!=foreign)]
 log('remaining lock/owner paths: '+repr(remains)); assert not remains,remains
 log(text(h/'state/.watch-cycle-exits.log'))
def drain(h,env):
 rc,out=run([str(R/'bin/fm-wake-drain.sh')],env); log('DRAIN rc='+str(rc)+'\n'+out); assert rc==0,out
 import re
 m=re.search(r'WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',out); assert m,out
 rc,out=run([str(R/'bin/fm-wake-drain.sh'),'--ack-through',m[1],'--recovery-generation',m[2]],env); assert rc==0,out; log('ACK '+out)
def stop(p,sig=signal.SIGHUP):
 p.send_signal(sig); rc=p.wait(timeout=40); log('arm signal exit='+str(rc)); return rc
def scenario(name,fn):
 if os.environ.get('LIVE_ONLY') and fn.__name__ not in os.environ['LIVE_ONLY'].split(','): return
 log('\n=== '+name+' ==='); start=time.monotonic()
 try: fn(); results.append({'name':name,'result':'pass'}); log('PASS elapsed='+str(round(time.monotonic()-start,2)))
 except Exception as ex: results.append({'name':name,'result':'fail','error':str(ex)}); log('FAIL '+repr(ex)); raise
try:
 rc,out=run(['tmux','-S',str(L/'s'),'new-session','-d','-s','fm-lab-watch','-x','100','-y','30','sleep 1200']); assert rc==0,out
 def slow():
  h,e=home('slow',FM_TEST_WATCHER_PRE_IDENTITY_DELAY=15); t=time.monotonic(); p,o=launch(h,e)
  wait(lambda:'watcher: started' in text(o),45); log(text(o)); assert time.monotonic()-t>14
  assert stop(p)==129; clean(h); drain(h,e)
 scenario('Default arm confirms a real local watcher delayed beyond the old ten-second budget',slow)
 def held():
  h,e=home('held',FM_WATCHER_STARTUP_LOCK_BOUND=2)
  f=open(E/'held-holder.log','w'); files.append(f)
  holder=sp.Popen(['bash','-c','. "$1"; fm_lock_acquire_wait "$FM_HOME/state/.wake-queue.lock"; touch "$FM_HOME/ready"; while [ ! -e "$FM_HOME/release" ]; do sleep .05; done; fm_lock_release "$FM_HOME/state/.wake-queue.lock"','_',str(R/'bin/fm-wake-lib.sh')],env=e,stdout=f,stderr=f,start_new_session=True); children.append(holder)
  wait(lambda:(h/'ready').exists()); (h/'state/.last-watcher-beat').touch(); p,o=launch(h,e); rc=p.wait(timeout=30); log('arm exit='+str(rc)+'\n'+text(o)); assert rc==1 and 'startup lock' in text(o) and 'watcher: started' not in text(o)
  (h/'release').touch(); assert holder.wait(timeout=10)==0; clean(h); drain(h,e)
 scenario('A real queue-lock holder causes a typed bounded startup refusal, not confirmation from an inherited beacon',held)
 def signals():
  for override in [30,60]:
   for sig in [signal.SIGHUP,signal.SIGTERM]:
    for i in range(4):
     h,e=home('signal-%s-%s-%s'%(override,sig.name,i),FM_TEST_WATCHER_PRE_IDENTITY_DELAY=2)
     (h/'config/watch.env').write_text('FM_ARM_CONFIRM_TIMEOUT=%s\n'%override)
     foreign=h/'state/.wake-queue.lock.owner.foreign'; foreign.mkdir(); (foreign/'pid').write_text(str(os.getpid())+'\n')
     p,o=launch(h,e); wait(lambda:(h/'state/.watch.lock/pid').exists()); rc=stop(p,sig); log(h.name+' '+text(o)); assert rc==128+sig
     assert (foreign/'pid').read_text().strip()==str(os.getpid()); clean(h,foreign); drain(h,e)
 scenario('Repeated HUP and TERM during unsafe local startup clean own locks and staging while preserving foreign staging with 30/60-second home overrides',signals)
 def deadline():
  h,e=home('deadline',FM_TEST_WATCHER_PRE_IDENTITY_DELAY=8,FM_ARM_CONFIRM_TIMEOUT=2); p,o=launch(h,e); t=time.monotonic(); rc=p.wait(timeout=35); log('arm exit='+str(rc)+' elapsed='+str(time.monotonic()-t)+'\n'+text(o)); assert rc==1 and time.monotonic()-t>=7 and 'no live watcher' in text(o); clean(h); drain(h,e)
 scenario('An expired short confirmation deadline waits for cleanup-safe startup before TERM',deadline)
 def identity():
  h,e=home('identity',FM_TEST_WATCHER_PRE_IDENTITY_DELAY=4,FM_ARM_CONFIRM_TIMEOUT=2); p,o=launch(h,e)
  wait(lambda:(h/'state/.watch.lock/pid').exists()); (h/'state/.watch.lock/fm-home').mkdir()
  rc=p.wait(timeout=30); log('arm exit='+str(rc)+'\n'+text(o)); assert rc==1 and 'could not publish watcher identity' in text(o)
  # The deliberate directory refuses writes and is not a lock primitive artifact.
  residue=h/'state/.watch.lock'; log('identity failure singleton exists='+str(residue.exists())+' symlink='+str(residue.is_symlink()))
  assert not residue.exists() and not residue.is_symlink(); drain(h,e)
 scenario('An actual filesystem identity-publication failure exits the watcher and joins the arm rather than hanging',identity)
 def recovery():
  for kind in ['pending','acked']:
   h,e=home('recover-'+kind,FM_WATCH_HANDLING_SUCCESSOR=1); p,o=launch(h,e); wait(lambda:'watcher: started' in text(o))
   # Stop only this watcher between polls while a production queue writer creates recoverable work.
   pid=int((h/'state/.watch.lock/pid').read_text()); os.kill(pid,signal.SIGSTOP)
   shell(e,'fm_recovery_marker_publish "$FM_HOME/state/.watcher-down" downtime; fm_wake_append check synthetic "check: synthetic queued obligation"')
   if kind=='acked': shell(e,'fm_recovery_marker_read "$FM_HOME/state/.watcher-down"; fm_recovery_marker_ack "$FM_HOME/state/.watcher-down" "${FM_RECOVERY_MARKER_TOKEN##*:}"')
   # Contend using the actual queue lock for longer than the startup bound.
   f=open(E/(h.name+'-holder.log'),'w'); files.append(f)
   holder=sp.Popen(['bash','-c','. "$1"; fm_lock_acquire_wait "$FM_HOME/state/.wake-queue.lock"; touch "$FM_HOME/ready"; sleep 3; fm_lock_release "$FM_HOME/state/.wake-queue.lock"','_',str(R/'bin/fm-wake-lib.sh')],env=e,stdout=f,stderr=f,start_new_session=True); children.append(holder)
   wait(lambda:(h/'ready').exists()); os.kill(pid,signal.SIGCONT)
   assert holder.wait(timeout=15)==0; rc=p.wait(timeout=30); log('arm exit='+str(rc)+'\n'+text(o)); assert rc==0 and 'check: rearm-resurface' in text(o); log('queue='+text(h/'state/.wake-queue')); drain(h,e)
 scenario('Handling successors deliver queued synthetic recovery work after real queue contention for pending and acknowledged downtime',recovery)
 def ledger():
  h,e=home('ledger',FM_CHECK_INTERVAL=0,FM_GUARD_GRACE=0,FM_ARM_CONFIRM_TIMEOUT=60)
  check=h/'state/synthetic.check.sh'; check.write_text('#!/usr/bin/env bash\nprintf "done: synthetic cycle\\n"\n'); check.chmod(0o700)
  rc,out=run([str(R/'bin/fm-check-register.sh'),'synthetic'],e); assert rc==0,out
  p,o=launch(h,e,label='initial'); assert p.wait(timeout=90)==0; log(text(o)); drain(h,e)
  check.unlink(); (h/'state/synthetic.check-trust').unlink(missing_ok=True)
  e=e|{'FM_CHECK_INTERVAL':'999999','FM_GUARD_GRACE':'300','FM_WATCH_PREDECESSOR_ARM_PID':str(p.pid)}
  p,o=launch(h,e,label='successor'); wait(lambda:'watcher: started' in text(o),40); log(text(o)); pid=(h/'state/.watch.lock/pid').read_text().strip(); assert 'successor=started:'+pid in text(h/'state/.watch-cycle-exits.log')
  assert stop(p)==129; clean(h); drain(h,e)
  for i in range(6):
   p,o=launch(h,e|{'FM_WATCH_CYCLE_LOG_MAX_BYTES':'1400','FM_WATCH_CYCLE_LOG_KEEP_LINES':'2'},label='bounded-'+str(i)); wait(lambda:'watcher: started' in text(o),40); assert stop(p)==129; clean(h); drain(h,e)
  size=(h/'state/.watch-cycle-exits.log').stat().st_size; log('bounded lifecycle ledger bytes='+str(size)); assert size<=1400
 scenario('Real synthetic-check wake, successor interruption, and six subsequent cycles all drain and acknowledge recovery with a bounded lifecycle ledger',ledger)
finally:
 for p in children:
  if p.poll() is None:
   try: os.killpg(p.pid,signal.SIGCONT); os.killpg(p.pid,signal.SIGTERM); p.wait(timeout=15)
   except Exception:
    try: os.killpg(p.pid,signal.SIGKILL); p.wait(timeout=5)
    except ProcessLookupError: pass
 run(['tmux','-S',str(L/'s'),'kill-server'])
 for f in files: f.close()
 (E/('live-results-'+os.environ.get('LIVE_ONLY','initial').replace(',','-')+'.json')).write_text(json.dumps(results,indent=2)+'\n')
 shutil.rmtree(L)
 log('CLEANUP complete: all owned launchers joined, private tmux stopped, disposable homes removed')
