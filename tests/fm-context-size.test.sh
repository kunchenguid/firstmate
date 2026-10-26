#!/usr/bin/env bash
# Fixture-only conversation observations: both log formats, account roots,
# unknown windows, bounded tails, and remote selected-home transport failures.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-size)
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

root, tmp = map(Path, sys.argv[1:])
reader = root / 'bin/fm-context-size.sh'
login = tmp / 'login'
login.mkdir()
env = dict(os.environ, HOME=str(login))
now = time.time()
stamp = datetime.datetime.fromtimestamp(now - 60, datetime.timezone.utc).isoformat()


def meta(name, **values):
    path = tmp / (name + '.meta')
    path.write_text(''.join(key + '=' + str(value) + '\n' for key, value in values.items()))
    return path


def read(path, **overrides):
    result = subprocess.run([str(reader), str(path)], env=dict(env, **overrides),
                            text=True, capture_output=True, timeout=8, check=True)
    return json.loads(result.stdout)


def log(account, harness, cwd, model, usage, provider=None, filename='new.jsonl'):
    if harness == 'claude':
        directory = account / 'projects' / re.sub(r'[^A-Za-z0-9]', '-', cwd)
    else:
        directory = account / 'sessions' / ('--' + cwd.lstrip('/').replace('/', '-') + '--')
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / filename
    message = dict(role='assistant', model=model, usage=usage)
    if provider:
        message.update(provider=provider, timestamp=int((now - 60) * 1000))
    path.write_text(json.dumps(dict(type='message', timestamp=stamp, message=message)) + '\n'
                    + json.dumps(dict(type='tool_result', timestamp=stamp)) + '\n'
                    + '{unfinished\n')
    return path


cwd = '/workspace/demo.worker'
claude_root = login / '.claude'
path = meta('claude', harness='claude', kind='ship', worktree=cwd)
fixture = log(claude_root, 'claude', cwd, 'claude-opus-5-5',
              dict(input_tokens=50000, cache_read_input_tokens=150000, cache_creation_input_tokens=1))
row = read(path)
assert row['tokens'] == 200001 and row['context_window'] == 1000000, row
assert row['percentage'] == 20.0001 and row['over_threshold'] is True, row
assert 60 <= row['age_seconds'] < 70, row
# Latest file, not largest transcript, and exactly 20% does not flag.
older = log(claude_root, 'claude', cwd, 'claude-sonnet-5-5', dict(input_tokens=900000), filename='old.jsonl')
os.utime(older, (now - 1000, now - 1000))
fixture = log(claude_root, 'claude', cwd, 'claude-fable-5-1', dict(input_tokens=200000))
assert read(path)['over_threshold'] is False
# Missing call timestamp stays unknown even though the file has an mtime.
fixture.write_text(json.dumps(dict(message=dict(role='assistant', model='unlisted-model',
                                               usage=dict(input_tokens=23456)))) + '\n')
row = read(path)
assert row['tokens'] == 23456 and row['context_window'] is None, row
assert row['percentage'] is None and row['over_threshold'] is None and row['age_seconds'] is None, row
# A large trailing event cannot make us scan the entire historical log.
with fixture.open('a') as stream:
    stream.write('x' * 4000100 + '\n')
assert read(path)['status'] == 'unknown'

pi_root = tmp / 'pinned-agent'
pi_cwd = '/workspace/mate'
pi_meta = meta('pi', harness='pi-signed', kind='secondmate', home=pi_cwd,
               worktree='/wrong-directory', account=pi_root, model='provider-a/model-a')
log(pi_root, 'pi', pi_cwd, 'model-a', dict(input=40, cacheRead=80, cacheWrite=10), provider='provider-a')
(pi_root / 'models-store.json').write_text(json.dumps({
    'provider-a': dict(models=[dict(id='model-a', contextWindow=500)]),
    'provider-b': dict(models=[dict(id='model-a', contextWindow=1000)])}))
row = read(pi_meta)
assert row['tokens'] == 130 and row['context_window'] == 500 and row['percentage'] == 26, row
assert row['over_threshold'] is True and 60 <= row['age_seconds'] < 70, row
(pi_root / 'models-store.json').write_text(json.dumps({
    'provider-a': dict(models=[dict(id='model-a', contextWindow=500)]),
    'provider-b': dict(models=[dict(id='model-a', contextWindow=1000)]),
    'openrouter': dict(models=[dict(id='anthropic/claude-sonnet-4-5', contextWindow=1000)]),
    'anthropic': dict(models=[dict(id='claude-sonnet-4-5', contextWindow=500)])}))
