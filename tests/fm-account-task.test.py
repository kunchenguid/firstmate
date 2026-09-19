#!/usr/bin/env python3
"""Public executable tests; invented homes/tools, no SSH/account/model/service use."""
import copy
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()
PYTHON = str(Path(sys.executable).resolve())

SSH_STUB = r'''#!PYTHON
import hashlib, json, pathlib, sys, time
p = pathlib.Path(__file__).resolve()
mode = (p.parent / 'sender-mode').read_text().strip()
if mode == 'delay':
    time.sleep(0.1)
raw = sys.stdin.buffer.read()
req = json.loads(raw)
(p.parent / 'sender-argv.json').write_text(json.dumps(sys.argv[1:]))
canon = json.dumps(req, sort_keys=True, ensure_ascii=True, separators=(',', ':')).encode()
if mode == 'oversize':
    sys.stdout.write('x' * 65537)
    raise SystemExit(0)
if req['verb'] == 'submit':
    outcome = {'state':'active', 'task':req['payload']['task'],
               'submit':hashlib.sha256(canon).hexdigest()}
elif req['verb'] == 'result':
    report = 'Invented bounded sender result.\n'
    outcome = {'state':'complete', 'task':req['payload']['task'],
               'submit':req['payload']['submit'], 'generation':'synthetic-generation-1',
               'sha256':hashlib.sha256(report.encode()).hexdigest(), 'report':report}
else:
    outcome = {'state':'unknown'}
if mode == 'wrong-task':
    outcome['task'] = 'sibling'
result = {'schema':'fm-account-task.v1', 'route':req['route'], 'epoch':req['epoch'],
          'operation':req['operation'], 'outcome':outcome}
print(json.dumps(result, sort_keys=True, separators=(',', ':')))
'''.replace('PYTHON', PYTHON)


STUB = r'''#!PYTHON
import json, os, pathlib, signal, sys
p = pathlib.Path(__file__)
a = p.parents[1] if p.parent.name == 'tools' else p.parents[2]
f = json.loads((a / 'fixture.json').read_text())
name = p.name
args = sys.argv[1:]
home = pathlib.Path(os.environ['FM_HOME'])
if name == 'tmux':
    if args[-2:] == ['show-environment', '-g']:
        print('NONSECRET=fixture')
    elif 'display-message' in args:
        target = args[args.index('-t') + 1]
        if (a / 'runtime-drift').exists() or target != '=' + f['session'] + ':':
            print('wrong-session')
        else:
            print(str(f['pid']) + '\t' + f['session'] + '\t' + f['socket'])
    elif 'has-session' in args:
        sys.exit(1 if (a / 'missing-session').exists() else 0)
    else:
        sys.exit(98)
    sys.exit(0)
if name == 'pi':
    sys.exit(0)
with (a / 'calls.jsonl').open('a') as log:
    log.write(json.dumps({'name':name, 'args':args, 'uid':os.getuid(),
                         'home':os.environ.get('HOME'), 'fm_home':os.environ.get('FM_HOME'),
                         'secret':os.environ.get('SYNTHETIC_SECRET'),
                         'agent':os.environ.get('SSH_AUTH_SOCK'),
                         'node':os.environ.get('NODE_OPTIONS'),
                         'bash':os.environ.get('BASH_ENV'),
                         'parent':os.environ.get('FM_PUBLIC_FOLLOWUP_PRIMARY_HOME'),
                         'workspace':os.environ.get('FM_ACCOUNT_TASK_WORKSPACE_ROOT')}) + '\n')
if name == 'fm-brief.sh':
    folder = home / 'data' / args[0]
    folder.mkdir(mode=0o700)
    (folder / 'brief.md').write_text('## Captain\'s intent\n{TASK}\n## Firstmate spec\n{FIRSTMATE_SPEC}\n')
elif name == 'fm-spawn.sh':
    task, project = args[:2]
    scout = '--scout' in args
    if scout and ('--mode' in args or '--yolo' in args):
        sys.exit(90)
    if not scout and not ('--mode' in args and '--yolo' in args):
        sys.exit(91)
    if (a / 'crash-before-meta').exists():
        os.kill(os.getppid(), signal.SIGKILL)
        sys.exit(0)
    worktree = a / 'workspaces' / task
    worktree.mkdir(mode=0o700)
    meta = {'harness':'pi', 'kind':'scout' if scout else 'ship',
            'window': f['session'] + ':fm-' + task, 'worktree':str(worktree),
            'spawn_gen':'synthetic-generation-1', 'project':project}
    (home / 'state' / (task + '.meta')).write_text(''.join(k+'='+v+'\n' for k,v in meta.items()))
    (a / 'worker-launch-delivered').write_text(task)
    if (a / 'crash-before-commit').exists():
        os.kill(os.getppid(), signal.SIGKILL)
        sys.exit(0)
    meta['account_task_commit'] = meta['spawn_gen']
    (home / 'state' / (task + '.meta')).write_text(''.join(k+'='+v+'\n' for k,v in meta.items()))
    if (a / 'crash-after-commit').exists():
        os.kill(os.getppid(), signal.SIGKILL)
        sys.exit(0)
'''.replace('PYTHON', PYTHON)


