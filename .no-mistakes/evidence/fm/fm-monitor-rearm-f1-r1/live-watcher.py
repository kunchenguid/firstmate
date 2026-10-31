import os, pathlib, subprocess, time, signal, shutil, json
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M68QJP6Q03GEDV19NYPCD253'); W=ROOT/'.live-watcher-labs'; W.mkdir(exist_ok=True)
base={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ['STATE','TMUX','TMUX_PANE','CLAUDE_CONFIG_DIR']}
base.update(TMUX=str(E/'unused-socket')+',0,0', FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WEDGE_ALARM_EXEC='discard')
results=[]
def cmd(args,env,**kw): return subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30,**kw)
def waitfor(f,timeout=30):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  if f(): return
  time.sleep(.1)
 raise AssertionError('wait deadline')
def locks(home):
 return [str(p.relative_to(home/'state')) for p in (home/'state').iterdir() if '.lock' in p.name and (p.is_symlink() or p.is_dir())]
def drain(home,env,log):
 r=cmd([str(ROOT/'bin/fm-wake-drain.sh')],env); log.write('DRAIN rc='+str(r.returncode)+'\n'+r.stdout+'\n'); assert r.returncode==0
 import re
 m=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',r.stdout); assert m,'no ack token'
 r=cmd([str(ROOT/'bin/fm-wake-drain.sh'),'--ack-through',m[1],'--recovery-generation',m[2]],env); log.write('ACK rc='+str(r.returncode)+'\n'+r.stdout+'\n'); assert r.returncode==0

def run(name,mode,budget=None):
 home=W/name; env=base|{'FM_HOME':str(home)}; procs=[]; start=time.monotonic()
 with (E/(name+'.log')).open('w') as log:
  try:
   r=cmd([str(ROOT/'bin/fm-lab-home.sh'),'create',str(home)],env); assert r.returncode==0,r.stdout
   if budget: (home/'config/watch.env').write_text('FM_ARM_CONFIRM_TIMEOUT='+str(budget)+'\n')
   if mode=='slow': env['FM_TEST_WATCHER_PRE_IDENTITY_DELAY']='15'
   if mode in ['deadline','signal']: env['FM_TEST_WATCHER_PRE_IDENTITY_DELAY']=str((budget or 2)+5)
   holder=None
   if mode=='held':
    env['FM_WATCHER_STARTUP_LOCK_BOUND']='2'
    holder=subprocess.Popen(['bash','-c','. "$1"; fm_lock_acquire_wait "$STATE/.wake-queue.lock" || exit; touch "$FM_HOME/ready"; trap \'fm_lock_release "$STATE/.wake-queue.lock"; exit\' TERM; while :; do sleep .1; done','_',str(ROOT/'bin/fm-wake-lib.sh')],env=env,stdout=log,stderr=log,start_new_session=True); procs.append(holder)
    waitfor(lambda:(home/'ready').exists()); (home/'state/.last-watcher-beat').touch()
   if mode=='probe':
    fake=home/'probe-bin'; fake.mkdir(); ps=fake/'ps'; ps.write_text('#!/usr/bin/env bash\ncase " $* " in *" lstart= "*" command= "*) pid=; prev=; for a in "$@"; do [ "$prev" != -p ] || pid=$a; prev=$a; done; command=$(/bin/ps -p "$pid" -o command=); case "$command" in *fm-watch.sh*) exit 1;; esac;; esac\nexec /bin/ps "$@"\n'); ps.chmod(0o755); env['PATH']=str(fake)+':'+env['PATH']; env['FM_ARM_CONFIRM_TIMEOUT']='2'
   if mode=='write':
    # Use the supported unsafe-start delay to deny an identity destination before publication.
    env['FM_TEST_WATCHER_PRE_IDENTITY_DELAY']='3'; env['FM_ARM_CONFIRM_TIMEOUT']='10'
   out=E/(name+'-arm.txt')
   with out.open('w') as stream:
    arm=subprocess.Popen([str(ROOT/'bin/fm-watch-arm.sh')],env=env,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True); procs.append(arm)
    if mode=='write':
     waitfor(lambda:(home/'state/.watch.lock/pid').exists()); (home/'deny-write').mkdir(); (home/'state/.watch.lock/fm-home').symlink_to(home/'deny-write',target_is_directory=True)
    if mode=='signal':
     waitfor(lambda:(home/'state/.watch.lock/pid').exists()); arm.send_signal(signal.SIGHUP)
    if mode=='slow':
     waitfor(lambda:'watcher: started pid=' in out.read_text(),45)
     elapsed=time.monotonic()-start; assert elapsed>10
     log.write('Confirmed after %.2fs (legacy budget 10s)\n'%elapsed); arm.send_signal(signal.SIGHUP)
    rc=arm.wait(timeout=(budget or 10)+45)
   text=out.read_text(); log.write('ARM rc='+str(rc)+' elapsed=%.2fs\n'%(time.monotonic()-start)+text+'\n')
   if holder: holder.terminate(); holder.wait(timeout=10)
   assert rc!=0
   if mode=='held':
    assert 'watcher: started' not in text
    assert 'watcher: FAILED - startup lock ' in text and 'held by live pid' in text
    assert not (home/'state/.last-watcher-beat').exists()
   if mode in ['probe','write']: assert 'watcher: FAILED - could not publish watcher identity' in text
   if mode=='deadline': assert 'watcher: FAILED - no live watcher with a fresh beacon' in text
   if mode=='signal': assert rc==129
   ledger=home/'state/.watch-cycle-exits.log'
   if ledger.exists():
    content=ledger.read_text(); log.write('CYCLE LEDGER\n'+content+'\n')
    if mode in ['signal','deadline']: assert 'lock_after=pid:none' in content
   time.sleep(.5)
   remaining=locks(home); log.write('Remaining lock paths: '+json.dumps(remaining)+'\n')
   for path in remaining:
    for f in (home/'state'/path).iterdir():
     if f.is_file(): log.write('Residual '+path+'/'+f.name+': '+f.read_text()+'\n')
   assert not remaining
   if mode not in ['probe','write']: drain(home,env,log)
   results.append({'name':name,'result':'pass'})
  except Exception as ex:
   log.write('FAILED '+repr(ex)+'\n'); results.append({'name':name,'result':'fail','error':repr(ex)})
  finally:
   for p in procs:
    if p.poll() is None:
     os.killpg(p.pid,signal.SIGTERM)
     try:p.wait(timeout=12)
     except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   shutil.rmtree(home,ignore_errors=True)
for name,mode,budget in [('signal-repeat1','signal',2),('signal-repeat2','signal',2),('signal-repeat3','signal',2)]: run(name,mode,budget)
W.rmdir(); (E/'results.json').write_text(json.dumps(results,indent=2)); print(json.dumps(results,indent=2)); raise SystemExit(any(r['result']=='fail' for r in results))
