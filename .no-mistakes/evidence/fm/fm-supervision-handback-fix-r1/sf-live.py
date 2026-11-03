import os, pathlib, subprocess, json, time, threading, http.server, shutil, signal
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M6HDVCQG2SFKA0B68CD54WW4'); L=R/'.sf-lab'; H=L/'home'; L.mkdir(exist_ok=True)
os.environ['FM_HERDR_LAB_STATE_DIR']=str(L/'tripwires')
S=subprocess.check_output(['bin/fm-herdr-lab.sh','name','stopfailure'],text=True).strip()
(E/'session.txt').write_text(S+'\n')
def log(s):
 print(s,flush=True)
 with (E/'herdr-live.log').open('a') as f:f.write(s+'\n')
def run(*a,check=True):
 p=subprocess.run(a,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 if check and p.returncode:raise RuntimeError(str(a)+': '+p.stdout)
 return p.stdout
def hd(*a):return run('bin/fm-herdr-lab.sh','run',S,*a)
def snap(tag):
 x=hd('pane','read',P,'--source','visible','--format','ansi'); (E/(tag+'.ansi.txt')).write_text(x);log(tag+': '+x)
def state(tag):
 d={}
 for p in (H/'state').glob('.*'):
  if p.is_file() and p.stat().st_size<100000:
   try:d[p.name]=p.read_text()
   except:pass
 (E/(tag+'-state.json')).write_text(json.dumps(d,indent=2)); log(tag+' ledger='+d.get('.claude-autoarm-epoch','absent')+' marker='+d.get('.watcher-down','absent'))
class Err(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length',0))); b=b'{"type":"error","error":{"type":"authentication_error","message":"isolated StopFailure live-test forced 401"}}'
  log('localhost forced401 '+self.path); self.send_response(401);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
 def do_GET(self):self.do_POST()
 def log_message(self,*a):pass
srv=http.server.ThreadingHTTPServer(('127.0.0.1',0),Err); t=threading.Thread(target=srv.serve_forever);t.start()
try:
 run('bin/fm-lab-home.sh','create',str(H))
 # Materialize tracked runtime in the disposable home, not operator state.
 p=subprocess.Popen(['git','archive','HEAD'],stdout=subprocess.PIPE); q=subprocess.run(['tar','-xf','-','-C',str(H)],stdin=p.stdout);p.stdout.close();assert p.wait()==0 and q.returncode==0
 run('git','-C',str(H),'init','-q')
 (H/'config/supervision-host').touch(); (H/'config/supervision-handoff-ack').touch()
 (H/'state/demo.meta').write_text('project=demo\nwindow=unreachable-lab\nharness=claude\n');(H/'state/demo.status').write_text('')
 run('bin/fm-herdr-lab.sh','provision',S);log('provisioned '+S)
 envs={'FM_HOME':str(H),'ANTHROPIC_BASE_URL':f'http://127.0.0.1:{srv.server_port}','CLAUDE_CODE_MAX_RETRIES':'0','FM_POLL':'1','FM_SIGNAL_GRACE':'0','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_CLAUDE_STOPFAILURE_REWAKE_COOLDOWN':'20','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION':'false'}
 args=['workspace','create','--cwd',str(H),'--no-focus','--label','stopfailure-primary']
 for k,v in envs.items():args+=['--env',k+'='+v]
 x=json.loads(hd(*args));log(json.dumps(x));P=x['result']['root_pane']['pane_id'];(L/'pane').write_text(P)
 # Explicitly remove inherited fleet overrides and unrelated agent identity.
 cmd='env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u PI_CODING_AGENT claude'
 hd('pane','run',P,cmd);time.sleep(8);snap('startup')
 # Pause for interactive startup handling by driver below.
 (L/'ready').touch()
 while not (L/'finish').exists():time.sleep(.5)
 state('final');snap('final')
finally:
 # Stop only pids recorded in disposable ownership records, then guarded session.
 if H.exists():
  for f in ['.supervision-host','.watch.lock/pid']:
   p=H/'state'/f
   if p.exists():
    try:
     s=p.read_text();pid=int(s.splitlines()[0]) if f.endswith('/pid') else int(next(l.split('\t')[1] for l in s.splitlines() if l.startswith('host\t')))
     os.kill(pid,signal.SIGTERM);log('stopped lab owned pid '+str(pid))
    except Exception as e:log('cleanup record '+str(e))
 try:log('teardown '+run('bin/fm-herdr-lab.sh','teardown',S))
 except Exception as e:log('TEARDOWN ERROR '+str(e))
 srv.shutdown();srv.server_close();t.join()
 log('server joined; lab cleanup complete')
