"""Bounded real-CLI/PTY resource check; no model calls or external repositories."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='moiras-budget-') as name:
    home = Path(name)
    (home / 'state').mkdir()
    (home / 'state/.last-watcher-beat').touch()
    for i in range(70):
        (home / f'state/sample-{i}.meta').write_text('harness=pi\nmodel=sample\neffort=low\n')
        (home / f'state/sample-{i}.status').write_text('working: checks running\n')
    env = dict(os.environ, FM_HOME=name, TERM='xterm-256color')
    env.pop('NO_COLOR', None)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
    child = subprocess.Popen([str(root / 'bin/fm-moiras.sh'), 'start', '--no-llm'], env=env,
                             stdin=slave, stdout=slave, stderr=slave)
    # Keep the slave open until the final drain: macOS discards queued output on last close.
    output = bytearray()

    def drain():
        while select.select([master], [], [], 0)[0]:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            output.extend(data)

    def status():
        result = subprocess.run([str(root / 'bin/fm-moiras.sh'), 'status', '--json'],
                                env=env, capture_output=True, text=True, timeout=10, check=True)
        data = json.loads(result.stdout)
        assert len(data['workers']) == 70, 'resource fixture was not actually observed'
        return data['server']

    try:
        deadline = time.monotonic() + 10
        while not (home / 'state/moiras/snapshot.json').exists():
            assert child.poll() is None, 'server exited during startup'
            assert time.monotonic() < deadline, 'no initial snapshot'
            drain()
            time.sleep(.1)
        for _ in range(5):
            drain()
            time.sleep(1)
        first = status()
        assert first['pid'] == child.pid, 'reported the status command, not the server'
        start = time.monotonic()
        maximum = first['rssBytes']
        for _ in range(30):
            drain()
            time.sleep(1)
            rss = subprocess.check_output(['ps', '-p', str(child.pid), '-o', 'rss='], text=True)
            maximum = max(maximum, int(rss.strip()) * 1024)
        last = status()
        seconds = time.monotonic() - start
        maximum = max(maximum, last['rssBytes'])
        percent = (last['cpuSeconds'] - first['cpuSeconds']) / seconds * 100
        drain()
        result = dict(windowSeconds=seconds, maxRssBytes=maximum, idleCpuPercent=percent,
                      reportedCpuPercent=last['cpuPercent'], pid=child.pid, tasks=70,
                      animated=b'\x1b[?1049h' in output, platform=sys.platform)
    finally:
        if child.poll() is None:
            child.send_signal(signal.SIGINT)
        try:
            child.wait(timeout=15)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            raise
        drain()
        os.close(slave)
        os.close(master)
    result['exit'] = child.returncode
    result['stoppedServer'] = status()
    result['restored'] = b'\x1b[?1049l' in output
    print(json.dumps(result))
    if not result['restored']:
        sys.stderr.write(output.decode(errors='replace')[-2000:])
    assert result['restored'], 'terminal was not restored'
