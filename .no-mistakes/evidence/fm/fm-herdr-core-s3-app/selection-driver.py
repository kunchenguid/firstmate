import os, subprocess, socket, json, pathlib
root=pathlib.Path.cwd(); ev=pathlib.Path(os.environ['EVIDENCE'])
base=os.environ.copy(); base.update(HC_TERMINAL_ID='t1',HC_TERMINAL_SOCKET='.s/fm-hclab-a.sock')
log=[]
def resolve(name,updates,expected,signal='',notice=None):
    env=base.copy()
    for k,v in updates.items():
        if v is None: env.pop(k,None)
        else: env[k]=v
    p=subprocess.run(['bash','-c','. bin/fm-backend.sh; fm_backend_resolve; printf "backend=%s\\nsignal=%s\\n" "$FM_BACKEND_RESOLVED" "$FM_BACKEND_DETECT_SIGNAL"'],env=env,text=True,capture_output=True,timeout=40)
    record={'name':name,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
    log.append(record)
    assert p.returncode==0 and p.stdout==f'backend={expected}\nsignal={signal}\n',record
    assert (notice in p.stderr) if notice else not p.stderr,record
try:
    resolve('projected terminal on the live pinned core',{},'hc','app-terminal','auto-detected a Herdr-app-projected terminal')
    term=subprocess.run(['bin/fm-hc-lab.sh','run','fm-hclab-a','run','--bg','--no-parent'],text=True,capture_output=True,check=True)
    unlabeled=json.loads(term.stdout)['address']
    resolve('bare markers from an actual unlabeled core terminal',{'HC_TERMINAL_ID':unlabeled},'tmux')
    resolve('labeled terminal cannot steer an unrelated spawn socket',{'FM_HC_SOCKET':'.s/absent.sock'},'tmux')
    resolve('live terminal with missing core binary names the missing toolchain',{'FM_HC_BIN':str(root/'.live/missing-hc')},'tmux','app-terminal-unusable','no usable hc toolchain')
    stale=socket.socket(socket.AF_UNIX); stale.bind('.s/dead.sock'); stale.close()
    resolve('stale terminal socket never starts a core',{'HC_TERMINAL_SOCKET':'.s/dead.sock','FM_HC_SOCKET':'.s/dead.sock'},'tmux')
    resolve('nonexistent terminal on live core is not a signal',{'HC_TERMINAL_ID':'tzzzz'},'tmux')
    resolve('tmux marker wins inside a projected terminal',{'TMUX':'isolated-marker'},'tmux','TMUX')
    resolve('classic Herdr marker wins inside a projected terminal',{'HERDR_ENV':'1'},'herdr','HERDR_ENV')
    resolve('explicit environment wins over projected terminal',{'FM_BACKEND':'tmux'},'tmux')
    cfg=root/'.live/home/config/backend'; cfg.write_text('tmux\n')
    resolve('explicit configuration wins over projected terminal',{},'tmux')
    cfg.unlink()
    window=socket.socket(socket.AF_UNIX); window.bind('.s/herdr-app.sock'); window.listen(16)
    import threading
    stopped=threading.Event(); window.settimeout(.1)
    def accept():
        while not stopped.is_set():
            try: c,_=window.accept(); c.close()
            except socket.timeout: pass
    thread=threading.Thread(target=accept); thread.start()
    try:
        markerless={'HC_TERMINAL_ID':None,'HC_TERMINAL_SOCKET':None,'HERDR_APP_HOME':str(root/'.s')}
        resolve('marker-less shell near a listening app socket and running core stays silent',markerless,'tmux')
        absent=markerless|{'HC_SESSION':'fm-hclab-never','FM_HC_SOCKET':None,'XDG_STATE_HOME':str(root/'.live/absent-state'),'XDG_RUNTIME_DIR':None}
        resolve('marker-less shell near a listening app socket with no core starts nothing',absent,'tmux')
        assert not (root/'.live/absent-state').exists()
    finally:
        stopped.set(); thread.join(); window.close()
    print(json.dumps(log,indent=2))
finally:
    (ev/'live-selection-boundaries.json').write_text(json.dumps(log,indent=2)+'\n')
