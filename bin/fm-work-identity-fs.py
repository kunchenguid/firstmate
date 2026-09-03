#!/usr/bin/env python3
# Descriptor-bound filesystem primitives for fm-work-identity.sh.
#
# The shell owner defines relation semantics and calls this helper only for
# race-resistant directory entry inspection, publication, locking, and removal.
# Keeping path traversal and file-descriptor checks here avoids weakening those
# guarantees into repeated shell pathname checks.
import ctypes
import errno
import fcntl
import hashlib
import os
import secrets
import stat
import subprocess
import sys
import tempfile
import time


TEARDOWN_JOURNAL_MAX = 65536


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def valid_name(name):
    return bool(name) and name not in (".", "..") and "/" not in name and "\0" not in name


def valid_token(token):
    return bool(token) and len(token) <= 256 and all(char.isalnum() or char in ".:_-" for char in token)


def open_owned_dir(path, expected):
    flags = os.O_RDONLY | os.O_DIRECTORY
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        fail(f"cannot open owned directory {path}: {exc.strerror}")
    info = os.fstat(fd)
    actual = f"{info.st_dev}:{info.st_ino}"
    if actual != expected:
        os.close(fd)
        fail(f"owned directory was replaced: {path}")
    return fd


def open_source(path):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        fail(f"cannot open publication source {path}: {exc.strerror}")
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        os.close(fd)
        fail(f"publication source is unsafe: {path}")
    return fd, info


def snapshot_path(path, maximum):
    parent, name = os.path.split(path)
    if not valid_name(name):
        fail(f"publication source name is unsafe: {path}")
    parent = parent or "."
    parent_flags = os.O_RDONLY | os.O_DIRECTORY
    parent_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        parent_fd = os.open(parent, parent_flags)
    except OSError as exc:
        fail(f"cannot open publication source parent {parent}: {exc.strerror}")
    source_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        source_fd = os.open(name, source_flags, dir_fd=parent_fd)
    except OSError as exc:
        os.close(parent_fd)
        fail(f"cannot open publication source {path}: {exc.strerror}")
    source_info = os.fstat(source_fd)
    if not stat.S_ISREG(source_info.st_mode) or source_info.st_nlink != 1:
        os.close(source_fd)
        os.close(parent_fd)
        fail(f"publication source is unsafe: {path}")
    if source_info.st_size > maximum:
        os.close(source_fd)
        os.close(parent_fd)
        fail(f"publication source exceeds {maximum} bytes: {path}")
    before = state_from_info(source_info)
    try:
        with tempfile.SpooledTemporaryFile(max_size=1048576) as payload:
            total = 0
            while True:
                chunk = os.read(source_fd, 131072)
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum:
                    fail(f"publication source exceeds {maximum} bytes: {path}")
                payload.write(chunk)
            if state_from_info(os.fstat(source_fd)) != before:
                fail(f"publication source changed during snapshot: {path}")
            try:
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                fail(f"publication source changed during snapshot: {path}")
            if state_from_info(current) != before:
                fail(f"publication source changed during snapshot: {path}")
            payload.seek(0)
            while True:
                chunk = payload.read(131072)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
    finally:
        os.close(source_fd)
        os.close(parent_fd)


