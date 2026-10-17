#!/usr/bin/env bash
# Typed Workforce intake through the public CLI in a task-private fake home.
# No endpoint or lifecycle command is invoked; all requests remain supervisor notes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-workforce)
export FM_HOME="$TMP_ROOT/home"
bash "$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
export WORKFORCE_BIN="$ROOT/bin/fm-workforce.py"
python3 - <<'PY'
import json, os, pathlib, subprocess
home = pathlib.Path(os.environ['FM_HOME'])
cli = os.environ['WORKFORCE_BIN']
os.environ['FM_STATE_OVERRIDE'] = str(home/'foreign-state')
os.environ['TASKS_AXI_FILE'] = str(home/'foreign-backlog.md')
(home/'data/projects.md').write_text('- demo [direct-PR] - fixture (added 2026-10-03)\n')
worktree = home/'projects/demo'
worktree.mkdir()
def git(*args):
    return subprocess.check_output(['git', '-C', str(worktree), *args], text=True).strip()
git('init', '-b', 'fm/batch')
git('config', 'user.name', 'Test')
git('config', 'user.email', 'test@example.invalid')
(worktree/'file').write_text('one')
git('add', 'file'); git('commit', '-m', 'fixture')
head = git('rev-parse', 'HEAD')
metadata = f'project={worktree}\nspawn_gen=gen-1\nkind=ship\nharness=codex\nbackend=herdr\nbranch=fm/batch\nworktree={worktree}\nmode=direct-PR\nyolo=off\n'
if os.environ.get('FM_WORKFORCE_LAB_SESSION'):
    metadata += 'herdr_session=' + os.environ['FM_WORKFORCE_LAB_SESSION'] + '\n'
(home/'state/job.meta').write_text(metadata)
def call(command, value=None, success=True):
    result = subprocess.run(['python3', cli, *command], input=json.dumps(value) if value else '',
                            text=True, capture_output=True)
    assert (result.returncode == 0) == success, (command, result.stdout, result.stderr)
    return json.loads(result.stdout)
def request(rid, action, scope, payload):
    return dict(schema='fm-workforce-request.v1', request_id=rid, action=action, scope=scope, payload=payload)
scope = dict(project='demo', job='job', batch=head, branch='fm/batch', head=head, generation='gen-1')
req = request('validate-1', 'validation-request', scope, dict(posture='assistant', delivery_mode='no-mistakes'))
# Batch identity is Git revision evidence, not an arbitrary completion label.
for i, batch in enumerate(['batch-v1', '0'*40]):
    mismatched = dict(req, request_id='wrong-batch-'+str(i), scope=dict(scope, batch=batch))
    assert 'batch does not identify' in call(['submit'], mismatched, False)['error']
    legacy = subprocess.run(['bash', str(pathlib.Path(cli).parent/'fm-inbox.sh'), 'note', '--json', '-'],
        input='Workforce request v1\n'+json.dumps(mismatched, separators=(',', ':'), sort_keys=True),
        text=True, capture_output=True, env={k:v for k,v in os.environ.items() if not k.startswith('FM_') or k == 'FM_HOME'})
    assert legacy.returncode == 0, legacy.stderr
    legacy_id = json.loads(legacy.stdout)['id']
    assert 'batch does not identify' in call(['answer', legacy_id],
        dict(decision='approved', reason='wrong batch', scope=mismatched['scope']), False)['error']
    subprocess.run(['bash', str(pathlib.Path(cli).parent/'fm-inbox.sh'), 'drain', '--ack', legacy_id],
        check=True, capture_output=True, env={k:v for k,v in os.environ.items() if not k.startswith('FM_') or k == 'FM_HOME'})
