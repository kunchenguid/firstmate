"""Frozen Workforce allocation/policy contract, consumed by admission and spawn.

Wire: optional job payload execution_policy = {schema: fm-workforce-policy.v1,
allocation_id: safe-id, crew: positive exact integer, descendants: {concurrent:
nonnegative exact integer}, route: host|openshell|company-vm, revisions: {global,
project, job: sha256, company?: sha256}}. Counts are workload allocations, not a
fleet ceiling. No paths, credentials, network rules or mutable policy selection.
Admission reserves one immutable slot per note under the inbox admission lock;
all requests sharing an allocation must have identical scope/payload. Relaunch
retains that slot and frozen policy. Uncertain reservations are never recycled.
Codex 0.159.3 controls only native subagents, not arbitrary OS children, total
spawned agents, tokens, cost or account quotas. Other native adapters are refused
for a requested hard count until their own supported controls are established.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import select
import subprocess
import tempfile
import time

SCHEMA = 'fm-workforce-policy.v1'
CODEX_VERSION = 'codex-cli 0.159.3'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def validate(value):
    if not isinstance(value, dict) or set(value) != {'schema', 'allocation_id', 'crew', 'descendants', 'route', 'revisions'}:
        raise ValueError('invalid execution_policy fields')
    if value['schema'] != SCHEMA or not isinstance(value['allocation_id'], str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', value['allocation_id']) or '..' in value['allocation_id']:
        raise ValueError('invalid policy schema/allocation identity')
    if not isinstance(value['descendants'], dict):
        raise ValueError('invalid descendants object')
    for n, minimum in [(value['crew'], 1), (value['descendants'].get('concurrent'), 0)]:
        if type(n) is not int or not minimum <= n <= 9007199254740991:
            raise ValueError('allocation counts must be exact integers')
    if set(value['descendants']) != {'concurrent'}:
        raise ValueError('unsupported depth/total/token/cost restriction')
    if value['route'] not in {'host', 'openshell', 'company-vm'}:
        raise ValueError('unsupported execution route')
    revisions = value['revisions']
    if not isinstance(revisions, dict) or not {'global', 'project', 'job'} <= set(revisions) or set(revisions) - {'global', 'company', 'project', 'job'} or any(not isinstance(v, str) or not re.fullmatch('[0-9a-f]{64}', v) for v in revisions.values()):
        raise ValueError('frozen policy requires exact global/project/job revision digests')
    return value


def reserve(home, request, notes, load):
    policy = request['payload'].get('execution_policy')
    if policy is None:
        return None
    validate(policy)
    frozen = dict(scope=request['scope'], payload=request['payload'])
    fingerprint = digest(frozen)
    slots = set()
    for path in notes:
        headers, _ = load(path)
        raw = headers.get('workforce_allocation')
        if not raw:
            continue
        entry = json.loads(raw)
        if entry['policy']['allocation_id'] != policy['allocation_id']:
            continue
        if entry['snapshot_digest'] != fingerprint:
            raise ValueError('allocation identity already binds a different frozen request')
        slot = entry['slot']
        if type(slot) is not int or not 0 <= slot < policy['crew'] or slot in slots:
            raise ValueError('ambiguous allocation occupancy; reconcile before dispatch')
        slots.add(slot)
    if len(slots) >= policy['crew']:
        raise ValueError('frozen workload allocation is fully occupied; no additional root dispatch')
    # No list(range(crew)): exact large quantities do not allocate large memory.
    slot = 0
    while slot in slots:
        slot += 1
    return dict(schema='fm-workforce-allocation.v1', policy=policy,
                snapshot_digest=fingerprint, policy_digest=digest(policy), slot=slot)


def codex_controls(policy):
    count = policy['descendants']['concurrent']
    # V2 takes precedence over agents.enabled, so disable it explicitly.
    controls = {'features.multi_agent_v2': False, 'features.multi_agent': count > 0,
                'agents.enabled': count > 0}
    if count:
        controls['agents.max_concurrent_threads_per_session'] = count
    return controls


def flags(controls):
    result = []
    for key, value in sorted(controls.items()):
        result.extend(['-c', key+'='+json.dumps(value)])
    return result


def probe_codex(policy, executable='codex', command=None):
    """Credential-free current installed native configuration readback.

    A private home/cwd excludes host credentials and project overrides. This is
    prerequisite evidence, never attestation of another running process.
    """
    command = command or [executable]
    version = subprocess.check_output([*command, '--version'], text=True, timeout=10).strip()
    if version != CODEX_VERSION:
        raise ValueError('unverified native descendant controls for '+version)
    controls = codex_controls(policy)
    with tempfile.TemporaryDirectory(prefix='fm-native-policy-') as directory:
        env = {k: v for k, v in os.environ.items() if not any(s in k.upper() for s in ('TOKEN', 'SECRET', 'PASSWORD', 'API_KEY'))}
        env.update(CODEX_HOME=directory)
        process = subprocess.Popen([*command, 'app-server', '--strict-config', *flags(controls)],
                cwd=directory, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL)
        try:
            def rpc(ident, method, params):
                process.stdin.write((canonical(dict(id=ident, method=method, params=params))+'\n').encode())
                process.stdin.flush()
                deadline = time.monotonic()+10
                buffer = b''
                while time.monotonic() < deadline:
                    if select.select([process.stdout], [], [], max(0, deadline-time.monotonic()))[0]:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk:
                            break
                        buffer += chunk
                        while b'\n' in buffer:
                            raw, buffer = buffer.split(b'\n', 1)
                            row = json.loads(raw)
                            if row.get('id') == ident:
                                if 'error' in row:
                                    raise ValueError('native policy readback refused')
                                return row['result']
                raise ValueError('native policy readback unavailable')
            rpc(1, 'initialize', {'clientInfo': {'name': 'firstmate-policy-probe', 'version': '1'}})
            config = rpc(2, 'config/read', {'includeLayers': False})['config']
            for key, value in controls.items():
                section, field = key.split('.')
                if config.get(section, {}).get(field) != value:
                    raise ValueError('native control not effective: '+key)
            return dict(version=version, controls=controls, source='installed-codex-config/read',
                        credential_free=True, enforcement_scope='native-session-concurrent-descendants')
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def probe_opencode(policy):
    if policy['descendants']['concurrent'] != 0:
        raise ValueError('OpenCode has no verified positive native quantity limit')
    version = subprocess.check_output(['opencode', '--version'], text=True, timeout=10).strip()
    if version != '1.18.31':
        raise ValueError('unverified native OpenCode denial for '+version)
    controls = {'subagent_depth': 0, 'permission': {'task': 'deny'}}
    with tempfile.TemporaryDirectory(prefix='fm-opencode-policy-') as directory:
        env = {k: v for k, v in os.environ.items() if not k.startswith('OPENCODE_') and not any(s in k.upper() for s in ('TOKEN', 'SECRET', 'PASSWORD', 'API_KEY'))}
        env.update(HOME=directory, XDG_CONFIG_HOME=directory+'/config', XDG_DATA_HOME=directory+'/data',
            XDG_CACHE_HOME=directory+'/cache', XDG_STATE_HOME=directory+'/state',
            OPENCODE_CONFIG_CONTENT=canonical(dict(controls, plugin=[])))
        raw = subprocess.check_output(['opencode', '--pure', 'debug', 'config'], env=env, cwd=directory,
            text=True, stderr=subprocess.DEVNULL, timeout=30)
        config = json.loads(raw)
        if config.get('subagent_depth') != 0 or config.get('permission', {}).get('task') != 'deny':
            raise ValueError('OpenCode native task denial did not read back')
    return dict(version=version, controls=controls, source='installed-opencode-debug-config',
        credential_free=True, enforcement_scope='native-task-tool-denial-only')


def probe_native(policy, harness):
    if harness == 'codex':
        return probe_codex(policy)
    if harness == 'opencode':
        return probe_opencode(policy)
    raise ValueError('requested native descendant count unsupported for '+harness)


def preflight(home, note, task, harness, backend, route, mode, yolo, model, effort, captured):
    _, headers, _, request = captured(home, note)
    policy = request['payload'].get('execution_policy')
    if policy is None:
        return None
    validate(policy)
    payload = request['payload']
    if payload['delivery_mode'] != mode or payload['merge_autonomy'] != (yolo == 'on'):
        raise ValueError('frozen delivery/merge policy differs from dispatch')
    for key in ('posture', 'delivery_mode', 'merge_autonomy'):
        requested = payload.get('preferences', {}).get(key)
        if requested is not None and requested != payload[key]:
            raise ValueError('inconsistent frozen '+key+' snapshot')
    for key, actual in [('harness', harness), ('backend', backend), ('model', model), ('effort', effort)]:
        requested = payload.get('preferences', {}).get(key)
        if requested is not None and requested != actual:
            raise ValueError('frozen '+key+' differs from dispatch')
    if policy['route'] != route:
        raise ValueError('frozen route differs from actual spawn route; no host fallback')
    if route == 'company-vm':
        raise ValueError('company-VM execution has no supported admission owner')
    if route == 'openshell':
        if harness != 'codex' or backend != 'herdr' or mode != 'no-mistakes':
            raise ValueError('OpenShell owner requires Herdr no-mistakes ship; no unsafe Direct-PR fallback')
        return dict(policy_digest=digest(policy), native=None, prerequisite='workload-native-readback-before-agent-start')
    native = probe_native(policy, harness)
    return dict(policy_digest=digest(policy), native=native)


def read_meta(home, task):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', task):
        raise ValueError('invalid task')
    path = home/'state'/f'{task}.meta'
    if path.is_symlink():
        raise ValueError('symlink metadata refused')
    pairs = [line.split('=', 1) for line in path.read_text().splitlines() if '=' in line]
    if len(dict(pairs)) != len(pairs):
        raise ValueError('ambiguous task metadata')
    return dict(pairs)


def launch(home, task, argv):
    """Launch wrapper adds verified controls to the actual task process.

    The same PID execs Codex; /proc start-time and command-line readback can
    establish current generation evidence. Host evidence is not a security
    attestation against the same user modifying records or starting other CLIs.
    """
    values = read_meta(home, task)
    allocation = json.loads(values['workforce_allocation'])
    policy = validate(allocation['policy'])
    from fm_inbox_admission import captured
    origin = json.loads(values['admission_origin'])
    _, headers, _, request = captured(home, origin['note_id'])
    if json.loads(headers.get('workforce_allocation', 'null')) != allocation or request['payload']['execution_policy'] != policy:
        raise ValueError('frozen admission/runtime policy custody differs')
    harness = values['harness']
    if harness not in {'codex','opencode'} or policy['route'] != 'host' or not argv or argv[0] != harness:
        raise ValueError('invalid policy-bound launch')
    if any(arg.startswith(('agents.', 'features.multi_agent')) for arg in argv[1:]):
        raise ValueError('launch cannot override frozen native controls')
    native = probe_native(policy, harness)
    if harness == 'codex':
        argv = [argv[0], *flags(native['controls']), *argv[1:]]
    else:
        config = json.loads(os.environ.get('OPENCODE_CONFIG_CONTENT', '{}'))
        config['subagent_depth'] = 0
        config.setdefault('permission', {})['task'] = 'deny'
        os.environ['OPENCODE_CONFIG_CONTENT'] = canonical(config)
    evidence = dict(schema='fm-workforce-runtime.v1', task_id=task,
        generation=values['spawn_gen'], allocation=allocation, native=native,
        harness=harness, pid=os.getpid(), observed_at=time.time(), state='launching',
        process_start=process_start(os.getpid()), route='host',
        filesystem='host-worker-authority', network='host-worker-authority',
        credentials='existing-host-harness-authority', attested=False)
    path = evidence_path(home, task, values['spawn_gen'], create=True)
    # Exclusive creation forbids a second process for the same generation.
    with path.open('x') as stream:
        os.chmod(path, 0o600)
        stream.write(canonical(evidence)+'\n')
        stream.flush()
        os.fsync(stream.fileno())
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    os.execvp(argv[0], argv)


def process_start(pid):
    try:
        return Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def observe(home, task):
    values = read_meta(home, task)
    allocation = json.loads(values['workforce_allocation'])
    result = dict(schema='fm-workforce-effective-policy.v1', allocation=allocation,
                  generation=values['spawn_gen'], state='unknown', native=None,
                  attested=False, provenance='spawn-metadata', occupied=None)
    if allocation['policy']['route'] == 'openshell':
        return observe_openshell(home, task, values, result)
    path = evidence_path(home, task, values['spawn_gen'])
    if not path.exists() or path.is_symlink():
        return result
    evidence = json.loads(path.read_text())
    if evidence.get('generation') != values['spawn_gen'] or evidence.get('allocation') != allocation:
        result['state'] = 'generation-changed'
        return result
    pid = evidence['pid']
    start = process_start(pid)
    if not start:
        if Path('/proc').is_dir() and not Path('/proc', str(pid)).exists():
            result.update(state='stopped', occupied=False)
        return result
    if start != evidence['process_start']:
        result.update(state='process-replaced', occupied=False)
        return result
    argv = Path('/proc', str(pid), 'cmdline').read_bytes().split(b'\0')
    argv = [part.decode(errors='replace') for part in argv if part]
    controls = evidence['native']['controls']
    if evidence.get('harness', 'codex') == 'codex':
        expected = flags(controls)
        if len(argv) < len(expected)+1 or argv[1:1+len(expected)] != expected:
            return result
    else:
        environ = Path('/proc', str(pid), 'environ').read_bytes().split(b'\0')
        raw = next((v.split(b'=',1)[1] for v in environ if v.startswith(b'OPENCODE_CONFIG_CONTENT=')), b'{}')
        config = json.loads(raw)
        if config.get('subagent_depth') != 0 or config.get('permission',{}).get('task') != 'deny':
            return result
    result.update(state='running', native=evidence['native'], occupied=True,
                  provenance='generation-bound-process-start-and-argv', runtime=evidence)
    return result


def observe_openshell(home, task, values, result):
    # The supported runner remains the sole sandbox/transfer/recovery owner.
    # Runtime identity and accepted native controls are evidence, not attestation
    # of effective provider policies or a future gateway-wide override.
    import importlib.util
    spec = importlib.util.spec_from_file_location('openshell_policy_runner', Path(__file__).with_name('fm-openshell-codex.py'))
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    try:
        ctx = runner.load_context(task, require_live=False)
        journal = runner.read_journal(ctx)
        if not journal or journal.get('generation') != values['spawn_gen']:
            return result
        if journal.get('workforce_policy_digest') != result['allocation']['policy_digest']:
            return result
        result.update(route='openshell', environment=dict(workspace=ctx['workspace'],
            workspace_id=ctx['workspace_id'], sandbox=ctx['sandbox']),
            boundary=dict(filesystem='hard-requirement-policy-request',
                network='provider-policy-dependent', credentials='attached-provider-dependent',
                descendants='same-sandbox-native-session', attested=False),
            occupied=None, native=journal.get('native_policy'))
        runner.ensure_no_global_policy(ctx)
        if journal.get('phase') == 'agent-running' and runner.sandbox_phase(ctx) == 'running':
            result.update(state='sandbox-running', occupied=True,
                provenance='generation-bound-runner-journal-and-workspace-bound-sandbox-readback')
        return result
    except (runner.Refusal, ValueError, OSError, KeyError):
        return result


def evidence_path(home, task, generation, create=False):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', generation) or '..' in generation:
        raise ValueError('invalid runtime generation')
    directory = home/'state'/f'{task}.workforce-runtime'
    if directory.is_symlink():
        raise ValueError('symlink runtime directory refused')
    if create:
        directory.mkdir(mode=0o700, exist_ok=True)
    if directory.exists() and (not directory.is_dir() or directory.stat().st_uid != os.getuid() or directory.stat().st_mode & 0o077):
        raise ValueError('runtime directory must be task-private')
    path = directory/(generation+'.json')
    if path.is_symlink():
        raise ValueError('symlink generation record refused')
    return path


def capabilities():
    try:
        version = subprocess.check_output(['codex', '--version'], text=True, timeout=5).strip()
    except (OSError, subprocess.SubprocessError):
        version = None
    try:
        harnesses = subprocess.check_output(['bash', '-c', '. "$1"; fm_control_harnesses',
            'workforce-policy', str(Path(__file__).with_name('fm-control-lib.sh'))], text=True, timeout=5).splitlines()
    except (OSError, subprocess.SubprocessError):
        harnesses = []
    other = [dict(harness=h, concurrent='unavailable',
        reason='no verified hard-count integration in this native launch adapter')
        for h in harnesses if h not in {'codex','opencode'}]
    return dict(schema='fm-workforce-policy-capabilities.v1',
        allocation=dict(owner='fm-inbox.sh prepare-admission', workload_scoped=True,
            permanent_workers=False, uncertain_slots='retained', automatic_dispatch=False),
        native=[dict(harness='codex', installed_version=version,
            concurrent='native-supported' if version == CODEX_VERSION else 'unavailable',
            supported_version=CODEX_VERSION, depth='unavailable', total='unavailable',
            token_budget='unavailable', cost_budget='unavailable',
            prerequisite='exact installed native config/read and launch controls'),
            dict(harness='opencode', supported_version='1.18.31', concurrent='unavailable',
                zero_descendants='native-task-denial', depth='not-a-quantity-limit',
                prerequisite='exact installed native config readback; no positive quota adapter'),
            *other],
        routes=[dict(route='host', supported=True, security_attestation=False),
            dict(route='openshell', supported=True, owner='fm-openshell-codex.py',
                 prerequisite='Herdr Codex no-mistakes ship; registered gateway/workspace/image/providers; workload native readback',
                 security_attestation=False, direct_pr=False),
            dict(route='company-vm', supported=False, reason='no authorized execution owner')])
