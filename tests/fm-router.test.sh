#!/usr/bin/env bash
# Public CLI behavior, with isolated homes, git repositories and launch-owner fixtures.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-router)
export TEST_ROUTER_ROOT="$ROOT" TEST_ROUTER_TMP="$TMP"
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
root = Path(os.environ['TEST_ROUTER_ROOT'])
tmp = Path(os.environ['TEST_ROUTER_TMP'])
home = tmp / 'home'
repo = tmp / 'demo'
repo.mkdir()
subprocess.run(['git', 'init', '-q', str(repo)], check=True)
(repo / 'package.json').write_text('{}')
subprocess.run(['git', '-C', str(repo), 'add', 'package.json'], check=True)
(home / 'config').mkdir(parents=True)
(home / 'state').mkdir()
(home / 'data').mkdir()
env = dict(os.environ, FM_HOME=str(home))
env.pop('FASTINO_API_KEY', None)
env.pop('TYPESAFE_API_KEY', None)
def run(*args, code=0, cli=root / 'bin/fm', cwd=None):
    result = subprocess.run([str(cli), *args], env=env, text=True, capture_output=True, cwd=cwd)
    assert result.returncode == code, (args, result.returncode, result.stderr, result.stdout)
    return result
for request, kind in [('design multiplayer architecture', 'reasoning'), ('fix race deadlock', 'reasoning'), ('fix off-by-one bug', 'bugfix'), ('rename typo', 'mechanical'), ('add feature', 'feature')]:
    value = json.loads(run('route', request, '--project', str(repo), '--worker', 'codex', '--dry-run').stdout)
    assert value['task_class'] == kind
    assert value['profile']['harness'] == 'codex'
    assert 'bypass' in value['permission_posture']
    assert value['repository']['manifests'] == ['package.json']
assert list((home / 'data').iterdir()) == []
assert list((home / 'state').iterdir()) == []
assert json.loads(run('sessions').stdout) == []
run('route', 'fix', '--project', str(repo), '--no-route', code=2)
run('task', '# Task\ninjected', '--project', str(repo), '--worker', 'codex', code=2)
run('task', 'fix', '--project', str(repo), '--worker', 'codex', '--id', 'x' * 65, code=2)
assert list((home / 'data').iterdir()) == []
run('status', '../escape', code=2)
(home / 'state' / 'known.meta').write_text('endpoint_task_id=known\nharness=codex\nworktree=/tmp/not-running\n')
assert json.loads(run('status', 'known').stdout)['liveness'] == 'unknown'
run('resume', 'known', code=2)
assert json.loads(run('resume', 'known', '--note', 'preserve current work', '--dry-run').stdout)['session'] == 'known'
(home / 'state' / 'known.meta').write_text('endpoint_task_id=known\nharness=codex\nproject=' + str(repo) + '\nworktree=/tmp/not-running\n')
assert json.loads(run('resume', '--note', 'explicit progress', '--dry-run', cwd=repo).stdout)['session'] == 'known'
assert json.loads(run(cwd=repo).stdout)[0]['session'] == 'known'
(home / 'state' / 'other.meta').write_text('endpoint_task_id=other\nharness=codex\nproject=' + str(repo) + '\n')
run('resume', '--note', 'explicit progress', '--dry-run', cwd=repo, code=2)
(home / 'state' / 'other.meta').unlink()
(home / 'config' / 'crew-dispatch.json').write_text('{bad')
doctor = json.loads(run('doctor').stdout)
assert doctor['configuration']['dispatch'] == 'invalid'
assert all(w['authentication'] == 'unknown' for w in doctor['workers'])
run('route', 'fix', '--worker', 'codex', '--project', str(repo), code=2)
(home / 'config' / 'crew-dispatch.json').unlink()
# Simulated HTTP transport drives the actual finite-class public routing path.
hook = tmp / 'pyhook'
hook.mkdir()
(hook / 'sitecustomize.py').write_text("""import json, os, urllib.request
class Reply:
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self, maximum): return os.environ['FAKE_FASTINO_REPLY'].encode()
def open_request(req, timeout):
    assert timeout == 5
    assert req.has_header("Authorization") and "Authorization" not in req.headers
    with open(os.environ['FAKE_FASTINO_REQUEST'], 'w') as f: json.dump(json.loads(req.data), f)
    return Reply()
urllib.request.urlopen = open_request
""")
env['PYTHONPATH'] = str(hook)
env['FASTINO_API_KEY'] = 'private-routing-key'
env['FASTINO_MODEL'] = 'custom-routing-model'
env['FAKE_FASTINO_REQUEST'] = str(tmp / 'request.json')
classes = ['reasoning', 'investigation', 'refactor', 'mechanical', 'bugfix', 'feature', 'general']
answer = {'choice': 'reasoning', 'confidence': .01, 'probabilities': {key: 1 if key == 'reasoning' else 0 for key in classes}}
env['FAKE_FASTINO_REPLY'] = json.dumps({'answers': {'task_class': answer}})
value = json.loads(run('route', 'general request', '--project', str(repo)).stdout)
assert value['task_class'] == 'reasoning' and value['source'] == 'custom-routing-model'
request = json.loads((tmp / 'request.json').read_text())
assert request['model'] == 'custom-routing-model'
assert request['questions']['task_class']['type'] == 'choice'
assert 'private-routing-key' not in json.dumps(value) + json.dumps(request)
answer['probabilities'] = classes
env['FAKE_FASTINO_REPLY'] = json.dumps({'answers': {'task_class': answer}})
value = json.loads(run('route', 'fix bug', '--project', str(repo)).stdout)
assert value['task_class'] == 'bugfix' and value['evidence']['status'] == 'error'
env['FASTINO_ENDPOINT'] = 'https://user:SECRET@example.test/api'
refused = run('route', 'general request', '--project', str(repo), code=2)
assert 'SECRET' not in refused.stderr
for key in ('PYTHONPATH', 'FASTINO_ENDPOINT', 'FASTINO_MODEL', 'FASTINO_API_KEY'):
    env.pop(key, None)
