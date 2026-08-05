#!/usr/bin/env python3

import errno
import base64
import ctypes
import hashlib
import json
import os
import re
import selectors
import secrets
import signal
import stat
import subprocess
import sys
import time


COMMAND_CLEANUP_RESERVE_SECONDS = 0.5
COMMAND_TERM_GRACE_SECONDS = 0.1


def fail(message):
    raise RuntimeError(message)


_completed_test_fifo_handshakes = set()


def test_fifo_handshake(ready_name, proceed_name, payload, label):
    ready_path = os.environ.get(ready_name)
    proceed_path = os.environ.get(proceed_name)
    if not ready_path and not proceed_path:
        return
    if not ready_path or not proceed_path:
        fail(f"{label} requires both FIFO endpoints")
    handshake = (ready_name, proceed_name)
    if handshake in _completed_test_fifo_handshakes:
        return
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    for path, endpoint in ((ready_path, "ready"), (proceed_path, "proceed")):
        observed = os.stat(path, follow_symlinks=False)
        if not stat.S_ISFIFO(observed.st_mode):
            fail(f"{label} {endpoint} endpoint must be a real FIFO")
    ready = os.open(ready_path, os.O_WRONLY | os.O_NONBLOCK | nofollow)
    proceed = os.open(proceed_path, os.O_RDONLY | os.O_NONBLOCK | nofollow)
    selector = selectors.DefaultSelector()
    try:
        os.write(ready, payload.encode("utf-8"))
        selector.register(proceed, selectors.EVENT_READ)
        deadline = time.monotonic() + 10
        permit = b""
        while b"\n" not in permit:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(timeout=remaining):
                fail(f"{label} timed out")
            chunk = os.read(proceed, 256)
            if not chunk:
                fail(f"{label} closed without a permit")
            permit += chunk
            if len(permit) > 256:
                fail(f"{label} permit is oversized")
        line, trailing = permit.split(b"\n", 1)
        if line != b"continue" or trailing:
            fail(f"{label} received an invalid permit")
        _completed_test_fifo_handshakes.add(handshake)
    finally:
        selector.close()
        os.close(ready)
        os.close(proceed)


def checked_root(descriptor):
    opened = os.fstat(descriptor)
    if not stat.S_ISDIR(opened.st_mode):
        fail("root descriptor is not a directory")
    return descriptor


def components(relative):
    if not relative or os.path.isabs(relative):
        fail("source is not a relative descendant")
    parts = relative.split(os.sep)
    if any(part in ("", ".", "..") for part in parts):
        fail("source has an unsafe relative path")
    return parts


