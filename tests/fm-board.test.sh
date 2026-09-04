#!/usr/bin/env bash
# Executable-interface regression for the dashboard daemon, SQLite queue,
# incremental ingest, and the real process-event capture runner. Routing fixtures
# pin argv boundaries without starting a harness or contacting a live home.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)
export FM_BOARD_TEST_ROOT="$TMP_ROOT" FM_BOARD_TEST_CODE="$ROOT"
PYTHON="${FM_BOARD_PYTHON:-python3}"
"$PYTHON" - <<'PY'
import contextlib,csv,io,json,os,pathlib,shutil,signal,socket,sqlite3,subprocess,sys,time,urllib.request,urllib.error
root=pathlib.Path(os.environ['FM_BOARD_TEST_ROOT'])
code=pathlib.Path(os.environ['FM_BOARD_TEST_CODE'])
fixture=root/'code'; (fixture/'bin').mkdir(parents=True)
for path in (code/'bin').iterdir():
    if path.name not in ('board','fm-board.py','fm-board.sh','fm-procevent-board-answers.sh'):
        (fixture/'bin'/path.name).symlink_to(path,target_is_directory=path.is_dir())
for name in ('fm-board.py','fm-board.sh','fm-procevent-board-answers.sh'):
    shutil.copy2(code/'bin'/name,fixture/'bin'/name)
shutil.copytree(code/'bin/board',fixture/'bin/board',ignore=shutil.ignore_patterns('__pycache__'))
(fakebin:=root/'fakebin').mkdir()
home=root/'main'; second=root/'second'
# Deliberately poison the launching session with a different, contained home.
# The boundary guards below refuse BEFORE executing any real process-event
# operation if production leaks these variables, even during failed-test cleanup.
sentinel=root/'non-fixture-home'
for directory in ('state','data','projects'):
    (sentinel/directory).mkdir(parents=True)
    (sentinel/directory/'must-remain').write_text('untouched')
def sentinel_state():
    return {str(p.relative_to(sentinel)):p.read_bytes() for p in sentinel.rglob('*') if p.is_file()}
sentinel_before=sentinel_state()
pe=fixture/'bin/fm-procevent.sh'
pe.unlink()
shutil.copy2(code/'bin/fm-procevent.sh',fixture/'bin/fm-procevent-real.sh')
pe.write_text("""#!PYTHON
import json,os,pathlib,sys
root=pathlib.Path(os.environ['FM_BOARD_TEST_ROOT']).resolve()
home=pathlib.Path(os.environ.get('FM_HOME','/')).resolve()
keys=('FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE')
record={'command':sys.argv[1:],'home':str(home),'overrides':{k:os.environ.get(k) for k in keys}}
clean=all(k not in os.environ for k in keys)
# The real sweep owner explicitly binds its recursive retire to this same state.
recursive_retire=(sys.argv[1:2]==['retire'] and os.environ.get('FM_STATE_OVERRIDE')==str(home/'state') and all(k not in os.environ for k in keys[1:]))
record['allowed']=home in (root/'main',root/'second') and (clean or recursive_retire)
with (root/'isolation.jsonl').open('a') as f:f.write(json.dumps(record)+'\\n')
if not record['allowed']:sys.exit('fixture containment refused')
os.execv('/bin/bash',['bash',str(pathlib.Path(__file__).with_name('fm-procevent-real.sh')),*sys.argv[1:]])
""".replace('PYTHON',sys.executable))
pe.chmod(0o755)
for h in (home,second):
    for d in ('state','data','config'):(h/d).mkdir(parents=True)
    (h/'data/backlog.md').write_text('fixture backlog')
    (h/'rows.json').write_text('[]')
