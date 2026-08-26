#!/usr/bin/env python3
"""Trusted guest executor for one unprivileged, bounded repository command.

This runs as root inside a systemd resource-control unit, opens protected log
files, then drops the command child to the dedicated fmrunner uid/gid. The child
never receives staging capabilities or bootstrap environment.
"""

import ctypes
import hashlib
import json
import os
from pathlib import Path
import resource
import selectors
import signal
import subprocess
import sys
import time


RESULT_SCHEMA = "fm.azure-command-result/v1"
PRIVATE_SOURCE_MODES = ("private-parent-bundle", "private-exact-bundle", "private-direct-bundle")


def fail(message):
    print("guest executor failed: " + message, file=sys.stderr)
    return 125


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                return "sha256:" + digest.hexdigest()
            digest.update(chunk)


def verify_request(request):
    supplied = request.get("request_digest")
    unsigned = dict(request)
    unsigned.pop("request_digest", None)
    actual = "sha256:" + hashlib.sha256(canonical_bytes(unsigned)).hexdigest()
    if supplied != actual:
        raise ValueError("request digest mismatch")
    command = request.get("command") or {}
    command_actual = "sha256:" + hashlib.sha256(canonical_bytes(command)).hexdigest()
    if request.get("command_digest") != command_actual:
        raise ValueError("command digest mismatch")
    argv = command.get("argv")
    if not isinstance(argv, list) or not argv or not all(isinstance(value, str) and "\x00" not in value for value in argv):
        raise ValueError("command argv is malformed")
    limits = request.get("limits") or {}
    hard = {
        "cpu_cores": (1, 8),
        "memory_bytes": (1024**3, 56 * 1024**3),
        "pid_max": (16, 4096),
        "disk_bytes": (1024**3, 52 * 1024**3),
        "log_bytes": (1024, 32 * 1024**2),
        "artifact_bytes": (0, 512 * 1024**2),
        "network_bytes": (0, 0),
        "wall_seconds": (1, 14400),
    }
    for name, bounds in hard.items():
        value = limits.get(name)
        if not isinstance(value, int) or value < bounds[0] or value > bounds[1]:
            raise ValueError("resource limit is invalid: " + name)
    return argv, limits