assert list((home / 'data').iterdir()) == []
# Copied CLI calls fixture owners instead of launching any real worker.
code = tmp / 'code'
(code / 'bin').mkdir(parents=True)
shutil.copy2(root / 'bin/fm', code / 'bin/fm')
log = tmp / 'owners.log'
env['ROUTER_OWNER_LOG'] = str(log)
env['FASTINO_API_KEY'] = 'never-in-worker-env'
for name, body in {
'fm-project-mode.sh': 'case "$1" in --branch-prefix) echo fm/;; --forge) echo none;; *) echo "no-mistakes off";; esac',
'fm-tasks-axi.sh': 'mkdir -p "$FM_HOME/data"',
'fm-brief.sh': 'mkdir -p "$FM_HOME/data/$1"; printf "# Task\\n## Captain\x27s intent\\n{TASK}\\n## Firstmate spec\\n{FIRSTMATE_SPEC}\\n" > "$FM_HOME/data/$1/brief.md"',
'fm-spawn.sh': 'test -z "${FASTINO_API_KEY:-}"; exit "${FIXTURE_SPAWN_EXIT:-0}"',
'fm-control.sh': 'test -z "${FASTINO_API_KEY:-}"; test "$1" = known; test "$2" = relaunch'
}.items():
    path = code / 'bin' / name
    path.write_text('#!/usr/bin/env bash\nset -eu\nprintf "%s\\n" "' + name + ' $*" >> "$ROUTER_OWNER_LOG"\n' + body + '\n')
    path.chmod(0o755)
(home / 'data' / 'projects.md').write_text('- demo [no-mistakes] - fixture\n')
result = run('task', 'fix harmless fixture', '--project', str(repo), '--worker', 'codex', '--id', 'launched', cli=code / 'bin/fm')
assert 'Permission posture: Codex bypass' in result.stderr
assert json.loads(result.stdout)['launch_outcome'] == 'launched'
assert json.loads((home / 'data' / 'launched' / 'route.json').read_text())['home'] == str(home)
assert '{TASK}' not in (home / 'data' / 'launched' / 'brief.md').read_text()
(home / 'data' / 'known').mkdir()
env['FIXTURE_SPAWN_EXIT'] = '7'
failed = run('task', 'fix fixture failure', '--project', str(repo), '--worker', 'codex', '--id', 'failed', cli=code / 'bin/fm', code=2)
assert 'Task identity: failed' in failed.stderr and 'task failed preserved' in failed.stderr
assert json.loads((home / 'data' / 'failed' / 'route.json').read_text())['launch_outcome'] == 'failed'
assert log.read_text().count('fm-spawn.sh failed ') == 1
assert any(value['session'] == 'failed' for value in json.loads(run('sessions', cli=code / 'bin/fm').stdout))
env.pop('FIXTURE_SPAWN_EXIT')
(home / 'data' / 'damaged').mkdir()
(home / 'data' / 'damaged' / 'route.json').write_text('{"task_class": "bug')
(home / 'data' / 'nonfinite').mkdir()
(home / 'data' / 'nonfinite' / 'route.json').write_text('{"confidence": NaN}')
for command in ('sessions', 'status'):
    listed = {value['session']: value for value in json.loads(run(command, cli=code / 'bin/fm').stdout)}
    assert 'damaged routing evidence' in listed['damaged']['error']
    assert 'damaged routing evidence' in listed['nonfinite']['error']
    assert 'routing' in listed['failed'] and 'routing' in listed['launched'] or 'record' in listed['launched']
run(cli=code / 'bin/fm')
assert (home / 'data' / 'damaged' / 'route.json').read_text() == '{"task_class": "bug'
shutil.rmtree(home / 'data' / 'damaged')
shutil.rmtree(home / 'data' / 'nonfinite')
run('resume', 'known', '--note', 'saved progress', cli=code / 'bin/fm')
assert (home / 'data' / 'known' / 'progress.md').read_text().strip() == 'saved progress'
assert 'fm-control.sh known relaunch --note saved progress' in log.read_text()
# Native supports remain exclusively the existing owner's responsibility.
print('ok: router dry-run, override, classification, state isolation, launch and continuation')
PY
pass "router public CLI fixtures"
