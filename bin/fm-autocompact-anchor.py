#!/usr/bin/env python3
import argparse
import fcntl
import os
from pathlib import Path
import tempfile
import time
from typing import Optional


def locked(lock_path: Path):
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(lock_path, flags, 0o600)
    deadline = time.monotonic() + 1
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return descriptor
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(descriptor)
                raise TimeoutError
            time.sleep(0.01)


def publish(args: argparse.Namespace) -> int:
    descriptor = locked(args.lock)
    try:
        os.replace(args.candidate, args.anchor)
    finally:
        os.close(descriptor)
    return 0


def update(args: argparse.Namespace) -> int:
    descriptor = locked(args.lock)
    temporary: Optional[str] = None
    try:
        lines = args.anchor.read_text().splitlines(keepends=True)
        capture_line = f"Capture ID: `{args.capture_id}`\n"
        if len(lines) < 5 or lines[4] != capture_line:
            return 3
        if lines[0].startswith("Judgment capture:"):
            status_index = 0
        elif lines[2].startswith("Judgment capture:"):
            status_index = 2
        else:
            return 3
        lines[status_index] = f"{args.status}\n"
        with tempfile.NamedTemporaryFile(
            mode="w", dir=args.anchor.parent, prefix=".autocompact-resume.md.", delete=False
        ) as output:
            temporary = output.name
            output.writelines(lines)
        os.chmod(temporary, 0o600)
        os.replace(temporary, args.anchor)
        temporary = None
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)
        os.close(descriptor)
    return 0


def alarm(args: argparse.Namespace) -> int:
    descriptor = locked(args.lock)
    temporary: Optional[str] = None
    try:
        lines = args.anchor.read_text().splitlines(keepends=True)
        if lines and lines[0].startswith("Judgment capture:"):
            lines[0] = f"{args.status}\n"
        elif len(lines) > 2 and lines[2].startswith("Judgment capture:"):
            del lines[2]
            lines.insert(0, f"{args.status}\n\n")
        else:
            lines.insert(0, f"{args.status}\n\n")
        with tempfile.NamedTemporaryFile(
            mode="w", dir=args.anchor.parent, prefix=".autocompact-resume.md.", delete=False
        ) as output:
            temporary = output.name
            output.writelines(lines)
        os.chmod(temporary, 0o600)
        os.replace(temporary, args.anchor)
        temporary = None
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)
        os.close(descriptor)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True, type=Path)
    subparsers = parser.add_subparsers(dest="operation", required=True)

    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("--candidate", required=True, type=Path)
    publish_parser.add_argument("--anchor", required=True, type=Path)
    publish_parser.set_defaults(handler=publish)

    update_parser = subparsers.add_parser("update")
    update_parser.add_argument("--anchor", required=True, type=Path)
    update_parser.add_argument("--capture-id", required=True)
    update_parser.add_argument("--status", required=True)
    update_parser.set_defaults(handler=update)

    alarm_parser = subparsers.add_parser("alarm")
    alarm_parser.add_argument("--anchor", required=True, type=Path)
    alarm_parser.add_argument("--status", required=True)
    alarm_parser.set_defaults(handler=alarm)

    args = parser.parse_args()
    try:
        return args.handler(args)
    except (OSError, TimeoutError):
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
