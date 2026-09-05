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
import threading
import time

if len(sys.argv) > 1 and sys.argv[1] == "--reuse-group":
    parent_group = int(sys.argv[2])
    owned_path = Path(sys.argv[3])
    trigger_path = Path(sys.argv[4])
    reused_path = Path(sys.argv[5])
    outside_root = sys.argv[6]
    os.setpgid(0, 0)
    owned_path.write_text(f"{os.getpid()} {os.getpgrp()}\n")
    while not trigger_path.exists():
        time.sleep(0.01)
    os.setpgid(0, parent_group)
    os.chdir(outside_root)
    os.execve(sys.executable, [sys.executable, __file__, "--reused-group", str(reused_path)], {})

if len(sys.argv) > 1 and sys.argv[1] == "--reused-group":
    os.setpgid(0, 0)
    Path(sys.argv[2]).write_text(f"{os.getpid()} {os.getpgrp()}\n")
    while True:
        signal.pause()

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
extra_pids = set()
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


def worker_environment(queue, timezone="UTC0", locale_name="C"):
    env = dict(os.environ, HOME=str(account), FM_ROOT_OVERRIDE=str(root),
               FM_REMOTE_JOB_STATE_ROOT=str(queue), FM_REMOTE_JOB_PLATFORM_OVERRIDE="Linux", TZ=timezone,
               LC_ALL=locale_name,
               PATH=f"{launch_bin}:{os.environ['PATH']}", FM_FIXTURE_NOHUP=real_nohup,
               FM_FIXTURE_LAUNCH_LOG=str(launch_log))
    env.pop("LOCPATH", None)
    return env


def call(script, queue, timezone="UTC0", locale_name="C"):
    env = worker_environment(queue, timezone, locale_name)
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


def queue_processes(queue):
    result = set()
    expected = os.fsencode(queue)
    for pid in processes():
        try:
            entries = (Path(f"/proc/{pid}/environ").read_bytes().split(b"\0"))
        except (FileNotFoundError, ProcessLookupError):
            continue
        if b"FM_REMOTE_JOB_STATE_ROOT=" + expected in entries:
            result.add(pid)
    return result


