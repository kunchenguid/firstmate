exec(open('.live-validation/spawn_live.py').read().split('try:\n')[0])
import shlex
q=shlex.quote;d=l/'rearm-live';(d/'state').mkdir(parents=True);(d/'config').mkdir()
(d/'state/task.busy-gen').write_text('g1\n');(d/'state/task.busy-state').write_text(f'v1 gen=g1 seq=1 state=busy source=fm-spawn event=test ts={int(time.time())}\n')
arm=f'bash {q(str(r/"bin/fm-osc7501.sh"))} arm --task task --backend hc --kind ship --state {q(str(d/"state"))} --config {q(str(d/"config"))}'
try:
 p=run([str(l/'hc'),'run','--bg','--json','--no-parent','--cwd',str(r),'--','bash','-c',f'{arm} --harness opencode; sleep 6; {arm} --harness claude --agent-bin claude; touch {q(str(d/"rearmed"))}; sleep 60'])
 t=json.loads(p.stdout)['address'];first=None
 for _ in range(20):
  p=run([str(l/'hc'),'get',t,'--json']);s=json.loads(p.stdout).get('status') or {}
  if s.get('state')=='working':
   first=int(next((d/'state').glob('.osc7501watch-*')).read_text().split()[0]);break
  time.sleep(.3)
 assert first
 for _ in range(60):
  if (d/'rearmed').exists():break
  time.sleep(.2)
 assert (d/'rearmed').exists()
 assert not list((d/'state').glob('.osc7501watch-*'))
 try:os.kill(first,0);raise AssertionError('old watcher survived')
 except ProcessLookupError:pass
 p=run([str(l/'hc'),'get',t,'--json']);s=json.loads(p.stdout)['status'];assert s['state']=='idle'
 print('RESULT: same-terminal native relaunch retired old writer, emitted final idle, and left zero generic watchers',flush=True)
finally:
 run([str(l/'hc'),'server','stop','--json']);(e/'rearm-live-observations.json').write_text(json.dumps(log,indent=2)+'\n')
