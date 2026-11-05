import concurrent.futures, json, os, pathlib, shutil, subprocess
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/kalvira/.no-mistakes/evidence/01M6PYAR78HNGTRD5001DE84AF')
cases=[('ship','ship-inline.json','ship-local.json','default'),('scout','scout-inline.json','scout-local.json','default'),('keep-trailers','keep-trailers-inline.json',None,'default'),('secondmate','secondmate-inline.json',None,'orchestrator'),('t3-ship',None,'t3-ship-local.json','default'),('t3-scout',None,'t3-scout-local.json','default')]
def run(case):
    name,inline,local,expected=case
    cwd=root/'.test-output-style'/name
    shutil.copytree(root/'.test-output-style/consumer',cwd)
    if local:
        shutil.copyfile(evidence/local,cwd/'.claude/settings.local.json')
    args=['claude','-p','Reply OK.','--max-turns','1','--no-session-persistence','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','project,local','--tools','','--output-format','stream-json','--verbose']
    if inline: args+=['--settings',str(evidence/inline)]
    result=subprocess.run(args,cwd=cwd,text=True,capture_output=True,timeout=60)
    (evidence/f'claude-{name}.jsonl').write_text(result.stdout)
    (evidence/f'claude-{name}.stderr').write_text(result.stderr)
    rows=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    init=next((r for r in rows if r.get('type')=='system' and r.get('subtype')=='init'),{})
    final=next((r for r in rows if r.get('type')=='result'),{})
    summary={'scenario':name,'command':args,'exit_code':result.returncode,'expected_style':expected,'actual_style':init.get('output_style'),'result':final.get('result'),'is_error':final.get('is_error')}
    summary['passed']=result.returncode==0 and init.get('output_style')==expected and final.get('is_error') is False and (('STYLE_SENTINEL_ORCHESTRATOR' in final.get('result',''))==(expected=='orchestrator'))
    return summary
cases=[('t3-secondmate',None,'t3-secondmate-local.json','orchestrator')]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    results=list(pool.map(run,cases))
results=json.loads((evidence/'consumer-results.json').read_text())+results
(evidence/'consumer-results.json').write_text(json.dumps(results,indent=2)+'\n')
for r in results: print(json.dumps(r))
assert all(r['passed'] for r in results)