for harness in ('pi', 'pi-signed'):
    for model, provider, configured, window in (
        ('anthropic/claude-sonnet-4-5', 'openrouter', 'provider-a/model-a', 1000),
        ('model-a', 'provider-b', 'provider-a/model-a', 1000),
        ('model-a', None, 'provider-a/model-a', None),
        ('anthropic/claude-sonnet-4-5', None, 'provider-a/model-a', 1000),
        (None, None, 'openrouter/anthropic/claude-sonnet-4-5', 1000),
        (None, None, 'provider-a/model-a', 500),
    ):
        case_meta = meta('pi-model', harness=harness, kind='ship', worktree=pi_cwd,
                         account=pi_root, model=configured)
        log(pi_root, 'pi', pi_cwd, model, dict(input=40, cacheRead=80, cacheWrite=10),
            provider=provider)
        row = read(case_meta)
        assert row['status'] == 'read' and row['tokens'] == 130, row
        assert row['model'] == (model or configured) and row['context_window'] == window, row
        assert row['percentage'] == (13000 / window if window else None), row
        assert row['over_threshold'] == (13000 / window > 20 if window else None), row
(pi_root / 'models-store.json').unlink()
assert read(pi_meta)['context_window'] is None
assert read(meta('missing', harness='pi', kind='ship', worktree='/missing'))['reason'] == 'no session log'
assert read(meta('other', harness='codex'))['status'] == 'not_read'
# A recorded alternate Claude account must not accidentally read the default.
pin = tmp / 'claude-pin'
log(pin, 'claude', cwd, 'claude-sonnet-5-5', dict(input_tokens=12))
assert read(meta('pinned', harness='claude', worktree=cwd, account=pin))['tokens'] == 12

# Fake SSH exercises fm-on's real argv routing without a network or live agent.
remote_home = tmp / 'remote-home'
(remote_home / 'state/parent-route').mkdir(parents=True)
(remote_home / '.fm-secondmate-home').write_text('mate\n')
remote_login = tmp / 'remote-login'
remote_login.mkdir()
remote_root = remote_login / '.pi/agent'
log(remote_root, 'pi', str(remote_home), 'anthropic/remote-model', dict(input=300, cacheRead=20, cacheWrite=4), provider='remote-provider')
(remote_root / 'models-store.json').write_text(json.dumps({
    'remote-provider': dict(models=[dict(id='anthropic/remote-model', contextWindow=1000)]),
    'anthropic': dict(models=[dict(id='remote-model', contextWindow=500)])}))
(remote_home / 'state/parent-route/mate.meta').write_text(
    'kind=secondmate\nharness=pi\nhome=' + str(remote_home) + '\n')
parent = tmp / 'parent'
(parent / 'data').mkdir(parents=True)
(parent / 'data/secondmates.md').write_text(
    '- mate - Example (host: fixture-host; root: /workspace/firstmate; home: '
    + str(remote_home) + '; scope: example; projects: ; added 2026-01-01)\n')
ssh = tmp / 'ssh'
ssh.write_text('''#!/usr/bin/env python3
import base64, json, os, subprocess, sys, time
if os.environ.get('FIXTURE_SSH_SLOW'):
    time.sleep(30)
    sys.exit(0)
if os.environ.get('FIXTURE_SSH_FAIL'):
    sys.exit(255)
args = sys.argv[1:]
assert args[args.index('--') + 1] == 'fixture-host'
command = base64.b64decode(args[-1]).decode().split('\\0')[:-1]
assert command == ['fm-context-size.sh', '--remote-self', 'mate'], command
sys.exit(subprocess.call([os.environ['FIXTURE_READER']] + command[1:],
                        env=dict(os.environ, HOME=os.environ['FIXTURE_REMOTE_LOGIN'],
                                 FM_HOME=os.environ['FIXTURE_REMOTE_HOME'])))
''')
ssh.chmod(0o755)
remote_meta = meta('mate', harness='pi', kind='secondmate', home=remote_home, remote_host='fixture-host')
remote_env = dict(FM_HOME=str(parent), FM_ROOT_OVERRIDE=str(root), FM_SSH_BIN=str(ssh),
                  FIXTURE_READER=str(reader), FIXTURE_REMOTE_HOME=str(remote_home),
                  FIXTURE_REMOTE_LOGIN=str(remote_login))
row = read(remote_meta, **remote_env)
assert row['tokens'] == 324 and row['context_window'] == 1000 and row['percentage'] == 32.4, row
assert read(remote_meta, **remote_env, FIXTURE_SSH_FAIL='1')['status'] == 'unknown'
start = time.monotonic()
assert read(remote_meta, **remote_env, FIXTURE_SSH_SLOW='1')['status'] == 'unknown'
assert time.monotonic() - start < 6, 'remote read exceeded its deadline'
print('PASS: bounded Claude/Pi usage, windows, pins, absence and selected-home remote reads')
PY
pass 'fixture-only conversation reader'
