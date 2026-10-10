#!/usr/bin/env bash
# Owner-boundary admission tests: fake tmux/treehouse, isolated fixture Git and
# a real task-private markdown backlog. No agent or real backend is started.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-workforce-admission)
export FM_HOME="$TMP_ROOT/home"
fm_test_spawn_home "$FM_HOME" codex
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_fake_sleep_noop "$fakebin"
fm_git_worktree "$FM_HOME/projects/demo" "$TMP_ROOT/wt-one" fixture-one
git -C "$FM_HOME/projects/demo" worktree add --quiet -b fixture-two "$TMP_ROOT/wt-two"
printf '%s\n' '- demo [direct-PR] - fixture (added 2026-10-04)' > "$FM_HOME/data/projects.md"
printf '%s\n' 'backend = "markdown"' '[markdown]' 'path = "data/backlog.md"' > "$FM_HOME/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
for task in one two failure prepared pending; do
  fm_test_spawn_brief "$FM_HOME" "$task"
  (cd "$FM_HOME" && tasks-axi add "$task" "fixture $task" --kind ship --file "$FM_HOME/data/backlog.md" >/dev/null)
done
export ADMISSION_ROOT="$ROOT" ADMISSION_FAKEBIN="$fakebin" ADMISSION_TMP="$TMP_ROOT"
python3 - <<'PY'
import json, os, pathlib, subprocess, shutil
home = pathlib.Path(os.environ['FM_HOME'])
root = pathlib.Path(os.environ['ADMISSION_ROOT'])
bin = root/'bin'
tmp = pathlib.Path(os.environ['ADMISSION_TMP'])
fake = pathlib.Path(os.environ['ADMISSION_FAKEBIN'])
# Add a synthetic foreground shell observation to the shared endpoint fake.
(fake/'tmux').write_text((fake/'tmux').read_text().replace('set -u\n',
    'set -u\ncase "$*" in *"#{pane_current_command}"*) echo bash; exit 0 ;; esac\n',1))
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') and key != 'FM_HOME':
        env.pop(key)
env.update(FM_SPAWN_NO_GUARD='1', FM_BACKEND='tmux', HOME=str(home/'user-home'),
           PATH=str(fake)+':'+env['PATH'], TMUX='fake,1,0')
(home/'user-home').mkdir()

def run(name, *args, value=None, ok=True, extra=None):
    e = dict(env, **(extra or {}))
    command = ['python3' if name.endswith('.py') else 'bash', str(bin/name), *args]
    p = subprocess.run(command, input=json.dumps(value) if value else '', env=e, text=True, capture_output=True)
    assert (p.returncode == 0) == ok, (command, p.returncode, p.stdout, p.stderr)
    return p

def submit(rid):
    r = dict(schema='fm-workforce-request.v1', request_id=rid, action='job-request',
             scope=dict(project='demo'), payload=dict(kind='ship', text='identical instructions',
             posture='assistant', delivery_mode='direct-PR', merge_autonomy=False))
    return json.loads(run('fm-workforce.py', 'submit', value=r).stdout)['id'], r

def receipts():
    return json.loads(run('fm-workforce.py', 'receipts', '--all-pending', '--all-handled').stdout)

def note(rid):
    return next(n for n in receipts()['pending']+receipts()['handled'] if n['request_id']=='workforce:'+rid)

def fields(task):
    return dict(line.split('=', 1) for line in (home/'state'/f'{task}.meta').read_text().splitlines() if '=' in line)

def replace(task, values):
    (home/'state'/f'{task}.meta').write_text(''.join(k+'='+v+'\n' for k,v in values.items()))

from concurrent.futures import ThreadPoolExecutor
with ThreadPoolExecutor(max_workers=2) as pool:
    (n1, req), (n2, _) = list(pool.map(submit, ['origin-one','origin-two']))
