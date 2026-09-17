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
FAKE = LAB / "synthetic-claude"
FAKE.symlink_to("/bin/bash")
PROCS = []

BASE_ENV = {
    k: v
    for k, v in os.environ.items()
    if not k.startswith(("FM_", "HERDR_", "PI_", "CLAUDE_PROJECT_DIR", "GROK_", "CURSOR_"))
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


def until(test, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(0.1)
    raise RuntimeError("condition timed out")


PAYLOAD = json.dumps({"session_id": "synthetic-second", "stop_hook_active": True})


def guard(env, label):
    process = run(
        env,
        "printf '%s\\n' '" + PAYLOAD + "' | \"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh\" --claude",
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
        '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; touch "$FM_HOME/state/owner-ready"; while :; do sleep 1; done',
        "owner-idle.txt",
    )
    until(lambda: (root / "state/owner-ready").exists())
    beat = root / "state/.last-watcher-beat"
    beat.touch()
    old_time = time.time() - 600
    os.utime(beat, (old_time, old_time))
    lock_owner = (root / "state/.lock").read_text().strip()
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
    until(lambda: (root / "state/.watch.lock/pid").exists())
    watcher_pid = (root / "state/.watch.lock/pid").read_text().strip()
    print("COUNTERFACTUAL dead original owner: watcher=", watcher_pid, flush=True)
    healthy = guard(env, "replacement-owned healthy watcher")
    require(healthy.returncode == 0, "a replacement owning session must still recover supervision")
    stop(replacement)

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
