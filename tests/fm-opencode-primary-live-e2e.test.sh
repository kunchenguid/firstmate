#!/usr/bin/env bash
# Opt-in native V2 primary regression. All server, TUI, and watcher state lives
# in a temporary project, never the user's background service or fleet home.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OPENCODE_LIVE_E2E opencode tmux python3
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
unset NO_MISTAKES_GATE

python3 - <<'PY'
import base64
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

root = Path(os.environ['ROOT'])
lab = Path(tempfile.mkdtemp(prefix='fm-opencode-v2-e2e-'))
project = lab / 'project'
server = None
socket_name = 'fm-opencode-v2-e2e-' + str(os.getpid())
log = None


def wait(predicate, label, seconds=180):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        if server is not None and server.poll() is not None:
            raise AssertionError('private OpenCode server exited: ' + (lab / 'server.log').read_text())
        time.sleep(0.2)
    raise AssertionError('timed out: ' + label)


def api(path, body=None):
    request = urllib.request.Request(
        base + path, data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': authorization, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.loads(response.read() or 'null')
        return payload.get('data') if isinstance(payload, dict) else None


def create():
    return api('/api/session', {
        'location': {'directory': str(project)},
        'model': {'providerID': 'opencode', 'id': 'big-pickle'},
        'permissions': [{'action': '*', 'resource': '*', 'effect': 'allow'}],
    })['id']


def context(session):
    return api('/api/session/' + session + '/context')


def prompt(session, text):
    previous = api('/api/session/' + session)['time'].get('idle', 0)
    api('/api/session/' + session + '/prompt', {'text': text, 'delivery': 'queue'})
    wait(lambda: api('/api/session/' + session)['time'].get('idle', 0) > previous,
         'model completes admitted prompt', seconds=600)


def ahoy(session, bearings):
    marker = project / 'state/ahoy-bearings'
    marker.unlink(missing_ok=True)
    prompt(session, '/ahoy')
    assert marker.exists() == bearings, 'Ahoy selected the wrong branch for the visible transcript'


def startup_count():
    return (project / 'state/session-start-count').read_text()


try:
    project.mkdir()
    subprocess.run(['git', 'init', '-q', str(project)], check=True)
    shutil.copytree(root / 'bin', project / 'bin')
    shutil.copytree(root / '.opencode', project / '.opencode')
    (project / 'state').mkdir()
    (project / 'config').mkdir()
    (project / 'config/supervision-host-off').touch()
    (project / 'AGENTS.md').write_text(
        '# Native OpenCode primary fixture\n\n'
        'Run `bin/fm-session-start.sh` once when the session-start instruction arrives.\n'
        'This is an isolated fixture; never operate on any other directory.\n')
    startup = project / 'bin/fm-session-start.sh'
    startup.write_text('#!/usr/bin/env bash\n'
                       'printf started >> "$FM_HOME/state/session-start-count"\n'
                       'cat "$FM_HOME/state/server-pid" > "$FM_HOME/state/.lock"\n'
                       'printf "SESSION START\\nSESSION_START_DONE\\n"\n')
    startup.chmod(0o755)
    for skill in ['ahoy', 'bearings']:
        (project / '.agents/skills' / skill).mkdir(parents=True)
    shutil.copyfile(root / '.agents/skills/ahoy/SKILL.md', project / '.agents/skills/ahoy/SKILL.md')
    (project / '.agents/skills/bearings/SKILL.md').write_text(
        '---\nname: bearings\ndescription: Test-only Bearings branch sentinel.\n---\n\n'
        'Run `printf gathered > "$FM_HOME/state/ahoy-bearings"` with the shell tool, then respond briefly.\n')
    env = dict(os.environ, FM_HOME=str(project), FM_ROOT_OVERRIDE=str(project),
               FM_STATE_OVERRIDE=str(project / 'state'), FM_CONFIG_OVERRIDE=str(project / 'config'),
               FM_POLL='1', FM_SIGNAL_GRACE='0', FM_HEARTBEAT='600',
               OPENCODE_DISABLE_AUTOUPDATE='1', OPENCODE_DISABLE_LSP_DOWNLOAD='1')
    for name in ['CONFIG', 'DATA', 'STATE', 'CACHE']:
        env['XDG_' + name + '_HOME'] = str(lab / name.lower())
    for name in ['OPENCODE_CONFIG', 'OPENCODE_CONFIG_CONTENT', 'OPENCODE_SERVER', 'OPENCODE_PASSWORD']:
        env.pop(name, None)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    log = (lab / 'server.log').open('w')
    server = subprocess.Popen(['opencode', 'serve', '--port', str(port), '--print-logs'],
                              cwd=project, env=env, stdout=log, stderr=log)
    (project / 'state/server-pid').write_text(str(server.pid) + '\n')
    password = wait(lambda: re.search(r'server password (\S+)', (lab / 'server.log').read_text()),
                    'private server authentication', seconds=30).group(1)
    base = 'http://127.0.0.1:' + str(port)
    authorization = 'Basic ' + base64.b64encode(('opencode:' + password).encode()).decode()
    wait(lambda: len([plugin for plugin in api('/api/plugin')
                      if plugin['id'].startswith('firstmate.primary.')
                      and plugin['state']['status'] == 'active']) == 5,
         'all five primary plugins load', seconds=30)

    session = create()
    wait(lambda: (project / 'state/session-start-count').exists(), 'native startup tool execution')
    wait(lambda: api('/api/session/' + session)['time'].get('idle'), 'startup completion')
    users = [message['text'] for message in context(session) if message['type'] == 'user']
    assert len(users) == 1 and users[0].startswith('\u2063FIRSTMATE_OP: v1 session-start: '), users
    assert startup_count() == 'started', 'session start must execute once'
    ahoy(session, True)
    prompt(session, 'Respond exactly PRIOR_BOUNDARY_ACK.')
    ahoy(session, False)
    assert startup_count() == 'started', 'later prompts must not rerun startup'

    watcher = '\u2063FIRSTMATE_OP: v1 watcher: CURRENT_AHOY_WATCHER_BODY'
    near_misses = [
        '\u2063Captain note: this invisible separator is intentional.',
        'Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.',
        'Captain quote: ' + watcher,
        'FIRSTMATE_OP: v1 watcher: captain-authored text',
    ]
    for preceding in near_misses:
        case = create()
        prompt(case, preceding)
        ahoy(case, False)
        # Ahoy's own helm check may legitimately run startup in a fresh session,
        # so the nudge's lock-owner suppression is asserted on delivered input.
        assert not any(message['type'] == 'user' and message['text'].startswith('\u2063FIRSTMATE_OP: v1 session-start: ')
                       for message in context(case)), 'session-lock owner must suppress duplicate startup nudges'

    def shell_errors():
        return '\n'.join(str(part['state'].get('error', '')) for message in context(session) if message['type'] == 'assistant'
                         for part in message['content'] if part['type'] == 'tool')
    prompt(session, 'Use the shell tool separately for each exact command without rewriting it: '
                    '`cd /tmp; printf denied > "' + str(project / 'state/cd-denied') + '"`; '
                    '`(cd /tmp; printf allowed > "' + str(project / 'state/cd-allowed') + '")`; '
                    '`printf complete > "' + str(project / 'state/pretool-complete') + '"`. '
                    'Do not retry denied commands.')
    assert not (project / 'state/cd-denied').exists(), 'persistent cd command ran'
    assert (project / 'state/cd-allowed').read_text() == 'allowed', 'subshell cd was incorrectly denied'
    assert (project / 'state/pretool-complete').read_text() == 'complete', 'ordinary shell command failed'
    assert 'persistent-cd' in shell_errors(), shell_errors()
    prompt(session, 'Use the shell tool once to run this exact command without rewriting it: '
                    '`bin/fm-watch-arm.sh | cat; printf denied > "' + str(project / 'state/arm-denied') + '"`. '
                    'Do not retry it or read any file about it.')
    assert not (project / 'state/arm-denied').exists(), 'bundled watcher arm ran'
    assert 'watcher-pipeline' in shell_errors(), shell_errors()

    env['OPENCODE_PASSWORD'] = password
    tui = 'env ' + ' '.join(shlex.quote(key + '=' + value) for key, value in env.items())
    tui += ' opencode --server ' + shlex.quote(base) + ' --session ' + session
    subprocess.run(['tmux', '-L', socket_name, 'new-session', '-d', '-s', 'fixture', '-c', str(project), tui], check=True)
    def capture():
        return subprocess.run(['tmux', '-L', socket_name, 'capture-pane', '-p', '-t', 'fixture', '-S', '-800'],
                              capture_output=True, text=True, check=True).stdout
    wait(lambda: 'Big Pickle' in capture(), 'persistent TUI displays native session', seconds=30)
    (project / 'state/opencode-e2e.meta').write_text('project=fixture\n')
    prompt(session, 'Respond exactly INITIAL_IDLE_ACK. If a later watcher wake arrives, run '
                   '`bin/fm-wake-drain.sh`, run the exact WAKE_ACK_REQUIRED command it prints, then '
                   '`printf handled > "' + str(project / 'state/opencode-model-handled') + '"`. '
                   'Never run or request any watcher arm command.')
    pid_file = project / 'state/.watch.lock/pid'
    wait(lambda: pid_file.exists(), 'native completion starts initial watcher')
    (project / 'state/opencode-e2e.status').write_text('done: opencode live e2e watcher fire\n')
    ledger = project / 'state/.watch-cycle-exits.log'
    wait(lambda: ledger.exists() and re.search(r'reason=actionable-signal.*successor=started:[0-9]+', ledger.read_text()),
         'actionable close starts and links successor')
    wait(lambda: (project / 'state/opencode-model-handled').exists(), 'queued watcher prompt drives model handling')
    users = [message['text'] for message in context(session) if message['type'] == 'user']
    assert any(text.startswith('\u2063FIRSTMATE_OP: v1 watcher: ') for text in users)
    assert not any('TURN WOULD END BLIND' in text for text in users), 'healthy successor triggered blind-turn followup'
    assert 'Big Pickle' in capture(), 'persistent TUI stopped displaying the native session after the watcher followup'
    # Disable only the watch owner in this fixture to exercise the guard's
    # recovery followup, rather than merely proving guard/watch coordination.
    watch_plugin = project / '.opencode/plugins/fm-primary-watch-arm.js'
    watch_plugin.rename(watch_plugin.with_suffix('.disabled'))
    api('/api/location/reload', {})
    wait(lambda: all(plugin['id'] != 'firstmate.primary.watch-arm' for plugin in api('/api/plugin')),
         'watch owner disposal', seconds=30)
    wait(lambda: not pid_file.exists(), 'disposed watch owner retires its child', seconds=30)
    prompt(session, 'Respond briefly. If a turn-end-guard recovery instruction arrives, acknowledge it '
                    'without running commands; this fixture intentionally has no watch plugin.')
    wait(lambda: any(message['type'] == 'user'
                     and message['text'].startswith('\u2063FIRSTMATE_OP: v1 turn-end-guard: ')
                     for message in context(session)), 'native guard queues recovery followup')
    assert 'Big Pickle' in capture(), 'persistent TUI stopped displaying the native session after the guard followup'
    print('ok - OpenCode ' + subprocess.check_output(['opencode', '--version'], text=True).strip()
          + ' native E2E covered five active plugins, startup, Ahoy boundaries, shell denials, TUI, watcher continuity, and guard recovery')
finally:
    subprocess.run(['tmux', '-L', socket_name, 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if server is not None:
        server.terminate()
        try:
            server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
    if log is not None:
        log.close()
    pid_file = project / 'state/.watch.lock/pid'
    if pid_file.exists():
        pid = int(pid_file.read_text())
        command = subprocess.run(['ps', '-p', str(pid), '-o', 'args='], capture_output=True, text=True).stdout
        if str(project) in command:
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
    shutil.rmtree(lab)
PY
