"""Retained-resource completion through real backlog/lifecycle public owners."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, home = map(Path, sys.argv[1:])
for folder in ('data', 'state', 'config'):
    (home / folder).mkdir(parents=True, exist_ok=True)
(home / '.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\n')
backlog = home / 'data/backlog.md'
backlog.write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root))
for key in ('FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
    env.pop(key, None)
cli = root / 'bin/fm-task-state.sh'
lib = root / 'bin/fm-task-lifecycle.py'
retire = root / 'bin/fm-task-retire.sh'


def run(*args, ok=True, custom_env=None):
    result = subprocess.run(list(map(str, args)), env=custom_env or env, cwd=home,
                            capture_output=True, text=True, check=False)
    assert (result.returncode == 0) == ok, result.stderr or result.stdout
    return result.stdout + (result.stderr if not ok else '')


def call(task, operation, *args):
    return json.loads(run(cli, operation, task, *args))


def state(task):
    return run('tasks-axi', 'show', task, '--file', backlog)


def setup(task, kind='scout'):
    folder = home / 'data' / task
    folder.mkdir()
    (folder / 'brief.md').write_text('Complete requested work\n')
    (folder / 'report.md').write_text('Preserved completed report\n')
    resource = folder / 'resource'
    resource.mkdir()
    (resource / 'unlanded.txt').write_text('Unlanded private content\n')
    (home / 'state' / f'{task}.meta').write_text(
        f'kind={kind}\nspawn_gen=g1\nbackend=herdr\nharness=codex\nworktree={resource}\n')
    run('tasks-axi', 'add', task, task, '--kind', kind, '--file', backlog)
    run('tasks-axi', 'start', task, '--file', backlog)
    call(task, 'enroll')
    if kind == 'scout':
        run(root / 'bin/fm-captain-hold.sh', 'complete', task, '--none')


def assess(task, disposition='accepted', authority=None, gap=''):
    refs = [f'data/{task}/report.md']
    authority = authority or f'data/{task}/brief.md'
    basis = call(task, 'inspect', '--evidence', refs[0], '--evidence', authority)['basis']
    return call(task, 'assess', '--basis', basis, '--judgment', json.dumps(dict(
        disposition=disposition, outcome='Completed report', remaining_gap=gap,
        authority_ref=authority, evidence=refs)))


def merge_receipt(task, url, head, generation='g1'):
    run(sys.executable, lib, 'owner-receipt', task, '--kind', 'merge',
        '--execution-generation', generation,
        '--facts', json.dumps(dict(url=url, head=head)))


def completion_refuses(task, message):
    before = (home / 'data' / task / 'lifecycle.json').read_bytes()
    output = run(sys.executable, lib, 'completion-read', task, ok=False)
    assert message in output and (home / 'data' / task / 'lifecycle.json').read_bytes() == before


def preserved(task):
    folder = home / 'data' / task
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in
            [folder / 'report.md', folder / 'resource/unlanded.txt', home / 'state' / f'{task}.meta']}


setup('unfinished')
before = preserved('unfinished')
run(retire, 'unfinished', '--complete-only', ok=False)
assert 'state: in_flight' in state('unfinished') and preserved('unfinished') == before
assert not (home / 'state/unfinished.cleanup.json').exists()

setup('unmerged', 'ship')
assess('unmerged')
before = preserved('unmerged')
output = run(retire, 'unmerged', '--complete-only', ok=False)
assert 'merge receipt' in output and 'state: in_flight' in state('unmerged')
assert preserved('unmerged') == before
print('ok - open goals and accepted but unmerged ships cannot be falsely closed')

# One guarded owner can retain more than one delivery from the same execution
# generation. Completion selects the exact current metadata identity rather than
# rejecting retained history or assuming that the newest receipt is current.
old_url = 'https://code.byted.org/fixture/firstmate/merge_requests/115'
current_url = 'https://code.byted.org/fixture/firstmate/merge_requests/116'
old_head, current_head = 'a' * 40, 'b' * 40
setup('multi-delivery', 'ship')
assess('multi-delivery')
merge_receipt('multi-delivery', current_url, current_head)
merge_receipt('multi-delivery', old_url, old_head)
with (home / 'state/multi-delivery.meta').open('a') as stream:
    stream.write(f'pr={current_url}\npr_head={current_head}\n')
record = home / 'data/multi-delivery/lifecycle.json'
before = record.read_bytes()
receipts = json.loads(before)['owner_receipts']['merge']
completion = json.loads(run(sys.executable, lib, 'completion-read', 'multi-delivery'))
assert completion['completion_delivery'] == receipts[0]
assert completion['owner_receipts']['merge'] == receipts
assert record.read_bytes() == before
multi_fakebin = home / 'multi-fakebin'
multi_fakebin.mkdir()
multi_wrapper = multi_fakebin / 'tasks-axi'
multi_wrapper.write_text('#!/usr/bin/env python3\nimport subprocess,sys\n'
                         'if sys.argv[1]=="done": sys.exit(73)\n'
                         f'sys.exit(subprocess.run([{shutil.which("tasks-axi")!r}]+sys.argv[1:]).returncode)\n')
multi_wrapper.chmod(0o755)
multi_env = dict(env, PATH=str(multi_fakebin) + os.pathsep + env['PATH'])
run(retire, 'multi-delivery', '--complete-only', ok=False, custom_env=multi_env)
multi_marker = home / 'state/multi-delivery.backlog-close'
assert f'arg={current_url}\n' in multi_marker.read_text()
assert old_url not in multi_marker.read_text()
assert 'state: in_flight' in state('multi-delivery')
run(retire, 'multi-delivery', '--complete-only')
done = state('multi-delivery')
assert 'state: done' in done and current_url in done and old_url not in done
assert not multi_marker.exists()
assert json.loads(record.read_text())['owner_receipts']['merge'] == receipts
print('ok - exact current delivery completes among retained same-generation merge history')

for task, metadata, message in (
        ('multi-absent', [], 'multiple merge receipts need one current delivery identity'),
        ('multi-ambiguous', [f'pr={old_url}', f'pr={current_url}', f'pr_head={current_head}'],
         'ambiguous current delivery metadata'),
        ('multi-conflict', [f'pr={current_url}', f'pr_head={old_head}'],
         'current delivery identity conflicts with merge receipts')):
    setup(task, 'ship')
    assess(task)
    merge_receipt(task, old_url, old_head)
    merge_receipt(task, current_url, current_head)
    if metadata:
        with (home / 'state' / f'{task}.meta').open('a') as stream:
            stream.write('\n'.join(metadata) + '\n')
    completion_refuses(task, message)
print('ok - absent, ambiguous and conflicting current delivery identity fail closed without rewriting history')

setup('single-ambiguous', 'ship')
assess('single-ambiguous')
merge_receipt('single-ambiguous', current_url, current_head)
with (home / 'state/single-ambiguous.meta').open('a') as stream:
    stream.write(f'pr={current_url}\npr={current_url}\npr_head={current_head}\n')
completion_refuses('single-ambiguous', 'ambiguous current delivery metadata')
print('ok - duplicate current metadata cannot hide behind an otherwise unique receipt')

setup('wrong-generation', 'ship')
merge_receipt('wrong-generation', old_url, old_head)
folder = home / 'data/wrong-generation'
(folder / 'authority-2.md').write_text('Authorize replacement delivery\n')
(folder / 'brief.md').write_text('Complete replacement delivery\n')
(home / 'state/wrong-generation.meta').write_text(
    f'kind=ship\nspawn_gen=g2\npr={old_url}\npr_head={old_head}\n')
refs = ['data/wrong-generation/authority-2.md', 'data/wrong-generation/report.md']
basis = call('wrong-generation', 'inspect', *[arg for ref in refs for arg in ('--evidence', ref)])['basis']
call('wrong-generation', 'assess', '--basis', basis, '--judgment', json.dumps(dict(
    disposition='open', outcome='Replacement authorized', remaining_gap='Deliver replacement',
    authority_ref=refs[0], evidence=[refs[1]], intent_changed=True)))
basis = call('wrong-generation', 'inspect', *[arg for ref in refs for arg in ('--evidence', ref)])['basis']
call('wrong-generation', 'assess', '--basis', basis, '--judgment', json.dumps(dict(
    disposition='accepted', outcome='Replacement delivered', remaining_gap='',
    authority_ref=refs[0], evidence=[refs[1]])))
completion_refuses('wrong-generation', 'required delivery has no confirmed merge receipt')
print('ok - a current metadata identity cannot promote a wrong-generation merge receipt')

# An actual guarded refusal precedes completion. It preserves uncertain endpoint
# identity; the completion path must never attempt a provider/window call.
setup('delivered', 'ship')
assess('delivered')
url = 'https://code.byted.org/fixture/firstmate/merge_requests/1'
merge_receipt('delivered', url, 'b' * 40)
before = preserved('delivered')
run(root / 'bin/fm-teardown.sh', 'delivered', '--endpoint-only', '--expect-spawn-gen', 'g1', ok=False)
assert 'state: in_flight' in state('delivered') and preserved('delivered') == before
run(retire, 'delivered', '--complete-only')
assert 'state: done' in state('delivered') and url in backlog.read_text()
assert preserved('delivered') == before
receipt = json.loads((home / 'state/delivered.cleanup.json').read_text())
assert receipt['phases']['record_close']['state'] == 'confirmed'
assert any(p['state'] == 'retained' for p in receipt['phases'].values())
assert json.loads(run(sys.executable, lib, 'due', 'delivered'))['due']
run(retire, 'delivered', '--complete-only')
assert preserved('delivered') == before
print('ok - accepted delivered ship plus refused cleanup becomes Done; report, merge URL and resources retained')

setup('scout')
assess('scout')
before = preserved('scout')
run(retire, 'scout', '--complete-only')
assert 'state: done' in state('scout') and 'data/scout/report.md' in backlog.read_text()
assert preserved('scout') == before
print('ok - accepted completed scout closes with its assessed report independently of resource disposal')

# Business bookkeeping never inspects or changes protected endpoints/copies.
# Exact custody ambiguity, focus, sibling activity and unlanded bytes all remain.
for name in ('dirty', 'unlanded', 'shared', 'ambiguous', 'focused', 'live-sibling'):
    task = 'retain-' + name
    setup(task)
    assess(task)
    meta = home / 'state' / (task + '.meta')
    with meta.open('a') as stream:
        stream.write('window=fixture:w1:p-' + task + '\nendpoint_task_id=' + task + '\n')
    resource = home / 'data' / task / 'resource'
    sibling = home / 'state' / (task + '-sibling.meta')
    sibling.write_text('spawn_gen=other-g1\nworktree=' + str(resource) + '\nwindow=fixture:w1:p-other\n')
    before = preserved(task)
    sibling_before = sibling.read_bytes()
    run(retire, task, '--complete-only')
    assert 'state: done' in state(task) and preserved(task) == before and sibling.read_bytes() == sibling_before
print('ok - dirty/unlanded/shared/ambiguous/focused/live-sibling resources stay byte-identical during business closure')

setup('archived')
(home / 'data/archived/stop.txt').write_text('Explicitly archive this task\n')
assess('archived', disposition='archived', authority='data/archived/stop.txt', gap='Uncertain old business effect')
before = preserved('archived')
run(retire, 'archived', '--complete-only')
assert 'state: done' in state('archived') and preserved('archived') == before
assert call('archived', 'lifecycle')['disposition'] == 'archived'

# Business-close bookkeeping is not a resource-fact change. If interruption
# lands this receipt phase before lifecycle relinking, completion validation
# must still admit the pending close-marker replay on restart.
setup('record-close-interruption')
assess('record-close-interruption')
receipt_path = home / 'state/record-close-interruption.cleanup.json'
receipt = dict(schema='fm-task-cleanup.v1', task_id='record-close-interruption',
               spawn_gen='g1', goal_revision=1,
               phases=dict(directory_return=dict(state='retained', reason_code='dirty-unlanded')))
receipt_path.write_text(json.dumps(receipt)); receipt_path.chmod(0o600)
run(sys.executable, lib, 'link-cleanup', 'record-close-interruption')
receipt['phases']['record_close'] = dict(state='confirmed', reason_code='backlog-paired-resource-record-retained')
receipt_path.write_text(json.dumps(receipt)); receipt_path.chmod(0o600)
run(sys.executable, lib, 'completion-read', 'record-close-interruption')

# A real tasks-axi done lands, then its response fails: the exact crash window
# between business completion and cleanup bookkeeping. No effects are retried.
setup('crash')
assess('crash')
before = preserved('crash')
real_tasks = shutil.which('tasks-axi')
assert real_tasks
fakebin = home / 'fakebin'
fakebin.mkdir()
wrapper = fakebin / 'tasks-axi'
wrapper.write_text('#!/usr/bin/env python3\nimport subprocess,sys\n'
                   f'r=subprocess.run([{real_tasks!r}]+sys.argv[1:])\n'
                   'sys.exit(73 if sys.argv[1]=="done" and r.returncode==0 else r.returncode)\n')
wrapper.chmod(0o755)
crash_env = dict(env, PATH=str(fakebin) + os.pathsep + env['PATH'])
run(retire, 'crash', '--complete-only', ok=False, custom_env=crash_env)
assert 'state: done' in state('crash') and preserved('crash') == before
marker = home / 'state/crash.backlog-close'
assert marker.exists() and (home / 'state/crash.cleanup.json').exists()
run(retire, 'crash', '--complete-only')
assert not marker.exists() and preserved('crash') == before
assert json.loads((home / 'state/crash.cleanup.json').read_text())['phases']['record_close']['state'] == 'confirmed'
print('ok - crash after Done preserves report and outstanding cleanup; marker replay completes bookkeeping without resource effects')

# Completed cleanup removed execution metadata, then prune moved its Done row
# into history before pending bookkeeping converged. Replaying the marker must
# not repeat the partially applied operation or create an active row.
setup('history-close')
(home / 'data/history-close/stop.txt').write_text('Explicitly archive this old investigation; retain uncertainty and reports')
assess('history-close', disposition='archived', authority='data/history-close/stop.txt', gap='Old scientific result remains uncertain')
run('tasks-axi', 'done', 'history-close', '--report', 'data/history-close/report.md', '--file', backlog)
run('tasks-axi', 'prune', '--keep', '0', '--file', backlog)
meta = home / 'state/history-close.meta'
meta.unlink()
marker = home / 'state/history-close.backlog-close'
marker.write_text(f'id=history-close\ndata={home / "data"}\nspawn_gen=g1\ncleanup_incomplete=0\ncleanup_disposition=retained-unverified\narg=--report\narg=data/history-close/report.md\n')
archive = home / 'data/done-archive.md'
archive_before = archive.read_bytes()
report_before = (home / 'data/history-close/report.md').read_bytes()
replay_script = 'set -u; . "$1/bin/fm-tasks-axi-lib.sh"; . "$1/bin/fm-backlog-transition-lib.sh"; fm_backlog_close_marker_replay "$2/state" "$2/state/history-close.backlog-close" "$2/data"'
# Mismatched generation preserves the marker and all archived uncertainty.
marker.write_text(marker.read_text().replace('spawn_gen=g1', 'spawn_gen=other-g1'))
run('bash', '-c', replay_script, '_', root, home, ok=False)
assert marker.exists() and archive.read_bytes() == archive_before
marker.write_text(marker.read_text().replace('spawn_gen=other-g1', 'spawn_gen=g1'))
# Missing exact delivery reference is not an applied artifact.
archive.write_text(archive.read_text().replace('data/history-close/report.md', 'data/other/report.md'))
run('bash', '-c', replay_script, '_', root, home, ok=False)
assert marker.exists()
archive.write_bytes(archive_before)
# Unchecked, duplicated, or merely prefix-matching archive evidence refuses.
row = next(line for line in archive.read_text().splitlines() if 'history-close -' in line)
for changed in (archive.read_text().replace('[x] history-close', '[ ] history-close'),
                archive.read_text() + '\n' + row + '\n',
                archive.read_text().replace('data/history-close/report.md', 'data/history-close/report.mdx')):
    archive.write_text(changed)
    run('bash', '-c', replay_script, '_', root, home, ok=False)
    assert marker.exists()
archive.write_bytes(archive_before)
run('bash', '-c', replay_script, '_', root, home)
assert not marker.exists() and not meta.exists() and archive.read_bytes() == archive_before
assert (home / 'data/history-close/report.md').read_bytes() == report_before
assert 'code: NOT_FOUND' in run('tasks-axi', 'show', 'history-close', '--file', backlog, ok=False)
readback = json.loads(run(sys.executable, lib, 'read', 'history-close'))
assert readback['disposition'] == 'archived' and 'uncertain' in readback['assessment']['remaining_gap']
assert readback['owner_receipts']['cleanup'][-1]['facts']['copyDisposition'] == 'retained-unverified'
run('bash', '-c', replay_script, '_', root, home)
assert archive.read_bytes() == archive_before
print('ok - exact Done history converges interrupted cleanup bookkeeping once; generation/artifact conflicts remain pending and archived uncertainty stays preserved')
