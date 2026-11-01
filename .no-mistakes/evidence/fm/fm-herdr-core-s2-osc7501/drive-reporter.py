import os, sys, pty, fcntl, termios, struct, subprocess, time, select, re, json, pathlib, shlex, signal
ROOT=pathlib.Path.cwd(); WORK=ROOT/'.live-validation'; E=pathlib.Path('~/.no-mistakes/evidence/01M6C5V0SWVRT0HZHREZ8XYXVM')
SCRIPT=str(ROOT/'bin/fm-osc7501.sh'); events=[]
CLEAN=['HC_TERMINAL_ID','HC_TERMINAL_SOCKET','HC_SCOPE','HC_SESSION','HC_SOCKET','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID','REX_BLOCK','REX_SESSION','TERM_PROGRAM','FM_OSC7501_TTY','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']
def note(case,action,**kw):
 rec=dict(scenario=case,action=action,**kw); events.append(rec); print(json.dumps(rec),flush=True)
class Pane:
 def __init__(self,name,harness='opencode',backend='tmux',agent='opencode',marker='ghostty',config=None,extra=':',typed=None):
  self.name=name; self.d=WORK/name; self.d.mkdir(); (self.d/'state').mkdir(); (self.d/'config').mkdir(); self.data=b''
  if config is not None: (self.d/'config/osc7501-status').write_text(config)
  self.master,self.slave=pty.openpty(); fcntl.ioctl(self.slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
  env=dict(os.environ)
  for x in CLEAN: env.pop(x,None)
  env.update(TERM_PROGRAM=marker,FM_HOME=str(self.d),FM_OSC7501_INTERVAL='1',FM_OSC7501_HEARTBEAT='1')
  self.args=['--task','local-proof','--harness',harness,'--backend',backend,'--kind','ship','--state',str(self.d/'state'),'--config',str(self.d/'config'),'--agent-bin',agent]
  cmd=shlex.join(['bash',SCRIPT,'arm']+self.args)+'; '+extra+'; touch '+shlex.quote(str(self.d/'ready'))+'; while [ ! -f '+shlex.quote(str(self.d/'stop'))+' ]; do sleep 0.1; done; '+shlex.join(['bash',SCRIPT,'disarm','--state',str(self.d/'state')])
  def setup():
   os.setsid(); fcntl.ioctl(0,termios.TIOCSCTTY,0)
  self.p=subprocess.Popen(['bash','-c',cmd],stdin=self.slave,stdout=self.slave,stderr=self.slave,env=env,preexec_fn=setup)
  os.close(self.slave)
  if typed is not None: os.write(self.master,typed)
  self.wait(lambda:(self.d/'ready').exists(),10)
 def drain(self,secs=.1):
  end=time.monotonic()+secs
  while time.monotonic()<end:
   if select.select([self.master],[],[],max(0,end-time.monotonic()))[0]:
    try: self.data+=os.read(self.master,65536)
    except OSError: break
 def wait(self,pred,secs=8):
  end=time.monotonic()+secs
  while time.monotonic()<end:
   self.drain(.1)
   if pred(): return
  raise AssertionError(self.name+' deadline: '+repr(self.data[-1000:]))
 def records(self):
  return [dict(p.split('=',1) for p in m.decode().split(':') if '=' in p) for m in re.findall(rb'\x1b\]7501;([^\x1b\x07]*)(?:\x1b\\|\x07)',self.data)]
 def expect(self,state,kind=None):
  self.wait(lambda:len(self.records())>0 and self.records()[-1].get('state')==state and (kind is None or self.records()[-1].get('kind')==kind))
  note(self.name,'observed OSC 7501',record=self.records()[-1])
 def busy(self,v):
  (self.d/'state/local-proof.busy-gen').write_text('g1\n')
  tmp=self.d/'state/busy.tmp'; tmp.write_text(f'v1 gen=g1 seq=1 state={v} source=fm-spawn event=manual ts={int(time.time())}\n'); tmp.replace(self.d/'state/local-proof.busy-state')
 def status(self,s): (self.d/'state/local-proof.status').write_text(s)
 def unknown(self):
  for f in ['local-proof.busy-gen','local-proof.busy-state']: (self.d/'state'/f).unlink(missing_ok=True)
 def watchers(self): return list((self.d/'state').glob('.osc7501watch-*'))
 def close(self):
  (self.d/'stop').touch()
  deadline=time.monotonic()+25
  while self.p.poll() is None and time.monotonic()<deadline: self.drain(.1)
  if self.p.poll() is None:
   self.p.kill(); self.p.wait(); raise RuntimeError(self.name+' did not exit after disarm')
  rc=self.p.wait()
  self.drain(.3); os.close(self.master)
  (E/(self.name+'.tty')).write_bytes(self.data)
  assert rc==0,(self.name,rc)
  assert not self.watchers(),(self.name,'watcher survived disarm')
  note(self.name,'ordinary disarm completed',exit_code=rc,records=len(self.records()))
panes=[]
try:
 p=Pane('status-transitions'); panes.append(p); p.busy('busy'); p.expect('working')
 p.status('paused [at=1]: waiting on CI\n'); p.drain(1.5); p.expect('working'); p.busy('idle'); p.expect('idle')
 p.status('needs-decision [at=2] [key=q1]: choose a color?\n'); p.expect('blocked','question')
 p.status('needs-decision [at=2] [key=q1]: choose a color?\nresolved [at=3] [key=q1]: blue\n'); p.expect('idle')
 p.status('blocked [at=4] [key=a1]: missing API token\n'); p.expect('blocked','auth')
 p.status('done [at=5]: PR https://example.test/pr/99\n'); p.expect('done')
 p.busy('busy'); p.expect('working'); p.busy('idle'); p.expect('done')
 p.status('failed [at=6]: synthetic build failure\n'); p.expect('error'); p.close(); panes.remove(p); assert p.records()[-1]['state']=='error'
 p=Pane('exit-parks-idle'); panes.append(p); p.busy('busy'); p.expect('working'); p.close(); panes.remove(p); assert p.records()[-1]['state']=='idle'
 for name,kw in [('unknown-terminal',dict(marker='unrecognized-terminal')),('config-off',dict(config='off\n')),('invalid-config',dict(config='onn\n')),('old-herdr',dict(backend='herdr')),('no-tty-backend',dict(backend='t3code')),('unresolved-identity',dict(agent=''))]:
  p=Pane(name,**kw); panes.append(p); p.busy('busy'); p.drain(1.4); assert not p.watchers(); assert not p.records(); note(name,'no watcher and zero protocol output')
  if name=='invalid-config': assert b'unknown value; using off' in p.data; note(name,'visible config warning',output=p.data.decode(errors='replace'))
  p.close(); panes.remove(p)
 claude=subprocess.run(['claude','--version'],capture_output=True,text=True,timeout=8,check=True).stdout.strip(); note('native-claude','actual executable version',version=claude)
 p=Pane('native-claude',harness='claude',agent='claude'); panes.append(p); p.busy('busy'); p.status('needs-decision [at=1] [key=q1]: must not replace native status\n'); p.drain(2); assert not p.watchers() and not p.records(); p.close(); panes.remove(p)
 p=Pane('codex-probe-fails-closed',harness='codex',agent='codex'); panes.append(p); p.busy('busy'); p.drain(1); assert not p.watchers() and not p.records(); p.close(); panes.remove(p)
 p=Pane('unknown-activity'); panes.append(p); p.busy('idle'); p.status('needs-decision [at=1] [key=q1]: approve?\n'); p.expect('blocked','question'); p.unknown(); p.drain(2); n=len(p.records()); p.status('done [at=2]: previous result\nneeds-decision [at=3] [key=q2]: another question\n'); p.drain(3); assert len(p.records())==n; note(p.name,'unknown activity: no heartbeat despite old done and open question',records_before=n,records_after=len(p.records()))
 p.status('done [at=4]: result\n'); p.busy('idle'); p.expect('done'); p.unknown(); p.drain(2); n=len(p.records()); p.close(); panes.remove(p); assert len(p.records())==n; note('unknown-activity','unknown activity: ordinary disarm writes no final record',records=n)
 # Input preservation is executed through arm on a real controlling pty; a
 # following shell read, not a source inspection, owns the oracle.
 p=Pane('typed-input',marker='unrecognized-terminal',extra='IFS= read -r input; printf "READBACK=%s\\n" "$input"',typed=b'input queued during startup\n'); panes.append(p)
 assert b'READBACK=input queued during startup' in p.data and not p.records(); note(p.name,'startup input preserved',readback='input queued during startup'); p.close(); panes.remove(p)
finally:
 for p in panes:
  try: p.close()
  except Exception as e: note(p.name,'cleanup error',error=str(e))
 (E/'reporter-live.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in events))
