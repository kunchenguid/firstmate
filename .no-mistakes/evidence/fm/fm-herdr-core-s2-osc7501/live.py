import os, subprocess as sp, pathlib as P, time, json, shutil
root=P.Path.cwd(); d=root/'.live-test'; ev=P.Path('~/.no-mistakes/evidence/01M6AE01KG33NM41T4D4Y9MGMZ'); log=open(ev/'hc-live.jsonl','w',buffering=1)
env=os.environ.copy()
for k in list(env):
 if k.startswith(('HC_','HERDR_','REX_','FM_')) or k in ('TMUX','TERM_PROGRAM'): env.pop(k,None)
for k,v in {'XDG_STATE_HOME':str(d/'xdg-state'),'XDG_CONFIG_HOME':str(d/'xdg-config'),'XDG_RUNTIME_DIR':str(d/'xdg-run'),'HC_SESSION':'fm-lab-osc7501','HC_SOCKET':str(root/'.s'),'FM_OSC7501_INTERVAL':'1','DISABLE_AUTOUPDATER':'1'}.items(): env[k]=v
for p in ('xdg-state','xdg-config','xdg-run'): (d/p).mkdir(exist_ok=True)
(d/'xdg-config/herdr-core').mkdir(exist_ok=True); (d/'xdg-config/herdr-core/config.toml').write_text('notes = false\n')
hc=str(d/'herdr-core'); reporter=str(root/'bin/fm-osc7501.sh'); terminals=[]; fds=[]
def cmd(*args):
 p=sp.run([hc,*args],env=env,text=True,capture_output=True,timeout=20)
 if p.returncode: raise RuntimeError((args,p.returncode,p.stdout,p.stderr))
 return json.loads(p.stdout)
def record(label,data): log.write(json.dumps({'check':label,'observed':data})+'\n'); print(label, data if isinstance(data,str) else '')
def start(name,extra='',harness='opencode',backend='hc',target=''):
 home=d/name; (home/'state').mkdir(parents=True); (home/'config').mkdir(); os.mkfifo(home/'control'); fd=os.open(home/'control',os.O_RDWR); fds.append(fd)
 script=home/'worker.sh'; script.write_text(f'''#!/bin/bash
set -u
{extra}
arm() {{ '{reporter}' arm --task {name} --harness {harness} --backend {backend} --target '{target}' --kind ship --state '{home}/state' --config '{home}/config'; }}
arm
printf 'WORKER_READY\\n'
while IFS= read -r action; do
 case "$action" in
 rearm) arm; echo REARMED;;
 stop) '{reporter}' disarm --state '{home}/state'; echo DISARMED;;
 esac
done <'{home}/control'
''')
 t=cmd('run','--bg','--name',name,'--no-parent','--','/bin/bash','--noprofile','--norc',str(script))['address']; terminals.append(t)
 time.sleep(2); return home,t,fd
def busy(home,state):
 name=home.name; (home/'state'/f'{name}.busy-gen').write_text('g1\n'); p=home/'state'/f'{name}.busy-state'; q=p.with_suffix('.tmp'); q.write_text(f'v1 gen=g1 seq=1 state={state} source=fm-spawn event=live ts={int(time.time())}\n'); q.replace(p)
def status(home,text): (home/'state'/f'{home.name}.status').write_text(text+'\n')
def expect(t,state,kind=None):
 last={}
 for _ in range(70):
  last=cmd('get',t); s=last.get('status') or {}
  if s.get('state')==state and (kind is None or s.get('kind')==kind): record(f'{t}: expected {state} {kind or ""}',last); return last
  time.sleep(.2)
 record('FAILED expected '+state,last); raise AssertionError(state)
