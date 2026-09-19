#!/usr/bin/env bash
# Opt-in credentialed Codex regression exercising native async Stop ownership,
# idle wake delivery, user turns and session shutdown in an isolated real TUI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.codex-live-e2e.$$"
CODEX_VERSION=$(codex --version)
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB"
printf 'Testing %s native Stop delivery\n' "$CODEX_VERSION"

# Native async delivery must wake a real idle TUI, not merely enqueue a message
# for a future user turn. Keep all hooks, processes and fleet state in this lab.
python3 - "$ROOT" "$LAB/native" <<'PY'
import fcntl, json, os, pathlib, pty, select, shutil, signal, struct, subprocess, sys, termios, time
root, lab = map(pathlib.Path, sys.argv[1:])
lab.mkdir(parents=True)
subprocess.run(['git', 'init', '-q', str(lab)], check=True)
shutil.copytree(root / 'bin', lab / 'bin')
(lab / 'state').mkdir()
(lab / 'config').mkdir()
(lab / '.codex').mkdir()
hooks = json.loads((root / '.codex/hooks.json').read_text())
hooks = {'hooks': {'Stop': hooks['hooks']['Stop'], 'SessionStart': [{'hooks': [{
    'type': 'command', 'command': f'bash "{lab}/bin/fm-lock.sh" >/dev/null'
}]}]}}
(lab / '.codex/hooks.json').write_text(json.dumps(hooks))
(lab / 'AGENTS.md').write_text('''This is an isolated native hook verification fixture.
Do not read other directories, dispatch agents or initialize projects.
When a Firstmate watcher wake arrives, run bin/fm-wake-drain.sh and its exact acknowledgement command, then append HANDLED to handled.txt and reply HANDLED.
Never start a watcher or checkpoint yourself; the native Stop hook owns it.
''')
check = lab / 'state/probe.check.sh'
check.write_text('#!/usr/bin/env bash\nexit 0\n')
check.chmod(0o700)
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_'):
        del env[key]
env.update(FM_HOME=str(lab), FM_POLL='1', FM_CHECK_INTERVAL='99999', FM_SIGNAL_GRACE='1')
subprocess.run([str(lab / 'bin/fm-check-register.sh'), 'probe'], env=env, check=True, capture_output=True)
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
command = ['codex', '--dangerously-bypass-hook-trust', '--no-alt-screen', '-C', str(lab),
           '-c', f'projects."{lab}".trust_level="trusted"',
           'Reply exactly READY without running tools.']
process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
                           preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
os.close(slave)
transcript = bytearray()
trusted = False
def pump():
    global trusted
    if select.select([master], [], [], .1)[0]:
        try:
            transcript.extend(os.read(master, 65536))
            (lab / 'native-transcript.txt').write_bytes(transcript)
        except OSError:
            pass
    if not trusted and b'Yes, continue' in transcript and b'Press enter to continue' in transcript:
        time.sleep(1)
        os.write(master, b'\r')
        trusted = True
    if process.poll() is not None:
        raise AssertionError(f'Codex exited unexpectedly: {process.returncode}')
def wait_for(predicate, label, seconds=120):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        pump()
        if predicate():
            return
    raise AssertionError(f'timed out: {label}; transcript tail: {transcript[-6000:]!r}')
def owner_ready():
    try:
        record = json.loads((lab / 'state/.codex-autoarm.json').read_text())
        return subprocess.run([str(lab / 'bin/fm-codex-stop-autoarm.sh'), '--ready',
                               record['session'], 'next-turn'], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, ValueError):
        return False
try:
    wait_for(owner_ready, 'first idle Stop arms watcher')
    original_owner = json.loads((lab / 'state/.codex-autoarm.json').read_text())['pid']
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        pump()
    os.write(master, b'Write USER_OK to user-reply.txt, then reply STATUS.')
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        pump()
    os.write(master, b'\r')
    wait_for(lambda: (lab / 'user-reply.txt').exists(), 'ordinary user message handled while watcher stays armed')
    wait_for(owner_ready, 'watcher stays armed after ordinary user turn')
    assert json.loads((lab / 'state/.codex-autoarm.json').read_text())['pid'] == original_owner, 'user turn duplicated the watcher owner'
    for number in (1, 2):
        # A quiet idle interval must neither kill supervision nor spend a turn.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            pump()
        assert owner_ready(), 'quiet idle lost callback/watcher ownership'
        with (lab / 'state/demo.status').open('a') as output:
            output.write(f'done: native wake {number}\n')
        wait_for(lambda: (lab / 'handled.txt').exists() and
                 (lab / 'handled.txt').read_text().count('HANDLED') >= number,
                 f'idle native wake {number} handled')
        wait_for(owner_ready, f'Stop rearms after wake {number}')
    assert b'TURN WOULD END BLIND' not in transcript, 'healthy native Stop emitted blind warning'
    callback_pid = int(json.loads((lab / 'state/.codex-autoarm.json').read_text())['pid'])
    watcher_pid = int((lab / 'state/.watch.lock/pid').read_text())
finally:
    (lab / 'native-transcript.txt').write_bytes(transcript)
    # Kill only this test-owned TUI group. Native hook children must also end.
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    os.close(master)
def live(pid):
    result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')
deadline = time.monotonic() + 10
while time.monotonic() < deadline and (live(callback_pid) or live(watcher_pid)):
    time.sleep(.1)
assert not live(callback_pid) and not live(watcher_pid), 'native shutdown orphaned callback or watcher'
print('ok - Codex native Stop survives idle and user turns, handles two wakes, and reaps watcher on shutdown')
PY
