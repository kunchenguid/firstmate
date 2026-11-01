import os, subprocess, pathlib, json, socket, threading, shutil, time
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6BF92S5VA9MF5NGKG3RB8MN')
env=dict(os.environ)
for k in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID','CMUX_WORKSPACE_ID','__CFBundleIdentifier','PASEO_AGENT_ID','TERM_PROGRAM','REX_BLOCK','REX_SESSION','FM_BACKEND','HC_TERMINAL_ID','HC_TERMINAL_SOCKET','HC_SCOPE','HC_SOCKET','HERDR_APP_HOME','FM_SUPERVISOR_BACKEND','FM_SUPERVISOR_TARGET','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']:
 env.pop(k,None)
env.update(HOME=str(R/'.live-test/home'),TMPDIR=str(R/'.live-test/tmp'),FM_HC_BIN=str(R/'.live-test/tools/herdr-core'),FM_HC_LAB_DIR=str(R/'.live-test/labs'),FM_HC_LAB_SOCK_DIR=str(E/'s'),FM_CONFIG_OVERRIDE=str(R/'.live-test/config'))
(R/'.live-test/config').mkdir(exist_ok=True)
S='fm-hclab-m'; helper=str(R/'bin/fm-hc-lab.sh')
def run(args,ee=None,ok=True):
 p=subprocess.run(args,env=ee or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=50)
 print(json.dumps({'argv':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}),flush=True)
 if ok: assert p.returncode==0
 return p
owned=False; listener=None; thread=None; stop=threading.Event()
try:
 run([helper,'provision',S]); owned=True
 sock=run([helper,'socket',S]).stdout.strip()
 env.update(HC_SESSION=S,FM_HC_SOCKET=sock)
 labeled=json.loads(run([helper,'run',S,'run','--bg','--no-parent','--label','herdr.space=synthetic-app','--label','herdr.tab=probe']).stdout)['address']
 bare=json.loads(run([helper,'run',S,'run','--bg','--no-parent']).stdout)['address']
 def resolve(name,expected,extra=None,notice=None,quiet=False):
  ee=dict(env); ee.update(extra or {})
  p=run(['/bin/bash','-c','. "$1/bin/fm-backend.sh"; fm_backend_resolve; printf "backend=%s\\nsignal=%s\\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"','_',str(R)],ee)
  assert p.stdout.splitlines()[0]=='backend='+expected,(name,p.stdout)
  if notice: assert notice in p.stderr,(name,p.stderr)
  if quiet: assert not p.stderr,(name,p.stderr)
  print('SCENARIO PASS: '+name,flush=True)
 resolve('Headless isolated home stays tmux','tmux',quiet=True)
 resolve('Bare markers on live unlabeled core terminal do not select','tmux',{'HC_TERMINAL_ID':bare,'HC_TERMINAL_SOCKET':sock},quiet=True)
 marks={'HC_TERMINAL_ID':labeled,'HC_TERMINAL_SOCKET':sock}
 resolve('Real labeled terminal selects app-terminal','hc',marks,notice='Herdr-app-projected terminal')
 resolve('Missing binary in surviving projected terminal warns and falls back','tmux',dict(marks,FM_HC_BIN=str(R/'.live-test/no-hc')),notice='no usable hc toolchain')
 tools=R/'.live-test/no-jq'; tools.mkdir(exist_ok=True)
 for tool in ['python3','uname','ps','dirname','env','tr']:
  p=tools/tool
  if not p.exists(): p.symlink_to(shutil.which(tool))
 resolve('Missing jq in surviving projected terminal warns and falls back','tmux',dict(marks,PATH=str(tools)),notice='no usable hc toolchain')
 resolve('Labeled terminal on a different endpoint cannot steer spawn','tmux',dict(marks,FM_HC_SOCKET=str(E/'missing-core.sock')),quiet=True)
 resolve('Dead terminal socket cannot select or start a core','tmux',dict(marks,HC_TERMINAL_SOCKET=str(E/'missing.sock')),quiet=True)
 resolve('Contradictory tmux markers retain earlier verdict','tmux',dict(marks,TMUX='synthetic-private-socket,1,0'),quiet=True)
 resolve('Contradictory classic Herdr markers retain earlier verdict','herdr',dict(marks,HERDR_ENV='1'),quiet=True)
 resolve('Contradictory Rex markers retain earlier verdict','rex',dict(marks,TERM_PROGRAM='rex',REX_SESSION='session:x',REX_BLOCK='block:y'),quiet=True)
 resolve('Explicit environment selection beats app terminal','zellij',dict(marks,FM_BACKEND='zellij'),quiet=True)
 cfg=R/'.live-test/config/backend'; cfg.write_text('tmux\n')
 resolve('Explicit config selection beats app terminal','tmux',marks,quiet=True); cfg.unlink()
 app=E/'w'; app.mkdir(exist_ok=True); path=app/'herdr-app.sock'
 listener=socket.socket(socket.AF_UNIX); listener.bind(str(path)); listener.listen(10); listener.settimeout(.1)
 def serve():
  while not stop.is_set():
   try: c,_=listener.accept(); c.close()
   except socket.timeout: pass
 thread=threading.Thread(target=serve); thread.start()
 window={'HERDR_APP_HOME':str(app)}
 resolve('Synthetic live app control endpoint selects running real core','hc',window,notice='live Herdr app window')
 resolve('Live window with missing binary warns instead of switching','tmux',dict(window,FM_HC_BIN=str(R/'.live-test/no-hc')),notice='no usable hc toolchain')
 resolve('Live window with missing jq warns instead of switching','tmux',dict(window,PATH=str(tools)),notice='no usable hc toolchain')
 before=list((R/'.live-test/labs').rglob('*'))
 resolve('Live window without running target core refuses autostart','tmux',dict(window,FM_HC_SOCKET=str(E/'absent-core.sock'),HC_SESSION='fm-hclab-absent'),notice='rather than starting one')
 assert before==list((R/'.live-test/labs').rglob('*'))
 stop.set(); thread.join(); listener.close(); listener=None
 resolve('Stale app socket does not select','tmux',window,quiet=True)
 path.unlink()
 resolve('Absent app socket does not select','tmux',window,quiet=True)
 # Run discovery and daemon under the real terminal's own injected HC identity.
 labhome=R/'.live-test/daemon-home'
 run([str(R/'bin/fm-lab-home.sh'),'create',str(labhome)])
 command=f'. "{R}/bin/fm-supervisor-target-lib.sh"; printf "target="; discover_supervisor_target; printf "\\nbackend="; discover_supervisor_backend; printf "\\n"; FM_HOME="{labhome}" FM_STATE_OVERRIDE="{labhome}/state" "{R}/bin/fm-supervise-daemon.sh"; rc=$?; echo daemon_exit=$rc'
 addr=json.loads(run([helper,'run',S,'run','--bg','--no-parent','sh','-c',command]).stdout)['address']
 run([helper,'run',S,'wait',addr],ok=False)
 p=run([helper,'run',S,'read',addr,'--lines','200'])
 assert 'target='+S+':'+addr in p.stdout,p.stdout
 assert 'backend=hc' in p.stdout and "does not support supervisor backend 'hc'" in p.stdout and 'daemon_exit=1' in p.stdout
 print('SCENARIO PASS: Real hc terminal resolves itself and away daemon fails closed before steering tmux',flush=True)
finally:
 stop.set()
 if thread: thread.join()
 if listener: listener.close()
 if owned: run([helper,'teardown',S])
print('ALL LIVE BOUNDARIES COMPLETE')