def open_relative(root_descriptor, relative, flags):
    parts = components(relative)
    parent = os.dup(root_descriptor)
    try:
        for part in parts[:-1]:
            child = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent,
            )
            os.close(parent)
            parent = child
        before = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            fail(f"source is a symlink: {relative}")
        if flags & os.O_DIRECTORY:
            if not stat.S_ISDIR(before.st_mode):
                fail(f"source is not a real directory: {relative}")
        elif not stat.S_ISREG(before.st_mode):
            fail(f"source is not a real regular file: {relative}")
        descriptor = os.open(parts[-1], flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        opened = os.fstat(descriptor)
        if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
            os.close(descriptor)
            fail("source identity changed while opening")
        return descriptor
    finally:
        os.close(parent)


def same_file(first, second):
    return (
        first.st_dev == second.st_dev
        and first.st_ino == second.st_ino
        and first.st_size == second.st_size
        and first.st_mtime_ns == second.st_mtime_ns
        and first.st_ctime_ns == second.st_ctime_ns
    )


class FingerprintBudget:
    def __init__(self, maximum_files, maximum_bytes, maximum_seconds=None, maximum_output_bytes=None):
        self.maximum_files = maximum_files
        self.maximum_bytes = maximum_bytes
        self.maximum_output_bytes = maximum_output_bytes if maximum_output_bytes is not None else maximum_bytes
        self.deadline = time.monotonic() + maximum_seconds if maximum_seconds is not None else None
        self.files = 0
        self.bytes = 0
        self.paths = 0
        self.output_bytes = 0

    def check_time(self, reserve_seconds=0):
        if self.deadline is not None and time.monotonic() + reserve_seconds > self.deadline:
            fail("repository fingerprint exceeds its time limit")

    def bounded_deadline(self, maximum_seconds):
        deadline = time.monotonic() + maximum_seconds
        if self.deadline is not None:
            deadline = min(deadline, self.deadline)
        return deadline

    def consume(self, size=0):
        self.check_time()
        self.files += 1
        if self.files > self.maximum_files:
            fail("repository fingerprint exceeds its file-count limit")
        self.consume_bytes(size)

    def consume_bytes(self, size):
        self.check_time()
        self.bytes += size
        if self.bytes > self.maximum_bytes:
            fail("repository fingerprint exceeds its byte limit")

    def consume_path(self):
        self.check_time()
        self.paths += 1
        if self.paths > self.maximum_files:
            fail("repository enumeration exceeds its path-count limit")

    def consume_output(self, size):
        self.check_time()
        self.output_bytes += size
        if self.output_bytes > self.maximum_output_bytes:
            fail("repository enumeration or identity output exceeds its byte limit")


def write_identity(output, value, budget):
    budget.consume_output(len(value))
    output.write(value)


def write_fingerprint(output, relative, kind, mode, digest, budget):
    write_identity(output, relative.encode("utf-8", "surrogateescape"), budget)
    write_identity(output, f"\0{kind}:{mode:o}:{digest}\0".encode("ascii"), budget)


def fingerprint_descriptor(descriptor, relative, output, budget):
    opened = os.fstat(descriptor)
    if stat.S_ISREG(opened.st_mode):
        budget.consume(opened.st_size)
        digest = hashlib.sha256()
        offset = 0
        while offset < opened.st_size:
            chunk = os.pread(descriptor, min(64 * 1024, opened.st_size - offset), offset)
            if not chunk:
                fail(f"repository file ended while fingerprinting: {relative}")
            budget.check_time()
            digest.update(chunk)
            offset += len(chunk)
        if not same_file(opened, os.fstat(descriptor)):
            fail(f"repository file changed while fingerprinting: {relative}")
        write_fingerprint(output, relative, "file", opened.st_mode, digest.hexdigest(), budget)
        return
    if not stat.S_ISDIR(opened.st_mode):
        budget.consume(0)
        write_fingerprint(output, relative, "special", opened.st_mode, "special", budget)
        return
    budget.consume(0)
    write_fingerprint(output, relative, "directory", opened.st_mode, "directory", budget)
    for name in sorted(os.listdir(descriptor)):
        child_relative = f"{relative}/{name}" if relative else name
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            target = os.readlink(name, dir_fd=descriptor).encode("utf-8", "surrogateescape")
            after = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not same_file(before, after):
                fail(f"repository symlink changed while fingerprinting: {child_relative}")
            budget.consume(len(target))
            write_fingerprint(
                output,
                child_relative,
                "symlink",
                before.st_mode,
                hashlib.sha256(target).hexdigest(),
                budget,
            )
            continue
        flags = os.O_RDONLY | (os.O_DIRECTORY if stat.S_ISDIR(before.st_mode) else 0)
        child = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
        try:
            actual = os.fstat(child)
            if actual.st_dev != before.st_dev or actual.st_ino != before.st_ino:
                fail(f"repository path changed while fingerprinting: {child_relative}")
            fingerprint_descriptor(child, child_relative, output, budget)
        finally:
            os.close(child)


def nul_records(value, budget):
    start = 0
    while start < len(value):
        budget.check_time()
        end = value.find(b"\0", start)
        if end < 0:
            fail("repository enumeration is not NUL terminated")
        record = value[start:end]
        start = end + 1
        if record:
            budget.consume_path()
            yield record


def bounded_path_file(path, budget):
    opened = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(opened.st_mode):
        fail("repository path inventory is not a regular file")
    if opened.st_size > budget.maximum_output_bytes:
        fail("repository path inventory exceeds its byte limit")
    with open(path, "rb") as source:
        value = source.read(budget.maximum_output_bytes + 1)
    budget.check_time()
    if len(value) > budget.maximum_output_bytes:
        fail("repository path inventory exceeds its byte limit")
    return value


def fingerprint_paths_records(root, paths, budget, output):
    ready = os.environ.get("FM_FINGERPRINT_PATHS_TEST_READY")
    proceed = os.environ.get("FM_FINGERPRINT_PATHS_TEST_PROCEED")
    if ready and proceed:
        with open(ready, "x", encoding="utf-8") as marker:
            marker.write("ready\n")
        while not os.path.exists(proceed):
            time.sleep(0.01)
        budget.check_time()
    for raw in paths:
        if not raw:
            continue
        relative = raw.decode("utf-8", "surrogateescape")
        try:
            parts = components(relative)
            parent = os.dup(root)
            try:
                for part in parts[:-1]:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                    os.close(parent)
                    parent = child
                before = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                if stat.S_ISLNK(before.st_mode):
                    target = os.readlink(parts[-1], dir_fd=parent).encode("utf-8", "surrogateescape")
                    after = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                    if not same_file(before, after):
                        fail(f"repository symlink changed while fingerprinting: {relative}")
                    budget.consume(len(target))
                    write_fingerprint(
                        output,
                        relative,
                        "symlink",
                        before.st_mode,
                        hashlib.sha256(target).hexdigest(),
                        budget,
                    )
                else:
                    flags = os.O_RDONLY | (os.O_DIRECTORY if stat.S_ISDIR(before.st_mode) else 0)
                    item = os.open(parts[-1], flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                    try:
                        actual = os.fstat(item)
                        if actual.st_dev != before.st_dev or actual.st_ino != before.st_ino:
                            fail(f"repository path changed while fingerprinting: {relative}")
                        fingerprint_descriptor(item, relative, output, budget)
                    finally:
                        os.close(item)
            finally:
                os.close(parent)
        except FileNotFoundError:
            write_fingerprint(output, relative, "missing", 0, "missing", budget)


def fingerprint_paths(root, paths_file, budget, output):
    value = bounded_path_file(paths_file, budget)
    fingerprint_paths_records(root, nul_records(value, budget), budget, output)


def command_fingerprint_paths_fd(arguments):
    if len(arguments) not in (1, 3, 4):
        fail("usage: fm-contained-read.py fingerprint-paths-fd <paths-file> [max-files max-bytes [max-seconds]]")
    root = checked_root(3)
    maximum_files = int(arguments[1]) if len(arguments) >= 3 else 100000
    maximum_bytes = int(arguments[2]) if len(arguments) >= 3 else 1073741824
    maximum_seconds = int(arguments[3]) if len(arguments) == 4 else None
    if maximum_files <= 0 or maximum_bytes <= 0 or (maximum_seconds is not None and maximum_seconds <= 0):
        fail("repository fingerprint limits must be positive")
    budget = FingerprintBudget(maximum_files, maximum_bytes, maximum_seconds)
    fingerprint_paths(root, arguments[0], budget, sys.stdout.buffer)


def bounded_command_output(command, budget):
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    selector = selectors.DefaultSelector()
    output = []
    try:
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        while True:
            budget.check_time(COMMAND_CLEANUP_RESERVE_SECONDS)
            for key, _ in selector.select(timeout=0.1):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if chunk:
                    budget.consume_output(len(chunk))
                    output.append(chunk)
                else:
                    selector.unregister(key.fileobj)
            if process.poll() is not None and not selector.get_map():
                break
        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, command)
        return b"".join(output)
    except BaseException as error:
        cleanup_deadline = budget.bounded_deadline(COMMAND_CLEANUP_RESERVE_SECONDS)
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except OSError:
            try:
                process.terminate()
            except OSError:
                pass
        term_deadline = min(
            cleanup_deadline,
            time.monotonic() + COMMAND_TERM_GRACE_SECONDS,
        )
        while time.monotonic() < term_deadline:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            except PermissionError:
                if process.poll() is not None:
                    break
            time.sleep(min(0.01, max(0, term_deadline - time.monotonic())))
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            try:
                process.kill()
            except OSError:
                pass
        if not bounded_process_wait(process, max(0, cleanup_deadline - time.monotonic())):
            try:
                process.kill()
            except OSError:
                pass
            if not bounded_process_wait(process, max(0, cleanup_deadline - time.monotonic())):
                raise RuntimeError(
                    "repository command cleanup timed out before the child could be reaped"
                ) from error
        raise
    finally:
        selector.close()
        process.stdout.close()


def bounded_process_wait(process, timeout):
    try:
        process.wait(timeout=timeout)
        return True
    except subprocess.TimeoutExpired:
        return False


def fingerprint_submodule_records(root, paths, budget, output):
    for raw in paths:
        relative = raw.decode("utf-8", "surrogateescape")
        descriptor = open_relative(root, relative, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fchdir(descriptor)
            command_output = []
            try:
                for command in (
                    ["git", "rev-parse", "HEAD"],
                    ["git", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                    ["git", "diff", "--no-ext-diff", "--binary", "--submodule=diff", "HEAD", "--"],
                ):
                    budget.consume()
                    command_output.append(bounded_command_output(command, budget))
                budget.consume()
                untracked = bounded_command_output(
                    ["git", "ls-files", "--others", "--exclude-standard", "-z"],
                    budget,
                ).split(b"\0")
            except subprocess.CalledProcessError:
                write_identity(output, b"submodule\0" + raw + b"\0unavailable\0", budget)
                continue
        finally:
            os.fchdir(root)
            os.close(descriptor)
        prefix = f"{relative}/"
        for item in untracked:
            if not item:
                continue
            item_relative = prefix + item.decode("utf-8", "surrogateescape")
            parts = components(item_relative)
            parent = os.dup(root)
            try:
                for part in parts[:-1]:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                    os.close(parent)
                    parent = child
                before = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                if stat.S_ISLNK(before.st_mode):
                    target = os.readlink(parts[-1], dir_fd=parent).encode("utf-8", "surrogateescape")
                    after = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                    if not same_file(before, after):
                        fail(f"repository symlink changed while fingerprinting: {item_relative}")
                    budget.consume(len(target))
                    write_fingerprint(
                        output,
                        item_relative,
                        "symlink",
                        before.st_mode,
                        hashlib.sha256(target).hexdigest(),
                        budget,
                    )
                else:
                    flags = os.O_RDONLY | (os.O_DIRECTORY if stat.S_ISDIR(before.st_mode) else 0)
                    item_descriptor = os.open(
                        parts[-1], flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent
                    )
                    try:
                        opened = os.fstat(item_descriptor)
                        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                            fail(f"repository path changed while fingerprinting: {item_relative}")
                        fingerprint_descriptor(item_descriptor, item_relative, output, budget)
                    finally:
                        os.close(item_descriptor)
            finally:
                os.close(parent)
        write_identity(output, b"submodule\0" + raw + b"\0", budget)
        for value in command_output:
            write_identity(output, value + b"\0", budget)


def fingerprint_submodules(root, paths_file, budget, output):
    value = bounded_path_file(paths_file, budget)
    fingerprint_submodule_records(root, nul_records(value, budget), budget, output)


def command_fingerprint_submodules_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py fingerprint-submodules-fd <paths-file> <max-files> <max-bytes> <max-seconds>")
    root = checked_root(3)
    maximum_files = int(arguments[1])
    maximum_bytes = int(arguments[2])
    maximum_seconds = int(arguments[3])
    if maximum_files <= 0 or maximum_bytes <= 0 or maximum_seconds <= 0:
        fail("repository fingerprint limits must be positive")
    budget = FingerprintBudget(maximum_files, maximum_bytes, maximum_seconds)
    fingerprint_submodules(root, arguments[0], budget, sys.stdout.buffer)


def command_fingerprint_repository_fd(arguments):
    if len(arguments) != 6:
        fail(
            "usage: fm-contained-read.py fingerprint-repository-fd "
            "<tracked-paths> <submodule-paths> <untracked-paths> <max-files> <max-bytes> <max-seconds>"
        )
    root = checked_root(3)
    maximum_files = int(arguments[3])
    maximum_bytes = int(arguments[4])
    maximum_seconds = int(arguments[5])
    if maximum_files <= 0 or maximum_bytes <= 0 or maximum_seconds <= 0:
        fail("repository fingerprint limits must be positive")
    budget = FingerprintBudget(maximum_files, maximum_bytes, maximum_seconds)
    output = sys.stdout.buffer
    write_identity(output, b"worktree-content\0", budget)
    fingerprint_paths(root, arguments[0], budget, output)
    write_identity(output, b"\0submodule-content\0", budget)
    fingerprint_submodules(root, arguments[1], budget, output)
    write_identity(output, b"\0untracked-content\0", budget)
    fingerprint_paths(root, arguments[2], budget, output)


def command_repository_identity_fd(arguments):
    if len(arguments) != 4:
        fail(
            "usage: fm-contained-read.py repository-identity-fd "
            "<max-files> <max-content-bytes> <max-output-bytes> <max-seconds>"
        )
    maximum_files, maximum_bytes, maximum_output_bytes, maximum_seconds = map(int, arguments)
    if min(maximum_files, maximum_bytes, maximum_output_bytes, maximum_seconds) <= 0:
        fail("repository identity limits must be positive")
    root = checked_root(3)
    budget = FingerprintBudget(
        maximum_files,
        maximum_bytes,
        maximum_seconds,
        maximum_output_bytes,
    )
    os.fchdir(root)
    try:
        status_output = bounded_command_output(
            ["git", "status", "--porcelain=v2", "--branch", "-z"],
            budget,
        )
        index_output = bounded_command_output(["git", "ls-files", "--stage", "-z"], budget)
        untracked_output = bounded_command_output(
            ["git", "ls-files", "--others", "--exclude-standard", "-z"],
            budget,
        )
    except subprocess.CalledProcessError as error:
        fail(f"repository enumeration command failed with status {error.returncode}")

    ready = os.environ.get("FM_REPOSITORY_IDENTITY_PARSE_TEST_READY")
    proceed = os.environ.get("FM_REPOSITORY_IDENTITY_PARSE_TEST_PROCEED")
    if ready and proceed:
        with open(ready, "x", encoding="utf-8") as marker:
            marker.write("ready\n")
        while not os.path.exists(proceed):
            budget.check_time()
            time.sleep(0.01)

    tracked = []
    submodules = []
    for record in nul_records(index_output, budget):
        if b"\t" not in record:
            fail("repository index enumeration is malformed")
        metadata, relative = record.split(b"\t", 1)
        mode = metadata.split(b" ", 1)[0]
        if not relative:
            fail("repository index enumeration contains an empty path")
        (submodules if mode == b"160000" else tracked).append(relative)
    untracked = list(nul_records(untracked_output, budget))

    output = sys.stdout.buffer
    write_identity(output, b"status\0", budget)
    write_identity(output, status_output, budget)
    write_identity(output, b"\0index\0", budget)
    write_identity(output, index_output, budget)
    write_identity(output, b"\0worktree-content\0", budget)
    fingerprint_paths_records(root, tracked, budget, output)
    write_identity(output, b"\0submodule-content\0", budget)
    fingerprint_submodule_records(root, submodules, budget, output)
    write_identity(output, b"\0untracked-content\0", budget)
    fingerprint_paths_records(root, untracked, budget, output)


def command_git_fd(arguments):
    if not arguments:
        fail("usage: fm-contained-read.py git-fd <git-arguments>...")
    root = checked_root(3)
    os.fchdir(root)
    os.execvp("git", ["git", *arguments])


def command_cat_fd(arguments):
    if len(arguments) != 2:
        fail("usage: fm-contained-read.py cat-fd <relative> <maximum-bytes>")
    relative, maximum_raw = arguments
    maximum = int(maximum_raw)
    if maximum < 0:
        fail("invalid contained read limit")
    root = checked_root(3)
    item = read_relative(root, relative, maximum, "strict")
    if item["oversized"]:
        fail(f"source exceeds {maximum} bytes: {relative}")
    sys.stdout.buffer.write(item["content"])


def command_cat_child_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py cat-child-fd <directory> <file> <maximum-bytes>")
    directory_name, file_name, maximum_raw = arguments
    if len(components(directory_name)) != 1 or len(components(file_name)) != 1:
        fail("contained child names must be single safe components")
    maximum = int(maximum_raw)
    if maximum < 0:
        fail("invalid contained read limit")
    root = checked_root(3)
    directory = open_relative(root, directory_name, os.O_RDONLY | os.O_DIRECTORY)
    try:
        ready = os.environ.get("FM_REPORT_ENTRY_TEST_READY")
        proceed = os.environ.get("FM_REPORT_ENTRY_TEST_PROCEED")
        if ready and proceed:
            descriptor = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
            os.close(descriptor)
            deadline = time.monotonic() + 5
            while not os.path.exists(proceed):
                if time.monotonic() >= deadline:
                    fail("report entry test gate timed out")
                time.sleep(0.01)
        item = read_relative(directory, file_name, maximum, "strict")
    finally:
        os.close(directory)
    if item["oversized"]:
        fail(f"source exceeds {maximum} bytes: {directory_name}/{file_name}")
    sys.stdout.buffer.write(item["content"])


def read_descriptor(descriptor, maximum, mode):
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode):
        fail("source is not a real regular file")
    if mode == "strict" and opened.st_size > maximum:
        return {"oversized": True, "size": opened.st_size, "content": b""}
    length = min(opened.st_size, maximum)
    offset = opened.st_size - length if mode == "tail" else 0
    chunks = []
    remaining = length
    while remaining:
        chunk = os.pread(descriptor, remaining, offset)
        if not chunk:
            fail("source ended before its recorded size")
        chunks.append(chunk)
        offset += len(chunk)
        remaining -= len(chunk)
    finished = os.fstat(descriptor)
    if not same_file(opened, finished):
        fail("source changed while reading")
    return {
        "oversized": opened.st_size > maximum,
        "size": opened.st_size,
        "content": b"".join(chunks),
    }


def read_relative(root_descriptor, relative, maximum, mode, optional=False):
    try:
        descriptor = open_relative(root_descriptor, relative, os.O_RDONLY)
    except FileNotFoundError:
        if optional:
            return None
        raise
    try:
        return read_descriptor(descriptor, maximum, mode)
    finally:
        os.close(descriptor)


def write_framed(items):
    header = []
    for name, item in items:
        if item is None:
            header.append({"name": name, "missing": True})
        else:
            header.append(
                {
                    "name": name,
                    "missing": False,
                    "oversized": item["oversized"],
                    "size": item["size"],
                    "bytes": len(item["content"]),
                }
            )
    output = sys.stdout.buffer
    output.write(json.dumps({"items": header}, separators=(",", ":")).encode("utf-8"))
    output.write(b"\n")
    for _, item in items:
        if item is not None:
            output.write(item["content"])


def open_verified_directory(parent_descriptor, name):
    before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if stat.S_ISLNK(before.st_mode) and name == "visuals":
        fail("visual evidence root must be a real directory")
    if not stat.S_ISDIR(before.st_mode):
        fail(f"visual evidence must contain only real directories at {name}")
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=parent_descriptor,
    )
    opened = os.fstat(descriptor)
    if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
        os.close(descriptor)
        fail(f"visual evidence changed while opening {name}")
    return descriptor


def ensure_destination_directory(parent_descriptor, name):
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent_descriptor)
    except FileExistsError:
        pass
    return os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=parent_descriptor,
    )


