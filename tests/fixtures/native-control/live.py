"""Real Claude/Herdr public fm-control path; helper-scoped synthetic inputs."""
import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import time
import uuid

root = Path(os.environ['ROOT'])
scratch = Path(os.environ['SCRATCH'])
home = Path(os.environ['FM_HOME'])
helper = os.environ['HERDR_LAB_HELPER']
session = os.environ['HERDR_LAB_SESSION']
binary = os.environ['FM_NATIVE_CLAUDE_BIN']
busy = os.environ.get('FM_CLAUDE_NATIVE_BUSY_LIVE') == '1'


def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, check=True, **kwargs).stdout


def lab(*args):
    output = run([helper, 'run', session, *args])
    try:
        return json.loads(output)
    except ValueError:
        return output


def wait_for(fn, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            value = fn()
            if value:
                return value
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(.05)
    raise AssertionError('timed out waiting for live native state')


version = run([binary, '--version']).strip()
assert version in ('2.1.288 (Claude Code)', '2.1.292 (Claude Code)'), f'unsupported installed Claude: {version}'
print('LIVE', version, json.dumps(lab('status', '--json')), flush=True)
print('HEAD', run(['git', '-C', str(root), 'rev-parse', 'HEAD']).strip(), flush=True)
print('UNSUPPORTED: Muse, other harnesses, other Claude releases, other backends', flush=True)
shim = scratch / 'bin'
shim.mkdir()
(shim / 'claude').symlink_to(binary)
(shim / 'herdr').write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
assert args.count('--session') == 1
i=args.index('--session'); assert args[i+1] == os.environ['HERDR_LAB_SESSION']
del args[i:i+2]
with open(os.environ['NATIVE_HERDR_LOG'],'a') as f: f.write(json.dumps(args)+'\\n')
os.environ['PATH']=os.environ['HERDR_LAB_REAL_PATH']
os.execv(os.environ['HERDR_LAB_HELPER'],[os.environ['HERDR_LAB_HELPER'],'run',os.environ['HERDR_LAB_SESSION'],*args])
''')
(shim / 'herdr').chmod(0o700)
bridge = root / '.claude/mods/firstmate-native-control/bridge.py'


def scenario(name, draft, *, cursor=None, mode='normal', bracket=False):
    case = scratch / name
    case.mkdir()
    project = case / 'project'
    project.mkdir()
    marker = project / 'uncommitted.txt'
    marker.write_text('preserve live proof\n')
    config = case / 'claude-config'
    config.mkdir()
    (config / '.claude.json').write_text(json.dumps({
        'hasCompletedOnboarding': True, 'theme': 'dark',
        'projects': {str(project): {'hasTrustDialogAccepted': True}},
    }))
    plugin = case / 'observer'
    (plugin / '.claude-plugin').mkdir(parents=True)
    (plugin / 'hooks').mkdir()
    (plugin / '.claude-plugin/plugin.json').write_text('{"name":"native-live-observer","version":"1.0.0"}')
    (plugin / 'hooks/hooks.json').write_text('{"modules":["./register.ts"]}')
    (plugin / 'hooks/register.ts').write_text('''
const base = ''' + json.dumps(str(case)) + ''';
const mode = ''' + json.dumps(mode) + ''';
export const register = (on) => {
  on("turn.start", async ($, e, next) => {
    if (mode === "busy") await $.fs.write(base + "/running", "model-turn-started");
    return next(e);
  });
  on("prompt.fill", async ($, e, next) => {
    if (mode === "rewrite" && e.text.startsWith("FM_DISCARD_"))
      return next({...e, text:"MIDDLEWARE REWRITE"});
    const result = await next(e);
    if (e.mode === "replace" && e.text === "" && ["doorbell", "edit"].includes(mode)) {
      await $.fs.write(base + "/barrier.json", JSON.stringify(await $.prompt.read()));
      for (let i=0; i<300 && !(await $.fs.exists(base + "/release")); i++) await $.clock.sleep(20);
      await $.fs.write(base + "/released.json", JSON.stringify(await $.prompt.read()));
      if (!(await $.fs.exists(base + "/release"))) return {isFilled:false};
    }
    return result;
  });
  on("command.run", {command:"exit"}, async ($, e, next) => {
    await $.fs.write(base + "/exit-box.json", JSON.stringify(await $.prompt.read()));
    return next(e);
  });
};
''')
    # Busy mode uses the existing authenticated store and trusted worktree with
    # ordinary settings sources disabled. Only explicit test hook settings load.
    cwd = root if mode == 'busy' else project
    before_diff = run(['git', '-C', str(root), 'diff', '--binary'])
    workspace = lab('workspace', 'create', '--cwd', str(cwd), '--label', f'fm-{name}', '--no-focus')
    pane_info = workspace['result']['root_pane']
    pane = pane_info['pane_id']
    target = f'{session}:{pane}'
    channel = Path(run(['python3', str(bridge), 'prepare', str(home / 'state'), name, target]).strip())
    (home / f'state/{name}.meta').write_text(
        f'window={target}\nendpoint_task_id={name}\nworktree={cwd}\nproject={cwd}\n'
        f'backend=herdr\nharness=claude\nkind=ship\nnative_control={channel}\n'
        f"herdr_session={session}\nherdr_workspace_id={pane_info['workspace_id']}\n"
        f"herdr_tab_id={pane_info['tab_id']}\nherdr_pane_id={pane}\n")
    env = dict(os.environ, PATH=f"{shim}:{os.environ['PATH']}", CLAUDE_CONFIG_DIR=str(config),
               NATIVE_HERDR_LOG=str(case / 'herdr-calls.jsonl'), FM_CONTROL_SETTLE_WAIT='1',
               DISABLE_AUTOUPDATER='1', CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
    cmd = ['env', '-u', 'CLAUDECODE', f"PATH={env['PATH']}",
           'DISABLE_AUTOUPDATER=1', 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false',
           'CLAUDE_CODE_SEND_FEEDBACK=0']
    if mode != 'busy':
        cmd += [f'CLAUDE_CONFIG_DIR={config}']
    cmd += [str(root / 'bin/fm-claude-native-launch.sh'), str(channel),
            '--session-id', str(uuid.uuid4()), '--setting-sources', '', '--strict-mcp-config',
            '--mcp-config', '{"mcpServers":{}}', '--permission-mode', 'auto',
            '--tools', '', '--debug-file', str(case / 'claude-debug.log'),
            '--plugin-dir', str(plugin)]
    if mode == 'busy':
        gen = run(['bash', str(root / 'bin/fm-busy-event.sh'), 'arm', str(home / 'state'), name, '--state', 'idle']).strip()
        hooks = {}
        for event, state in [('UserPromptSubmit', 'busy'), ('Stop', 'idle'), ('StopFailure', 'idle'), ('SessionEnd', 'idle')]:
            argv = ['bash', str(root / 'bin/fm-busy-event.sh'), 'apply', str(home / 'state'), name, state, '--gen', gen,
                    '--source', 'claude-hook', '--event', event.lower()]
            hooks[event] = [{'hooks': [{'type': 'command', 'command': shlex.join(argv)}]}]
        cmd += ['--settings', json.dumps({'hooks': hooks}), '--model', 'haiku',
                '--system-prompt', 'You are a synthetic lifecycle test. Answer the prompt only in plain text. Tools are unavailable. Do not read or change files or start agents.']
    lab('pane', 'run', pane, shlex.join(cmd))
    try:
        ready = wait_for(lambda: json.loads((channel / 'ready.json').read_text()))
        lab('pane', 'report-agent', pane, '--source', 'fm-native-live', '--agent', 'claude', '--state', 'idle')
        if mode == 'busy':
            lab('pane', 'send-text', pane, 'Write a 6000-word plain-text description of an imaginary garden. Start immediately and continue until the description is complete.')
            lab('pane', 'send-keys', pane, 'enter')
            wait_for(lambda: (case / 'running').exists(), 60)
            wait_for(lambda: 'Stream started - received first chunk' in (case / 'claude-debug.log').read_text(), 60)
            assert 'state=busy' in (home / f'state/{name}.busy-state').read_text()
        if mode == 'image':
            png = case / 'synthetic.png'
            png.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
            draft = str(png)
            bracket = True
        if draft:
            lab('pane', 'send-text', pane, f'\x1b[200~{draft}\x1b[201~' if bracket else draft)
        if cursor:
            lab('pane', 'send-keys', pane, cursor)
        if mode == 'modal':
            lab('pane', 'send-text', pane, '/model')
            lab('pane', 'send-keys', pane, 'enter')
        time.sleep(.3)
        public = ['bash', str(root / 'bin/fm-control.sh'), name, 'exit']
        if name == 'multiline':
            ordinary = subprocess.run(public, text=True, capture_output=True, env=env)
            assert ordinary.returncode != 0 and 'pending text' in ordinary.stderr, ordinary.stdout + ordinary.stderr
        control = subprocess.Popen([*public, '--discard-pending'], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        if mode in ('doorbell', 'edit'):
            wait_for(lambda: (case / 'barrier.json').exists())
            assert json.loads((case / 'barrier.json').read_text())['text'] == ''
            if mode == 'edit':
                lab('pane', 'send-text', pane, 'EARLY_CONCURRENT_EDIT')
                time.sleep(.15)
            else:
                send = subprocess.run(['bash', str(root / 'bin/fm-send.sh'), name, 'Retain this synthetic durable steer.'], text=True, capture_output=True, env=env)
                assert send.returncode == 0 and 'input is locked' in send.stderr, send.stdout + send.stderr
                pending = list((home / f'state/{name}.inbox').glob('*.msg'))
                assert len(pending) == 1
                assert not list((home / f'state/{name}.inbox/handled').glob('*.msg'))
            (case / 'release').touch()
        out, err = control.communicate(timeout=35)
        refused = mode in ('modal', 'rewrite', 'edit')
        assert (control.returncode != 0) == refused, (name, out, err)
        if refused:
            assert not (case / 'exit-box.json').exists(), 'refusal invoked native exit'
            assert any(p['pid'] == ready['pid'] for p in lab('pane', 'process-info', '--pane', pane)['result']['process_info']['foreground_processes'])
            if mode == 'edit':
                assert json.loads((case / 'released.json').read_text())['text'] == 'EARLY_CONCURRENT_EDIT'
        else:
            assert 'stopped ' in out, out + err
            assert json.loads((case / 'exit-box.json').read_text()) == {'text': '', 'cursor': 0}
            assert not any(p['pid'] == ready['pid'] for p in lab('pane', 'process-info', '--pane', pane)['result']['process_info']['foreground_processes'])
        calls = [json.loads(line) for line in (case / 'herdr-calls.jsonl').read_text().splitlines()]
        assert not any(call[:2] in (['pane', 'send-text'], ['pane', 'submit']) for call in calls), calls
        keys = [call for call in calls if call[:2] == ['pane', 'send-keys']]
        assert (len(keys) == 1 if mode == 'busy' else not keys), keys
        assert lab('pane', 'get', pane)['result']['pane']['pane_id'] == pane
        assert marker.read_text() == 'preserve live proof\n'
        assert run(['git', '-C', str(root), 'diff', '--binary']) == before_diff
        print('PASS', name, 'refused' if refused else 'native exit; endpoint and files preserved', flush=True)
        return {'case': name, 'stdout': out, 'stderr': err, 'pid': ready['pid'], 'refused': refused}
    except Exception:
        print('FAILED', name, 'SCREEN', json.dumps(lab('pane', 'read', pane, '--source', 'visible', '--format', 'text')), flush=True)
        raise


if busy:
    results = [scenario('busy', 'QUEUED DRAFT\n\nTAIL', mode='busy')]
else:
    results = [
        scenario('empty', ''),
        scenario('beginning', 'alpha omega', cursor='ctrl+a'),
        scenario('middle', 'alpha omega', cursor='ctrl+b'),
        scenario('multiline', 'ALPHA\n\nBETA\n────────\n❯ title-like SUFFIX'),
        scenario('paste', '\n'.join(f'{i}: Unicode 日本語 café ❯ ──── {("x" * 130)}' for i in range(120)), bracket=True),
        scenario('literal-markers', ' [Image #1]\n[Pasted text #5 +119 lines]\n\t '),
        scenario('image', '', mode='image'),
        scenario('modal', '', mode='modal'),
        scenario('rewrite', 'KEEP ORIGINAL', mode='rewrite'),
        scenario('edit', 'OLD DRAFT', mode='edit'),
        scenario('doorbell', 'OLD DRAFT', mode='doorbell'),
    ]
(scratch / 'results.json').write_text(json.dumps(results, indent=2))
print('PASS live native control cases:', len(results), flush=True)
