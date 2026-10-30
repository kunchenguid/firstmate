# Execute only environment/helper declarations from the disposable spawn driver.
exec(open('.live-validation/spawn_live.py').read().split('try:\n')[0])
env['OPENCODE_DISABLE_AUTOUPDATE']='true'
try:
 p=run(['bin/fm-spawn.sh','generic-proof',str(l/'project'),'--scout','--backend','hc','--harness','opencode'],timeout=180)
 if p.returncode:raise RuntimeError('spawn failed')
 meta=(l/'spawn-home/state/generic-proof.meta').read_text();print(meta,flush=True)
 tid=dict(x.split('=',1) for x in meta.splitlines() if '=' in x)['hc_terminal']
 for _ in range(20):
  p=run([str(l/'hc'),'get',tid,'--json']);row=json.loads(p.stdout)
  if (row.get('status') or {}).get('app')=='firstmate-opencode':break
  time.sleep(1)
 assert (row.get('status') or {}).get('app')=='firstmate-opencode',row
 s=l/'spawn-home/state/generic-proof.status'
 with s.open('a') as f:f.write('needs-decision [at=1] [key=proof]: fixture decision\n')
 for _ in range(15):
  p=run([str(l/'hc'),'get',tid,'--json']);row=json.loads(p.stdout)
  if (row.get('status') or {}).get('kind')=='question':break
  time.sleep(1)
 assert row['status']['state']=='blocked' and row['status']['kind']=='question',row
 run(['bin/fm-peek.sh','generic-proof'])
 print('RESULT: real fm-spawn launch armed generic watcher and hc consumed its blocked question',flush=True)
finally:
 run([str(l/'hc'),'server','stop','--json'])
 (e/'generic-spawn-observations.json').write_text(json.dumps(log,indent=2)+'\n')
