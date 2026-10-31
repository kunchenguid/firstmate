#!/usr/bin/env bash
# Explicit corpus snapshots, completion wiki and atomic derived Connections graph.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-brain)
export BRAIN_ROOT="$ROOT" BRAIN_TMP="$TMP_ROOT"
python3 - <<'PY'
import json,os,subprocess
from pathlib import Path
root=Path(os.environ['BRAIN_ROOT']);tmp=Path(os.environ['BRAIN_TMP']);home=tmp/'home'
(home/'config/project-brains').mkdir(parents=True);(home/'data').mkdir();(home/'state').mkdir()
(home/'data/projects.md').write_text('- alpha [no-mistakes] - Alpha (added 2026-10-31)\n- beta [no-mistakes] - Beta (added 2026-10-31)\n')
a=tmp/'a.md';b=tmp/'b.md';original='# Alpha\nFirst fact.\n```markdown\n## Connections\n[[units/ghost]]\n```\n';a.write_text(original);b.write_text('# Beta\nSecond fact.\n')
cfg={'schema_version':1,'sources':[{'id':'a','path':str(a)},{'id':'b','path':str(b)}]}
conf=home/'config/project-brains/alpha.json';conf.write_text(json.dumps(cfg))
env=dict(os.environ,FM_HOME=str(home));env.pop('FM_TASK_ID',None)
def run(*args,ok=True):
 p=subprocess.run(['bash',str(root/'bin/fm-brain.sh'),*args],env=env,text=True,capture_output=True)
 assert (p.returncode==0)==ok,(p.returncode,p.stdout,p.stderr)
 return p
assert json.loads(run('status','beta').stdout)['status']=='unconfigured'
run('check','alpha',ok=False)
summary=tmp/'unit.json';summary.write_text(json.dumps({'title':'Profile unit','body':'A bounded completed unit.','sources':['a','b'],'connections':[]}))
d=json.loads(run('complete','alpha','--unit','unit-1','--summary',str(summary)).stdout);generation=Path(d['generation'])
assert (generation/'index.md').is_file() and (generation/'log.md').is_file()
graph=json.loads((generation/'graphify-out/graph.json').read_text())
assert len(graph['nodes'])==3 and len(graph['links'])==2
assert all(e['confidence']=='EXTRACTED' and e['source_location'] for e in graph['links'])
manifest=json.loads((generation/'manifest.json').read_text());old=manifest['sources']['a']['sha256']
raw=home/'data/brains/alpha/raw'/f'{old}.md';assert raw.read_text()==a.read_text()
run('check','alpha');same=json.loads(run('complete','alpha','--unit','unit-1','--summary',str(summary)).stdout)
assert same['generation']==str(generation)
a.write_text('# Alpha\nChanged fact.\n');run('check','alpha',ok=False)
new=json.loads(run('build','alpha').stdout);assert new['generation']!=str(generation) and raw.read_text()==original
# Deleted derived graph is detected and rebuilt without erasing historical generations.
broken=Path(new['generation']);(broken/'graphify-out/graph.json').unlink();run('check','alpha',ok=False)
repaired=json.loads(run('build','alpha').stdout)
assert repaired['generation']!=str(broken) and broken.exists()
run('check','alpha');assert json.loads(run('build','alpha').stdout)['generation']==repaired['generation']
# Explicit source removal shrinks only derived current state; historical evidence survives.
cfg['sources']=cfg['sources'][:1];conf.write_text(json.dumps(cfg));run('check','alpha',ok=False)
new=json.loads(run('build','alpha').stdout);current=Path(new['generation'])
g=json.loads((current/'graphify-out/graph.json').read_text());assert len(g['nodes'])==2 and len(g['links'])==1
assert json.loads((current/'manifest.json').read_text())['units']['unit-1']['status']=='stale'
assert generation.is_dir() and (current/'pages/units/unit-1.md').is_file()
# Failed update cannot publish a half-wiki or erase prior graph; retry uses the same explicit summary.
pointer=(home/'data/brains/alpha/CURRENT').read_text()
summary.write_text(json.dumps({'title':'Broken unit','body':'Retry me.','sources':['unknown'],'connections':[]}))
run('complete','alpha','--unit','bad-unit','--summary',str(summary),ok=False)
assert (home/'data/brains/alpha/CURRENT').read_text()==pointer
assert json.loads(run('status','alpha').stdout)['last_attempt']['status']=='failed'
summary.write_text(json.dumps({'title':'Retry unit','body':'Recovered.','sources':['a'],'connections':[]}))
run('complete','alpha','--unit','bad-unit','--summary',str(summary));run('check','alpha')
assert not (home/'data/brains/beta').exists()
# Explicitly adding a third source is detected and rebuilt; no unrelated file is discovered.
c=tmp/'c.md';c.write_text('# Added source\nNew evidence.\n')
cfg['sources'].append({'id':'c','path':str(c)});conf.write_text(json.dumps(cfg));run('check','alpha',ok=False)
added=json.loads(run('build','alpha').stdout)
assert len(json.loads((Path(added['generation'])/'graphify-out/graph.json').read_text())['nodes'])==4
lock=home/'data/brains/alpha/.write-lock';lock.mkdir()
run('build','alpha',ok=False);lock.rmdir()
assert json.loads(run('build','alpha').stdout)['generation']==added['generation']
# A deleted input cannot be called fresh; the prior raw evidence remains readable.
c.unlink();run('check','alpha',ok=False);run('build','alpha');run('check','alpha')
assert json.loads(run('status','alpha').stdout)['status']=='current'  # current missing-source observation, not claim verification

# Output must not recursively ingest itself, and source symlinks are refused.
a.unlink();a.symlink_to(b);run('build','alpha',ok=False)
assert json.loads(run('status','alpha').stdout)['status']=='stale'
print('ok: completion, idempotence, source add/change/delete, stale references, retained prior generation, retry, isolation')
PY