def write(path, content, mode=0o600):
    path.write_text(content)
    path.chmod(mode)


def canon(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':')).encode()


class RouteTest(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.no-mistakes'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='account-route-test-', dir=scratch)
        self.a = Path(self.temp.name).resolve()
        self.a.chmod(0o700)
        self.home = self.a / 'home'
        self.code = self.a / 'code'
        self.tools = self.a / 'tools'
        for part in ('home', 'home/state', 'home/data', 'home/config', 'home/projects',
                     'home/projects/demo', 'home/projects/demo/.git', 'code', 'code/bin',
                     'code/.agents', 'code/.agents/skills',
                     'code/.agents/skills/captain-hold-lifecycle', 'code/.pi',
                     'tools', 'workspaces', 'runtime'):
            (self.a / part).mkdir(mode=0o700)
        self.script = self.code / 'bin/fm-account-task.py'
        shutil.copyfile(ROOT / 'bin/fm-account-task.py', self.script)
        self.script.chmod(0o600)
        for name in ('fm-tasks-axi.sh', 'fm-brief.sh', 'fm-spawn.sh', 'fm-send.sh', 'fm-control.sh'):
            write(self.code / 'bin' / name, STUB, 0o700)
        for name in ('bash', 'git', 'jq', 'pi', 'python3', 'tasks-axi', 'tmux', 'treehouse'):
            write(self.tools / name, STUB, 0o700)
        write(self.code / 'AGENTS.md', 'Synthetic worker contract.\n')
        write(self.code / 'CLAUDE.md', '@AGENTS.md\n')
        write(self.code / '.agents/skills/captain-hold-lifecycle/SKILL.md',
              'Synthetic completion contract.\n')
        write(self.home / 'config/launch-env-allowlist', '')
        write(self.home / 'projects/demo/.git/config', '[core]\nrepositoryformatversion = 0\n')
        self.sock = socket.socket(socket.AF_UNIX)
        self.socket_path = self.a / 'runtime/socket'
        # macOS Unix socket paths are short; use a descriptor-created socket at
        # a short relative path without changing anything outside this fixture.
        previous = os.getcwd()
        try:
            os.chdir(self.a / 'runtime')
            self.sock.bind('socket')
        finally:
            os.chdir(previous)
        self.socket_path.chmod(0o600)
        self.fixture = dict(pid=os.getpid(), session='isolated-tools', socket=str(self.socket_path))
        write(self.a / 'fixture.json', json.dumps(self.fixture))
        search = list(dict.fromkeys([str(self.tools), os.path.realpath('/usr/bin'), os.path.realpath('/bin')]))
        tools = {name: str(self.tools / name)
                 for name in ('bash', 'git', 'jq', 'pi', 'python3', 'tasks-axi', 'tmux', 'treehouse')}
        self.b = dict(schema='fm-account-route.v1', route='tools', epoch='a'*32,
                      user=pwd.getpwuid(os.getuid()).pw_name, uid=os.getuid(),
                      account_home=str(self.a), home=str(self.home),
                      code_root=str(self.code), workspace_root=str(self.a / 'workspaces'),
                      search_path=search, tools=tools, repositories={'demo':'demo'},
                      profile=dict(kind='scout', model='synthetic/model', effort='low'),
                      runtime=dict(socket=str(self.socket_path), session='isolated-tools', pid=os.getpid(),
                                   environment_sha256=hashlib.sha256(b'NONSECRET=fixture\n').hexdigest()),
                      guards={}, absent=[str(self.a / 'signal-canary')],
                      denied=[str(self.a / 'private-canary')], receipt='b'*64,
                      expires=int(time.time())+3600)
        write(self.a / 'private-canary', 'invented', 0o000)
        self.path = self.a / 'binding.json'
        self.pin()
        self.sequence = 0

    def tearDown(self):
        self.sock.close()
        canary = self.a / 'private-canary'
        if canary.exists():
            canary.chmod(0o600)
        self.temp.cleanup()

    def pin(self):
        paths = [self.code / 'bin', self.code / 'AGENTS.md', self.code / 'CLAUDE.md',
                 self.code / '.agents/skills/captain-hold-lifecycle/SKILL.md',
                 self.home / 'config',
                 *[Path(path) for path in self.b['tools'].values()],
                 self.home / 'projects/demo/.git/config']
        for path in paths:
            p = subprocess.run([PYTHON, '-I', str(self.script), 'digest', str(path)], capture_output=True)
            self.assertEqual(p.returncode, 0, p.stdout)
            self.b['guards'][str(path)] = p.stdout.decode().strip()
        write(self.path, json.dumps(self.b))

    def request(self, verb='submit', payload=None):
        self.sequence += 1
        if payload is None:
            payload = dict(task='sample', repository='demo', intent='Review invented public documentation only.')
        return dict(schema='fm-account-task.v1', route='tools', epoch='a'*32,
                    operation=f'{self.sequence:032x}', expires=int(time.time())+1800, verb=verb, payload=payload)

    def call(self, req, raw=None, env=None):
        environment = dict(os.environ)
        environment.update(SYNTHETIC_SECRET='invented-marker', SSH_AUTH_SOCK='/invented/agent',
                           NODE_OPTIONS='--invented', BASH_ENV='/invented/rc',
                           FM_PUBLIC_FOLLOWUP_PRIMARY_HOME='/invented/personal')
        if env:
            environment.update(env)
        p = subprocess.run([PYTHON, '-I', str(self.script), 'receive', str(self.path)],
                           input=raw if raw is not None else canon(req), capture_output=True, env=environment)
        self.assertEqual(p.stderr, b'')
        return p.returncode, json.loads(p.stdout) if p.stdout else None

    def accepted(self):
        req = self.request()
        rc, result = self.call(req)
        self.assertEqual(rc, 0, result)
        self.assertEqual(result['outcome']['state'], 'active', result)
        return req, result['outcome']['submit']

    def calls(self, name=None):
        path = self.a / 'calls.jsonl'
        rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [row for row in rows if name is None or row['name'] == name]

    def task(self):
        ledger = json.loads((self.home / 'state/account-route/ledger.json').read_text())
        return ledger['tasks']['sample']

    def follow(self, verb, submit, **extra):
        return self.request(verb, dict(task='sample', submit=submit, **extra))

    def test_handoff_environment_and_replay(self):
        req, submit = self.accepted()
        self.assertEqual(submit, hashlib.sha256(canon(req)).hexdigest())
        rc, repeated = self.call(req)
        self.assertEqual(rc, 0)
        self.assertEqual(repeated['outcome']['state'], 'active')
        self.assertEqual(len(self.calls('fm-spawn.sh')), 1)
        for row in self.calls():
            self.assertEqual(row['uid'], os.getuid())
            self.assertEqual(row['home'], str(self.a))
            self.assertEqual(row['fm_home'], str(self.home))
            for key in ('secret', 'agent', 'node', 'bash', 'parent'):
                self.assertIsNone(row[key])
            self.assertEqual(row['workspace'], str(self.a / 'workspaces'))
        self.assertFalse((self.home / 'data/captain-shared.md').exists())
        changed = copy.deepcopy(req)
        changed['payload']['intent'] = 'Different invented task.'
        rc, result = self.call(changed)
        self.assertEqual(rc, 78)
        self.assertEqual(result['refused'], 'operation-conflict')
        self.assertEqual(len(self.calls('fm-spawn.sh')), 1)

    def test_no_generic_authority_or_wrong_identity(self):
        for field, value in [('command', 'echo invented'), ('home', '/invented'),
                             ('callback', '/invented'), ('session', 'default'), ('path', '../x')]:
            req = self.request()
            req['payload'][field] = value
            self.assertEqual(self.call(req)[0], 78)
        for verb in ('repair', 'relaunch', 'delete', 'key', 'shell'):
            req = self.request(verb, {})
            self.assertEqual(self.call(req)[0], 78)
        for field, value in [('route', 'other'), ('epoch', 'c'*32), ('expires', 0)]:
            req = self.request()
            req[field] = value
            self.assertEqual(self.call(req)[0], 78)
        self.assertEqual(self.calls(), [])
        self.b['user'] = 'invented-other-account'
        write(self.path, json.dumps(self.b))
        self.assertEqual(self.call(self.request())[0], 78)
        self.assertEqual(self.calls(), [])
        self.b['user'] = pwd.getpwuid(os.getuid()).pw_name
        self.b['uid'] += 100
        write(self.path, json.dumps(self.b))
        self.assertEqual(self.call(self.request())[0], 78)
        self.assertEqual(self.calls(), [])

    def test_strict_input_and_entrypoint(self):
        for raw in (b'{"schema":1,"schema":2}', b'{"x":NaN}', b'\xff', b'{} {}', b' '*65537):
            self.assertEqual(self.call(None, raw=raw)[0], 78)
        self.assertEqual(self.call(self.request(), env={'SSH_ORIGINAL_COMMAND':'fm-remote-entrypoint.sh'})[0], 78)
        req = self.request()
        req['payload']['intent'] = 'x'*16385
        self.assertEqual(self.call(req)[0], 78)
        self.assertEqual(self.calls(), [])

    def test_inheritance_and_custody_refuse(self):
        write(self.home / 'data/captain-shared.md', 'invented personal marker')
        rc, result = self.call(self.request())
        self.assertEqual(rc, 78)
        self.assertEqual(result['refused'], 'route-drift-disabled')
        self.assertEqual(self.calls(), [])
        (self.home / 'data/captain-shared.md').unlink()
        self.assertEqual(self.call(self.request())[1]['refused'], 'route-disabled')

    def test_qualification_and_guard_drift_disable(self):
        _, submit = self.accepted()
        write(self.home / 'config/unapproved', 'invented drift')
        self.assertEqual(self.call(self.follow('status', submit))[1]['refused'], 'route-drift-disabled')
        (self.home / 'config/unapproved').unlink()
        self.assertEqual(self.call(self.request())[1]['refused'], 'route-disabled')
        self.assertEqual(len(self.calls('fm-spawn.sh')), 1)

    def test_pinned_executable_drift_disables(self):
        write(self.tools / 'pi', STUB + '\n# changed\n', 0o700)
        self.assertEqual(self.call(self.request())[1]['refused'], 'route-drift-disabled')
        self.assertEqual(self.calls(), [])

    def test_signal_and_private_canaries_refuse(self):
        write(self.a / 'signal-canary', 'invented')
        self.assertEqual(self.call(self.request())[1]['refused'], 'route-drift-disabled')
        self.assertEqual(self.calls(), [])

    def test_communications_artifacts_refuse(self):
        (self.home / 'state/x-inbox').mkdir()
        self.assertEqual(self.call(self.request())[1]['refused'], 'route-drift-disabled')
        self.assertEqual(self.calls(), [])

    def test_readable_denial_canary_refuse(self):
        (self.a / 'private-canary').chmod(0o600)
        self.assertEqual(self.call(self.request())[1]['refused'], 'route-drift-disabled')
        self.assertEqual(self.calls(), [])

    def test_symlink_and_hardlink_refuse(self):
        self.path.unlink()
        target = self.a / 'another-binding'
        write(target, json.dumps(self.b))
        self.path.symlink_to(target)
        self.assertEqual(self.call(self.request())[0], 78)
        self.path.unlink()
        os.link(target, self.path)
        self.assertEqual(self.call(self.request())[0], 78)
        self.assertEqual(self.calls(), [])

    def test_task_scoped_control_and_rollback(self):
        _, submit = self.accepted()
        local = self.task()['local']
        rc, result = self.call(self.request('disable', {}))
        self.assertEqual((rc, result['outcome']['state']), (0, 'disabled'))
        self.assertEqual(self.call(self.request())[1]['refused'], 'route-disabled')
        self.assertEqual(self.call(self.follow('steer', submit, text='new work'))[1]['refused'], 'route-disabled')
        req = self.follow('checkpoint', submit)
        self.assertEqual(self.call(req)[1]['outcome']['state'], 'recorded')
        self.assertEqual(self.call(req)[1]['outcome']['state'], 'recorded')
        self.assertEqual(len(self.calls('fm-send.sh')), 1)
        self.assertEqual(self.calls('fm-send.sh')[0]['args'][0], local)
        req = self.follow('stop', submit)
        self.assertEqual(self.call(req)[1]['outcome']['state'], 'stopped')
        self.call(req)
        self.assertEqual(self.calls('fm-control.sh')[0]['args'], [local, 'exit'])
        self.assertEqual(len(self.calls('fm-control.sh')), 1)
        self.assertTrue((self.home / 'state' / (local + '.meta')).exists())
        self.assertTrue((self.a / 'workspaces' / local).exists())

    def test_disable_remains_available_at_operation_limit(self):
        self.accepted()
        ledger_path = self.home / 'state/account-route/ledger.json'
        ledger = json.loads(ledger_path.read_text())
        while len(ledger['operations']) < 4096:
            value = len(ledger['operations']) + 1
            operation = f'{value:032x}'
            ledger['operations'].setdefault(operation,
                dict(digest=hashlib.sha256(operation.encode()).hexdigest(),
                     result={'state':'unknown'}))
        write(ledger_path, json.dumps(ledger))
        self.sequence = 5000
        rc, result = self.call(self.request('disable', {}))
        self.assertEqual((rc, result['outcome']['state']), (0, 'disabled'))
        after = json.loads(ledger_path.read_text())
        self.assertTrue(after['disabled'])
        self.assertEqual(len(after['operations']), 4096)

    def test_task_generation_and_native_steer_refuse(self):
        _, submit = self.accepted()
        for message in ('/quit', '$skill', ' \n/quit'):
            self.assertEqual(self.call(self.follow('steer', submit, text=message))[0], 78)
        local = self.task()['local']
        meta = self.home / 'state' / (local + '.meta')
        write(meta, meta.read_text().replace('synthetic-generation-1', 'another-generation'))
        self.assertEqual(self.call(self.follow('stop', submit))[1]['outcome']['state'], 'unknown')
        self.assertEqual(self.calls('fm-control.sh'), [])

    def test_runtime_drift_never_repairs(self):
        write(self.a / 'runtime-drift', 'invented')
        self.assertEqual(self.call(self.request())[1]['refused'], 'route-drift-disabled')
        self.assertEqual(self.calls(), [])

    def test_crash_before_meta_is_not_retried(self):
        write(self.a / 'crash-before-meta', 'invented')
        req = self.request()
        rc, result = self.call(req)
        self.assertLess(rc, 0)
        self.assertIsNone(result)
        self.assertEqual(self.call(req)[1]['outcome']['state'], 'unknown')
        self.assertEqual(self.call(self.request())[1]['refused'], 'route-disabled')
        self.assertEqual(len(self.calls('fm-spawn.sh')), 1)

    def test_crash_before_commit_refuses_adoption(self):
        write(self.a / 'crash-before-commit', 'invented')
        req = self.request()
        self.assertLess(self.call(req)[0], 0)
        self.assertEqual(self.call(req)[1]['outcome']['state'], 'unknown')
        submit = hashlib.sha256(canon(req)).hexdigest()
        outcome = self.call(self.follow('status', submit))[1]['outcome']
        self.assertEqual(outcome, dict(state='unknown'))
        self.assertEqual(self.task()['phase'], 'launching')
        self.assertIsNone(self.task()['binding'])
        self.assertEqual((self.a / 'worker-launch-delivered').read_text(), self.task()['local'])
        self.assertEqual(self.calls('fm-send.sh'), [])
        self.assertEqual(self.calls('fm-control.sh'), [])
        self.assertEqual(len(self.calls('fm-spawn.sh')), 1)

    def test_crash_after_commit_preserves_work(self):
        write(self.a / 'crash-after-commit', 'invented')
        req = self.request()
        self.assertLess(self.call(req)[0], 0)
        self.assertEqual(self.call(req)[1]['outcome']['state'], 'unknown')
        self.assertEqual(len(self.calls('fm-spawn.sh')), 1)
        self.assertTrue(list((self.home / 'state').glob('acct-*.meta')))
        self.assertTrue(list((self.a / 'workspaces').iterdir()))

        submit = hashlib.sha256(canon(req)).hexdigest()
        status = self.call(self.follow('status', submit))[1]['outcome']
        self.assertEqual(status, dict(state='accepted', task='sample', submit=submit))
        self.assertEqual(self.task()['phase'], 'active')
        self.assertEqual(self.task()['binding']['spawn_gen'], 'synthetic-generation-1')
        folder = self.home / 'data' / self.task()['local']
        report = 'Invented recovered task result.\n'
        sha = hashlib.sha256(report.encode()).hexdigest()
        write(folder / 'report.md', report)
        write(folder / 'result.json', json.dumps(dict(schema='fm-account-result.v1', epoch='a'*32,
              task='sample', submit=submit, uid=os.getuid(), report_sha256=sha)))
        result = self.call(self.follow('result', submit))[1]['outcome']
        self.assertEqual(result['state'], 'complete')
        self.assertEqual(result['submit'], submit)
        self.assertEqual(result['generation'], 'synthetic-generation-1')
        self.assertEqual(result['report'], report)
        self.assertEqual(self.call(self.follow('checkpoint', submit))[1]['outcome']['state'], 'recorded')
        self.assertEqual(self.call(self.follow('stop', submit))[1]['outcome']['state'], 'stopped')
        local = self.task()['local']
        self.assertEqual(self.calls('fm-send.sh')[0]['args'][0], local)
        self.assertEqual(self.calls('fm-control.sh')[0]['args'], [local, 'exit'])
        self.assertEqual(len(self.calls('fm-spawn.sh')), 1)

    def test_crash_after_mismatched_meta_refuses_adoption(self):
        write(self.a / 'crash-after-commit', 'invented')
        req = self.request()
        self.assertLess(self.call(req)[0], 0)
        submit = hashlib.sha256(canon(req)).hexdigest()
        local = self.task()['local']
        meta = self.home / 'state' / (local + '.meta')
        write(meta, meta.read_text().replace(
              'account_task_commit=synthetic-generation-1',
              'account_task_commit=synthetic-generation-other'))

        outcome = self.call(self.follow('status', submit))[1]['outcome']
        self.assertEqual(outcome, dict(state='unknown'))
        self.assertEqual(self.task()['phase'], 'launching')
        self.assertIsNone(self.task()['binding'])
        self.assertEqual(self.call(self.follow('checkpoint', submit))[1]['outcome'],
                         dict(state='unknown'))
        self.assertEqual(self.call(self.follow('stop', submit))[1]['outcome'],
                         dict(state='unknown'))
        self.assertEqual(self.calls('fm-send.sh'), [])
        self.assertEqual(self.calls('fm-control.sh'), [])
        self.assertEqual(len(self.calls('fm-spawn.sh')), 1)

    def test_incomplete_and_complete_results(self):
        _, submit = self.accepted()
        self.assertEqual(self.call(self.follow('result', submit))[1]['outcome']['state'], 'incomplete')
        folder = self.home / 'data' / self.task()['local']
        report = 'Invented public documentation result.\n'
        sha = hashlib.sha256(report.encode()).hexdigest()
        receipt = dict(schema='fm-account-result.v1', epoch='a'*32, task='sample', submit=submit,
                       uid=os.getuid(), report_sha256=sha)
        write(folder / 'report.md', report)
        write(folder / 'result.json', json.dumps(dict(receipt, task='sibling')))
        self.assertEqual(self.call(self.follow('result', submit))[1]['outcome']['state'], 'incomplete')
        write(folder / 'result.json', json.dumps(receipt))
        outcome = self.call(self.follow('result', submit))[1]['outcome']
        self.assertEqual(outcome['state'], 'complete')
        self.assertEqual(outcome['report'], report)
        self.assertEqual(outcome['sha256'], sha)
        self.assertEqual(outcome['submit'], submit)
        self.assertEqual(outcome['generation'], 'synthetic-generation-1')
        replacement = 'Rewritten result that must never replace the first receipt.\n'
        write(folder / 'report.md', replacement)
        write(folder / 'result.json', json.dumps(dict(receipt,
              report_sha256=hashlib.sha256(replacement.encode()).hexdigest())))
        sealed = self.call(self.follow('result', submit))[1]['outcome']
        self.assertEqual(sealed, outcome)

    def test_ship_dispatch_uses_fixed_delivery_contract(self):
        for name in ('gh-axi', 'no-mistakes'):
            write(self.tools / name, STUB, 0o700)
            self.b['tools'][name] = str(self.tools / name)
        self.b['profile']['kind'] = 'ship'
        self.pin()
        self.accepted()
        args = self.calls('fm-spawn.sh')[0]['args']
        self.assertEqual(args[args.index('--mode')+1], 'no-mistakes')
        self.assertEqual(args[args.index('--yolo')+1], 'off')
        self.assertNotIn('--secondmate', args)


class SenderTest(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.no-mistakes'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='account-sender-test-', dir=scratch)
        self.a = Path(self.temp.name).resolve()
        self.a.chmod(0o700)
        self.ssh = self.a / 'ssh'
        write(self.ssh, SSH_STUB, 0o700)
        self.sender = self.a / 'sender.json'
        write(self.sender, json.dumps(dict(schema='fm-account-sender.v1', route='tools',
              epoch='a'*32, host='tools-local', ssh=str(self.ssh))))
        self.sequence = 0

    def tearDown(self):
        self.temp.cleanup()

    def request(self, verb='submit', payload=None):
        self.sequence += 1
        if payload is None:
            payload = dict(task='sample', repository='demo',
                           intent='Review invented public documentation only.')
        return dict(schema='fm-account-task.v1', route='tools', epoch='a'*32,
                    operation=f'{self.sequence:032x}', expires=int(time.time())+1800,
                    verb=verb, payload=payload)

    def call(self, req, mode='delay'):
        write(self.a / 'sender-mode', mode)
        return subprocess.run([PYTHON, '-I', str(ROOT / 'bin/fm-account-task.py'),
                               'send', str(self.sender)], input=canon(req), capture_output=True)

    def test_sender_uses_restricted_ssh_and_validates_bound_response(self):
        req = self.request()
        result = self.call(req)
        self.assertEqual(result.returncode, 0, result.stdout)
        response = json.loads(result.stdout)
        self.assertEqual(response['outcome']['submit'], hashlib.sha256(canon(req)).hexdigest())
        argv = json.loads((self.a / 'sender-argv.json').read_text())
        self.assertIn('ForwardAgent=no', argv)
        self.assertIn('ClearAllForwardings=yes', argv)
        self.assertEqual(argv[-2:], ['tools-local', 'fm-account-task-v1'])

        follow = self.request('result', dict(task='sample', submit='c'*64))
        complete = self.call(follow)
        self.assertEqual(complete.returncode, 0, complete.stdout)
        self.assertEqual(json.loads(complete.stdout)['outcome']['state'], 'complete')
        bad = self.call(follow, 'wrong-task')
        self.assertEqual(bad.returncode, 78)
        self.assertEqual(json.loads(bad.stdout)['refused'], 'result-binding-mismatch')

    def test_sender_bounds_transport_output(self):
        result = self.call(self.request(), 'oversize')
        self.assertEqual(result.returncode, 78)
        self.assertEqual(json.loads(result.stdout)['refused'], 'transport-unknown')


if __name__ == '__main__':
    unittest.main()
