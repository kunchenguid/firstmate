import os, pathlib, subprocess, json, time, shutil, stat, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M71CSGESZJH0GDRK9XQPKK4T')
LAB=ROOT/'.posture-live-lab'
LOG=[]
base={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE')}
env=base.copy()
def note(s):
 print(s,flush=True); LOG.append(s)
def run(args, extra=None, ok=True, show=True, timeout=45):
 e=env.copy(); e.update(extra or {})
 p=subprocess.run([str(x) for x in args],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 if show: note('$ '+' '.join(map(str,args))+'\n'+p.stdout+'[exit '+str(p.returncode)+']')
 if ok and p.returncode: raise AssertionError(p.stdout)
 return p

def launch(*a,**kw): return run(['bin/fm-afk-launch.sh',*a],**kw)
def mode(): return run(['bin/fm-afk-contract.sh','mode'],show=False).stdout.strip()
def ready():
 p=run(['bin/fm-inbox.sh','ready'],show=False)
 j=json.loads(p.stdout); note('fm-inbox.sh ready: '+json.dumps(j,sort_keys=True)); return j['posture']['state']
def alive(pid):
 try: os.kill(pid,0); return True
 except ProcessLookupError: return False
def snapshot():
 return {n:(LAB/'state'/n).read_bytes() for n in ('.afk-contract','.afk','.afk-daemon-terminal')}
def daemon_pid():
 p=LAB/'state/.supervise-daemon.lock/pid'
 return int(p.read_text()) if p.exists() else None

def wait_for_daemon():
 for _ in range(100):
  pid=daemon_pid()
  if pid and alive(pid): return pid
  time.sleep(.1)
 raise AssertionError('real daemon did not acquire lock')

started=False
try:
 run(['bin/fm-lab-home.sh','create',LAB])
 env['FM_HOME']=str(LAB)
 # The supported helper owns a short ephemeral private toolchain socket directory.
 env['TMUX_TMPDIR']=run(['bin/fm-lab-home.sh','tmux-dir',LAB],show=False).stdout.strip()
 env['FM_TEST_HARNESS']='claude'; env['FM_TEST_SEAM']='1'
 note('Oracle: author intent option A: record mode wins; without a record the legacy flag word wins; neither means present in readiness.')
 for record in ('none','away','quiet'):
  for flag in ('none','away','quiet'):
   p=LAB/'state/.afk-contract'
   if p.exists(): run(['bin/fm-afk-contract.sh','archive'],show=False)
   if record!='none': run(['bin/fm-afk-contract.sh','enter','--words','synthetic posture matrix'],extra={'FM_AFK_MODE':record},show=False)
   f=LAB/'state/.afk'
   if f.exists(): f.unlink()
   if flag!='none':
    run(['bash','-c','. bin/fm-afk-start.sh; fm_afk_flag_write "$FM_HOME/state" "$1"','_',flag],show=False)
   expected=record if record!='none' else (flag if flag!='none' else 'present')
   actual=ready()
   read=run(['bash','-c','. bin/fm-wake-lib.sh; fm_afk_mode "$FM_HOME/state"'],show=False).stdout.strip()
   note(f'MATRIX record={record} flag={flag}: ready={actual}, fm_afk_mode={read}, expected_ready={expected}')
   assert actual==expected
   assert read==(expected if expected!='present' else 'away')
 note('SCENARIO PASS: all nine record/flag readiness and shared-mode combinations')
 run(['bin/fm-afk-contract.sh','archive'],show=False)
 (LAB/'state/.afk').unlink(missing_ok=True)
 (LAB/'config/supervision-host').touch()
 cli_env=env.copy()
 for k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_HARNESS','FM_TEST_SEAM'):
  cli_env.pop(k,None)
 # The actual installed CLI, not a stand-in. No login or credential changes.
 p=subprocess.run(['tmux','-L','fm-lab','new-session','-d','-x','120','-y','36','-s','primary','-c',str(ROOT),'-e','FM_HOME='+str(LAB),'claude'],env=cli_env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 note('tmux private lab primary: claude [exit '+str(p.returncode)+'] '+p.stdout)
 assert p.returncode==0
 started=True
 time.sleep(3)
 run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'])
 tmux=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0'],show=False).stdout.strip()
 pane=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{pane_id}'],show=False).stdout.strip()
 env.update(TMUX=tmux,TMUX_PANE=pane,FM_SUPERVISOR_TARGET=pane,FM_SUPERVISOR_BACKEND='tmux')
 p=launch('quiet-check',ok=False); assert p.returncode==1
 launch('enter','--words','quiet lab posture',extra={'FM_AFK_MODE':'quiet'})
 launch('start')
 pid=wait_for_daemon(); note(f'Actual fm-supervise-daemon pid={pid}')
 run(['ps','-p',str(pid),'-o','pid=,command='])
 assert mode()=='quiet' and ready()=='quiet'
 before=snapshot()
 for args in [('enter','--words-file',str(LAB/'missing-words')),('enter','--expected-return','not-a-time')]:
  p=launch(*args,ok=False); assert p.returncode!=0
  assert snapshot()==before and alive(pid) and mode()=='quiet'
  note('Refused entry preserved all three persisted records byte-for-byte and the real daemon remained alive.')
 # Hold the real record lock with a real live process (this Python driver).
 lock=LAB/'state/.afk-contract.lock'
 identity=run(['bash','-c','. bin/fm-wake-lib.sh; fm_pid_identity "$1"','_',str(os.getpid())],show=False).stdout.strip()
 lock.mkdir(); (lock/'pid').write_text(str(os.getpid())); (lock/'pid-identity').write_text(identity)
 try:
  p=launch('enter','--words','blocked by concurrent record holder',extra={'FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT':'1'},ok=False)
  assert p.returncode!=0 and snapshot()==before and alive(pid)
  note('Lock refusal preserved quiet record, flag, terminal record and real daemon.')
 finally: shutil.rmtree(lock)
 # A real filesystem refusal while preparing record publication (superseded archive), no wrapped/stubbed command.
 contract=LAB/'state/.afk-contract'
 os.chflags(contract,stat.UF_IMMUTABLE)
 try:
  p=launch('enter','--words','blocked publication',ok=False)
  assert p.returncode!=0 and snapshot()==before and alive(pid)
  note('Immutable-record archive/publication-preparation refusal preserved all quiet state and the real daemon.')
 finally: os.chflags(contract,0)
 note('SCENARIO PASS: invalid arguments, lock contention and publication failure leave daemon-backed quiet mode intact')
 launch('enter','--words','merge anything green')
 assert mode()=='away' and ready()=='away'
 for _ in range(100):
  if not alive(pid): break
  time.sleep(.1)
 assert not alive(pid)
 assert not (LAB/'state/.afk').exists() and not (LAB/'state/.afk-daemon-terminal').exists()
 sessions=run(['tmux','-L','fm-lab','list-sessions']).stdout
 assert sessions.count('\n')==1 and sessions.startswith('primary:')
 note('SCENARIO PASS: away entry kept the away record, stopped the real quiet daemon and exact daemon terminal, cleared the flag, and preserved primary')
 p=launch('start',ok=False); assert p.returncode!=0 and mode()=='away' and ready()=='away'
 launch('stop'); assert ready()=='present'
 note('SCENARIO PASS: host away daemon start refuses without changing away posture; stop archives record and readiness returns present')
 # Non-host boundary: the quiet daemon remains, but its refreshed flag follows away record.
 (LAB/'config/supervision-host-off').touch()
 launch('enter','--words','quiet non-host',extra={'FM_AFK_MODE':'quiet'})
 launch('start'); pid=wait_for_daemon()
 launch('enter','--words','away non-host')
 assert alive(pid) and mode()=='away' and ready()=='away'
 assert (LAB/'state/.afk').read_text().splitlines()[0]=='quiet'
 launch('start')
 assert alive(pid) and (LAB/'state/.afk').read_text().splitlines()[0]=='away'
 note('SCENARIO PASS: non-host away entry preserves real daemon, record wins over stale quiet flag, refresh writes away')
 launch('stop'); assert not alive(pid) and ready()=='present'
 note('ALL LIVE SCENARIOS PASSED')
except Exception:
 note(traceback.format_exc())
 raise
finally:
 if (LAB/'state/.afk-contract').exists(): os.chflags(LAB/'state/.afk-contract',0)
 if started:
  run(['tmux','-L','fm-lab','kill-server'],ok=False)
 if LAB.exists():
  run(['bin/fm-lab-home.sh','teardown',LAB])
  for d, dirs, files in os.walk(LAB):
   for name in files: os.chflags(pathlib.Path(d)/name,0)
  shutil.rmtree(LAB)
 note('Disposable lab and private tmux server removed.')
 (E/'posture-live.log').write_text('\n'.join(LOG)+'\n')
