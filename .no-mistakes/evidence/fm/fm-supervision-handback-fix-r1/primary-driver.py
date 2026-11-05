import subprocess, json, time, os, pathlib
root=pathlib.Path(__file__).parent
root=root/os.environ.get('SCENARIO','')
root.mkdir(exist_ok=True)
out=(root/'claude-persistent.jsonl').open('w')
args=['claude','--setting-sources','project','--model','haiku','--tools','','--strict-mcp-config','--debug-file',str(root/'persistent-debug.log'),'-p','--input-format','stream-json','--output-format','stream-json','--verbose']
p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=out,stderr=subprocess.STDOUT,text=True)
(root/'primary.pid').write_text(str(p.pid))
p.stdin.write(json.dumps({'type':'user','message':{'role':'user','content':'Say ahoy'}})+'\n'); p.stdin.flush()
try:
    until=time.monotonic()+600
    while p.poll() is None and time.monotonic()<until and not (root/'stop-primary').exists(): time.sleep(.2)
finally:
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=10)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    (root/'primary-exit').write_text(str(p.returncode))
    out.close()
