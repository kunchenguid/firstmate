#!/usr/bin/env python3
"""Coordinate prompt-return Crosscheck launches for PR-ready registration.

`fm-pr-check.sh` owns the public registration surface.
This helper persists the latest requested exact head, keeps one coordinator per task, and runs Crosscheck outside the caller.
Coordinator and operation locks are task-local, while the existing Azure lane and cost admission remain the spending authority.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, NoReturn, Optional, Tuple


SCHEMA = "firstmate.crosscheck-autostart.v1"
REQUEST_SCHEMA = "firstmate.crosscheck-autostart-request.v1"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PR_RE = re.compile(r"^https://github\.com/[^/\s]+/[^/\s]+/pull/[1-9][0-9]*$")
MAX_RECORD_BYTES = 64 * 1024
MAX_FLEET_ENV_BYTES = 1024 * 1024
MAX_COMMAND_OUTPUT_BYTES = 256 * 1024
MAX_LOG_BYTES = 2 * 1024 * 1024
DEFAULT_ACTIVE_WAIT_SECONDS = 4 * 60 * 60
DEFAULT_COMMAND_TIMEOUT_SECONDS = 4 * 60 * 60
MAX_HEAD_RESTARTS = 16


class AutostartError(RuntimeError):
    """Raised when the task-local launcher cannot honestly start or clear review."""


def fail(message: str) -> NoReturn:
    raise AutostartError(message)


def utc_now() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def bounded_text(value: str, limit: int = 500) -> str:
    flattened = " ".join(value.replace("\r", "\n").splitlines())
    if len(flattened) <= limit:
        return flattened
    return flattened[: limit - 3] + "..."


def positive_int_environment(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    if not raw.isdigit() or int(raw) <= 0:
        fail(f"{name} must be a positive integer")
    return int(raw)


def absolute_without_symlink_resolution(value: str) -> Path:
    return Path(os.path.abspath(os.path.expanduser(value)))


def runtime_paths() -> Tuple[Path, Path, Path]:
    script = Path(__file__).resolve()
    default_root = script.parent.parent
    root = Path(os.environ.get("FM_ROOT_OVERRIDE", str(default_root))).resolve()
    home = Path(os.environ.get("FM_HOME", str(root))).resolve()
    state = absolute_without_symlink_resolution(
        os.environ.get("FM_STATE_OVERRIDE", str(home / "state"))
    )
    try:
        metadata = state.lstat()
    except FileNotFoundError:
        state.mkdir(parents=True, mode=0o700)
        metadata = state.lstat()
    except OSError as exc:
        fail(f"Crosscheck autostart state inspection failed at {state}: {exc}")
    if not stat.S_ISDIR(metadata.st_mode) or state.is_symlink():
        fail(f"Crosscheck autostart state is not a real directory: {state}")
    return root, home, state


def validate_identity(task_id: str, url: str, head: str, generation: str) -> None:
    if ID_RE.fullmatch(task_id) is None:
        fail(f"invalid task id: {task_id!r}")
    if PR_RE.fullmatch(url) is None:
        fail(f"invalid full GitHub PR URL: {url!r}")
    if SHA_RE.fullmatch(head) is None:
        fail(f"invalid exact PR head: {head!r}")
    if (
        not generation
        or len(generation.encode("utf-8")) > 512
        or any(character in generation for character in "\0\r\n")
    ):
        fail("invalid task generation identity")


def task_paths(state: Path, task_id: str) -> Dict[str, Path]:
    return {
        "request": state / f"{task_id}.crosscheck-autostart.request.json",
        "state": state / f"{task_id}.crosscheck-autostart.json",
        "log": state / f"{task_id}.crosscheck-autostart.log",
        "handoff_lock": state / f".{task_id}.crosscheck-autostart-handoff.lock",
        "coordinator_lock": state / f".{task_id}.crosscheck-autostart.lock",
        "crosscheck_lock": state / f".{task_id}.crosscheck.lock",
    }


def atomic_json(path: Path, value: Dict[str, Any]) -> None:
    encoded = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if len(encoded) > MAX_RECORD_BYTES:
        fail(f"Crosscheck autostart JSON exceeds its bound at {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        if path.exists() or path.is_symlink():
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
                fail(f"unsafe Crosscheck autostart destination: {path}")
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def load_json(path: Path, schema: str) -> Optional[Dict[str, Any]]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        return None
    except OSError as exc:
        fail(f"cannot open Crosscheck autostart record {path}: {exc}")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"unsafe Crosscheck autostart record: {path}")
        if metadata.st_size > MAX_RECORD_BYTES:
            fail(f"Crosscheck autostart record exceeds its bound: {path}")
        raw = os.read(descriptor, MAX_RECORD_BYTES + 1)
    finally:
        os.close(descriptor)
    if len(raw) > MAX_RECORD_BYTES:
        fail(f"Crosscheck autostart record exceeds its bound: {path}")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot read Crosscheck autostart record {path}: {exc}")
    if not isinstance(value, dict) or value.get("schema") != schema:
        fail(f"invalid Crosscheck autostart record at {path}")
    return value


def request_record(
    task_id: str, url: str, head: str, generation: str
) -> Dict[str, Any]:
    return {
        "schema": REQUEST_SCHEMA,
        "task_id": task_id,
        "pull_request": url,
        "head_sha": head,
        "generation_id": generation,
        "requested_at": utc_now(),
    }


def write_state(
    path: Path,
    task_id: str,
    url: str,
    head: str,
    generation: str,
    lifecycle: str,
    attempt: int,
    message: str,
    pid: int,
    log: Path,
) -> None:
    if lifecycle not in {"starting", "running", "clear", "failed"}:
        fail(f"invalid Crosscheck autostart state: {lifecycle}")
    atomic_json(
        path,
        {
            "schema": SCHEMA,
            "task_id": task_id,
            "pull_request": url,
            "head_sha": head,
            "generation_id": generation,
            "state": lifecycle,
            "attempt": attempt,
            "pid": pid,
            "updated_at": utc_now(),
            "message": bounded_text(message),
            "log": log.name,
        },
    )


def open_lock(path: Path) -> int:
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as exc:
        fail(f"Crosscheck autostart lock open failed at {path}: {exc}")
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        os.close(descriptor)
        fail(f"unsafe Crosscheck autostart lock: {path}")
    return descriptor


@contextmanager
def task_handoff(paths: Dict[str, Path]):
    descriptor = open_lock(paths["handoff_lock"])
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def fleet_environment_path() -> Path:
    configured = os.environ.get("FM_CROSSCHECK_FLEET_ENV", "")
    if configured:
        path = Path(os.path.expanduser(configured))
    else:
        path = Path.home() / ".fm-azure" / "fleet.env"
    if not path.is_absolute():
        fail("Crosscheck fleet environment path must be absolute")
    return path


def open_fleet_environment(path: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        fail(f"Crosscheck fleet environment is missing: {path}")
    except OSError as exc:
        fail(f"Crosscheck fleet environment cannot be opened safely at {path}: {exc}")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"Crosscheck fleet environment must be a regular non-symlink file: {path}")
        if metadata.st_uid != os.getuid():
            fail(f"Crosscheck fleet environment is not owned by the current operator: {path}")
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            fail(f"Crosscheck fleet environment is group/world writable: {path}")
        if metadata.st_size > MAX_FLEET_ENV_BYTES:
            fail(f"Crosscheck fleet environment exceeds its byte bound: {path}")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def crosscheck_command(root: Path) -> Path:
    command = root / "bin" / "fm-crosscheck.sh"
    try:
        metadata = command.lstat()
    except FileNotFoundError:
        fail(f"Crosscheck command is missing: {command}")
    except OSError as exc:
        fail(f"Crosscheck command inspection failed at {command}: {exc}")
    if (
        not stat.S_ISREG(metadata.st_mode)
        or command.is_symlink()
        or not os.access(command, os.X_OK)
    ):
        fail(f"Crosscheck command is not a real executable file: {command}")
    return command


def next_attempt(state_path: Path, generation: str) -> int:
    existing = load_json(state_path, SCHEMA)
    if existing is None or existing.get("generation_id") != generation:
        return 1
    value = existing.get("attempt")
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        fail(f"invalid Crosscheck autostart attempt at {state_path}")
    return value + 1


def open_log_descriptor(path: Path) -> int:
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as exc:
        fail(f"Crosscheck autostart log open failed at {path}: {exc}")
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        os.close(descriptor)
        fail(f"unsafe Crosscheck autostart log: {path}")
    return descriptor


def append_log(path: Path, label: str, output: bytes) -> None:
    if len(output) > MAX_COMMAND_OUTPUT_BYTES:
        output = output[:MAX_COMMAND_OUTPUT_BYTES] + b"\n[output clipped]\n"
    descriptor = open_log_descriptor(path)
    try:
        metadata = os.fstat(descriptor)
        if metadata.st_size > MAX_LOG_BYTES:
            os.ftruncate(descriptor, 0)
        os.write(descriptor, f"\n[{utc_now()}] {label}\n".encode())
        if output:
            os.write(descriptor, output)
            if not output.endswith(b"\n"):
                os.write(descriptor, b"\n")
    finally:
        os.close(descriptor)


def command_environment() -> Dict[str, str]:
    return os.environ.copy()


def run_crosscheck_command(
    fleet_env: Path,
    command: Path,
    verb: str,
    task_id: str,
    url: str,
    expected_head: str,
    log: Path,
) -> Tuple[int, str]:
    environment_descriptor: Optional[int] = None
    command_arguments = [str(command), verb, task_id, url]
    if verb == "run":
        command_arguments.extend(["--expected-head", expected_head])
        environment_descriptor = open_fleet_environment(fleet_env)
        # Source only the validated, already-open descriptor and suppress output
        # from the private file itself. Crosscheck output is captured separately;
        # environment values never enter argv or Python-owned durable records.
        shell = (
            'set -a; if ! . "/dev/fd/$1" >/dev/null 2>&1; then '
            'printf "Crosscheck fleet environment could not be loaded safely\\n" >&2; '
            'exit 78; fi; set +a; shift; exec "$@"'
        )
        arguments = [
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-c",
            shell,
            "fm-crosscheck-autostart-env",
            str(environment_descriptor),
            *command_arguments,
        ]
        pass_fds = (environment_descriptor,)
    else:
        # Exact-head verification is read-only and needs no fleet credential.
        # Doing it first lets a prior CLEAR result deduplicate even while the
        # private Azure launch configuration is temporarily unavailable.
        arguments = command_arguments
        pass_fds = ()
    timeout = positive_int_environment(
        "FM_CROSSCHECK_AUTOSTART_COMMAND_TIMEOUT_SECONDS",
        DEFAULT_COMMAND_TIMEOUT_SECONDS,
    )
    try:
        completed = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=timeout,
            env=command_environment(),
            pass_fds=pass_fds,
        )
        output = completed.stdout or b""
        append_log(
            log,
            f"{verb} expected_head={expected_head} exit={completed.returncode}",
            output,
        )
        return completed.returncode, output.decode("utf-8", errors="replace")
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, bytes) else b""
        stderr = exc.stderr if isinstance(exc.stderr, bytes) else b""
        append_log(log, f"{verb} expected_head={expected_head} timed out", stdout + stderr)
        return 124, "Crosscheck command timed out"
    except OSError as exc:
        append_log(
            log,
            f"{verb} expected_head={expected_head} launch failed",
            str(exc).encode(),
        )
        return 125, f"Crosscheck command launch failed: {exc}"
    finally:
        if environment_descriptor is not None:
            os.close(environment_descriptor)


def lock_is_active(lock_path: Path) -> bool:
    descriptor = open_lock(lock_path)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        return False
    finally:
        os.close(descriptor)


def latest_request(path: Path) -> Tuple[str, str, str, str]:
    value = load_json(path, REQUEST_SCHEMA)
    if value is None:
        fail(f"Crosscheck autostart request disappeared: {path}")
    task_id = value.get("task_id")
    url = value.get("pull_request")
    head = value.get("head_sha")
    generation = value.get("generation_id")
    if not all(isinstance(item, str) for item in (task_id, url, head, generation)):
        fail(f"invalid Crosscheck autostart request identity at {path}")
    validate_identity(task_id, url, head, generation)
    return task_id, url, head, generation


def validate_task_generation(state: Path, task_id: str, generation: str) -> None:
    metadata_path = state / f"{task_id}.meta"
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(metadata_path, flags)
    except FileNotFoundError:
        fail(f"task metadata disappeared before Crosscheck autostart: {metadata_path}")
    except OSError as exc:
        fail(f"task metadata cannot be opened before Crosscheck autostart: {exc}")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"task metadata is unsafe before Crosscheck autostart: {metadata_path}")
        if metadata.st_size > MAX_RECORD_BYTES:
            fail(f"task metadata exceeds the Crosscheck autostart bound: {metadata_path}")
        raw = os.read(descriptor, MAX_RECORD_BYTES + 1)
    finally:
        os.close(descriptor)
    try:
        text = raw.decode("utf-8")
    except UnicodeError as exc:
        fail(f"task metadata cannot be read before Crosscheck autostart: {exc}")
    observed = ""
    for line in text.splitlines():
        if line.startswith("generation_id="):
            observed = line.split("=", 1)[1]
    if observed != generation:
        fail("task generation changed before Crosscheck autostart")


def matching_verified_head(output: str, expected_head: str) -> bool:
    return output.strip() == expected_head


def worker(lock_descriptor: int, task_id: str, starting_attempt: int) -> int:
    root, _home, state = runtime_paths()
    os.set_inheritable(lock_descriptor, False)
    paths = task_paths(state, task_id)
    attempt = starting_attempt
    processed = 0
    try:
        while processed < MAX_HEAD_RESTARTS:
            request = latest_request(paths["request"])
            current_task, url, head, generation = request
            if current_task != task_id:
                fail("Crosscheck autostart request changed task identity")
            validate_task_generation(state, task_id, generation)
            command = crosscheck_command(root)
            fleet_env = fleet_environment_path()
            write_state(
                paths["state"],
                task_id,
                url,
                head,
                generation,
                "running",
                attempt,
                "exact-head Crosscheck coordinator is running",
                os.getpid(),
                paths["log"],
            )
            active_wait = positive_int_environment(
                "FM_CROSSCHECK_AUTOSTART_ACTIVE_WAIT_SECONDS",
                DEFAULT_ACTIVE_WAIT_SECONDS,
            )
            active_deadline = time.monotonic() + active_wait
            if lock_is_active(paths["crosscheck_lock"]):
                write_state(
                    paths["state"],
                    task_id,
                    url,
                    head,
                    generation,
                    "running",
                    attempt,
                    "matching task Crosscheck operation is active; waiting to deduplicate",
                    os.getpid(),
                    paths["log"],
                )
            while lock_is_active(paths["crosscheck_lock"]):
                if time.monotonic() >= active_deadline:
                    fail("timed out waiting for the matching task Crosscheck operation")
                time.sleep(0.1)
            if latest_request(paths["request"]) != request:
                attempt += 1
                processed += 1
                continue
            verify_status, verify_output = run_crosscheck_command(
                fleet_env,
                command,
                "verify",
                task_id,
                url,
                head,
                paths["log"],
            )
            if verify_status == 0 and matching_verified_head(verify_output, head):
                result_state = "clear"
                result_message = "matching exact-head CLEAR review already exists"
            else:
                run_status, run_output = run_crosscheck_command(
                    fleet_env,
                    command,
                    "run",
                    task_id,
                    url,
                    head,
                    paths["log"],
                )
                if run_status == 0:
                    post_status, post_output = run_crosscheck_command(
                        fleet_env,
                        command,
                        "verify",
                        task_id,
                        url,
                        head,
                        paths["log"],
                    )
                    if post_status == 0 and matching_verified_head(post_output, head):
                        result_state = "clear"
                        result_message = "exact-head Crosscheck completed CLEAR"
                    else:
                        result_state = "failed"
                        result_message = (
                            "Crosscheck returned success but exact-head verification failed: "
                            + bounded_text(post_output)
                        )
                else:
                    result_state = "failed"
                    result_message = "Crosscheck run failed: " + bounded_text(run_output)
            write_state(
                paths["state"],
                task_id,
                url,
                head,
                generation,
                result_state,
                attempt,
                result_message,
                os.getpid(),
                paths["log"],
            )
            with task_handoff(paths):
                if latest_request(paths["request"]) == request:
                    os.close(lock_descriptor)
                    lock_descriptor = -1
                    return 0 if result_state == "clear" else 1
            attempt += 1
            processed += 1
        fail(f"Crosscheck autostart exceeded {MAX_HEAD_RESTARTS} queued head restarts")
    except Exception as exc:
        with task_handoff(paths):
            message = str(exc) if isinstance(exc, AutostartError) else (
                f"unexpected {type(exc).__name__}: {exc}"
            )
            try:
                failed_task, url, head, generation = latest_request(paths["request"])
                if failed_task == task_id:
                    write_state(
                        paths["state"],
                        task_id,
                        url,
                        head,
                        generation,
                        "failed",
                        attempt,
                        message,
                        os.getpid(),
                        paths["log"],
                    )
                    append_log(paths["log"], "coordinator failure", message.encode())
            except Exception:
                pass
            os.close(lock_descriptor)
            lock_descriptor = -1
            return 1
    finally:
        if lock_descriptor >= 0:
            os.close(lock_descriptor)


def start(task_id: str, url: str, head: str, generation: str) -> int:
    validate_identity(task_id, url, head, generation)
    root, _home, state = runtime_paths()
    validate_task_generation(state, task_id, generation)
    paths = task_paths(state, task_id)
    with task_handoff(paths):
        return start_locked(root, paths, task_id, url, head, generation)


def start_locked(
    root: Path, paths: Dict[str, Path], task_id: str, url: str, head: str, generation: str
) -> int:
    descriptor = open_lock(paths["coordinator_lock"])
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            atomic_json(paths["request"], request_record(task_id, url, head, generation))
            existing = load_json(paths["state"], SCHEMA)
            active_head = existing.get("head_sha") if existing else "unknown"
            active_generation = existing.get("generation_id") if existing else ""
            if active_head == head and active_generation == generation:
                print(
                    f"crosscheck autostart: matching review already active for {task_id} at {head}"
                )
            else:
                print(f"crosscheck autostart: queued new head {head} for active task {task_id}")
            return 0
        atomic_json(paths["request"], request_record(task_id, url, head, generation))
        attempt = next_attempt(paths["state"], generation)
        try:
            crosscheck_command(root)
            write_state(
                paths["state"],
                task_id,
                url,
                head,
                generation,
                "starting",
                attempt,
                "starting exact-head Crosscheck coordinator",
                0,
                paths["log"],
            )
            environment = os.environ.copy()
            log_descriptor = open_log_descriptor(paths["log"])
            try:
                process = subprocess.Popen(
                    [
                        sys.executable,
                        str(Path(__file__).resolve()),
                        "worker",
                        str(descriptor),
                        task_id,
                        str(attempt),
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=log_descriptor,
                    stderr=subprocess.STDOUT,
                    close_fds=True,
                    pass_fds=(descriptor,),
                    start_new_session=True,
                    env=environment,
                    cwd=str(root),
                )
            finally:
                os.close(log_descriptor)
            print(f"crosscheck autostart: started {task_id} at {head} (pid {process.pid})")
            return 0
        except Exception as exc:
            message = str(exc) if isinstance(exc, AutostartError) else (
                f"unexpected {type(exc).__name__}: {exc}"
            )
            write_state(
                paths["state"],
                task_id,
                url,
                head,
                generation,
                "failed",
                attempt,
                "Crosscheck autostart launch failed: " + message,
                0,
                paths["log"],
            )
            append_log(paths["log"], "launcher failure", message.encode())
            print(
                "UNREVIEWED: Crosscheck autostart launch failed: "
                + bounded_text(message),
                file=sys.stderr,
            )
            # PR registration already succeeded. Launcher faults are visible in
            # the task-local state and retry with the same command; they never
            # turn registration into a global or operator-blocking refusal.
            return 0
    finally:
        os.close(descriptor)


def status(task_id: str, url: str, head: str, generation: str) -> int:
    validate_identity(task_id, url, head, generation)
    _root, _home, state = runtime_paths()
    paths = task_paths(state, task_id)
    with task_handoff(paths):
        return status_locked(paths, task_id, url, head, generation)


def status_locked(
    paths: Dict[str, Path], task_id: str, url: str, head: str, generation: str
) -> int:
    record = load_json(paths["state"], SCHEMA)
    record_matches = record is not None and (
        record.get("pull_request") == url
        and record.get("head_sha") == head
        and record.get("generation_id") == generation
    )
    if not record_matches:
        request = load_json(paths["request"], REQUEST_SCHEMA)
        request_matches = request is not None and (
            request.get("task_id") == task_id
            and request.get("pull_request") == url
            and request.get("head_sha") == head
            and request.get("generation_id") == generation
        )
        if not request_matches or lock_is_active(paths["coordinator_lock"]):
            return 0
        attempt = next_attempt(paths["state"], generation)
        message = "Crosscheck coordinator stopped before the requested head started; rerun fm-pr-check.sh"
        write_state(
            paths["state"],
            task_id,
            url,
            head,
            generation,
            "failed",
            attempt,
            message,
            0,
            paths["log"],
        )
        print(f"{message}; log={paths['log'].name}")
        return 1
    assert record is not None
    lifecycle = record.get("state")
    if lifecycle in {"starting", "running"} and not lock_is_active(
        paths["coordinator_lock"]
    ):
        attempt = record.get("attempt")
        if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
            fail(f"invalid Crosscheck autostart attempt at {paths['state']}")
        message = "Crosscheck coordinator is no longer active; rerun fm-pr-check.sh"
        write_state(
            paths["state"],
            task_id,
            url,
            head,
            generation,
            "failed",
            attempt,
            message,
            0,
            paths["log"],
        )
        lifecycle = "failed"
        record["message"] = message
    if lifecycle == "failed":
        message = bounded_text(str(record.get("message", "Crosscheck autostart failed")))
        print(f"{message}; log={record.get('log', '')}")
        return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    start_parser = subparsers.add_parser("start")
    status_parser = subparsers.add_parser("status")
    for command in (start_parser, status_parser):
        command.add_argument("task_id")
        command.add_argument("pr_url")
        command.add_argument("head_sha")
        command.add_argument("generation_id")
    worker_parser = subparsers.add_parser("worker")
    worker_parser.add_argument("lock_descriptor", type=int)
    worker_parser.add_argument("task_id")
    worker_parser.add_argument("attempt", type=int)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "start":
            return start(
                args.task_id,
                args.pr_url,
                args.head_sha,
                args.generation_id,
            )
        if args.command == "status":
            return status(
                args.task_id,
                args.pr_url,
                args.head_sha,
                args.generation_id,
            )
        return worker(args.lock_descriptor, args.task_id, args.attempt)
    except AutostartError as exc:
        print(
            f"UNREVIEWED: Crosscheck autostart failed: {bounded_text(str(exc))}",
            file=sys.stderr,
        )
        return 1
    except Exception as exc:
        print(
            "UNREVIEWED: Crosscheck autostart failed unexpectedly: "
            f"{type(exc).__name__}: {bounded_text(str(exc))}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