def copy_regular(source_parent, destination_parent, name, remaining):
    before = os.stat(name, dir_fd=source_parent, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode):
        return 0
    source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_parent)
    destination = None
    try:
        opened = os.fstat(source)
        if not stat.S_ISREG(opened.st_mode) or opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
            fail(f"visual evidence changed while opening {name}")
        if opened.st_size > remaining:
            fail("visual evidence exceeds the 20 MiB report limit")
        destination = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=destination_parent,
        )
        copied = 0
        while copied < opened.st_size:
            chunk = os.read(source, min(64 * 1024, opened.st_size - copied))
            if not chunk:
                fail(f"visual evidence changed size while copying {name}")
            view = memoryview(chunk)
            while view:
                written = os.write(destination, view)
                view = view[written:]
            copied += len(chunk)
        if os.read(source, 1):
            fail(f"visual evidence changed size while copying {name}")
        if not same_file(opened, os.fstat(source)):
            fail(f"visual evidence changed while copying {name}")
        return copied
    finally:
        if destination is not None:
            os.close(destination)
        os.close(source)


def command_cat_optional_fd(arguments):
    if len(arguments) != 2:
        fail("usage: fm-contained-read.py cat-optional-fd <relative> <maximum-bytes>")
    relative, maximum_raw = arguments
    maximum = int(maximum_raw)
    if maximum < 0:
        fail("invalid contained read limit")
    parts = components(relative)
    parent = os.dup(checked_root(3))
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        try:
            item = read_relative(parent, parts[-1], maximum, "strict")
        except FileNotFoundError:
            raise SystemExit(3)
        if item["oversized"]:
            fail(f"source exceeds {maximum} bytes: {relative}")
        sys.stdout.buffer.write(item["content"])
    finally:
        os.close(parent)


def snapshot_artifact(source_parent, destination_parent, source_name, destination_name, view_limit, mode, copy_limit=None, optional=False):
    try:
        source = open_relative(source_parent, source_name, os.O_RDONLY)
    except FileNotFoundError:
        if optional:
            return None
        raise
    destination = None
    try:
        opened = os.fstat(source)
        item = read_descriptor(source, view_limit, mode)
        if copy_limit is not None and opened.st_size > copy_limit:
            return item
        destination = os.open(
            destination_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=destination_parent,
        )
        os.lseek(source, 0, os.SEEK_SET)
        copied = 0
        while copied < opened.st_size:
            chunk = os.read(source, min(64 * 1024, opened.st_size - copied))
            if not chunk:
                fail(f"source ended before its recorded size: {source_name}")
            view = memoryview(chunk)
            while view:
                written = os.write(destination, view)
                view = view[written:]
            copied += len(chunk)
        if os.read(source, 1):
            fail(f"source changed size while copying: {source_name}")
        if not same_file(opened, os.fstat(source)):
            fail(f"source changed while copying: {source_name}")
        return item
    finally:
        if destination is not None:
            os.close(destination)
        os.close(source)


def write_artifact(destination, name, content):
    descriptor = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=destination,
    )
    try:
        view = memoryview(content)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
    finally:
        os.close(descriptor)


def copy_visuals(task_descriptor, destination_descriptor, maximum, entry_limit, depth_limit):
    try:
        source = open_verified_directory(task_descriptor, "visuals")
    except FileNotFoundError:
        return []
    destination = ensure_destination_directory(destination_descriptor, "visuals")
    copied_paths = []
    total = 0
    entries = 1

    def visit(source_directory, destination_directory, relative, depth):
        nonlocal entries, total
        if depth > depth_limit:
            fail(f"visual evidence exceeds the {depth_limit}-level depth limit")
        for name in sorted(os.listdir(source_directory)):
            entries += 1
            if entries > entry_limit:
                fail(f"visual evidence exceeds the {entry_limit}-entry limit")
            item = os.stat(name, dir_fd=source_directory, follow_symlinks=False)
            display = "/".join((*relative, name))
            if stat.S_ISLNK(item.st_mode):
                fail(f"visual evidence must not contain symlinks at {display}")
            if stat.S_ISDIR(item.st_mode):
                source_child = open_verified_directory(source_directory, name)
                destination_child = ensure_destination_directory(destination_directory, name)
                try:
                    visit(source_child, destination_child, (*relative, name), depth + 1)
                finally:
                    os.close(destination_child)
                    os.close(source_child)
            elif stat.S_ISREG(item.st_mode):
                total += copy_regular(source_directory, destination_directory, name, maximum - total)
                copied_paths.append(f"visuals/{display}")

    try:
        visit(source, destination, (), 0)
    finally:
        os.close(destination)
        os.close(source)
    return sorted(copied_paths)


def command_read_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py read-fd <relative> <maximum-bytes> <strict|head|tail>")
    relative, maximum_raw, mode = arguments
    maximum = int(maximum_raw)
    if maximum < 0 or mode not in ("strict", "head", "tail"):
        fail("invalid contained read arguments")
    root = checked_root(3)
    write_framed([("source", read_relative(root, relative, maximum, mode, optional=True))])