call(['submit'], dict(req, request_id='missing-generation', scope={k:v for k,v in scope.items() if k != 'generation'}), False)
call(['submit'], dict(req, request_id='old-generation', scope=dict(scope, generation='gen-0')), False)
first = call(['submit'], req)
assert first['outcome'] == 'created' and first['announced']
assert call(['submit'], req)['id'] == first['id']
changed = dict(req, scope=dict(scope, batch='different'))
assert 'identity' in call(['submit'], changed, False)['error']
assert len(list((home/'state/inbox').glob('*.note'))) == 1
assert 'inbox:' in (home/'state/.wake-queue').read_text()
assert 'Workforce request v1' in (home/'state/inbox'/f"{first['id']}.note").read_text()
wrong = dict(decision='approved', reason='reviewed', scope=dict(scope, head='0'*40))
call(['answer', first['id']], wrong, False)
answer = dict(decision='approved', reason='exact batch reviewed', scope=scope)
(home/'state/job.meta').write_text(metadata.replace('spawn_gen=gen-1', 'spawn_gen=gen-2'))
assert 'stale job generation' in call(['answer', first['id']], answer, False)['error']
assert call(['submit'], req)['id'] == first['id']
(home/'state/job.meta').write_text(metadata)
call(['answer', first['id']], answer)
receipts = call(['receipts', '--all-replies'])
assert len(receipts['replies']) == 1
assert 'fm-workforce-answer.v1' in json.dumps(receipts)
# A new process reads the same request and reply after acknowledgement.
subprocess.run(['bash', str(pathlib.Path(cli).parent/'fm-inbox.sh'), 'drain', '--ack', first['id']], check=True, capture_output=True, env={k:v for k,v in os.environ.items() if not k.startswith('FM_') or k == 'FM_HOME'})
assert call(['submit'], req)['acknowledged'], call(['submit'], req)
second = call(['submit'], dict(req, request_id='validate-2'))
interrupted = dict(req, request_id='interrupted')
reserved = call(['submit'], interrupted)
published = home/'state/inbox'/f"{reserved['id']}.note"
staged = home/'state/inbox'/('.staging-' + reserved['id'].partition('-')[2])
published.rename(staged)
unrelated_staging = home/'state/inbox/.staging-unrelated'
unrelated_staging.write_text('unrelated owned elsewhere')
assert 'identity' in call(['submit'], dict(interrupted, scope=dict(scope, batch='different')), False)['error']
assert not published.exists() and staged.exists()
(worktree/'file').write_text('two'); git('add', 'file'); git('commit', '-m', 'advance')
assert 'stale head' in call(['answer', second['id']], answer, False)['error']
recovered = call(['submit'], interrupted)
assert recovered['id'] == reserved['id'] and recovered['outcome'] == 'replay'
assert not staged.exists()
assert unrelated_staging.read_text() == 'unrelated owned elsewhere'
assert json.loads(published.read_text().split('Workforce request v1\n', 1)[1]) == interrupted
assert call(['submit'], interrupted)['id'] == reserved['id']
assert 'identity' in call(['submit'], dict(interrupted, scope=dict(scope, batch='different')), False)['error']
missing = dict(req, request_id='missing-staged')
(home/'state/inbox/.requests/workforce:missing-staged').write_text('123456-missing\n')
assert 'staged content unavailable' in call(['submit'], missing, False)['error']
assert not (home/'state/inbox/123456-missing.note').exists()
call(['submit'], dict(req, request_id='stale'), False)
# Identity replay remains possible after work advances, never approves new head.
assert call(['submit'], req)['outcome'] == 'replay'
new_scope = dict(scope, head=git('rev-parse', 'HEAD'), batch=git('rev-parse', 'HEAD'))
(home/'state/job.meta').write_text(metadata.replace('mode=direct-PR', 'mode=local-only'))
call(['submit'], dict(req, request_id='local', scope=new_scope), False)
(home/'state/job.meta').write_text(metadata)
for verb in ['interrupt', 'exit', 'send-instruction', 'relaunch']:
    payload = dict(verb=verb)
    if verb in ['send-instruction', 'relaunch']: payload['text'] = 'checkpoint'
    call(['submit'], request('window-'+verb, 'window-request', dict(project='demo', job='job', generation='gen-1'), payload))
for verb in ['open', 'focus', 'teardown']:
    call(['submit'], request('bad-'+verb, 'window-request', dict(project='demo', job='job', generation='gen-1'), dict(verb=verb)), False)
