"""Behavior tests with real inert children; no OMP is imported or executed."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'bin' / 'omp-kepler' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


controller = load('controller')
boundary = load('fs_boundary')
signer = load('record_signer')


class Filesystem(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        (self.root / 'a.txt').write_text('alpha beta\n')

    def tearDown(self):
        self.temp.cleanup()

    def test_confined_mutations_and_changed_target(self):
        args = {'operation': 'edit', 'path': 'a.txt', 'oldText': 'alpha', 'newText': 'omega'}
        preview = boundary.preview(str(self.root), args)[0]
        (self.root / 'a.txt').write_text('alpha changed\n')
        with self.assertRaises(ValueError):
            boundary.execute(str(self.root), args, preview)
        self.assertEqual((self.root / 'a.txt').read_text(), 'alpha changed\n')
        preview = boundary.preview(str(self.root), args)[0]
        self.assertEqual(boundary.execute(str(self.root), args, preview), 'mutation_applied')
        args = {'operation': 'write', 'path': 'new.txt', 'content': 'new'}
        preview = boundary.preview(str(self.root), args)[0]
        self.assertEqual(boundary.execute(str(self.root), args, preview), 'mutation_applied')
        with self.assertRaises(ValueError):
            boundary.execute(str(self.root), args, preview)

    def test_paths_symlinks_links_fifo_and_bounds(self):
        for path in ('/tmp/foreign', '../foreign', 'x/../a', '.git/config', '.env.local', '.codex/auth.json', 'state/control', 'config/key', 'a//b'):
            with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                boundary.preview(str(self.root), {'operation': 'read', 'path': path})
        outside = self.root.parent / (self.root.name + '-outside')
        outside.write_text('outside')
        try:
            (self.root / 'symlink').symlink_to(outside)
            os.link(outside, self.root / 'hardlink')
            (self.root / 'alias').symlink_to(self.root, target_is_directory=True)
            os.mkfifo(self.root / 'fifo')
            (self.root / 'big').write_bytes(b'x' * 65537)
            for path in ('symlink', 'hardlink', 'alias/new', 'fifo', 'big'):
                with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                    boundary.preview(str(self.root), {'operation': 'write', 'path': path, 'content': 'bad'})
            self.assertEqual(outside.read_text(), 'outside')
            self.assertEqual(boundary.grep(str(self.root), '.', 'alpha'), 'a.txt:1:alpha beta')
        finally:
            outside.unlink()

    def test_staged_short_zero_and_failing_writes_preserve_target(self):
        args = {'operation': 'write', 'path': 'a.txt', 'content': 'complete replacement'}
        original = (self.root / 'a.txt').read_bytes()
        expected = boundary.preview(str(self.root), args)[0]
        with self.assertRaises(ValueError):
            boundary.execute(str(self.root), args, expected, lambda fd, data: 0)
        self.assertEqual((self.root / 'a.txt').read_bytes(), original)
        calls = [0]
        def failing(fd, data):
            calls[0] += 1
            if calls[0] == 2:
                raise OSError('inert_write_failure')
            return os.write(fd, data[:2])
        with self.assertRaises(OSError):
            boundary.execute(str(self.root), args, expected, failing)
        self.assertEqual((self.root / 'a.txt').read_bytes(), original)
        with self.assertRaises(ValueError):
            boundary.execute(str(self.root), args, expected, lambda fd, data: len(data))
        self.assertEqual((self.root / 'a.txt').read_bytes(), original)
        boundary.execute(str(self.root), args, expected, lambda fd, data: os.write(fd, data[:2]))
        self.assertEqual((self.root / 'a.txt').read_text(), args['content'])
        self.assertFalse(any(p.name.startswith('.fm-write-') for p in self.root.iterdir()))
        expected = boundary.preview(str(self.root), args)[0]
        def changed_target(fd, data):
            (self.root / 'a.txt').write_text('foreign fixture change')
            return os.write(fd, data)
        with self.assertRaises(ValueError):
            boundary.execute(str(self.root), args, expected, changed_target)
        self.assertEqual((self.root / 'a.txt').read_text(), 'foreign fixture change')
        missing = {'operation': 'write', 'path': 'missing.txt', 'content': 'complete'}
        with self.assertRaises(ValueError):
            boundary.execute(str(self.root), missing, boundary.preview(str(self.root), missing)[0], lambda fd, data: 0)
        self.assertFalse((self.root / 'missing.txt').exists())


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fm-omp-inert-')
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def run_child(self, body, seconds=2):
        script = self.root / 'inert.py'
        script.write_text(body)
        return controller.supervise([sys.executable, '-I', str(script)], self.root / 'state',
                                    time.time() + seconds, controller.clean_env(self.home))

    def test_continuation_terminal_and_reaped(self):
        record = self.run_child('print(\'{"type":"agent_start"}\',flush=True)\nprint(\'{"type":"agent_end","isTerminal":false}\',flush=True)\nprint(\'{"type":"agent_end","isTerminal":true}\',flush=True)\nprint(\'{"type":"worker_result","task":"inert","stopReason":"stop","text":"inert fixture"}\',flush=True)\n')
        self.assertEqual(record['state'], 'completed')
        self.assertTrue(record['reaped'])
        self.assertGreater(record['sequence'], 2)
        self.assertIsNone(controller.identity(record['pid']))

    def test_quiet_exit_is_failure(self):
        record = self.run_child('pass\n')
        self.assertEqual(record['state'], 'failed')
        self.assertFalse(record['terminalReceipt'])

    def test_stalled_input_cannot_block_watchdog_deadline(self):
        script = self.root / 'inert.py'
        script.write_text('import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(30)\n')
        payload = {'capsuleHash': 'inert', 'padding': 'x' * 100000,
                   'capsule': {'task': 'ATX-2170', 'sourceHashes': {}, 'head': 'inert', 'worktree': str(self.root),
                               'cockpit': 'kepler', 'keplerTaskId': None, 'keplerWorktreeId': None}}
        begin = time.monotonic()
        record = controller.supervise([sys.executable, '-I', str(script)], self.root / 'state',
                                      time.time()+.2, controller.clean_env(self.home), payload=payload)
        self.assertEqual(record['state'], 'expired')
        self.assertTrue(record['reaped'])
        self.assertLess(time.monotonic()-begin, 2)

    def test_wrong_extension_event_is_failure(self):
        record = self.run_child('print(\'{"type":"agent_end","willContinue":false}\',flush=True)\nimport time;time.sleep(2)\n')
        self.assertEqual(record['state'], 'invalid-receipt')
        self.assertTrue(record['reaped'])

    def test_malformed_receipts_are_durably_failed_and_reaped(self):
        for index, event in enumerate(([], None, 4, 'scalar', {}, {'type': []}, {'type': 'unknown'})):
            with self.subTest(event=event):
                self.root.joinpath('state').mkdir(exist_ok=True)
                record = self.run_child(f'print({json.dumps(json.dumps(event))},flush=True)\nimport time;time.sleep(2)\n')
                self.assertEqual(record['state'], 'invalid-receipt')
                durable = json.loads((self.root / 'state/receipt.json').read_text())
                self.assertTrue(durable['reaped'])
                self.assertIsNotNone(durable['exitCode'])
                (self.root / 'state/receipt.json').unlink()

    def test_exceptional_watchdog_finalizes_failed_receipt(self):
        original = controller.owned_atomic
        calls = [0]
        def fault(path, value):
            calls[0] += 1
            if calls[0] == 2:
                raise RuntimeError('inert_marker_fault')
            return original(path, value)
        controller.owned_atomic = fault
        try:
            with self.assertRaises(RuntimeError):
                controller._supervise(['/bin/sleep', '2'], self.root / 'state', time.time()+2, controller.clean_env(self.home))
        finally:
            controller.owned_atomic = original
        durable = json.loads((self.root / 'state/receipt.json').read_text())
        self.assertEqual(durable['state'], 'failed')
        self.assertTrue(durable['reaped'])
        self.assertIsNone(controller.identity(durable['pid']))

    def test_expiry_kills_stalled_event_loop_and_descendants(self):
        child_pid = self.root / 'descendant.pid'
        body = ('import subprocess,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
                f'p=subprocess.Popen(["/bin/sleep","30"]);open({str(child_pid)!r},"w").write(str(p.pid))\n'
                'while True: time.sleep(1)\n')
        begin = time.monotonic()
        record = self.run_child(body, .2)
        self.assertEqual(record['state'], 'expired')
        self.assertTrue(record['reaped'])
        self.assertLess(time.monotonic() - begin, 2)
        descendant = int(child_pid.read_text())
        # A zombie is dead, pending its OS init reaper; never a live helper.
        status = subprocess.run(['ps', '-p', str(descendant), '-o', 'stat='], stdout=subprocess.PIPE).stdout.decode().strip()
        self.assertTrue(not status or status.startswith('Z'))

    def test_controller_sigkill_independent_watchdog_reaps(self):
        script = self.root / 'inert.py'
        script.write_text('import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(30)\n')
        runner = self.root / 'runner.py'
        runner.write_text(f'import sys;sys.path.insert(0,{str(ROOT / "bin" / "omp-kepler")!r})\nimport controller,time\nfrom pathlib import Path\ncontroller.supervise([{sys.executable!r},"-I",{str(script)!r}],{str(self.root / "state")!r},time.time()+20,controller.clean_env(Path({str(self.home)!r})))\n')
        parent = subprocess.Popen([sys.executable, '-I', str(runner)])
        marker = self.root / 'state' / 'receipt.json'
        end = time.monotonic() + 3
        while not marker.exists() and time.monotonic() < end:
            time.sleep(.02)
        self.assertTrue(marker.exists())
        record = json.loads(marker.read_text())
        os.kill(parent.pid, signal.SIGKILL)
        parent.wait(timeout=2)
        while not json.loads(marker.read_text())['reaped'] and time.monotonic() < end:
            time.sleep(.03)
        final = json.loads(marker.read_text())
        self.assertEqual(final['state'], 'controller-lost')
        self.assertTrue(final['reaped'])
        self.assertIsNone(controller.identity(record['pid']))

    def test_interrupt_exact_identity_and_status_reconnect(self):
        runner = self.root / 'runner.py'
        script = self.root / 'inert.py'
        script.write_text('import time\nprint(\'{"type":"agent_start"}\',flush=True)\ntime.sleep(30)\n')
        runner.write_text(f'import sys;sys.path.insert(0,{str(ROOT / "bin" / "omp-kepler")!r})\nimport controller,time\nfrom pathlib import Path\ncontroller.supervise([{sys.executable!r},"-I",{str(script)!r}],{str(self.root / "state")!r},time.time()+20,controller.clean_env(Path({str(self.home)!r})))\n')
        parent = subprocess.Popen([sys.executable, '-I', str(runner)])
        marker = self.root / 'state' / 'receipt.json'
        end = time.monotonic() + 3
        while not marker.exists() and time.monotonic() < end:
            time.sleep(.02)
        record = json.loads(marker.read_text())
        self.assertEqual(controller.identity(record['pid']), record['start'])
        for request, expected in ((b'wrong:interrupt', b'refused'), (record['owner'].encode()+b':interrupt', b'accepted')):
            connection = socket.socket(socket.AF_UNIX)
            connection.connect(str(self.root / 'state' / 'control.sock'))
            connection.sendall(request)
            self.assertEqual(connection.recv(1024), expected)
            connection.close()
        parent.wait(timeout=3)
        final = json.loads(marker.read_text())
        self.assertEqual(final['state'], 'interrupted')
        self.assertTrue(final['reaped'])

    def test_cross_task_worktree_lease_and_failure_cleanup(self):
        lease = self.root / 'leases' / 'same-worktree'
        lease.mkdir(parents=True)
        controller.atomic(lease / 'owner.json', {'owner': 'foreign'})
        with self.assertRaises(FileExistsError):
            controller._supervise(['/bin/sleep', '1'], self.root / 'state', time.time()+2,
                                  controller.clean_env(self.home), lease=lease)
        self.assertEqual(json.loads((lease / 'owner.json').read_text())['owner'], 'foreign')
        (lease / 'owner.json').unlink()
        lease.rmdir()
        with self.assertRaises(FileNotFoundError):
            controller._supervise(['/does-not-exist-inert'], self.root / 'state', time.time()+2,
                                  controller.clean_env(self.home), lease=lease)
        self.assertFalse(lease.exists())
        self.assertFalse((self.root / 'state' / 'control.sock').exists())

    def test_foreign_marker_is_preserved_on_cleanup(self):
        runner = self.root / 'runner.py'
        runner.write_text(f'import sys;sys.path.insert(0,{str(ROOT / "bin" / "omp-kepler")!r})\nimport controller,time\nfrom pathlib import Path\ncontroller.supervise(["/bin/sleep","30"],{str(self.root / "state")!r},time.time()+20,controller.clean_env(Path({str(self.home)!r})))\n')
        parent = subprocess.Popen([sys.executable, '-I', str(runner)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        marker = self.root / 'state' / 'receipt.json'
        end = time.monotonic() + 3
        while not marker.exists() and time.monotonic() < end:
            time.sleep(.02)
        record = json.loads(marker.read_text())
        controller.atomic(marker, {'owner': 'foreign', 'preserve': True})
        parent.wait(timeout=3)
        self.assertEqual(json.loads(marker.read_text()), {'owner': 'foreign', 'preserve': True})
        self.assertIsNone(controller.identity(record['pid']))


class Entry(unittest.TestCase):
    def valid_capsule_host(self, root):
        task = 'ATX-2170'
        worktree = root / 'worktree'
        worktree.mkdir()
        (worktree / 'README.md').write_text('fixture\n')
        subprocess.run(['/usr/bin/git', 'init', '-q', str(worktree)], check=True)
        subprocess.run(['/usr/bin/git', '-C', str(worktree), 'add', 'README.md'], check=True)
        subprocess.run(['/usr/bin/git', '-C', str(worktree), '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
                        'commit', '-q', '-m', 'fixture'], check=True)
        head = subprocess.run(['/usr/bin/git', '-C', str(worktree), 'rev-parse', 'HEAD'],
                              stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        runtime_root = root / 'runtime'
        modules = runtime_root / 'node_modules'
        package = modules / '@oh-my-pi/pi-coding-agent/package.json'
        package.parent.mkdir(parents=True)
        package.write_text('{"version":"18.1.11"}\n')
        bun = runtime_root / 'bun'
        bun.write_text('#!/bin/sh\n')
        os.chmod(bun, 0o755)
        runtime = {'bun': str(bun), 'bunVersion': '1.4.0', 'bunSha256': controller.sha(bun),
                   'sdkVersion': '18.1.11', 'nodeModules': str(modules),
                   'nodeModulesSha256': controller.tree_digest(modules)}
        source = {p.name: controller.sha(p) for p in (ROOT / 'bin/omp-kepler').iterdir() if p.suffix in ('.py', '.ts')}
        source['fm-omp-kepler.sh'] = controller.sha(ROOT / 'bin/fm-omp-kepler.sh')
        now = int(time.time())
        capsule = {'version': 1, 'task': task, 'issue': 'ATX-2170', 'scope': 'command-center-pilot',
                   'role': 'scout', 'backend': 'orca', 'cockpit': 'kepler', 'launchSurface': 'manual-terminal',
                   'supervisor': 'firstmate', 'keplerTaskId': None, 'keplerWorktreeId': None,
                   'tools': ['read', 'grep'], 'authority': 'owner-approved-activation', 'ownerAction': 'ATX-1758-approved',
                   'gates': {'provider': True, 'installation': False, 'login': False, 'merge': False, 'production': False},
                   'issuedAt': now - 1, 'deadline': now + 300,
                   'credit': {'included': True, 'overage': 0, 'validUntil': now + 300},
                   'model': {'provider': 'fixture', 'id': 'fixture-model', 'api': 'openai-completions',
                             'baseUrl': 'https://example.invalid/v1'},
                   'fallback': False, 'brief': 'inert', 'worktree': str(worktree), 'head': head,
                   'runtime': runtime, 'sourceHashes': source, 'credentialFile': str(root / 'credential')}
        owner = root / 'owner.pub'
        owner.write_text('fixture-public-key')
        host = {'issue': 'ATX-2170', 'scope': 'command-center-pilot', 'task': task,
                'workerAccount': {'name': 'fm-omp-worker', 'uid': 65533, 'gid': 65533},
                'allowedWorktrees': [str(worktree)], 'ownerPublicKey': str(owner),
                'ownerPublicKeySha256': controller.sha(owner), 'stateRoot': str(root / 'state'),
                'capsuleRoot': str(root / 'capsules'), 'runtime': runtime, 'sourceHashes': source}
        (root / 'state').mkdir()
        (root / 'capsules').mkdir()
        (root / 'credential').write_text('fixture')
        return capsule, host, task, now

    def test_neutral_discovery_refuses_another_repo_and_ambient_sources(self):
        with tempfile.TemporaryDirectory(prefix='fm-omp-ancestry-') as directory:
            root = Path(directory).resolve()
            bootstrap = root / 'state/task/bootstrap'
            bootstrap.mkdir(parents=True)
            controller.neutral_discovery_root(bootstrap)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'WATCHDOG.md').write_text('@import outside-secret-fixture')
            (root / 'WATCHDOG.yml').write_text('instructions: "@import outside-secret-fixture"')
            (root / '.omp').mkdir()
            (root / '.omp/settings.yml').write_text('extensions: [hostile-fixture]')
            with self.assertRaisesRegex(ValueError, 'ambient_startup_discovery_refused'):
                controller.neutral_discovery_root(bootstrap)
            assigned = root.parent / (root.name + '-assigned')
            assigned.mkdir()
            try:
                capsule = {'version': 1, 'task': 'ATX-2170', 'issue': 'ATX-2170', 'scope': 'command-center-pilot',
                           'role': 'scout', 'backend': 'orca', 'cockpit': 'kepler', 'launchSurface': 'manual-terminal',
                           'supervisor': 'firstmate', 'keplerTaskId': None, 'keplerWorktreeId': None,
                           'tools': ['read', 'grep'], 'authority': 'owner-approved-activation', 'ownerAction': 'ATX-1758-approved',
                           'gates': {'provider': True, 'installation': False, 'login': False, 'merge': False, 'production': False},
                           'issuedAt': 100, 'deadline': 200, 'credit': {'included': True, 'overage': 0, 'validUntil': 200},
                           'model': {'provider': 'fixture', 'id': 'fixture', 'api': 'fixture', 'baseUrl': 'https://example.invalid'},
                           'fallback': False, 'brief': 'inert', 'worktree': str(assigned)}
                host = {'issue': 'ATX-2170', 'scope': 'command-center-pilot', 'task': 'ATX-2170',
                        'allowedWorktrees': [str(assigned)], 'stateRoot': str(root / 'state'),
                        'capsuleRoot': str(root / 'capsules'), 'ownerPublicKey': str(root / 'owner.pub'),
                        'runtime': {'bun': str(root / 'runtime/bun'), 'nodeModules': str(root / 'runtime/node_modules')}}
                with self.assertRaisesRegex(ValueError, 'ambient_startup_discovery_refused'):
                    controller.validate(capsule, host, 'ATX-2170', 101)
            finally:
                assigned.rmdir()

    def test_validate_rejects_relative_host_paths_before_effects(self):
        with tempfile.TemporaryDirectory(prefix='fm-host-paths-') as directory:
            root = Path(directory).resolve()
            capsule, host, task, now = self.valid_capsule_host(root)
            fake = root / 'fake-bin'
            fake.mkdir()
            marker = root / 'ambient-git-ran'
            git = fake / 'git'
            git.write_text(f'#!/bin/sh\n: > {str(marker)!r}\nexit 99\n')
            os.chmod(git, 0o755)
            original_path = os.environ.get('PATH', '')
            try:
                os.environ['PATH'] = str(fake) + os.pathsep + original_path
                for mutate in (
                    lambda h, c: h.update(stateRoot='state'),
                    lambda h, c: h.update(capsuleRoot='capsules'),
                    lambda h, c: h.update(allowedWorktrees=['worktree']),
                    lambda h, c: h['runtime'].update(bun='runtime/bun'),
                    lambda h, c: h['runtime'].update(nodeModules='runtime/node_modules'),
                    lambda h, c: c.update(credentialFile='credential'),
                ):
                    changed_host = json.loads(json.dumps(host))
                    changed_capsule = json.loads(json.dumps(capsule))
                    mutate(changed_host, changed_capsule)
                    with self.subTest(host=changed_host, credential=changed_capsule.get('credentialFile')):
                        with self.assertRaisesRegex(ValueError, 'canonical_.*path_required'):
                            controller.validate(changed_capsule, changed_host, task, now)
                self.assertFalse(marker.exists())
            finally:
                os.environ['PATH'] = original_path

    def test_validate_uses_fixed_git_and_sanitized_environment(self):
        with tempfile.TemporaryDirectory(prefix='fm-fixed-git-') as directory:
            root = Path(directory).resolve()
            capsule, host, task, now = self.valid_capsule_host(root)
            fake = root / 'fake-bin'
            fake.mkdir()
            marker = root / 'ambient-git-ran'
            git = fake / 'git'
            git.write_text(f'#!/bin/sh\n: > {str(marker)!r}\nexit 99\n')
            os.chmod(git, 0o755)
            original_path = os.environ.get('PATH', '')
            original_git_config = os.environ.get('GIT_CONFIG_COUNT')
            try:
                os.environ['PATH'] = str(fake) + os.pathsep + original_path
                os.environ['GIT_CONFIG_COUNT'] = '1'
                self.assertEqual(controller.validate(capsule, host, task, now), root / 'state' / task)
                self.assertFalse(marker.exists())
            finally:
                os.environ['PATH'] = original_path
                if original_git_config is None:
                    os.environ.pop('GIT_CONFIG_COUNT', None)
                else:
                    os.environ['GIT_CONFIG_COUNT'] = original_git_config

    def test_validate_rejects_mutable_adapter_source_overlap(self):
        with tempfile.TemporaryDirectory(prefix='fm-source-overlap-') as directory:
            root = Path(directory).resolve()
            capsule, host, task, now = self.valid_capsule_host(root)
            capsule['worktree'] = str(ROOT)
            host['allowedWorktrees'] = [str(ROOT)]
            with self.assertRaisesRegex(ValueError, 'trusted_paths_inside_worker_scope'):
                controller.validate(capsule, host, task, now)

    def test_filesystem_boundary_refuses_mutable_helper_overlap(self):
        with self.assertRaisesRegex(ValueError, 'trusted_source_inside_worker_scope'):
            boundary.preview(str(ROOT / 'bin/omp-kepler'), {'operation': 'read', 'path': 'controller.py'})

    def test_finite_safe_canonical_boundaries(self):
        self.assertEqual(controller.canonical([1.0, -0.0]), b'[1,0]')
        for bad in (float('nan'), float('inf'), 2**53, '\ud800', {'\udfff': 1}):
            with self.assertRaises((ValueError, UnicodeError)):
                controller.canonical(bad)
    def test_registration_is_fixed_and_does_not_install(self):
        result = subprocess.run(['/bin/bash', str(ROOT / 'bin/fm-omp-kepler.sh'), 'registration', 'ATX-2170'], stdout=subprocess.PIPE, check=True)
        record = json.loads(result.stdout)
        self.assertEqual(record['kind'], 'terminal')
        self.assertEqual(record['args'], ['handoff', 'ATX-2170'])
        self.assertEqual(record['env'], {})
        self.assertTrue(record['command'].startswith('/'))

    def test_default_launch_refuses_without_trusted_host(self):
        # No trusted host is installed in test runs; no SDK can start.
        result = subprocess.run(['/bin/bash', str(ROOT / 'bin/fm-omp-kepler.sh'), 'launch', 'ATX-2170'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')

    def test_fixed_root_handoff_cannot_choose_account_or_command(self):
        host = {'task': 'ATX-2170', 'workerAccount': {'name': 'fm-omp-worker', 'uid': 65533, 'gid': 65533}}
        lookup = lambda name: SimpleNamespace(pw_uid=65533, pw_gid=65533) if name == 'fm-omp-worker' else None
        self.assertEqual(controller.handoff_command(host, 'ATX-2170', lookup),
                         ['/usr/sbin/runuser', '-u', 'fm-omp-worker', '--', '/bin/bash',
                          str(ROOT / 'bin/fm-omp-kepler.sh'), 'launch', 'ATX-2170'])
        for record in ({}, {'name': 'root', 'uid': 0, 'gid': 0}, {'name': 'foreign', 'uid': 65533, 'gid': 65533},
                       {'name': 'fm-omp-worker', 'uid': 1, 'gid': 1}):
            with self.assertRaises(ValueError):
                controller.handoff_command({**host, 'workerAccount': record}, 'ATX-2170', lookup)
        with self.assertRaises(ValueError):
            controller.handoff_command(host, 'ATX-2171', lookup)


class OwnerRecords(unittest.TestCase):
    def test_publish_refuses_relative_path_without_root_fallback(self):
        with tempfile.TemporaryDirectory(prefix='fm-owner-relative-') as directory:
            root = Path(directory).resolve()
            original = Path.cwd()
            try:
                os.chdir(root)
                with self.assertRaisesRegex(ValueError, 'canonical_publish_path_required'):
                    signer.publish(Path('capsules') / 'ATX-2170.json', {'fixture': True}, 0o644)
                self.assertFalse((root / 'ATX-2170.json').exists())
            finally:
                os.chdir(original)

    def test_publish_replaces_link_without_following_and_refuses_linked_parent(self):
        with tempfile.TemporaryDirectory(prefix='fm-owner-publish-fixture-') as directory:
            root = Path(directory).resolve()
            outside = root / 'outside'
            outside.write_text('preserve')
            target = root / 'receipt.json'
            target.symlink_to(outside)
            signer.publish(target, {'fixture': True}, 0o644)
            self.assertEqual(outside.read_text(), 'preserve')
            self.assertEqual(json.loads(target.read_text()), {'fixture': True})
            (root / 'alias').symlink_to(root, target_is_directory=True)
            with self.assertRaises((ValueError, OSError)):
                signer.publish(root / 'alias' / 'other.json', {'fixture': True}, 0o644)

    def test_mutation_producer_binds_exact_preview_and_credit(self):
        with tempfile.TemporaryDirectory(prefix='fm-owner-fixture-') as directory:
            root = str(Path(directory).resolve())
            args = {'operation': 'write', 'path': 'file.txt', 'content': 'fixture'}
            capsule = {'task': 'ATX-2170', 'role': 'crew', 'worktree': root, 'deadline': 200,
                       'model': {'provider': 'fixture', 'id': 'fixture'}}
            request = {'version': 1, 'task': 'ATX-2170', 'capsuleHash': 'fixture-hash', 'operation': 'write',
                       'arguments': args, 'preview': boundary.preview(root, args)[0], 'expiresAt': 130}
            signer.bind_mutation(request, capsule, 'fixture-hash', 100)
            with self.assertRaises(ValueError):
                signer.bind_mutation(request, capsule, 'foreign-hash', 100)
            (Path(root) / 'file.txt').write_text('changed')
            with self.assertRaises(ValueError):
                signer.bind_mutation(request, capsule, 'fixture-hash', 100)
            credit = {'version': 1, 'kind': 'verified-provider-credit', 'task': 'ATX-2170', 'capsuleHash': 'fixture-hash',
                      'provider': 'fixture', 'modelId': 'fixture', 'accountEvidenceRef': 'inert-account', 'usageEvidenceRef': 'inert-usage',
                      'included': True, 'overage': 0, 'observedAt': 99, 'validUntil': 130}
            signer.bind_credit(credit, capsule, 'fixture-hash', 100)
            for bad in ({**credit, 'overage': 1}, {**credit, 'observedAt': 1}, {**credit, 'provider': 'foreign'}):
                with self.assertRaises(ValueError):
                    signer.bind_credit(bad, capsule, 'fixture-hash', 100)

    def test_fixture_openssl_sign_verify_and_tamper(self):
        version = subprocess.run(['/usr/bin/openssl', 'version'], stdout=subprocess.PIPE, check=True).stdout
        if not version.startswith(b'OpenSSL 3'):
            self.skipTest('native Ed25519 producer proof requires OpenSSL 3; Linux proof must run this case')
        with tempfile.TemporaryDirectory(prefix='fm-owner-ed25519-fixture-') as directory:
            private, public = Path(directory) / 'fixture.key', Path(directory) / 'fixture.pub'
            subprocess.run(['/usr/bin/openssl', 'genpkey', '-algorithm', 'Ed25519', '-out', str(private)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.chmod(private, 0o600)
            subprocess.run(['/usr/bin/openssl', 'pkey', '-in', str(private), '-pubout', '-out', str(public)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            envelope = signer.sign_record({'inertFixture': True}, private)
            self.assertEqual(controller.verify_envelope(envelope, public), {'inertFixture': True})
            envelope['payload']['inertFixture'] = False
            with self.assertRaises(ValueError):
                controller.verify_envelope(envelope, public)


if __name__ == '__main__':
    unittest.main(verbosity=2)
