#!/usr/bin/env python3
"""Exercise the shell worker lifecycle with a real Linux child subreaper."""
import ctypes
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1]).resolve()
if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "cannot become child subreaper")
fixture = Path(tempfile.mkdtemp(prefix="fm-subreaper-"))
root = fixture / "root"
(root / "bin").mkdir(parents=True)
account = fixture / "account"
account.mkdir()
(root / "AGENTS.md").write_text("fixture\n")
worker = root / "bin/fm-remote-job-worker.sh"
known = set()


def processes():
    result = {}
    for path in Path("/proc").iterdir():
        if not path.name.isdigit():
            continue
        try:
            args = (path / "cmdline").read_bytes().split(b"\0")
            if os.fsencode(worker) not in args:
                continue
            fields = (path / "stat").read_text().rsplit(") ", 1)[1].split()
            result[int(path.name)] = (int(fields[1]), int(fields[2]), "--serve" in [os.fsdecode(a) for a in args])
        except (FileNotFoundError, ProcessLookupError):
            continue
    known.update(result)
    return result


def reap():
    for pid in list(known):
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            pass


def wait_for(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        reap()
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("condition did not become true before deadline")


def call(script, queue):
    env = dict(os.environ, HOME=str(account), FM_ROOT_OVERRIDE=str(root),
               FM_REMOTE_JOB_STATE_ROOT=str(queue), FM_REMOTE_JOB_PLATFORM_OVERRIDE="Linux")
    proc = subprocess.Popen(["bash", "-c", '. "$1/bin/fm-remote-job-lib.sh"\n' + script,
                             "fixture", str(repo)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(lambda: proc.poll() is not None, 20)
        out, err = proc.communicate()
        assert proc.returncode == 0, (out, err)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


try:
    # Recreate older independent restart supervisors using actual processes,
    # while production start and stop own every lifecycle operation under test.
    worker.write_text('''#!/bin/bash
trap 'exit 0' TERM
if [ "${1:-}" = --serve ]; then
  echo "$$" > "$FM_REMOTE_JOB_STATE_ROOT/worker.pid"
  while :; do sleep 0.1; done
fi
while :; do
  "$0" --serve &
  wait "$!"
done
''')
    worker.chmod(0o755)
    queue = fixture / "queue"
    other = fixture / "other-queue"
    start = 'fm_remote_job_start_linux_worker "$FM_ROOT_OVERRIDE" "$HOME"'
    call(start, queue)
    wait_for(lambda: len(processes()) == 2)
    call(start, queue)
    wait_for(lambda: len(processes()) == 4)
    call(start, other)
    wait_for(lambda: len(processes()) == 6)
    snapshot = processes()
    assert all(parent == os.getpid() and group == pid
               for pid, (parent, group, serving) in snapshot.items() if not serving)
    other_child = int((other / "worker.pid").read_text())
    other_group = snapshot[other_child][1]
    call('fm_remote_job_stop_worker_tree "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")"', queue)
    wait_for(lambda: len(processes()) == 2)
    for _ in range(30):
        assert all(group == other_group for _, group, _ in processes().values()), "worker respawned after stop"
        reap()
        time.sleep(0.1)
    assert other_child in processes(), "stop reached another queue"
    call('fm_remote_job_stop_worker_tree "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")"', other)
    wait_for(lambda: not processes())
    print("ok - stop finds adopted sibling supervisors, prevents respawn, and preserves another queue")

    # The real supervisor lease must outlive damaged/stale serving ownership.
    for name in ("fm-remote-job-worker.sh", "fm-remote-job-lib.sh"):
        shutil.copy2(repo / "bin" / name, root / "bin" / name)
    call(start, queue)
    wait_for(lambda: (queue / "worker.ready").is_file() and len(processes()) == 2)
    original = set(processes())
    (queue / "worker.lock/command").write_text("stale serving ownership\n")
    for _ in range(3):
        call(start, queue)
        wait_for(lambda: set(processes()) == original)
    call('fm_remote_job_stop_worker_tree "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")"', queue)
    wait_for(lambda: not processes())
    for _ in range(30):
        assert not processes(), "real supervisor respawned after stop"
        time.sleep(0.1)
    print("ok - stale serving metadata cannot accumulate restart supervisors")
finally:
    # Bounded fixture-only fallback, even when a pre-fix assertion fails.
    for pid in processes():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    wait_for(lambda: not processes())
    reap()
    shutil.rmtree(fixture)