def copy_to_new(source, directory_fd, name, expected_state, expected_digest):
    if not valid_regular_commitment(expected_state, expected_digest):
        fail("publication source commitment is malformed")
    source_fd, source_info = open_source(source)
    source_state = state_from_info(source_info)
    if source_state != expected_state:
        os.close(source_fd)
        fail(f"publication source changed before copying: {source}")
    expected_size = committed_entry_size(expected_state)
    source_digest = hashlib.sha256()
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        target_fd = os.open(name, flags, stat.S_IMODE(source_info.st_mode), dir_fd=directory_fd)
    except OSError as exc:
        os.close(source_fd)
        raise exc
    copied = False
    try:
        total = 0
        while True:
            chunk = os.read(source_fd, min(131072, expected_size - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > expected_size:
                fail(f"publication source changed during copying: {source}")
            source_digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(target_fd, view)
                view = view[written:]
        if total != expected_size or source_digest.hexdigest() != expected_digest \
                or state_from_info(os.fstat(source_fd)) != expected_state:
            fail(f"publication source changed during copying: {source}")
        try:
            current = os.stat(source, follow_symlinks=False)
        except FileNotFoundError:
            fail(f"publication source changed during copying: {source}")
        if state_from_info(current) != expected_state:
            fail(f"publication source changed during copying: {source}")
        os.fchmod(target_fd, stat.S_IMODE(source_info.st_mode))
        os.fsync(target_fd)
        target_info = os.fstat(target_fd)
        if target_info.st_size != expected_size:
            fail(f"publication candidate does not match its source: {name}")
        copied = True
        return source_state, source_digest.hexdigest()
    finally:
        os.close(target_fd)
        os.close(source_fd)
        if not copied:
            remove(directory_fd, name)


def remove(directory_fd, name):
    try:
        os.unlink(name, dir_fd=directory_fd)
    except FileNotFoundError:
        pass


def raw_entry_state(directory_fd, name):
    try:
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return "absent"
    kind = "regular" if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 else "unsafe"
    return ":".join([
        kind,
        str(info.st_dev),
        str(info.st_ino),
        str(info.st_mode),
        str(info.st_nlink),
        str(info.st_size),
        str(info.st_mtime_ns),
        str(info.st_ctime_ns),
    ])


def entry_state(directory_fd, name):
    state = raw_entry_state(directory_fd, name)
    if state.startswith("unsafe:"):
        fail(f"owned destination entry is unsafe: {name}")
    return state


def entry_digest(directory_fd, name, allowed_links=(1,), expected_size=None):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(name, flags, dir_fd=directory_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink not in allowed_links:
            fail(f"owned destination entry is unsafe: {name}")
        if expected_size is not None and info.st_size != expected_size:
            fail(f"owned destination size does not match expected size: {name}")
        digest = hashlib.sha256()
        total = 0
        while True:
            read_size = 131072
            if expected_size is not None:
                read_size = min(read_size, expected_size - total + 1)
            chunk = os.read(fd, read_size)
            if not chunk:
                break
            total += len(chunk)
            if expected_size is not None and total > expected_size:
                fail(f"owned destination size does not match expected size: {name}")
            digest.update(chunk)
        if expected_size is not None \
                and (total != expected_size or os.fstat(fd).st_size != expected_size):
            fail(f"owned destination size does not match expected size: {name}")
        return digest.hexdigest()
    finally:
        os.close(fd)


def file_digest(directory_fd, name, expected_size=None):
    return entry_digest(directory_fd, name, expected_size=expected_size)


def state_from_info(info):
    kind = "regular" if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 else "unsafe"
    return ":".join([
        kind,
        str(info.st_dev),
        str(info.st_ino),
        str(info.st_mode),
        str(info.st_nlink),
        str(info.st_size),
        str(info.st_mtime_ns),
        str(info.st_ctime_ns),
    ])


def committed_entry_size(expected_state):
    fields = expected_state.split(":")
    if len(fields) != 8 or fields[0] not in ("regular", "unsafe") \
            or any(not field.isdigit() for field in fields[1:]):
        fail("owned destination size commitment is malformed")
    return int(fields[5])


def describe_source(path, maximum):
    source_fd, source_info = open_source(path)
    expected_state = state_from_info(source_info)
    if source_info.st_size > maximum:
        os.close(source_fd)
        fail(f"publication source exceeds {maximum} bytes: {path}")
    expected_size = source_info.st_size
    digest = hashlib.sha256()
    try:
        total = 0
        while True:
            chunk = os.read(source_fd, min(131072, expected_size - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > expected_size:
                fail(f"publication source changed during commitment: {path}")
            digest.update(chunk)
        if total != expected_size or state_from_info(os.fstat(source_fd)) != expected_state:
            fail(f"publication source changed during commitment: {path}")
        try:
            current = os.stat(path, follow_symlinks=False)
        except FileNotFoundError:
            fail(f"publication source changed during commitment: {path}")
        if state_from_info(current) != expected_state:
            fail(f"publication source changed during commitment: {path}")
        print(f"{expected_state}\t{digest.hexdigest()}")
    finally:
        os.close(source_fd)


def exact_entry_matches(directory_fd, name, expected_state, expected_digest):
    if entry_state(directory_fd, name) != expected_state:
        return False
    return expected_state != "absent" and file_digest(directory_fd, name) == expected_digest


def read_exact(directory_fd, name, expected_state, expected_digest):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(name, flags, dir_fd=directory_fd)
    try:
        before = state_from_info(os.fstat(fd))
        if before != expected_state or not before.startswith("regular:"):
            fail(f"owned source changed before snapshot: {name}")
        digest = hashlib.sha256()
        with tempfile.SpooledTemporaryFile(max_size=1048576) as payload:
            while True:
                chunk = os.read(fd, 131072)
                if not chunk:
                    break
                payload.write(chunk)
                digest.update(chunk)
            if digest.hexdigest() != expected_digest:
                fail(f"owned source content changed before snapshot: {name}")
            if state_from_info(os.fstat(fd)) != expected_state:
                fail(f"owned source changed during snapshot: {name}")
            payload.seek(0)
            while True:
                chunk = payload.read(131072)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
    finally:
        os.close(fd)


def conditional_remove(directory_fd, name, expected_state, expected_digest=None, allow_hardlink=False):
    actual = raw_entry_state(directory_fd, name) if allow_hardlink else entry_state(directory_fd, name)
    if actual != expected_state:
        fail(f"owned destination changed before removal: {name}")
    if actual == "absent":
        return
    if allow_hardlink:
        fields = actual.split(":")
        if fields[0] not in ("regular", "unsafe") or not stat.S_ISREG(int(fields[3])):
            fail(f"owned removal staging entry is unsafe: {name}")
    elif expected_digest is not None and file_digest(directory_fd, name) != expected_digest:
        fail(f"owned destination content changed before removal: {name}")
    current = raw_entry_state(directory_fd, name) if allow_hardlink else entry_state(directory_fd, name)
    if current != expected_state:
        fail(f"owned destination changed before removal: {name}")
    os.unlink(name, dir_fd=directory_fd)
    os.fsync(directory_fd)


def read_remove_journal(directory_fd, journal, name):
    try:
        fd = os.open(
            journal,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 2048:
        os.close(fd)
        fail(f"owned removal journal is unsafe: {journal}")
    try:
        payload = os.read(fd, 2049).decode("ascii", "strict")
    except UnicodeError:
        fail(f"owned removal journal is malformed: {journal}")
    finally:
        os.close(fd)
    lines = payload.splitlines()
    retired_prefix = f".{name}.remove-retired."
    if len(lines) != 3 or lines[0] != "v1" or not valid_name(lines[1]) \
            or not lines[1].startswith(retired_prefix) \
            or len(lines[1]) <= len(retired_prefix):
        fail(f"owned removal journal is malformed: {journal}")
    commitment = lines[2].split("\t")
    if len(commitment) != 2:
        fail(f"owned removal journal is malformed: {journal}")
    expected_state, expected_digest = commitment
    state_fields = expected_state.split(":")
    retired_token = lines[1][len(retired_prefix):]
    if len(state_fields) != 8 or state_fields[0] not in ("regular", "unsafe") \
            or any(not field.isdigit() for field in state_fields[1:]) \
            or not stat.S_ISREG(int(state_fields[3])) \
            or int(state_fields[4]) not in (1, 2) \
            or (state_fields[0] == "regular") != (int(state_fields[4]) == 1) \
            or len(retired_token) not in (16, 32) \
            or any(char not in "0123456789abcdef" for char in retired_token):
        fail(f"owned removal journal is malformed: {journal}")
    if len(expected_digest) != 64 or any(char not in "0123456789abcdef" for char in expected_digest):
        fail(f"owned removal journal is malformed: {journal}")
    return lines[1], expected_state, expected_digest


def publish_remove_journal(directory_fd, journal, retired, expected_state, expected_digest):
    temporary = f".{journal}.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
    published = False
    try:
        payload = f"v1\n{retired}\n{expected_state}\t{expected_digest}\n".encode("ascii")
        if os.write(fd, payload) != len(payload):
            raise OSError(errno.EIO, "short removal journal write")
        os.fsync(fd)
        atomic_rename(directory_fd, temporary, journal, False)
        published = True
        os.fsync(directory_fd)
    finally:
        os.close(fd)
        if not published:
            remove(directory_fd, temporary)


def retired_entry_matches(directory_fd, retired, expected_state, expected_digest):
    expected_links = int(expected_state.split(":")[4])
    expected_size = committed_entry_size(expected_state)
    return state_matches(raw_entry_state(directory_fd, retired), expected_state) \
        and entry_digest(
            directory_fd, retired, (expected_links,), expected_size
        ) == expected_digest


def recover_remove(directory_fd, name):
    journal = f".{name}.remove-journal"
    loaded = read_remove_journal(directory_fd, journal, name)
    if loaded is None:
        return
    retired, expected_state, expected_digest = loaded
    target_state = raw_entry_state(directory_fd, name)
    retired_state = raw_entry_state(directory_fd, retired)
    if retired_state == "absent":
        if target_state != "absent" and target_state != expected_state:
            fail(f"owned destination changed during removal: {name}")
        remove(directory_fd, journal)
        os.fsync(directory_fd)
        return
    if target_state != "absent":
        fail(f"owned destination changed during removal: {name}")
    if retired_entry_matches(directory_fd, retired, expected_state, expected_digest):
        remove(directory_fd, retired)
        remove(directory_fd, journal)
        os.fsync(directory_fd)
        return
    atomic_rename(directory_fd, retired, name, False)
    remove(directory_fd, journal)
    os.fsync(directory_fd)
    fail(f"owned destination changed before removal: {name}")


def remove_entry(directory_fd, name, expected_state, expected_digest, allow_hardlink=False):
    recover_remove(directory_fd, name)
    actual_state = raw_entry_state(directory_fd, name) if allow_hardlink else entry_state(directory_fd, name)
    if actual_state != expected_state:
        fail(f"owned destination changed before removal: {name}")
    if expected_state == "absent":
        return
    expected_links = int(expected_state.split(":")[4])
    if expected_links != 1 and not allow_hardlink:
        fail(f"owned destination entry is unsafe: {name}")
    expected_size = committed_entry_size(expected_state)
    if entry_digest(
            directory_fd, name, (expected_links,), expected_size
    ) != expected_digest:
        fail(f"owned destination content changed before removal: {name}")
    retired = f".{name}.remove-retired.{secrets.token_hex(16)}"
    journal = f".{name}.remove-journal"
    publish_remove_journal(directory_fd, journal, retired, expected_state, expected_digest)
    atomic_rename(directory_fd, name, retired, False)
    os.fsync(directory_fd)
    recover_remove(directory_fd, name)


def valid_regular_commitment(expected_state, expected_digest):
    fields = expected_state.split(":")
    return len(fields) == 8 and fields[0] == "regular" \
        and all(field.isdigit() for field in fields[1:]) \
        and int(fields[4]) == 1 and len(expected_digest) == 64 \
        and all(char in "0123456789abcdef" for char in expected_digest)


def parse_teardown_journal_payload(payload, journal, quarantine):
    lines = payload.splitlines()
    records = None
    if len(lines) == 3 and lines[0] == "v1" and lines[1] == quarantine:
        phase = "quarantined"
        transaction = "legacy"
        commitment = lines[2].split("\t")
        version = "v1"
    elif len(lines) == 4 and lines[0] in ("v2\tQ", "v2\tC", "v2\tF") \
            and lines[1] == quarantine:
        phase = {
            "v2\tQ": "quarantined",
            "v2\tC": "command-completed",
            "v2\tF": "finalizing",
        }[lines[0]]
        commitment = lines[2].split("\t")
        transaction = lines[3]
        version = "v2"
    elif len(lines) == 10 and lines[0] in ("v3\tQ", "v3\tC", "v3\tF") \
            and lines[1] == quarantine:
        phase = {
            "v3\tQ": "quarantined",
            "v3\tC": "command-completed",
            "v3\tF": "finalizing",
        }[lines[0]]
        commitment = lines[2].split("\t")
        transaction = lines[3]
        metadata_commitment = lines[7].split("\t")
        launch_commitment = lines[9].split("\t")
        try:
            state_path = os.fsdecode(bytes.fromhex(lines[4]))
        except ValueError:
            fail(f"owned teardown journal is malformed: {journal}")
        if os.fsencode(state_path).hex() != lines[4] \
                or not valid_name(lines[6]) or not valid_name(lines[8]) \
                or len(metadata_commitment) != 2 or len(launch_commitment) != 2 \
                or not valid_regular_commitment(*metadata_commitment) \
                or not valid_regular_commitment(*launch_commitment):
            fail(f"owned teardown journal is malformed: {journal}")
        records = (
            state_path, lines[5], lines[6], *metadata_commitment,
            lines[8], *launch_commitment,
        )
        version = "v3"
    else:
        fail(f"owned teardown journal is malformed: {journal}")
    if len(commitment) != 2:
        fail(f"owned teardown journal is malformed: {journal}")
    expected_state, expected_digest = commitment
    if not valid_regular_commitment(expected_state, expected_digest) \
            or not valid_token(transaction):
        fail(f"owned teardown journal is malformed: {journal}")
    return (
        journal, quarantine, expected_state, expected_digest,
        phase, transaction, version, records,
    )


def read_teardown_journal(directory_fd, name):
    journal = f".{name}.teardown-journal"
    quarantine = f".{name}.teardown-quarantine"
    try:
        fd = os.open(
            journal,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        if raw_entry_state(directory_fd, quarantine) != "absent":
            fail(f"owned teardown quarantine has no journal: {quarantine}")
        return None
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 \
            or info.st_size > TEARDOWN_JOURNAL_MAX:
        os.close(fd)
        fail(f"owned teardown journal is unsafe: {journal}")
    try:
        payload = os.read(fd, TEARDOWN_JOURNAL_MAX + 1).decode("ascii", "strict")
    except UnicodeError:
        fail(f"owned teardown journal is malformed: {journal}")
    finally:
        os.close(fd)
    return parse_teardown_journal_payload(payload, journal, quarantine)


def publish_teardown_journal(
        directory_fd, name, expected_state, expected_digest, transaction, records
):
    journal = f".{name}.teardown-journal"
    quarantine = f".{name}.teardown-quarantine"
    temporary = f".{journal}.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
    published = False
    try:
        state_path, state_id, metadata_name, metadata_state, metadata_digest, \
            launch_name, launch_state, launch_digest = records
        payload = (
            f"v3\tQ\n{quarantine}\n{expected_state}\t{expected_digest}\n"
            f"{transaction}\n{os.fsencode(state_path).hex()}\n{state_id}\n{metadata_name}\n"
            f"{metadata_state}\t{metadata_digest}\n{launch_name}\n"
            f"{launch_state}\t{launch_digest}\n"
        ).encode("ascii")
        if len(payload) > TEARDOWN_JOURNAL_MAX:
            fail("owned teardown journal payload is too large")
        if os.write(fd, payload) != len(payload):
            raise OSError(errno.EIO, "short teardown journal write")
        os.fsync(fd)
        atomic_rename(directory_fd, temporary, journal, False)
        published = True
        os.fsync(directory_fd)
    finally:
        os.close(fd)
        if not published:
            remove(directory_fd, temporary)
    return (
        journal, quarantine, expected_state, expected_digest,
        "quarantined", transaction, "v3", records,
    )


def set_teardown_phase(directory_fd, name, expected_phase, phase, transaction):
    loaded = read_teardown_journal(directory_fd, name)
    if loaded is None:
        fail(f"owned teardown authorization is absent: {name}")
    journal, _, _, _, current_phase, journal_transaction, version, _ = loaded
    if version not in ("v2", "v3") or journal_transaction != transaction \
            or current_phase != expected_phase:
        fail(f"owned teardown phase changed before transition: {journal}")
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(journal, flags, dir_fd=directory_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            fail(f"owned teardown journal is unsafe: {journal}")
        payload = os.read(fd, TEARDOWN_JOURNAL_MAX + 1).decode("ascii", "strict")
        if parse_teardown_journal_payload(
                payload, journal, f".{name}.teardown-quarantine"
        ) != loaded:
            fail(f"owned teardown journal changed before phase transition: {journal}")
        code = {"command-completed": b"C", "finalizing": b"F"}[phase]
        if os.pwrite(fd, code, 3) != 1:
            raise OSError(errno.EIO, "short teardown phase write")
        os.fsync(fd)
        after = os.fstat(fd)
        current = os.stat(journal, dir_fd=directory_fd, follow_symlinks=False)
        if after.st_dev != before.st_dev or after.st_ino != before.st_ino \
                or current.st_dev != after.st_dev or current.st_ino != after.st_ino \
                or not stat.S_ISREG(after.st_mode) or after.st_nlink != 1:
            fail(f"owned teardown journal changed during phase transition: {journal}")
    finally:
        os.close(fd)
    transitioned = read_teardown_journal(directory_fd, name)
    if transitioned is None or transitioned[4] != phase \
            or transitioned[5] != transaction:
        fail(f"owned teardown phase was not published: {journal}")
    return transitioned


def teardown_quarantine(
        directory_fd, name, expected_state, expected_digest, transaction, records
):
    loaded = read_teardown_journal(directory_fd, name)
    if loaded is None:
        if entry_state(directory_fd, name) != expected_state \
                or file_digest(directory_fd, name) != expected_digest:
            fail(f"owned teardown receipt changed before quarantine: {name}")
        quarantine = f".{name}.teardown-quarantine"
        if raw_entry_state(directory_fd, quarantine) != "absent":
            fail(f"owned teardown quarantine conflicts: {quarantine}")
        loaded = publish_teardown_journal(
            directory_fd, name, expected_state, expected_digest, transaction, records
        )
    journal, quarantine, journal_state, journal_digest, phase, journal_transaction, _, journal_records = loaded
    if journal_state != expected_state or journal_digest != expected_digest \
            or journal_transaction != transaction or phase != "quarantined" \
            or journal_records != records:
        fail(f"owned teardown receipt does not match retained authorization: {name}")
    target_state = raw_entry_state(directory_fd, name)
    quarantine_state = raw_entry_state(directory_fd, quarantine)
    if target_state != "absent":
        if not retired_entry_matches(
                directory_fd, name, expected_state, expected_digest
        ) or quarantine_state != "absent":
            fail(f"owned teardown receipt changed during quarantine: {name}")
        atomic_rename(directory_fd, name, quarantine, False)
        os.fsync(directory_fd)
    elif not retired_entry_matches(
            directory_fd, quarantine, expected_state, expected_digest
    ):
        fail(f"owned teardown quarantine changed: {quarantine}")
    return loaded


def teardown_state(directory_fd, name, transaction):
    loaded = read_teardown_journal(directory_fd, name)
    if loaded is None:
        return "absent"
    if loaded[5] not in (transaction, "legacy"):
        fail(f"owned teardown transaction is mismatched: {name}")
    if loaded[5] == "legacy":
        return "legacy-quarantined"
    return loaded[4]


def teardown_record_commitments(loaded):
    records = loaded[7]
    if records is None:
        return None, ()
    state_path, state_id, metadata_name, metadata_state, metadata_digest, \
        launch_name, launch_state, launch_digest = records
    return (state_path, state_id), (
        (metadata_name, metadata_state, metadata_digest),
        (launch_name, launch_state, launch_digest),
    )


def teardown_quarantine_records(loaded):
    state_owner, commitments = teardown_record_commitments(loaded)
    if state_owner is None:
        return
    state_fd = open_owned_dir(*state_owner)
    mutex_fd = operation_lock(state_fd, "teardown-records")
    try:
        positions = []
        for record_name, record_state, record_digest in commitments:
            quarantine = f".{record_name}.teardown-quarantine"
            live_state = raw_entry_state(state_fd, record_name)
            quarantine_state = raw_entry_state(state_fd, quarantine)
            if retired_entry_matches(
                    state_fd, record_name, record_state, record_digest
            ) and quarantine_state == "absent":
                positions.append((record_name, quarantine, record_state, record_digest, True))
            elif live_state == "absent" and retired_entry_matches(
                    state_fd, quarantine, record_state, record_digest
            ):
                positions.append((record_name, quarantine, record_state, record_digest, False))
            else:
                fail(f"owned teardown record changed before retirement: {record_name}")
        for record_name, quarantine, _, _, live in positions:
            if live:
                atomic_rename(state_fd, record_name, quarantine, False)
        os.fsync(state_fd)
        for record_name, quarantine, record_state, record_digest, _ in positions:
            if raw_entry_state(state_fd, record_name) != "absent" \
                    or not retired_entry_matches(
                        state_fd, quarantine, record_state, record_digest
                    ):
                fail(f"owned teardown record quarantine changed: {record_name}")
    finally:
        os.close(mutex_fd)
        os.close(state_fd)


def teardown_restore_records(loaded):
    state_owner, commitments = teardown_record_commitments(loaded)
    if state_owner is None:
        return
    state_fd = open_owned_dir(*state_owner)
    mutex_fd = operation_lock(state_fd, "teardown-records")
    try:
        positions = []
        for record_name, record_state, record_digest in commitments:
            quarantine = f".{record_name}.teardown-quarantine"
            recover_remove(state_fd, quarantine)
            live_state = raw_entry_state(state_fd, record_name)
            quarantine_state = raw_entry_state(state_fd, quarantine)
            if retired_entry_matches(
                    state_fd, record_name, record_state, record_digest
            ) and quarantine_state == "absent":
                positions.append((record_name, quarantine, False))
            elif live_state == "absent" and retired_entry_matches(
                    state_fd, quarantine, record_state, record_digest
            ):
                positions.append((record_name, quarantine, True))
            else:
                fail(f"owned teardown record changed before restore: {record_name}")
        for record_name, quarantine, quarantined in positions:
            if quarantined:
                atomic_rename(state_fd, quarantine, record_name, False)
        os.fsync(state_fd)
    finally:
        os.close(mutex_fd)
        os.close(state_fd)


def teardown_finalize_records(loaded):
    state_owner, commitments = teardown_record_commitments(loaded)
    if state_owner is None:
        return
    state_fd = open_owned_dir(*state_owner)
    mutex_fd = operation_lock(state_fd, "teardown-records")
    try:
        for record_name, record_state, record_digest in commitments:
            quarantine = f".{record_name}.teardown-quarantine"
            recover_remove(state_fd, quarantine)
            if raw_entry_state(state_fd, record_name) != "absent":
                fail(f"owned teardown record was recreated before commit: {record_name}")
            quarantine_state = raw_entry_state(state_fd, quarantine)
            if quarantine_state == "absent":
                continue
            if not retired_entry_matches(
                    state_fd, quarantine, record_state, record_digest
            ):
                fail(f"owned teardown record quarantine changed: {quarantine}")
            remove_entry(state_fd, quarantine, quarantine_state, record_digest)
        os.fsync(state_fd)
    finally:
        os.close(mutex_fd)
        os.close(state_fd)


def teardown_command_complete(directory_fd, name, transaction):
    loaded = read_teardown_journal(directory_fd, name)
    if loaded is None or loaded[5] != transaction:
        fail(f"owned teardown authorization is absent or mismatched: {name}")
    _, quarantine, expected_state, expected_digest, phase, _, _, _ = loaded
    if raw_entry_state(directory_fd, name) != "absent":
        fail(f"owned teardown receipt was recreated before command completion: {name}")
    if phase in ("command-completed", "finalizing"):
        return
    if phase != "quarantined" or not retired_entry_matches(
            directory_fd, quarantine, expected_state, expected_digest
    ):
        fail(f"owned teardown quarantine changed before command completion: {quarantine}")
    set_teardown_phase(
        directory_fd, name, "quarantined", "command-completed", transaction
    )


def teardown_restore(directory_fd, name):
    loaded = read_teardown_journal(directory_fd, name)
    if loaded is None:
        return
    journal, quarantine, expected_state, expected_digest, phase, _, _, _ = loaded
    if phase != "quarantined":
        fail(f"owned completed teardown cannot be restored: {name}")
    teardown_restore_records(loaded)
    recover_remove(directory_fd, quarantine)
    target_state = raw_entry_state(directory_fd, name)
    quarantine_state = raw_entry_state(directory_fd, quarantine)
    if target_state == "absent" and quarantine_state == "absent":
        fail(f"owned teardown receipt proof is absent before restore: {name}")
    if target_state == "absent":
        if not retired_entry_matches(
                directory_fd, quarantine, expected_state, expected_digest
        ):
            fail(f"owned teardown quarantine changed before restore: {quarantine}")
        atomic_rename(directory_fd, quarantine, name, False)
        os.fsync(directory_fd)
    elif not retired_entry_matches(
            directory_fd, name, expected_state, expected_digest
    ) or quarantine_state != "absent":
        fail(f"owned teardown receipt changed before restore: {name}")
    remove(directory_fd, journal)
    os.fsync(directory_fd)


def teardown_finalize(directory_fd, name):
    loaded = read_teardown_journal(directory_fd, name)
    if loaded is None:
        fail(f"owned teardown authorization is absent: {name}")
    journal, quarantine, expected_state, expected_digest, phase, transaction, _, _ = loaded
    recover_remove(directory_fd, quarantine)
    if raw_entry_state(directory_fd, name) != "absent":
        fail(f"owned teardown receipt was recreated before commit: {name}")
    quarantine_state = raw_entry_state(directory_fd, quarantine)
    if phase == "command-completed":
        if quarantine_state == "absent" or not retired_entry_matches(
                directory_fd, quarantine, expected_state, expected_digest
        ):
            fail(f"owned teardown quarantine changed before finalization: {quarantine}")
        teardown_quarantine_records(loaded)
        loaded = set_teardown_phase(
            directory_fd, name, "command-completed", "finalizing", transaction
        )
        phase = "finalizing"
    if phase != "finalizing":
        fail(f"owned teardown command has not completed: {name}")
    teardown_finalize_records(loaded)
    quarantine_state = raw_entry_state(directory_fd, quarantine)
    if quarantine_state != "absent":
        if not retired_entry_matches(
                directory_fd, quarantine, expected_state, expected_digest
        ):
            fail(f"owned teardown quarantine changed before commit: {quarantine}")
        quarantine_current = entry_state(directory_fd, quarantine)
        conditional_remove(
            directory_fd, quarantine, quarantine_current, expected_digest
        )
    remove(directory_fd, journal)
    os.fsync(directory_fd)


def operation_lock(directory_fd, name):
    del name
    fd = os.dup(directory_fd)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def atomic_rename(directory_fd, first, second, exchange):
    libc = ctypes.CDLL(None, use_errno=True)
    first_b = os.fsencode(first)
    second_b = os.fsencode(second)
    if sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        function = libc.renameatx_np
        flag = 0x00000002 if exchange else 0x00000004
    elif hasattr(libc, "renameat2"):
        function = libc.renameat2
        flag = 0x2 if exchange else 0x1
    else:
        fail("conditional destination rename is unavailable")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(directory_fd, first_b, directory_fd, second_b, flag) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def state_matches(actual, expected):
    return actual.rsplit(":", 1)[0] == expected.rsplit(":", 1)[0]


def read_replace_journal(directory_fd, journal):
    try:
        fd = os.open(
            journal,
            os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            fail(f"owned replacement journal is unsafe: {journal}")
        raise
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 2048:
        os.close(fd)
        fail(f"owned replacement journal is unsafe: {journal}")
    try:
        payload = os.read(fd, 2049).decode("ascii", "strict")
    except UnicodeError:
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    lines = payload.splitlines()
    if len(lines) != 5:
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    header = lines[0].split("\t")
    if len(header) != 3 or header[0] != "v3" or not valid_name(header[1]) or not valid_name(header[2]):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    expected_state = lines[1]
    expected_digest = lines[2]
    if expected_state == "absent":
        if expected_digest != "-":
            os.close(fd)
            fail(f"owned replacement journal is malformed: {journal}")
    elif not expected_state.startswith("regular:") \
            or len(expected_digest) != 64 \
            or any(char not in "0123456789abcdef" for char in expected_digest):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    candidate_state = lines[3]
    candidate_digest = lines[4]
    if not candidate_state.startswith("regular:"):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    if len(candidate_digest) != 64 or any(char not in "0123456789abcdef" for char in candidate_digest):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    return (
        fd, header[1], header[2], expected_state, expected_digest,
        candidate_state, candidate_digest,
    )


def publish_replace_journal(
        directory_fd, journal, stage, previous, expected_state, expected_digest,
        candidate_state, candidate_digest):
    temporary = f".{journal}.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
    published = False
    try:
        payload = (
            f"v3\t{stage}\t{previous}\n{expected_state}\n{expected_digest}\n"
            f"{candidate_state}\n{candidate_digest}\n"
        ).encode("ascii")
        if os.write(fd, payload) != len(payload):
            raise OSError(errno.EIO, "short replacement journal write")
        os.fsync(fd)
        atomic_rename(directory_fd, temporary, journal, False)
        published = True
        os.fsync(directory_fd)
    finally:
        os.close(fd)
        if not published:
            remove(directory_fd, temporary)


def recover_replace(directory_fd, name):
    journal = f".{name}.replace-journal"
    stage = f".{name}.replace-candidate"
    previous = f".{name}.replace-previous"
    loaded = read_replace_journal(directory_fd, journal)
    if loaded is None:
        stage_state = raw_entry_state(directory_fd, stage)
        if stage_state != "absent":
            if not stage_state.startswith("regular:"):
                fail(f"owned replacement candidate is unsafe: {stage}")
            remove(directory_fd, stage)
            os.fsync(directory_fd)
        if raw_entry_state(directory_fd, previous) != "absent":
            fail(f"owned replacement predecessor has no journal: {previous}")
        return
    (
        journal_fd, stage, previous, expected_state, expected_digest,
        candidate_state, candidate_digest,
    ) = loaded
    try:
        target_state = raw_entry_state(directory_fd, name)
        stage_state = raw_entry_state(directory_fd, stage)
        previous_state = raw_entry_state(directory_fd, previous)
        if previous_state == "absent" and stage_state == "absent" \
                and state_matches(target_state, candidate_state) \
                and file_digest(directory_fd, name) == candidate_digest:
            os.close(journal_fd)
            journal_fd = None
            remove(directory_fd, journal)
            os.fsync(directory_fd)
            return
        if previous_state != "absent" \
                and (not state_matches(previous_state, expected_state)
                     or file_digest(directory_fd, previous) != expected_digest):
            if target_state == "absent":
                atomic_rename(directory_fd, previous, name, False)
            elif stage_state == "absent" \
                    and state_matches(target_state, candidate_state) \
                    and file_digest(directory_fd, name) == candidate_digest:
                atomic_rename(directory_fd, name, stage, False)
                atomic_rename(directory_fd, previous, name, False)
            fail(f"owned destination changed during publication: {name}")
        if expected_state != "absent" and previous_state == "absent":
            if target_state != expected_state \
                    or file_digest(directory_fd, name) != expected_digest:
                fail(f"owned destination changed during publication: {name}")
            atomic_rename(directory_fd, name, previous, False)
            previous_state = raw_entry_state(directory_fd, previous)
            target_state = "absent"
            if not state_matches(previous_state, expected_state) \
                    or file_digest(directory_fd, previous) != expected_digest:
                atomic_rename(directory_fd, previous, name, False)
                fail(f"owned destination changed during publication: {name}")
        if target_state == "absent":
            if not state_matches(stage_state, candidate_state) \
                    or file_digest(directory_fd, stage) != candidate_digest:
                fail(f"owned replacement candidate changed during publication: {stage}")
            atomic_rename(directory_fd, stage, name, False)
            target_state = raw_entry_state(directory_fd, name)
            stage_state = "absent"
        if not state_matches(target_state, candidate_state) or stage_state != "absent" \
                or file_digest(directory_fd, name) != candidate_digest:
            fail(f"owned destination changed during publication: {name}")
        if previous_state != "absent":
            if not state_matches(raw_entry_state(directory_fd, previous), expected_state) \
                    or file_digest(directory_fd, previous) != expected_digest:
                atomic_rename(directory_fd, name, stage, False)
                atomic_rename(directory_fd, previous, name, False)
                fail(f"owned destination changed during publication: {name}")
            remove(directory_fd, previous)
            os.fsync(directory_fd)
        if not state_matches(raw_entry_state(directory_fd, name), candidate_state) \
                or file_digest(directory_fd, name) != candidate_digest:
            fail(f"owned destination changed before publication commit: {name}")
        os.close(journal_fd)
        journal_fd = None
        remove(directory_fd, journal)
        os.fsync(directory_fd)
    finally:
        if journal_fd is not None:
            os.close(journal_fd)


def replace_entry(
        directory_fd, name, source, expected_state, expected_digest,
        expected_source_state, expected_source_digest):
    recover_replace(directory_fd, name)
    if entry_state(directory_fd, name) != expected_state:
        fail(f"owned destination changed before publication: {name}")
    if expected_state == "absent":
        if expected_digest != "-":
            fail("absent replacement destination has a digest")
    elif file_digest(directory_fd, name) != expected_digest:
        fail(f"owned destination changed before publication: {name}")
    stage = f".{name}.replace-candidate"
    previous = f".{name}.replace-previous"
    journal = f".{name}.replace-journal"
    source_state, source_digest = copy_to_new(
        source, directory_fd, stage, expected_source_state, expected_source_digest
    )
    candidate_state = raw_entry_state(directory_fd, stage)
    if not candidate_state.startswith("regular:"):
        fail(f"owned replacement candidate is unsafe: {stage}")
    candidate_digest = file_digest(directory_fd, stage)
    if candidate_digest != source_digest \
            or committed_entry_size(candidate_state) != committed_entry_size(source_state):
        fail(f"owned replacement candidate does not match its source: {stage}")
    publish_replace_journal(
        directory_fd, journal, stage, previous, expected_state, expected_digest,
        candidate_state, candidate_digest
    )
    recover_replace(directory_fd, name)


def allowed_no_clobber_staging(name, staging):
    return staging in (f"{name}.publishing", f".{name}.scaffold-publishing")


def read_no_clobber_journal(directory_fd, journal, name, staging=None):
    recover_remove(directory_fd, journal)
    try:
        fd = os.open(
            journal,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    info = os.fstat(fd)
    journal_state = state_from_info(info)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 1024:
        os.close(fd)
        fail(f"publication journal is unsafe: {journal}")
    try:
        payload_bytes = os.read(fd, 1025)
        payload = payload_bytes.decode("ascii", "strict")
        after = os.fstat(fd)
        current = os.stat(journal, dir_fd=directory_fd, follow_symlinks=False)
        if state_from_info(after) != journal_state or state_from_info(current) != journal_state:
            fail(f"publication journal changed during validation: {journal}")
    except UnicodeError:
        fail(f"publication journal is malformed: {journal}")
    finally:
        os.close(fd)
    journal_digest = hashlib.sha256(payload_bytes).hexdigest()
    lines = payload.splitlines()
    pin_prefix = f".{name}.no-clobber-pin."
    if len(lines) == 4 and lines[0] == "v1":
        phase = "publishing"
    elif len(lines) == 5 and lines[0] == "v2" and lines[4] in ("publishing", "conflict"):
        phase = lines[4]
    else:
        fail(f"publication journal is malformed: {journal}")
    if not valid_name(lines[1]) or not allowed_no_clobber_staging(name, lines[1]) \
            or (staging is not None and lines[1] != staging) \
            or not valid_name(lines[2]) or not lines[2].startswith(pin_prefix) \
            or len(lines[2]) <= len(pin_prefix) \
            or len(lines[3]) != 64 \
            or any(char not in "0123456789abcdef" for char in lines[3]):
        fail(f"publication journal is malformed: {journal}")
    return lines[1], lines[2], lines[3], phase, journal_state, journal_digest


def publish_no_clobber_journal(directory_fd, journal, name, staging, pin, digest):
    temporary = f".{journal}.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
    published = False
    try:
        payload = f"v2\n{staging}\n{pin}\n{digest}\npublishing\n".encode("ascii")
        if os.write(fd, payload) != len(payload):
            raise OSError(errno.EIO, "short publication journal write")
        os.fsync(fd)
        atomic_rename(directory_fd, temporary, journal, False)
        published = True
        os.fsync(directory_fd)
    finally:
        os.close(fd)
        if not published:
            remove(directory_fd, temporary)


def opened_entry(directory_fd, name, digest, allowed_links):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(name, flags, dir_fd=directory_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink not in allowed_links:
            fail(f"publication entry is unsafe: {name}")
        actual_digest = hashlib.sha256()
        while True:
            chunk = os.read(fd, 131072)
            if not chunk:
                break
            actual_digest.update(chunk)
        after = os.fstat(fd)
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino) \
                or (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino) \
                or not stat.S_ISREG(current.st_mode) \
                or current.st_nlink not in allowed_links \
                or actual_digest.hexdigest() != digest:
            fail(f"publication entry changed during validation: {name}")
        return before
    finally:
        os.close(fd)


def same_inode(first, second):
    return (first.st_dev, first.st_ino) == (second.st_dev, second.st_ino)


def rollback_no_clobber_conflict(
        directory_fd, name, staging, pin, digest, journal,
        journal_state, journal_digest):
    recover_remove(directory_fd, pin)
    recover_remove(directory_fd, staging)
    try:
        target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        target_info = None
    try:
        pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        pin_info = None
    try:
        staging_info = os.stat(staging, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        staging_info = None
    if pin_info is not None:
        pin_info = opened_entry(directory_fd, pin, digest, (1, 2))
        if target_info is not None and same_inode(target_info, pin_info):
            fail("publication conflict aliases its retained candidate")
    if staging_info is not None:
        staging_info = opened_entry(directory_fd, staging, digest, (1, 2))
        if (target_info is not None and same_inode(target_info, staging_info)) \
                or (pin_info is not None and not same_inode(pin_info, staging_info)):
            fail("publication conflict does not match its retained candidate")
    if pin_info is not None:
        remove_entry(
            directory_fd, pin, state_from_info(pin_info), digest,
            allow_hardlink=True
        )
    if staging_info is not None:
        staging_info = opened_entry(directory_fd, staging, digest, (1,))
        remove_entry(directory_fd, staging, state_from_info(staging_info), digest)
    remove_entry(directory_fd, journal, journal_state, journal_digest)
    os.fsync(directory_fd)


def recover_no_clobber(directory_fd, name, staging=None, source_digest=None,
                       conflict_is_error=False):
    journal = f".{name}.no-clobber-journal"
    loaded = read_no_clobber_journal(directory_fd, journal, name, staging)
    if loaded is None:
        return False
    staging, pin, source_journal_digest, phase, journal_state, journal_digest = loaded
    if source_digest is not None and source_journal_digest != source_digest:
        fail("publication source changed while recovering")
    source_digest = source_journal_digest
    if phase == "conflict":
        rollback_no_clobber_conflict(
            directory_fd, name, staging, pin, source_digest, journal,
            journal_state, journal_digest
        )
        if conflict_is_error:
            raise SystemExit(2)
        return False

    try:
        target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        target_info = None
    try:
        pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        pin_info = None
    try:
        staging_info = os.stat(staging, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        staging_info = None

    if target_info is not None and pin_info is None and staging_info is None:
        if not stat.S_ISREG(target_info.st_mode) or target_info.st_nlink != 1:
            fail(f"publication target is unsafe: {name}")
        committed = file_digest(directory_fd, name) == source_digest
        remove_entry(directory_fd, journal, journal_state, journal_digest)
        os.fsync(directory_fd)
        if committed:
            return True
        if conflict_is_error:
            raise SystemExit(2)
        return False

    if target_info is not None \
            and ((pin_info is not None and not same_inode(target_info, pin_info))
                 or (staging_info is not None and not same_inode(target_info, staging_info))):
        rollback_no_clobber_conflict(
            directory_fd, name, staging, pin, source_digest, journal,
            journal_state, journal_digest
        )
        if conflict_is_error:
            raise SystemExit(2)
        return False

    if target_info is None:
        if pin_info is None:
            if staging_info is None:
                fail("publication journal lost its staged candidate")
            opened = opened_entry(directory_fd, staging, source_digest, (1,))
            try:
                os.link(staging, pin, src_dir_fd=directory_fd,
                        dst_dir_fd=directory_fd, follow_symlinks=False)
            except FileExistsError:
                fail("publication pin conflicts with another entry")
            pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
            current_fd = os.open(
                staging,
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_fd,
            )
            try:
                current = os.fstat(current_fd)
            finally:
                os.close(current_fd)
            if not same_inode(opened, pin_info) or not same_inode(opened, current) \
                    or pin_info.st_nlink != 2 or current.st_nlink != 2:
                remove(directory_fd, pin)
                fail("publication staging entry changed while being pinned")
        else:
            if staging_info is None or not same_inode(pin_info, staging_info):
                fail("publication pin is not bound to its staging entry")
            opened_entry(directory_fd, pin, source_digest, (2,))
        try:
            atomic_rename(directory_fd, pin, name, False)
        except OSError as exc:
            if exc.errno != errno.EEXIST:
                raise
            rollback_no_clobber_conflict(
                directory_fd, name, staging, pin, source_digest, journal,
                journal_state, journal_digest
            )
            if conflict_is_error:
                raise SystemExit(2)
            return False
        target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        pin_info = None

    if not stat.S_ISREG(target_info.st_mode) or target_info.st_nlink not in (1, 2):
        fail(f"publication target is unsafe: {name}")
    opened_entry(directory_fd, name, source_digest, (1, 2))

    if pin_info is None:
        try:
            pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            pin_info = None
    if pin_info is None and staging_info is not None:
        try:
            atomic_rename(directory_fd, staging, pin, False)
        except OSError as exc:
            if exc.errno != errno.ENOENT:
                raise
        try:
            pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            pin_info = None
    if pin_info is not None:
        target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not same_inode(pin_info, target_info):
            try:
                atomic_rename(directory_fd, pin, staging, False)
            except OSError:
                pass
            fail("publication staging entry changed during commit")
        remove(directory_fd, pin)
    elif staging_info is not None:
        fail("publication staging entry changed during commit")

    opened_entry(directory_fd, name, source_digest, (1,))
    remove_entry(directory_fd, journal, journal_state, journal_digest)
    os.fsync(directory_fd)
    return True


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def process_start_identity(pid):
    if sys.platform.startswith("linux"):
        try:
            payload = open(f"/proc/{pid}/stat", "r", encoding="ascii").read()
            fields = payload.rsplit(")", 1)[1].split()
            return f"linux:{fields[19]}"
        except (OSError, IndexError, UnicodeError):
            return None
    try:
        output = subprocess.check_output(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return f"ps:{output.replace(' ', '_')}" if output else None


def lock_owner(directory_fd, name):
    try:
        lock_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise SystemExit(3)
        raise
    try:
        lock_info = os.fstat(lock_fd)
        entries = os.listdir(lock_fd)
        try:
            owner_fd = os.open(
                "owner",
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=lock_fd,
            )
        except FileNotFoundError:
            return lock_info, None, None, None, entries
        try:
            owner_info = os.fstat(owner_fd)
            if not stat.S_ISREG(owner_info.st_mode) or owner_info.st_nlink != 1 or owner_info.st_size > 512:
                fail(f"owned lock owner is unsafe: {name}/owner")
            try:
                payload = os.read(owner_fd, 513).decode("ascii", "strict")
            except UnicodeError:
                fail(f"owned lock owner is malformed: {name}/owner")
        finally:
            os.close(owner_fd)
        fields = payload.rstrip("\n").split("\t")
        if len(fields) not in (2, 3) or not fields[0].isdigit() or not valid_token(fields[1]):
            fail(f"owned lock owner is malformed: {name}/owner")
        owner_start = fields[2] if len(fields) == 3 else None
        if owner_start is not None and not valid_token(owner_start):
            fail(f"owned lock owner is malformed: {name}/owner")
        if sorted(entries) != ["owner"]:
            fail(f"owned lock contains unexpected entries: {name}")
        return lock_info, int(fields[0]), fields[1], owner_start, entries
    finally:
        os.close(lock_fd)


def create_lock(directory_fd, name, pid, token):
    candidate = f".{name}.candidate.{os.getpid()}.{secrets.token_hex(8)}"
    os.mkdir(candidate, 0o700, dir_fd=directory_fd)
    lock_fd = os.open(
        candidate,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    published = False
    try:
        owner_fd = os.open(
            "owner",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=lock_fd,
        )
        try:
            start_identity = process_start_identity(pid)
            if start_identity is None or not valid_token(start_identity):
                raise OSError(errno.ESRCH, "cannot identify lock owner process")
            payload = f"{pid}\t{token}\t{start_identity}\n".encode("ascii")
            if os.write(owner_fd, payload) != len(payload):
                raise OSError(errno.EIO, "short lock owner write")
            os.fsync(owner_fd)
        finally:
            os.close(owner_fd)
        os.fsync(lock_fd)
        try:
            atomic_rename(directory_fd, candidate, name, False)
        except OSError as exc:
            if exc.errno in (errno.EEXIST, errno.ENOTEMPTY):
                raise FileExistsError(exc.errno, exc.strerror)
            raise
        published = True
        os.fsync(directory_fd)
    finally:
        if not published:
            try:
                os.unlink("owner", dir_fd=lock_fd)
            except OSError:
                pass
        os.close(lock_fd)
        if not published:
            try:
                os.rmdir(candidate, dir_fd=directory_fd)
            except OSError:
                pass


def retire_lock(directory_fd, name, quarantine, expected_info):
    current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != (expected_info.st_dev, expected_info.st_ino):
        raise FileNotFoundError(name)
    os.rename(name, quarantine, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    retired = os.stat(quarantine, dir_fd=directory_fd, follow_symlinks=False)
    if (retired.st_dev, retired.st_ino) != (expected_info.st_dev, expected_info.st_ino):
        fail(f"owned lock changed during retirement: {name}")
    lock_fd = os.open(
        quarantine,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    try:
        entries = os.listdir(lock_fd)
        if entries not in (["owner"], []):
            fail(f"owned lock contains unexpected entries: {name}")
        if entries:
            os.unlink("owner", dir_fd=lock_fd)
    finally:
        os.close(lock_fd)
    os.rmdir(quarantine, dir_fd=directory_fd)


def lock_try(directory_fd, name, pid, token, stale_after):
    try:
        create_lock(directory_fd, name, pid, token)
        return
    except FileExistsError:
        pass
    details = lock_owner(directory_fd, name)
    if details is None:
        raise SystemExit(2)
    lock_info, owner_pid, owner_token, owner_start, entries = details
    if owner_pid == pid and owner_token == token:
        return
    owner_alive = owner_pid is not None and pid_alive(owner_pid)
    current_start = process_start_identity(owner_pid) if owner_alive else None
    if owner_alive and (owner_start is None or current_start is None or current_start == owner_start):
        raise SystemExit(2)
    if owner_pid is None and entries:
        raise SystemExit(2)
    age = time.time() - lock_info.st_mtime
    if age < stale_after:
        raise SystemExit(2)
    quarantine = f".{name}.retiring.{os.getpid()}.{secrets.token_hex(8)}"
    try:
        retire_lock(directory_fd, name, quarantine, lock_info)
    except FileNotFoundError:
        raise SystemExit(2)
    try:
        create_lock(directory_fd, name, pid, token)
    except FileExistsError:
        raise SystemExit(2)


def lock_held(directory_fd, name, pid, token):
    details = lock_owner(directory_fd, name)
    if details is None:
        fail(f"owned lock authorization is absent: {name}")
    _, owner_pid, owner_token, owner_start, _ = details
    if owner_pid != pid or owner_token != token:
        fail(f"owned lock authorization is mismatched: {name}")
    current_start = process_start_identity(owner_pid)
    if owner_start is None or current_start is None or current_start != owner_start:
        fail(f"owned lock authorization process is stale: {name}")


def lock_release(directory_fd, name, pid, token):
    details = lock_owner(directory_fd, name)
    if details is None:
        return
    _, owner_pid, owner_token, _, _ = details
    if owner_pid != pid or owner_token != token:
        return
    lock_fd = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    try:
        entries = os.listdir(lock_fd)
        if entries != ["owner"]:
            fail(f"owned lock contains unexpected entries: {name}")
        os.unlink("owner", dir_fd=lock_fd)
    finally:
        os.close(lock_fd)
    os.rmdir(name, dir_fd=directory_fd)
    os.fsync(directory_fd)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "describe-source":
        try:
            maximum = int(sys.argv[3])
        except ValueError:
            fail("publication source maximum size is malformed")
        if maximum < 0:
            fail("publication source maximum size is malformed")
        describe_source(sys.argv[2], maximum)
        return
    if len(sys.argv) == 4 and sys.argv[1] == "snapshot-path":
        try:
            maximum = int(sys.argv[3])
        except ValueError:
            fail("snapshot-path maximum size is malformed")
        if maximum < 0:
            fail("snapshot-path maximum size is malformed")
        snapshot_path(sys.argv[2], maximum)
        return
    if len(sys.argv) < 5:
        fail("usage: fm-work-identity-fs.py COMMAND DIRECTORY INODE NAME [ARG]")
    command, directory, expected, name = sys.argv[1:5]
    if not valid_name(name):
        fail("unsafe owned entry name")
    directory_fd = open_owned_dir(directory, expected)
    try:
        if command == "mkdir":
            try:
                os.mkdir(name, 0o700, dir_fd=directory_fd)
            except FileExistsError:
                raise SystemExit(2)
            info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            if not stat.S_ISDIR(info.st_mode):
                fail("created owned entry is not a directory")
            os.fsync(directory_fd)
            print(f"{info.st_dev}:{info.st_ino}")
        elif command == "probe":
            probe = f".{name}.{os.getpid()}.{secrets.token_hex(8)}"
            os.mkdir(probe, 0o700, dir_fd=directory_fd)
            os.rmdir(probe, dir_fd=directory_fd)
        elif command in ("describe", "describe-raw", "describe-digest", "describe-replace"):
            expected_size = None
            if command == "describe-digest" and len(sys.argv) == 6:
                try:
                    expected_size = int(sys.argv[5])
                except ValueError:
                    fail("owned destination expected size is malformed")
                if expected_size < 0:
                    fail("owned destination expected size is malformed")
            elif len(sys.argv) != 5:
                fail(f"{command} received unexpected arguments")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_no_clobber(directory_fd, name)
                recover_replace(directory_fd, name)
                recover_remove(directory_fd, name)
                if command == "describe":
                    print(entry_state(directory_fd, name))
                elif command == "describe-raw":
                    print(raw_entry_state(directory_fd, name))
                else:
                    state = entry_state(directory_fd, name)
                    if state == "absent":
                        if command == "describe-replace":
                            print("absent\t-")
                        else:
                            fail(f"owned destination is absent: {name}")
                    else:
                        print(f"{state}\t{file_digest(directory_fd, name, expected_size)}")
            finally:
                os.close(mutex_fd)
        elif command == "snapshot":
            if len(sys.argv) != 7:
                fail("snapshot requires expected source state and SHA-256")
            expected_state, expected_digest = sys.argv[5:7]
            if len(expected_digest) != 64 \
                    or any(char not in "0123456789abcdef" for char in expected_digest):
                fail("owned snapshot SHA-256 is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_no_clobber(directory_fd, name)
                recover_replace(directory_fd, name)
                recover_remove(directory_fd, name)
                read_exact(directory_fd, name, expected_state, expected_digest)
            finally:
                os.close(mutex_fd)
        elif command in ("remove", "remove-staging"):
            if len(sys.argv) not in (6, 7):
                fail(f"{command} requires expected destination state and optional SHA-256")
            expected_state = sys.argv[5]
            expected_digest = sys.argv[6] if len(sys.argv) == 7 else None
            if expected_digest is not None and (
                    len(expected_digest) != 64
                    or any(char not in "0123456789abcdef" for char in expected_digest)):
                fail("owned removal SHA-256 is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_no_clobber(directory_fd, name)
                recover_replace(directory_fd, name)
                if command == "remove-staging":
                    conditional_remove(
                        directory_fd,
                        name,
                        expected_state,
                        expected_digest,
                        allow_hardlink=True,
                    )
                else:
                    if expected_digest is None:
                        fail("owned removal requires a validated SHA-256")
                    remove_entry(directory_fd, name, expected_state, expected_digest)
            finally:
                os.close(mutex_fd)
        elif command in ("replace", "replace-if-peer"):
            if command == "replace" and len(sys.argv) != 10:
                fail("replace requires exact source and destination identities")
            if command == "replace-if-peer" and len(sys.argv) != 15:
                fail("replace-if-peer requires exact source, destination, and peer identities")
            source, expected_state, expected_digest, expected_source_state, expected_source_digest = sys.argv[5:10]
            if expected_state == "absent":
                if expected_digest != "-":
                    fail("absent replacement destination has a digest")
            elif len(expected_digest) != 64 \
                    or any(char not in "0123456789abcdef" for char in expected_digest):
                fail("replacement destination SHA-256 is malformed")
            peer_fd = None
            peer_mutex_fd = None
            mutex_fd = operation_lock(directory_fd, name)
            try:
                if command == "replace-if-peer":
                    peer_directory, peer_inode, peer_name, peer_state, peer_digest = sys.argv[10:15]
                    if not valid_name(peer_name) or len(peer_digest) != 64 \
                            or any(char not in "0123456789abcdef" for char in peer_digest):
                        fail("replacement peer identity is malformed")
                    peer_fd = open_owned_dir(peer_directory, peer_inode)
                    peer_mutex_fd = operation_lock(peer_fd, peer_name)
                    recover_no_clobber(peer_fd, peer_name)
                    recover_replace(peer_fd, peer_name)
                    recover_remove(peer_fd, peer_name)
                    if not exact_entry_matches(peer_fd, peer_name, peer_state, peer_digest):
                        fail(f"owned replacement peer changed before publication: {peer_name}")
                recover_no_clobber(directory_fd, name)
                recover_remove(directory_fd, name)
                replace_entry(
                    directory_fd, name, source, expected_state, expected_digest,
                    expected_source_state, expected_source_digest
                )
                if command == "replace-if-peer" \
                        and not exact_entry_matches(peer_fd, peer_name, peer_state, peer_digest):
                    fail(f"owned replacement peer changed during publication: {peer_name}")
            finally:
                if peer_mutex_fd is not None:
                    os.close(peer_mutex_fd)
                if peer_fd is not None:
                    os.close(peer_fd)
                os.close(mutex_fd)
        elif command == "no-clobber":
            if len(sys.argv) != 9:
                fail("no-clobber requires a staging name and exact source identity")
            source, staging, expected_source_state, expected_source_digest = sys.argv[5:9]
            if not valid_regular_commitment(expected_source_state, expected_source_digest):
                fail("publication source commitment is malformed")
            if not valid_name(staging) or not allowed_no_clobber_staging(name, staging):
                fail("unsafe publication staging name")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_replace(directory_fd, name)
                recover_remove(directory_fd, name)
                source_digest = expected_source_digest
                if recover_no_clobber(
                        directory_fd, name, staging, source_digest,
                        conflict_is_error=True):
                    return
                try:
                    staging_info = os.stat(staging, dir_fd=directory_fd, follow_symlinks=False)
                except FileNotFoundError:
                    staging_info = None
                try:
                    target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                except FileNotFoundError:
                    target_info = None
                if staging_info is not None:
                    if target_info is not None:
                        if not stat.S_ISREG(staging_info.st_mode) \
                                or not stat.S_ISREG(target_info.st_mode) \
                                or staging_info.st_nlink != 2 \
                                or target_info.st_nlink != 2 \
                                or not same_inode(staging_info, target_info):
                            fail("publication target conflicts with retained staging")
                        opened_entry(directory_fd, staging, source_digest, (2,))
                        opened_entry(directory_fd, name, source_digest, (2,))
                        remove(directory_fd, staging)
                        os.fsync(directory_fd)
                        return
                    opened_entry(directory_fd, staging, source_digest, (1,))
                else:
                    if target_info is not None:
                        raise SystemExit(2)
                    candidate = f".{staging}.copy-candidate.{secrets.token_hex(16)}"
                    try:
                        copied_state, copied_digest = copy_to_new(
                            source, directory_fd, candidate,
                            expected_source_state, expected_source_digest
                        )
                        if copied_state != expected_source_state \
                                or copied_digest != expected_source_digest:
                            fail("publication candidate does not match its source commitment")
                        atomic_rename(directory_fd, candidate, staging, False)
                    finally:
                        remove(directory_fd, candidate)
                    opened_entry(directory_fd, staging, source_digest, (1,))
                pin = f".{name}.no-clobber-pin.{secrets.token_hex(16)}"
                journal = f".{name}.no-clobber-journal"
                publish_no_clobber_journal(
                    directory_fd, journal, name, staging, pin, source_digest
                )
                recover_no_clobber(
                    directory_fd, name, staging, source_digest,
                    conflict_is_error=True
                )
            finally:
                os.close(mutex_fd)
        elif command == "lock-try":
            if len(sys.argv) != 8:
                fail("lock-try requires pid, token, and stale age")
            pid_text, token, stale_text = sys.argv[5:8]
            if not pid_text.isdigit() or not valid_token(token):
                fail("owned lock identity is malformed")
            try:
                stale_after = float(stale_text)
            except ValueError:
                fail("owned lock stale age is malformed")
            if stale_after < 0:
                fail("owned lock stale age is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                lock_try(directory_fd, name, int(pid_text), token, stale_after)
            finally:
                os.close(mutex_fd)
        elif command == "teardown-quarantine":
            if len(sys.argv) != 16:
                fail("teardown-quarantine requires receipt and final-record commitments")
            expected_state, expected_digest, transaction = sys.argv[5:8]
            records = tuple(sys.argv[8:16])
            if len(expected_digest) != 64 \
                    or any(char not in "0123456789abcdef" for char in expected_digest) \
                    or not valid_token(transaction) \
                    or not valid_name(records[2]) or not valid_name(records[5]) \
                    or not valid_regular_commitment(records[3], records[4]) \
                    or not valid_regular_commitment(records[6], records[7]):
                fail("teardown receipt commitment is malformed")
            state_fd = open_owned_dir(records[0], records[1])
            os.close(state_fd)
            mutex_fd = operation_lock(directory_fd, name)
            try:
                _, quarantine, _, _, _, _, _, _ = teardown_quarantine(
                    directory_fd, name, expected_state, expected_digest,
                    transaction, records
                )
                print(
                    f"{entry_state(directory_fd, quarantine)}"
                    f"\t{file_digest(directory_fd, quarantine)}"
                )
            finally:
                os.close(mutex_fd)
        elif command in (
                "teardown-state", "teardown-records-quarantine",
                "teardown-command-complete"):
            if len(sys.argv) != 6 or not valid_token(sys.argv[5]):
                fail(f"{command} requires a transaction")
            transaction = sys.argv[5]
            mutex_fd = operation_lock(directory_fd, name)
            try:
                if command == "teardown-state":
                    print(teardown_state(directory_fd, name, transaction))
                elif command == "teardown-records-quarantine":
                    loaded = read_teardown_journal(directory_fd, name)
                    if loaded is None or loaded[4] != "quarantined" \
                            or loaded[5] != transaction:
                        fail(f"owned teardown authorization is absent or mismatched: {name}")
                    teardown_quarantine_records(loaded)
                else:
                    teardown_command_complete(directory_fd, name, transaction)
            finally:
                os.close(mutex_fd)
        elif command in ("teardown-restore", "teardown-finalize"):
            if len(sys.argv) != 5:
                fail(f"{command} accepts no additional arguments")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                if command == "teardown-restore":
                    teardown_restore(directory_fd, name)
                else:
                    teardown_finalize(directory_fd, name)
            finally:
                os.close(mutex_fd)
        elif command in ("lock-held", "lock-release"):
            if len(sys.argv) != 7:
                fail(f"{command} requires pid and token")
            pid_text, token = sys.argv[5:7]
            if not pid_text.isdigit() or not valid_token(token):
                fail("owned lock identity is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                if command == "lock-held":
                    lock_held(directory_fd, name, int(pid_text), token)
                else:
                    lock_release(directory_fd, name, int(pid_text), token)
            finally:
                os.close(mutex_fd)
        else:
            fail(f"unknown command: {command}")
    except OSError as exc:
        if exc.errno == errno.EEXIST and command == "no-clobber":
            raise SystemExit(2)
        fail(f"owned {command} failed for {directory}/{name}: {exc.strerror}")
    finally:
        os.close(directory_fd)


if __name__ == "__main__":
    main()
