import os, sys, pathlib, subprocess, json
name=sys.argv[1]
home=pathlib.Path(os.environ['FM_HOME'])
expected=pathlib.Path(__file__).parent / ('sub-' + name)
assert home == expected, (home, expected)
keys=['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_CONFIG_OVERRIDE']
result={'scenario':name,'FM_HOME':str(home),'overrides':{k:{'present':k in os.environ,'value':os.environ.get(k)} for k in keys}}
assert all(k not in os.environ for k in keys), result
state=home/'state'
for suffix in ['check.sh','check-trust']:
    (state/('lab-env.'+suffix)).write_text('disposable validation artifact\n')
(state/'lab-env.keep').write_text('must remain\n')
r=subprocess.run([str(home/'bin/fm-check-unregister.sh'),'lab-env'],capture_output=True,text=True)
result['unregister']={'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'check_exists':(state/'lab-env.check.sh').exists(),'trust_exists':(state/'lab-env.check-trust').exists(),'unrelated_exists':(state/'lab-env.keep').exists()}
assert r.returncode == 0 and not (state/'lab-env.check.sh').exists() and not (state/'lab-env.check-trust').exists() and (state/'lab-env.keep').exists(), result
for suffix in ['check.sh','check-trust']:
    (state/('lab-empty.'+suffix)).write_text('must not be removed\n')
env=dict(os.environ,FM_STATE_OVERRIDE='')
r=subprocess.run([str(home/'bin/fm-check-unregister.sh'),'lab-empty'],env=env,capture_output=True,text=True)
result['explicit_empty_guard']={'exit':r.returncode,'stderr':r.stderr,'check_preserved':(state/'lab-empty.check.sh').exists(),'trust_preserved':(state/'lab-empty.check-trust').exists()}
assert r.returncode == 1 and 'state directory is unavailable' in r.stderr and (state/'lab-empty.check.sh').exists() and (state/'lab-empty.check-trust').exists(), result
out=pathlib.Path('~/.no-mistakes/evidence/01M70ZY6MZS566QD0EAKS3F9WW')/('live-'+name+'.json')
out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
