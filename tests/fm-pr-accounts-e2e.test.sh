#!/usr/bin/env bash
# Product transcript: real gh credential lookup and gh-axi, with only gh's
# network operations replaced by an identity-enforcing, stateful forge fixture.
# No real credential, GitHub request, account switch, or pipeline operation.
# stdout is reviewer-visible CLI evidence; redirect it to an evidence file.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_LIVE_PR_ACCOUNTS gh gh-axi python3
TEMP_ROOT=$(fm_test_tmproot fm-pr-accounts-e2e)
python3 - "$ROOT" "$TEMP_ROOT" <<'PY'
import concurrent.futures
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time

root, temp = map(Path, sys.argv[1:])
real_gh = shutil.which('gh')
home = temp / 'home'
config = home / 'config'
state = home / 'state'
gh_config = temp / 'gh-config'
fakebin = temp / 'fakebin'
for directory in (config, state, gh_config, fakebin, temp / 'root/bin', temp / 'wt'):
    directory.mkdir(parents=True)

def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)

# These are synthetic tokens stored in gh's real multi-account configuration
# format. Only gh auth token reaches the real CLI; network calls cannot escape.
hosts = gh_config / 'hosts.yml'
hosts.write_text('''github.com:
    user: personal-user
    oauth_token: fixture-personal
    git_protocol: https
    users:
        personal-user:
            oauth_token: fixture-personal
        work-user:
            oauth_token: fixture-work
''')
original_hosts = hosts.read_bytes()
executable(temp / 'root/bin/fm-guard.sh', '#!/bin/sh\nexit 0\n')
executable(fakebin / 'no-mistakes', '#!/bin/sh\nexit 1\n')
executable(fakebin / 'tmux', '#!/bin/sh\nexit 1\n')
executable(fakebin / 'gh', '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
args = sys.argv[1:]
base = pathlib.Path(os.environ['FM_ACCOUNTS_FIXTURE'])
if args[:2] == ['auth', 'token']:
    sys.exit(subprocess.run([os.environ['FM_ACCOUNTS_REAL_GH'], *args]).returncode)
# Resolve the normal active-account path through real gh, not fixture logic.
token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
if not token:
    token = subprocess.check_output([os.environ['FM_ACCOUNTS_REAL_GH'], 'auth', 'token',
                                    '--hostname', 'github.com'], text=True).strip()
identity = {'fixture-work': 'work-user', 'fixture-personal': 'personal-user'}.get(token)
repo = None
number = '7'
if '--repo' in args:
    repo = args[args.index('--repo') + 1]
    number = args[2]
elif args[:2] == ['pr', 'view']:
    parts = args[2].split('/')
    repo, number = '/'.join(parts[3:5]), parts[6]
elif args[:2] == ['api', 'graphql']:
    fields = dict(a.split('=', 1) for a in args if a.startswith(('owner=', 'repo=', 'number=')))
    repo, number = fields['owner'] + '/' + fields['repo'], fields['number']
expected = {'work-org/project': 'work-user', 'work-org/shared': 'personal-user'}.get(repo)
if not expected or expected != identity or os.environ.get('GH_HOST') != 'github.com':
    print('fixture: repository access denied', file=sys.stderr)
    sys.exit(1)
pr_state = base / (repo.replace('/', '-') + '-' + number)
current = pr_state.read_text() if pr_state.exists() else 'OPEN'
operation = ' '.join(args[:2])
if '--json' in args:
    operation += ' ' + args[args.index('--json') + 1]
with (base / 'requests.jsonl').open('a') as log:
    log.write(json.dumps({'identity': identity, 'repo': repo, 'number': number,
                          'operation': operation, 'state': current}) + '\\n')
barrier = os.environ.get('FM_ACCOUNTS_BARRIER')
if barrier:
    barrier = pathlib.Path(barrier) / operation.replace(' ', '-')
    barrier.mkdir(exist_ok=True)
    (barrier / identity).touch()
    deadline = time.monotonic() + 8
    while not all((barrier / user).exists() for user in ('work-user', 'personal-user')):
        if time.monotonic() > deadline:
            sys.exit('concurrent command did not overlap')
        time.sleep(0.02)
if args[:2] == ['pr', 'merge']:
    pr_state.write_text('MERGED')
    print('Merged pull request #' + number)
elif args[:2] == ['api', 'graphql']:
    print('state=' + current + '\\nmerged=' + str(current == 'MERGED').lower() + '\\nqueued=false\\nbase=main')
elif '-q' in args:
    query = args[args.index('-q') + 1]
    if query == '.headRefOid':
        print('a' * 40)
    elif query == '.state':
        print(current)
    else:
        sys.exit('unsupported fixture query: ' + query)
elif args[:2] == ['pr', 'view']:
    print(json.dumps({'state': current, 'mergedBy': {'login': identity} if current == 'MERGED' else None,
        'mergedAt': '2026-09-07T00:00:00Z' if current == 'MERGED' else None,
        'statusCheckRollup': [{'__typename': 'CheckRun', 'name': 'build',
        'status': 'COMPLETED', 'conclusion': 'SUCCESS',
        'detailsUrl': 'https://github.com/' + repo + '/actions/runs/1'}]}))
else:
    sys.exit('unsupported fixture operation: ' + repr(args))
''')
env = {k: v for k, v in os.environ.items() if k not in (
    'GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN',
    'GH_DEBUG', 'FM_CONFIG_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
    'FM_PROJECTS_OVERRIDE')}
env.update(PATH=str(fakebin) + os.pathsep + os.environ['PATH'], HOME=str(home),
           GH_CONFIG_DIR=str(gh_config), GH_HOST='enterprise.invalid',
           GH_PROMPT_DISABLED='1', GH_NO_UPDATE_NOTIFIER='1',
           HTTPS_PROXY='http://127.0.0.1:9', HTTP_PROXY='http://127.0.0.1:9',
           FM_HOME=str(home), FM_ROOT_OVERRIDE=str(temp / 'root'),
           FM_ACCOUNTS_FIXTURE=str(temp), FM_ACCOUNTS_REAL_GH=real_gh,
           FM_CHECK_INTERVAL='0', FM_CHECK_TIMEOUT='3', FM_POLL='0.02',
           FM_HEARTBEAT='999999', FM_SIGNAL_GRACE='0')


def call(args, extra=None, expect=0):
    result = subprocess.run(args, cwd=root, env=env | (extra or {}),
                            text=True, capture_output=True, timeout=15)
    assert result.returncode == expect, (args, result.returncode, result.stdout, result.stderr)
    return result


def show(args, result):
    print('$ ' + shlex.join(args))
    print(result.stdout, end='')
    if result.stderr:
        print(result.stderr, end='')


def request_rows():
    return [json.loads(line) for line in (temp / 'requests.jsonl').read_text().splitlines()]


def checks(repo):
    return ['bash', 'bin/fm-pr-lib.sh', '--github', 'github.com', repo,
            'gh-axi', 'pr', 'checks', '7', '--repo', repo]


def parallel_commands(commands, label):
    barrier = temp / label
    barrier.mkdir()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(call, cmd, {'FM_ACCOUNTS_BARRIER': str(barrier)}) for cmd in commands]
        results = [f.result() for f in futures]
    for cmd, result in zip(commands, results):
        show(cmd, result)
    stages = list(barrier.iterdir())
    assert stages and all({p.name for p in stage.iterdir()} == {'work-user', 'personal-user'} for stage in stages)
    print('Observed both identities inside each forge operation concurrently; neither waited for an account switch.')
    return results


print('Firstmate dual-account CLI lifecycle (stateful fake forge; real gh auth token and gh-axi).')
print('Synthetic credentials only. GitHub network operations are intercepted; no live PR was mutated.')
print('Initial gh active account: personal-user. Ambient GH_HOST: enterprise.invalid. No exported token.\n')
cmd = checks('work-org/shared')
result = call(cmd)
show(cmd, result)
assert '1 passed' in result.stdout
assert request_rows()[-1]['identity'] == 'personal-user'
print('Unconfigured single-account flow used the active personal account.\n')
cmd = checks('work-org/project')
result = call(cmd, expect=1)
show(cmd, result)
assert 'repository access denied' in result.stdout + result.stderr
print('Counterfactual: the active personal account cannot check the work repository.\n')

mapping = config / 'github-accounts'
mapping.write_text('github.com/work-org work-user\ngithub.com/work-org/shared personal-user\n')
print('config/github-accounts:\n' + mapping.read_text())
results = parallel_commands([checks('work-org/project'), checks('work-org/shared')], 'checks-barrier')
assert all('1 passed' in result.stdout for result in results)

repos = ['work-org/project', 'work-org/shared']
urls = ['https://github.com/' + repo + '/pull/7' for repo in repos]
for task, url in zip(('work', 'personal'), urls):
    (state / (task + '.meta')).write_text('kind=ship\nmode=direct-PR\nworktree=' + str(temp / 'wt') + '\n')
    cmd = ['bash', 'bin/fm-pr-check.sh', task, url]
    show(cmd, call(cmd))
    assert 'pr_head=' + 'a' * 40 in (state / (task + '.meta')).read_text()

# Open polls cannot produce a false merge. Stop the bounded open watcher after
# both repositories have actually been read, then retry the same persisted
# registrations after an external merge.
watch = ['bash', 'bin/fm-watch.sh']
process = subprocess.Popen(watch, cwd=root, env=env, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    deadline = time.monotonic() + 10
    while not all(any(r['repo'] == repo and r['operation'] == 'pr view state' for r in request_rows()) for repo in repos):
        assert time.monotonic() < deadline, 'watcher did not poll both repositories'
        assert process.poll() is None, 'open watcher unexpectedly exited'
        time.sleep(0.05)
finally:
    process.terminate()
    out, err = process.communicate(timeout=10)
assert not out.strip(), (out, err)
print('$ bash bin/fm-watch.sh  # observed both OPEN PRs, then stopped this test cycle')
print('(no merge wake; both registrations retained)')
assert all((state / (task + '.pr-poll')).exists() for task in ('work', 'personal'))

def acknowledge_cycle():
    cmd = ['bash', 'bin/fm-wake-drain.sh']
    result = call(cmd)
    match = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', result.stderr)
    if match:
        call(cmd + ['--ack-through', match[1], '--recovery-generation', match[2]])


acknowledge_cycle()
print('\nFixture transition: both reviewed PRs are merged externally.')
for repo in repos:
    (temp / (repo.replace('/', '-') + '-7')).write_text('MERGED')
merge_wakes = ''
for _ in repos:
    result = call(watch)
    show(watch, result)
    assert 'merged' in result.stdout
    merge_wakes += (state / '.wake-queue').read_text()
    acknowledge_cycle()
assert not list(state.glob('*.pr-poll'))
assert all(url in merge_wakes for url in urls)
print('Persisted merge wakes (captured before acknowledgement):\n' + merge_wakes)

# Reuse the tasks for different PRs, now exercising the actual guarded merge
# command and independent read-back verification, simultaneously for both users.
commands = [['bash', 'bin/fm-pr-merge.sh', task, 'https://github.com/' + repo + '/pull/8']
            for task, repo in zip(('work', 'personal'), repos)]
results = parallel_commands(commands, 'merge-barrier')
assert all('verified:' in result.stdout and 'is merged' in result.stdout for result in results)
assert all((temp / (repo.replace('/', '-') + '-8')).read_text() == 'MERGED' for repo in repos)

before = (state / 'work.meta').read_bytes()
mapping.write_text('github.com/work-org unavailable-user\ngithub.com/work-org/shared personal-user\n')
cmd = ['bash', 'bin/fm-pr-check.sh', 'work', urls[0]]
result = call(cmd, expect=1)
show(cmd, result)
assert (state / 'work.meta').read_bytes() == before
assert 'poll not armed' in result.stderr
assert hosts.read_bytes() == original_hosts, 'global active-account state changed'
for path in state.rglob('*'):
    if path.is_file():
        assert b'fixture-work' not in path.read_bytes() and b'fixture-personal' not in path.read_bytes(), path
print('\nObserved authenticated forge requests (account names only):')
for row in request_rows():
    print(json.dumps(row, sort_keys=True))
print('\nFinal gh active account: personal-user; hosts.yml byte-identical to before the run.')
print('Task metadata and poll state contain no credential values; unavailable mapping refused without replacing metadata.')
PY
