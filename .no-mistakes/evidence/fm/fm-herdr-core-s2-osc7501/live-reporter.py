import os, sys, pty, fcntl, termios, struct, subprocess, select, time, signal, pathlib, tempfile, shlex, re, json, shutil
import faulthandler
faulthandler.dump_traceback_later(60, repeat=True)
ROOT=pathlib.Path.cwd(); E=pathlib.Path(sys.argv[1]); lab=pathlib.Path(tempfile.mkdtemp(prefix='.osc-live-',dir=ROOT))
master,slave=pty.openpty(); fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
env=dict(os.environ)
for k in list(env):
 if k.startswith(('HC_','HERDR_','REX_','FM_OSC7501_')) or k=='TERM_PROGRAM': env.pop(k,None)
env.update(TERM_PROGRAM='ghostty',FM_OSC7501_INTERVAL='1',FM_OSC7501_HEARTBEAT='2')
def session():
 os.setsid(); fcntl.ioctl(slave,termios.TIOCSCTTY,0)
p=subprocess.Popen(['bash','--noprofile','--norc','-c','while IFS= read -r cmd; do eval "$cmd"; done'],stdin=subprocess.PIPE,stdout=slave,stderr=slave,env=env,preexec_fn=session)
buf=b''; entries=[]; cases=[]; watchers=set(); counter=0
pattern=re.compile(rb'\x1b\]7501;([^\x1b]*)\x1b\\')
def drain(secs=.1):
 global buf
 end=time.monotonic()+secs
 while time.monotonic()<end:
  if select.select([master],[],[],max(0,end-time.monotonic()))[0]:
   try: buf+=os.read(master,65536)
   except OSError: break
 return [dict(x.decode().split('=',1) for x in rec.split(b':')) for rec in pattern.findall(buf)]
def command(args,timeout=45):
 global counter
 counter+=1; marker=f'COMMAND_DONE_{counter}'
 text=shlex.join([str(a) for a in args])+f'; rc=$?; printf "\\n{marker}:%s\\n" "$rc"'
 p.stdin.write((text+'\n').encode()); p.stdin.flush(); end=time.monotonic()+timeout
 while (marker+':').encode() not in buf:
  drain(.05)
  if time.monotonic()>end: raise AssertionError('command timeout '+text)
 assert re.search((marker+':0').encode(),buf),text
 entries.append({'command':shlex.join([str(a) for a in args]),'records':drain()[-3:]})
def home(name):
 d=lab/name; (d/'state').mkdir(parents=True); (d/'config').mkdir(); return d
def arm(d,h='opencode',agent='opencode'):
 command(['bash',ROOT/'bin/fm-osc7501.sh','arm','--task','worker','--harness',h,'--agent-bin',agent,'--backend','tmux','--kind','ship','--state',d/'state','--config',d/'config'])
 fs=list((d/'state').glob('.osc7501watch-*'))
 if fs:
  pid=int(fs[0].read_text().split()[0]); watchers.add(pid); return pid
 return None
def disarm(d):
 print('DISARM '+str(d),flush=True)
 command(['bash',ROOT/'bin/fm-osc7501.sh','disarm','--state',d/'state'])
 print('DISARM completed',flush=True)
def busy(d,state='busy'):
 (d/'state/worker.busy-gen').write_text('g1\n'); (d/'state/worker.busy-state').write_text(f'v1 gen=g1 seq=1 state={state} source=fm-spawn event=launch ts={int(time.time())}\n')
def unknown(d):
 for n in ['worker.busy-state','worker.busy-gen']:
  (d/'state'/n).unlink(missing_ok=True)
def status(d,s):
 with (d/'state/worker.status').open('a') as f: f.write(s+'\n')
def waitstate(want,timeout=6):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  records=drain(.1)
  if records and records[-1]['state']==want: return
 raise AssertionError('wanted '+want+' got '+str(drain()[-5:]))
def noreporter(d): assert not list((d/'state').glob('.osc7501watch-*'))
def passed(name):
 cases.append(name); entries.append({'PASS':name,'last_records':drain()[-6:]}); print('PASS '+name,flush=True)
