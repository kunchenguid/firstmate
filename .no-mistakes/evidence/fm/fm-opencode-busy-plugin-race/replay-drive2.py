import os, sys, json, time, threading, subprocess, socket, http.server, urllib.request, urllib.error, urllib.parse, base64, shutil
from pathlib import Path
ROOT=Path.cwd(); PROJECT=Path(os.environ['LIVE_PLUGIN_PROJECT']); FMHOME=Path(os.environ['LIVE_FM_HOME']); ID=os.environ['LIVE_ID']
EVIDENCE=Path('~/.no-mistakes/evidence/01M6YG76R9H5R07DWQ5KZ7B8SG'); LAB=ROOT/'.busy-live/v2'; LAB.mkdir(exist_ok=True)
generated_project=PROJECT
PROJECT=LAB/'project'
PROJECT.mkdir(exist_ok=True)
(PROJECT/'.opencode/plugins').mkdir(parents=True,exist_ok=True)
shutil.copy(generated_project/'.opencode/plugins/fm-busy-state.js',PROJECT/'.opencode/plugins/fm-busy-state.js')
subprocess.run(['git','init','-q',str(PROJECT)],check=True)
AUDIT=LAB/'events.jsonl'; RESULT=[]; hold=threading.Event(); release=threading.Event(); requests=[]
BIN=str(ROOT/'.busy-live/oc2/node_modules/.bin/opencode2')
class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length']))); requests.append(body)
        text=json.dumps(body.get('messages',[])[-1:])
        if 'HOLD_MAIN' in text: hold.set(); release.wait(20)
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        chunk={'id':'chatcmpl-local','object':'chat.completion.chunk','created':1,'model':'local','choices':[{'index':0,'delta':{'role':'assistant','content':'LOCAL_TURN_ACK'},'finish_reason':None}]}
        try:
            self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode()); chunk['choices'][0]={'index':0,'delta':{},'finish_reason':'stop'}
            self.wfile.write(('data: '+json.dumps(chunk)+'\n\ndata: [DONE]\n\n').encode()); self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass
provider=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider); pt=threading.Thread(target=provider.serve_forever);pt.start()
config={'model':'fixture/local','agents':{'build':{'model':'fixture/local'}},'snapshots':False,'permissions':[{'action':'*','resource':'*','effect':'deny'}],'providers':{'fixture':{'package':'@opencode-ai/ai/providers/openai-compatible','settings':{'baseURL':f'http://127.0.0.1:{provider.server_port}/v1','apiKey':'local-not-a-credential'},'models':{'local':{'capabilities':{'tools':True,'input':['text'],'output':['text']},'limit':{'context':100000,'output':1000}}}}}}
config['plugins']=[str(PROJECT/'.opencode/plugins/fm-busy-state.js'),str(PROJECT/'.opencode/plugins/z-live-audit.js')]
(PROJECT/'opencode.json').write_text(json.dumps(config))
(PROJECT/'.opencode/plugins/package.json').write_text('{"private":true,"type":"module"}')
(PROJECT/'.opencode/plugins/z-live-audit.js').write_text('import { appendFileSync } from "node:fs";\nconst log=(channel,event)=>appendFileSync('+json.dumps(str(AUDIT))+',JSON.stringify({at:new Date().toISOString(),channel,event})+"\\n");\nexport default {id:"test.audit",server:async()=>({event:async({event})=>log("server",event)}),setup(ctx){(async()=>{for await(const e of await ctx.event.subscribe())log("setup",e)})().catch(()=>{});}};\n')
env=dict(os.environ)
for k in list(env):
    if k.startswith(('OPENCODE_','FM_','XDG_')) or k in ('TMUX','NO_MISTAKES_GATE','PI_CODING_AGENT'): del env[k]
env.update(HOME=str(LAB/'user'),OPENCODE_TEST_HOME=str(LAB/'user'),FM_HOME=str(FMHOME),OPENCODE_DB=str(LAB/'sessions.db'),OPENCODE_DISABLE_AUTOUPDATE='1',OPENCODE_DISABLE_LSP_DOWNLOAD='1',OPENCODE_DISABLE_MODELS_FETCH='1')
for kind in ('CONFIG','DATA','CACHE','STATE'):
    p=LAB/kind.lower();p.mkdir(exist_ok=True);env['XDG_'+kind+'_HOME']=str(p)
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
logpath=LAB/'server.log';log=logpath.open('w');proc=subprocess.Popen([BIN,'serve','--hostname','127.0.0.1','--port',str(port)],cwd=PROJECT,env=env,stdout=log,stderr=log)
headers={}
def api(path,body=None,method=None):
    req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={**headers,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=30) as r:
        b=r.read();return json.loads(b) if b else None
