#!/usr/bin/env python3
"""Executable regression for the foreign session-lock owner turn-end loop.

This is adapted from Appendix A of the downstream reproduction report. It
runs the shipped lock, Claude auto-arm, and turn-end guard scripts against
isolated synthetic primary homes and harness-shaped processes.
"""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
LAB = pathlib.Path(tempfile.mkdtemp(prefix="fm-turnend-foreign-owner-"))
OUT = LAB / "evidence"
OUT.mkdir()
# Basename must be an exact FM_HARNESS_NAMES entry. Linux procps comm= is the
# 15-char kernel name, so "synthetic-claude" becomes "synthetic-claud" and
# never matches the claude regex, so fm-lock.sh exits without writing .lock.
FAKE = LAB / "claude"
FAKE.symlink_to("/bin/bash")
PROCS = []

# The suite may itself run inside a Claude session. Its CLAUDE_CODE_SESSION_ID
# and CLAUDE_PID are scrubbed so the foreign-owner negative control below is
# genuinely id-less; the same-session positive control sets its own.
BASE_ENV = {
    k: v
    for k, v in os.environ.items()
    if not k.startswith(
        ("FM_", "HERDR_", "PI_", "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "GROK_", "CURSOR_")
    )
}


def make(name):
    root = LAB / name
    root.mkdir()
    for directory in ("state", "config", "data", "projects"):
        (root / directory).mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True, env=BASE_ENV)
    (root / "AGENTS.md").write_text("Synthetic diagnostic fixture. No fleet or project operations.\n")
    (root / "bin").symlink_to(REPO / "bin", target_is_directory=True)
    (root / "state/task.meta").write_text("project=synthetic\n")
    (root / "state/home-summary.json").write_text("{}\n")
    env = BASE_ENV | {
        "FM_HOME": str(root),
        "FM_ROOT_OVERRIDE": str(root),
        "FM_STATE_OVERRIDE": str(root / "state"),
        "FM_CONFIG_OVERRIDE": str(root / "config"),
        "FM_DATA_OVERRIDE": str(root / "data"),
        "FM_PROJECTS_OVERRIDE": str(root / "projects"),
        "FM_POLL": "1",
        "FM_HEARTBEAT": "999999",
        "FM_HOME_SUMMARY_INTERVAL": "999999",
        "FM_CHECK_INTERVAL": "999999",
        "FM_CLAUDE_AUTOARM_SYNC_WAIT_MS": "0",
    }
    return root, env


def run(env, command):
    return subprocess.run(
        [str(FAKE), "-c", command],
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
    )


def start(env, command, name):
    output = (OUT / name).open("w")
    process = subprocess.Popen(
        [str(FAKE), "-c", command],
        env=env,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        text=True,
    )
    output.close()
    PROCS.append(process)
    return process


def until(test, seconds=20, message="condition timed out"):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(0.1)
    raise RuntimeError(message() if callable(message) else message)


def session_lock_text(path):
    try:
        if path.is_symlink() or not path.is_file():
            return None
        text = path.read_text().strip()
    except OSError:
        return None
    return text if text.isdigit() else None


PAYLOAD = json.dumps({"session_id": "synthetic-second", "stop_hook_active": True})


def guard(env, label, prefix=""):
    process = run(
        env,
        prefix + "printf '%s\\n' '" + PAYLOAD + "' | \"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh\" --claude",
    )
    print(label, "rc=" + str(process.returncode), "stdout=" + repr(process.stdout), "stderr=" + repr(process.stderr), flush=True)
    return process


def autoarm(env, label):
    process = run(
        env,
        "printf '%s\\n' '" + PAYLOAD + "' | \"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh\"; "
        "rc=$?; printf 'autoarm_rc=%s\\n' \"$rc\"; true",
    )
    print(label, "rc=" + str(process.returncode), "stdout=" + repr(process.stdout), "stderr=" + repr(process.stderr), flush=True)
    return process


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


