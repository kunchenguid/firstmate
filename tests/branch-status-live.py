"""Drive only an isolated Pi CLI, retain real ANSI output and visible transitions."""
import fcntl, json, os, pathlib, pty, re, select, struct, subprocess, termios, time
lab = pathlib.Path(os.environ['FM_STATUS_LAB'])
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 120, 0, 0))
args = ['pi', '--offline', '--approve', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-context-files',
        '-e', str(lab/'driver.ts'), '-e', str(lab/'.pi/extensions/fm-branch-supervision.ts'),
        '-e', str(lab/'.pi/extensions/fm-branch-status.ts'), '--model', 'status-lab/lab', '--thinking', 'off', '--session-dir', str(lab/'sessions')]
# Capture the same real Pi with the activity extension absent as the before view.
baseline_args=args.copy()
index=baseline_args.index(str(lab/'.pi/extensions/fm-branch-status.ts'))
del baseline_args[index-1:index+1]
baseline=subprocess.Popen(baseline_args,cwd=lab,stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'},start_new_session=True)
before=bytearray()
end=time.monotonic()+20
sent=False
while time.monotonic()<end:
    if select.select([master],[],[],.1)[0]:
        data=os.read(master,65536);before.extend(data)
        if b'\x1b[6n' in data:os.write(master,b'\x1b[1;1R')
    if not sent and (lab/'state/probe.jsonl').exists():
        time.sleep(.3);os.write(master,b'/lab-stage before\r');sent=True
    if b'LAB_BASELINE_READY' in before:break
try:
    assert b'LAB_BASELINE_READY' in before and b'Branch idle' not in before, before[-3000:]
finally:
    os.write(master,b'/quit\r')
    try:baseline.wait(timeout=10)
    except subprocess.TimeoutExpired:baseline.terminate();baseline.wait(timeout=10)
(lab/'before.ansi').write_bytes(before)
# Drain baseline terminal bytes before starting the candidate.
while select.select([master],[],[],.1)[0]:os.read(master,65536)
p = subprocess.Popen(args, cwd=lab, stdin=slave, stdout=slave, stderr=slave, env={**os.environ,'TERM':'xterm-256color'}, start_new_session=True)
os.close(slave)
raw = bytearray()
ansi = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')
def receive(seconds=.2):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if select.select([master],[],[],.05)[0]:
            try: data=os.read(master,65536)
            except OSError: return
            raw.extend(data)
            if b'\x1b[6n' in data: os.write(master,b'\x1b[1;1R')
def wait(text, start=0, seconds=40):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        receive()
        visible=ansi.sub('',raw[start:].decode('utf-8',errors='replace'))
        if text in visible:
            (lab/('visible-'+str(len(list(lab.glob('visible-*'))))+'.txt')).write_text(visible)
            print('VISIBLE '+text,flush=True)
            return
        if p.poll() is not None: break
    raise AssertionError('missing rendered '+text+'\n'+raw[-9000:].decode('utf-8',errors='replace'))
def command(value):
    start=len(raw); os.write(master,(value+'\r').encode()); return start
try:
    wait('Branch idle')
    wait('Completed: unknown',command('/supervision-status'))
    wait('model/tools',command('/lab-stage process'))
    wait('durable branch result',command('/lab-stage finish'))
    wait('MAIN: check-main-only',command('/lab-stage main'))
    wait('ownership-lost',command('/lab-stage conflict'))
    wait('Branch disabled',command('/lab-stage disabled'))
    wait('Branch unknown',command('/lab-stage unknown'))
    wait('Branch error',command('/lab-stage error'))
    # A pulse from the completed run cannot make an aged health snapshot fresh.
    receive(.3)
    wait('Branch unknown',command('/lab-stage stale'))
    command('/lab-stage restore'); receive(.5)
    wait('Branch',command('/reload'))
    command('/supervision-status'); receive(.3)
    command('/quit'); p.wait(timeout=10)
    rows=[json.loads(l) for l in (lab/'state/probe.jsonl').read_text().splitlines()]
    conflict=[x for x in rows if x.get('token')=='conflict'][-1]
    assert conflict['calls']==2 and 'claimed by main' in conflict['error'],conflict
    print('REAL_TUI_OK providerCalls=2 conflictBeforePrompt=true reload=true')
finally:
    (lab/'render.ansi').write_bytes(raw)
    dest=os.environ.get('FM_STATUS_EVIDENCE')
    if dest:
        import shutil
        out=pathlib.Path(dest);out.mkdir(parents=True,exist_ok=True)
        for file in [lab/'before.ansi',lab/'render.ansi',lab/'state/probe.jsonl',*lab.glob('visible-*')]:
            if file.exists():shutil.copy(file,out/file.name)
    if p.poll() is None:
        p.terminate()
        try:p.wait(timeout=10)
        except subprocess.TimeoutExpired:p.kill();p.wait()
    os.close(master)
