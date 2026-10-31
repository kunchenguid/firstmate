#!/usr/bin/env bash
# Explicit corpus snapshots, completion wiki and atomic derived Connections graph.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-brain)
export BRAIN_ROOT="$ROOT" BRAIN_TMP="$TMP_ROOT"
python3 - <<'PY'
import hashlib,json,os,subprocess
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
baseline=summary.read_text()
for marker in ['```','~~~']:
 for refs in [[],['units/ghost']]:
  summary.write_text(json.dumps({'title':'Unclosed example','body':f'Example:\n{marker}markdown\n[[sources/a]]','sources':['a','b'],'connections':refs}))
  pointer=(home/'data/brains/alpha/CURRENT').read_text()
  run('complete','alpha','--unit','unit-1','--summary',str(summary),ok=False)
  assert (home/'data/brains/alpha/CURRENT').read_text()==pointer
summary.write_text(json.dumps({'title':'Cited examples','body':'```markdown\n[[units/unit-1]]\n[[sources/a]]\n```\n\n~~~markdown\n[[sources/b]]\n~~~','sources':['a','b'],'connections':['units/unit-1','units/unit-1']}))
cited=Path(json.loads(run('complete','alpha','--unit','unit-1','--summary',str(summary)).stdout)['generation'])
page=(cited/'pages/units/unit-1.md').read_text().splitlines()
section=page.index('## Connections')+1
edges=json.loads((cited/'graphify-out/graph.json').read_text())['links']
assert {edge['target'] for edge in edges}=={'alpha/sources/a','alpha/sources/b','alpha/units/unit-1'} and len(edges)==3
for edge in edges:
 location,lineno=edge['source_location'].rsplit(':',1)
 assert location=='pages/units/unit-1.md' and int(lineno)>section
 assert page[int(lineno)-1]==f'- [[{edge["target"].removeprefix("alpha/")}]]'
summary.write_text(baseline)
assert json.loads(run('complete','alpha','--unit','unit-1','--summary',str(summary)).stdout)['generation']==str(generation)
(generation/'graphify-out/graph.json').write_text('{}\n')
a.write_text('# Alpha\nTemporary input.\n');run('build','alpha')
a.write_text(original)
historical_repair=Path(json.loads(run('build','alpha').stdout)['generation'])
assert historical_repair!=generation and generation.exists()
run('check','alpha')
(historical_repair/'pages/units/unit-1.md').write_text('Damaged page.\n')
a.write_text('# Alpha\nTemporary input.\n');run('build','alpha')
a.write_text(original)
second_repair=Path(json.loads(run('build','alpha').stdout)['generation'])
assert second_repair not in [generation,historical_repair] and historical_repair.exists()
run('check','alpha')
assert json.loads(run('build','alpha').stdout)['generation']==str(second_repair)
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

for content in [b'x'*2_000_000,b'`'*2_000_000,'# Evidence\r\nΑκριβές.\r\nMixed.\n'.encode(),b'# Evidence\rBare carriage return.\r']:
 a.write_bytes(content)
 built=Path(json.loads(run('build','alpha').stdout)['generation'])
 run('check','alpha')
 assert json.loads(run('status','alpha').stdout)['status']=='current'
 sha=hashlib.sha256(content).hexdigest()
 manifest=json.loads((built/'manifest.json').read_text())
 assert manifest['sources']['a']['sha256']==sha
 assert (home/'data/brains/alpha/raw'/f'{sha}.md').read_bytes()==content
 page=(built/'pages/sources/a.md').read_bytes()
 assert content in page and f'SHA-256: {sha}'.encode() in page
 assert hashlib.sha256(page).hexdigest()==manifest['pages']['sources/a']
 assert json.loads(run('build','alpha').stdout)['generation']==str(built)
 run('query','alpha','Evidence: a')
pointer=(home/'data/brains/alpha/CURRENT').read_text()
a.write_bytes(b'x'*2_000_001)
run('build','alpha',ok=False)
assert (home/'data/brains/alpha/CURRENT').read_text()==pointer
a.write_text(original);run('build','alpha');run('check','alpha')

pointer=(home/'data/brains/alpha/CURRENT').read_text()
current=home/'data/brains/alpha/generations'/pointer.strip()
saved_log=(current/'log.md').read_bytes()
(current/'log.md').write_bytes(b'x'*1_999_999)
a.write_text('# Log boundary\n')
failure=run('build','alpha',ok=False)
assert 'staged generation failed validation' in failure.stderr
assert (home/'data/brains/alpha/CURRENT').read_text()==pointer
assert not list((home/'data/brains/alpha').glob('.generation-*'))
(current/'log.md').write_bytes(saved_log)
a.write_text(original);run('check','alpha')

units=json.loads((current/'units.json').read_text())
for i in range(6000):
 units[f'bulk-{i:05}-'+('x'*89)]={'title':'Small unit','body':'Done.','sources':['a'],'connections':[]}
(current/'units.json').write_text(json.dumps(units,ensure_ascii=False,sort_keys=True,indent=2)+'\n')
assert (current/'units.json').stat().st_size<2_000_000
large=Path(json.loads(run('build','alpha').stdout)['generation'])
assert (large/'manifest.json').stat().st_size>2_000_000
assert json.loads(run('status','alpha').stdout)['status']=='current'
run('check','alpha');run('query','alpha','Small unit')
assert json.loads(run('build','alpha').stdout)['generation']==str(large)
assert json.loads(run('complete-task','alpha','--unit','unit-1').stdout)['generation']==str(large)
a.write_text('# Large manifest drift\n');run('build','alpha')
a.write_text(original)
assert json.loads(run('build','alpha').stdout)['generation']==str(large)
run('check','alpha')

# Output must not recursively ingest itself, and source symlinks are refused.
a.unlink();a.symlink_to(b);run('build','alpha',ok=False)
assert json.loads(run('status','alpha').stdout)['status']=='stale'
print('ok: completion, idempotence, source add/change/delete, stale references, retained prior generation, retry, isolation')
PY