env['TMUX_TMPDIR']=str(root/'.t'); tmuxenv=env.copy(); (root/'.t').mkdir(exist_ok=True)
def tmux(*args): return sp.run(['tmux','-f','/dev/null','-L','fm-lab',*args],env=tmuxenv,text=True,capture_output=True,timeout=15)
try:
 h,t,fd=start('query', 'unset HC_TERMINAL_ID REX_BLOCK REX_SESSION TERM_PROGRAM'); busy(h,'busy'); expect(t,'working'); os.write(fd,b'stop\n')
 h,t,fd=start('mapping'); busy(h,'busy'); expect(t,'working')
 busy(h,'idle'); expect(t,'idle')
 status(h,'needs-decision [at=1] [key=q1]: approve release?'); expect(t,'blocked','question')
 status(h,'blocked [at=2] [key=b1]: login token expired'); expect(t,'blocked','auth')
 status(h,'blocked [at=3] [key=b2]: filesystem permission required'); expect(t,'blocked','permission')
 status(h,'failed [at=4]: build failed'); expect(t,'error')
 status(h,'done [at=5]: PR https://example.test/pull/42'); s=expect(t,'done'); assert 'PR ready' in s['status']['msg']
 busy(h,'busy'); expect(t,'working'); busy(h,'idle'); expect(t,'done')
 status(h,'paused [at=6]: waiting on CI'); expect(t,'idle'); busy(h,'busy'); expect(t,'working')
 # re-arm must retire the first watcher, then cleanup must park idle.
 first=[p.read_text().split()[0] for p in (h/'state').glob('.osc7501watch-*')]; os.write(fd,b'rearm\n'); time.sleep(3)
 second=[p.read_text().split()[0] for p in (h/'state').glob('.osc7501watch-*')]; assert first and second and first!=second
 for pid in first:
  try: os.kill(int(pid),0); raise AssertionError('old watcher survives')
  except ProcessLookupError: pass
 record('rearm replaces and retires watcher',{'old':first,'new':second})
 os.write(fd,b'stop\n'); expect(t,'idle'); time.sleep(3); assert not list((h/'state').glob('.osc7501watch-*')); record('disarm removes watcher',cmd('get',t))
 # A separate done result remains visible after disarm.
 h,t,fd=start('finaldone'); busy(h,'idle'); status(h,'done [at=7]: finished'); expect(t,'done'); os.write(fd,b'stop\n'); time.sleep(4); expect(t,'done')
 for name,extra,harness,backend in [('off','echo off >"$(dirname "$0")/config/osc7501-status"','opencode','hc'),('typo','echo typo >"$(dirname "$0")/config/osc7501-status"','opencode','hc'),('native','','claude','hc'),('legacy','','opencode','herdr'),('headless','','opencode','t3code')]:
  h,t,fd=start(name,extra,harness,backend); busy(h,'busy'); time.sleep(3); got=cmd('get',t); record('gate '+name,got); assert got.get('status') is None and not list((h/'state').glob('.osc7501watch-*'))
  if name=='typo':
   read=sp.run([hc,'read',t],env=env,text=True,capture_output=True,timeout=10).stdout; record('visible config warning',read); assert 'unknown value; using off' in read
  os.write(fd,b'stop\n')
 # Real tmux capture with synthetic Grok screen, not a fake tmux CLI.
 pane=d/'pane.txt'; pane.write_text('working on it\n  Ctrl+c:cancel\n')
 redraw=d/'redraw.sh'; redraw.write_text(f'while :; do clear; cat "{pane}"; sleep 1; done\n')
 p=tmux('new-session','-d','-s','grok','-x','120','-y','40','/bin/bash --noprofile --norc '+str(redraw)); assert p.returncode==0,p.stderr
 sock=tmux('display-message','-p','-t','grok:0.0','#{socket_path}').stdout.strip()
 record('tmux socket',sock); record('busy capture before reporter',tmux('capture-pane','-p','-t','grok:0.0').stdout)
 h,t,fd=start('capture',extra=f"export TMUX='{sock},0,0'\n tmux capture-pane -p -t grok:0.0\n . '{root}/bin/fm-busy-lib.sh'\n . '{root}/bin/fm-backend.sh'\n fm_busy_classify tmux grok:0.0 grok capture '{d}/capture/state'",harness='grok',backend='tmux',target='grok:0.0'); record('worker diagnostic',sp.run([hc,'read',t],env=env,text=True,capture_output=True).stdout); status(h,'done [at=8]: previous turn completed'); expect(t,'working')
 record('real tmux busy viewport',tmux('capture-pane','-p','-t','grok:0.0').stdout)
 pane.write_text('ready\n> \n'); expect(t,'done'); record('real tmux idle viewport',tmux('capture-pane','-p','-t','grok:0.0').stdout); os.write(fd,b'stop\n')
 record('RESULT','all hc live assertions passed')
finally:
 tr=tmux('kill-server'); record('private tmux cleanup',{'exit':tr.returncode,'stderr':tr.stderr})
 for fd in fds: os.close(fd)
 for t in terminals:
  try: cmd('kill',t)
  except Exception as e: record('kill cleanup',str(e))
 result=sp.run([hc,'server','stop'],env=env,text=True,capture_output=True,timeout=20); record('isolated core stop',{'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr}); assert result.returncode==0
 log.close()
