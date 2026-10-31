import os,sys,time,subprocess,pathlib,shutil,signal,json,re
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M68QJP6Q03GEDV19NYPCD253'); W=ROOT/'.phase-labs'; W.mkdir(exist_ok=True)
base=os.environ.copy()
for k in list(base):
 if k.startswith('FM_') or k in ('STATE','CONFIG','DATA','PROJECTS','TMUX','TMUX_PANE'): base.pop(k,None)
base.update(FM_POLL='2',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WEDGE_ALARM_EXEC='discard',FM_HOME_SUMMARY_TIMEOUT='2')
children=[]; results=[]
def run(args,env,timeout=60): return subprocess.run(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
def waitfor(fn,timeout=30):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  if fn(): return
  time.sleep(.025)
 raise RuntimeError('wait timed out')
def start(args,env,out):
 f=open(out,'w'); p=subprocess.Popen(args,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True); f.close(); children.append(p); return p
def text(p): return p.read_text() if p.exists() else ''
def clean(st,foreign=None):
 locks=('.watch.lock','.watch.lock.steal','.wake-queue.lock','.wake-queue.lock.steal','.watcher-down.lock','.watcher-down.lock.steal')
 residue=[str(p.name) for p in st.glob('.*') if any(p.name==k or p.name.startswith(k+'.owner.') for k in locks) and (p.is_dir() or p.is_symlink()) and p.name!=foreign]
 assert not residue, 'lock residue='+repr(residue)
 return 'no singleton, steal, micro-lock, or owner-directory residue'
def drain(env,log):
 p=run([str(ROOT/'bin/fm-wake-drain.sh')],env); log.append('DRAIN rc='+str(p.returncode)+'\n'+p.stdout); assert p.returncode==0
 m=re.search(r'WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',p.stdout); assert m,'no recovery ack contract'
 p=run([str(ROOT/'bin/fm-wake-drain.sh'),'--ack-through',m[1],'--recovery-generation',m[2]],env); log.append('ACK rc='+str(p.returncode)+'\n'+p.stdout); assert p.returncode==0

def case(name,fn):
 home=W/name; home.mkdir(); env=base.copy(); env['FM_HOME']=str(home); env['TMUX']=str(home/'tmux/socket')+',0,0'; env['TMUX_TMPDIR']=str(home/'tmux'); log=['SCENARIO '+name]; t=time.monotonic()
 p=run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(home)],env); assert p.returncode==0,p.stdout
 (home/'tmux').mkdir(); st=home/'state'
 try:
  fn(home,st,env,log)
  result='pass'
 except Exception as ex:
  result='fail'; log.append('ERROR '+repr(ex))
 finally:
  for p in children:
   if p.poll() is None:
    os.killpg(p.pid,signal.SIGTERM)
    try:p.wait(timeout=15)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();log.append('FORCED process cleanup '+str(p.pid))
  log.append('elapsed=%.2fs'%(time.monotonic()-t))
  for p in home.glob('*.out'):log.append(p.name+'\n'+text(p))
  for name2 in ('.watch-cycle-exits.log','.watcher-down','.wake-queue'):
   p=st/name2
   if p.exists():log.append(name2+'\n'+text(p))
  log.append('FINAL_STATE '+repr(sorted(p.name for p in st.iterdir())))
  # Await detached side-band publishers too before removing their lab.
  for attempt in range(300):
   snapshot=subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,stat=,command='],text=True)
   owned=[line for line in snapshot.splitlines() if str(home) in line and ' Z' not in line]
   if not owned:break
   time.sleep(.1)
  else:raise RuntimeError('lab descendants remain: '+repr(owned))
  shutil.rmtree(home)
  log.append('lab removed; all direct children awaited; no lab descendants in process inventory')
  (E/(name+'.log')).write_text('\n'.join(log)+'\n')
  results.append(dict(name=name,result=result,evidence=str(E/(name+'.log')))); print(name,result,log[-3:],flush=True)

def slow(h,st,env,l):
 env['FM_TEST_WATCHER_PRE_IDENTITY_DELAY']='13'; out=h/'arm.out'; p=start([str(ROOT/'bin/fm-watch-arm.sh')],env,out); t=time.monotonic(); waitfor(lambda:'watcher: started' in text(out),120); l.append('confirmed after %.2fs'%(time.monotonic()-t)); assert time.monotonic()-t>10
 p.send_signal(signal.SIGHUP); assert p.wait(timeout=30)==129; l.append(clean(st));drain(env,l)

def held(h,st,env,l):
 # Real production lock library holds a foreign live queue lock, not a watcher stub.
 holder=start(['bash','-c','. "$1"; fm_lock_acquire_wait "$FM_HOME/state/.wake-queue.lock" || exit 2; touch "$FM_HOME/ready"; while [ ! -e "$FM_HOME/release" ]; do sleep .05; done; fm_lock_release "$FM_HOME/state/.wake-queue.lock"','_',str(ROOT/'bin/fm-wake-lib.sh')],env,h/'holder.out');waitfor(lambda:(h/'ready').exists()); (st/'.last-watcher-beat').touch(); env['FM_WATCHER_STARTUP_LOCK_BOUND']='2';t=time.monotonic();p=run([str(ROOT/'bin/fm-watch-arm.sh')],env,30);(h/'arm.out').write_text(p.stdout);l.append('arm rc=%s duration=%.2fs'%(p.returncode,time.monotonic()-t));assert p.returncode!=0;assert 'watcher: started' not in p.stdout;assert 'watcher: FAILED - startup lock' in p.stdout,p.stdout;assert str(holder.pid) in p.stdout
 (h/'release').touch();assert holder.wait(timeout=10)==0;l.append(clean(st));drain(env,l)

