import os, sys, json, time, threading, subprocess, socket, http.server, urllib.request, urllib.error, shutil
from pathlib import Path

ROOT=Path.cwd(); VARIANT=sys.argv[1]; PROJECT=Path(os.environ['LIVE_PLUGIN_PROJECT']); FMHOME=Path(os.environ['LIVE_FM_HOME']); ID=os.environ['LIVE_ID']
EVIDENCE=Path('~/.no-mistakes/evidence/01M6YG76R9H5R07DWQ5KZ7B8SG')
LAB=ROOT/'.busy-live'/VARIANT; LAB.mkdir(exist_ok=True)
AUDIT=LAB/'events.jsonl'; RESULT=[]; hold=threading.Event(); release=threading.Event(); requests=[]
BIN=str(ROOT/'.busy-live/oc1193/node_modules/.bin/opencode')
class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length']))); requests.append(body)
        text=json.dumps(body.get('messages',[])[-1:])
        if 'HOLD_MAIN' in text:
            hold.set(); release.wait(20)
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        chunk={'id':'chatcmpl-local','object':'chat.completion.chunk','created':1,'model':'local','choices':[{'index':0,'delta':{'role':'assistant','content':'LOCAL_TURN_ACK'},'finish_reason':None}]}
        try:
            self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode())
            chunk['choices'][0]={'index':0,'delta':{},'finish_reason':'stop'}
            self.wfile.write(('data: '+json.dumps(chunk)+'\n\ndata: [DONE]\n\n').encode()); self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass
provider=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider)
pt=threading.Thread(target=provider.serve_forever); pt.start()
config={'model':'fixture/local','snapshot':False,'permission':{'*':'deny'},'provider':{'fixture':{'npm':'@ai-sdk/openai-compatible','name':'Fixture','options':{'baseURL':f'http://127.0.0.1:{provider.server_port}/v1','apiKey':'local-not-a-credential'},'models':{'local':{'name':'Local fixture','limit':{'context':100000,'output':1000}}}}}}
(PROJECT/'opencode.json').write_text(json.dumps(config))
(PROJECT/'.opencode/plugins/z-live-audit.js').write_text('import { appendFileSync } from "node:fs";\nexport const LiveAudit = async () => ({event: async ({event}) => {appendFileSync('+json.dumps(str(AUDIT))+',JSON.stringify({at:new Date().toISOString(),event})+"\\n");}});\n')
env=dict(os.environ)
for k in list(env):
    if k.startswith(('OPENCODE_','FM_','XDG_')) or k in ('TMUX','NO_MISTAKES_GATE','PI_CODING_AGENT'): del env[k]
env.update(HOME=str(LAB/'user'),FM_HOME=str(FMHOME),OPENCODE_DB=str(LAB/'sessions.db'),OPENCODE_DISABLE_AUTOUPDATE='1',OPENCODE_DISABLE_LSP_DOWNLOAD='1',OPENCODE_DISABLE_MODELS_FETCH='1',OPENCODE_DISABLE_DEFAULT_PLUGINS='1')
for kind in ('CONFIG','DATA','CACHE','STATE'):
    p=LAB/kind.lower(); p.mkdir(exist_ok=True); env['XDG_'+kind+'_HOME']=str(p)
with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
log=(LAB/'server.log').open('w'); proc=subprocess.Popen([BIN,'serve','--hostname','127.0.0.1','--port',str(port)],cwd=PROJECT,env=env,stdout=log,stderr=log)
def api(path,body=None,method=None):
    req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=45) as r:
        b=r.read(); return json.loads(b) if b else None
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
def classification():
    return subprocess.check_output(['bash','-c','source "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux fake:w opencode "$2" "$3"','bash',str(ROOT),ID,str(FMHOME/'state')],text=True).strip()
def emit(kind,**values):
    rec={'scenario':kind,**values}; RESULT.append(rec); print(json.dumps(rec),flush=True)
def turn(sid,text):
    out=api('/session/'+sid+'/message',{'model':{'providerID':'fixture','modelID':'local'},'parts':[{'type':'text','text':text}]})
    parts=out.get('parts',[])
    assert any(p.get('type')=='text' and p.get('text')=='LOCAL_TURN_ACK' for p in parts),out
    return out
try:
    until(lambda:api('/global/health'),'server health')
    sid=api('/session',{'title':'Isolated busy/idle regression'})['id']
    for i in range(5):
        before=state(); out=turn(sid,'Reply with LOCAL_TURN_ACK only. Turn '+str(i)); time.sleep(1.0)
        after=state(); c=classification()
        emit('real-turn',variant=VARIANT,turn=i,session=sid,classification=c,record=after,assistant='LOCAL_TURN_ACK')
        assert after!=before,'Plugin did not update state'
        if VARIANT!='base':assert c=='idle opencode-plugin',c
    if VARIANT!='base':
        errors=[]
        def main_turn():
            try:turn(sid,'HOLD_MAIN: Reply with LOCAL_TURN_ACK only.')
            except Exception as e:errors.append(str(e))
        t=threading.Thread(target=main_turn);t.start()
        try:
            assert hold.wait(15),'Provider never saw held turn'
            until(lambda:classification()=='busy opencode-plugin','active main busy')
            child=api('/session',{'parentID':sid,'title':'Child terminal boundary'})['id']
            turn(child,'Reply with LOCAL_TURN_ACK only. Child finishes while parent waits.')
            time.sleep(1)
            c=classification();emit('child-idle-while-parent-busy',classification=c,record=state(),main=sid,child=child)
            assert c=='busy opencode-plugin',c
        finally:
            release.set();t.join(45)
        assert not t.is_alive() and not errors,errors
        until(lambda:classification()=='idle opencode-plugin','parent final idle')
        emit('parent-settled-after-child',classification=classification(),record=state())
finally:
    release.set();proc.terminate()
    try:proc.wait(15)
    except subprocess.TimeoutExpired:proc.kill();proc.wait()
    provider.shutdown();provider.server_close();pt.join();log.close()
    (EVIDENCE/(VARIANT+'-live-results.json')).write_text(json.dumps(RESULT,indent=2))
    if AUDIT.exists():shutil.copy(AUDIT,EVIDENCE/(VARIANT+'-events.jsonl'))
    shutil.copy(LAB/'server.log',EVIDENCE/(VARIANT+'-server.log'))
    (EVIDENCE/(VARIANT+'-lifecycle.json')).write_text(json.dumps({'server_exit':proc.returncode,'provider_thread_stopped':not pt.is_alive(),'provider_requests':len(requests),'cli':BIN,'version':subprocess.check_output([BIN,'--version'],text=True).strip()}))
