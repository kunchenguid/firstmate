"""Public lifecycle interfaces in a disposable home; no live fleet effects."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root, home = Path(os.environ['ROOT']), Path(os.environ['CASE_DIR'])
(home / 'state').mkdir(parents=True)
(home / 'data/task').mkdir(parents=True)
(home / 'state/.lock').write_text(str(os.getpid()) + '\n')
shutil.copytree(root / 'bin', home / 'bin')
bin_dir = home / 'bin'
(bin_dir / 'fm-crew-state.sh').write_text('#!/bin/sh\ncat "$FM_HOME/state/provider"\n')
(home / 'state/provider').write_text('state: working · source: controlled-provider\n')
brief = home / 'data/task/brief.md'
brief.write_text("# Task\n## Captain's intent\nOriginal request.\n\n## Firstmate spec\nValidate.\n")
meta = home / 'state/task.meta'
meta.write_text('spawn_gen=g1\nkind=ship\nexecutor=local-agent\nbackend=herdr\nwindow=fixture:w1:p-task\nharness=pi\nendpoint_task_id=task\n')
env = dict(os.environ, FM_HOME=str(home), FM_SUPERVISION_ACTOR='main', PI_CODING_AGENT='true',
           PATH=os.environ['FM_FIXTURE_BACKEND'] + os.pathsep + os.environ['PATH'])
env.pop('FM_ROOT_OVERRIDE', None)
env.pop('FM_DATA_OVERRIDE', None)
env.pop('FM_STATE_OVERRIDE', None)


def call(script, *args, ok=True, actor='main'):
    proc = subprocess.run([str(bin_dir / script), *args], text=True, capture_output=True,
                          env=dict(env, FM_SUPERVISION_ACTOR=actor))
    assert (proc.returncode == 0) == ok, (args, proc.returncode, proc.stdout, proc.stderr)
    return json.loads(proc.stdout) if ok and proc.stdout.startswith('{') else proc


def state(op, *args, **kwargs):
    return call('fm-task-state.sh', op, 'task', *args, **kwargs)


def inspect(*refs):
    return state('inspect', *[part for ref in refs for part in ('--evidence', ref)])


def assess(value, basis=None, ok=True, actor='main'):
    refs = value['evidence'] + [value['authority_ref']]
    action = value.get('next_action')
    if action:
        refs.append(action['payload_ref'])
        if action.get('blocker'):
            refs.append(action['blocker']['release_ref'])
    basis = basis or inspect(*refs)['basis']
    return state('assess', '--basis', basis, '--judgment', json.dumps(value), ok=ok, actor=actor)


state('enroll')
(home / 'data/evidence').write_text('Observed checks, not acceptance.\n')
judgment = dict(disposition='open', outcome='Checks reviewed', remaining_gap='Complete required behavior',
                authority_ref='data/task/brief.md', evidence=['data/evidence'])
result = assess(judgment)
assert 'coordination' not in result and result['disposition'] == 'open'
assert assess(judgment)['revision'] == result['revision']
snapshot = inspect('data/evidence', judgment['authority_ref'])
(home / 'data/evidence').write_text('Changed after MAIN inspected.\n')
assess(judgment, basis=snapshot['basis'], ok=False)
snapshot = inspect('data/evidence', judgment['authority_ref'])
assess(dict(judgment, outcome='Concurrent assessment'))
assess(judgment, basis=snapshot['basis'], ok=False)
assess(judgment, actor='branch', ok=False)
assess(dict(judgment, disposition='accepted'), ok=False)
assess(dict(judgment, intent_changed=True), ok=False)
assess(dict(judgment, attempts=0), ok=False)

# Authentic session capture and route are the only automatic intent source.
session = home / 'session.jsonl'
entries = [dict(type='session', version=3, id='isolated-session')]


def entry(data):
    item = dict(type='custom', customType='fm-continuation-input', id='e' + str(len(entries)),
                parentId=entries[-1]['id'] if len(entries) > 1 else None, data=data)
    entries.append(item)
    session.write_text(''.join(json.dumps(e) + '\n' for e in entries))
    return item['id']


def routed(name, text, task='task'):
    entry(dict(id=name, text=text))
    return entry(dict(id=name, text=text, task=task, update_brief=True, pending=True))


def update(name, receipt, ok=True):
    return state('update-brief', '--session-file', str(session), '--entry-id', receipt, '--input', name, ok=ok)


r1 = routed('request1', 'Additional acceptance condition one.')
update('request1', 'unread', ok=False)
wrong = routed('other-task', 'Other task words', 'another')
update('other-task', wrong, ok=False)
untrusted = entry(dict(id='injected', text='Not captured', task='task', update_brief=True))
update('injected', untrusted, ok=False)
prior = brief.read_text()
brief.write_text(prior + '\nUnexplained manual edit\n')
update('request1', r1, ok=False)
call('fm-send.sh', 'task', 'must refuse changed intent', ok=False)
brief.write_text(prior)
r = update('request1', r1)
assert r['goal_revision'] == 2 and 'request1' in r['assessment']['remaining_gap']
assert brief.read_text().count('Additional acceptance condition one.') == 1
assert update('request1', r1)['revision'] == r['revision']
r2 = routed('request2', 'Additional acceptance condition two.')
# Interrupt after the canonical transaction receipt, before brief replacement.
# Inject only the OS replacement failure; replay uses the unchanged public CLI.
fault = home / 'fault'
fault.mkdir()
(fault / 'sitecustomize.py').write_text('''import os
original = os.replace
def fail_brief(source, target):
    if str(target).endswith('/brief.md'):
        raise OSError('injected brief replace failure')
    return original(source, target)
os.replace = fail_brief
''')
env['PYTHONPATH'] = str(fault)
update('request2', r2, ok=False)
env.pop('PYTHONPATH')
r = update('request2', r2)
assert all(name in r['assessment']['remaining_gap'] for name in ('request1', 'request2'))
assert brief.read_text().count('Additional acceptance condition two.') == 1
assert r['goal_revision'] == 3 and r['disposition'] == 'open'
# The original operator path now sends normally after the supported update.
call('fm-send.sh', 'task', 'Proceed with the exact added conditions.')

# No caller-built action identity, hashes, attempts, or receipt JSON.
payload = home / 'data/payload'
payload.write_text('Execute the exact authorized operation.')
action = dict(kind='steer', payload_ref='data/payload', recheck_at='2026-01-01T00:00:00Z', deadline='2099-01-01T00:00:00Z')
r = assess(dict(judgment, next_action=action))
action_id = r['next_action']['id']
call('fm-send.sh', 'task', '--action-id', action_id, '--expected-generation', 'g1', payload.read_text())
assert state('lifecycle')['next_action']['phase'] == 'attempted'
assert state('refresh')['next_action']['phase'] == 'attempted'
forge = home / 'forge'
forge.mkdir()
for name in ('gh', 'gh-axi'):
    program = forge / name
    program.write_text('#!/bin/sh\necho unexpected-forge-access >&2\nexit 97\n')
    program.chmod(0o755)
env['PATH'] = str(forge) + os.pathsep + env['PATH']
refused = call('fm-pr-merge.sh', 'task', 'https://github.com/fixture/repo/pull/7', ok=False)
assert 'outstanding lifecycle effect' in refused.stderr and 'unexpected-forge-access' not in refused.stderr, refused.stderr
refused = call('fm-merge-local.sh', 'task', ok=False)
assert 'outstanding lifecycle effect' in refused.stderr, refused.stderr
assess(dict(judgment, next_action=None), ok=False)
r3 = routed('request3', 'Cannot overwrite an uncertain action.')
update('request3', r3, ok=False)
inbox = home / 'state/task.inbox'
(inbox / 'handled').mkdir(exist_ok=True)
for path in inbox.glob('*.msg'):
    path.rename(inbox / 'handled' / path.name)
r = state('refresh')
assert r['next_action']['phase'] == 'confirmed' and r['disposition'] == 'open'
assert Path(r['next_action']['receipt_ref']).is_file()
assert state('refresh')['revision'] == r['revision']
(home / 'state/provider').write_text('state: done · source: provider-success\n')
assert state('observe')['state'] == 'pending' and state('refresh')['disposition'] == 'open'
old_meta = meta.read_text()
meta.write_text(old_meta.replace('spawn_gen=g1', 'spawn_gen=g2'))
assess(judgment, ok=False)
state('refresh', ok=False)
meta.write_text(old_meta)

# Failure from the actual enqueue owner survives lease-release bookkeeping.
assess(dict(judgment, next_action=None))
shutil.rmtree(inbox)
inbox.write_text('not an inbox directory')
failed = call('fm-send.sh', 'task', 'must fail to enqueue', ok=False)
assert 'could not be written' in failed.stderr
inbox.unlink()

# v2 upgrade remains an explicit legacy operation; ordinary revocation and
# assessment use semantic input. A live delegation never silently gains intent.
(home / 'data/delegation').write_text('MAIN delegates receipt observation only.')
record = state('lifecycle')
record['schema'] = 'fm-task-lifecycle.v2'
record['delegation'] = dict(revision=1, issuer='main', authority_ref='data/delegation',
    authority_sha256=hashlib.sha256((home / 'data/delegation').read_bytes()).hexdigest(),
    allowed=['inspect', 'observe-receipt'], edges=[], expires_at='2099-01-01T00:00:00Z', revoked=False)
record['precheck'] = None
proposal = home / 'data/upgrade.json'
proposal.write_text(json.dumps(record)); proposal.chmod(0o600)
state('reconcile', '--expected-revision', str(record['revision']), '--record', str(proposal))
update('request3', r3, ok=False)
assess(dict(judgment, revoke_delegation=True))
update('request3', r3)
assert state('lifecycle')['delegation']['revoked'] is True

# The canonical merge/cleanup hooks derive fact hashes without changing judgment.
def owner(kind, facts, generation='g1', ok=True):
    proc = subprocess.run(['bash', '-c', '. "$1"; . "$2"; fm_task_lifecycle_owner_receipt task "$3" "$4" "$5"',
                           '_', str(bin_dir / 'fm-wake-lib.sh'), str(bin_dir / 'fm-task-lifecycle-lib.sh'),
                           generation, kind, json.dumps(facts)], env=env, text=True, capture_output=True)
    assert (proc.returncode == 0) == ok, proc.stderr


facts = dict(url='https://example.invalid/project/pull/1', head='a' * 40)
owner('merge', facts, generation='stale', ok=False)
owner('merge', facts)
r = state('lifecycle')
owner('merge', facts)
assert state('lifecycle')['revision'] == r['revision'] and r['disposition'] == 'open'
owner('merge', dict(facts, head='b' * 40), ok=False)
owner('merge', dict(facts, url='https://example.invalid/project/pull/2', head='b' * 40))
assert len(state('lifecycle')['owner_receipts']['merge']) == 2
assert inspect()['owner_receipts']['merge']['facts']['head'] == 'b' * 40
cleanup = dict(taskRecordRemoved=True, endpointConfirmedGone=True,
               copyDisposition='returned-or-already-absent', bookkeepingComplete=True)
owner('cleanup', cleanup, ok=False)
meta.unlink()
owner('cleanup', cleanup)
assert state('lifecycle')['owner_receipts']['cleanup'][-1]['facts'] == cleanup
assert state('lifecycle')['disposition'] == 'open'
assess(dict(judgment, disposition='accepted', outcome='All requested conditions verified', remaining_gap=''))
assert state('observe')['state'] == 'accepted'

# The other supported landing owner records the exact local commit too.
project = home / 'project'
project.mkdir()
def git(*args):
    result = subprocess.run(['git', '-C', str(project), '-c', 'user.name=Fixture',
        '-c', 'user.email=fixture@example.invalid', *args], env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()
git('init', '-b', 'main')
git('commit', '--allow-empty', '-m', 'base')
git('checkout', '-b', 'fm/local')
git('commit', '--allow-empty', '-m', 'authorized local change')
head = git('rev-parse', 'HEAD')
git('checkout', 'main')
(home / 'data/local').mkdir()
(home / 'data/local/brief.md').write_text('Land the authorized local branch; retain semantic verification.')
(home / 'state/local.meta').write_text(f'spawn_gen=local-g1\nmode=local-only\nkind=ship\nproject={project}\n')
call('fm-task-state.sh', 'enroll', 'local')
call('fm-merge-local.sh', 'local')
local = call('fm-task-state.sh', 'lifecycle', 'local')
assert local['owner_receipts']['merge'][-1]['facts']['head'] == head and local['disposition'] == 'open'
print('ok - semantic lifecycle: exact-byte CAS, authenticated intent, multiple obligations, owner receipts, failed delivery, and explicit acceptance')