(home/'state/job.meta').write_text(metadata.replace('backend=herdr', 'backend=orca'))
call(['submit'], request('orca', 'window-request', dict(project='demo', job='job', generation='gen-1'), dict(verb='exit')), False)
(home/'state/job.meta').write_text(metadata+'remote_host=elsewhere\n')
call(['submit'], request('remote', 'window-request', dict(project='demo', job='job', generation='gen-1'), dict(verb='exit')), False)
(home/'state/job.meta').write_text(metadata)
policy = request('policy', 'policy-request', dict(project='demo'), dict(posture='autonomy', delivery_mode='local-only', merge_autonomy=True))
call(['submit'], policy)
for level, target in [('global', {}), ('project', {'project':'demo'}), ('job', {'project':'demo','job':'job','generation':'gen-1'})]:
    defaults_scope = dict(level=level, **target)
    valid_defaults = request('defaults-'+level, 'defaults-request', defaults_scope, dict(harness='codex', effort='high'))
    valid_note = call(['submit'], valid_defaults)
    call(['answer', valid_note['id']], dict(decision='approved', reason='supported effort', scope=defaults_scope))
    invalid_defaults = request('ultra-'+level, 'defaults-request', defaults_scope, dict(harness='codex', effort='ultra'))
    assert 'ultra effort requires' in call(['submit'], invalid_defaults, False)['error']
    legacy = subprocess.run(['bash', str(pathlib.Path(cli).parent/'fm-inbox.sh'), 'note',
                             '--request-id', 'workforce:'+invalid_defaults['request_id'], '--json', '-'],
                            input='Workforce request v1\n'+json.dumps(invalid_defaults, separators=(',', ':'), sort_keys=True),
                            text=True, capture_output=True, env={k:v for k,v in os.environ.items() if not k.startswith('FM_') or k == 'FM_HOME'})
    assert legacy.returncode == 0, legacy.stderr
    legacy_note = json.loads(legacy.stdout)
    assert call(['submit'], invalid_defaults)['id'] == legacy_note['id']
    assert 'ultra effort requires' in call(['answer', legacy_note['id']],
        dict(decision='approved', reason='unsupported effort', scope=defaults_scope), False)['error']
    call(['answer', legacy_note['id']], dict(decision='declined', reason='unsupported effort', scope=defaults_scope))
for i, preferences in enumerate([dict(effort='ultra'), dict(harness='pi', effort='ultra'),
        dict(harness='pi-signed', effort='ultra'), dict(harness='pi', model='other', effort='ultra'),
        dict(harness='pi-signed', model='codex-native/', effort='ultra')]):
    assert 'ultra effort requires' in call(['submit'], request('unsupported-ultra-'+str(i),
        'defaults-request', dict(level='global'), preferences), False)['error']
for harness in ['pi', 'pi-signed']:
    native = subprocess.run(['bash', str(pathlib.Path(cli).parent/'fm-harness.sh'),
                             'validate-native-effort', harness, 'codex-native/example', 'ultra'],
                            text=True, capture_output=True)
    assert native.returncode == 0, native.stderr
call(['submit'], request('unknown-model', 'defaults-request', dict(level='global'), dict(harness='unsupported', model='assumed')), False)
call(['submit'], dict(policy, request_id='injection', payload=dict(policy['payload'], executable='/bin/sh')), False)
call(['submit'], dict(policy, request_id='other-home', home='/tmp'), False)
call(['submit'], dict(policy, request_id='unregistered', scope=dict(project='absent')), False)
assert (home/'state/job.meta').read_text() == metadata
assert '+yolo' not in (home/'data/projects.md').read_text()
assert not (home/'data/backlog.md').exists()
call(['submit'], request('stale-generation', 'window-request', dict(project='demo', job='job', generation='gen-0'), dict(verb='exit')), False)
row_view = call(['status'])
assert row_view['windows'][0]['generation'] == 'gen-1'
assert row_view['windows'][0]['verbs']['exit']['request_supported']
assert not row_view['windows'][0]['verbs']['open']['request_supported']
assert not row_view['windows'][0]['verbs']['exit']['direct_execution']
assert row_view['preferences']['jobs'][0]['profile_observation'] == 'same-generation'
for verb, capability in row_view['windows'][0]['verbs'].items():
    payload = dict(verb=verb)
    if verb in {'send-instruction', 'relaunch'}:
        payload['text'] = 'bounded instruction'
    call(['submit'], request('advertised-'+verb, 'window-request',
        dict(project=row_view['windows'][0]['project'], job='job', generation='gen-1'), payload),
        capability['request_supported'])
