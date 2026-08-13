#!/usr/bin/env python3
"""Execute bounded Crosscheck evidence in a networkless Azure runner checkout."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


MAX_CAPTURE = 200_000
MAX_FILES = 64
MAX_FILE_BYTES = 12 * 1024
MAX_TOTAL_BYTES = 24 * 1024
SAFE_EVIDENCE_PATH = re.compile(
    r"^\.crosscheck/(?:reproductions|mutations)/[A-Za-z0-9._/+@:-]{1,180}$"
)
SAFE_TRACKED_PATH = re.compile(r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9._/+@:-]{1,240}$")


def contained_regular(root: Path, relative: str) -> Path:
    target = root / relative
    resolved = target.resolve(strict=True)
    if root not in resolved.parents:
        raise ValueError("path escapes exact checkout")
    current = root
    for part in Path(relative).parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("path traverses a symlink")
    if not stat.S_ISREG(os.stat(resolved, follow_symlinks=False).st_mode):
        raise ValueError("path is not a regular file")
    return resolved


def safe_manifest_parent(root: Path, relative: str) -> Path:
    current = root
    for part in Path(relative).parent.parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            current.mkdir(mode=0o700)
            mode = current.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise ValueError("evidence manifest parent is not a real directory")
    if root not in current.resolve().parents and current.resolve() != root:
        raise ValueError("evidence manifest parent escapes exact checkout")
    return current


def materialize_manifest(root: Path, encoded: str) -> None:
    try:
        files = json.loads(base64.b64decode(encoded, validate=True))
    except (ValueError, json.JSONDecodeError) as exc:
        raise ValueError("evidence manifest is malformed") from exc
    if not isinstance(files, dict) or not files or len(files) > MAX_FILES:
        raise ValueError("evidence manifest item count is invalid")
    total = 0
    for relative, body in files.items():
        if (
            not isinstance(relative, str)
            or not SAFE_EVIDENCE_PATH.fullmatch(relative)
            or ".." in Path(relative).parts
            or "//" in relative
            or not isinstance(body, str)
        ):
            raise ValueError("evidence manifest path is invalid")
        try:
            content = base64.b64decode(body, validate=True)
        except ValueError as exc:
            raise ValueError("evidence body is malformed") from exc
        total += len(content)
        if (
            not content
            or len(content) > MAX_FILE_BYTES
            or total > MAX_TOTAL_BYTES
            or b"\x00" in content
        ):
            raise ValueError("evidence body violates its byte contract")
        parent = safe_manifest_parent(root, relative)
        target = parent / Path(relative).name
        descriptor = os.open(
            target,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o700 if relative.startswith(".crosscheck/reproductions/") else 0o600,
        )
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)


def clean_environment(home: Path) -> dict[str, str]:
    return {
        "HOME": str(home),
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_TERMINAL_PROMPT": "0",
    }


def run_bounded(
    argv: list[str], cwd: Path, environment: dict[str, str], timeout: int
) -> subprocess.CompletedProcess[bytes]:
    try:
        completed = subprocess.run(
            argv,
            cwd=cwd,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise ValueError("evidence command exceeded its deadline") from exc
    if len(completed.stdout) + len(completed.stderr) > MAX_CAPTURE:
        raise ValueError("evidence command output exceeded its byte bound")
    return completed


def run_reproduction(args: argparse.Namespace, root: Path, home: Path) -> None:
    test = contained_regular(root, args.test_path)
    completed = run_bounded(
        [
            "bash", "--noprofile", "--norc", str(test),
            args.base_sha, args.head_sha,
        ],
        root,
        clean_environment(home),
        900,
    )
    combined = completed.stdout + completed.stderr
    if completed.returncode != args.expected_exit:
        raise ValueError("replay observed an unexpected helper exit")
    if args.output_contains.encode() not in combined:
        raise ValueError("replay did not observe its required marker")
    if args.receipt_path:
        receipt = contained_regular(root, args.receipt_path).read_bytes()
        if len(receipt) > MAX_CAPTURE:
            raise ValueError("replay receipt exceeded its byte bound")
        if any(marker.encode() not in receipt for marker in args.receipt_contains):
            raise ValueError("replay receipt omitted bound identity")
        sys.stdout.buffer.write(receipt)
    else:
        sys.stdout.buffer.write(b"remote-evidence-ok\n")


def exact_clone(source: Path, destination: Path, head_sha: str, environment: dict[str, str]) -> None:
    cloned = run_bounded(
        [
            "git", "-c", "protocol.file.allow=always", "clone", "--quiet",
            "--no-hardlinks", str(source), str(destination),
        ],
        source,
        environment,
        180,
    )
    if cloned.returncode != 0:
        raise ValueError("mutation proof could not create an exact clone")
    checkout = run_bounded(
        ["git", "checkout", "--quiet", "--detach", head_sha],
        destination,
        environment,
        60,
    )
    if checkout.returncode != 0:
        raise ValueError("mutation proof could not select the exact head")
    observed = run_bounded(
        ["git", "rev-parse", "HEAD"], destination, environment, 30
    )
    status = run_bounded(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        destination,
        environment,
        30,
    )
    if observed.stdout.decode().strip() != head_sha or status.stdout:
        raise ValueError("mutation proof clone is not the exact clean head")


def pytest_command(root: Path, checkout: Path, test_path: str) -> list[str]:
    python = root / "tools" / "agent-fleet" / ".venv" / "bin" / "python"
    if not python.is_file() or not os.access(python, os.X_OK):
        raise ValueError("mutation proof has no pinned Azure pytest runtime")
    return [str(python), "-m", "pytest", test_path]


def run_mutation(args: argparse.Namespace, root: Path, home: Path) -> None:
    if args.test_runner != "pytest":
        raise ValueError("mutation proof runner has no Azure non-execution classification")
    if not SAFE_TRACKED_PATH.fullmatch(args.test_path) or "::" in args.test_path.split("/", 1)[0]:
        raise ValueError("mutation proof test path is invalid")
    patch = contained_regular(root, args.mutation_path)
    expected_changed = sorted(set(args.changed_path))
    if not expected_changed or any(not SAFE_TRACKED_PATH.fullmatch(path) for path in expected_changed):
        raise ValueError("mutation proof changed-path identity is invalid")
    proof_root = root / ".crosscheck-azure-mutation"
    if proof_root.exists() or proof_root.is_symlink():
        raise ValueError("mutation proof scratch already exists")
    proof_root.mkdir(mode=0o700)
    baseline = proof_root / "baseline"
    mutated = proof_root / "mutated"
    environment = clean_environment(home)
    try:
        exact_clone(root, baseline, args.head_sha, environment)
        exact_clone(root, mutated, args.head_sha, environment)
        baseline_result = run_bounded(
            pytest_command(root, baseline, args.test_path), baseline, environment, 900
        )
        if baseline_result.returncode != 0:
            raise ValueError("mutation proof baseline did not pass")
        applied = run_bounded(
            ["git", "apply", "--whitespace=nowarn", str(patch)],
            mutated,
            environment,
            60,
        )
        if applied.returncode != 0:
            raise ValueError("mutation proof patch did not apply")
        changed = run_bounded(
            ["git", "diff", "--name-only"], mutated, environment, 30
        ).stdout.decode().splitlines()
        if sorted(changed) != expected_changed:
            raise ValueError("mutation proof patch changed an unexpected path set")
        mutated_result = run_bounded(
            pytest_command(root, mutated, args.test_path), mutated, environment, 900
        )
        if mutated_result.returncode in {2, 3, 4, 5}:
            raise ValueError("mutation proof test did not execute after mutation")
        if mutated_result.returncode != 1:
            raise ValueError("mutation proof named test did not catch the mutation")
        sys.stdout.buffer.write(b"remote-mutation-ok\n")
    finally:
        shutil.rmtree(proof_root, ignore_errors=True)
        if proof_root.exists() or proof_root.is_symlink():
            raise ValueError("mutation proof scratch cleanup failed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("reproduction", "mutation"), default="reproduction")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--test-path", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--expected-exit", type=int)
    parser.add_argument("--output-contains")
    parser.add_argument("--receipt-path")
    parser.add_argument("--receipt-contains", action="append", default=[])
    parser.add_argument("--mutation-path")
    parser.add_argument("--test-runner")
    parser.add_argument("--changed-path", action="append", default=[])
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.base_sha) or not re.fullmatch(
        r"[0-9a-f]{40}", args.head_sha
    ):
        raise SystemExit("Azure evidence replay refused malformed exact-head identity")
    root = Path.cwd().resolve()
    home = root / ".crosscheck-home"
    try:
        materialize_manifest(root, args.manifest)
        home.mkdir(mode=0o700, exist_ok=False)
        if args.mode == "reproduction":
            if args.expected_exit is None or not args.output_contains:
                raise ValueError("reproduction expectations are incomplete")
            run_reproduction(args, root, home)
        else:
            if not args.mutation_path or not args.test_runner:
                raise ValueError("mutation proof request is incomplete")
            run_mutation(args, root, home)
    except (OSError, ValueError) as exc:
        raise SystemExit("Azure evidence replay refused: " + str(exc)) from exc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
