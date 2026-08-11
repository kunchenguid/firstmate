#!/usr/bin/env python3
"""Validate behavior-test admission before any test can reach Herdr."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
TEST_DIR = ROOT / "tests"
REGISTRY = TEST_DIR / "test-capabilities.tsv"
ENTRY_MARKER = '. "$(dirname "$0")/test-entry.sh"'
CAPABILITIES = {"hermetic", "herdr-lab", "herdr-mixed"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
COMMAND_SUBSTITUTION = re.compile(
    r"\$\(\s*(?:(?:command|exec)\s+)?(?:[^\s;|&()]+/)?herdr\s+"
    r"(?:server\b|session\s+(?!list\b))"
)


class SealError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise SealError(message)


def registry() -> dict[str, str]:
    rows: dict[str, str] = {}
    for number, raw in enumerate(REGISTRY.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 2:
            fail(f"{REGISTRY.relative_to(ROOT)}:{number}: expected test<TAB>capability")
        name, capability = fields
        if Path(name).name != name or not name.endswith(".test.sh"):
            fail(f"{REGISTRY.relative_to(ROOT)}:{number}: invalid test name: {name}")
        if capability not in CAPABILITIES:
            fail(
                f"{REGISTRY.relative_to(ROOT)}:{number}: invalid capability for {name}: "
                f"{capability}"
            )
        if name in rows:
            fail(f"{REGISTRY.relative_to(ROOT)}:{number}: duplicate declaration: {name}")
        rows[name] = capability
    return rows


def tracked_tests() -> dict[str, Path]:
    return {path.name: path for path in sorted(TEST_DIR.glob("*.test.sh"))}


def safe_test_path(raw: str, rows: dict[str, str]) -> Path:
    candidate = Path(raw)
    if not candidate.is_absolute():
        candidate = ROOT / candidate
    try:
        physical = candidate.resolve(strict=True)
    except OSError as error:
        fail(f"test path is unavailable: {raw}: {error}")
    expected = TEST_DIR / physical.name
    if physical != expected:
        fail(f"test is outside the registered suite: {raw}")
    metadata = physical.lstat()
    if not stat.S_ISREG(metadata.st_mode) or physical.is_symlink():
        fail(f"test is not a regular non-symlink file: {raw}")
    if physical.name not in rows:
        fail(f"test has no lifecycle capability declaration: {physical.name}")
    return physical


def command_words(segment: str) -> list[str]:
    try:
        lexer = shlex.shlex(segment, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = "#"
        return list(lexer)
    except ValueError:
        return []


def raw_lifecycle_lines(path: Path) -> list[int]:
    violations: list[int] = []
    pending = ""
    pending_number = 0
    logical_lines: list[tuple[int, str]] = []
    for number, physical in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not pending:
            pending_number = number
        if physical.endswith("\\"):
            pending += physical[:-1] + " "
            continue
        logical_lines.append((pending_number, pending + physical))
        pending = ""
    if pending:
        logical_lines.append((pending_number, pending))
    for number, raw in logical_lines:
        stripped = raw.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        if COMMAND_SUBSTITUTION.search(raw):
            violations.append(number)
            continue
        words = command_words(raw)
        segment: list[str] = []
        for word in [*words, ";"]:
            if word in {";", "&&", "||", "|", "(", ")"}:
                if raw_lifecycle_segment(segment):
                    violations.append(number)
                    break
                segment = []
            else:
                segment.append(word)
    return violations


def raw_lifecycle_segment(words: list[str]) -> bool:
    while words and words[0] in {"if", "elif", "while", "until", "then", "do", "!", "time"}:
        words = words[1:]
    while words and ASSIGNMENT.match(words[0]):
        words = words[1:]
    if words and words[0] == "env":
        words = words[1:]
        while words and (words[0].startswith("-") or ASSIGNMENT.match(words[0])):
            words = words[1:]
    while words and words[0] in {"command", "exec"}:
        words = words[1:]
        while words and words[0].startswith("-"):
            words = words[1:]
    if len(words) < 2:
        return False
    command = Path(words[0]).name
    if command != "herdr" and not re.fullmatch(r"\$\{?[A-Za-z_]*HERDR[A-Za-z0-9_]*\}?", command):
        return False
    if words[1] == "server":
        return True
    return len(words) >= 3 and words[1] == "session" and words[2] != "list"


def verify_routes() -> dict[str, str]:
    rows = registry()
    tests = tracked_tests()
    missing = sorted(set(tests) - set(rows))
    stale = sorted(set(rows) - set(tests))
    if missing:
        fail("tests missing lifecycle capability declarations: " + ", ".join(missing))
    if stale:
        fail("lifecycle declarations name absent tests: " + ", ".join(stale))
    for name, path in tests.items():
        header = path.read_text(encoding="utf-8").splitlines()[:12]
        if ENTRY_MARKER not in header:
            fail(f"{name}: direct execution does not source tests/test-entry.sh in its header")
        violations = raw_lifecycle_lines(path)
        if violations:
            rendered = ", ".join(str(line) for line in violations)
            fail(
                f"{name}:{rendered}: raw Herdr server/session lifecycle is forbidden; "
                "use tests/herdr-test-safety.sh"
            )
    return rows


def parent_pid(pid: int) -> int:
    observed = subprocess.check_output(
        ["ps", "-o", "ppid=", "-p", str(pid)], text=True
    ).strip()
    return int(observed)


def runner_is_ancestor(runner_pid: int) -> bool:
    current = os.getppid()
    seen: set[int] = set()
    while current > 1 and current not in seen:
        if current == runner_pid:
            return True
        seen.add(current)
        try:
            current = parent_pid(current)
        except (OSError, subprocess.SubprocessError, ValueError):
            return False
    return False


def admit(path: Path, capability: str) -> None:
    if os.environ.get("FM_TEST_RUNNER_ACTIVE") != "firstmate-test-runner-v1":
        fail("test was not launched through tests/run.sh")
    suite_root_raw = os.environ.get("FM_TEST_SUITE_ROOT", "")
    token_raw = os.environ.get("FM_TEST_RUNNER_TOKEN", "")
    runner_raw = os.environ.get("FM_TEST_RUNNER_PID", "")
    if not suite_root_raw or not token_raw or not runner_raw.isdigit():
        fail("runner admission identity is incomplete")
    suite_root = Path(suite_root_raw).resolve(strict=True)
    token = Path(token_raw)
    if token.is_symlink() or not token.is_file():
        fail("runner admission token is not a regular non-symlink file")
    token = token.resolve(strict=True)
    if token.parent != suite_root:
        fail("runner admission token escaped its owned suite directory")
    mode = stat.S_IMODE(token.stat().st_mode)
    if token.stat().st_uid != os.getuid() or mode & 0o077:
        fail("runner admission token has unsafe ownership or permissions")
    try:
        record = json.loads(token.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        fail(f"runner admission token is unreadable: {error}")
    expected = {
        "runner_pid": int(runner_raw),
        "test": str(path),
        "capability": capability,
    }
    if record != expected:
        fail("runner admission token does not authorize this test and capability")
    if not runner_is_ancestor(int(runner_raw)):
        fail("recorded test runner is not an ancestor of this process")
    if os.environ.get("FM_TEST_HERDR_CAPABILITY") != capability:
        fail("runtime lifecycle capability differs from the registry")
    if capability in {"herdr-lab", "herdr-mixed"} and os.environ.get(
        "FM_TEST_SKIP_HERDR", "0"
    ) != "1":
        session = os.environ.get("FM_TEST_HERDR_LAB_SESSION", "")
        if not re.fullmatch(r"fm-lab-[A-Za-z0-9][A-Za-z0-9_-]*", session):
            fail("real-Herdr test has no valid runner-owned lab session")
        if os.environ.get("HERDR_SESSION") != session:
            fail("real-Herdr test ambient session differs from its owned lab")
        helper = os.environ.get("HERDR_LAB_HELPER", "")
        if Path(helper).resolve() != ROOT / "bin" / "fm-herdr-lab.sh":
            fail("real-Herdr test is not bound to this checkout's lab helper")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("verify")
    capability_parser = subparsers.add_parser("capability")
    capability_parser.add_argument("test")
    admit_parser = subparsers.add_parser("admit")
    admit_parser.add_argument("test")
    scan_parser = subparsers.add_parser("scan-file")
    scan_parser.add_argument("test", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "verify":
            verify_routes()
        elif args.command == "scan-file":
            violations = raw_lifecycle_lines(args.test)
            if violations:
                fail(
                    f"{args.test}: raw Herdr server/session lifecycle on lines "
                    + ", ".join(str(line) for line in violations)
                )
        else:
            rows = registry()
            path = safe_test_path(args.test, rows)
            capability = rows[path.name]
            if args.command == "capability":
                print(capability)
            else:
                admit(path, capability)
    except SealError as error:
        print(f"test admission refused: {error}", file=sys.stderr)
        return 97
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