def verify_private_source_ancestors(request_path, repo):
    try:
        request = json.loads(request_path.read_text(encoding="utf-8"))
        repository = request["repository"]
        if repository.get("source_mode") not in PRIVATE_SOURCE_MODES:
            raise ValueError("private source ancestor verification requires a private bundle")
        commit = repository["commit"]
        ancestors = repository.get("source_ancestors", [])
        for ancestor in ancestors:
            object_type = subprocess.run(
                ["git", "-C", str(repo), "cat-file", "-t", ancestor],
                check=True,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ).stdout.strip()
            if object_type != "commit":
                raise ValueError("source ancestor is not a commit")
            subprocess.run(
                ["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, commit],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
    except (KeyError, OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        return fail("private source ancestor verification failed: {}".format(exc))
    return 0


def drop_privileges(uid, gid, pid_max, disk_bytes):
    if os.environ.get("FM_AZURE_RUNNER_TEST_NO_DROP") == "1":
        if uid != os.getuid() or gid != os.getgid():
            os._exit(126)
        os.setsid()
        return
    os.setgroups([])
    resource.setrlimit(resource.RLIMIT_NPROC, (pid_max, pid_max))
    resource.setrlimit(resource.RLIMIT_FSIZE, (disk_bytes, disk_bytes))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.setgid(gid)
    os.setuid(uid)
    libc = ctypes.CDLL(None)
    if libc.prctl(38, 1, 0, 0, 0) != 0:  # PR_SET_NO_NEW_PRIVS
        os._exit(126)
    if os.getuid() != uid or os.getgid() != gid or os.getgroups():
        os._exit(126)
    if sys.platform.startswith("linux"):
        status = {}
        for line in Path("/proc/self/status").read_text(encoding="ascii").splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                status[key] = value.strip()
        if any(int(status.get(name, "1"), 16) != 0 for name in ("CapEff", "CapPrm", "CapAmb")):
            os._exit(126)
        if status.get("NoNewPrivs") != "1":
            os._exit(126)
    os.setsid()


def copy_bounded(selector, streams, log_handles, cap, deadline, process):
    sizes = {"stdout": 0, "stderr": 0}
    truncated = {"stdout": False, "stderr": False}
    timed_out = False
    while selector.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0 and process.poll() is None:
            timed_out = True
            with suppress_oserror():
                os.killpg(process.pid, signal.SIGTERM)
            terminate_deadline = time.monotonic() + 10
            while process.poll() is None and time.monotonic() < terminate_deadline:
                time.sleep(0.1)
            if process.poll() is None:
                with suppress_oserror():
                    os.killpg(process.pid, signal.SIGKILL)
            remaining = 0.1
        events = selector.select(timeout=max(0.05, min(1.0, remaining if remaining > 0 else 0.1)))
        if not events and process.poll() is not None:
            for key in list(selector.get_map().values()):
                data = os.read(key.fd, 65536)
                if data:
                    name = streams[key.fd]
                    allowed = max(0, cap - sizes[name])
                    if allowed:
                        log_handles[name].write(data[:allowed])
                        sizes[name] += min(allowed, len(data))
                    if len(data) > allowed:
                        truncated[name] = True
                else:
                    selector.unregister(key.fd)
            continue
        for key, _ in events:
            data = os.read(key.fd, 65536)
            if not data:
                selector.unregister(key.fd)
                continue
            name = streams[key.fd]
            allowed = max(0, cap - sizes[name])
            if allowed:
                log_handles[name].write(data[:allowed])
                sizes[name] += min(allowed, len(data))
            if len(data) > allowed:
                truncated[name] = True
    return sizes, truncated, timed_out


class suppress_oserror:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return exc_type is not None and issubclass(exc_type, OSError)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--verify-private-source-ancestors":
        return verify_private_source_ancestors(Path(sys.argv[2]), Path(sys.argv[3]))
    if len(sys.argv) != 8:
        return fail("expected request, repo, output, uid, gid, VM id, and boot id")
    request_path = Path(sys.argv[1])
    repo = Path(sys.argv[2])
    output = Path(sys.argv[3])
    uid = int(sys.argv[4])
    gid = int(sys.argv[5])
    vm_resource_id = sys.argv[6]
    vm_instance_id = sys.argv[7]
    boot_id_path = Path(os.environ.get("FM_AZURE_RUNNER_BOOT_ID_PATH", "/proc/sys/kernel/random/boot_id"))
    boot_id = boot_id_path.read_text(encoding="ascii").strip()
    try:
        request = json.loads(request_path.read_text(encoding="utf-8"))
        argv, limits = verify_request(request)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return fail(str(exc))
    try:
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
    except FileExistsError:
        # The guest pre-creates the output directory so the hardened unit
        # can bind it writable under ProtectSystem=strict; accept it only
        # root-owned and empty, and keep the exclusive log creates below as
        # the per-run freshness fence.
        details = output.stat()
        if details.st_uid != 0 or any(output.iterdir()):
            return fail("output directory is not a fresh root-owned staging area")
        os.chmod(output, 0o700)
    stdout_path = output / "stdout.log"
    stderr_path = output / "stderr.log"
    stdout_handle = open(stdout_path, "xb", buffering=0)
    stderr_handle = open(stderr_path, "xb", buffering=0)
    # The unit's PrivateTmp puts /tmp on its own tmpfs, so repository tests
    # that hard-link between their temp root and the work mount fail with
    # EXDEV (generation 051 ground truth: fm-auto-reap's fixture hard
    # link). A temp root beside the repository stays on the same device.
    # The bootstrap pre-creates it owned by the runner user with mode
    # 0700: world-writable modes trip the repository's own path guard
    # (generation 052 ground truth), and the unit's bounding set carries
    # no CAP_CHOWN so ownership cannot be adjusted here. The hermetic
    # fallback creates it as the invoking user; when neither exists the
    # child simply keeps the default TMPDIR.
    work_tmp = Path(repo).resolve().parent / "tmp"
    try:
        work_tmp.mkdir(mode=0o700, exist_ok=True)
    except OSError:
        pass
    if not work_tmp.is_dir():
        work_tmp = None
    child_env = {
        "HOME": "/work/home",
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "CI": "true",
        "FM_AZURE_RUNNER": "1",
        "FM_AZURE_RUNNER_INVOCATION": request["invocation"],
        "FM_AZURE_RUNNER_DEPENDENCIES": "/work/repo",
        # Declares the sealed-lane environment fact: deny-all repository
        # networking with only the staged tool closure. Tests whose runtime
        # dependencies cannot exist here (interpreter versions, package
        # registries) key their explicit skip on this, keeping their full
        # coverage in public CI which the ci step still requires green.
        "FM_TEST_SEALED_CELL": "1",
    }
    if work_tmp is not None:
        child_env["TMPDIR"] = str(work_tmp)
    started = time.monotonic()
    try:
        def enter_repo_as_runner():
            # The unit's bounding set has no CAP_DAC_OVERRIDE, so root
            # cannot enter the 0700 runner-owned repository; the child
            # drops privileges first and then changes directory as the
            # runner user, instead of Popen's early root chdir.
            drop_privileges(uid, gid, limits["pid_max"], limits["disk_bytes"])
            os.chdir(str(repo))

        process = subprocess.Popen(
            argv,
            env=child_env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            preexec_fn=enter_repo_as_runner,
            close_fds=True,
        )
        selector = selectors.DefaultSelector()
        selector.register(process.stdout.fileno(), selectors.EVENT_READ)
        selector.register(process.stderr.fileno(), selectors.EVENT_READ)
        streams = {process.stdout.fileno(): "stdout", process.stderr.fileno(): "stderr"}
        sizes, truncated, timed_out = copy_bounded(
            selector, streams, {"stdout": stdout_handle, "stderr": stderr_handle},
            limits["log_bytes"], started + limits["wall_seconds"], process,
        )
        return_code = process.wait()
    finally:
        stdout_handle.close()
        stderr_handle.close()
    if timed_out:
        exit_code = 124
        signal_number = signal.SIGKILL if return_code == -signal.SIGKILL else signal.SIGTERM
    elif return_code < 0:
        signal_number = -return_code
        exit_code = 128 + signal_number
    else:
        signal_number = None
        exit_code = return_code
    duration = round(time.monotonic() - started, 3)
    result = {
        "schema": RESULT_SCHEMA,
        "request_digest": request["request_digest"],
        "invocation": request["invocation"],
        "attempt": request["attempt"],
        "fence": request["fence"],
        "snapshot_digest": request["repository"]["snapshot_digest"],
        "commit": request["repository"]["commit"],
        "tree": request["repository"]["tree"],
        "command_digest": request["command_digest"],
        "vm_resource_id": vm_resource_id,
        "vm_instance_id": vm_instance_id,
        "boot_id": boot_id,
        "exit_code": exit_code,
        "timed_out": timed_out,
        "signal": signal_number,
        "duration_seconds": duration,
        "stdout_bytes": sizes["stdout"],
        "stderr_bytes": sizes["stderr"],
        "stdout_truncated": truncated["stdout"],
        "stderr_truncated": truncated["stderr"],
        "stdout_digest": sha256_file(stdout_path),
        "stderr_digest": sha256_file(stderr_path),
        "artifacts": [],
    }
    result_path = output / "result.json"
    fd = os.open(str(result_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(canonical_bytes(result) + b"\n")
        handle.flush()
        os.fsync(handle.fileno())
    return 0


if __name__ == "__main__":
    sys.exit(main())
