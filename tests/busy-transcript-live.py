#!/usr/bin/env python3
"""Executable fixture for fm-busy-transcript-live-e2e.test.sh, not a model proxy.

Only the isolated subprocess serves HTTP. The driving process has no listener.
All Herdr operations go through the caller's guarded lab helper.
"""
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import threading
import time
import uuid


def command(*args, **kwargs):
    return subprocess.check_output([str(arg) for arg in args], text=True, **kwargs).strip()


def serve(root, lab, tool):
    home = lab / (tool + '-home')
    control = lab / (tool + '-mode')

    class Provider(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            mode = control.read_text().strip()
            with (lab / (tool + '-requests.jsonl')).open('a') as stream:
                stream.write(json.dumps({'at': time.time(), 'mode': mode, 'path': self.path}) + '\n')
            if mode == 'failure':
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b'{"error":{"message":"FM_SIMULATED_401"}}')
                return
            if mode in ('hold', 'launch'):
                time.sleep(25 if mode == 'hold' else 2)
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            rid, mid = 'resp_' + uuid.uuid4().hex, 'msg_' + uuid.uuid4().hex
            if mode in ('tool', 'ack'):
                control.write_text('success')
                name = 'Bash' if tool == 'traex' else 'exec_command'
                args = {'command': 'sleep 6; exit 7'} if tool == 'traex' else {'cmd': 'sleep 6; exit 7', 'yield_time_ms': 10000}
                if mode == 'ack':
                    inbox = lab / ('home/state/' + tool + '.inbox')
                    command_text = 'cat ' + shlex.quote(str(inbox / '001.msg')) + '; mkdir -p ' + shlex.quote(str(inbox / 'handled')) + '; mv ' + shlex.quote(str(inbox / '001.msg')) + ' ' + shlex.quote(str(inbox / 'handled/001.msg'))
                    args = {'command': command_text} if tool == 'traex' else {'cmd': command_text, 'yield_time_ms': 10000}
                item = {'type': 'function_call', 'id': mid, 'call_id': 'call_' + uuid.uuid4().hex,
                        'name': name, 'arguments': json.dumps(args), 'status': 'completed'}
            else:
                item = {'type': 'message', 'id': mid, 'role': 'assistant', 'status': 'completed',
                        'content': [{'type': 'output_text', 'text': 'FM_LIVE_OK', 'annotations': []}]}
            events = [
                {'type': 'response.created', 'response': {'id': rid, 'status': 'in_progress', 'output': []}},
                {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                {'type': 'response.completed', 'response': {'id': rid, 'status': 'completed', 'output': [item],
                    'usage': {'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15}}},
            ]
            try:
                for event in events:
                    self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config = f'''model = "gpt-6-astra"
model_provider = "lab"
[features]
hooks = false
[model_providers.lab]
name = "Local simulated provider"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
base_url = "http://127.0.0.1:{server.server_port}/v1"
'''
    if (lab / 'enable-hooks').exists():
        config = config.replace('hooks = false', 'hooks = true')
    (home / ('config.toml' if tool == 'codex' else 'traecli.toml')).write_text(config)
    # These are the managed fm-spawn TUI flags, including Codex's notify and
    # TraeX's environment identity. Worktree provisioning is outside this probe.
    binary = json.loads((lab / 'binaries.json').read_text())[tool]
    args = [binary, '--model', 'gpt-6-astra', '-c', 'model_reasoning_effort="low"']
    if tool == 'codex':
        notify = ['bash', '-c', 'touch ' + shlex.quote(str(lab / 'home/state/codex.turn-ended'))]
        args += ['--dangerously-bypass-approvals-and-sandbox', '-c', 'notify=' + json.dumps(notify)]
    else:
        args += ['-y']
    prompt = command(root / 'bin/fm-operational-input.sh', 'encode', 'launch-brief',
                     input='Disposable isolated lifecycle probe. Reply FM_LIVE_OK. No external services.')
    gen = (lab / 'home/state' / (tool + '.busy-gen')).read_text().strip()
    args += [prompt + '\nFIRSTMATE_BUSY_GENERATION=' + gen]
    if len(sys.argv) > 5:
        # Spawn regression: preserve the real launch owner's exact argv.
        args = [binary] + sys.argv[5:]
    (lab / (tool + '-argv.json')).write_text(json.dumps(args))
    env = dict(os.environ, FM_HOME=str(lab / 'home'), FM_TASK_ID=tool,
               GOTMPDIR='/tmp/fm-' + tool + '/gotmp')
    for name in ('CLAUDECODE', 'PI_CODING_AGENT', 'GROK_AGENT', 'FM_PI_HARNESS'):
        env.pop(name, None)
    if tool == 'traex':
        env['FM_TRAEX_HARNESS'] = 'traex'
    try:
        result = subprocess.run(args, cwd=lab / (tool + '-project'), env=env)
    finally:
        server.shutdown()
    sys.exit(result.returncode)


def drive(root, lab, helper, session):
    assert session.startswith('fm-lab-') and session != 'default'
    binaries = {tool: str(Path(shutil.which(tool)).resolve()) for tool in ('codex', 'traex')}
    (lab / 'binaries.json').write_text(json.dumps(binaries))
    versions = {tool: command(binary, '--version') for tool, binary in binaries.items()}
    print('versions: ' + json.dumps(versions), flush=True)
    state = lab / 'home/state'
    state.mkdir(parents=True)
    (lab / 'home/data').mkdir()
    (lab / 'home/config').mkdir()
    (lab / 'home/config/backlog-backend').write_text('manual\n')
    real_home = Path.home().resolve()
    # Sandbox hides every real-home namespace. Bind only these installed
    # packages and the disposable test checkout/lab back into it.
    mounts = ['bwrap', '--die-with-parent', '--unshare-user', '--unshare-pid', '--unshare-net',
              '--ro-bind', '/', '/', '--tmpfs', str(real_home), '--tmpfs', '/tmp', '--proc', '/proc', '--dev', '/dev']
    for tool, binary in binaries.items():
        package = Path(binary).parent
        if tool == 'codex' and package.name == 'bin':
            package = package.parent
        mounts += ['--ro-bind', str(package), str(package)]
    mounts += ['--bind', str(root), str(root)]
    if not lab.is_relative_to(root):
        mounts += ['--bind', str(lab), str(lab)]
    mounts += ['--tmpfs', '/run/user/' + str(os.getuid()), '--chdir', str(lab)]
    for name in ('CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'HERDR_SOCKET_PATH', 'HERDR_ENV', 'TRAE_SESSION_ID'):
        mounts += ['--unsetenv', name]
    mounts += ['--setenv', 'TMPDIR', str(lab), '--setenv', 'CODEX_HOME', str(lab / 'codex-home'),
               '--setenv', 'TRAE_HOME', str(lab / 'traex-home')]
    command(*mounts, '--', '/usr/bin/true')

    def herdr(*args):
        return command(helper, 'run', session, *args)

    wrap = lab / 'recovery-wrap'
    wrap.mkdir()
    transport = wrap / 'herdr'
    real_herdr = shutil.which('herdr')
    transport.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
real, helper, session = CONFIG
args = sys.argv[1:]
if os.environ.get('FM_LIVE_INSIDE_HELPER') == '1':
    os.execv(real, [real] + args)
assert args[-2:] == ['--session', session]
sys.exit(subprocess.call([helper, 'run', session] + args[:-2],
    env=dict(os.environ, FM_LIVE_INSIDE_HELPER='1')))
'''.replace('CONFIG', repr((real_herdr, helper, session))))
    transport.chmod(0o755)
    recovery_env = dict(os.environ, FM_HOME=str(lab / 'home'), PATH=str(wrap) + ':' + os.environ['PATH'])
    for key in ('FM_STATE_OVERRIDE', 'FM_ROOT_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE'):
        recovery_env.pop(key, None)

    control_script = lab / 'control.sh'
    control_script.write_text('''#!/usr/bin/env bash
set -eu
root=$1 lab=$2 helper=$3 session=$4 tool=$5 pane=$6 action=$7
export FM_HOME=$lab/home
source "$root/bin/fm-backend.sh"
source "$root/bin/fm-busy-lib.sh"
fm_backend_source herdr
fm_backend_herdr_cli() {
  [ "$1" = "$session" ] || return 97
  shift
  "$helper" run "$session" "$@"
}
target=$session:$pane
case "$action" in
 read) fm_busy_classify_live herdr "$target" "$tool" "$tool" "$FM_HOME/state" ;;
 enter) fm_backend_send_key herdr "$target" Enter ;;
 interrupt) fm_backend_send_key herdr "$target" Escape
   [ "$tool" != traex ] || fm_backend_send_key herdr "$target" C-u ;;
esac
''')
    reader = root / 'bin/fm-busy-transcript.py'
    for tool in binaries:
        try:
            project = lab / (tool + '-project')
            project.mkdir()
            (lab / (tool + '-home')).mkdir()
            command('git', '-C', project, 'init', '-q')
            (project / 'AGENTS.md').write_text('Disposable lab. No network services or delegation.\n')
            created = json.loads(herdr('workspace', 'create', '--cwd', project, '--label', 'busy-' + tool))
            panes = []
            def visit(value):
                if isinstance(value, dict):
                    if isinstance(value.get('pane_id'), str):panes.append(value['pane_id'])
                    for child in value.values():visit(child)
                elif isinstance(value, list):
                    for child in value:visit(child)
            visit(created)
            assert len(set(panes)) == 1, created
            pane = panes[0]
            target = session + ':' + pane
            gen = command(root / 'bin/fm-busy-event.sh', 'arm', state, tool, '--state', 'unknown')
            pane_data = json.loads(herdr('pane', 'get', pane))['result']['pane']
            (state / (tool + '.meta')).write_text(f'harness={tool}\nkind=scout\nworktree={project}\nbackend=herdr\nwindow={target}\nbusy_gen={gen}\n'
                f'herdr_session={session}\nherdr_workspace_id={pane_data["workspace_id"]}\nherdr_tab_id={pane_data["tab_id"]}\nherdr_pane_id={pane}\n')
            sessions = lab / (tool + '-home') / ('sessions' if tool == 'codex' else 'cli/sessions')
            command('python3', reader, 'init', state, tool, tool, project, sessions, 'herdr', target)
            def control(action):
                return command('bash', control_script, root, lab, helper, session, tool, pane, action, env=recovery_env)
            def wait(want, seconds=15):
                deadline = time.monotonic() + seconds
                actual = ''
                while time.monotonic() < deadline:
                    actual = control('read')
                    if actual == want:return
                    time.sleep(.15)
                raise AssertionError((want, actual))
            def send(text):
                herdr('pane', 'send-text', pane, text)
                time.sleep(.3)
                control('enter')
            mode = lab / (tool + '-mode')
            mode.write_text('success')
            assert control('read').startswith(('unknown ', 'dead '))
            launcher = lab / (tool + '-launch.sh')
            launcher.write_text('#!/bin/sh\nexec ' + shlex.join(mounts + ['--chdir', str(project), '--', 'python3', str(Path(__file__).resolve()), 'serve', str(root), str(lab), tool]) + '\n')
            herdr('pane', 'send-text', pane, 'bash ' + shlex.quote(str(launcher)))
            time.sleep(.3)
            herdr('pane', 'send-keys', pane, 'enter')
            # Grant only the private generated project folder, after observing
            # its actual fresh-directory chooser. No hook trust bypass is used.
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                screen = herdr('pane', 'read', pane, '--source', 'recent', '--lines', '200')
                if ('Trust this folder?' in screen or 'Do you trust the contents of this directory?' in screen):
                    herdr('pane', 'send-keys', pane, 'enter')
                    break
                time.sleep(.2)
            else:raise AssertionError('fresh-directory trust chooser missing')
            command('python3', reader, 'activate', state, tool)
            wait('idle ' + tool + '-transcript')
            print('ok - ' + tool + ' default TUI startup and completion', flush=True)
            # Restore the actual original generation, then exercise subsequent
            # text/key/state paths with the recovered process seal in place.
            info = json.loads(herdr('pane', 'process-info', '--pane', pane))['result']['process_info']
            pid, = [p['pid'] for p in info['foreground_processes'] if p['name'] == tool and any(arg.startswith('\u2063FIRSTMATE_OP: v1 launch-brief:') for arg in p.get('argv', []))]
            command(root / 'bin/fm-busy-event.sh', 'retire', state, tool, '--gen', gen)
            receipt = lab / (tool + '-recovery.json')
            receipt.write_text(command(root / 'bin/fm-busy-event.sh', 'recover', state, tool,
                '--check', '--terminal', pane_data['terminal_id'], '--pid', pid, env=recovery_env))
            command(root / 'bin/fm-busy-event.sh', 'recover', state, tool, '--apply', receipt, env=recovery_env)
            print('ok - ' + tool + ' real original-generation recovery', flush=True)
            inbox = state / (tool + '.inbox')
            inbox.mkdir()
            record = inbox / '001.msg'
            record.write_text('schema=fm-task-inbox.v1\n--\nRead and acknowledge this harmless lab instruction.\n')
            record_bytes = record.read_bytes()
            mode.write_text('ack')
            ring_script = 'set -eu\nsource "$1/bin/fm-backend.sh"\nsource "$1/bin/fm-task-inbox-lib.sh"\nfm_task_inbox_ring herdr "$2" "$3" "fm-$4"\n'
            command('bash', '-c', ring_script, '_', root, target, record, tool, env=recovery_env)
            deadline = time.monotonic() + 15
            handled = inbox / 'handled/001.msg'
            while time.monotonic() < deadline:
                if handled.exists():
                    break
                time.sleep(.2)
            else:
                raise AssertionError('recovered steering message was not acknowledged')
            assert handled.read_bytes() == record_bytes
            wait('idle ' + tool + '-transcript')
            print('ok - ' + tool + ' recovered steering read and acknowledged one durable message', flush=True)
            mode.write_text('hold')
            send('Hold the simulated response.')
            wait('busy ' + tool + '-transcript')
            control('interrupt')
            wait('idle ' + tool + '-transcript')
            print('ok - ' + tool + ' active turn and user interrupt', flush=True)
            mode.write_text('tool')
            send('Execute the simulated failing tool.')
            wait('busy ' + tool + '-transcript', 4)
            wait('idle ' + tool + '-transcript')
            mode.write_text('failure')
            send('Return the simulated API failure.')
            wait('idle ' + tool + '-transcript')
            # The vendor records, not the simulator, must prove the tool ran
            # and the API error ended this session's turn.
            binding = json.loads((state / (tool + '.busy-session')).read_text())
            text = Path(binding['bound']['path']).read_text()
            assert 'FM_SIMULATED_401' in text and 'turn_aborted' in text
            assert 'exited with code 7' in text or 'Exit code: 7' in text or '"exit_code":7' in text or '"exit_code": 7' in text, 'tool did not execute'
            evidence = []
            for line in text.splitlines():
                record = json.loads(line)
                payload = record.get('payload', {})
                if record.get('type') == 'event_msg' and payload.get('type') in ('task_started', 'task_complete', 'turn_aborted'):
                    event = {key: payload[key] for key in ('type', 'turn_id', 'root_turn_id', 'started_at', 'completed_at', 'duration_ms', 'reason') if key in payload}
                    event['error'] = bool(payload.get('error'))
                    evidence.append({'timestamp': record['timestamp'], 'ordinal': record['ordinal'], 'payload': event})
            print('evidence - ' + json.dumps({'tool': tool, 'session_id': binding['bound']['sid'],
                'generation': gen, 'events': evidence, 'tool_exit_code': 7}), flush=True)
            print('ok - ' + tool + ' real tool failure and simulated API failure', flush=True)
            send('/exit' if tool == 'codex' else '/quit')
            wait('dead endpoint-gone')
            print('ok - ' + tool + ' process exit overrides a completed transcript', flush=True)
            # Abrupt endpoint disappearance is independently checked by the
            # public classifier while its bound record still exists.
            herdr('workspace', 'close', pane.split(':')[0])
            wait('dead endpoint-gone')
            print('ok - ' + tool + ' endpoint death', flush=True)
        except Exception as error:
            raise RuntimeError(tool + ' ' + versions[tool] + ': ' + str(error)) from error


if __name__ == '__main__':
    if sys.argv[1] == 'serve':
        serve(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
    else:
        drive(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5])