try:
 # A known non-native reporter with actual /dev/tty output and durable synthetic inputs.
 d=home('signals'); pid=arm(d); waitstate('idle')
 status(d,'needs-decision [at=1] [key=k]: choose'); waitstate('blocked')
 status(d,'resolved [at=2] [key=k]: proceed'); waitstate('idle')
 n=len(drain()); drain(3); assert len(drain())==n,'unknown activity heartbeated'
 for verb,expected in [('done','done'),('failed','error')]:
  status(d,verb+' [at=3]: previous result'); busy(d); waitstate('working'); unknown(d); waitstate('idle')
  n=len(drain()); drain(2); assert len(drain())==n,'stale result or heartbeat'
  status(d,verb+' [at=3]: fresh appended result'); waitstate(expected)
 status(d,'captain-held [at=4]: captain owns it'); waitstate('blocked')
 status(d,'done [at=5]: final outcome'); waitstate('done'); disarm(d); waitstate('done'); noreporter(d)
 passed('Synthetic durable signals on real PTY: unknown clears blocked/working once; stale results stay idle; fresh done/error and captain hold report; exit preserves done')
 # The real launch order: watcher death -> disarm -> off/native arm on the same tty.
 for outcome,want in [('working','idle'),('done','done'),('failed','error')]:
  d=home('dead-'+outcome); busy(d); pid=arm(d); waitstate('working'); os.kill(pid,signal.SIGKILL); time.sleep(.2)
  unknown(d)
  if outcome!='working': status(d,outcome+' [at=1]: worker exit outcome')
  disarm(d); waitstate(want); noreporter(d)
  n=len(drain()); (d/'config/osc7501-status').write_text('off\n'); assert arm(d) is None; drain(2); assert len(drain())==n
  (d/'config/osc7501-status').unlink(); assert arm(d,'claude',shutil.which('claude')) is None; drain(2); assert len(drain())==n
 passed('Real PTY dead watcher: disarm finalizes idle/done/error before removing ownership; off and installed-Claude relaunch add zero records')
 # BASH_ENV holds the real watcher's shell startup before the script can install its trap.
 d=home('early-term'); hook=d/'startup.sh'; marker=d/'initializing'
 hook.write_text('if [ "${FM_OSC7501_WATCHER:-}" = 1 ]; then echo $$ > '+shlex.quote(str(marker))+'; sleep 3; fi\n')
 command(['export','BASH_ENV='+str(hook)]); pid=arm(d); waitstate('idle')
 deadline=time.monotonic()+5
 while not marker.exists():
  drain(.05); assert time.monotonic()<deadline,'watcher did not initialize'
 assert int(marker.read_text())==pid
 status(d,'done [at=1]: short worker already finished'); n=len(drain()); disarm(d); waitstate('done'); noreporter(d)
 assert len(drain())==n+1,'retirement must fold the outcome missed by early TERM'
 command(['unset','BASH_ENV'])
 passed('Real PTY early TERM during shell initialization: short worker done survives grace retirement before watcher trap exists')
 # Freeze actual watcher, not a substitute process: TERM cannot be handled, so retirement must escalate.
 for outcome,want in [('working','idle'),('done','done'),('failed','error')]:
  d=home('stopped-'+outcome); busy(d); pid=arm(d); waitstate('working'); os.kill(pid,signal.SIGSTOP)
  unknown(d)
  if outcome!='working': status(d,outcome+' [at=1]: worker finished during blocked capture')
  n=len(drain()); start=time.monotonic(); disarm(d); elapsed=time.monotonic()-start
  waitstate(want); noreporter(d); assert elapsed>=5 and elapsed<45,(elapsed,'not bounded escalation'); entries.append({'retirement_seconds':elapsed})
  assert len(drain())==n+1,'stopped watcher should have exactly one retirement emit'
 passed('Real PTY live-but-stopped watcher: TERM grace expires, KILL retires it, one final idle/done/error record lands within deadline')
 # Gates must never arm or emit on a clean pane; use installed agent identity, not a fake version executable.
 d=home('clean-gates'); n=len(drain()); assert arm(d,'claude',shutil.which('claude')) is None
 (d/'config/osc7501-status').write_text('off\n'); assert arm(d) is None
 disarm(d); drain(3); assert len(drain())==n
 passed('Clean real PTY: installed native-Claude gate, reporting off, and disarm without ownership produce no OSC bytes')
except BaseException:
 import traceback; traceback.print_exc()
 raise
finally:
 drain(.2); (E/'live-reporter.pty').write_bytes(buf); (E/'live-reporter.json').write_text(json.dumps({'cases':cases,'transcript':entries,'records':drain()},indent=2))
 for pid in watchers:
  try: os.kill(pid,signal.SIGKILL)
  except ProcessLookupError: pass
 p.stdin.close()
 try: p.wait(timeout=3)
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGKILL); os.killpg(p.pid,signal.SIGCONT); p.wait(timeout=5)
 drain(.2); (E/'live-reporter.pty').write_bytes(buf); (E/'live-reporter.json').write_text(json.dumps({'cases':cases,'transcript':entries,'records':drain()},indent=2))
 os.close(master); os.close(slave); shutil.rmtree(lab)
