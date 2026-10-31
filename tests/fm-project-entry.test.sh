#!/usr/bin/env bash
# Folder entry resolves a single existing owner and relays without supervisor creation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-entry)
export ENTRY_ROOT="$ROOT" ENTRY_TMP="$TMP_ROOT"
python3 - <<'PY'
import json,os,subprocess
from pathlib import Path
root=Path(os.environ['ENTRY_ROOT']);tmp=Path(os.environ['ENTRY_TMP']);home=tmp/'home'
for x in ['config','data','state','projects/alpha','projects/beta']:(home/x).mkdir(parents=True)
for name in ['alpha','beta']:subprocess.run(['git','init','-q',str(home/'projects'/name)],check=True)
(home/'data/projects.md').write_text('- alpha [no-mistakes] - Alpha (added 2026-10-31)\n- beta [local-only] - Beta (added 2026-10-31)\n')
env=dict(os.environ,FM_HOME=str(home));env.pop('FM_TASK_ID',None)
def run(*args,ok=True,env=env):
 p=subprocess.run(['bash',str(root/'bin/fm-entry.sh'),*args],env=env,text=True,capture_output=True)
 assert (p.returncode==0)==ok,(p.returncode,p.stdout,p.stderr)
 return p
p=run('inspect',str(home/'projects/alpha'));d=json.loads(p.stdout)
assert d['project']=='alpha' and d['owner']=='main' and d['gateway_home']==str(home)
assert not (home/'state/.lock').exists()
# A project owner is an existing registry binding, never a clone-list inference.
child=tmp/'child';(child/'data').mkdir(parents=True)
(home/'data/secondmates.md').write_text(f'- alpha-lead - Alpha (home: {child}; scope: Alpha implementation; projects: alpha; added 2026-10-31)\n')
(home/'data/alpha-lead').mkdir();(home/'data/alpha-lead/brief.md').write_text('# Charter\nAlpha coordination.\n# Routing scope\nAlpha implementation.\n')
(home/'config/project-entry.json').write_text(json.dumps({'schema_version':1,'owners':{'alpha':'alpha-lead'}}))
a=json.loads(run('inspect',str(home/'projects/alpha')).stdout)
assert a['owner']=='alpha-lead' and a['owner_home']==str(child)
assert json.loads(run('inspect',str(home/'projects/beta')).stdout)['owner']=='main'
(home/'projects/alpha/sub').mkdir()
assert json.loads(run('inspect',str(home/'projects/alpha/sub')).stdout)['owner']=='alpha-lead'
# Two independent entry clients resolve the same owner and idempotently relay through the primary inbox.
for _ in range(2):run('send',str(home/'projects/alpha'),'--request-id','same-project-request','--','Please plan the next unit.')
notes=list((home/'state/inbox/pending').glob('*'))
# Use the real inbox receipt protocol rather than relying on storage paths.
r=subprocess.run(['bash',str(root/'bin/fm-inbox.sh'),'receipts','--all-pending'],env=env,text=True,capture_output=True)
assert r.returncode==0,r.stderr
assert r.stdout.count('Please plan the next unit.')==1,r.stdout
assert not (child/'state').exists() and not (home/'state/.lock').exists()
context=run('context',str(home/'projects/alpha')).stdout
assert 'entry client' in context and 'parent' in context and 'alpha-lead' in context
# The entry clients leave an existing home lock byte-identical.
(home/'state/.lock').write_text('existing-primary-owner\n')
run('inspect',str(home/'projects/alpha'))
assert (home/'state/.lock').read_text()=='existing-primary-owner\n'
# The normal primary reply stays on its owned inbox receipt path.
bad=dict(env,FM_TASK_ID='crew');assert 'worker' in run('inspect',str(home/'projects/alpha'),ok=False,env=bad).stderr
(home/'config/project-entry.json').write_text('{broken')
run('inspect',str(home/'projects/alpha'),ok=False)
(home/'config/project-entry.json').write_text(json.dumps({'schema_version':1,'owners':{'alpha':'missing'}}))
run('inspect',str(home/'projects/alpha'),ok=False)
print('ok: single-owner project entry, two clients, idempotent parent relay, isolation and refusal')
PY
