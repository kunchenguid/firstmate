#!/usr/bin/env python3
"""Run one admitted test in an owned process group and reap only that group."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time


def group_members(group: int) -> list[int]:
    output = subprocess.check_output(["ps", "-axo", "pid=,pgid=,state="], text=True)
    members: list[int] = []
    for line in output.splitlines():
        fields = line.split()
        if (
            len(fields) != 3
            or int(fields[1]) != group
            or int(fields[0]) == os.getpid()
            or fields[2].startswith("Z")
        ):
            continue
        pid = int(fields[0])
        try:
            if os.getpgid(pid) == group:
                members.append(pid)
        except ProcessLookupError:
            pass
    return members


def signal_owned(group: int, signum: int) -> None:
    for pid in group_members(group):
        try:
            if os.getpgid(pid) == group:
                os.kill(pid, signum)
        except ProcessLookupError:
            pass


def describe(pids: list[int]) -> str:
    if not pids:
        return ""
    try:
        return subprocess.check_output(
            ["ps", "-ww", "-o", "pid=,ppid=,pgid=,state=,command=", "-p", ",".join(map(str, pids))],
            text=True,
        ).strip()
    except subprocess.SubprocessError:
        return ",".join(str(pid) for pid in pids)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: run-one.py <command> [arguments...]", file=sys.stderr)
        return 2
    os.setsid()
    group = os.getpgrp()
    child = subprocess.Popen(sys.argv[1:])

    def forward(signum: int, _frame: object) -> None:
        signal_owned(group, signum)

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, forward)
    status = child.wait()
    remaining = group_members(group)
    if remaining:
        leaked = describe(remaining)
        signal_owned(group, signal.SIGTERM)
        deadline = time.monotonic() + 3
        while group_members(group) and time.monotonic() < deadline:
            time.sleep(0.05)
        signal_owned(group, signal.SIGKILL)
        if status == 0:
            print(
                "test isolation violation: reaped processes left in the owned test group:\n"
                + leaked,
                file=sys.stderr,
            )
            return 97
    return status


if __name__ == "__main__":
    raise SystemExit(main())