invalid_rows = [
    metadata.replace('project='+str(worktree), 'project='+str(home/'secondmates/demo'))
            .replace('kind=ship', 'kind=secondmate').replace('harness=codex', 'harness=pi')
            .replace('mode=direct-PR', 'mode=secondmate'),
    metadata.replace('project='+str(worktree), 'project='+str(home/'secondmates/unregistered'))
            .replace('kind=ship', 'kind=secondmate').replace('harness=codex', 'harness=pi')
            .replace('mode=direct-PR', 'mode=secondmate'),
    metadata.replace('project='+str(worktree), 'project='+str(home/'outside/demo')),
    metadata.replace('spawn_gen=gen-1\n', ''),
    metadata.replace('spawn_gen=gen-1', 'spawn_gen=invalid/generation'),
    metadata+'remote_host=elsewhere\n',
]
for i, invalid_metadata in enumerate(invalid_rows):
    (home/'state/job.meta').write_text(invalid_metadata)
    window = call(['status'])['windows'][0]
    assert all(not capability['request_supported'] and capability['reason']
               for capability in window['verbs'].values()), window
    for verb in ['send-instruction', 'interrupt', 'exit', 'relaunch']:
        payload = dict(verb=verb)
        if verb in {'send-instruction', 'relaunch'}:
            payload['text'] = 'bounded instruction'
        call(['submit'], request('unaddressable-'+str(i)+'-'+verb, 'window-request',
            dict(project=window['project'], job=window['job'], generation=window['generation']), payload), False)
(home/'state/job.meta').write_text(metadata)
assert call(['status'])['windows'][0]['verbs']['exit']['request_supported']
(home/'state/job.meta').unlink()
(home/'config/backend').write_text('orca\n')
view = call(['status'])
assert view['backends']['configured'] == 'orca'
assert view['backends']['configuration_valid']
assert view['schema'] == 'fm-workforce-status.v1'
assert view['projects'][0]['effective'] == 'direct-PR off'
assert view['preferences']['precedence'] == ['global','project','explicit-job']
assert view['preferences']['revision']
assert view['readiness']['schema'] == 'fm-primary-ready.v1'
assert view['fleet']['tasks'] == []
job = request('new-worker', 'job-request', dict(project='demo'),
    dict(kind='ship', text='bounded job', posture='assistant', delivery_mode='local-only',
         merge_autonomy=False, preferences=dict(harness='codex', effort='high'),
         preference_revision=view['preferences']['revision']))
new_worker_note = call(['submit'], job)
call(['answer', new_worker_note['id']], dict(decision='approved', reason='supported worker preferences', scope=job['scope']))
invalid_worker = dict(job, request_id='ultra-worker', payload=dict(job['payload'], preferences=dict(harness='codex', effort='ultra')))
assert 'ultra effort requires' in call(['submit'], invalid_worker, False)['error']
legacy_worker = subprocess.run(['bash', str(pathlib.Path(cli).parent/'fm-inbox.sh'), 'note', '--json', '-'],
    input='Workforce request v1\n'+json.dumps(invalid_worker, separators=(',', ':'), sort_keys=True),
    text=True, capture_output=True, env={k:v for k,v in os.environ.items() if not k.startswith('FM_') or k == 'FM_HOME'})
assert legacy_worker.returncode == 0, legacy_worker.stderr
legacy_worker_id = json.loads(legacy_worker.stdout)['id']
assert 'ultra effort requires' in call(['answer', legacy_worker_id],
    dict(decision='approved', reason='unsupported worker preferences', scope=job['scope']), False)['error']
call(['answer', legacy_worker_id], dict(decision='refused', reason='unsupported worker preferences', scope=job['scope']))
call(['submit'], dict(job, request_id='missing-snapshot', payload={k:v for k,v in job['payload'].items() if k != 'preference_revision'}), False)
assert not (home/'config/crew-harness').exists()
inherited = view['preferences']
assert inherited['global']['harness']['value'] is None
assert 'unresolved' in inherited['global']['harness']['source']
os.environ['FM_SUPERVISION_ACTOR'] = 'branch'
os.environ['FM_SUPERVISION_PRIMARY_HARNESS'] = 'pi'
assert call(['status'])['preferences']['revision'] == inherited['revision']
os.environ['CLAUDECODE'] = '1'
assert call(['status'])['preferences']['revision'] == inherited['revision']
for setting in ['default\n', ' \n']:
    (home/'config/crew-harness').write_text(setting)
    assert call(['status'])['preferences']['revision'] == inherited['revision']
