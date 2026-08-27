#!/usr/bin/env python3
"""Select the focused Azure service suite or the full behavior inventory."""

import argparse
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent
SHA = re.compile(r"^[0-9a-f]{40}$")
FOCUSED_TESTS = (
    "tests/fm-azure-pilot.test.sh",
    "tests/fm-azure-runner.test.sh",
    "tests/fm-cloud-provider-seal.test.sh",
    "tests/fm-no-mistakes-reattach.test.sh",
    "tests/fm-no-mistakes-runtime.test.sh",
    "tests/fm-no-mistakes-worker.test.sh",
    "tests/fm-worker-lifecycle.test.sh",
    "tests/fm-worker-outcome-transport.test.sh",
    "tests/fm-worker-placement.test.sh",
    "tests/fm-worker-supervisor.test.sh",
)
FOCUSED_SOURCES = frozenset(
    (
        ".no-mistakes.yaml",
        "bin/fm-azure-pilot.sh",
        "bin/fm-azure-runner.py",
        "bin/fm-azure-runner-dispatch.sh",
        "bin/fm-azure-worker-provider.py",
        "bin/fm-no-mistakes-reattach.sh",
        "bin/fm-no-mistakes-runtime.py",
        "bin/fm-no-mistakes-test-command.sh",
        "bin/fm-no-mistakes-worker",
        "bin/fm-worker-lifecycle.py",
        "bin/fm-worker-lifecycle.sh",
        "bin/fm-worker-supervisor.py",
        "docs/azure-workers.md",
    )
    + FOCUSED_TESTS
)


def git(*args):
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout


def changed_paths(base, head):
    if not SHA.fullmatch(base) or not SHA.fullmatch(head):
        raise ValueError("base and head must be exact 40-character lowercase SHAs")
    body = git("diff", "--name-only", "-z", base, head, "--")
    return tuple(item.decode("utf-8") for item in body.split(b"\0") if item)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    mode = sub.add_parser("mode")
    mode.add_argument("base")
    mode.add_argument("head")
    shell = sub.add_parser("shell")
    shell.add_argument("base")
    shell.add_argument("head")
    args = parser.parse_args()
    if args.command == "list":
        for path in FOCUSED_TESTS:
            print(path)
        return
    paths = changed_paths(args.base, args.head)
    if args.command == "mode":
        print("focused" if paths and set(paths) <= FOCUSED_SOURCES else "full")
        return
    for path in paths:
        if path.endswith(".sh") and path.startswith(("bin/", "tests/")):
            print(path)


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError, subprocess.CalledProcessError) as exc:
        raise SystemExit("fm-azure-service-test-scope: {}".format(exc))
