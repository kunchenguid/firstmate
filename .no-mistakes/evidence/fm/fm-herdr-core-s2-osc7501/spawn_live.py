import os,pathlib,subprocess,json,time
r=pathlib.Path.cwd(); l=r/'.live-validation'; e=pathlib.Path('/Users/kunchen/.no-mistakes/evidence/01M6766N8H82Z1ZJ3TPP8196PX'); env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HC_','HERDR_')):env.pop(k,None)
env.update(PATH=str(l)+':'+env['PATH'], FM_HOME=str(l/'spawn-home'), HC_SESSION='fm-lab-s2', XDG_RUNTIME_DIR=str(r), XDG_STATE_HOME=str(l/'spawn-state'), XDG_CONFIG_HOME=str(l/'spawn-config'), XDG_DATA_HOME=str(l/'spawn-data'), XDG_CACHE_HOME=str(l/'spawn-cache'), TREEHOUSE_ROOT=str(l/'pool'), DISABLE_AUTOUPDATER='1')
for k in ['XDG_STATE_HOME','XDG_CONFIG_HOME','XDG_DATA_HOME','XDG_CACHE_HOME']:pathlib.Path(env[k]).mkdir(exist_ok=True)
log=[]
def run(args,timeout=180):
 p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=timeout);log.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr});print(json.dumps(log[-1]),flush=True);return p
try:
 p=run(['bin/fm-spawn.sh','launch-proof',str(l/'project'),'--scout','--backend','hc','--harness','claude'],timeout=180)
 if p.returncode:raise RuntimeError('spawn failed')
 meta=l/'spawn-home/state/launch-proof.meta';print(meta.read_text(),flush=True)
 records=run([str(l/'hc'),'ls','--json']);rows=json.loads(records.stdout)
 print('records',rows,flush=True)
 for i in range(45):
  s=l/'spawn-home/state/launch-proof.status'
  if s.exists() and 'done [' in s.read_text():break
  time.sleep(2)
 run([str(l/'hc'),'ls','--all','--json'])
 run(['bin/fm-peek.sh','launch-proof'])
 report=l/'spawn-home/data/launch-proof/report.md'
 if report.exists():log.append({'report':report.read_text()});print(report.read_text(),flush=True)
 if s.exists():log.append({'status':s.read_text()});print(s.read_text(),flush=True)
 print('watcher pidfiles',list((l/'spawn-home/state').glob('.osc7501watch-*')),flush=True)
finally:
 run([str(l/'hc'),'server','stop','--json'])
 (e/'spawn-live-observations.json').write_text(json.dumps(log,indent=2)+'\n')