script='''#!PYTHON
import csv,json,os,pathlib,sys,time
h=pathlib.Path(os.environ['FM_HOME']); name=pathlib.Path(sys.argv[0]).name
assert h.resolve() in (pathlib.Path(os.environ['FM_BOARD_TEST_ROOT'])/'main',pathlib.Path(os.environ['FM_BOARD_TEST_ROOT'])/'second')
assert all(k not in os.environ for k in ('FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE'))
with (h/'calls.jsonl').open('a') as f:f.write(json.dumps([name,sys.argv[1:]])+'\\n')
if (h/'delay').exists():time.sleep(float((h/'delay').read_text()))
if (h/'fail').exists():sys.exit(1)
if name=='tasks-axi':
 state=sys.argv[sys.argv.index('--state')+1];rows=json.loads((h/'rows.json').read_text());print('tasks[0]{id,state,kind,repo,title,hold_kind,hold_reason,blocked,blocked_by}:')
 for r in rows:
  if state==r[1] or state=='held' and r[5]!='-':
   import io
   line=io.StringIO();csv.writer(line,lineterminator='').writerow(r);print('  '+line.getvalue())
elif name=='fm-crew-state.sh':print('state: parked · source: pane · fixture')
elif name=='fm-fleet-snapshot.sh':print(json.dumps({'tasks':[]}))
elif name in ('fm-send.sh','fm-decision-hold.sh'):
 if name=='fm-decision-hold.sh':
  with (h/'hold-input').open('a') as f:f.write(sys.stdin.read())
 with (h/'deliveries.jsonl').open('a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
'''.replace('PYTHON',sys.executable)
for name in ('tasks-axi','fm-crew-state.sh','fm-fleet-snapshot.sh','fm-send.sh','fm-decision-hold.sh'):
    dest=(fakebin if name=='tasks-axi' else fixture/'bin')/name
    if dest.is_symlink():dest.unlink()
    dest.write_text(script);dest.chmod(0o755)
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
secret='fixture-secret-24-characters-minimum'
config=home/'config/board.json';config.write_text(json.dumps({'homes':[{'id':'Main','path':str(home)},{'id':'Second','path':str(second)}],'lan_host':'localhost','port':port,'secret':secret,'repo_tags':{'wonderok':'WOK','ces':'CES'}}))
env=dict(os.environ,FM_HOME=str(home),FM_BOARD_CONFIG=str(config),FM_BOARD_PYTHON=sys.executable,
         FM_PROCEVENT_CLAIM_ROOT=str(root/'claims'),PATH=str(fakebin)+os.pathsep+os.environ['PATH'])
for key in ('FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE'):
    env[key]=str(sentinel/{'FM_STATE_OVERRIDE':'state','FM_DATA_OVERRIDE':'data','FM_PROJECTS_OVERRIDE':'projects'}[key])
