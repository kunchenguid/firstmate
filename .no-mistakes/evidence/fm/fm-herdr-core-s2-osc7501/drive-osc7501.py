#!/usr/bin/env python3
"""Live local reporter checks: actual /dev/tty, 120x40 PTY, actual private tmux.
Synthetic durable task inputs; no agent CLI or terminal runtime is impersonated.
Oracle: author's status mapping, append freshness, final-outcome and eligibility contract.
"""
import base64, fcntl, json, os, pathlib, pty, re, select, shlex, shutil, signal, struct, subprocess, termios, time
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6DNKG1M8VHA6185EYWSPVHH')
D=ROOT/'.live-validation'
SCRIPT=ROOT/'bin/fm-osc7501.sh'
LOG=[]
RESULTS=[]
q=shlex.quote
BASE=dict(os.environ)
for k in list(BASE):
    if k.startswith(('HC_', 'HERDR_', 'REX_', 'FM_')) or k in ('TERM_PROGRAM','TMUX','TMUX_PANE'):
        BASE.pop(k,None)
BASE.update(FM_OSC7501_INTERVAL='1', FM_OSC7501_HEARTBEAT='2', TERM='xterm-256color')

def note(s):
    LOG.append(s); print(s,flush=True)

class Pane:
    def __init__(self,name,aware=True,extra=None):
        self.d=D/name; (self.d/'state').mkdir(parents=True); (self.d/'config').mkdir()
        self.m,self.s=pty.openpty()
        fcntl.ioctl(self.s,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
        modes=termios.tcgetattr(self.s); modes[3]&=~termios.ECHO; termios.tcsetattr(self.s,termios.TCSANOW,modes)
        self.modes=termios.tcgetattr(self.s)
        rd,self.wr=os.pipe(); self.ack,aw=os.pipe()
        env=dict(BASE)
        if aware: env['TERM_PROGRAM']='ghostty' # synthetic passive marker, not a Ghostty claim
        env.update(extra or {})
        code=f'while IFS= read -r cmd <&{rd}; do eval "$cmd"; printf "ACK\\n" >&{aw}; done'
        def setup():
            os.setsid(); fcntl.ioctl(self.s,termios.TIOCSCTTY,0)
        self.p=subprocess.Popen(['/bin/bash','--noprofile','--norc','-c',code],env=env,
            stdin=self.s,stdout=self.s,stderr=self.s,pass_fds=(rd,aw),preexec_fn=setup)
        os.close(rd); os.close(aw)
        self.raw=b''; self.closed=False
    def drain(self,seconds=.08):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            if select.select([self.m],[],[],max(0,end-time.monotonic()))[0]:
                try: data=os.read(self.m,65536)
                except OSError: break
                if not data: break
                self.raw+=data
    def cmd(self,c):
        note(f'[{self.d.name}] $ {c}')
        os.write(self.wr,(c+'\n').encode()); end=time.monotonic()+12
        while time.monotonic()<end:
            self.drain(.05)
            if select.select([self.ack],[],[],0)[0]:
                assert os.read(self.ack,4096)==b'ACK\n', 'shell exited without acknowledgement'
                self.drain(); return
        raise AssertionError('command did not acknowledge')
    def records(self):
        self.drain()
        ret=[]
        for match in re.finditer(rb'\x1b\]7501;([^\x1b]*)\x1b\\',self.raw):
            r={}
            for f in match[1].decode().split(':'):
                k,_,v=f.partition('=')
                r[k]=base64.b64decode(v).decode() if k in ('msg','title') else v
            ret.append(r)
        return ret
    def wait(self,state,kind=None,after=0):
        end=time.monotonic()+9
        while time.monotonic()<end:
            r=self.records()
            if len(r)>after and r[-1].get('state')==state and (kind is None or r[-1].get('kind')==kind):
                note(f'[{self.d.name}] observed {json.dumps(r[-1])}'); return r[-1]
            time.sleep(.08)
        raise AssertionError(f'{self.d.name}: expected {state}/{kind}, got {self.records()}')
    def status(self,s,append=False):
        with open(self.d/'state/t.status','a' if append else 'w') as f: f.write(s)
        note(f'[{self.d.name}] status {"append" if append else "replace"}: {s.strip()}')
    def busy(self,state):
        sd=self.d/'state'
        if state is None:
            for f in ('t.busy-state','t.busy-gen'): (sd/f).unlink(missing_ok=True)
        else:
            (sd/'t.busy-gen').write_text('g1\n')
            (sd/'t.busy-state').write_text(f'v1 gen=g1 seq=1 state={state} source=fm-spawn event=launch ts={int(time.time())}\n')
        note(f'[{self.d.name}] synthetic durable busy input: {state or "absent (unknown)"}')
    def arm(self,h='opencode',agent='opencode',backend='tmux',target=''):
        self.cmd(f'bash {q(str(SCRIPT))} arm --task t --harness {q(h)} --agent-bin {q(agent)} --backend {q(backend)} --kind ship --state {q(str(self.d/"state"))} --config {q(str(self.d/"config"))} --target {q(target)}')
    def watchers(self): return list((self.d/'state').glob('.osc7501watch-*'))
    def disarm(self): self.cmd(f'bash {q(str(SCRIPT))} disarm --state {q(str(self.d/"state"))}')
    def no_bytes(self):
        self.drain(.4); assert self.raw==b'', f'unexpected bytes {self.raw!r}'
        assert not self.watchers(), 'unexpected watcher'
        assert termios.tcgetattr(self.s)==self.modes, 'reporter changed terminal modes'
        note(f'[{self.d.name}] zero output bytes; no watcher; terminal modes unchanged')
    def stop(self,parent_exit=False):
        if self.closed:return
        if not parent_exit: self.disarm()
        os.close(self.wr); self.p.wait(timeout=8)
        if parent_exit:
            end=time.monotonic()+3
            while time.monotonic()<end: self.drain(.1)
        self.drain()
        (E/(self.d.name+'.pty')).write_bytes(self.raw)
        (E/(self.d.name+'.records.json')).write_text(json.dumps(self.records(),indent=2))
        os.close(self.ack);os.close(self.s);os.close(self.m);self.closed=True

PANES=[]
def pane(*a,**kw):
    p=Pane(*a,**kw);PANES.append(p);return p

def check(name,fn):
    note('\nSCENARIO: '+name)
    try: fn();RESULTS.append({'name':name,'result':'pass'});note('RESULT: pass')
    except Exception as e:
        RESULTS.append({'name':name,'result':'fail','error':repr(e)});note('RESULT: fail '+repr(e));raise

def eligibility():
    p=pane('unknown-terminal',aware=False); p.arm();p.no_bytes()
    os.write(p.m,b'queued worker input\n')
    p.cmd(f'IFS= read -r typed; printf "%s" "$typed" > {q(str(p.d/"input"))}')
    assert (p.d/'input').read_text()=='queued worker input';p.no_bytes();p.stop()
    for name,h,a,b,config in [
        ('config-off','opencode','opencode','tmux','off\n'),
        ('native-claude','claude',shutil.which('claude'),'tmux',None),
        ('native-codex-safe-probe','codex',shutil.which('codex'),'tmux',None),
        ('legacy-herdr','opencode','opencode','herdr',None),
        ('no-task-tty','opencode','opencode','t3code',None),
        ('unresolved-agent','env','','tmux',None)]:
        p=pane(name)
        if config:(p.d/'config/osc7501-status').write_text(config)
        p.arm(h,a,b);p.no_bytes();p.stop()

def mapping():
    p=pane('known-status');p.busy('busy');p.arm();p.wait('working')
    assert p.watchers()
    p.status('needs-decision [at=1] [key=k]: choose a region\n');p.wait('blocked','question')
    p.status('resolved [at=2] [key=k]: chosen\n',True);p.wait('working')
    p.status('blocked [at=3] [key=a]: API token expired\n');p.wait('blocked','auth')
    p.status('resolved [at=4] [key=a]: refreshed\n',True);p.wait('working')
    p.busy('idle');p.status('captain-held [at=5]: captain to decide\n');p.wait('blocked','question')
    p.status('done [at=6]: PR https://example.invalid/pr/7\n');p.wait('done')
    n=len(p.records());p.wait('done',after=n) # bounded wait includes classifier/process overhead
    p.disarm();p.wait('done',after=n);assert not p.watchers();p.stop()

def unknown():
    for verb,want in [('done','done'),('failed','error')]:
        p=pane('stale-'+verb);stamp=int(time.time())
        p.status(f'{verb} [at={stamp}]: earlier result with identical timestamp\n')
        p.busy('busy');p.arm();p.wait('working');p.busy(None);p.wait('idle')
        assert not any(r['state']==want for r in p.records()), 'earlier result appeared mid-turn'
        n=len(p.records());time.sleep(3);assert len(p.records())==n,'unknown state heartbeated'
        p.disarm();p.wait(want,after=n);assert not p.watchers();p.stop()
    p=pane('unknown-decisions');p.busy('idle');p.arm();p.wait('idle')
    p.status('needs-decision [at=1] [key=x]: choose one\n');p.wait('blocked','question')
    p.busy(None);time.sleep(2);n=len(p.records());time.sleep(3);assert len(p.records())==n
    p.status('resolved [at=2] [key=x]: yes\n',True);p.wait('idle')
    n=len(p.records());p.disarm();p.wait('idle',after=n);p.stop()
    # Real private tmux serves synthetic rendered inputs to the actual activity reader.
    socket='.live-validation/s'
    def tm(*args):
        r=subprocess.run(['tmux','-f','/dev/null','-S',socket,*args],env=BASE,capture_output=True,text=True,timeout=8)
        assert r.returncode==0,r.stderr
        return r.stdout
    tm('new-session','-d','-s','lab','-x','120','-y','40','/bin/bash --noprofile --norc')
    try:
        tm('send-keys','-t','lab:',"printf '\\033[2J\\033[H Rovo is thinking...\\n'",'Enter');time.sleep(.3)
        p=pane('rovo-real-tmux',extra={'TMUX':socket+',0,0'})
        p.arm(h='rovo',agent='rovo',target='lab:');p.wait('working')
        stamp=int(time.time())
        # Clear the complete screen and history so the former busy signature is absent.
        tm('send-keys','-t','lab:',"printf '\\033[2J\\033[H idle synthetic viewport\\n'",'Enter');time.sleep(.2)
        tm('clear-history','-t','lab:');p.wait('idle')
        p.status(f'done [at={stamp}]: fresh line appended after busy reading\n');p.wait('done')
        p.status('failed [at=1]: fresh failure appended after busy reading\n',True);p.wait('error')
        n=len(p.records());p.disarm();p.wait('error',after=n);p.stop()
        (E/'rovo-private-tmux.txt').write_text(tm('capture-pane','-p','-t','lab:'))
    finally: tm('kill-server')

def relaunch():
    for native in (False,True):
        name='leftover-native' if native else 'leftover-off'
        p=pane(name);p.busy('busy');p.arm();p.wait('working')
        pid=int(p.watchers()[0].read_text().split()[0]);os.kill(pid,signal.SIGKILL)
        time.sleep(.3);n=len(p.records())
        if native:p.arm('claude',shutil.which('claude'))
        else:
            (p.d/'config/osc7501-status').write_text('off\n');p.arm()
        p.wait('idle',after=n);assert len(p.records())==n+1,'relaunch wrote more than one clear'
        assert not p.watchers();time.sleep(2.5);assert len(p.records())==n+1,'unarmed relaunch kept writing'
        p.stop()

try:
    D.mkdir(exist_ok=True)
    check('Local PTY: eligibility, native exclusion and queued-input safety',eligibility)
    check('Local PTY: known activity maps decisions, captain holds and final done',mapping)
    check('Local PTY + private tmux: stale/fresh outcomes, unknown retirement and finalization',unknown)
    check('Local PTY: off/native relaunch clears a killed watcher exactly once',relaunch)
finally:
    for p in PANES:
        if not p.closed:
            try:p.stop()
            except Exception as e:
                note('cleanup failure '+repr(e))
                if p.p.poll() is None:
                    os.killpg(p.p.pid,signal.SIGTERM);p.p.wait(timeout=5)
    shutil.rmtree(D)
    (E/'live-reporter-transcript.txt').write_text('\n'.join(LOG)+'\n')
    (E/'live-reporter-results.json').write_text(json.dumps(RESULTS,indent=2))