def command_snapshot_task_fd(arguments):
    if len(arguments) != 6:
        fail("usage: fm-contained-read.py snapshot-task-fd <task-id> <source-name> <brief-limit> <source-limit> <visual-limit> <entry-limit>:<depth-limit>")
    task_id, source_name, brief_raw, source_raw, visual_raw, inventory_raw = arguments
    task_parts = components(task_id)
    source_parts = components(source_name)
    if len(task_parts) != 1 or len(source_parts) != 1:
        fail("task and report source names must be single safe components")
    entry_raw, depth_raw = inventory_raw.split(":", 1)
    root = checked_root(3)
    destination = checked_root(4)
    task = open_relative(root, task_id, os.O_RDONLY | os.O_DIRECTORY)
    try:
        if not stat.S_ISDIR(os.fstat(task).st_mode):
            fail("task data source is not a real directory")
        brief = snapshot_artifact(task, destination, "brief.md", "brief.md", int(brief_raw), "head", optional=True)
        source = snapshot_artifact(task, destination, source_name, "report.md", int(source_raw), "strict", copy_limit=int(source_raw), optional=True)
        visuals = copy_visuals(task, destination, int(visual_raw), int(entry_raw), int(depth_raw))
        write_artifact(destination, ".visuals.json", json.dumps(visuals, separators=(",", ":")).encode("utf-8"))
        write_framed([("brief", brief), ("source", source)])
    finally:
        os.close(task)


def command_snapshot_file_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py snapshot-file-fd <relative> <view-limit> <head|tail> <destination-name>")
    relative, maximum_raw, mode, destination_name = arguments
    maximum = int(maximum_raw)
    if maximum < 0 or mode not in ("head", "tail") or len(components(destination_name)) != 1:
        fail("invalid contained snapshot arguments")
    root = checked_root(3)
    destination = checked_root(4)
    parent_name = os.path.dirname(relative)
    source_parent = open_relative(root, parent_name, os.O_RDONLY | os.O_DIRECTORY) if parent_name else os.dup(root)
    try:
        item = snapshot_artifact(source_parent, destination, os.path.basename(relative), destination_name, maximum, mode, optional=True)
    finally:
        os.close(source_parent)
    write_framed([("source", item)])


def command_snapshot_files_fd(arguments):
    if len(arguments) < 2:
        fail("usage: fm-contained-read.py snapshot-files-fd <maximum-bytes> <source>...")
    maximum = int(arguments[0])
    if maximum < 0:
        fail("invalid contained snapshot limit")
    root = checked_root(3)
    destination = checked_root(4)
    for index, relative in enumerate(arguments[1:]):
        if len(components(relative)) != 1:
            fail("snapshot sources must be single safe components")
        item = read_relative(root, relative, maximum, "strict", optional=True)
        if item is None:
            continue
        if item["oversized"]:
            fail(f"source exceeds {maximum} bytes: {relative}")
        name = f"{index}.snapshot"
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=destination,
        )
        try:
            content = item["content"]
            written = 0
            while written < len(content):
                written += os.write(descriptor, content[written:])
        finally:
            os.close(descriptor)


