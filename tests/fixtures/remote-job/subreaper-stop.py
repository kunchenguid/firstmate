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
launch_bin = fixture / "launch-bin"
launch_bin.mkdir()
launch_log = fixture / "launches"
launch_log.touch()
real_nohup = shutil.which("nohup")
assert real_nohup, "nohup is required by the production Linux start path"
(launch_bin / "nohup").write_text('''#!/bin/bash
printf 'launch\n' >> "$FM_FIXTURE_LAUNCH_LOG"
exec "$FM_FIXTURE_NOHUP" "$@"
''')
(launch_bin / "nohup").chmod(0o755)


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


def call(script, queue, timezone="UTC0"):
    env = dict(os.environ, HOME=str(account), FM_ROOT_OVERRIDE=str(root),
               FM_REMOTE_JOB_STATE_ROOT=str(queue), FM_REMOTE_JOB_PLATFORM_OVERRIDE="Linux", TZ=timezone,
               PATH=f"{launch_bin}:{os.environ['PATH']}", FM_FIXTURE_NOHUP=real_nohup,
               FM_FIXTURE_LAUNCH_LOG=str(launch_log))
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
    queue_snapshot = processes()
    leader = next(pid for pid, (_, _, serving) in queue_snapshot.items() if not serving)
    leaderless_child = next(pid for pid, (_, group, serving) in queue_snapshot.items()
                            if serving and group == leader)
    os.kill(leader, signal.SIGKILL)
    wait_for(lambda: not Path(f"/proc/{leader}").exists() and leaderless_child in processes())
    assert processes()[leaderless_child][1] == leader
    call(start, other)
    wait_for(lambda: len(processes()) == 5)
    snapshot = processes()
    assert all(parent == os.getpid() and group == pid
               for pid, (parent, group, serving) in snapshot.items() if not serving)
    other_child = int((other / "worker.pid").read_text())
    other_group = snapshot[other_child][1]
    call(f'fm_remote_job_stop_worker_tree {leaderless_child}', queue)
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
    call(start, queue, "EST5")
    wait_for(lambda: (queue / "worker.ready").is_file() and len(processes()) == 2)
    original = set(processes())
    ensure = 'fm_remote_job_ensure_worker "$FM_ROOT_OVERRIDE" "$HOME"; [ "$FM_REMOTE_JOB_REPAIRED" -eq 0 ]'
    launches = launch_log.read_text()
    for timezone in ("UTC0", "EST5", "JST-9", "UTC0"):
        call(ensure, queue, timezone)
        wait_for(lambda: set(processes()) == original)
        assert launch_log.read_text() == launches, "ensure launched another worker"
    serving = int((queue / "worker.pid").read_text())
    os.kill(serving, signal.SIGSTOP)
    try:
        os.utime(queue / "worker.ready", (0, 0))
        call('FM_REMOTE_JOB_REPAIRED=0; ' + start + '; [ "$FM_REMOTE_JOB_REPAIRED" -eq 0 ]', queue)
        assert launch_log.read_text() == launches, "stale heartbeat launched another worker"
    finally:
        os.kill(serving, signal.SIGCONT)
    # Old lstart records must remain verifiable while a deployment drains them.
    for lock in (queue / "worker.lock", queue / "supervisor.lock"):
        pid = (lock / "pid").read_text().strip()
        kernel_identity = (lock / "start").read_text()
        legacy = subprocess.check_output(["/bin/ps", "-p", pid, "-o", "lstart="],
                                         env=dict(os.environ, TZ="EST5", LC_ALL="C"), text=True)
        (lock / "start").write_text(legacy)
        call(ensure, queue, "JST-9")
        assert launch_log.read_text() == launches, "legacy identity launched another worker"
        (lock / "start").write_text(kernel_identity)
    print("ok - repeated ensure across timezones and delayed readiness preserves owners without new workers")
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
