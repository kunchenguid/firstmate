#!/usr/bin/env python3
"""Pinned minimal guest supervisor for one exact Azure author assignment.

The host installs this exact committed file through the immutable bootstrap Run
Command.  It accepts one canonical request, re-proves assignment/environment
bindings, runs one command without a shell, and atomically writes one bounded
result.  It has no fleet, secondmate, browser, network, or child-worker API.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


SCHEMA = "fm.worker-execution/v1"
RESULT_SCHEMA = "fm.worker-execution-result/v1"
HEX = re.compile(r"^[0-9a-f]{64}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
MAX_REQUEST_BYTES = 1024 * 1024
MAX_RESULT_BYTES = 8 * 1024 * 1024
MAX_WALL_SECONDS = 6 * 60 * 60
MAX_OUTPUT_BYTES = 4 * 1024 * 1024


class SupervisorError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def read_request(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_REQUEST_BYTES:
        raise SupervisorError("execution request is absent, redirected, or oversized")
    try:
        request = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SupervisorError("execution request is unreadable: {}".format(exc))
    if not isinstance(request, dict) or request.get("schema") != SCHEMA:
        raise SupervisorError("execution request schema is not supported")
    supplied = request.get("request_digest")
    unsigned = dict(request)
    unsigned.pop("request_digest", None)
    if not isinstance(supplied, str) or supplied != digest(unsigned):
        raise SupervisorError("execution request digest is not exact")
    for field in (
        "home_binding", "task", "task_generation", "assignment_generation",
        "repository_generation", "cloud_instance_id",
    ):
        value = request.get(field)
        if field == "home_binding":
            if not isinstance(value, str) or not HEX.fullmatch(value):
                raise SupervisorError("execution home binding is malformed")
        elif not isinstance(value, str) or not SAFE_ID.fullmatch(value):
            raise SupervisorError("execution {} is malformed".format(field))
    for field in ("account_binding", "worktree_binding", "repository_binding"):
        if not isinstance(request.get(field), str) or not HEX.fullmatch(request[field]):
            raise SupervisorError("execution {} is malformed".format(field))
    argv = request.get("argv")
    if (
        not isinstance(argv, list) or not argv or len(argv) > 64
        or any(not isinstance(item, str) or not item or "\x00" in item or len(item) > 4096 for item in argv)
    ):
        raise SupervisorError("execution argv is malformed or unbounded")
    wall = request.get("wall_seconds")
    if not isinstance(wall, int) or isinstance(wall, bool) or not 1 <= wall <= MAX_WALL_SECONDS:
        raise SupervisorError("execution wall deadline is invalid")
    return request


def verify_environment(request):
    bindings = {
        "FM_WORKER_HOME_BINDING": "home_binding",
        "FM_WORKER_TASK": "task",
        "FM_WORKER_TASK_GENERATION": "task_generation",
        "FM_WORKER_ASSIGNMENT_GENERATION": "assignment_generation",
        "FM_WORKER_ACCOUNT_BINDING": "account_binding",
        "FM_WORKER_WORKTREE_BINDING": "worktree_binding",
        "FM_WORKER_REPOSITORY_BINDING": "repository_binding",
        "FM_WORKER_REPOSITORY_GENERATION": "repository_generation",
        "FM_WORKER_CLOUD_INSTANCE_ID": "cloud_instance_id",
    }
    for env_name, field in bindings.items():
        if os.environ.get(env_name) != request[field]:
            raise SupervisorError("guest environment {} binding differs".format(field))
    worktree = Path(os.environ.get("FM_WORKER_WORKTREE", "")).resolve()
    if not worktree.is_dir() or worktree == Path("/"):
        raise SupervisorError("guest worktree is unavailable")
    return worktree


def bounded(value):
    if len(value) <= MAX_OUTPUT_BYTES:
        return value, False
    return value[:MAX_OUTPUT_BYTES], True


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SupervisorError("staging fetch was redirected, which is refused")


MAX_ARCHIVE_BYTES = 600 * 1024 * 1024
SAFE_STAGED_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def fetch_archive(label):
    """Fetch one staged archive named by the launch environment and verify it
    byte-for-byte against the digest the digest-bound request carries."""
    prefix = "FM_WORKER_{}_".format(label.upper())
    url = os.environ.get(prefix + "URL", "")
    expected_digest = os.environ.get(prefix + "SHA256", "")
    expected_bytes = os.environ.get(prefix + "BYTES", "")
    if not url.startswith("https://") or not HEX.match(expected_digest) or not expected_bytes.isdigit():
        raise SupervisorError("{} staging environment is incomplete".format(label))
    size = int(expected_bytes)
    if not 0 < size <= MAX_ARCHIVE_BYTES:
        raise SupervisorError("{} staging archive size is unbounded".format(label))
    local_source = os.environ.get(prefix + "FILE", "")
    if local_source:
        # Hermetic test lane: the archive is supplied as a file instead of a
        # network fetch; every verification below still runs unchanged.
        body = Path(local_source).read_bytes()
    else:
        # A redirect-refusing opener: the staging endpoint never redirects,
        # and following one could silently downgrade to plaintext before the
        # digest check.
        opener = urllib.request.build_opener(_NoRedirect())
        try:
            with opener.open(url, timeout=300) as response:
                body = response.read(size + 1)
        except OSError as exc:
            raise SupervisorError("{} staging fetch failed: {}".format(label, exc))
    if len(body) != size or hashlib.sha256(body).hexdigest() != expected_digest:
        raise SupervisorError("{} staging archive differs from its bound digest".format(label))
    return body


def extract_staged_archive(body, manifest, target, label):
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(target, 0o700)
    seen = set()
    try:
        with tarfile.open(fileobj=io.BytesIO(body), mode="r:gz") as archive:
            for member in archive.getmembers():
                if not member.isreg() or not SAFE_STAGED_NAME.match(member.name):
                    raise SupervisorError("{} staging archive member is unsupported: {}".format(label, member.name))
                expected = manifest.get(member.name)
                if not isinstance(expected, dict):
                    raise SupervisorError("{} staging archive member is not in the bound manifest: {}".format(label, member.name))
                handle = archive.extractfile(member)
                content = handle.read() if handle else b""
                if (
                    len(content) != expected.get("bytes")
                    or hashlib.sha256(content).hexdigest() != expected.get("sha256")
                ):
                    raise SupervisorError("{} staged file differs from its bound manifest: {}".format(label, member.name))
                destination = target / member.name
                destination.write_bytes(content)
                destination.chmod(0o600)
                seen.add(member.name)
    except tarfile.TarError as exc:
        raise SupervisorError("{} staging archive is malformed: {}".format(label, exc))
    missing = sorted(set(manifest) - seen)
    if missing:
        raise SupervisorError("{} staging archive lacks bound files: {}".format(label, ", ".join(missing)))


def stage_payload(request, worktree, account_home):
    """Materialize the crewmate payload: repository from its bundle, task
    files, and the provider-account material, all digest-verified."""
    payload_manifest = request.get("payload_files")
    account_manifest = request.get("account_files")
    if payload_manifest is None and account_manifest is None:
        return worktree
    if not isinstance(payload_manifest, dict) or not isinstance(account_manifest, dict):
        raise SupervisorError("payload and account manifests travel together or not at all")
    staging = worktree / ".fm-task"
    extract_staged_archive(fetch_archive("payload"), payload_manifest, staging, "payload")
    account_target = account_home / "pi-agent"
    extract_staged_archive(fetch_archive("account"), account_manifest, account_target, "account")
    repo = worktree / "repo"
    if repo.exists():
        # Staging only runs when no executed marker exists, so anything at
        # the target is the debris of an interrupted earlier staging; remove
        # it rather than wedging every future dispatch of this request.
        if repo.is_symlink() or not repo.is_dir():
            raise SupervisorError("staged repository target is not a removable directory")
        shutil.rmtree(repo)
    bundle = staging / "repo.bundle"
    clone = subprocess.run(
        ["git", "clone", "--quiet", str(bundle), str(repo)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=600, check=False,
    )
    if clone.returncode != 0:
        raise SupervisorError(
            "staged repository bundle clone failed: {}".format(
                clone.stderr.decode("utf-8", errors="replace")[-500:]
            )
        )
    head = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=60, check=False,
    )
    if head.returncode != 0 or head.stdout.decode().strip() != request["repository_generation"]:
        raise SupervisorError("staged repository head differs from the bound repository generation")
    return repo


def write_atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload = canonical(value) + b"\n"
    if len(payload) > MAX_RESULT_BYTES:
        raise SupervisorError("execution result exceeds its bounded allowance")
    fd, name = tempfile.mkstemp(prefix=".worker-result-", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


def execute(request, worktree):
    safe_env = {
        "HOME": str(Path(os.environ.get("FM_WORKER_ACCOUNT_HOME", "/nonexistent")).resolve()),
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/bin/false",
    }
    try:
        completed = subprocess.run(
            request["argv"], cwd=str(worktree), env=safe_env,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=request["wall_seconds"], check=False,
        )
        timed_out = False
        exit_code = completed.returncode
        stdout = completed.stdout
        stderr = completed.stderr
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        exit_code = 124
        stdout = exc.stdout or b""
        stderr = exc.stderr or b""
    stdout, stdout_truncated = bounded(stdout)
    stderr, stderr_truncated = bounded(stderr)
    # Persist the exact digested streams on the retained task disk so the
    # bounded result's stream digests stay verifiable after the VM is gone.
    logs_dir = worktree / ".fm-worker"
    try:
        logs_dir.mkdir(mode=0o700, exist_ok=True)
        for suffix, data in (("stdout", stdout), ("stderr", stderr)):
            stream_path = logs_dir / "{}-{}.log".format(request["assignment_generation"], suffix)
            fd = os.open(str(stream_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
    except OSError as exc:
        raise SupervisorError("guest stream evidence could not be persisted: {}".format(exc))
    result = {
        "schema": RESULT_SCHEMA,
        "request_digest": request["request_digest"],
        "task": request["task"],
        "task_generation": request["task_generation"],
        "assignment_generation": request["assignment_generation"],
        "cloud_instance_id": request["cloud_instance_id"],
        "repository_binding": request["repository_binding"],
        "repository_generation": request["repository_generation"],
        "exit_code": exit_code,
        "timed_out": timed_out,
        "stdout_sha256": hashlib.sha256(stdout).hexdigest(),
        "stderr_sha256": hashlib.sha256(stderr).hexdigest(),
        "stdout_truncated": stdout_truncated,
        "stderr_truncated": stderr_truncated,
    }
    unsigned = dict(result)
    result["result_digest"] = digest(unsigned)
    return result


def steer_ack(args):
    assignment_path = Path(
        os.environ.get("FM_WORKER_ASSIGNMENT_PATH", "/var/lib/firstmate-worker/assignment.json")
    )
    try:
        assignment = json.loads(assignment_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SupervisorError("guest assignment record is unreadable: {}".format(exc))
    expected = {
        "home_binding": args.home_binding,
        "task": args.task,
        "task_generation": args.task_generation,
        "assignment_generation": args.assignment_generation,
    }
    for field, value in sorted(expected.items()):
        if assignment.get(field) != value:
            raise SupervisorError("steer {} binding differs from the guest assignment".format(field))
    if not HEX.match(str(args.request_digest)):
        raise SupervisorError("steer request digest is malformed")
    ack = {
        "schema": "fm.worker-steer-ack/v1",
        "assignment_generation": args.assignment_generation,
        "request_digest": args.request_digest,
    }
    ack["ack_digest"] = digest(ack)
    print("FM-WORKER-STEER-ACK:" + json.dumps(ack, sort_keys=True, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    exe = sub.add_parser("execute")
    exe.add_argument("--request", required=True)
    exe.add_argument("--result", required=True)
    steer = sub.add_parser("steer")
    steer.add_argument("--home-binding", required=True)
    steer.add_argument("--task", required=True)
    steer.add_argument("--task-generation", required=True)
    steer.add_argument("--assignment-generation", required=True)
    steer.add_argument("--request-digest", required=True)
    args = parser.parse_args()
    if args.mode == "steer":
        steer_ack(args)
        return
    if args.mode != "execute":
        raise SupervisorError("only one-task execute is supported")
    request = read_request(args.request)
    worktree = verify_environment(request)
    # One request digest executes at most once on this guest: a controller
    # replay after a transport loss re-emits the recorded result instead of
    # running the task command a second time.
    executed_dir = Path(
        os.environ.get("FM_WORKER_EXECUTED_DIR", "/var/lib/firstmate-worker/executed")
    )
    marker = executed_dir / (request["request_digest"] + ".json")
    if marker.is_file():
        try:
            recorded = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SupervisorError("recorded execution replay evidence is unreadable: {}".format(exc))
        unsigned = dict(recorded)
        supplied = unsigned.pop("result_digest", None)
        if supplied != digest(unsigned) or recorded.get("request_digest") != request["request_digest"]:
            raise SupervisorError("recorded execution replay evidence is not exact")
        write_atomic(args.result, recorded)
        print(json.dumps({"result_digest": recorded["result_digest"]}, separators=(",", ":")))
        return
    # Staging happens only on a first execution: a controller replay above
    # re-emits the recorded result without touching the staged repository.
    account_home = Path(os.environ.get("FM_WORKER_ACCOUNT_HOME", "/nonexistent")).resolve()
    worktree = stage_payload(request, worktree, account_home)
    result = execute(request, worktree)
    write_atomic(marker, result)
    write_atomic(args.result, result)
    print(json.dumps({"result_digest": result["result_digest"]}, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except SupervisorError as exc:
        print("WORKER SUPERVISOR REFUSED: {}".format(exc), file=os.sys.stderr)
        raise SystemExit(2)
