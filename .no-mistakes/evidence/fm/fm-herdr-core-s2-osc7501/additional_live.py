exec(open('.live-validation/spawn_live.py').read().split('try:\n')[0])
import shlex
q=shlex.quote
try:
 d=l/'capture-fallback';(d/'state').mkdir(parents=True);(d/'config').mkdir()
 (d/'state/task.status').write_text('done [at=1]: previous result\n')
 command=f'''printf 'working on it\\n  Ctrl+c:cancel\\n'; bash {q(str(r/'bin/fm-osc7501.sh'))} arm --task task --harness grok --backend hc --target "$HC_SESSION:$HC_TERMINAL_ID" --kind ship --state {q(str(d/'state'))} --config {q(str(d/'config'))}; while [ ! -f {q(str(d/'clear'))} ]; do sleep .2; done; printf '\\033[2J\\033[Hready\\n> \\n'; sleep 30'''
 p=run([str(l/'hc'),'run','--bg','--json','--no-parent','--cwd',str(r),'--','bash','-c',command]);t=json.loads(p.stdout)['address']
 def await_state(state):
  for _ in range(20):
   p=run([str(l/'hc'),'get',t,'--json']);s=json.loads(p.stdout).get('status') or {}
   if s.get('state')==state:return
   time.sleep(.5)
  raise AssertionError((state,s))
 await_state('working');run([str(l/'hc'),'read',t,'--lines','40']);(d/'clear').touch();await_state('done')
 print('RESULT: real hc capture fed the Grok classifier: working overrides earlier done, then done returns',flush=True)
finally:
 run([str(l/'hc'),'server','stop','--json']);(e/'capture-fallback-observations.json').write_text(json.dumps(log,indent=2)+'\n')
# A real unaware terminal (tmux) discards the capability probe. All server calls
# address this worktree's private socket, never the operator's tmux server.
log=[];socket=str(r/'t.sock');base=['tmux','-S',socket]
d=l/'unaware-live';(d/'state').mkdir(parents=True,exist_ok=True);(d/'config').mkdir(exist_ok=True)
for name in ['complete','terminal.raw','pid']:
 (d/name).unlink(missing_ok=True)
clean=['env']
for key in ['HC_TERMINAL_ID','HC_TERMINAL_SOCKET','HC_SCOPE','HC_SESSION','HC_SOCKET','HERDR_ENV','HERDR_PANE_ID','REX_BLOCK','REX_SESSION','TERM_PROGRAM']:clean+=['-u',key]
arm=f'bash {q(str(r/"bin/fm-osc7501.sh"))} arm --task task --harness opencode --backend tmux --kind ship --state {q(str(d/"state"))} --config {q(str(d/"config"))}'
command=f'''sleep 1; stty -g >{q(str(d/'before'))}; {arm}; stty -g >{q(str(d/'after'))}; printf 'READY-AFTER-PROBE\\n'; FM_OSC7501_QUERY_DS=20 {arm} & p=$!; echo "$p" >{q(str(d/'pid'))}; wait "$p"; stty -g >{q(str(d/'after-interrupt'))}; touch {q(str(d/'complete'))}; sleep 30'''
try:
 run(base+['new-session','-d','-x','120','-y','40','-s','fm-lab-unaware','-c',str(r),shlex.join(clean+['bash','-c',command])])
 run(base+['pipe-pane','-t','fm-lab-unaware','-O','cat > '+q(str(d/'terminal.raw'))])
 for _ in range(80):
  if (d/'terminal.raw').exists() and (d/'terminal.raw').read_bytes().count(bytes.fromhex('1b5d373530313b3f1b5c'))>=2:
   import signal
   os.kill(int((d/'pid').read_text()),signal.SIGTERM)
   break
  time.sleep(.1)
 for _ in range(60):
  if (d/'complete').exists():break
  time.sleep(.2)
 assert (d/'complete').exists()
 time.sleep(.5)
 # Ignore Darwin's transient PENDIN bit, retaining every persistent tty flag.
 def persistent_mode(path):
  import re
  return re.sub(r'lflag=([0-9a-f]+)',lambda m:'lflag='+format(int(m[1],16)&~0x20000000,'x'),path.read_text())
 assert persistent_mode(d/'before')==persistent_mode(d/'after')==persistent_mode(d/'after-interrupt')
 assert not list((d/'state').glob('.osc7501watch-*'))
 raw=(d/'terminal.raw').read_bytes();assert raw.count(b'\x1b]7501;?\x1b\\')==2,raw
 assert b'state=' not in raw
 run(base+['capture-pane','-p','-t','fm-lab-unaware'])
 (e/'unaware-terminal-observations.json').write_text(json.dumps({'terminal':'real tmux, private worktree socket, 120x40','query_count':2,'scenarios':['unanswered capability query','interrupted capability query'],'raw_output':repr(raw),'tty_mode_before':(d/'before').read_text().strip(),'tty_mode_after':(d/'after').read_text().strip(),'tty_mode_after_interrupt':(d/'after-interrupt').read_text().strip(),'watchers':0},indent=2)+'\n')
 print('RESULT: silent terminal saw only two probes; normal timeout and TERM restored exact tty mode, no watcher',flush=True)
finally:run(base+['kill-server'])