(home/'config/crew-harness').write_text('codex\n')
explicit = call(['status'])['preferences']
assert explicit['global']['harness'] == dict(value='codex', source='config/crew-harness')
assert explicit['revision'] != inherited['revision']
assert 'stale preference snapshot' in call(['submit'], dict(job, request_id='stale-preferences'), False)['error']
assert 'stale preference snapshot' in call(['answer', new_worker_note['id']],
    dict(decision='approved', reason='old defaults', scope=job['scope']), False)['error']
assert call(['submit'], job)['id'] == new_worker_note['id']
current_job = dict(job, request_id='current-preferences', payload=dict(job['payload'], preference_revision=explicit['revision']))
current_note = call(['submit'], current_job)
call(['answer', current_note['id']], dict(decision='approved', reason='current defaults', scope=job['scope']))
(home/'config/crew-harness').unlink()
dispatch_path = home/'config/crew-dispatch.json'
valid_profile = dict(harness='codex', model='catalog-model', effort='high', provider='openai')
for default in [valid_profile, [valid_profile, dict(harness='claude', effort='max')]]:
    dispatch_path.write_text(json.dumps(dict(default=default)))
    snapshot = call(['status'])['preferences']
    observed = snapshot['global']['dispatch_default']
    assert observed['configuration_valid'] and observed['value'] == default
    assert snapshot['revision'] != inherited['revision']
for default in [valid_profile, [valid_profile, dict(harness='claude', effort='max')]]:
    dispatch_path.write_text(json.dumps(dict(default=default)))
    before = call(['status'])['preferences']
    changed_profile = dict(valid_profile, provider='different-provider')
    changed_default = changed_profile if isinstance(default, dict) else [changed_profile, default[1]]
    dispatch_path.write_text(json.dumps(dict(default=changed_default)))
    after = call(['status'])['preferences']
    assert after['global']['dispatch_default']['value'] == changed_default
    assert before['revision'] != after['revision']
invalid_configs = [
    dict(default=dict(harness='codex', model=123, effort='high')),
    dict(default=dict(harness='codex', model='')),
    dict(default=dict(harness='')),
    dict(default=dict(harness='unsupported')),
    dict(default=dict(harness='codex', effort='')),
    dict(default=dict(harness='codex', effort='invented')),
    dict(default=dict(harness='codex', effort='max')),
    dict(default=dict(harness='opencode', effort='high')),
    dict(default=dict(harness='pi', model='other', effort='ultra')),
    dict(default=[]), dict(default=[valid_profile, valid_profile]),
    dict(default=[valid_profile, dict(harness='codex', model=None)]),
    dict(default=valid_profile, rules=[dict(when='match', use=dict(harness='unsupported'))]),
    [],
]
for config in invalid_configs:
    dispatch_path.write_text(json.dumps(config))
    snapshot = call(['status'])['preferences']
    observed = snapshot['global']['dispatch_default']
    assert not observed['configuration_valid'] and observed['value'] is None and observed['reason'], config
    assert snapshot['revision'] != inherited['revision']
dispatch_path.write_text('{malformed')
assert not call(['status'])['preferences']['global']['dispatch_default']['configuration_valid']
dispatch_path.unlink()
assert not (home/'foreign-state').exists()
assert not (home/'foreign-backlog.md').exists()
# A fixture catalog proves only explicit authoritative identities are accepted.
catalog = home/'catalog'; catalog.mkdir()
(catalog/'models_cache.json').write_text(json.dumps({'models':[{'slug':'catalog-model'}]}))
os.environ['CODEX_HOME'] = str(catalog)
call(['submit'], request('catalog-match', 'defaults-request', dict(level='global'), dict(harness='codex', model='catalog-model')))
call(['submit'], request('catalog-mismatch', 'defaults-request', dict(level='global'), dict(harness='codex', model='invented-model')), False)
print('PASS: durable deduplication, supervisor routing/replies, exact scope/head, stale rejection, independent authority, window refusals and prospective defaults')
PY
pass 'Workforce typed public interface'