def process_state(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
    return fields[0]


def process_alive(pid):
    try:
        return process_state(pid) != "Z"
    except (FileNotFoundError, ProcessLookupError):
        return False


def utf8_locale():
    for candidate in ("C.UTF-8", "C.utf8"):
        result = subprocess.run(["locale", "charmap"], env=dict(os.environ, LC_ALL=candidate),
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if result.returncode == 0 and result.stdout.strip().upper() == "UTF-8":
            return candidate
    raise AssertionError("a built-in C UTF-8 locale is required")


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

    direct_queue = fixture / "direct-queue"
    direct_queue.mkdir()
    direct = subprocess.Popen([str(worker)], env=worker_environment(direct_queue), cwd=root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for(lambda: (direct_queue / "worker.pid").is_file() and len(processes()) == 2)
        direct_child = int((direct_queue / "worker.pid").read_text())
        assert os.getpgid(direct.pid) == os.getpgrp()
        call(f"fm_remote_job_stop_worker_tree {direct_child}", direct_queue)
        wait_for(lambda: not processes())
        direct.wait(timeout=5)
        for _ in range(30):
            assert not processes(), "same-group supervisor respawned after stop"
            time.sleep(0.1)
    finally:
        if direct.poll() is None:
            direct.kill()
            direct.wait()
    print("ok - stop terminates a same-group supervisor without signalling the caller group")

    call(start, queue)
    wait_for(lambda: (queue / "worker.pid").is_file() and len(processes()) == 2)
    anchor = int((queue / "worker.pid").read_text())
    owned_path = fixture / "group-owned"
    trigger_path = fixture / "group-reuse"
    reused_path = fixture / "group-reused"
    reuser = subprocess.Popen([sys.executable, __file__, "--reuse-group", str(os.getpgrp()),
                               str(owned_path), str(trigger_path), str(reused_path), str(fixture)],
                              env=worker_environment(queue), cwd=root)
    try:
        wait_for(owned_path.exists)
        owned_pid, owned_group = map(int, owned_path.read_text().split())
        assert owned_pid == reuser.pid and owned_group == reuser.pid
        call(f'fm_remote_job_scoped_process_identity {reuser.pid} "$FM_ROOT_OVERRIDE" "$FM_REMOTE_JOB_STATE_ROOT" >/dev/null', queue)
        trigger_path.touch()
        wait_for(reused_path.exists)
        reused_pid, reused_group = map(int, reused_path.read_text().split())
        assert reused_pid == owned_pid and reused_group == owned_group
        call(f"fm_remote_job_stop_worker_tree {anchor}", queue)
        wait_for(lambda: not processes())
        assert reuser.poll() is None, "stop signalled the unrelated reused group"
    finally:
        if reuser.poll() is None:
            reuser.terminate()
            reuser.wait()
    print("ok - stop leaves a concretely dissolved and reused unrelated group untouched")

    # The real supervisor lease must outlive damaged/stale serving ownership.
    for name in ("fm-remote-job-worker.sh", "fm-remote-job-lib.sh"):
        shutil.copy2(repo / "bin" / name, root / "bin" / name)
    chdir_worker = root / "bin/fm-chdir-block.sh"
    chdir_worker.write_text('''#!/bin/bash
cd "$HOME" || exit 1
printf '%s\n' "$$" > "$HOME/chdir-job.pid"
exec sleep 300
''')
    chdir_worker.chmod(0o755)
    git_env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    subprocess.run(["git", "-C", str(root), "init", "-q", "-b", "main"], env=git_env, check=True)
    subprocess.run(["git", "-C", str(root), "add", "AGENTS.md", "bin"], env=git_env, check=True)
    subprocess.run(["git", "-C", str(root), "-c", "user.name=Test", "-c",
                    "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                    "commit", "-qm", "fixture"], env=git_env, check=True)
    locale_name = utf8_locale()
    call(start, queue, "EST5", locale_name)
    wait_for(lambda: (queue / "worker.ready").is_file() and len(processes()) == 2)
    quarantine = queue / "worker.lock/quarantine"
    quarantine.write_text("active execution could not be confirmed stopped\n")
    replacement = subprocess.run([str(worker)], env=worker_environment(queue), cwd=root,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    assert replacement.returncode == 75, (replacement.stdout, replacement.stderr)
    quarantine.unlink()
    print("ok - a live supervisor lease cannot mask quarantined serving ownership")
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
                                         env=dict(os.environ, TZ="EST5", LC_ALL=locale_name), text=True)
        canonical = subprocess.check_output(["/bin/ps", "-p", pid, "-o", "lstart="],
                                            env=dict(os.environ, TZ="UTC0", LC_ALL="C"), text=True)
        assert legacy != canonical, "fixture timezone did not change the legacy timestamp"
        (lock / "start").write_text(legacy)
        call(ensure, queue, "JST-9")
        assert launch_log.read_text() == launches, "legacy identity launched another worker"
        (lock / "start").write_text(kernel_identity)
    print("ok - repeated ensure across timezones and delayed readiness preserves owners without new workers")
    job_queue = fixture / "job-queue"
    call(start, job_queue)
    wait_for(lambda: len(queue_processes(job_queue)) == 2)
    unrelated_process = subprocess.Popen(["sleep", "300"], cwd=fixture)
    extra_pids.add(unrelated_process.pid)
    try:
        (account / "chdir-job.pid").unlink(missing_ok=True)
        call('printf "" | fm_remote_job_stage "$HOME" "$FM_ROOT_OVERRIDE" "$HOME" fm-chdir-block.sh >/dev/null',
             job_queue)
        wait_for(lambda: (account / "chdir-job.pid").is_file())
        chdir_pid = int((account / "chdir-job.pid").read_text())
        extra_pids.add(chdir_pid)
        assert Path(f"/proc/{chdir_pid}/cwd").resolve() == account
        job_serving = int((job_queue / "worker.pid").read_text())
        call(f"fm_remote_job_stop_worker_tree {job_serving}", job_queue)
        wait_for(lambda: not process_alive(chdir_pid))
        try:
            os.waitpid(chdir_pid, os.WNOHANG)
        except ChildProcessError:
            pass
        extra_pids.discard(chdir_pid)
        wait_for(lambda: not queue_processes(job_queue))
        assert unrelated_process.poll() is None, "claim-backed stop reached an unrelated process"
        assert set(processes()) == original, "claim-backed stop reached another queue"
        for _ in range(30):
            assert not queue_processes(job_queue), "claim-backed worker respawned after stop"
            assert not process_alive(chdir_pid), "chdir job survived worker stop"
            time.sleep(0.1)
    finally:
        if unrelated_process.poll() is None:
            unrelated_process.terminate()
            unrelated_process.wait()
        extra_pids.discard(unrelated_process.pid)
    print("ok - active claim identity stops a job after it changes directory outside the root")
    (queue / "worker.lock/command").write_text("stale serving ownership\n")
    for _ in range(3):
        call(start, queue)
        wait_for(lambda: set(processes()) == original)
    real_other = fixture / "real-other-queue"
    call(start, real_other)
    wait_for(lambda: len(queue_processes(real_other)) == 2)
    unrelated = set(queue_processes(real_other))
    serving = int((queue / "worker.pid").read_text())
    supervisor = int((queue / "supervisor.lock/pid").read_text())
    os.kill(supervisor, signal.SIGSTOP)
    os.kill(serving, signal.SIGKILL)
    wait_for(lambda: process_state(serving) == "Z")

    def resume_supervisor():
        time.sleep(0.2)
        try:
            os.kill(supervisor, signal.SIGCONT)
        except ProcessLookupError:
            pass

    resume = threading.Thread(target=resume_supervisor)
    resume.start()
    call(f"fm_remote_job_stop_worker_tree {serving}", queue)
    resume.join(timeout=2)
    wait_for(lambda: not queue_processes(queue))
    for _ in range(30):
        assert not queue_processes(queue), "real supervisor respawned after zombie-child stop"
        assert queue_processes(real_other) == unrelated, "zombie-child stop reached another queue"
        time.sleep(0.1)
    call('fm_remote_job_stop_worker_tree "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")"', real_other)
    wait_for(lambda: not processes())
    print("ok - zombie serving ownership recovers its scoped supervisor without respawn")
finally:
    # Bounded fixture-only fallback, even when a pre-fix assertion fails.
    for pid in extra_pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for pid in processes():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    wait_for(lambda: not processes())
    reap()
    shutil.rmtree(fixture)
