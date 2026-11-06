#!/usr/bin/env python3
"""Exercise actual startup, acquisition, ownership and Stop in a temporary home.

Only the vendor process-table boundary is simulated. The server's real PID is
shared by every invocation. UUIDs are fixture inputs, never live identity proof.
"""
import json
import os
import select
import signal
import sys
import time
import pathlib
import shutil
import subprocess
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
OWNER = '00000000-0000-4000-8000-000000000001'
OTHER = '00000000-0000-4000-8000-000000000002'
BASE = {k: v for k, v in os.environ.items() if not k.startswith(
    ('FM_', 'CODEX_', 'CLAUDE_', 'HERDR_', 'TASKS_AXI_', 'CURSOR_', 'PI_'))}
for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
    BASE.pop(name, None)
BASE.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
PS = shutil.which('ps')

with tempfile.TemporaryDirectory(prefix='fm-codex-session-') as temp:
    home = pathlib.Path(temp)
    for name in ('state', 'data', 'config', 'projects', 'fakebin'):
        (home / name).mkdir()
    shutil.copytree(REPO / 'bin', home / 'bin')
    (home / 'AGENTS.md').write_text('Isolated fixture.\n')
    subprocess.run(['git', 'init', '-q', str(home)], env=BASE, check=True)
    # Startup composition remains real. External fleet, network and cleanup
    # leaves cannot run infrastructure commands, even against an empty home.
    for name in ('fm-bootstrap.sh', 'fm-herdr-session-cleanup.sh',
                 'fm-startup-network.sh', 'fm-home-summary-refresh.sh',
                 'fm-guard.sh', 'fm-lease.sh', 'fm-branch-outcome.sh',
                 'fm-public-followup.sh'):
        (home / 'bin' / name).write_text('#!/usr/bin/env bash\nexit 0\n')
    (home / 'fakebin' / 'ps').write_text(f'''#!/usr/bin/env bash
if [ "$*" = '-o comm= -p {os.getpid()}' ]; then printf '%s\\n' "${{FM_FIXTURE_COMM:-/opt/codex}}"; exit 0; fi
if [ "$*" = '-o args= -p {os.getpid()}' ]; then printf '%s\\n' "${{FM_FIXTURE_ARGV0:-/opt/codex}} ${{FM_FIXTURE_SUBCOMMAND:-app-server}} --listen stdio://"; exit 0; fi
exec '{PS}' "$@"
''')
    (home / 'fakebin' / 'ps').chmod(0o755)
    (home / 'bin/fm-watch.sh').write_text('#!/usr/bin/env bash\ntouch "$FM_HOME/state/checkpoint-ran"\nprintf "signal: fixture\\n"\n')
    (home / '.codex').mkdir()
    shutil.copy(REPO / '.codex/hooks.json', home / '.codex/hooks.json')
    env = BASE | {'FM_HOME': str(home), 'FM_ROOT_OVERRIDE': str(home),
                  'FM_SESSION_START_STAGE_FILE': str(home / 'state/stage'),
                  'PATH': str(home / 'fakebin') + ':' + BASE['PATH']}

    def run(command, identity=OWNER, payload=None, thread_identity=None):
        call_env = env.copy()
        if identity is not None:
            call_env |= {'CODEX_SESSION_ID': identity,
                         'CODEX_THREAD_ID': identity if thread_identity is None else thread_identity}
        return subprocess.run(['bash', '-c', command], input=payload,
                              env=call_env, text=True, capture_output=True,
                              timeout=30)

    if '--live' in sys.argv:
        # The installed server generates both sessions and their hook payloads.
        # An isolated provider points at a closed loopback port. No credentials
        # or model requests leave the fixture, and model success is not a gate.
        codex_home = home / 'codex-home'
        codex_home.mkdir()
        (codex_home / 'config.toml').write_text(
            'model_provider="fixture"\nmodel="fixture"\n'
            '[features]\nhooks=true\n'
            '[model_providers.fixture]\nname="fixture"\n'
            'base_url="http://127.0.0.1:1/v1"\nwire_api="responses"\n'
            'requires_openai_auth=false\nrequest_max_retries=0\nstream_max_retries=0\n')
        capture = home / 'capture.sh'
        capture.write_text('#!/usr/bin/env bash\npayload=$(cat)\nid=$(printf \'%s\' "$payload" | jq -er \'.session_id\') || exit 1\nprintf \'%s\' "$payload" | "$FM_HOME/bin/fm-sessionstart-run.sh" > "$FM_HOME/state/$id.startup"\nprintf \'%s\\n\' "$id" >> "$FM_HOME/state/observed-sessions"\n')
        capture.chmod(0o755)
        (codex_home / 'hooks.json').write_text(json.dumps({'hooks': {
            'SessionStart': [{'hooks': [{'type': 'command',
                                        'command': str(capture), 'timeout': 30}]}]}}))
        live_env = env | {'CODEX_HOME': str(codex_home), 'PATH': BASE['PATH']}
        stderr = (home / 'native.stderr').open('w')
        process = subprocess.Popen(
            [shutil.which('codex'), 'app-server', '--listen', 'stdio://'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
            env=live_env, start_new_session=True)
        buffered = bytearray()
        def send(request_id, method, params):
            process.stdin.write((json.dumps({'id': request_id, 'method': method,
                                           'params': params}) + '\n').encode())
            process.stdin.flush()
        def response(request_id):
            end = time.monotonic() + 20
            while time.monotonic() < end:
                while b'\n' in buffered:
                    line, _, rest = buffered.partition(b'\n')
                    buffered[:] = rest
                    data = json.loads(line)
                    if data.get('id') == request_id:
                        assert 'error' not in data, data
                        return data['result']
                ready = select.select([process.stdout], [], [], max(0, end-time.monotonic()))[0]
                assert ready, 'native app-server response timed out'
                chunk = os.read(process.stdout.fileno(), 65536)
                assert chunk, 'native app-server closed unexpectedly'
                buffered.extend(chunk)
            raise AssertionError('native app-server response timed out')
        try:
            send(1, 'initialize', {'clientInfo': {'name': 'fm-isolated-regression',
                                                'version': '1'},
                                   'capabilities': {'experimentalApi': True}})
            version = response(1)['userAgent']
            process.stdin.write(b'{"method":"initialized"}\n')
            process.stdin.flush()
            identities = []
            for number in (2, 4):
                send(number, 'thread/start', {'cwd': str(home),
                     'approvalPolicy': 'never', 'sandbox': 'danger-full-access',
                     'config': {'bypass_hook_trust': True}})
                thread = response(number)['thread']
                identities.append(thread['sessionId'])
                send(number+1, 'turn/start', {'threadId': thread['id'],
                     'input': [{'type': 'text', 'text': 'Isolated hook fixture.'}]})
                response(number+1)
                observed = home / 'state/observed-sessions'
                for _ in range(300):
                    if observed.exists() and thread['sessionId'] in observed.read_text().splitlines():
                        break
                    time.sleep(0.1)
                else:
                    raise AssertionError('installed native SessionStart hook did not complete')
            assert identities[0] != identities[1], 'native server reused session identity'
            assert 'lock acquired:' in (home / ('state/'+identities[0]+'.startup')).read_text()
            assert 'READ-ONLY SESSION' in (home / ('state/'+identities[1]+'.startup')).read_text()
            assert (home / 'state/.lock-session').read_text().strip() == 'codex-native:'+identities[0]
            print('ok - '+version+': distinct native hook identities sharing one server preserve one lock owner')
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)
            stderr.close()
        sys.exit(0)

    start = '"$FM_HOME/bin/fm-session-start.sh"'
    lock = '"$FM_HOME/bin/fm-lock.sh"'
    own = '. "$FM_HOME/bin/fm-session-lock-lib.sh"; fm_session_lock_owned_by_self "$FM_HOME/state"'
    first = run(start)
    assert first.returncode == 0 and 'lock acquired:' in first.stdout, first.stdout + first.stderr
    assert run(lock).returncode == 0, 'same-session reentry failed'
    assert run(own).returncode == 0, 'the owner lost ownership'
    before = (home / 'state/.lock').read_bytes()
    sidecar = (home / 'state/.lock-session').read_bytes() if (home / 'state/.lock-session').exists() else None
    second = run(start, OTHER)
    print('shared server PID:', os.getpid())
    print('owner startup:', 'lock acquired:' in first.stdout)
    print('competing startup read-only:', 'READ-ONLY SESSION' in second.stdout)
    assert 'READ-ONLY SESSION' in second.stdout, 'different native threads both acquired one home lock'
    assert run(lock, OTHER).returncode == 1, 'competitor acquired owner lock'
    assert run(own, OTHER).returncode == 1, 'competitor trusted owner lock'
    assert run(own, thread_identity=OTHER).returncode == 1, 'descendant trusted its root owner lock'
    assert run(lock, thread_identity=OTHER).returncode == 1, 'descendant acquired its root owner lock'
    assert 'READ-ONLY SESSION' in run(start, thread_identity=OTHER).stdout, 'descendant startup acquired its root owner lock'
    assert run(own, None).returncode == 1, 'missing identity trusted shared PID'
    assert (home / 'state/.lock').read_bytes() == before, 'owner PID changed'
    assert (home / 'state/.lock-session').read_bytes() == sidecar, 'owner identity changed'
    assert run(own).returncode == 0, 'competitor displaced the owner'
    (home / 'state/task.meta').write_text('project=fixture\n')
    stop = '"$FM_HOME/bin/fm-turnend-guard.sh"'
    payload = '{"session_id":"' + OTHER + '","stop_hook_active":false}'
    foreign_stop = run(stop, OTHER, payload)
    assert foreign_stop.returncode == 0, 'read-only native Stop requested impossible supervision repair'
    owner_stop_payload = '{"session_id":"' + OWNER + '","stop_hook_active":false}'
    descendant_stop = run(stop, payload=owner_stop_payload, thread_identity=OTHER)
    assert descendant_stop.returncode == 0, 'read-only descendant Stop requested impossible supervision repair'
    assert 'OWNED BY ANOTHER LIVE SESSION' in descendant_stop.stdout, 'descendant Stop did not report the foreign owner'
    checkpoint = '"$FM_HOME/bin/fm-watch-checkpoint.sh" --seconds 1'
    assert run(checkpoint, OTHER).returncode == 1, 'competitor started a second checkpoint'
    assert run(checkpoint, thread_identity=OTHER).returncode == 1, 'descendant started its root owner checkpoint'
    assert not (home / 'state/checkpoint-ran').exists(), 'read-only checkpoint ran the watcher'
    assert run(checkpoint).returncode == 0, 'owner could not start its checkpoint'
    assert (home / 'state/checkpoint-ran').exists(), 'owner checkpoint did not run'
    # Hook identity must work without shell-tool variables. Contradictory or
    # malformed vendor payloads must never refresh another session's sidecar.
    hook = '"$FM_HOME/bin/fm-sessionstart-run.sh"'
    good_payload = '{"source":"startup","session_id":"' + OWNER + '"}'
    assert 'lock acquired:' in run(hook, None, good_payload).stdout, 'authenticated hook lost its session identity'
    assert 'READ-ONLY SESSION' in run(hook, payload=good_payload, thread_identity=OTHER).stdout, 'hook identity authorized a descendant shell thread'
    bad_payload = '{"source":"startup","session_id":"' + OTHER + '"}'
    assert 'READ-ONLY SESSION' in run(hook, OWNER, bad_payload).stdout, 'contradictory hook identity acquired the lock'
    assert 'READ-ONLY SESSION' in run(hook, OWNER, '{"source":"startup"}').stdout, 'missing hook identity fell back to retained environment'
    assert (home / 'state/.lock-session').read_bytes() == sidecar, 'hook rewrote owner identity'
    assert run(lock, 'invalid').returncode == 1, 'malformed runtime identity acquired native lock'
    assert run(own, OWNER+'\ninvalid').returncode == 1, 'multiline identity claimed native lock'
    # An inherited ID in an ordinary CLI process is not native identity proof.
    env['FM_FIXTURE_SUBCOMMAND'] = 'exec'
    assert run(own).returncode == 1, 'ordinary CLI inherited native ownership'
    assert run(lock).returncode == 1, 'ordinary CLI replaced native sidecar'
    env.pop('FM_FIXTURE_SUBCOMMAND')
    # A shared code-mode host has the same boundary, including Linux comm
    # truncation and vendor global config arguments before the subcommand.
    env['FM_FIXTURE_COMM'] = 'codex-code-mode'
    env['FM_FIXTURE_ARGV0'] = '/opt/codex-code-mode-host'
    assert run(own).returncode == 0, 'code-mode host owner lost its lock'
    assert run(lock, OTHER).returncode == 1, 'code-mode host accepted a competing session'
    assert run(own, thread_identity=OTHER).returncode == 1, 'code-mode host authorized a descendant shell thread'
    env.pop('FM_FIXTURE_COMM')
    env.pop('FM_FIXTURE_ARGV0')
    env['FM_FIXTURE_SUBCOMMAND'] = '-c features.hooks=true app-server'
    assert run(lock, OTHER).returncode == 1, 'global config flags hid the native server'
    assert run(own).returncode == 0, 'global config flags hid the owner'
    env.pop('FM_FIXTURE_SUBCOMMAND')
    # Old PID-only native locks cannot be upgraded by guessing their thread.
    (home / 'state/.lock-session').unlink()
    assert run(lock).returncode == 1, 'legacy shared-PID lock was claimed without owner identity'
    assert not (home / 'state/.lock-session').exists(), 'legacy owner identity was fabricated'
    (home / 'state/.lock-session').write_bytes(sidecar)
    # A symlink cannot serve as verified lock evidence for a native owner.
    (home / 'state/owner-pid').write_bytes(before)
    (home / 'state/.lock').unlink()
    (home / 'state/.lock').symlink_to(home / 'state/owner-pid')
    assert run(own).returncode == 1, 'symlinked lock proved ownership'
    assert run(lock).returncode == 1, 'symlinked lock was acquired'
    (home / 'state/.lock').unlink()
    # A genuinely dead process remains reclaimable with a fresh verified ID.
    (home / 'state/.lock').write_text('99999999\n')
    assert run(lock, thread_identity=OTHER).returncode == 1, 'descendant reclaimed a dead native lock as its root owner'
    assert run(lock, OTHER).returncode == 0, 'dead native process prevented verified recovery'
    assert run(own, OTHER).returncode == 0, 'new owner could not prove its reclaimed lock'
    # Removing the shared-server condition restores ordinary PID ownership.
    (home / 'state/.lock').unlink()
    (home / 'state/.lock-session').unlink()
    env['FM_FIXTURE_SUBCOMMAND'] = 'exec'
    assert run(lock, None).returncode == 0, 'ordinary Codex CLI lock acquisition regressed'
    assert run(lock, None).returncode == 0, 'ordinary Codex CLI reentry regressed'
    assert run(own, None).returncode == 0, 'ordinary Codex CLI ownership regressed'
    print('ok - distinct native sessions sharing a server cannot acquire or trust its owner lock')