def until(fn,label,seconds=30):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        try:
            v=fn()
            if v:return v
        except (OSError,urllib.error.URLError):pass
        time.sleep(.1)
    raise RuntimeError('Timeout: '+label)
def state():return (FMHOME/'state'/f'{ID}.busy-state').read_text()
def classify():return subprocess.check_output(['bash','-c','source "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux fake:w opencode "$2" "$3"','bash',str(ROOT),ID,str(FMHOME/'state')],text=True).strip()
def emit(kind,**values):
    rec={'scenario':kind,**values};RESULT.append(rec);print(json.dumps(rec),flush=True)
def turn(sid,text):
    admitted=api(f'/api/session/{sid}/prompt',{'text':text})['data']['id']
    def complete():
        ctx=api(f'/api/session/{sid}/context')['data'];idx=next((i for i,m in enumerate(ctx) if m['id']==admitted),None)
        return ctx[idx+1:] if idx is not None and any(m['type']=='assistant' and m.get('time',{}).get('completed') for m in ctx[idx+1:]) and api(f'/api/session/{sid}')['data'].get('outcome')=='succeeded' else None
    try:
        messages=until(complete,'turn terminal context',seconds=10)
    except RuntimeError:
        print('CONTEXT_DEBUG',json.dumps({'admitted':admitted,'session':api(f'/api/session/{sid}'),'context':api(f'/api/session/{sid}/context')}),flush=True)
        raise
    assert 'LOCAL_TURN_ACK' in json.dumps(messages),messages
try:
    password=until(lambda:next((x.removeprefix('server password ') for x in logpath.read_text().splitlines() if x.startswith('server password ')),None),'password')
    headers['Authorization']='Basic '+base64.b64encode(f'opencode:{password}'.encode()).decode()
    info=api('/api/health');emit('runtime',info=info)
    query=urllib.parse.urlencode({'location[directory]':str(PROJECT)})
    plugins=until(lambda:next((p for p in api('/api/plugin?'+query)['data'] if p.get('id')=='fm.busy-state' and p.get('status',p.get('state',{}).get('status'))=='active'),None),'busy plugin ready')
    emit('native-plugin-loaded',plugin=plugins)
    sid=api('/api/session',{'location':{'directory':str(PROJECT)},'agent':'build','model':{'providerID':'fixture','id':'local'}})['data']['id']
    for i in range(5):
        before=state();turn(sid,'Reply with LOCAL_TURN_ACK only. Turn '+str(i))
        until(lambda:state()!=before and classify()=='idle opencode-plugin','plugin queue settled')
        time.sleep(.5)
        after=state();c=classify();emit('real-v2-turn',turn=i,session=sid,classification=c,record=after)
        assert c=='idle opencode-plugin' and before!=after
    # Hold a real new turn and observe the next busy edge before releasing it.
    errors=[]
    def held():
        try:turn(sid,'HOLD_MAIN: Reply with LOCAL_TURN_ACK only.')
        except Exception as e:errors.append(str(e))
    t=threading.Thread(target=held);t.start()
    try:
        assert hold.wait(15);until(lambda:classify()=='busy opencode-plugin','next turn busy')
        emit('new-turn-busy',classification=classify(),record=state())
    finally:release.set();t.join(45)
    assert not t.is_alive() and not errors,errors
    until(lambda:classify()=='idle opencode-plugin','final idle');emit('new-turn-settled',classification=classify(),record=state())
finally:
    release.set();proc.terminate()
    try:proc.wait(15)
    except subprocess.TimeoutExpired:proc.kill();proc.wait()
    provider.shutdown();provider.server_close();pt.join();log.close()
    (EVIDENCE/'v2-live-results.json').write_text(json.dumps(RESULT,indent=2))
    if AUDIT.exists():shutil.copy(AUDIT,EVIDENCE/'v2-events.jsonl')
    shutil.copy(logpath,EVIDENCE/'v2-server.log')
    (EVIDENCE/'v2-lifecycle.json').write_text(json.dumps({'server_exit':proc.returncode,'provider_thread_stopped':not pt.is_alive(),'provider_requests':len(requests),'cli_version':subprocess.check_output([BIN,'--version'],text=True).strip()}))
