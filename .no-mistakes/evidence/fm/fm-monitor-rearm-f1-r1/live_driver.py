import os, pathlib, subprocess, time, signal, shutil, re, json
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M68QJP6Q03GEDV19NYPCD253')
BASE=ROOT/'.test-live'
results=[]
class Lab:
 def __init__(self,name):
  self.name=name; self.home=BASE/name; self.children=[]; self.handles=[]
  subprocess.run(['bin/fm-lab-home.sh','create',str(self.home)],check=True,capture_output=True)
  self.state=self.home/'state'
  self.env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('STATE','TMUX','BASH_ENV','CLAUDE_CODE_SESSION_ID','CLAUDE_PID')}
  self.env.update(FM_HOME=str(self.home),TMUX=str(self.home/'unused-socket')+',1,0',TMUX_TMPDIR=str(self.home),TMPDIR=str(BASE),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WEDGE_ALARM_EXEC='/usr/bin/true')
  self.log=open(E/(name+'.log'),'w'); self.start=time.monotonic()
 def note(self,s):
  self.log.write(f'[{time.monotonic()-self.start:.2f}s] {s}\n');self.log.flush()
 def launch(self,extra={}):
  out=self.home/'arm.out'; f=open(out,'w');self.handles.append(f)
  p=subprocess.Popen([str(ROOT/'bin/fm-watch-arm.sh')],env=self.env|extra,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);self.children.append(p)
  self.note(f'RUN bin/fm-watch-arm.sh FM_HOME={self.home} options={extra} arm_pid={p.pid}')
  return p,out
 def wait(self,p,bound=100):
  rc=p.wait(timeout=bound); self.note(f'arm exit={rc}');return rc
 def ready(self,path,bound=15):
  until=time.monotonic()+bound
  while time.monotonic()<until:
   if path.exists():return
   time.sleep(.03)
  raise AssertionError(f'never appeared: {path}')
 def started(self,p,out,bound=45):
  until=time.monotonic()+bound
  while time.monotonic()<until:
   if 'watcher: started pid=' in out.read_text():return
   if p.poll() is not None:raise AssertionError(out.read_text())
   time.sleep(.1)
  raise AssertionError('never confirmed')
 def snapshot(self,out):
  self.note('PRODUCT OUTPUT:\n'+out.read_text())
  ledger=self.state/'.watch-cycle-exits.log'
  if ledger.exists():self.note('PERSISTED CYCLE LEDGER:\n'+ledger.read_text())
 def clean(self,foreign=()):
  residue=[]
  for key in ('.watch.lock','.wake-queue.lock','.watcher-down.lock'):
   for p in self.state.glob(key+'*'):
    if (p.name==key or p.name.startswith(key+'.steal') or p.name.startswith(key+'.owner.')) and p.name not in foreign:residue.append(p.name)
  self.note('startup lock residue='+repr(residue))
  for name in residue:
   path=self.state/name
   self.note(f'RESIDUE {name} symlink={os.readlink(path) if path.is_symlink() else None} files={[(x.name,x.read_text() if x.is_file() else "directory") for x in path.iterdir()]}')
  assert not residue,residue
 def drain(self):
  p=subprocess.run([str(ROOT/'bin/fm-wake-drain.sh')],env=self.env,capture_output=True,text=True,timeout=30)
  self.note(f'RUN bin/fm-wake-drain.sh exit={p.returncode}\n{p.stdout}\n{p.stderr}')
  assert p.returncode==0
  m=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',p.stderr)
  assert m,'no acknowledgement contract'
  p=subprocess.run([str(ROOT/'bin/fm-wake-drain.sh'),'--ack-through',m[1],'--recovery-generation',m[2]],env=self.env,capture_output=True,text=True,timeout=30)
  self.note(f'ACK exit={p.returncode}\n{p.stdout}\n{p.stderr}');assert p.returncode==0
 def close(self):
  for p in self.children:
   if p.poll() is None:
    p.send_signal(signal.SIGTERM)
    try:p.wait(timeout=20)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   # Ensure no descendant from a failed scenario remains in the private group.
   try:os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError:pass
  for f in self.handles:f.close()
  shutil.rmtree(self.home)
  self.note('Disposable lab removed; all launched process leaders waited.');self.log.close()
