#!/usr/bin/env python3
import hashlib
import os
import stat
import sys
import time


def fail(message):
    print(f"error: continuation prompt launch failed: {message}", file=sys.stderr)
    raise SystemExit(1)


cleanup_only = len(sys.argv) == 5 and sys.argv[1] == "--cleanup"
wait_successor = len(sys.argv) == 7 and sys.argv[6] == "--wait-successor"
if (cleanup_only and len(sys.argv) != 5) or (not cleanup_only and len(sys.argv) != 6 and not wait_successor):
    fail("expected a prompt file, parent identity, file identity, content identity, and launch command")

prompt_path = os.path.abspath(sys.argv[2] if cleanup_only else sys.argv[1])
parent_path, name = os.path.split(prompt_path)
if not name or name in (".", ".."):
    fail("invalid prompt path")

expected_parent = sys.argv[3] if cleanup_only else sys.argv[2]
expected_file = sys.argv[4] if cleanup_only else sys.argv[3]
expected_content = None if cleanup_only else sys.argv[4]
parent = os.open(parent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
descriptor = None
snapshot = None
try:
    parent_stat = os.fstat(parent)
    if f"{parent_stat.st_dev}:{parent_stat.st_ino}" != expected_parent:
        fail("prompt parent generation changed")
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or f"{before.st_dev}:{before.st_ino}" != expected_file:
        fail("prompt source generation changed")
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        fail("prompt source changed while opening")
    if not cleanup_only:
        digest = hashlib.sha256()
        chunks = []
        offset = 0
        while offset < opened.st_size:
            chunk = os.pread(descriptor, min(65536, opened.st_size - offset), offset)
            if not chunk:
                fail("prompt source ended while verifying content")
            digest.update(chunk)
            chunks.append(chunk)
            offset += len(chunk)
        snapshot = b"".join(chunks)
    finished = os.fstat(descriptor)
    if (finished.st_dev, finished.st_ino, finished.st_size, finished.st_mtime_ns, finished.st_ctime_ns) != (
        opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns
    ) or (not cleanup_only and digest.hexdigest() != expected_content):
        fail("prompt source content changed")
    if not cleanup_only:
        if b"\0" in snapshot:
            fail("provider-native initial prompt cannot contain NUL bytes")
        try:
            snapshot.decode("utf-8")
        except UnicodeDecodeError:
            fail("provider-native initial prompt must be valid UTF-8")
    ready = os.environ.get("FM_PROMPT_EXEC_TEST_READY")
    proceed = os.environ.get("FM_PROMPT_EXEC_TEST_PROCEED")
    if not cleanup_only and ready and proceed:
        marker = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(marker)
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                fail("prompt launch test gate timed out")
            time.sleep(0.01)
    if wait_successor:
        deadline = time.monotonic() + 30
        while True:
            try:
                successor_fd = os.open("successor", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                break
            except FileNotFoundError:
                if time.monotonic() >= deadline:
                    fail("successor endpoint verification timed out; rerun continuation")
                time.sleep(0.05)
        with os.fdopen(successor_fd) as receipt:
            if not stat.S_ISREG(os.fstat(receipt.fileno()).st_mode):
                fail("successor receipt is not a regular file")
            successor = receipt.read(4096).strip()
        if not successor or "\n" in successor:
            fail("invalid successor endpoint")
        os.environ["FM_HANDOFF_SUCCESSOR_BACKEND"] = "herdr"
        os.environ["FM_HANDOFF_SUCCESSOR_TARGET"] = successor
        os.unlink("successor", dir_fd=parent)
    else:
        os.environ.pop("FM_HANDOFF_SUCCESSOR_BACKEND", None)
        os.environ.pop("FM_HANDOFF_SUCCESSOR_TARGET", None)
    os.unlink(name, dir_fd=parent)
finally:
    if descriptor is not None:
        os.close(descriptor)
    os.close(parent)

grandparent_path, parent_name = os.path.split(parent_path)
grandparent = os.open(grandparent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    current_parent = os.stat(parent_name, dir_fd=grandparent, follow_symlinks=False)
    if f"{current_parent.st_dev}:{current_parent.st_ino}" == expected_parent:
        try:
            os.rmdir(parent_name, dir_fd=grandparent)
        except OSError:
            pass
finally:
    os.close(grandparent)

if cleanup_only:
    raise SystemExit(0)

command = os.fsencode(sys.argv[5])
if snapshot is None:
    fail("prompt snapshot is unavailable")

os.execve(
    b"/bin/bash",
    [b"bash", b"-c", command + b' "$1"', b"fm-continuation", snapshot],
    os.environb.copy(),
)