assert n1 != n2
assert note('origin-one')['execution']['state'] == 'pending'
run('fm-workforce.py', 'answer', n1, value=dict(decision='approved', reason='intake', scope=req['scope']))
assert note('origin-one')['admission'] is None
changed = dict(req, payload=dict(req['payload'], text='different'))
run('fm-workforce.py', 'submit', value=changed, ok=False)
# Real spawn owner, synthetic endpoint/worktree allocation and launch delivery.
for task, noteid, wt in [('one',n1,'wt-one'),('two',n2,'wt-two')]:
    run('fm-spawn.sh', task, str(home/'projects/demo'), '--mode', 'direct-PR', '--yolo', 'off',
        '--origin-note', noteid, extra=dict(FM_FAKE_PANE_PATH=str(tmp/wt)))
    observed = note('origin-'+task)
    binding = observed['admission']
    assert binding['task_id']==task and binding['note_id']==noteid and binding['project']=='demo'
    assert binding['admitted_generation']==fields(task)['spawn_gen']
    assert observed['execution']['state']=='admitted', observed
    assert observed['execution']['current']['worktree']['path']==str(tmp/wt)
    assert fields(task)['mode']=='direct-PR' and fields(task)['yolo']=='off'
original = note('origin-one')['admission']
run('fm-spawn.sh', '--recover-admission', 'one')
assert note('origin-one')['admission']==original
run('fm-inbox.sh','drain','--ack',n1)
assert note('origin-one')['admission']==original
run('fm-inbox.sh','prepare-admission',n1,'another',str(home/'projects/demo'),'ship',ok=False)
# Provisional metadata cannot be promoted by backlog-only recovery.
np, _ = submit('origin-prepared')
run('fm-inbox.sh','prepare-admission',np,'prepared',str(home/'projects/demo'),'ship')
origin = json.loads(run('fm_inbox_admission.py','origin',np,'prepared','s-provisional').stdout)
provisional = dict(fields('one'), endpoint_task_id='prepared', spawn_gen='s-provisional', admission_origin=json.dumps(origin))
for key in ('admission_committed_at','admission_committed_generation'):
    provisional.pop(key)
replace('prepared',provisional)
run('fm-inbox.sh','publish-admission','prepared',ok=False)
assert note('origin-prepared')['admission_state']=='prepared'
run('fm-inbox.sh','prepare-admission',np,'prepared',str(home/'projects/demo'),'ship',ok=False)
# Crash after final metadata marker, before inbox publication. Remove only the
# synthetic attachment to reconstruct that boundary and replay without launch.
npath = home/'state/inbox/handled'/f'{n1}.note'
raw = npath.read_text()
npath.write_text('\n'.join(line for line in raw.split('\n') if not line.startswith(('admission=','admission_cursor='))))
assert note('origin-one')['execution']['state']=='pending'
log = tmp/'recovery-launch.log'
run('fm-spawn.sh','--recover-admission','one',extra=dict(FM_FAKE_LAUNCH_LOG=str(log)))
assert not log.exists() and note('origin-one')['admission']==original
# Relauch uses the existing owner path, preserves unowned origin fields, and
# emits a new generation. The fake process observation proves agent absence.
run('fm-spawn.sh','one','--relaunch',extra=dict(FM_FAKE_PANE_PATH=str(tmp/'wt-one'),FM_FAKE_DUPLICATE_WINDOW='fm-one'))
assert note('origin-one')['admission']==original
assert note('origin-one')['execution']['state']=='generation-changed'
# Wrong original generation, home, kind, note and duplicate origins fail closed.
valid = fields('one')
for key, value in [('admission_committed_generation','wrong'), ('project',str(tmp/'wrong')),
                   ('kind','secondmate'),('remote_host','remote')]:
    replace('one', dict(valid, **{key:value}))
    run('fm-spawn.sh','--recover-admission','one',ok=False)
replace('one',valid)
for key, value in [('home',str(tmp/'other')),('note_id',n2),('task_id','two'),('kind','scout')]:
    bad = dict(json.loads(valid['admission_origin']), **{key:value})
    replace('one',dict(valid,admission_origin=json.dumps(bad)))
    run('fm-spawn.sh','--recover-admission','one',ok=False)
replace('one',valid)
replace('duplicate',valid)
run('fm-spawn.sh','--recover-admission','one',ok=False)
(home/'state/duplicate.meta').unlink()
# Refuse fresh admission through incompatible intake shapes before allocation.
for args in [('one','--relaunch','--origin-note',n1),
             ('one',str(home/'projects/demo'),'--secondmate','--origin-note',n1),
             ('one',str(home/'projects/demo'),'--origin-note=')]:
    run('fm-spawn.sh',*args,'--mode','direct-PR','--yolo','off',ok=False)
