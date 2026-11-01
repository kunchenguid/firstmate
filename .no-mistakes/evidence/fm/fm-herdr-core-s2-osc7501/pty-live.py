import os,pty,fcntl,termios,struct,time,select,json,pathlib as P,signal,shlex
root=P.Path.cwd(); d=root/'.live-test'; ev=P.Path('~/.no-mistakes/evidence/01M6AE01KG33NM41T4D4Y9MGMZ'); env=os.environ.copy()
for k in list(env):
 if k.startswith(('HC_','HERDR_','REX_','FM_')) or k in ('TMUX','TERM_PROGRAM'): env.pop(k,None)
env['FM_OSC7501_QUERY_DS']='2'; out=[]
for mode in ('silent','answer','interrupt'):
 home=d/('pty-'+mode); (home/'state').mkdir(parents=True,exist_ok=True); (home/'config').mkdir(exist_ok=True); m,s=pty.openpty(); fcntl.ioctl(s,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0)); before=termios.tcgetattr(s)
 args=[str(root/'bin/fm-osc7501.sh'),'arm','--task','pty','--harness','opencode','--backend','tmux','--kind','ship','--state',str(home/'state'),'--config',str(home/'config')]
 if mode=='interrupt': line=shlex.join(args)+' & arm=$!; echo ARM_PID=$arm; wait $arm; echo PROBE_ENDED; sleep 2'
 else: line=shlex.join(args)+f"; if read -t 1 -n 1 leftover; then echo INPUT_LEAK; else echo NO_INPUT_LEAK; fi; '{root}/bin/fm-osc7501.sh' disarm --state '{home}/state'; echo PROBE_ENDED; sleep 2"
 command=['/bin/bash','--noprofile','--norc','-c',line]
 pid=os.fork()
 if pid==0:
  os.close(m); os.setsid(); fcntl.ioctl(s,termios.TIOCSCTTY,0)
  for fd in (0,1,2): os.dup2(s,fd)
  os.execve(command[0],command,env)
 data=b''; reacted=False; rc=None; after=None; deadline=time.monotonic()+15
 try:
  while time.monotonic()<deadline:
   r,_,_=select.select([m],[],[],.05)
   if r:
    chunk=os.read(m,65536)
    if chunk: data+=chunk
   if b'\x1b]7501;?\x1b\\' in data and not reacted:
    reacted=True
    if mode=='answer': os.write(m,b'\x1b]7501;state='); time.sleep(.05); os.write(m,b'idle\x1b\\')
    if mode=='interrupt':
     import re
     arm=int(re.search(rb'ARM_PID=(\d+)',data).group(1)); os.kill(arm,signal.SIGTERM)
   if b'PROBE_ENDED' in data and after is None: after=termios.tcgetattr(s)
   waited,status=os.waitpid(pid,os.WNOHANG)
   if waited: rc=os.waitstatus_to_exitcode(status); break
  if rc is None: raise RuntimeError('pty child timed out: '+mode)
  result={'mode':mode,'exit':rc,'terminal_output':data.decode(errors='replace'),'input_flags_restored':(before[3] & (termios.ICANON|termios.ECHO))==(after[3] & (termios.ICANON|termios.ECHO)),'watchers_left':[str(p) for p in (home/'state').glob('.osc7501watch-*')]}; out.append(result); print(result,flush=True)
  assert reacted and result['input_flags_restored'] and not result['watchers_left'],result
  if mode!='interrupt': assert rc==0 and b'NO_INPUT_LEAK' in data,result
  if mode=='silent': assert data.count(b'\x1b]7501;')==1,result
 finally:
  if rc is None:
   os.kill(pid,signal.SIGKILL); os.waitpid(pid,0)
  os.close(m); os.close(s)
(ev/'pty-live.json').write_text(json.dumps(out,indent=2))