def run(name,fn):
 lab=Lab(name)
 try:
  fn(lab);lab.note('SCENARIO PASS');results.append(dict(name=name,result='pass'))
 except Exception as e:
  lab.note('SCENARIO FAIL '+repr(e));results.append(dict(name=name,result='fail',error=repr(e)))
 finally:lab.close()
 (E/'live-results.json').write_text(json.dumps(results,indent=2))
def slow(l):
 p,o=l.launch({'FM_TEST_WATCHER_PRE_IDENTITY_DELAY':'15'})
 l.started(p,o);assert time.monotonic()-l.start>14
 p.send_signal(signal.SIGHUP);assert l.wait(p)==129;l.snapshot(o);l.clean();l.drain()
def held(l):
 script='. "$1"; fm_lock_acquire_wait "$2" || exit 1; touch "$3"; while [ ! -e "$4" ]; do sleep .1; done; fm_lock_release "$2"'
 h=subprocess.Popen(['bash','-c',script,'_',str(ROOT/'bin/fm-wake-lib.sh'),str(l.state/'.wake-queue.lock'),str(l.home/'held'),str(l.home/'release')],env=l.env,start_new_session=True);l.children.append(h)
 l.ready(l.home/'held');(l.state/'.last-watcher-beat').touch()
 p,o=l.launch({'FM_WATCHER_STARTUP_LOCK_BOUND':'2'});rc=l.wait(p,20)
 (l.home/'release').touch();assert h.wait(timeout=10)==0
 l.snapshot(o);assert rc!=0;assert 'watcher: started' not in o.read_text();assert f'held by live pid {h.pid}' in o.read_text();l.clean();l.drain()
def deadline(l,budget):
 (l.home/'config/watch.env').write_text(f'FM_ARM_CONFIRM_TIMEOUT={budget}\n')
 p,o=l.launch({'FM_TEST_WATCHER_PRE_IDENTITY_DELAY':str(budget+4)})
 assert l.wait(p,budget+30)==1;l.snapshot(o)
 assert time.monotonic()-l.start>=budget+4
 assert 'reason=confirmation-timeout' in (l.state/'.watch-cycle-exits.log').read_text();l.clean();l.drain()
def signals(l):
 for i in range(8):
  p,o=l.launch({'FM_TEST_WATCHER_PRE_IDENTITY_DELAY':'2','FM_ARM_CONFIRM_TIMEOUT':'1'})
  l.ready(l.state/'.watch.lock/pid');time.sleep(.05)
  # A live foreign acquirer's unpublished owner is not ours to discard.
  foreign=l.state/f'.wake-queue.lock.owner.foreign{i}'
  foreign.mkdir();(foreign/'pid').write_text(str(os.getpid())+'\n')
  p.send_signal(signal.SIGHUP if i%2==0 else signal.SIGTERM)
  assert l.wait(p,20)==(129 if i%2==0 else 143)
  l.snapshot(o);l.clean((foreign.name,));assert (foreign/'pid').read_text().strip()==str(os.getpid())
  shutil.rmtree(foreign);l.drain()
  # Next cycle must begin with no inherited dead singleton.
  assert 'lock_after=pid:none' in (l.state/'.watch-cycle-exits.log').read_text().splitlines()[-1]
def identity_write(l,record):
 p,o=l.launch({'FM_TEST_WATCHER_PRE_IDENTITY_DELAY':'2','FM_ARM_CONFIRM_TIMEOUT':'10'})
 l.ready(l.state/'.watch.lock/pid');(l.state/'.watch.lock'/record).mkdir()
 assert l.wait(p,20)==1;l.snapshot(o)
 assert 'FAILED - could not publish watcher identity' in o.read_text();assert not (l.state/'.last-watcher-beat').exists()
 # The deliberately injected directory is fixture-owned; rm -f cannot remove
 # it, so do not count that inert, pid-less fixture as a dead process lock.
 for owner in l.state.glob('.watch.lock.owner.*'):
  assert not (owner/'pid').exists()
  (owner/record).rmdir();owner.rmdir()
 l.note('Removed only the intentionally injected directory and its pid-less container.')
 l.clean();l.drain()
if os.environ.get('RECHECK_SIGNALS'):
 run('signal-diagnostic-foreign-owner',signals)
for record in ('fm-home','watcher-path','pid-identity'):
 run('unwritable-'+record,lambda l,r=record:identity_write(l,r))
print(json.dumps(results,indent=2))
raise SystemExit(any(x['result']=='fail' for x in results))
