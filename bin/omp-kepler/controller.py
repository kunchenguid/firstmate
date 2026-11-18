"""Task-only Terminal controller and independent worker watchdog.

The fixed root-owned host record supplies runtime paths and an Ed25519 public
key. It is not a capsule-selectable signer. No credential value is printed.
State here is adapter-local; this does not write FM semantic busy records.
template owns the host/capsule wire skeleton; contract.ts owns signed credit
and mutation-receipt fields. Signature payload is sorted compact UTF-8 JSON.
Envelope is {"payload": <record>, "signature": <base64 Ed25519 signature>}.
Private keys stay with the separately authenticated FM owner broker, outside
worker-readable files. The root-owned public key is verification material.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import pwd
import re
import selectors
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

SOURCE = Path(__file__).resolve().parent
HOST = Path('/etc/firstmate/omp-kepler/host.json')
TASK_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')
GIT = '/usr/bin/git'
GIT_ENV = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'LC_ALL': 'C',
           'HOME': '/nonexistent', 'XDG_CONFIG_HOME': '/nonexistent',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
           'GIT_CONFIG_COUNT': '0', 'GIT_TERMINAL_PROMPT': '0'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def canonical_path(value, error):
    if not isinstance(value, str):
        raise ValueError(error)
    path = Path(value)
    if not path.is_absolute() or path.resolve() != path:
        raise ValueError(error)
    return path


def overlaps(left, right):
    left, right = Path(left).resolve(), Path(right).resolve()
    return left == right or left in right.parents or right in left.parents


def host_paths(host):
    runtime = host.get('runtime')
    if not isinstance(runtime, dict):
        raise ValueError('canonical_host_path_required')
    allowed = host.get('allowedWorktrees')
    if not isinstance(allowed, list) or not allowed:
        raise ValueError('canonical_host_path_required')
    return {'ownerPublicKey': canonical_path(host.get('ownerPublicKey'), 'canonical_host_path_required'),
            'stateRoot': canonical_path(host.get('stateRoot'), 'canonical_host_path_required'),
            'capsuleRoot': canonical_path(host.get('capsuleRoot'), 'canonical_host_path_required'),
            'allowedWorktrees': [canonical_path(path, 'canonical_host_path_required') for path in allowed],
            'runtime': {'bun': canonical_path(runtime.get('bun'), 'canonical_runtime_path_required'),
                        'nodeModules': canonical_path(runtime.get('nodeModules'), 'canonical_runtime_path_required')}}


def canonical(value):
    """Finite safe binary64 numbers use their exact non-exponent decimal value.

    Strings are valid Unicode; keys sort by UTF-16 units in both languages.
    Negative zero is zero. Values outside +/- (2**53-1) are unsupported.
    """
    def encode(item):
        if item is None:
            return 'null'
        if type(item) is bool:
            return 'true' if item else 'false'
        if type(item) in (int, float):
            if abs(item) > 2**53-1 or not math.isfinite(item):
                raise ValueError('finite_safe_number_required')
            numerator, denominator = float(item).as_integer_ratio()
            if denominator == 1:
                return str(numerator)
            places = denominator.bit_length()-1
            digits = str(abs(numerator) * 5**places).rjust(places+1, '0')
            return ('-' if numerator < 0 else '') + (digits[:-places] + '.' + digits[-places:]).rstrip('0').rstrip('.')
        if isinstance(item, str):
            item.encode('utf-8')  # Reject unpaired surrogates.
            return json.dumps(item, ensure_ascii=False)
        if type(item) is list:
            return '[' + ','.join(encode(v) for v in item) + ']'
        if type(item) is dict and all(isinstance(k, str) for k in item):
            keys = sorted(item, key=lambda k: k.encode('utf-16-be'))
            return '{' + ','.join(encode(k) + ':' + encode(item[k]) for k in keys) + '}'
        raise ValueError('supported_json_value_required')
    return encode(value).encode('utf-8')


def neutral_discovery_root(bootstrap):
    """Refuse ambient SDK18.1.11 startup sources before any SDK import."""
    bootstrap = Path(bootstrap)
    if bootstrap.resolve() != bootstrap:
        raise ValueError('canonical_neutral_bootstrap_required')
    for directory in (bootstrap, *bootstrap.parents):
        if directory.is_dir() and any(directory.glob('.env*')):
            raise ValueError('ambient_startup_discovery_refused')
        if all(os.path.lexists(directory / name) for name in ('HEAD', 'objects', 'refs')):
            raise ValueError('ambient_startup_discovery_refused')
        for name in ('.git', '.hg', '.svn', '.jj', '.omp', '.pi', '.claude', '.codex',
                     '.env', '.env.local', 'WATCHDOG.md', 'WATCHDOG.yml', 'WATCHDOG.yaml',
                     'AGENTS.md', 'CLAUDE.md', 'settings.json', 'settings.yml', 'settings.yaml', 'config.yml', 'config.yaml'):
            if os.path.lexists(directory / name):
                raise ValueError('ambient_startup_discovery_refused')
    for child in ('agent', 'config'):
        directory = bootstrap / child
        if directory.is_symlink():
            raise ValueError('canonical_neutral_bootstrap_required')
        for name in ('WATCHDOG.md', 'WATCHDOG.yml', 'WATCHDOG.yaml', 'AGENTS.md', 'CLAUDE.md',
                     'settings.json', 'settings.yml', 'settings.yaml', 'config.yml', 'config.yaml', '.env'):
            if os.path.lexists(directory / name):
                raise ValueError('ambient_startup_discovery_refused')


def owned_host(path):
    path = Path(path)
    if path.resolve() != path or not path.is_file():
        raise ValueError('host_custody_required')
    for p in (path, *path.parents):
        s = p.stat()
        if s.st_uid != 0 or s.st_mode & 0o022:
            raise ValueError('root_owned_nonwritable_host_custody_required')


def load_host():
    owned_host(HOST)
    host = json.loads(HOST.read_text())
    paths = host_paths(host)
    owned_host(paths['ownerPublicKey'])
    if sha(paths['ownerPublicKey']) != host['ownerPublicKeySha256']:
        raise ValueError('owner_key_changed')
    return host


def worker_account(host, lookup=None):
    """The observed root Kepler server may hand off only to this fixed account."""
    record = host.get('workerAccount', {})
    if record.get('name') != 'fm-omp-worker' or type(record.get('uid')) is not int or type(record.get('gid')) is not int or min(record['uid'], record['gid']) <= 0:
        raise ValueError('fixed_unprivileged_worker_account_required')
    account = (lookup or pwd.getpwnam)('fm-omp-worker')
    if account.pw_uid != record['uid'] or account.pw_gid != record['gid']:
        raise ValueError('worker_account_identity_changed')
    return record


def handoff_command(host, task, lookup=None):
    worker_account(host, lookup)
    if not TASK_RE.fullmatch(task) or task != host.get('task'):
        raise ValueError('named_worker_task_required')
    return ['/usr/sbin/runuser', '-u', 'fm-omp-worker', '--', '/bin/bash',
            str(SOURCE.parent / 'fm-omp-kepler.sh'), 'launch', task]


def verify_envelope(envelope, key):
    import base64
    # Openssl is an explicit host dependency, never a capsule command.
    with tempfile.TemporaryDirectory(prefix='fm-omp-signature-') as directory:
        message = Path(directory) / 'message'
        signature = Path(directory) / 'signature'
        message.write_bytes(canonical(envelope['payload']))
        signature.write_bytes(base64.b64decode(envelope['signature'], validate=True))
        result = subprocess.run(['/usr/bin/openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', str(key),
                                 '-rawin', '-in', str(message), '-sigfile', str(signature)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    if result.returncode:
        raise ValueError('owner_signature_refused')
    return envelope['payload']


def tree_digest(root):
    root = canonical_path(str(root), 'canonical_runtime_path_required')
    entries = []
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            target = path.resolve()
            if root.resolve() not in target.parents:
                raise ValueError('runtime_symlink_escape')
            entries.append([str(path.relative_to(root)), 'link', os.readlink(path)])
        elif path.is_file():
            entries.append([str(path.relative_to(root)), 'file', sha(path)])
    return hashlib.sha256(canonical(entries)).hexdigest()


def validate(c, host, task, now=None):
    now = time.time() if now is None else now
    paths = host_paths(host)
    if c.get('version') != 1 or c.get('task') != task or not TASK_RE.fullmatch(task):
        raise ValueError('task_capsule_refused')
    if host.get('issue') != 'ATX-2170' or host.get('scope') != 'command-center-pilot' or host.get('task') != task or c.get('issue') != 'ATX-2170' or c.get('scope') != 'command-center-pilot' or not task.startswith('ATX-2170'):
        raise ValueError('named_pilot_scope_required')
    if c.get('role') not in ('crew', 'scout') or c.get('backend') != 'orca':
        raise ValueError('worker_role_required')
    if c.get('cockpit') != 'kepler' or c.get('launchSurface') != 'manual-terminal' or c.get('supervisor') != 'firstmate':
        raise ValueError('kepler_launch_binding_required')
    if 'keplerTaskId' not in c or 'keplerWorktreeId' not in c or any(c[k] is not None and not isinstance(c[k], str) for k in ('keplerTaskId', 'keplerWorktreeId')):
        raise ValueError('kepler_task_identity_or_explicit_unknown_required')
    expected = ['read', 'grep'] if c['role'] == 'scout' else ['read', 'grep', 'write', 'edit']
    if c.get('tools') != expected:
        raise ValueError('exact_tools_required')
    if c.get('authority') != 'owner-approved-activation' or c.get('ownerAction') != 'ATX-1758-approved':
        raise ValueError('implementation_only_ATX1758_OWNER_ACTION_PENDING')
    gates = c.get('gates', {})
    if gates != {'provider': True, 'installation': False, 'login': False, 'merge': False, 'production': False}:
        raise ValueError('distinct_owner_gates_required')
    if not isinstance(c.get('deadline'), int) or not isinstance(c.get('issuedAt'), int) or not now < c.get('deadline', 0) <= now + 900 or c.get('issuedAt', now + 1) > now or c['deadline'] - c['issuedAt'] > 900:
        raise ValueError('bounded_deadline_required')
    credit = c.get('credit', {})
    if credit.get('included') is not True or credit.get('overage') != 0 or credit.get('validUntil', 0) < c['deadline']:
        raise ValueError('fresh_zero_overage_credit_required')
    model = c.get('model', {})
    for name in ('provider', 'id', 'api', 'baseUrl'):
        value = model.get(name)
        if not isinstance(value, str) or not value or any(x in value for x in ('*', '?', '\n')):
            raise ValueError('explicit_model_required')
    if not model['baseUrl'].startswith('https://') or c.get('fallback') is not False:
        raise ValueError('exact_endpoint_zero_fallback_required')
    if any(model[k] in ('auto', 'default', 'main', 'crew', 'scout', 'fast', 'heavy') for k in ('provider', 'id')):
        raise ValueError('model_alias_refused')
    endpoint = urlsplit(model['baseUrl'])
    if endpoint.username or endpoint.password or endpoint.query or endpoint.fragment or any(model.get(k) for k in ('headers', 'requestModelId', 'transport')):
        raise ValueError('unaliased_credential_free_endpoint_required')
    if not isinstance(c.get('brief'), str) or not c['brief'].strip() or len(c['brief']) > 65536:
        raise ValueError('approved_brief_required')
    worktree = canonical_path(c.get('worktree'), 'canonical_worktree_required')
    if not worktree.is_dir():
        raise ValueError('canonical_worktree_required')
    if host.get('allowedWorktrees') != [str(worktree)]:
        raise ValueError('single_command_center_worktree_required')
    state = paths['stateRoot'] / task
    if overlaps(worktree, state) or overlaps(worktree, paths['capsuleRoot']):
        raise ValueError('paths_not_separate')
    for trusted in (SOURCE, paths['runtime']['bun'], paths['runtime']['nodeModules']):
        if overlaps(worktree, trusted):
            raise ValueError('trusted_paths_inside_worker_scope')
    neutral_discovery_root(state.resolve() / 'bootstrap')
    head = subprocess.run([GIT, '-C', str(worktree), 'rev-parse', 'HEAD'], check=True, env=GIT_ENV,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5).stdout.decode().strip()
    top = subprocess.run([GIT, '-C', str(worktree), 'rev-parse', '--show-toplevel'], check=True, env=GIT_ENV,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5).stdout.decode().strip()
    if head != c.get('head') or str(Path(top).resolve()) != str(worktree):
        raise ValueError('exact_worktree_head_required')
    runtime = host['runtime']
    if c.get('runtime') != runtime or runtime.get('bunVersion') != '1.4.0' or runtime.get('sdkVersion') != '18.1.11':
        raise ValueError('pinned_runtime_required')
    if sha(paths['runtime']['bun']) != runtime['bunSha256'] or tree_digest(paths['runtime']['nodeModules']) != runtime['nodeModulesSha256']:
        raise ValueError('runtime_bytes_changed')
    package = paths['runtime']['nodeModules'] / '@oh-my-pi/pi-coding-agent/package.json'
    if json.loads(package.read_text())['version'] != '18.1.11':
        raise ValueError('sdk_version_changed')
    actual_sources = {p.name: sha(p) for p in SOURCE.iterdir() if p.suffix in ('.py', '.ts')}
    actual_sources['fm-omp-kepler.sh'] = sha(SOURCE.parent / 'fm-omp-kepler.sh')
    if c.get('sourceHashes') != actual_sources or host.get('sourceHashes') != actual_sources:
        raise ValueError('source_bytes_changed')
    if not isinstance(c.get('credentialFile'), str):
        raise ValueError('custodied_credential_descriptor_required')
    credential = canonical_path(c.get('credentialFile'), 'canonical_credential_path_required')
    if overlaps(worktree, credential):
        raise ValueError('credential_inside_worker_scope')
    return state


def identity(pid):
    if pid <= 1:
        return None
    if sys.platform == 'linux':
        try:
            fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            if fields[0] == 'Z':
                return None
            boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
            return f'linux:{boot}:{fields[19]}:{fields[2]}:{fields[1]}'
        except (OSError, IndexError):
            return None
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=', '-o', 'ppid=', '-o', 'pgid='],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    text = result.stdout.decode().strip()
    return text if result.returncode == 0 and text else None


def atomic(path, value):
    tmp = path.with_suffix('.next')
    tmp.write_bytes(canonical(value))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def owned_atomic(path, value):
    if path.exists() and marker_owner(path) != value['owner']:
        raise ValueError('receipt_owner_changed')
    atomic(path, value)


def marker_owner(path):
    try:
        return json.loads(path.read_text()).get('owner')
    except (OSError, ValueError, AttributeError):
        return None


def clean_env(home):
    return {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'XDG_CONFIG_HOME': str(home / 'config'),
            'PI_CODING_AGENT_DIR': str(home / 'agent'), 'PI_CONFIG_DIR': str(home / 'config'),
            'BUN_RUNTIME_TRANSPILER_CACHE_PATH': '0', 'PI_NO_TITLE': '1', 'OMP_SKIP_SETUP': '1',
            'LANG': 'C.UTF-8'}


def template():
    runtime = {'bun': '<absolute-private-bun>', 'bunVersion': '1.4.0', 'bunSha256': '<sha256>',
               'sdkVersion': '18.1.11', 'nodeModules': '<absolute-private-node_modules>', 'nodeModulesSha256': '<tree_digest>'}
    return {'host': {'issue': 'ATX-2170', 'scope': 'command-center-pilot', 'task': 'ATX-2170',
                     'workerAccount': {'name': 'fm-omp-worker', 'uid': '<verified-nonzero-uid>', 'gid': '<verified-nonzero-gid>'},
                     'allowedWorktrees': ['<canonical-command-center-pilot-worktree>'],
                     'ownerPublicKey': '/etc/firstmate/omp-kepler/owner.pub', 'ownerPublicKeySha256': '<sha256>',
                     'stateRoot': '<absolute-task-state-root-outside-worktrees>', 'capsuleRoot': '<absolute-FM-capsule-root>',
                     'runtime': runtime, 'sourceHashes': '<producer-file-name-to-sha256-map>'},
            'capsule': {'version': 1, 'task': 'ATX-2170', 'issue': 'ATX-2170', 'scope': 'command-center-pilot', 'role': 'scout', 'backend': 'orca',
                        'cockpit': 'kepler', 'launchSurface': 'manual-terminal', 'supervisor': 'firstmate',
                        'keplerTaskId': None, 'keplerWorktreeId': None, 'authority': 'implementation-only',
                        'ownerAction': 'ATX1758 OWNER ACTION PENDING',
                        'gates': {'provider': False, 'installation': False, 'login': False, 'merge': False, 'production': False},
                        'worktree': '<canonical-assigned-worktree>', 'head': '<40-character-head>', 'brief': '<approved-brief>',
                        'issuedAt': 0, 'deadline': 0, 'credit': {'included': False, 'overage': 0, 'validUntil': 0},
                        'fallback': False, 'tools': ['read', 'grep'], 'model': '<complete-owner-selected-Model-metadata>',
                        'runtime': runtime, 'sourceHashes': '<producer-file-name-to-sha256-map>',
                        'credentialFile': '<private-opaque-access-credential-file-outside-worktrees>'}}


def parent_death():
    if sys.platform == 'linux':
        import ctypes
        parent_pid = os.getppid()
        if ctypes.CDLL(None).prctl(1, signal.SIGKILL, 0, 0, 0) != 0 or os.getppid() != parent_pid:
            os._exit(1)


def supervise(command, state, deadline, env, payload=None, pass_fds=(), lease=None):
    """A separate watchdog owns/reaps the worker even if the Terminal dies."""
    parent = (os.getpid(), identity(os.getpid()))
    watchdog = os.fork()
    if watchdog == 0:
        try:
            _supervise(command, state, deadline, env, payload, pass_fds, parent, lease)
            os._exit(0)
        except BaseException:
            os._exit(1)
    def forward(_signum, _frame):
        try:
            os.kill(watchdog, signal.SIGTERM)
        except ProcessLookupError:
            pass
    previous = {s: signal.signal(s, forward) for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    try:
        _, status = os.waitpid(watchdog, 0)
        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise ValueError('owned_watchdog_failed')
        return json.loads((Path(state) / 'receipt.json').read_text())
    finally:
        for s, handler in previous.items():
            signal.signal(s, handler)


def _supervise(command, state, deadline, env, payload=None, pass_fds=(), parent=None, lease=None):
    resources = {}
    completed = False
    try:
        result = _supervise_owned(command, state, deadline, env, payload, pass_fds, parent, lease, resources)
        completed = True
        return result
    finally:
        child = resources.get('child')
        if child and child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=2)
            except ProcessLookupError:
                pass
        record = resources.get('record')
        marker = Path(state) / 'receipt.json'
        if not completed and child and record and (not marker.exists() or marker_owner(marker) == resources.get('owner')):
            record.update(state='failed', event='watchdog_exception', reaped=child.poll() is not None, exitCode=child.poll())
            owned_atomic(marker, record)
        if child:
            if child.stdout:
                child.stdout.close()
            if child.stdin and not child.stdin.closed:
                child.stdin.close()
        server = resources.get('server')
        if server:
            server.close()
        owner = resources.get('owner')
        marker = Path(state) / 'receipt.json'
        control = Path(state) / 'control.sock'
        if owner and ((marker.exists() and marker_owner(marker) == owner) or not marker.exists()):
            if control.exists() and resources.get('socketIdentity') == (control.stat().st_dev, control.stat().st_ino):
                control.unlink()
        if lease:
            lease_path = Path(lease)
            owner_file = lease_path / 'owner.json'
            if owner_file.exists() and marker_owner(owner_file) == owner:
                owner_file.unlink()
                lease_path.rmdir()


def _supervise_owned(command, state, deadline, env, payload=None, pass_fds=(), parent=None, lease=None, resources=None):
    """This dedicated process owns/reaps the child independently of its event loop."""
    state = Path(state)
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    marker = state / 'receipt.json'
    owner = os.urandom(24).hex()
    resources['owner'] = owner
    if lease:
        lease = Path(lease)
        lease.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        lease.mkdir(mode=0o700)
        atomic(lease / 'owner.json', {'owner': owner, 'watchdogPid': os.getpid(), 'start': identity(os.getpid())})
    server = socket.socket(socket.AF_UNIX)
    resources['server'] = server
    control = state / 'control.sock'
    if control.exists():
        raise ValueError('existing_control_endpoint')
    server.bind(str(control))
    resources['socketIdentity'] = (control.stat().st_dev, control.stat().st_ino)
    os.chmod(control, 0o600)
    server.listen(2)
    server.setblocking(False)
    child = subprocess.Popen(command, cwd=env['HOME'], env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True,
                             pass_fds=pass_fds, preexec_fn=parent_death)
    resources['child'] = child
    start = identity(child.pid)
    record = {'version': 1, 'owner': owner, 'pid': child.pid, 'start': start, 'watchdogPid': os.getpid(),
              'watchdogStart': identity(os.getpid()), 'state': 'busy', 'event': 'approved-brief',
              'deadline': deadline, 'sequence': 0, 'terminalReceipt': False, 'resultReceipt': False, 'reaped': False}
    if payload:
        capsule = payload['capsule']
        record.update(task=capsule['task'], capsuleHash=payload['capsuleHash'], sourceHashes=capsule['sourceHashes'],
                      sourceHead=capsule['head'], worktree=capsule['worktree'], cockpit=capsule['cockpit'],
                      keplerTaskId=capsule['keplerTaskId'], keplerWorktreeId=capsule['keplerWorktreeId'])
    record['identityStrength'] = 'linux-boot-startticks' if sys.platform == 'linux' else 'portable-ps-weak'
    resources['record'] = record
    owned_atomic(marker, record)
    selector = selectors.DefaultSelector()
    selector.register(server, selectors.EVENT_READ, 'control')
    os.set_blocking(child.stdout.fileno(), False)
    selector.register(child.stdout, selectors.EVENT_READ, 'worker')
    outbound = canonical(payload) + b'\n' if payload is not None else b''
    if outbound:
        os.set_blocking(child.stdin.fileno(), False)
        selector.register(child.stdin, selectors.EVENT_WRITE, 'input')
    else:
        child.stdin.close()
    buffer = b''
    stopping = False
    kill_at = None
    requested_stop = [False]
    def signal_stop(_signum, _frame):
        requested_stop[0] = True
    previous = {s: signal.signal(s, signal_stop) for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    def stop(reason):
        nonlocal stopping, kill_at
        if stopping:
            return
        stopping = True
        record.update(state=reason, event=reason)
        if identity(child.pid) == start:
            os.killpg(child.pid, signal.SIGTERM)
        kill_at = time.monotonic() + 0.5
    try:
        while True:
            running = child.poll() is None
            if requested_stop[0] or (parent and identity(parent[0]) != parent[1]):
                stop('controller-lost')
            if time.time() >= deadline:
                stop('expired')
            if stopping and time.monotonic() >= kill_at and identity(child.pid) == start:
                os.killpg(child.pid, signal.SIGKILL)
            ready = selector.select(0.05 if running else 0)
            # An exited child may still have its final receipts in the pipe.
            # Drain only bytes already available; descendants cannot keep us waiting.
            if not running and not any(key.data == 'worker' for key, _ in ready):
                break
            for key, _ in ready:
                if key.data == 'control':
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(0.5)
                        request = connection.recv(1024)
                        if request == owner.encode() + b':interrupt':
                            stop('interrupted')
                            connection.sendall(b'accepted')
                        else:
                            connection.sendall(b'refused')
                elif key.data == 'input':
                    try:
                        written = os.write(child.stdin.fileno(), outbound)
                        outbound = outbound[written:]
                    except BlockingIOError:
                        continue
                    except BrokenPipeError:
                        outbound = b''
                        if running:
                            stop('failed-input')
                    if not outbound:
                        selector.unregister(child.stdin)
                        child.stdin.close()
                else:
                    try:
                        chunk = os.read(child.stdout.fileno(), 8192)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(child.stdout)
                        continue
                    buffer += chunk
                    if len(buffer) > 65536:
                        stop('invalid-receipt')
                        buffer = b''
                    while b'\n' in buffer:
                        line, buffer = buffer.split(b'\n', 1)
                        try:
                            event = json.loads(line)
                            allowed = {'agent_start': {'type'}, 'agent_end': {'type', 'isTerminal'},
                                       'worker_failure': {'type'}, 'worker_result': {'type', 'task', 'stopReason', 'text', 'truncated'}}
                            if not isinstance(event, dict) or not isinstance(event.get('type'), str) or event['type'] not in allowed or set(event) - allowed[event['type']]:
                                raise ValueError('invalid_receipt_object')
                            if event.get('type') == 'agent_start' and not stopping:
                                record.update(state='busy', event='agent_start')
                            elif event.get('type') == 'agent_end' and not stopping:
                                if 'willContinue' in event or ('isTerminal' in event and not isinstance(event['isTerminal'], bool)):
                                    stop('invalid-receipt')
                                elif event.get('isTerminal') is False:
                                    record.update(state='busy', event='agent_end-continuation')
                                else:
                                    record.update(state='idle', event='agent_end', terminalReceipt=True)
                            elif event.get('type') == 'worker_failure':
                                stop('failed')
                            elif event.get('type') == 'worker_result' and not stopping:
                                expected_task = payload['capsule']['task'] if payload else 'inert'
                                if event.get('task') != expected_task or event.get('stopReason') != 'stop' or not isinstance(event.get('text'), str) or len(event['text']) > 8192:
                                    stop('invalid-result')
                                else:
                                    record['resultReceipt'] = True
                                    atomic(state / 'result.json', {'task': expected_task, 'capsuleHash': record.get('capsuleHash'),
                                                                 'text': event['text'], 'truncated': event.get('truncated') is True})
                            record['sequence'] += 1
                        except (ValueError, TypeError):
                            stop('invalid-receipt')
            owned_atomic(marker, record)
        rc = child.wait(timeout=2)
        # Remove any descendant still in the owned session's process group.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        record.update(reaped=True, exitCode=rc)
        if not stopping:
            record['state'] = 'completed' if rc == 0 and record['terminalReceipt'] and record['resultReceipt'] else 'failed'
        owned_atomic(marker, record)
        return record
    except BaseException:
        record.update(state='failed', event='watchdog_exception')
        raise
    finally:
        if child.poll() is None and identity(child.pid) == start:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=2)
        if marker.exists() and marker_owner(marker) == owner:
            record.update(reaped=child.poll() is not None, exitCode=child.poll())
            owned_atomic(marker, record)
        selector.close()
        server.close()
        for s, handler in previous.items():
            signal.signal(s, handler)
        if marker.exists() and marker_owner(marker) == owner:
            if control.exists() and resources['socketIdentity'] == (control.stat().st_dev, control.stat().st_ino):
                control.unlink()
        if lease and (lease / 'owner.json').exists() and marker_owner(lease / 'owner.json') == owner:
            (lease / 'owner.json').unlink()
            lease.rmdir()


def main():
    if sys.argv[1:] == ['template']:
        print(json.dumps(template(), indent=2))
        return
    if len(sys.argv) != 3 or sys.argv[1] not in ('handoff', 'launch', 'status', 'interrupt', 'registration', 'authority') or not TASK_RE.fullmatch(sys.argv[2]):
        raise ValueError('usage: fm-omp-kepler.sh handoff|launch|status|interrupt|registration <task-id>')
    action, task = sys.argv[1:]
    if action == 'registration':
        print(json.dumps({'id': f'fm-omp-{task}', 'name': f'OMP worker {task}', 'kind': 'terminal',
                          'command': str(SOURCE.parent / 'fm-omp-kepler.sh'), 'args': ['handoff', task], 'env': {}}))
        return
    host = load_host()
    if task != host.get('task'):
        raise ValueError('named_worker_task_required')
    state = host_paths(host)['stateRoot'] / task
    if action in ('status', 'interrupt'):
        record = json.loads((state / 'receipt.json').read_text())
        if action == 'status':
            live = identity(record['pid']) == record['start'] and not record['reaped']
            print(json.dumps({**{k: v for k, v in record.items() if k != 'owner'}, 'live': live}))
            return
        if identity(record['watchdogPid']) != record['watchdogStart'] or record['reaped']:
            raise ValueError('owned_watchdog_not_live')
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(2)
        connection.connect(str(state / 'control.sock'))
        connection.sendall(record['owner'].encode() + b':interrupt')
        accepted = connection.recv(1024) == b'accepted'
        connection.close()
        end = time.monotonic() + 2
        final = record
        while accepted and time.monotonic() < end:
            final = json.loads((state / 'receipt.json').read_text())
            if final.get('owner') != record['owner'] or final.get('reaped'):
                break
            time.sleep(0.05)
        stopped = final.get('owner') == record['owner'] and final.get('reaped') is True and identity(record['pid']) != record['start']
        print(json.dumps({'requestAccepted': accepted, 'ownedWorkerStopped': stopped}))
        if not accepted or not stopped:
            sys.exit(1)
        return
    envelope_path = host_paths(host)['capsuleRoot'] / f'{task}.json'
    if envelope_path.is_symlink() or envelope_path.stat().st_mode & 0o222:
        raise ValueError('immutable_capsule_required')
    envelope = json.loads(envelope_path.read_text())
    capsule = verify_envelope(envelope, host['ownerPublicKey'])
    def deadline_stop(_signum, _frame):
        raise ValueError('worker_deadline_expired')
    if isinstance(capsule.get('deadline'), int):
        signal.signal(signal.SIGALRM, deadline_stop)
        signal.setitimer(signal.ITIMER_REAL, max(0.001, capsule['deadline'] - time.time()))
    state = validate(capsule, host, task)
    if action == 'authority':
        print(hashlib.sha256(canonical(capsule)).hexdigest())
        return
    if sys.platform != 'linux':
        raise ValueError('operational_linux_parent_death_boundary_required')
    if str(Path.cwd().resolve()) != capsule['worktree']:
        raise ValueError('kepler_task_worktree_cwd_required')
    account = worker_account(host)
    if action == 'handoff' and os.geteuid() == 0:
        command = handoff_command(host, task)
        if not Path(command[0]).is_file():
            raise ValueError('fixed_runuser_handoff_dependency_required')
        signal.setitimer(signal.ITIMER_REAL, 0)
        os.execv(command[0], command)
    if os.geteuid() == 0:
        raise ValueError('unprivileged_worker_account_required')
    if os.geteuid() != account['uid'] or os.getegid() != account['gid']:
        raise ValueError('worker_account_identity_changed')
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    # One launch per signed capsule; status reconnects without submitting again.
    claim = state / ('claim-' + hashlib.sha256(canonical(capsule)).hexdigest())
    claim_fd = os.open(claim, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(claim_fd)
    home = state / 'bootstrap'
    home.mkdir(mode=0o700)
    credential_path = canonical_path(capsule.get('credentialFile'), 'canonical_credential_path_required')
    s = credential_path.stat()
    if credential_path.is_symlink() or not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != os.getuid() or s.st_mode & 0o077:
        raise ValueError('private_credential_custody_required')
    credential_fd = os.open(credential_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(credential_fd)
        if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1 or opened.st_size > 16384 or (opened.st_dev, opened.st_ino) != (s.st_dev, s.st_ino):
            raise ValueError('credential_descriptor_changed')
        payload = {'capsule': capsule, 'capsuleHash': hashlib.sha256(canonical(capsule)).hexdigest(),
                   'ownerPublicKey': Path(host['ownerPublicKey']).read_text(), 'state': str(state),
                   'credentialFd': credential_fd}
        result = supervise([str(host_paths(host)['runtime']['bun']), '--no-env-file', str(SOURCE / 'worker.ts')],
                           state, capsule['deadline'], clean_env(home), payload, (credential_fd,),
                           host_paths(host)['stateRoot'] / '.leases' / hashlib.sha256(capsule['worktree'].encode()).hexdigest())
        print(json.dumps({'state': result['state'], 'reaped': result['reaped'], 'exitCode': result['exitCode']}))
        if result['state'] != 'completed':
            sys.exit(1)
    finally:
        os.close(credential_fd)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Error names contain no provider output, credentials, paths, or capsule.
        message = str(exc) if isinstance(exc, ValueError) else 'controller_refused'
        print(json.dumps({'error': message}), file=sys.stderr)
        sys.exit(1)