run('fm-inbox.sh','prepare-admission',n2,'other',str(tmp/'wrong'),'ship',ok=False)
run('fm-inbox.sh','prepare-admission',n2,'other',str(home/'projects/demo'),'scout',ok=False)
# Inject inbox owner publication failure after final spawn commitment. No
# lifecycle is retried: the recovery command only fills the missing attachment.
npend, _ = submit('origin-pending')
real_python = subprocess.check_output(['bash','-c','command -v python3'],text=True).strip()
(fake/'python3').write_text('#!/usr/bin/env bash\ncase "$1:$2" in */fm_inbox_admission.py:publish) exit 1 ;; esac\nexec '+real_python+' "$@"\n')
(fake/'python3').chmod(0o755)
failed = run('fm-spawn.sh','pending',str(home/'projects/demo'),'--mode','direct-PR','--yolo','off',
    '--origin-note',npend,ok=False,extra=dict(FM_FAKE_PANE_PATH=str(tmp/'wt-two')))
assert 'spawned-but-binding-pending' in failed.stderr, (failed.stdout,failed.stderr)
assert fields('pending')['admission_committed_at']
(fake/'python3').unlink()
assert note('origin-pending')['admission'] is None
run('fm-spawn.sh','--recover-admission','pending',extra=dict(FM_FAKE_LAUNCH_LOG=str(log)))
assert note('origin-pending')['admission']['task_id']=='pending' and not log.exists()
# A lost sequence counter must not put a later admission behind earlier ones.
(home/'state/inbox/.replies/.seq').unlink()
run('fm-spawn.sh','--recover-admission','pending')
assert int((home/'state/inbox/.replies/.seq').read_text()) > int(note('origin-pending')['admission_cursor'])
# Failed backlog commit never writes an admission marker or attachment.
nf, _ = submit('origin-failure')
real_tasks = subprocess.check_output(['bash','-c','command -v tasks-axi'],text=True).strip()
(fake/'tasks-axi').write_text('#!/usr/bin/env bash\n[ "$1" != start ] || exit 1\nexec '+real_tasks+' "$@"\n')
(fake/'tasks-axi').chmod(0o755)
run('fm-spawn.sh','failure',str(home/'projects/demo'),'--mode','direct-PR','--yolo','off',
    '--origin-note',nf,ok=False,extra=dict(FM_FAKE_PANE_PATH=str(tmp/'wt-two')))
assert note('origin-failure')['admission'] is None
assert not (home/'state/failure.meta').exists()
(fake/'tasks-axi').unlink()
# Retiring metadata does not delete the original inbox relation.
(home/'state/one.meta').unlink()
assert note('origin-one')['admission']==original
assert note('origin-one')['execution']['state']=='retired'
# Missing, omitted, and unavailable snapshot evidence is explicitly unknown.
# Intercept only the canonical fleet owner's executable boundary, with fixture
# JSON. All bridge receipt handling still runs through its public CLI.
real_bash = shutil.which('bash')
(fake/'bash').write_text('#!'+real_bash+'\n'
    'case "$1" in */fm-fleet-snapshot.sh) [ "$ADMISSION_FLEET_FIXTURE" != unavailable ] || exit 1; '
    'cat "$ADMISSION_FLEET_FIXTURE"; exit 0 ;; esac\nexec '+real_bash+' "$@"\n')
(fake/'bash').chmod(0o755)
fleet_file=tmp/'fleet.json'
for fleet in [{},dict(schema='fm-fleet-snapshot.v1',fm_home=str(home),tasks=[],task_inventory_complete=True,omitted=['tasks'])]:
    fleet_file.write_text(json.dumps(fleet))
    result=json.loads(run('fm-workforce.py','receipts','--all-handled',
        extra=dict(ADMISSION_FLEET_FIXTURE=str(fleet_file))).stdout)
    assert next(n for n in result['handled'] if n['id']==n1)['execution']['state']=='unknown'
result=json.loads(run('fm-workforce.py','receipts','--all-handled',
    extra=dict(ADMISSION_FLEET_FIXTURE='unavailable')).stdout)
assert next(n for n in result['handled'] if n['id']==n1)['execution']['state']=='unknown'
(fake/'bash').unlink()
print('PASS: exact admission, answer-only, spawn/relaunch custody, crash replay, conflicts and retirement')
PY
pass 'Workforce authoritative admission owner boundaries'
