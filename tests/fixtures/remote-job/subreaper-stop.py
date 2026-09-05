#!/usr/bin/env python3
"""Exercise the shell worker lifecycle with a real Linux child subreaper."""
import ctypes
import errno
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

def process_start(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    return f"linux:{boot}:{fields[19]}"


def stop_process(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def pid_reuse_case(repo, legacy_claim=False):
    if os.getpid() != 1:
        print("private PID namespace did not make the fixture process PID 1")
        return 77
    last_pid = Path("/proc/sys/kernel/ns_last_pid")
    if not last_pid.exists() or not os.access(last_pid, os.W_OK):
        print("private PID namespace does not expose writable /proc/sys/kernel/ns_last_pid")
        return 77
    print("FM_PID_REUSE_READY", flush=True)
    fixture = Path(tempfile.mkdtemp(prefix="fm-pid-reuse-"))
    root = fixture / "root"
    state = fixture / "state"
    account = fixture / "account"
    outside = fixture / "outside"
    fifo = fixture / "snapshot.fifo"
    for path in (root / "bin", state, account, outside):
        path.mkdir(parents=True, exist_ok=True)
    (root / "AGENTS.md").write_text("fixture\n")
    (root / "bin/fm-remote-job-worker.sh").write_text("#!/bin/bash\n")
    os.mkfifo(fifo)
    environment = dict(os.environ, HOME=str(account), FM_ROOT_OVERRIDE=str(root),
                       FM_REMOTE_JOB_STATE_ROOT=str(state),
                       FM_REMOTE_JOB_TEST_STOP_SNAPSHOT_FIFO=str(fifo), TZ="UTC0", LC_ALL="C")
    leader = stop = unrelated = None
    release_fd = None
    try:
        while time.time() % 1 > 0.5:
            time.sleep(0.01)
        leader = subprocess.Popen(["sleep", "300"], env=environment, cwd=root,
                                  start_new_session=True)
        leader_start = process_start(leader.pid)
        assert os.getpgid(leader.pid) == leader.pid
        legacy_start = subprocess.check_output(
            ["/bin/ps", "-p", str(leader.pid), "-o", "lstart="], env=environment, text=True)
        if legacy_claim:
            claim = state / "jobs/job-legacy/.claim"
            claim.mkdir(parents=True)
            (claim.parent / "state").write_text("running\n")
            (claim / "armed").touch()
            (claim / "group").write_text(f"{leader.pid}\n")
            (claim / "group_start").write_text(legacy_start)
        stop = subprocess.Popen(
            ["bash", "-c", '. "$1/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$2"',
             "fixture", str(repo), str(leader.pid)],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                release_fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
                break
            except OSError as error:
                if error.errno != errno.ENXIO:
                    raise
                if stop.poll() is not None:
                    raise AssertionError(stop.communicate())
                time.sleep(0.01)
        assert release_fd is not None, "stop did not reach the snapshot boundary"
        leader.terminate()
        leader.wait(timeout=3)
        time.sleep(0.05)
        last_pid.write_text(str(leader.pid - 1))
        unrelated = subprocess.Popen(["sleep", "300"], env=environment, cwd=outside,
                                     start_new_session=True)
        assert unrelated.pid == leader.pid
        assert os.getpgid(unrelated.pid) == leader.pid
        assert process_start(unrelated.pid) != leader_start
        if legacy_claim:
            replacement_legacy = subprocess.check_output(
                ["/bin/ps", "-p", str(unrelated.pid), "-o", "lstart="],
                env=environment, text=True)
            if replacement_legacy != legacy_start:
                print("legacy replacement crossed the ps lstart second boundary")
                return 77
        os.write(release_fd, b"release\n")
        os.close(release_fd)
        release_fd = None
        stdout, stderr = stop.communicate(timeout=10)
        if legacy_claim:
            assert stop.returncode != 0, (stdout, stderr)
            assert "NEEDING MANUAL CLEANUP" in stderr, (stdout, stderr)
            assert f"pid {leader.pid}" in stderr, (stdout, stderr)
            assert legacy_start.strip() in stderr, (stdout, stderr)
        else:
            assert stop.returncode == 0, (stdout, stderr)
        assert unrelated.poll() is None, "stop signalled the unrelated recycled identity"
        return 0
    finally:
        if release_fd is not None:
            os.close(release_fd)
        stop_process(stop)
        stop_process(unrelated)
        stop_process(leader)
        shutil.rmtree(fixture)


if len(sys.argv) > 1 and sys.argv[1] == "--pid-reuse-case":
    sys.exit(pid_reuse_case(Path(sys.argv[2]).resolve(), len(sys.argv) > 3 and sys.argv[3] == "legacy"))

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


def identity_mismatch_unit_case(queue):
    candidate = subprocess.Popen(["sleep", "300"], env=worker_environment(queue), cwd=root,
                                 start_new_session=True)
    extra_pids.add(candidate.pid)
    signal_log = fixture / "identity-mismatch-signal"
    try:
        actual_start = process_start(candidate.pid)
        prefix, boot, ticks = actual_start.split(":")
        stale_start = f"{prefix}:{boot}:{max(0, int(ticks) - 1)}"
        group = os.getpgid(candidate.pid)
        snapshot = f"{candidate.pid}\t{stale_start}\t{group}"
        script = '''
actual=$(fm_remote_job_scoped_process_identity "$2" "$3" "$4") || exit 1
[ "$actual" = "$5\t$6" ] || exit 1
kill() { printf 'signal\n' > "$8"; }
fm_remote_job_signal_scope_snapshot "$7" "$3" "$4" TERM
[ ! -e "$8" ]
'''
        result = subprocess.run(
            ["bash", "-c", '. "$1/bin/fm-remote-job-lib.sh"\n' + script,
             "fixture", str(repo), str(candidate.pid), str(root), str(queue), actual_start,
             str(group), snapshot, str(signal_log)],
            env=worker_environment(queue), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=10)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert candidate.poll() is None
    finally:
        stop_process(candidate)
        extra_pids.discard(candidate.pid)


def run_kernel_pid_reuse_case(legacy_claim=False):
    unshare = shutil.which("unshare")
    if not unshare:
        return "unshare is unavailable"
    command = [unshare, "--user", "--map-root-user", "--pid", "--fork", "--mount-proc",
               sys.executable, __file__, "--pid-reuse-case", str(repo)]
    if legacy_claim:
        command.append("legacy")
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                timeout=20)
    except subprocess.TimeoutExpired:
        return "private user/PID namespace setup timed out"
    if result.returncode == 0:
        return None
    reason = (result.stdout.strip() or result.stderr.strip() or f"unshare exited {result.returncode}")
    if result.returncode == 77 or "FM_PID_REUSE_READY" not in result.stdout.splitlines():
        return reason
    raise AssertionError((result.stdout, result.stderr))


def queue_process_identity(pid, queue):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
    entries = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
    assert b"FM_REMOTE_JOB_STATE_ROOT=" + os.fsencode(queue) in entries
    assert os.fsencode(worker) in args
    return fields[19]


def assert_queue_unchanged(queue, expected):
    for pid, start in expected.items():
        assert queue_process_identity(pid, queue) == start, "another queue replaced an owned process"
    assert not queue_processes(queue) - expected.keys(), "another queue gained an unexpected process"


def utf8_locale():
    for candidate in ("C.UTF-8", "C.utf8"):
        result = subprocess.run(["locale", "charmap"], env=dict(os.environ, LC_ALL=candidate),
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if result.returncode == 0 and result.stdout.strip().upper() == "UTF-8":
            return candidate
    raise AssertionError("a built-in C UTF-8 locale is required")


def locale_render_pair(pid, timezone):
    installed = subprocess.check_output(["locale", "-a"], text=True).splitlines()
    preferred = ("C", "C.UTF-8", "C.utf8", "en_US.UTF-8", "en_US.utf8",
                 "pt_BR.UTF-8", "pt_BR.utf8", "de_DE.UTF-8", "de_DE.utf8")
    locales = [name for name in preferred if name in installed]
    locales.extend(name for name in installed if name not in locales)
    renderings = {}
    for name in locales:
        result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                                env=dict(os.environ, TZ=timezone, LC_ALL=name),
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if result.returncode == 0 and result.stdout:
            renderings[name] = result.stdout
    for recorded in renderings:
        for caller in renderings:
            if renderings[recorded] != renderings[caller]:
                return recorded, caller, renderings[recorded], renderings[caller], locales
    return None, None, None, None, locales


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

    identity_mismatch_unit_case(queue)
    print("ok - scope signalling skips a snapshot whose process start identity changed")
    kernel_skip = run_kernel_pid_reuse_case()
    if kernel_skip:
        print(f"skip - kernel PID/PGID reuse race: {kernel_skip}")
    else:
        print("ok - stop leaves a kernel-recycled unrelated PID/PGID untouched")
    legacy_skip = run_kernel_pid_reuse_case(True)
    if legacy_skip:
        print(f"skip - legacy claim PID/PGID reuse containment: {legacy_skip}")
    else:
        print("ok - legacy active claim reports manual cleanup without signalling a recycled group")

    # The real supervisor lease must outlive damaged/stale serving ownership.
    for name in ("fm-remote-job-worker.sh", "fm-remote-job-lib.sh"):
        shutil.copy2(repo / "bin" / name, root / "bin" / name)
    chdir_worker = root / "bin/fm-chdir-block.sh"
    chdir_worker.write_text('''#!/bin/bash
(
  cd "$HOME" || exit 1
  printf '%s\n' "$BASHPID" > "$HOME/chdir-job.pid"
  exec sleep 300
) &
wait "$!"
''')
    chdir_worker.chmod(0o755)
    git_env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    subprocess.run(["git", "-C", str(root), "init", "-q", "-b", "main"], env=git_env, check=True)
    subprocess.run(["git", "-C", str(root), "add", "AGENTS.md", "bin"], env=git_env, check=True)
    subprocess.run(["git", "-C", str(root), "-c", "user.name=Test", "-c",
                    "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                    "commit", "-qm", "fixture"], env=git_env, check=True)
    locale_recorded, locale_caller, locale_rendered, caller_rendered, probed_locales = \
        locale_render_pair(os.getpid(), "EST5")
    locale_name = locale_recorded or utf8_locale()
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
    if locale_recorded:
        assert locale_rendered != caller_rendered
        for lock in (queue / "worker.lock", queue / "supervisor.lock"):
            pid = (lock / "pid").read_text().strip()
            kernel_identity = (lock / "start").read_text()
            locale_legacy = subprocess.check_output(["/bin/ps", "-p", pid, "-o", "lstart="],
                                                    env=dict(os.environ, TZ="EST5", LC_ALL=locale_recorded),
                                                    text=True)
            caller_legacy = subprocess.check_output(["/bin/ps", "-p", pid, "-o", "lstart="],
                                                    env=dict(os.environ, TZ="EST5", LC_ALL=locale_caller),
                                                    text=True)
            assert locale_legacy != caller_legacy
            (lock / "start").write_text(locale_legacy)
            call(ensure, queue, "EST5", locale_caller)
            assert launch_log.read_text() == launches, "locale-only legacy identity launched another worker"
            (lock / "start").write_text(kernel_identity)
        print(f"ok - locale-only legacy identity reconstruction uses {locale_recorded} from {locale_caller}")
    else:
        print("skip - locale-only legacy identity reconstruction: no differing ps lstart rendering among "
              + ", ".join(probed_locales))
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
        claim_group = int(next((job_queue / "jobs").glob("job-*/.claim/group")).read_text())
        assert chdir_pid != claim_group and os.getpgid(chdir_pid) == claim_group
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
    print("ok - active claim identity stops a job descendant after it changes directory outside the root")
    (queue / "worker.lock/command").write_text("stale serving ownership\n")
    for _ in range(3):
        call(start, queue)
        wait_for(lambda: set(processes()) == original)
    real_other = fixture / "real-other-queue"
    call(start, real_other)
    wait_for(lambda: len(queue_processes(real_other)) == 2)
    unrelated = {pid: queue_process_identity(pid, real_other) for pid in queue_processes(real_other)}
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
        assert_queue_unchanged(real_other, unrelated)
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