cli=fixture/'bin/fm-board.sh';daemon=None;out=(root/'daemon.log').open('wb')
def command(*args,ok=True,timeout=30):
    p=subprocess.run([str(cli),*map(str,args)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if ok and p.returncode:raise AssertionError(p.stderr.decode()+p.stdout.decode())
    if not ok:assert p.returncode!=0,(args,p.stdout)
    return p

def sql(query,args=()):
    with sqlite3.connect(home/'state/board.sqlite',timeout=5) as c:
        c.row_factory=sqlite3.Row
        return [dict(r) for r in c.execute(query,args)]

def mutate(query,args=()):
    with sqlite3.connect(home/'state/board.sqlite',timeout=5) as c:c.execute(query,args)

def rev():return int(sql("select value from meta where key='rev'")[0]['value'])
def request(path='/api/state',body=None,auth=True,extra=None):
    headers={'Authorization':'Bearer '+secret} if auth else {}
    headers.update(extra or {})
    req=urllib.request.Request(f'http://localhost:{port}'+path,data=json.dumps(body).encode() if body is not None else None,headers=headers)
    try:r=urllib.request.urlopen(req,timeout=10)
    except urllib.error.HTTPError as e:r=e
    with r:
        data=r.read();return r.status,json.loads(data) if data and data[:1] in (b'{',b'[') else data,r.headers

def wait(test,seconds=15):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        try:
            v=test()
            if v:return v
        except (OSError,urllib.error.URLError,sqlite3.OperationalError):pass
        time.sleep(.1)
    raise AssertionError('condition did not become true')

def start():
    global daemon
    daemon=subprocess.Popen([str(cli),'serve'],env=env,stdout=out,stderr=out)
    wait(lambda:request('/healthz')[1].get('ok') and request('/healthz')[1]['last_snapshot_ms'].get('Main') is not None,20)

def stop(kill=False):
    global daemon
    if daemon and daemon.poll() is None:
        daemon.kill() if kill else daemon.terminate()
        daemon.wait(timeout=30)
    daemon=None

def meta(h,tid,status='working: fixture'):
    (h/f'state/{tid}.meta').write_text('kind=task\nproject=wonderok\n')
    (h/f'state/{tid}.status').write_text(status+'\n')
def decision(tid,key='choose',project='WOK'):
    return json.loads(command('decision','Main',tid,key,'--project',project,'--title','Choose for '+tid,'--option','A: Ship it','--option','B: Wait','--rec','A','--why','Small reversible change').stdout)
def answer(tid,key='choose',choice='A',note='a note',revision=1):return dict(home='Main',task=tid,key=key,revision=revision,choice=choice,note=note)
def accelerate(ids):
    for aid in ids:mutate('update answers set ready_at=0 where answer_id=?',(aid,))
def calls(h,name):
    p=h/'calls.jsonl'
    return [r for r in map(json.loads,p.read_text().splitlines()) if r[0]==name] if p.exists() else []
def passed(t):print('ok - '+t,flush=True)
try:
    for sub in ('serve','ingest','decision','live','answered','refresh','arm-answers','backup'):
        command(sub,'--help');command(sub,'--invalid',ok=False)
    command('--help');command('decision','Main','../bad','key',ok=False)
    refused=subprocess.run([str(pe),'sweep-home'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    assert refused.returncode and b'fixture containment refused' in refused.stderr
    assert sentinel_state()==sentinel_before
    passed('every subcommand validates arguments and supports --help')
    meta(home,'alpha','needs-decision [key=choose]: Which release?')
    meta(second,'beta')
    rows=[['alpha','in_flight','ship','wonderok','Release alpha','-','-','no','none'],
          ['origin-decision-budget','queued','captain','ces','Budget approval','captain','Set the budget','no','none'],
          ['blocked-decision-no','queued','captain','ces','Blocked hold','captain','Wait','yes','missing'],
          ['external','in_flight','ship','ces','External wait','external','Supplier','no','none']]
    (home/'rows.json').write_text(json.dumps(rows))
    command('ingest','--once');before=rev()
    assert sql("select title from tasks where task_id='alpha'")[0]['title']=='Release alpha'
    assert len(sql("select * from decisions where source='hold'"))==1
    assert sql("select * from decisions where task_id='alpha'")[0]['decision_key']=='choose'
    assert sql("select * from tasks where home_id='Second' and task_id='beta'")
    assert not calls(home,'fm-fleet-snapshot.sh')
    command('ingest','--once');assert rev()==before
    (home/'state/alpha.status').touch();command('ingest','--once');assert rev()==before
    (home/'state/.last-watcher-beat').touch();command('ingest','--once');assert rev()==before
    passed('fixture homes, actionable holds, keyed decisions; no timestamp churn or hot snapshots')
    (second/'state/beta.meta').unlink();command('ingest','--once','--home','Second')
    assert sql("select deleted_at from tasks where task_id='beta'")[0]['deleted_at']
    assert rev()==before+1
    passed('vanished meta tombstones once')
    before=rev();decision('alpha');assert rev()==before+1
    row=sql("select * from decisions where task_id='alpha' order by revision desc")[0]
    assert json.loads(row['options'])[0]['label']=='Ship it' and row['recommendation']=='A'
    decision('alpha');assert rev()==before+1
    passed('decision CLI creates options and recommendation idempotently')
    # Single flight across CLI processes, preserving last-good state on timeout.
    (home/'delay').write_text('12');(home/'state/alpha.status').touch()
    slow=subprocess.Popen([str(cli),'ingest','--once','--home','Main'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    time.sleep(.5);n=len(calls(home,'fm-crew-state.sh'))
    command('ingest','--once','--home','Main');assert len(calls(home,'fm-crew-state.sh'))==n
    _,err=slow.communicate(timeout=20);assert slow.returncode!=0 and b'timeout' in err
    assert sql("select title from tasks where task_id='alpha'")[0]['title']=='Release alpha'
    assert 'timeout' in sql("select last_error from ingest_runs where home_id='Main'")[0]['last_error']
    (home/'delay').unlink();command('ingest','--once');passed('single-flight and bounded subprocess failure keep last-good rows')
    start();assert calls(home,'fm-fleet-snapshot.sh')
    status,health,_=request('/healthz');assert status==200 and health['answers_armed']
    assert set(('ok','ingest_age_s','last_snapshot_ms','sse_clients','db_ok','outbox_backlog','answers_armed'))<=health.keys()
    _,payload,h=request();assert request(extra={'If-None-Match':h['ETag']})[0]==304
    assert request(auth=False)[0]==403
    assert request('/api/state',extra={'Origin':'http://evil.test'})[0]==403
    assert request('/../config/board.json')[0]==404
    assert request('/')[0]==200
    assert request('/answer',answer('alpha',revision=row['revision']),auth=False)[0]==403
    assert request('/answer',answer('alpha',revision=99))[0]==409
    passed('health, Bearer authentication, Host/Origin boundary, explicit routes, ETag, stale revision')
    # SSE uses a real streaming socket; new status appears without reload.
    req=urllib.request.Request(f'http://localhost:{port}/events',headers={'Authorization':'Bearer '+secret})
    stream=urllib.request.urlopen(req,timeout=15)
    event=b''
    while b'\n\n' not in event:event+=stream.readline()
    assert b'event: changed' in event and b'"rev"' in event
    meta(home,'pushed','needs-decision [key=deploy]: Pick a deploy window')
    wait(lambda:any(d['task_id']=='pushed' for d in request()[1]['decisions']),10)
    deadline=time.monotonic()+10
    while True:
        seen=b''
        while b'\n\n' not in seen:seen+=stream.readline()
        if b'event: changed' in seen:break
        assert time.monotonic()<deadline,'SSE changed event missing'
    # Registration pushes immediately through the loopback-only reload route.
    started=time.monotonic();result=decision('instant')
    while True:
        pushed=b''
        while b'\n\n' not in pushed:pushed+=stream.readline()
        data=next((line[6:] for line in pushed.splitlines() if line.startswith(b'data: ')),b'{}')
        if json.loads(data).get('rev')==rev():break
    assert time.monotonic()-started<1.5,'registration did not push promptly'
    assert request('/internal/reload',{},auth=False)[0]==403
    stream.close();passed('changed SSE carries rev, status arrives within ten seconds, registration pushes immediately')
    # Queue is durable before handler starts; restart does not lose or duplicate.
    code_,posted,_=request('/answer',answer('alpha',revision=row['revision']));assert code_==200,posted
    aid=posted['answers'][0]['answer_id'];assert request('/answer',answer('alpha',revision=row['revision']))[1]['answers'][0]['answer_id']==aid
    assert sql('select state from decisions where task_id=? and revision=?',('alpha',row['revision']))[0]['state']=='queued'
    assert request('/answer',{'action':'undo','answer_id':aid})[0]==200
    aid=request('/answer',answer('alpha',revision=row['revision']))[1]['answers'][0]['answer_id']
    stop(kill=True);start();accelerate([aid])
    wait(lambda:sql('select consumed_at from answers where answer_id=?',(aid,))[0]['consumed_at'])
    delivered=list(map(json.loads,(home/'deliveries.jsonl').read_text().splitlines()))
    assert len(delivered)==1 and delivered[0][:3]==['alpha','--resolve-key','choose'] and '(note: a note)' in delivered[0][-1]
    assert not (home/'state/board-inbox/answers.jsonl').exists()
    command('answered',aid);passed('undo, dedupe, crash-before-handler replay, note routing, consumption without JSONL')
    # A known keyed legacy answer goes to its worker, including its note.
    meta(home,'keyed-legacy','needs-decision [key=reason]: Explain your choice')
    wait(lambda:any(d['task_id']=='keyed-legacy' for d in request()[1]['decisions']))
    r=request('/answer',answer('keyed-legacy',key='reason',choice='custom',note='Keep the current copy'))
    kid=r[1]['answers'][0]['answer_id'];accelerate([kid])
    wait(lambda:sql('select consumed_at from answers where answer_id=?',(kid,))[0]['consumed_at'])
    meta(home,'options-please','needs-decision [key=alternatives]: Need options')
    wait(lambda:any(d['task_id']=='options-please' for d in request()[1]['decisions']))
    r=request('/answer',answer('options-please',key='alternatives',choice='request-options',note=''))
    oid=r[1]['answers'][0]['answer_id'];accelerate([oid])
    wait(lambda:sql('select consumed_at from answers where answer_id=?',(oid,))[0]['consumed_at'])
    deliveries=list(map(json.loads,(home/'deliveries.jsonl').read_text().splitlines()))
    assert deliveries[-2][-1]=='custom (note: Keep the current copy)'
    assert deliveries[-1]==['options-please',"Captain requested structured options for decision alternatives: register 2-4 distinct alternatives with `bin/fm-board.sh decision Main options-please alternatives --option '...'` and stop."]
    passed('keyed legacy note routes directly; concrete-options request is one exact fixed steer')
    # Three legacy answers are exceptions: one atomic JSONL burst, one source fire.
    for i in range(3):meta(home,f'legacy{i}',f'needs-decision: Explain choice {i}')
    wait(lambda:len([d for d in request()[1]['decisions'] if d['task_id'].startswith('legacy')])==3)
    batch=[answer(f'legacy{i}',key='default',choice='custom',note='Please inspect') for i in range(3)]
    response=request('/answers',{'answers':batch});assert response[0]==200,response
    aids=[a['answer_id'] for a in response[1]['answers']];accelerate(aids)
    log=home/'state/board-inbox/answers.jsonl'
    wait(lambda:log.exists() and len(log.read_text().splitlines())==3)
    wait(lambda:len(list((home/'state/procevent-inbox').glob('*.result')))==1)
    time.sleep(1)
    assert len(list((home/'state/procevent-inbox').glob('*.result')))==1
    exported=list(map(json.loads,log.read_text().splitlines()))
    assert {a['answer_id'] for a in exported}==set(aids)
    assert all(set(('ts','home','task','choice','note','key','answer_id'))<=a.keys() for a in exported)
    # Restore the exact crash-after-publication state; restart must not append duplicates.
    stop();mutate('update answers set exported_at=NULL where error IS NOT NULL');start()
    wait(lambda:all(a['exported_at'] for a in sql('select * from answers where error IS NOT NULL')))
    assert len(log.read_text().splitlines())==3
    for a in aids:command('answered',a)
    passed('batch exceptions produce one JSONL burst/source fire; publication crash replay is idempotent')
    # A backlog hold invokes the authoritative keyed-answer intake.
    held=next(d for d in request()[1]['decisions'] if d['task_id']=='origin-decision-budget')
    r=request('/answer',answer(held['task_id'],key='budget',choice='custom',note='Use the small budget',revision=held['revision']))
    assert r[0]==200,r
    hid=r[1]['answers'][0]['answer_id'];accelerate([hid])
    wait(lambda:sql('select consumed_at from answers where answer_id=?',(hid,))[0]['consumed_at'])
    assert (home/'hold-input').read_text().startswith('budget\tcustom (note: Use the small budget)\t')
    passed('backlog hold routes through fm-decision-hold answers')
    assert not sql("select * from events where kind='live'")
    command('live','Main','alpha','--url','javascript:bad','--env','production',ok=False)
    command('live','Main','alpha','--url','https://example.com','--env','production','--evidence','Verified response')
    assert sql("select * from events where kind='live'")[0]['verified_at']
    passed('daemon and runner subprocess environments reject inherited path overrides')
    stop()
    for _ in range(8):backup=json.loads(command('backup').stdout)['backup']
    assert len(list((home/'state/backups').glob('board-*.sqlite')))==7
    expected=rev()
    for suffix in ('','-wal','-shm'):
        p=pathlib.Path(str(home/'state/board.sqlite')+suffix)
        if p.exists():p.unlink()
    shutil.copy2(backup,home/'state/board.sqlite');assert rev()==expected
    command('ingest','--once');passed('verified live registration and VACUUM backup restore')
    # The replaced private source used a plain integer cursor and records with
    # no UUID. Preserve those records as exceptions while exporting new rows.
    cursor=home/'state/board-inbox/answers.cursor'
    cursor.write_text(str(json.loads(cursor.read_text())['offset']))
    with log.open('a') as f:f.write(json.dumps({'ts':'legacy','home':'Main','task':'old','choice':'custom','note':'Older answer'})+'\n')
    start()
    wait(lambda:len(list((home/'state/procevent-inbox').glob('*.result')))==2)
    wait(lambda:isinstance(json.loads(cursor.read_text()),dict))
    r=request('/answer',{'action':'correction','answer_id':aid,'note':'Review this correction'})
    assert r[0]==200,r
    cid=sql("select answer_id from answers where action='correction'")[0]['answer_id'];accelerate([cid])
    wait(lambda:sql('select exported_at from answers where answer_id=?',(cid,))[0]['exported_at'])
    assert len(log.read_text().splitlines())==5
    passed('legacy integer cursor and id-less lines migrate without losing or blocking answers')
except Exception:
    for log in (root/'daemon.log',home/'state/logs/board.log',home/'state/logs/board-answers.log'):
        if log.exists():print(log.name+': '+log.read_text()[-1800:],file=sys.stderr)
    raise
finally:
    stop()
    cleanup_env=dict(env)
    for key in ('FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE'):
        cleanup_env.pop(key,None)
    assert pathlib.Path(cleanup_env['FM_HOME']).resolve()==home
    cleanup=subprocess.run([str(pe),'sweep-home'],env=cleanup_env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
    assert cleanup.returncode==0,cleanup.stderr.decode()
    audit=[json.loads(line) for line in (root/'isolation.jsonl').read_text().splitlines()]
    executed=[record for record in audit if record['allowed']]
    assert any(r['command'][0]=='start' for r in executed)
    assert any(r['command'][0]=='register' for r in executed)
    sweeps=[r for r in executed if r['command'][0]=='sweep-home']
    assert len(sweeps)==1 and sweeps[0]['home']==str(home)
    assert all(all(v is None for v in r['overrides'].values()) for r in executed if r['command'][0]!='retire')
    assert all(r['overrides']['FM_STATE_OVERRIDE']==str(home/'state') for r in executed if r['command'][0]=='retire')
    assert sentinel_state()==sentinel_before
    out.close()
    passed('all cleanup uses only fixture FM_HOME; all three path overrides stripped; sentinel unchanged')
PY
pass 'dashboard integration suite'