def signals(h,st,env,l):
 foreign=st/'.wake-queue.lock.owner.foreign'; foreign.mkdir();(foreign/'pid').write_text(str(os.getpid())+'\n')
 for i in range(12):
  env['FM_TEST_WATCHER_PRE_IDENTITY_DELAY']='1';(h/'config/watch.env').write_text('FM_ARM_CONFIRM_TIMEOUT='+('30' if i%2==0 else '60')+'\n');out=h/('arm-%02d.out'%i);p=start([str(ROOT/'bin/fm-watch-arm.sh')],env,out)
  waitfor(lambda:(st/'.watch.lock/pid').exists());pid=text(st/'.watch.lock/pid').strip();sig=signal.SIGHUP if i%2==0 else signal.SIGTERM;p.send_signal(sig);rc=p.wait(timeout=35);assert rc==(129 if sig==signal.SIGHUP else 143),rc
  assert (foreign/'pid').read_text().strip()==str(os.getpid());l.append('iteration=%s signal=%s watcher=%s rc=%s %s; foreign owner preserved'%(i,sig.name,pid,rc,clean(st,foreign.name)))
  assert 'lock_after=pid:none' in text(st/'.watch-cycle-exits.log');drain(env,l)
 foreign.unlink() if foreign.is_symlink() else shutil.rmtree(foreign)
 # Exercise the precise interrupted external-mutation race on the real watcher.
 for tool in ('mktemp','ln'):
  real=shutil.which(tool); faults=h/('fault-'+tool);faults.mkdir(); wrapper=faults/tool
  wrapper.write_text('''#!/usr/bin/env bash
trap '' HUP TERM
case "$*" in
 *".wake-queue.lock"*)
  if mkdir "$FM_HOME/mutation-once" 2>/dev/null; then
   kill -"$MUTATION_SIGNAL" "$(cat "$FM_HOME/state/.watch.lock/pid")"
   sleep .5
   "$MUTATION_REAL" "$@"
   rc=$?
   touch "$FM_HOME/mutation-done"
   exit "$rc"
  fi ;;
esac
exec "$MUTATION_REAL" "$@"
''');wrapper.chmod(0o755)
  for sig in ('HUP','TERM'):
   for marker in ('mutation-once','mutation-done'):
    path=h/marker
    if path.is_dir():path.rmdir()
    elif path.exists():path.unlink()
   env2=env.copy();env2.pop('FM_TEST_WATCHER_PRE_IDENTITY_DELAY',None);env2.update(PATH=str(faults)+':'+env['PATH'],MUTATION_SIGNAL=sig,MUTATION_REAL=real)
   foreign.mkdir();(foreign/'pid').write_text(str(os.getpid())+'\n')
   p=start([str(ROOT/'bin/fm-watch.sh')],env2,h/('mutation-%s-%s.out'%(tool,sig)));rc=p.wait(timeout=90);waitfor(lambda:(h/'mutation-done').exists(),30)
   assert rc!=0;assert (foreign/'pid').read_text().strip()==str(os.getpid());l.append('late real %s after %s: watcher rc=%s %s; foreign staging preserved'%(tool,sig,rc,clean(st,foreign.name)));drain(env,l);shutil.rmtree(foreign)

def deadline(h,st,env,l):
 env.update(FM_ARM_CONFIRM_TIMEOUT='2',FM_TEST_WATCHER_PRE_IDENTITY_DELAY='7');t=time.monotonic();p=run([str(ROOT/'bin/fm-watch-arm.sh')],env,35);(h/'arm.out').write_text(p.stdout);elapsed=time.monotonic()-t;l.append('arm rc=%s duration=%.2fs'%(p.returncode,elapsed));assert p.returncode==1;assert elapsed>=7;assert 'reason=confirmation-timeout' in text(st/'.watch-cycle-exits.log');assert 'lock_after=pid:none' in text(st/'.watch-cycle-exits.log');l.append(clean(st));drain(env,l)

def identity(h,st,env,l):
 # Inject ps failure at external OS boundary while running unchanged arm/watcher.
 fake=h/'faultbin';fake.mkdir();ps=fake/'ps';ps.write_text('#!/usr/bin/env bash\ncase " $* " in *" lstart= "*" command= "*) exit 1;; esac\nexec /bin/ps "$@"\n');ps.chmod(0o755);env['PATH']=str(fake)+':'+env['PATH'];env['FM_ARM_CONFIRM_TIMEOUT']='2';env['FM_TEST_WATCHER_PRE_IDENTITY_DELAY']='7'
 p=run([str(ROOT/'bin/fm-watch-arm.sh')],env,40);(h/'arm.out').write_text(p.stdout);l.append('arm rc='+str(p.returncode));assert p.returncode!=0;l.append(clean(st));assert 'could not publish watcher identity' in p.stdout,p.stdout

def recovery(h,st,env,l):
 for i in range(3):
  out=h/('arm-%s.out'%i);p=start([str(ROOT/'bin/fm-watch-arm.sh')],env,out);waitfor(lambda:'watcher: started' in text(out),120);p.send_signal(signal.SIGHUP);assert p.wait(timeout=35)==129;l.append('cycle=%s %s'%(i,clean(st)));drain(env,l)
for name,fn in [('slow-start',slow),('held-queue-inherited-beacon',held),('signals-30-60-overrides',signals),('unsafe-deadline',deadline),('identity-probe-failure',identity),('recovery-drain-rearm',recovery)]:
 if len(sys.argv)==1 or name in sys.argv[1:]:case(name,fn)
(E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n');W.rmdir();assert all(p.poll() is not None for p in children)
if any(x['result']=='fail' for x in results):sys.exit(1)
