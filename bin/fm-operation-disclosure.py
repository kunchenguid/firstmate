#!/usr/bin/env python3
"""Issue and consume argument-bound disclosure receipts for guarded operations."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import shlex
import subprocess
import sys
import time
from pathlib import Path

VERSION = 1
OPERATIONS = {
    "spawn": "dispatch task-lifecycle briefing",
    "pr-merge": "task-lifecycle",
    "local-merge": "task-lifecycle",
    "teardown": "task-lifecycle",
    "control": "dispatch task-lifecycle",
    "overlay-rebuild": "operational-home",
    "overlay-install": "operational-home",
}
ROLES = {"primary", "secondmate"}
HANDOFFS = {"control-relaunch": ("control", "spawn")}


class Refusal(RuntimeError):
    pass


def system_command(name: str, candidates: tuple[str, ...]) -> str:
    for candidate in candidates:
        if Path(candidate).is_file():
            return candidate
    raise Refusal(f"fixed system {name} executable is unavailable")


def canonical_home(value: str) -> Path:
    home = Path(value).resolve()
    if not home.is_dir():
        raise Refusal(f"home is unavailable: {home}")
    return home


def instruction_digest(root: Path, disclosures: str) -> str:
    digest = hashlib.sha256()
    for name in disclosures.split():
        path = root / {
            "dispatch": "FIRSTMATE_DISPATCH.md",
            "task-lifecycle": "FIRSTMATE_TASK_LIFECYCLE.md",
            "briefing": "FIRSTMATE_BRIEFING.md",
            "operational-home": "FIRSTMATE_OPERATIONAL_HOME.md",
        }[name]
        if not path.is_file():
            raise Refusal(f"disclosure owner is unavailable: {path}")
        digest.update(name.encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def payload(args: argparse.Namespace, root: Path, home: Path, nonce: str, issued: int) -> dict:
    disclosures = OPERATIONS[args.operation]
    return {
        "version": VERSION,
        "nonce": nonce,
        "operation": args.operation,
        "task": args.task,
        "arguments": args.arguments,
        "role": args.role,
        "home": str(home),
        "root": str(root),
        "mutation_paths": {
            "state": str(Path(os.environ.get("FM_STATE_OVERRIDE", home / "state")).resolve()),
            "data": str(Path(os.environ.get("FM_DATA_OVERRIDE", home / "data")).resolve()),
            "config": str(Path(os.environ.get("FM_CONFIG_OVERRIDE", home / "config")).resolve()),
            "projects": str(Path(os.environ.get("FM_PROJECTS_OVERRIDE", home / "projects")).resolve()),
        },
        "instruction_sha256": instruction_digest(root, disclosures),
        "disclosures": disclosures.split(),
        "issued_at": issued,
        "expires_at": issued + args.ttl,
    }


def receipt_digest(value: dict) -> str:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


def receipt_dir(home: Path) -> Path:
    path = home / "state" / "operation-disclosures"
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir():
        raise Refusal("receipt directory is unsafe")
    return path


def disclose(args: argparse.Namespace) -> None:
    root = Path(args.root).resolve()
    home = canonical_home(args.home)
    if args.role not in ROLES:
        raise Refusal(f"role {args.role!r} cannot authorize guarded fleet mutation")
    issued = int(time.time())
    value = payload(args, root, home, secrets.token_hex(16), issued)
    token = receipt_digest(value)
    target = receipt_dir(home) / f"{token}.pending"
    temp = target.with_suffix(f".tmp-{os.getpid()}")
    temp.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.chmod(temp, 0o600)
    os.replace(temp, target)
    for name in value["disclosures"]:
        print(f"DISCLOSE bin/fm-instructions.sh {name}")
    print(f"FM_DISCLOSURE_TOKEN={token}")


def process_cwd(pid: int) -> Path:
    proc_cwd = Path(f"/proc/{pid}/cwd")
    if proc_cwd.exists():
        return proc_cwd.resolve()
    result = subprocess.run(
        (system_command("lsof", ("/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof")),
         "-a", "-p", str(pid), "-d", "cwd", "-Fn"),
        check=False,
        capture_output=True,
        text=True,
    )
    line = next((item[1:] for item in result.stdout.splitlines() if item.startswith("n")), "")
    if result.returncode or not line:
        raise Refusal("internal disclosure caller cwd is unavailable")
    return Path(line).resolve()


def process_executable(pid: int) -> Path:
    proc_executable = Path(f"/proc/{pid}/exe")
    if proc_executable.exists():
        return proc_executable.resolve()
    result = subprocess.run(
        (system_command("lsof", ("/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof")),
         "-a", "-p", str(pid), "-d", "txt", "-Fn"),
        check=False,
        capture_output=True,
        text=True,
    )
    executable = next((item[1:] for item in result.stdout.splitlines() if item.startswith("n")), "")
    if result.returncode or not executable:
        raise Refusal("internal disclosure caller executable is unavailable")
    return Path(executable).resolve()


def process_identity(pid: int) -> tuple[int, str, Path, Path]:
    result = subprocess.run(
        (system_command("ps", ("/bin/ps", "/usr/bin/ps")),
         "-o", "ppid=,command=", "-p", str(pid)),
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode or not result.stdout.strip():
        raise Refusal("internal disclosure caller ancestry is unavailable")
    parent, command = result.stdout.strip().split(maxsplit=1)
    return int(parent), command, process_cwd(pid), process_executable(pid)


def trusted_shell(executable: Path) -> bool:
    common_shells = (
        "/opt/homebrew/bin/bash",
        "/usr/local/bin/bash",
        "/home/linuxbrew/.linuxbrew/bin/bash",
    )
    try:
        configured = {
            Path(line).resolve()
            for line in Path("/etc/shells").read_text().splitlines()
            if line.startswith("/") and Path(line).name in {"bash", "sh"}
        }
    except OSError:
        return False
    configured.update(Path(path).resolve() for path in common_shells if Path(path).is_file())
    return executable.resolve() in configured


def command_runs(command: str, cwd: Path, executable: Path, root: Path, script: str) -> bool:
    expected = (root / "bin" / script).resolve()
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False
    if not tokens:
        return False
    if not trusted_shell(executable) or len(tokens) <= 1:
        return False
    candidate = Path(tokens[1])
    if not candidate.is_absolute():
        candidate = cwd / candidate
    return candidate.resolve() == expected


def test_call_is_authorized() -> bool:
    if os.environ.get("FM_TEST_MODE") != "1":
        return False
    runner_pid = os.environ.get("FM_TEST_RUNNER_PID", "")
    if not runner_pid.isdigit():
        return False
    expected_pid = int(runner_pid)
    root = Path(__file__).resolve().parent.parent
    pid = os.getppid()
    for _ in range(16):
        parent_pid, command, cwd, executable = process_identity(pid)
        if pid == expected_pid:
            if command_runs(command, cwd, executable, root, "fm-test-run.sh"):
                return True
            raise Refusal("test disclosure runner identity does not match its process")
        if pid <= 1 or parent_pid == pid:
            break
        pid = parent_pid
    raise Refusal("test disclosure runner is not an ancestor of the guarded operation")


def receipt_ttl(value: dict) -> int:
    issued = value.get("issued_at")
    expires = value.get("expires_at")
    if type(issued) is not int or type(expires) is not int:
        raise Refusal("malformed disclosure receipt timestamps")
    ttl = expires - issued
    if ttl < 1 or ttl > 900:
        raise Refusal("malformed disclosure receipt ttl")
    return ttl


def consume(args: argparse.Namespace) -> None:
    if test_call_is_authorized():
        return
    token = os.environ.get("FM_DISCLOSURE_TOKEN", "")
    if len(token) != 64 or any(ch not in "0123456789abcdef" for ch in token):
        raise Refusal("missing or malformed disclosure token")
    root = Path(args.root).resolve()
    home = canonical_home(args.home)
    directory = receipt_dir(home)
    source = directory / f"{token}.pending"
    used = directory / f"{token}.used"
    handed_off = directory / f"{token}.handed-off"
    if used.exists() or handed_off.exists():
        raise Refusal("disclosure token was already consumed")
    if source.is_symlink() or not source.is_file():
        raise Refusal("disclosure token is missing or belongs to another home")
    try:
        value = json.loads(source.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise Refusal(f"malformed disclosure receipt: {error}") from error
    args.ttl = receipt_ttl(value)
    expected = payload(args, root, home, value.get("nonce", ""), value.get("issued_at", 0))
    if value != expected or receipt_digest(value) != token:
        raise Refusal("stale or mismatched disclosure token")
    if int(time.time()) >= value["expires_at"]:
        raise Refusal("disclosure token expired")
    try:
        os.replace(source, used)
    except OSError as error:
        raise Refusal(f"could not consume disclosure token atomically: {error}") from error


def handoff(args: argparse.Namespace) -> None:
    if test_call_is_authorized():
        print(f"FM_DISCLOSURE_TOKEN={'0' * 64}")
        return
    token = os.environ.get("FM_DISCLOSURE_TOKEN", "")
    if len(token) != 64 or any(ch not in "0123456789abcdef" for ch in token):
        raise Refusal("missing or malformed disclosure token")
    source_operation, target_operation = HANDOFFS[args.operation]
    root = Path(args.root).resolve()
    home = canonical_home(args.home)
    directory = receipt_dir(home)
    source = directory / f"{token}.used"
    handed_off = directory / f"{token}.handed-off"
    if handed_off.exists():
        raise Refusal("disclosure handoff was already issued")
    if source.is_symlink() or not source.is_file():
        raise Refusal("consumed disclosure token is unavailable for handoff")
    try:
        value = json.loads(source.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise Refusal(f"malformed disclosure receipt: {error}") from error
    if (
        value.get("operation") != source_operation
        or value.get("task") != args.task
        or value.get("root") != str(root)
        or value.get("home") != str(home)
        or value.get("role") != args.role
        or value.get("arguments", [])[:2] != [args.task, "relaunch"]
        or receipt_digest(value) != token
    ):
        raise Refusal("consumed disclosure token cannot authorize this handoff")
    expected = payload(
        argparse.Namespace(
            operation=source_operation,
            task=args.task,
            arguments=value["arguments"],
            role=args.role,
            ttl=receipt_ttl(value),
        ),
        root,
        home,
        value.get("nonce", ""),
        value.get("issued_at", 0),
    )
    if value != expected or int(time.time()) >= value["expires_at"]:
        raise Refusal("stale or mismatched disclosure token")
    if not args.arguments or args.arguments[0] != args.task or "--relaunch" not in args.arguments[1:]:
        raise Refusal("control relaunch handoff requires the same task's relaunch invocation")
    target_args = argparse.Namespace(
        operation=target_operation,
        task=args.task,
        arguments=args.arguments,
        role=args.role,
        ttl=receipt_ttl(value),
    )
    target_value = payload(target_args, root, home, secrets.token_hex(16), value["issued_at"])
    target_token = receipt_digest(target_value)
    target = directory / f"{target_token}.pending"
    temp = target.with_suffix(f".tmp-{os.getpid()}")
    temp.write_text(json.dumps(target_value, sort_keys=True) + "\n")
    os.chmod(temp, 0o600)
    moved_source = False
    try:
        os.replace(source, handed_off)
        moved_source = True
        os.replace(temp, target)
    except OSError as error:
        temp.unlink(missing_ok=True)
        if moved_source:
            try:
                os.replace(handed_off, source)
            except OSError as rollback_error:
                raise Refusal(f"could not issue or restore disclosure handoff: {rollback_error}") from error
        raise Refusal(f"could not issue disclosure handoff atomically: {error}") from error
    print(f"FM_DISCLOSURE_TOKEN={target_token}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("action", choices=("disclose", "consume", "handoff"))
    result.add_argument("operation", choices=tuple(OPERATIONS) + tuple(HANDOFFS))
    result.add_argument("task")
    result.add_argument("arguments", nargs=argparse.REMAINDER)
    result.add_argument("--root", default=os.environ.get("FM_ROOT_OVERRIDE", Path(__file__).resolve().parent.parent))
    result.add_argument("--home", default=os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", Path(__file__).resolve().parent.parent)))
    result.add_argument("--role", default=os.environ.get("FM_PROMPT_ROLE", "primary"))
    result.add_argument("--ttl", type=int, default=300)
    return result


def main() -> int:
    args = parser().parse_args()
    if args.arguments[:1] == ["--"]:
        args.arguments = args.arguments[1:]
    if args.ttl < 1 or args.ttl > 900:
        print("REFUSED: ttl must be between 1 and 900 seconds", file=sys.stderr)
        return 2
    try:
        if args.action == "handoff":
            if args.operation not in HANDOFFS:
                raise Refusal("unsupported disclosure handoff")
            handoff(args)
        elif args.operation in HANDOFFS:
            raise Refusal("handoff operation requires the handoff action")
        else:
            (disclose if args.action == "disclose" else consume)(args)
    except (OSError, Refusal) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