def remove_directory_contents(descriptor):
    for entry in os.scandir(descriptor):
        before = os.stat(entry.name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(before.st_mode):
            child = os.open(
                entry.name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
                    fail(f"directory changed while removing {entry.name}")
                remove_directory_contents(child)
                current = os.stat(entry.name, dir_fd=descriptor, follow_symlinks=False)
                if current.st_dev != opened.st_dev or current.st_ino != opened.st_ino:
                    fail(f"directory changed while removing {entry.name}")
                os.rmdir(entry.name, dir_fd=descriptor)
            finally:
                os.close(child)
        else:
            os.unlink(entry.name, dir_fd=descriptor)


def command_replace_file_fd(arguments):
    if len(arguments) != 2:
        fail("usage: fm-contained-read.py replace-file-fd <source-name> <destination-name>")
    source_name, destination_name = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("replacement names must be single safe components")
    source_root = checked_root(3)
    destination_root = checked_root(4)
    source = os.stat(source_name, dir_fd=source_root, follow_symlinks=False)
    if not stat.S_ISREG(source.st_mode):
        fail("replacement source is not a real regular file")
    try:
        destination = os.stat(destination_name, dir_fd=destination_root, follow_symlinks=False)
        if not stat.S_ISREG(destination.st_mode):
            fail("replacement destination is not a real regular file")
    except FileNotFoundError:
        pass
    os.rename(
        source_name,
        destination_name,
        src_dir_fd=source_root,
        dst_dir_fd=destination_root,
    )


def command_remove_owned_directory_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py remove-owned-directory-fd <directory-name> <control-name> <token>")
    directory_name, control_name, token = arguments
    if len(components(directory_name)) != 1 or len(components(control_name)) != 1:
        fail("owned directory names must be single safe components")
    root = checked_root(3)
    before = os.stat(directory_name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISDIR(before.st_mode):
        fail("owned path is not a real directory")
    directory = os.open(
        directory_name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=root,
    )
    try:
        opened = os.fstat(directory)
        if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
            fail("owned directory changed while opening")
        control = read_relative(directory, control_name, 4096, "strict")
        if control["oversized"]:
            fail("owned directory control file is too large")
        raw = control["content"].decode("utf-8").strip()
        try:
            owner_token = json.loads(raw).get("token", "")
        except json.JSONDecodeError:
            owner_token = raw.splitlines()[-1] if raw else ""
        if owner_token != token:
            fail("owned directory token changed")
        current = os.stat(directory_name, dir_fd=root, follow_symlinks=False)
        if current.st_dev != opened.st_dev or current.st_ino != opened.st_ino:
            fail("owned directory changed before removal")
        quarantine = f".{directory_name}.released.{os.getpid()}.{token}"
        os.rename(directory_name, quarantine, src_dir_fd=root, dst_dir_fd=root)
        quarantined = os.stat(quarantine, dir_fd=root, follow_symlinks=False)
        if quarantined.st_dev != opened.st_dev or quarantined.st_ino != opened.st_ino:
            fail("owned directory changed during removal")
        remove_directory_contents(directory)
        os.rmdir(quarantine, dir_fd=root)
    finally:
        os.close(directory)


def process_start_identity(pid):
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "lstart="],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={**os.environ, "LC_ALL": "C"},
            text=True,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    value = " ".join(result.stdout.split())
    return value or None


def owned_process_liveness(owner):
    try:
        os.kill(owner["pid"], 0)
    except ProcessLookupError:
        return "dead"
    except PermissionError:
        return "unknown"
    started_at = process_start_identity(owner["pid"])
    if not started_at:
        return "unknown"
    return "live" if started_at == owner["startedAt"] else "dead"


def process_is_absent(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def read_owned_directory_control(directory, control_name):
    control = read_relative(directory, control_name, 4096, "strict")
    if control["oversized"]:
        fail("owned directory control file is too large")
    try:
        owner = json.loads(control["content"].decode("utf-8").strip())
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("owned directory control file is invalid")
    if not isinstance(owner, dict) or not isinstance(owner.get("pid"), int) or owner["pid"] <= 0 \
            or not isinstance(owner.get("startedAt"), str) or not owner["startedAt"] \
            or not isinstance(owner.get("token"), str) or not owner["token"]:
        fail("owned directory control file has no verifiable process generation")
    return owner


def command_remove_dead_owned_directory_fd(arguments):
    if len(arguments) != 5:
        fail(
            "usage: fm-contained-read.py remove-dead-owned-directory-fd "
            "<directory-name> <control-name> <pid> <started-at> <token>"
        )
    directory_name, control_name, pid_text, started_at, token = arguments
    if len(components(directory_name)) != 1 or len(components(control_name)) != 1:
        fail("dead-owned directory names must be single safe components")
    if not pid_text.isdigit() or int(pid_text) <= 0 or not started_at \
            or not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", token):
        fail("dead-owned directory identity is invalid")
    candidate_name = f".publish.lock.candidate.{pid_text}.{token}"
    quarantine = f".publish.lock.candidate-orphan.{pid_text}.{token}"
    if directory_name not in (candidate_name, quarantine):
        fail("dead-owned directory name does not match its owner identity")
    expected_owner = {"pid": int(pid_text), "startedAt": started_at, "token": token}
    root = checked_root(3)
    before = os.stat(directory_name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISDIR(before.st_mode) or before.st_uid != os.getuid() \
            or stat.S_IMODE(before.st_mode) != 0o700:
        fail("dead-owned path is not a private current-user directory")
    directory = os.open(
        directory_name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=root,
    )
    renamed = False
    deleting = False
    try:
        opened = os.fstat(directory)
        if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
            fail("dead-owned directory changed while opening")
        owner = read_owned_directory_control(directory, control_name)
        if owner != expected_owner or owned_process_liveness(owner) != "dead":
            fail("dead-owned directory owner is not positively dead")
        test_fifo_handshake(
            "FM_CONTAINED_DEAD_OWNER_TEST_READY",
            "FM_CONTAINED_DEAD_OWNER_TEST_PROCEED",
            "dead-owner-observed\n",
            "dead-owned directory removal test gate",
        )
        current = os.stat(directory_name, dir_fd=root, follow_symlinks=False)
        owner = read_owned_directory_control(directory, control_name)
        if current.st_dev != opened.st_dev or current.st_ino != opened.st_ino \
                or owner != expected_owner or owned_process_liveness(owner) != "dead":
            fail("dead-owned directory changed before removal")
        if directory_name == candidate_name:
            rename_noreplace(root, root, directory_name, quarantine)
            renamed = True
        quarantined = os.stat(quarantine, dir_fd=root, follow_symlinks=False)
        owner = read_owned_directory_control(directory, control_name)
        if quarantined.st_dev != opened.st_dev or quarantined.st_ino != opened.st_ino \
                or owner != expected_owner or owned_process_liveness(owner) != "dead":
            fail("dead-owned directory changed during removal")
        deleting = True
        remove_directory_contents(directory)
        os.rmdir(quarantine, dir_fd=root)
    except BaseException:
        if renamed and not deleting:
            try:
                rename_noreplace(root, root, quarantine, directory_name)
            except OSError:
                pass
        raise
    finally:
        os.close(directory)


def incomplete_candidate_contents(directory):
    names = os.listdir(directory)
    if not names:
        return False
    if names != ["owner"]:
        fail("incomplete dead candidate contains unexpected entries")
    before = os.stat("owner", dir_fd=directory, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() \
            or stat.S_IMODE(before.st_mode) != 0o600 or before.st_nlink != 1 \
            or before.st_size > 4096:
        fail("incomplete candidate owner is not a private current-user file")
    owner_descriptor = os.open(
        "owner",
        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
        dir_fd=directory,
    )
    try:
        opened = os.fstat(owner_descriptor)
        content = os.read(owner_descriptor, 4097)
        if not same_file(before, opened) or not same_file(opened, os.fstat(owner_descriptor)) \
                or len(content) > 4096:
            fail("incomplete candidate owner changed while reading")
    finally:
        os.close(owner_descriptor)
    try:
        owner = json.loads(content.decode("utf-8").strip())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return True
    if isinstance(owner, dict) and isinstance(owner.get("pid"), int) and owner["pid"] > 0 \
            and isinstance(owner.get("startedAt"), str) and owner["startedAt"] \
            and isinstance(owner.get("token"), str) and owner["token"]:
        fail("incomplete candidate acquired a complete owner")
    return True


def command_remove_incomplete_dead_candidate_fd(arguments):
    if len(arguments) != 3:
        fail(
            "usage: fm-contained-read.py remove-incomplete-dead-candidate-fd "
            "<directory-name> <pid> <token>"
        )
    directory_name, pid_text, token = arguments
    if len(components(directory_name)) != 1 or not pid_text.isdigit() or int(pid_text) <= 0 \
            or not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", token):
        fail("incomplete dead candidate identity is invalid")
    candidate_name = f".publish.lock.candidate.{pid_text}.{token}"
    quarantine = f".publish.lock.candidate-orphan.{pid_text}.{token}"
    if directory_name not in (candidate_name, quarantine):
        fail("incomplete dead candidate name does not match its process identity")
    pid = int(pid_text)
    root = checked_root(3)
    before = os.stat(directory_name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISDIR(before.st_mode) or before.st_uid != os.getuid() \
            or stat.S_IMODE(before.st_mode) != 0o700:
        fail("incomplete dead candidate is not a private current-user directory")
    directory = os.open(
        directory_name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=root,
    )
    renamed = False
    try:
        opened = os.fstat(directory)
        if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino \
                or not process_is_absent(pid):
            fail("incomplete dead candidate is not positively abandoned")
        has_owner = incomplete_candidate_contents(directory)
        current = os.stat(directory_name, dir_fd=root, follow_symlinks=False)
        if current.st_dev != opened.st_dev or current.st_ino != opened.st_ino \
                or incomplete_candidate_contents(directory) != has_owner \
                or not process_is_absent(pid):
            fail("incomplete dead candidate changed before removal")
        if directory_name == candidate_name:
            rename_noreplace(root, root, directory_name, quarantine)
            renamed = True
        quarantined = os.stat(quarantine, dir_fd=root, follow_symlinks=False)
        if quarantined.st_dev != opened.st_dev or quarantined.st_ino != opened.st_ino \
                or incomplete_candidate_contents(directory) != has_owner \
                or not process_is_absent(pid):
            fail("incomplete dead candidate changed during removal")
        if has_owner:
            os.unlink("owner", dir_fd=directory)
        os.rmdir(quarantine, dir_fd=root)
    except BaseException:
        if renamed:
            try:
                rename_noreplace(root, root, quarantine, directory_name)
            except OSError:
                pass
        raise
    finally:
        os.close(directory)


def exchange_names(root, first, second):
    exchange_between(root, first, root, second)


def exchange_between(first_root, first, second_root, second):
    libc = ctypes.CDLL(None, use_errno=True)
    first_raw = os.fsencode(first)
    second_raw = os.fsencode(second)
    if sys.platform == "darwin":
        rename_exchange = libc.renameatx_np
        rename_exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename_exchange.restype = ctypes.c_int
        result = rename_exchange(first_root, first_raw, second_root, second_raw, 0x00000002)
    else:
        machine = os.uname().machine
        syscall_number = 316 if machine in ("x86_64", "amd64") else 276
        result = libc.syscall(syscall_number, first_root, first_raw, second_root, second_raw, 0x00000002)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def rename_noreplace(source_root, destination_root, source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    source_raw = os.fsencode(source)
    destination_raw = os.fsencode(destination)
    if sys.platform == "darwin":
        rename_exclusive = libc.renameatx_np
        rename_exclusive.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename_exclusive.restype = ctypes.c_int
        result = rename_exclusive(source_root, source_raw, destination_root, destination_raw, 0x00000004)
    else:
        machine = os.uname().machine
        syscall_number = 316 if machine in ("x86_64", "amd64") else 276
        result = libc.syscall(syscall_number, source_root, source_raw, destination_root, destination_raw, 0x00000001)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def command_exchange_files_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py exchange-files-fd <source> <destination> <source-id> <destination-id>")
    source_name, destination_name, source_id, destination_id = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("exchange names must be single safe components")
    root = checked_root(3)
    source = os.stat(source_name, dir_fd=root, follow_symlinks=False)
    destination = os.stat(destination_name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISREG(source.st_mode) or not stat.S_ISREG(destination.st_mode):
        fail("exchange operands must be real regular files")
    if f"{source.st_dev}:{source.st_ino}" != source_id or f"{destination.st_dev}:{destination.st_ino}" != destination_id:
        fail("exchange generation changed before publication")
    exchange_names(root, source_name, destination_name)
    moved_source = os.stat(destination_name, dir_fd=root, follow_symlinks=False)
    moved_destination = os.stat(source_name, dir_fd=root, follow_symlinks=False)
    if f"{moved_source.st_dev}:{moved_source.st_ino}" == source_id \
            and f"{moved_destination.st_dev}:{moved_destination.st_ino}" == destination_id:
        return
    exchange_names(root, source_name, destination_name)
    fail("exchange generation changed during publication")


def command_copy_file_fd(arguments):
    if len(arguments) not in (3, 4) or (len(arguments) == 4 and arguments[3] != "emit-base64"):
        fail("usage: fm-contained-read.py copy-file-fd <source> <destination> <source-id> [emit-base64]")
    source_name, destination_name, source_id = arguments[:3]
    emit_base64 = len(arguments) == 4
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("copy names must be single safe components")
    root = checked_root(3)
    ready = os.environ.get("FM_CONTAINED_COPY_TEST_READY")
    proceed = os.environ.get("FM_CONTAINED_COPY_TEST_PROCEED")
    if ready and proceed:
        with open(ready, "x", encoding="utf-8") as marker:
            marker.write(f"{source_name}\n")
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                fail("copy test gate timed out")
            time.sleep(0.01)
    source = open_relative(root, source_name, os.O_RDONLY)
    destination = None
    copied = []
    try:
        before = os.fstat(source)
        if not stat.S_ISREG(before.st_mode) or f"{before.st_dev}:{before.st_ino}" != source_id:
            fail("copy source generation changed")
        destination = os.open(
            destination_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=root,
        )
        offset = 0
        while offset < before.st_size:
            chunk = os.pread(source, min(1024 * 1024, before.st_size - offset), offset)
            if not chunk:
                fail("source ended before its recorded size")
            written = 0
            while written < len(chunk):
                written += os.write(destination, chunk[written:])
            if emit_base64:
                copied.append(chunk)
            offset += len(chunk)
        os.fsync(destination)
        after = os.fstat(source)
        if not same_file(before, after) or f"{after.st_dev}:{after.st_ino}" != source_id:
            fail("source changed while copying")
        if emit_base64:
            sys.stdout.buffer.write(base64.b64encode(b"".join(copied)))
    except Exception:
        if destination is not None:
            os.close(destination)
            destination = None
        try:
            os.unlink(destination_name, dir_fd=root)
        except FileNotFoundError:
            pass
        raise
    finally:
        if destination is not None:
            os.close(destination)
        os.close(source)


def command_rename_noreplace_owned_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py rename-noreplace-owned-fd <source> <destination> <source-id>")
    source_name, destination_name, source_id = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("rename names must be single safe components")
    source_root = checked_root(3)
    destination_root = checked_root(4)
    source = os.stat(source_name, dir_fd=source_root, follow_symlinks=False)
    if not stat.S_ISDIR(source.st_mode) or f"{source.st_dev}:{source.st_ino}" != source_id:
        fail("owned directory generation changed before rename")
    ready = os.environ.get("FM_CONTAINED_RENAME_TEST_READY")
    proceed = os.environ.get("FM_CONTAINED_RENAME_TEST_PROCEED")
    if ready and proceed:
        with open(ready, "x", encoding="utf-8") as marker:
            marker.write(f"{destination_name}\n")
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                fail("owned rename test gate timed out")
            time.sleep(0.01)
    rename_noreplace(source_root, destination_root, source_name, destination_name)
    moved = os.stat(destination_name, dir_fd=destination_root, follow_symlinks=False)
    if moved.st_dev != source.st_dev or moved.st_ino != source.st_ino:
        try:
            rename_noreplace(destination_root, source_root, destination_name, source_name)
            restored = os.stat(source_name, dir_fd=source_root, follow_symlinks=False)
            if restored.st_dev != moved.st_dev or restored.st_ino != moved.st_ino:
                fail("unowned directory generation could not be restored after rename")
        except OSError as error:
            fail(f"unowned directory generation remains quarantined after rename: {error}")
        fail("owned directory generation changed during rename and the moved replacement was restored")


def command_rename_noreplace_owned_entry_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py rename-noreplace-owned-entry-fd <source> <destination> <source-id>")
    source_name, destination_name, source_id = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("rename names must be single safe components")
    source_root = checked_root(3)
    destination_root = checked_root(4)
    source = os.stat(source_name, dir_fd=source_root, follow_symlinks=False)
    if stat.S_ISLNK(source.st_mode) or not (stat.S_ISDIR(source.st_mode) or stat.S_ISREG(source.st_mode)) \
            or f"{source.st_dev}:{source.st_ino}" != source_id:
        fail("owned entry generation changed before rename")
    rename_noreplace(source_root, destination_root, source_name, destination_name)
    moved = os.stat(destination_name, dir_fd=destination_root, follow_symlinks=False)
    if moved.st_dev != source.st_dev or moved.st_ino != source.st_ino:
        try:
            rename_noreplace(destination_root, source_root, destination_name, source_name)
        except OSError as error:
            fail(f"unowned entry generation remains quarantined after rename: {error}")
        fail("owned entry generation changed during rename and the moved replacement was restored")


def remove_one_tombstone_item(descriptor):
    with os.scandir(descriptor) as entries:
        entry = next(entries, None)
    if entry is None:
        return False
    observed = os.stat(entry.name, dir_fd=descriptor, follow_symlinks=False)
    if stat.S_ISDIR(observed.st_mode):
        child = open_relative(descriptor, entry.name, os.O_RDONLY | os.O_DIRECTORY)
        try:
            if remove_one_tombstone_item(child):
                return True
        finally:
            os.close(child)
        current = os.stat(entry.name, dir_fd=descriptor, follow_symlinks=False)
        if current.st_dev != observed.st_dev or current.st_ino != observed.st_ino:
            fail(f"retention cleanup directory changed: {entry.name}")
        os.rmdir(entry.name, dir_fd=descriptor)
        return True
    if not stat.S_ISREG(observed.st_mode):
        fail(f"invalid retention cleanup entry: {entry.name}")
    os.unlink(entry.name, dir_fd=descriptor)
    return True


def command_prune_tombstones_fd(arguments):
    if len(arguments) != 1:
        fail("usage: fm-contained-read.py prune-tombstones-fd <batch>")
    batch = int(arguments[0])
    if batch <= 0:
        fail("tombstone prune batch must be positive")
    root = checked_root(3)
    pruned = 0
    while pruned < batch:
        with os.scandir(root) as tombstones:
            tombstone_entry = next(tombstones, None)
        if tombstone_entry is None:
            break
        tombstone_name = tombstone_entry.name
        if not tombstone_name.startswith("tombstone-"):
            fail(f"invalid retention tombstone: {tombstone_name}")
        observed = os.stat(tombstone_name, dir_fd=root, follow_symlinks=False)
        if not stat.S_ISDIR(observed.st_mode):
            fail(f"invalid retention tombstone: {tombstone_name}")
        tombstone = open_relative(root, tombstone_name, os.O_RDONLY | os.O_DIRECTORY)
        try:
            if remove_one_tombstone_item(tombstone):
                pruned += 1
                continue
        finally:
            os.close(tombstone)
        current = os.stat(tombstone_name, dir_fd=root, follow_symlinks=False)
        if current.st_dev != observed.st_dev or current.st_ino != observed.st_ino:
            fail(f"retention tombstone changed during cleanup: {tombstone_name}")
        os.rmdir(tombstone_name, dir_fd=root)
        pruned += 1
    pending = bool(os.listdir(root))
    print(json.dumps({"pruned": pruned, "pending": pending}, separators=(",", ":")))


def copy_directory_contents(source, destination):
    before = os.fstat(source)
    names = sorted(os.listdir(source))
    for name in names:
        observed = os.stat(name, dir_fd=source, follow_symlinks=False)
        if stat.S_ISDIR(observed.st_mode):
            child_source = open_relative(source, name, os.O_RDONLY | os.O_DIRECTORY)
            os.mkdir(name, 0o700, dir_fd=destination)
            child_destination = open_relative(destination, name, os.O_RDONLY | os.O_DIRECTORY)
            try:
                copy_directory_contents(child_source, child_destination)
            finally:
                os.close(child_destination)
                os.close(child_source)
        elif stat.S_ISREG(observed.st_mode):
            child_source = open_relative(source, name, os.O_RDONLY)
            child_destination = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
                dir_fd=destination,
            )
            try:
                opened = os.fstat(child_source)
                offset = 0
                while offset < opened.st_size:
                    chunk = os.pread(child_source, min(1024 * 1024, opened.st_size - offset), offset)
                    if not chunk:
                        fail(f"source ended while copying {name}")
                    written = 0
                    while written < len(chunk):
                        written += os.write(child_destination, chunk[written:])
                    offset += len(chunk)
                os.fsync(child_destination)
                if not same_file(opened, os.fstat(child_source)):
                    fail(f"source changed while copying {name}")
            finally:
                os.close(child_destination)
                os.close(child_source)
        else:
            fail(f"source is not a real file or directory: {name}")
    after = os.fstat(source)
    if before.st_dev != after.st_dev or before.st_ino != after.st_ino or names != sorted(os.listdir(source)):
        fail("source directory changed while copying")


def command_copy_directory_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py copy-directory-fd <source> <destination-parent|-> <destination>")
    source_name, parent_name, destination_name = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("copy directory names must be single safe components")
    if parent_name != "-" and len(components(parent_name)) != 1:
        fail("copy directory parent must be one safe component")
    source_root = checked_root(3)
    destination_root = checked_root(4)
    source = open_relative(source_root, source_name, os.O_RDONLY | os.O_DIRECTORY)
    parent = os.dup(destination_root)
    staged_name = f".{destination_name}.legacy-restore"
    try:
        if parent_name != "-":
            try:
                os.mkdir(parent_name, 0o700, dir_fd=destination_root)
            except FileExistsError:
                pass
            os.close(parent)
            parent = open_relative(destination_root, parent_name, os.O_RDONLY | os.O_DIRECTORY)
        try:
            staged = open_relative(parent, staged_name, os.O_RDONLY | os.O_DIRECTORY)
        except FileNotFoundError:
            staged = None
        if staged is not None:
            try:
                remove_directory_contents(staged)
            finally:
                os.close(staged)
            os.rmdir(staged_name, dir_fd=parent)
        os.mkdir(staged_name, 0o700, dir_fd=parent)
        destination = open_relative(parent, staged_name, os.O_RDONLY | os.O_DIRECTORY)
        try:
            copy_directory_contents(source, destination)
            os.fsync(destination)
        finally:
            os.close(destination)
        rename_noreplace(parent, parent, staged_name, destination_name)
        os.fsync(parent)
    except Exception:
        try:
            staged = open_relative(parent, staged_name, os.O_RDONLY | os.O_DIRECTORY)
        except (FileNotFoundError, NotADirectoryError):
            staged = None
        if staged is not None:
            try:
                remove_directory_contents(staged)
            finally:
                os.close(staged)
            os.rmdir(staged_name, dir_fd=parent)
        raise
    finally:
        os.close(parent)
        os.close(source)


def command_rebase_legacy_report_links_fd(arguments):
    if len(arguments) != 2:
        fail("usage: fm-contained-read.py rebase-legacy-report-links-fd <cohort> <report>")
    cohort_name, report_name = arguments
    if len(components(cohort_name)) != 1 or len(components(report_name)) != 1:
        fail("legacy report names must be single safe components")
    root = checked_root(3)
    cohort = open_relative(root, cohort_name, os.O_RDONLY | os.O_DIRECTORY)
    report = open_relative(cohort, report_name, os.O_RDONLY | os.O_DIRECTORY)
    source = None
    staged_name = f".report.html.rebased.{secrets.token_hex(16)}"
    try:
        try:
            source = open_relative(report, "report.html", os.O_RDONLY)
        except FileNotFoundError:
            return
        opened = os.fstat(source)
        if opened.st_size > 32 * 1024 * 1024:
            fail("legacy report page exceeds its migration limit")
        content = bytearray()
        offset = 0
        while offset < opened.st_size:
            chunk = os.pread(source, min(1024 * 1024, opened.st_size - offset), offset)
            if not chunk:
                fail("legacy report page ended during migration")
            content.extend(chunk)
            offset += len(chunk)
        if not same_file(opened, os.fstat(source)):
            fail("legacy report page changed during migration")
        rebased = bytes(content).replace(
            b'src="../../.retention-policy.js"',
            b'src="../../../.retention-policy.js"',
        ).replace(
            b'href="../../index.html"',
            b'href="../../../index.html"',
        )
        if rebased == content:
            return
        staged = os.open(
            staged_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=report,
        )
        try:
            view = memoryview(rebased)
            while view:
                written = os.write(staged, view)
                view = view[written:]
            os.fsync(staged)
        finally:
            os.close(staged)
        current = os.stat("report.html", dir_fd=report, follow_symlinks=False)
        if not same_file(opened, current):
            fail("legacy report page changed before migration install")
        os.rename(staged_name, "report.html", src_dir_fd=report, dst_dir_fd=report)
        os.fsync(report)
    finally:
        if source is not None:
            os.close(source)
        try:
            os.unlink(staged_name, dir_fd=report)
        except FileNotFoundError:
            pass
        os.close(report)
        os.close(cohort)


def command_exchange_directories_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py exchange-directories-fd <first> <second> <first-id> <second-id>")
    first_name, second_name, first_id, second_id = arguments
    if len(components(first_name)) != 1 or len(components(second_name)) != 1:
        fail("exchange directory names must be single safe components")
    root = checked_root(3)
    first = os.stat(first_name, dir_fd=root, follow_symlinks=False)
    second = os.stat(second_name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISDIR(first.st_mode) or not stat.S_ISDIR(second.st_mode):
        fail("exchange operands must be real directories")
    if f"{first.st_dev}:{first.st_ino}" != first_id or f"{second.st_dev}:{second.st_ino}" != second_id:
        fail("exchange directory generation changed before publication")
    exchange_names(root, first_name, second_name)
    moved_first = os.stat(second_name, dir_fd=root, follow_symlinks=False)
    moved_second = os.stat(first_name, dir_fd=root, follow_symlinks=False)
    if f"{moved_first.st_dev}:{moved_first.st_ino}" != first_id \
            or f"{moved_second.st_dev}:{moved_second.st_ino}" != second_id:
        exchange_names(root, first_name, second_name)
        fail("exchange directory generation changed during publication")


def symlink_target(root, name):
    observed = os.stat(name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISLNK(observed.st_mode):
        fail(f"expected an owned symbolic link at {name}")
    return os.readlink(name, dir_fd=root)


def command_stage_retention_cohort_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py stage-retention-cohort-fd <cohort> <handoff> <identity> <target>")
    cohort, handoff, identity, target = arguments
    if len(components(cohort)) != 1 or len(components(handoff)) != 1 or not target:
        fail("retention cohort handoff arguments are invalid")
    active = checked_root(3)
    replacement = checked_root(4)
    source = os.stat(cohort, dir_fd=active, follow_symlinks=False)
    if stat.S_ISDIR(source.st_mode):
        if f"{source.st_dev}:{source.st_ino}" != identity:
            fail("fresh cohort generation changed before handoff")
        try:
            os.symlink(target, handoff, dir_fd=replacement)
        except FileExistsError:
            if symlink_target(replacement, handoff) != target:
                fail("fresh cohort handoff link changed")
        exchange_between(active, cohort, replacement, handoff)
        moved_link = symlink_target(active, cohort)
        moved_source = os.stat(handoff, dir_fd=replacement, follow_symlinks=False)
        if moved_link != target or not stat.S_ISDIR(moved_source.st_mode) \
                or f"{moved_source.st_dev}:{moved_source.st_ino}" != identity:
            exchange_between(active, cohort, replacement, handoff)
            fail("fresh cohort generation changed during handoff")
    elif stat.S_ISLNK(source.st_mode):
        if os.readlink(cohort, dir_fd=active) != target:
            fail("fresh cohort public handoff link changed")
        moved_source = os.stat(handoff, dir_fd=replacement, follow_symlinks=False)
        if not stat.S_ISDIR(moved_source.st_mode) or f"{moved_source.st_dev}:{moved_source.st_ino}" != identity:
            fail("fresh cohort handoff generation changed")
    else:
        fail("fresh cohort is not a directory or owned handoff link")
    try:
        os.symlink(handoff, cohort, dir_fd=replacement)
    except FileExistsError:
        if symlink_target(replacement, cohort) != handoff:
            fail("fresh cohort replacement link changed")


def command_finalize_retention_cohort_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py finalize-retention-cohort-fd <cohort> <handoff> <identity> <retired-target>")
    cohort, handoff, identity, retired_target = arguments
    if len(components(cohort)) != 1 or len(components(handoff)) != 1 or not retired_target:
        fail("retention cohort finalization arguments are invalid")
    active = checked_root(3)
    retired = checked_root(4)
    current = os.stat(cohort, dir_fd=active, follow_symlinks=False)
    if stat.S_ISLNK(current.st_mode):
        if os.readlink(cohort, dir_fd=active) != handoff:
            fail("fresh cohort activation link changed")
        staged = os.stat(handoff, dir_fd=active, follow_symlinks=False)
        if not stat.S_ISDIR(staged.st_mode) or f"{staged.st_dev}:{staged.st_ino}" != identity:
            fail("fresh cohort activation generation changed")
        exchange_between(active, cohort, active, handoff)
        installed = os.stat(cohort, dir_fd=active, follow_symlinks=False)
        if not stat.S_ISDIR(installed.st_mode) or f"{installed.st_dev}:{installed.st_ino}" != identity \
                or symlink_target(active, handoff) != handoff:
            exchange_between(active, cohort, active, handoff)
            fail("fresh cohort changed during activation")
        os.unlink(handoff, dir_fd=active)
    elif not stat.S_ISDIR(current.st_mode) or f"{current.st_dev}:{current.st_ino}" != identity:
        fail("fresh cohort active generation changed")
    try:
        if symlink_target(retired, cohort) != retired_target:
            fail("retired fresh cohort handoff link changed")
        os.unlink(cohort, dir_fd=retired)
    except FileNotFoundError:
        pass


def command_prepare_retention_link_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py prepare-retention-link-fd <cohort> <identity> <target>")
    cohort, identity, target = arguments
    if len(components(cohort)) != 1 or os.path.isabs(target) or "\0" in target:
        fail("retention link arguments are invalid")
    active = checked_root(3)
    replacement = checked_root(4)
    source = os.stat(cohort, dir_fd=active, follow_symlinks=False)
    if not stat.S_ISDIR(source.st_mode) or f"{source.st_dev}:{source.st_ino}" != identity:
        fail("fresh cohort generation changed before cutover")
    try:
        os.symlink(target, cohort, dir_fd=replacement)
    except FileExistsError:
        if symlink_target(replacement, cohort) != target:
            fail("fresh cohort cutover link changed")


def command_finalize_retention_link_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py finalize-retention-link-fd <cohort> <identity> <target>")
    cohort, identity, target = arguments
    if len(components(cohort)) != 1 or os.path.isabs(target) or "\0" in target:
        fail("retention link arguments are invalid")
    active = checked_root(3)
    retired = checked_root(4)
    current = os.stat(cohort, dir_fd=active, follow_symlinks=False)
    if stat.S_ISDIR(current.st_mode):
        if f"{current.st_dev}:{current.st_ino}" != identity:
            fail("fresh cohort active generation changed")
        return
    if not stat.S_ISLNK(current.st_mode) or os.readlink(cohort, dir_fd=active) != target:
        fail("fresh cohort public link changed")
    source = os.stat(cohort, dir_fd=retired, follow_symlinks=False)
    if not stat.S_ISDIR(source.st_mode) or f"{source.st_dev}:{source.st_ino}" != identity:
        fail("fresh cohort retired generation changed")
    exchange_between(active, cohort, retired, cohort)
    installed = os.stat(cohort, dir_fd=active, follow_symlinks=False)
    displaced_target = symlink_target(retired, cohort)
    if not stat.S_ISDIR(installed.st_mode) or f"{installed.st_dev}:{installed.st_ino}" != identity \
            or displaced_target != target:
        exchange_between(active, cohort, retired, cohort)
        fail("fresh cohort changed during activation")
    os.unlink(cohort, dir_fd=retired)


def command_remove_owned_file_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py remove-owned-file-fd <name> <identity> <quarantine>")
    name, identity, quarantine = arguments
    if len(components(name)) != 1 or len(components(quarantine)) != 1:
        fail("owned file names must be single safe components")
    root = checked_root(3)
    before = os.stat(name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or f"{before.st_dev}:{before.st_ino}" != identity:
        fail("owned file generation changed before removal")
    try:
        os.stat(quarantine, dir_fd=root, follow_symlinks=False)
        fail("owned file quarantine already exists")
    except FileNotFoundError:
        pass
    ready = os.environ.get("FM_CONTAINED_REMOVE_TEST_READY")
    proceed = os.environ.get("FM_CONTAINED_REMOVE_TEST_PROCEED")
    if ready and proceed:
        with open(ready, "x", encoding="utf-8") as marker:
            marker.write("ready\n")
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                fail("owned file removal test gate timed out")
            time.sleep(0.01)
    os.rename(name, quarantine, src_dir_fd=root, dst_dir_fd=root)
    moved = os.stat(quarantine, dir_fd=root, follow_symlinks=False)
    if f"{moved.st_dev}:{moved.st_ino}" != identity:
        try:
            os.link(
                quarantine,
                name,
                src_dir_fd=root,
                dst_dir_fd=root,
                follow_symlinks=False,
            )
            os.unlink(quarantine, dir_fd=root)
        except OSError:
            pass
        fail("owned file generation changed during removal")
    os.unlink(quarantine, dir_fd=root)


def ensure_child_directory(root, name):
    try:
        os.mkdir(name, 0o700, dir_fd=root)
    except FileExistsError:
        pass
    observed = os.stat(name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISDIR(observed.st_mode):
        fail(f"report cohort is not a real directory: {name}")
    descriptor = open_relative(root, name, os.O_RDONLY | os.O_DIRECTORY)
    opened = os.fstat(descriptor)
    if not same_file(observed, opened):
        os.close(descriptor)
        fail(f"report cohort changed while opening: {name}")
    return descriptor


def command_publish_report_fd(arguments):
    if len(arguments) != 6:
        fail("usage: fm-contained-read.py publish-report-fd <staged> <cohort> <report> <staged-id> <previous-cohort|-> <previous-id|->")
    staged_name, cohort_name, report_name, staged_id, previous_cohort, previous_id = arguments
    for name in (staged_name, cohort_name, report_name):
        if len(components(name)) != 1:
            fail("report publication names must be single safe components")
    root = checked_root(3)
    staged = os.stat(staged_name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISDIR(staged.st_mode) or f"{staged.st_dev}:{staged.st_ino}" != staged_id:
        fail("staged report generation changed before publication")
    test_fifo_handshake(
        "FM_CONTAINED_REPORT_PUBLISH_TEST_READY",
        "FM_CONTAINED_REPORT_PUBLISH_TEST_PROCEED",
        f"{staged_name}\n",
        "report publication test gate",
    )
    destination = ensure_child_directory(root, cohort_name)
    previous_name = f".{report_name}.previous"
    previous_root = None
    displaced = False
    try:
        if previous_cohort != "-":
            if len(components(previous_cohort)) != 1 or not previous_id or previous_id == "-":
                fail("previous report identity is invalid")
            previous_root = ensure_child_directory(root, previous_cohort)
            previous = os.stat(report_name, dir_fd=previous_root, follow_symlinks=False)
            if not stat.S_ISDIR(previous.st_mode) or f"{previous.st_dev}:{previous.st_ino}" != previous_id:
                fail("previous report generation changed before publication")
            rename_noreplace(previous_root, root, report_name, previous_name)
            moved_previous = os.stat(previous_name, dir_fd=root, follow_symlinks=False)
            if f"{moved_previous.st_dev}:{moved_previous.st_ino}" != previous_id:
                fail("previous report generation changed during publication")
            displaced = True
        test_fifo_handshake(
            "FM_CONTAINED_REPORT_RENAME_TEST_READY",
            "FM_CONTAINED_REPORT_RENAME_TEST_PROCEED",
            f"{staged_name}\n",
            "report rename test gate",
        )
        rename_noreplace(root, destination, staged_name, report_name)
        installed = os.stat(report_name, dir_fd=destination, follow_symlinks=False)
        if f"{installed.st_dev}:{installed.st_ino}" != staged_id:
            try:
                rename_noreplace(destination, root, report_name, staged_name)
                restored = os.stat(staged_name, dir_fd=root, follow_symlinks=False)
                if not same_file(installed, restored):
                    fail("unowned staged report generation could not be restored")
            except OSError as error:
                fail(f"unowned staged report generation remains quarantined after rename: {error}")
            fail("staged report generation changed during publication")
    except Exception:
        if displaced:
            try:
                rename_noreplace(root, previous_root, previous_name, report_name)
            except OSError:
                pass
        raise
    finally:
        if previous_root is not None:
            os.close(previous_root)
        os.close(destination)


def command_rollback_report_fd(arguments):
    if len(arguments) != 6:
        fail("usage: fm-contained-read.py rollback-report-fd <cohort> <report> <installed-id> <previous-cohort|-> <previous-id|-> <failed-name>")
    cohort_name, report_name, installed_id, previous_cohort, previous_id, failed_name = arguments
    for name in (cohort_name, report_name, failed_name):
        if len(components(name)) != 1:
            fail("report rollback names must be single safe components")
    root = checked_root(3)
    destination = ensure_child_directory(root, cohort_name)
    installed = os.stat(report_name, dir_fd=destination, follow_symlinks=False)
    if not stat.S_ISDIR(installed.st_mode) or f"{installed.st_dev}:{installed.st_ino}" != installed_id:
        os.close(destination)
        fail("installed report generation changed before rollback")
    rename_noreplace(destination, root, report_name, failed_name)
    failed = os.stat(failed_name, dir_fd=root, follow_symlinks=False)
    if f"{failed.st_dev}:{failed.st_ino}" != installed_id:
        os.close(destination)
        fail("installed report generation changed during rollback")
    previous_root = None
    try:
        if previous_cohort != "-":
            previous_name = f".{report_name}.previous"
            previous_root = ensure_child_directory(root, previous_cohort)
            previous = os.stat(previous_name, dir_fd=root, follow_symlinks=False)
            if not stat.S_ISDIR(previous.st_mode) or f"{previous.st_dev}:{previous.st_ino}" != previous_id:
                fail("previous report generation changed before rollback")
            rename_noreplace(root, previous_root, previous_name, report_name)
        failed_root = open_relative(root, failed_name, os.O_RDONLY | os.O_DIRECTORY)
        try:
            remove_directory_contents(failed_root)
        finally:
            os.close(failed_root)
        os.rmdir(failed_name, dir_fd=root)
    except Exception:
        try:
            rename_noreplace(root, destination, failed_name, report_name)
        except OSError:
            pass
        raise
    finally:
        if previous_root is not None:
            os.close(previous_root)
        os.close(destination)


def command_remove_owned_tree_fd(arguments):
    if len(arguments) != 2:
        fail("usage: fm-contained-read.py remove-owned-tree-fd <name> <identity>")
    name, identity = arguments
    if len(components(name)) != 1:
        fail("owned tree name must be one safe component")
    root = checked_root(3)
    observed = os.stat(name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISDIR(observed.st_mode) or f"{observed.st_dev}:{observed.st_ino}" != identity:
        fail("owned tree generation changed before removal")
    tombstones = checked_root(4)
    descriptor = open_relative(root, name, os.O_RDONLY | os.O_DIRECTORY)
    quarantine = f"tombstone-{secrets.token_hex(16)}"
    try:
        rename_noreplace(root, tombstones, name, quarantine)
        quarantined = os.stat(quarantine, dir_fd=tombstones, follow_symlinks=False)
        if observed.st_dev != quarantined.st_dev or observed.st_ino != quarantined.st_ino:
            try:
                rename_noreplace(tombstones, root, quarantine, name)
            except OSError:
                pass
            fail("owned tree generation changed during quarantine")
        ready = os.environ.get("FM_CONTAINED_REMOVE_TREE_TEST_READY")
        proceed = os.environ.get("FM_CONTAINED_REMOVE_TREE_TEST_PROCEED")
        if ready and proceed:
            with open(ready, "x", encoding="utf-8") as marker:
                marker.write(f"{quarantine}\n")
            deadline = time.monotonic() + 5
            while not os.path.exists(proceed):
                if time.monotonic() >= deadline:
                    fail("owned tree removal test gate timed out")
                time.sleep(0.01)
        remove_directory_contents(descriptor)
        current = os.stat(quarantine, dir_fd=tombstones, follow_symlinks=False)
        if observed.st_dev != current.st_dev or observed.st_ino != current.st_ino:
            fail("owned tree generation changed during removal")
        os.rmdir(quarantine, dir_fd=tombstones)
    finally:
        os.close(descriptor)


def main():
    if len(sys.argv) < 2:
        fail("contained read command is required")
    if sys.argv[1] == "read-fd":
        command_read_fd(sys.argv[2:])
    elif sys.argv[1] == "snapshot-task-fd":
        command_snapshot_task_fd(sys.argv[2:])
    elif sys.argv[1] == "snapshot-files-fd":
        command_snapshot_files_fd(sys.argv[2:])
    elif sys.argv[1] == "snapshot-file-fd":
        command_snapshot_file_fd(sys.argv[2:])
    elif sys.argv[1] == "replace-file-fd":
        command_replace_file_fd(sys.argv[2:])
    elif sys.argv[1] == "remove-owned-directory-fd":
        command_remove_owned_directory_fd(sys.argv[2:])
    elif sys.argv[1] == "remove-dead-owned-directory-fd":
        command_remove_dead_owned_directory_fd(sys.argv[2:])
    elif sys.argv[1] == "remove-incomplete-dead-candidate-fd":
        command_remove_incomplete_dead_candidate_fd(sys.argv[2:])
    elif sys.argv[1] == "fingerprint-paths-fd":
        command_fingerprint_paths_fd(sys.argv[2:])
    elif sys.argv[1] == "fingerprint-submodules-fd":
        command_fingerprint_submodules_fd(sys.argv[2:])
    elif sys.argv[1] == "fingerprint-repository-fd":
        command_fingerprint_repository_fd(sys.argv[2:])
    elif sys.argv[1] == "repository-identity-fd":
        command_repository_identity_fd(sys.argv[2:])
    elif sys.argv[1] == "git-fd":
        command_git_fd(sys.argv[2:])
    elif sys.argv[1] == "cat-fd":
        command_cat_fd(sys.argv[2:])
    elif sys.argv[1] == "cat-optional-fd":
        command_cat_optional_fd(sys.argv[2:])
    elif sys.argv[1] == "cat-child-fd":
        command_cat_child_fd(sys.argv[2:])
    elif sys.argv[1] == "exchange-files-fd":
        command_exchange_files_fd(sys.argv[2:])
    elif sys.argv[1] == "copy-file-fd":
        command_copy_file_fd(sys.argv[2:])
    elif sys.argv[1] == "rename-noreplace-owned-fd":
        command_rename_noreplace_owned_fd(sys.argv[2:])
    elif sys.argv[1] == "rename-noreplace-owned-entry-fd":
        command_rename_noreplace_owned_entry_fd(sys.argv[2:])
    elif sys.argv[1] == "prune-tombstones-fd":
        command_prune_tombstones_fd(sys.argv[2:])
    elif sys.argv[1] == "copy-directory-fd":
        command_copy_directory_fd(sys.argv[2:])
    elif sys.argv[1] == "rebase-legacy-report-links-fd":
        command_rebase_legacy_report_links_fd(sys.argv[2:])
    elif sys.argv[1] == "exchange-directories-fd":
        command_exchange_directories_fd(sys.argv[2:])
    elif sys.argv[1] == "stage-retention-cohort-fd":
        command_stage_retention_cohort_fd(sys.argv[2:])
    elif sys.argv[1] == "finalize-retention-cohort-fd":
        command_finalize_retention_cohort_fd(sys.argv[2:])
    elif sys.argv[1] == "prepare-retention-link-fd":
        command_prepare_retention_link_fd(sys.argv[2:])
    elif sys.argv[1] == "finalize-retention-link-fd":
        command_finalize_retention_link_fd(sys.argv[2:])
    elif sys.argv[1] == "remove-owned-file-fd":
        command_remove_owned_file_fd(sys.argv[2:])
    elif sys.argv[1] == "publish-report-fd":
        command_publish_report_fd(sys.argv[2:])
    elif sys.argv[1] == "rollback-report-fd":
        command_rollback_report_fd(sys.argv[2:])
    elif sys.argv[1] == "remove-owned-tree-fd":
        command_remove_owned_tree_fd(sys.argv[2:])
    else:
        fail(f"unknown contained read command: {sys.argv[1]}")


def run():
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        if isinstance(error, OSError) and error.errno == errno.ELOOP:
            message = "source traversal encountered a symlink"
        else:
            message = str(error)
        print(f"error: contained read failed: {message}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    run()