try:
    root, env = make("nonowner")
    owner = start(
        env,
        '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh" && touch "$FM_HOME/state/owner-ready" && while :; do sleep 1; done',
        "owner-idle.txt",
    )
    lock_path = root / "state/.lock"
    until(
        lambda: session_lock_text(lock_path) is not None,
        message=lambda: "synthetic owner did not publish a readable state/.lock; owner log="
        + (OUT / "owner-idle.txt").read_text(errors="replace"),
    )
    until(
        lambda: (root / "state/owner-ready").exists(),
        message="synthetic owner published state/.lock but did not reach owner-ready",
    )
    beat = root / "state/.last-watcher-beat"
    beat.touch()
    old_time = time.time() - 600
    os.utime(beat, (old_time, old_time))
    lock_owner = session_lock_text(lock_path)
    require(lock_owner is not None, "state/.lock vanished after the owner-ready wait")
    print("SETUP live synthetic owner=", owner.pid, "lock=", lock_owner, flush=True)

    acquisition = run(
        env,
        '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; rc=$?; printf "lock_rc=%s\\n" "$rc"; true',
    )
    print("second-session acquisition", "rc=" + str(acquisition.returncode), "stdout=" + repr(acquisition.stdout), "stderr=" + repr(acquisition.stderr), flush=True)
    require("lock_rc=1" in acquisition.stdout, "foreign session unexpectedly acquired the session lock")
    require("another live firstmate session holds the lock" in acquisition.stderr, "lock refusal lost its ownership diagnostic")

    auto = autoarm(env, "nonowner autoarm")
    require(auto.returncode == 0, "foreign-owner auto-arm must exit safely")
    require(not (root / "state/.claude-autoarm-epoch").exists(), "foreign-owner auto-arm must not claim a generation")

    for number in range(1, 6):
        result = guard(env, f"nonowner stop {number}")
        require(result.returncode == 0, f"foreign-owner Stop {number} must end safely")
        require("SUPERVISION IS OWNED BY ANOTHER LIVE SESSION" in result.stdout, "foreign-owner Stop lost its clear diagnostic")
        require("cannot and should not arm or repair" in result.stdout, "diagnostic did not explain the safe ownership boundary")
    require(not (root / "state/.turnend-claude-blocks").exists(), "foreign-owner guard must not consume its block budget")
    print("FIXED repeated non-owner Stops: all five ended safely", flush=True)

    beat.touch()
    fresh = guard(env, "fresh-beat-only counterfactual")
    require(fresh.returncode == 0, "a fresh leftover beat must not restore foreign-owner blocking")

    stop(owner)
    replacement = start(
        env,
        'printf \'%s\\n\' \'{"session_id":"replacement","stop_hook_active":true}\' | "$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"; printf "replacement_rc=%s\\n" "$?"; sleep 1',
        "replacement.txt",
    )
    until(
        lambda: (root / "state/.watch.lock/pid").is_file(),
        message="replacement owner did not publish state/.watch.lock/pid",
    )
    watcher_pid = (root / "state/.watch.lock/pid").read_text().strip()
    print("COUNTERFACTUAL dead original owner: watcher=", watcher_pid, flush=True)
    healthy = guard(env, "replacement-owned healthy watcher")
    require(healthy.returncode == 0, "a replacement owning session must still recover supervision")
    stop(replacement)

    # Resuming a live conversation shares its id across distinct processes. The second
    # model loop must stay foreign, including its Stop and auto-arm paths.
    same, same_env = make("same-session")
    same_env["CLAUDE_CODE_SESSION_ID"] = "synthetic-same"
    same_owner = start(
        same_env,
        'export CLAUDE_PID=$$; "$FM_ROOT_OVERRIDE/bin/fm-lock.sh" && touch "$FM_HOME/state/owner-ready" && while :; do sleep 1; done',
        "same-owner.txt",
    )
    same_lock = same / "state/.lock"
    until(
        lambda: session_lock_text(same_lock) is not None,
        message=lambda: "same-session owner did not publish a readable state/.lock; owner log="
        + (OUT / "same-owner.txt").read_text(errors="replace"),
    )
    until(
        lambda: (same / "state/owner-ready").exists(),
        message="same-session owner published state/.lock but did not reach owner-ready",
    )
    same_lock_owner = session_lock_text(same_lock)
    require(
        (same / "state/.lock-session").read_text().splitlines()[0] == "synthetic-same",
        "the owner did not record its trusted session id beside the lock",
    )
    same_beat = same / "state/.last-watcher-beat"
    same_beat.touch()
    os.utime(same_beat, (old_time, old_time))
    lease = same / "state/.lease-demo"
    lease.write_text(f"main\t{same_lock_owner}\t100\n")
    epoch = same / "state/.claude-autoarm-epoch"
    epoch.write_text(f"epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid={same_lock_owner} recovery_generation=g1\nidentity-1\n")
    saved = {path: path.read_bytes() for path in (same_lock, same / "state/.lock-session", lease, epoch)}
    accepted = start(
        same_env,
        'export CLAUDE_PID=$$; printf "%s\\n" "$$" > "$FM_HOME/state/accepted-pid"; '
        '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; printf "%s\\n" "$?" > "$FM_HOME/state/accepted-rc.tmp"; '
        'mv "$FM_HOME/state/accepted-rc.tmp" "$FM_HOME/state/accepted-rc"; '
        "while :; do sleep 1; done",
        "same-accepted.txt",
    )
    until(
        lambda: (same / "state/accepted-rc").exists(),
        message="the same-session acquisition did not finish",
    )
    accepted_pid = (same / "state/accepted-pid").read_text().strip()
    accepted_log = (OUT / "same-accepted.txt").read_text(errors="replace")
    print("same-session acquisition", "rc=" + (same / "state/accepted-rc").read_text().strip(), "pid=" + accepted_pid, "output=" + repr(accepted_log), flush=True)
    require((same / "state/accepted-rc").read_text().strip() == "1", "a second live model loop acquired the same conversation's lock")
    require("second process resuming" in accepted_log and "exit this session" in accepted_log,
            "the live-publisher acquisition gave the wrong remedy")
    require(same_owner.poll() is None, "the original owner exited, so the refusal proves nothing over a live line 1")
    require(accepted_pid != same_lock_owner, "the same-session acquisition ran as the original owner")
    require(session_lock_text(same_lock) == same_lock_owner, "the resumed second process moved the live owner's lock")
    require((same / "state/.lock-session").read_text().splitlines()[0] == "synthetic-same", "a same-session confirmation changed the recorded id")
    refused = run(
        same_env | {"CLAUDE_CODE_SESSION_ID": "synthetic-other"},
        'export CLAUDE_PID=$$; "$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; rc=$?; printf "lock_rc=%s\\n" "$rc"; true',
    )
    print("other-session acquisition", "rc=" + str(refused.returncode), "stdout=" + repr(refused.stdout), "stderr=" + repr(refused.stderr), flush=True)
    require("lock_rc=1" in refused.stdout, "a different session id acquired the live lock")
    require(f"pid {same_lock_owner}, session synthetic-same" in refused.stderr, "the refusal did not name the original pid and the recorded session id")
    same_stop = guard(same_env, "same-session stop", prefix="export CLAUDE_PID=$$; ")
    require(same_stop.returncode == 0, "a resumed foreign Stop must end safely")
    require("SUPERVISION IS OWNED BY ANOTHER LIVE SESSION" in same_stop.stdout, "a resumed process lost the foreign-owner diagnostic")
    require("second process resuming" in same_stop.stdout and "exit this session" in same_stop.stdout,
            "the live-publisher Stop gave the wrong remedy")
    other_stop = guard(same_env | {"CLAUDE_CODE_SESSION_ID": "synthetic-other"}, "other-session stop", prefix="export CLAUDE_PID=$$; ")
    require(other_stop.returncode == 0, "a different-session Stop must still end safely")
    require("SUPERVISION IS OWNED BY ANOTHER LIVE SESSION" in other_stop.stdout, "a different-session Stop lost the foreign-owner diagnostic")
    require(session_lock_text(same_lock) == same_lock_owner, "a Stop moved the original lock line")
    resumed_auto = run(same_env, "export CLAUDE_PID=$$; " + 'echo "{}" | "$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"')
    require(resumed_auto.returncode == 0, "resumed foreign auto-arm did not stand down")
    require(epoch.read_bytes() == saved[epoch], "resumed foreign auto-arm changed the generation")
    require(all(path.read_bytes() == data for path, data in saved.items()), "the resumed foreign process changed ownership, leases, or rewake")
    print("FIXED a second live model loop remains foreign after resuming the owner's conversation", flush=True)
    # Retain the live frontend but record a publisher that has actually exited.
    retired = subprocess.Popen(["sleep", "60"])
    retired.terminate()
    retired.wait()
    sidecar = same / "state/.lock-session"
    sidecar.write_text(f"synthetic-same\n{retired.pid}\n")
    saved = {path: path.read_bytes() for path in (same_lock, sidecar, lease, epoch)}
    dead_publisher = run(same_env, 'export CLAUDE_PID=$$; "$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; rc=$?; exit "$rc"')
    require(dead_publisher.returncode == 1, "an exited publisher let an outsider re-anchor the live frontend")
    require("legacy record or a replaced model loop" in dead_publisher.stderr and "restarting the main session" in dead_publisher.stderr,
            "the dead-publisher refusal omitted the restart diagnostic")
    dead_stop = guard(same_env, "dead-publisher stop", prefix="export CLAUDE_PID=$$; ")
    require("SUPERVISION IS OWNED BY ANOTHER LIVE SESSION" in dead_stop.stdout, "the dead publisher hid the live foreign owner")
    require("legacy record or a replaced model loop" in dead_stop.stdout and "restarting the main session" in dead_stop.stdout,
            "the dead-publisher Stop omitted the restart remedy")
    dead_auto = run(same_env, 'export CLAUDE_PID=$$; echo "{}" | "$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"')
    require(dead_auto.returncode == 0, "dead-publisher foreign auto-arm did not stand down")
    require(same_owner.poll() is None, "the frontend exited during the dead-publisher check")
    require(all(path.read_bytes() == data for path, data in saved.items()), "dead-publisher refusal moved ownership, leases, or rewake")
    print("FIXED an exited publisher cannot transfer a live frontend's lock, leases, or rewake", flush=True)
    stop(same_owner)

    single, single_env = make("single-idle")
    stale = single / "state/.last-watcher-beat"
    stale.touch()
    os.utime(stale, (old_time, old_time))
    sole_owner = run(
        single_env,
        '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; . "$FM_ROOT_OVERRIDE/bin/fm-session-lock-lib.sh"; '
        'if fm_session_lock_owned_by_self "$FM_HOME/state"; then printf "single_owner_verified=1\\n"; fi; '
        'printf \'%s\\n\' \'{"session_id":"synthetic-second","stop_hook_active":true}\' | '
        '"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh" --claude; rc=$?; printf "single_owner_guard_rc=%s\\n" "$rc"; true',
    )
    print("single owner, no autoarm firing", "rc=" + str(sole_owner.returncode), "stdout=" + repr(sole_owner.stdout), "stderr=" + repr(sole_owner.stderr), flush=True)
    require("single_owner_guard_rc=2" in sole_owner.stdout, "a sole owner without supervision must retain the guard")
    print("COMPLETE", flush=True)
finally:
    for process in reversed(PROCS):
        stop(process)
    shutil.rmtree(LAB, ignore_errors=True)
