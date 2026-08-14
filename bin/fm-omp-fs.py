#!/usr/bin/env python3
import os
import stat
import sys
import ctypes
import errno
import time
import uuid


READ_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
FILE_READ_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
FILE_WRITE_FLAGS = os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0)


def identity(value):
    return f"{value.st_dev}:{value.st_ino}"


def require_name(name):
    if not name or "/" in name or name in {".", ".."}:
        raise ValueError("invalid entry name")


def open_directory(path, expected):
    fd = os.open(path, READ_FLAGS)
    try:
        value = os.fstat(fd)
        if not stat.S_ISDIR(value.st_mode):
            raise ValueError("not a directory")
        if expected and identity(value) != expected:
            raise ValueError("directory identity changed")
        return fd
    except Exception:
        os.close(fd)
        raise


def regular_entry(fd, name, expected=""):
    require_name(name)
    value = os.stat(name, dir_fd=fd, follow_symlinks=False)
    if not stat.S_ISREG(value.st_mode):
        raise ValueError("not a regular file")
    if expected and identity(value) != expected:
        raise ValueError("entry identity changed")
    return value


def directory_entry(fd, name, expected=""):
    require_name(name)
    value = os.stat(name, dir_fd=fd, follow_symlinks=False)
    if not stat.S_ISDIR(value.st_mode):
        raise ValueError("not a directory")
    if expected and identity(value) != expected:
        raise ValueError("entry identity changed")
    return value


def read_regular_bytes(fd, name, expected=""):
    value = regular_entry(fd, name, expected)
    child = os.open(name, FILE_READ_FLAGS, dir_fd=fd)
    try:
        opened = os.fstat(child)
        if identity(opened) != identity(value):
            raise ValueError("entry identity changed")
        content = b""
        while True:
            chunk = os.read(child, 65536)
            if not chunk:
                break
            content += chunk
        return value, content
    finally:
        os.close(child)


def exchange(fd, left, right):
    library = ctypes.CDLL(None, use_errno=True)
    function = getattr(library, "renameatx_np", None)
    if function is None:
        function = getattr(library, "renameat2", None)
    if function is None:
        raise OSError(errno.ENOTSUP, "atomic exchange is unavailable")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    flags = 2
    if function(fd, left.encode(), fd, right.encode(), flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def temporary_name(prefix):
    return f".firstmate-{prefix}-{os.getpid()}-{uuid.uuid4().hex}"


def removal_test_pause():
    gate = os.environ.get("FM_OMP_FS_REMOVE_GATE")
    if not gate:
        return
    with open(gate + ".ready", "w", encoding="utf-8"):
        pass
    while os.path.exists(gate + ".hold"):
        time.sleep(0.01)


def remove_file(parent, name, expected_parent, expected_entry):
    fd = open_directory(parent, expected_parent)
    placeholder = temporary_name("remove")
    placeholder_created = False
    placeholder_identity = ""
    exchanged = False
    try:
        regular_entry(fd, name, expected_entry)
        child = os.open(placeholder, FILE_WRITE_FLAGS | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=fd)
        try:
            value = os.fstat(child)
            if not stat.S_ISREG(value.st_mode):
                raise ValueError("not a regular placeholder")
            placeholder_identity = identity(value)
        finally:
            os.close(child)
        placeholder_created = True
        exchange(fd, placeholder, name)
        exchanged = True
        swapped = regular_entry(fd, placeholder)
        replacement = regular_entry(fd, name)
        if identity(swapped) != expected_entry or identity(replacement) != placeholder_identity:
            raise ValueError("entry changed during removal")
        removal_test_pause()
        regular_entry(fd, name, placeholder_identity)
        regular_entry(fd, placeholder, expected_entry)
        os.unlink(name, dir_fd=fd)
        regular_entry(fd, placeholder, expected_entry)
        os.unlink(placeholder, dir_fd=fd)
        exchanged = False
    finally:
        if exchanged:
            try:
                swapped = regular_entry(fd, placeholder)
                replacement = regular_entry(fd, name)
                if identity(swapped) == expected_entry and identity(replacement) == placeholder_identity:
                    exchange(fd, placeholder, name)
            except OSError:
                pass
        if placeholder_created:
            try:
                if identity(regular_entry(fd, placeholder)) == placeholder_identity:
                    os.unlink(placeholder, dir_fd=fd)
            except FileNotFoundError:
                pass
            except (OSError, ValueError):
                pass
        os.close(fd)


def remove_directory(parent, name, expected_parent, expected_entry):
    fd = open_directory(parent, expected_parent)
    temporary = temporary_name("rmdir")
    temporary_created = False
    exchanged = False
    temporary_identity = ""
    try:
        directory_entry(fd, name, expected_entry)
        child = os.open(name, READ_FLAGS, dir_fd=fd)
        try:
            if os.listdir(child):
                raise ValueError("directory is not empty")
        finally:
            os.close(child)
        os.mkdir(temporary, 0o700, dir_fd=fd)
        temporary_created = True
        temporary_identity = identity(directory_entry(fd, temporary))
        exchange(fd, temporary, name)
        exchanged = True
        swapped = directory_entry(fd, temporary)
        replacement = directory_entry(fd, name)
        if identity(swapped) != expected_entry or identity(replacement) != temporary_identity:
            raise ValueError("directory changed during removal")
        removal_test_pause()
        directory_entry(fd, name, temporary_identity)
        directory_entry(fd, temporary, expected_entry)
        os.rmdir(name, dir_fd=fd)
        directory_entry(fd, temporary, expected_entry)
        os.rmdir(temporary, dir_fd=fd)
        exchanged = False
    finally:
        if exchanged:
            try:
                swapped = directory_entry(fd, temporary)
                replacement = directory_entry(fd, name)
                if identity(swapped) == expected_entry and identity(replacement) == temporary_identity:
                    exchange(fd, temporary, name)
            except OSError:
                pass
        if temporary_created:
            try:
                directory_entry(fd, temporary, temporary_identity)
                os.rmdir(temporary, dir_fd=fd)
            except FileNotFoundError:
                pass
            except (OSError, ValueError):
                pass
        os.close(fd)


def remove_owned_lock(parent, name, expected_parent, expected_lock, expected_owner, process_id, token):
    state_fd = open_directory(parent, expected_parent)
    lock_fd = -1
    owner_identity = ""
    orphan_name = ""
    try:
        directory_entry(state_fd, name, expected_lock)
        lock_fd = os.open(name, READ_FLAGS, dir_fd=state_fd)
        lock_value = os.fstat(lock_fd)
        if not stat.S_ISDIR(lock_value.st_mode) or identity(lock_value) != expected_lock:
            raise ValueError("lock identity changed")
        try:
            owner_value, owner_content = read_regular_bytes(lock_fd, "owner")
        except FileNotFoundError:
            owner_value = None
            owner_content = b""
        if owner_value is None:
            entries = os.listdir(lock_fd)
            if not entries:
                lock_identity = identity(lock_value)
            elif len(entries) == 1 and entries[0].startswith(".firstmate-remove-"):
                orphan_name = entries[0]
                orphan_value, orphan_content = read_regular_bytes(lock_fd, orphan_name)
                if orphan_content != f"{process_id} {token}\n".encode():
                    raise ValueError("lock ownership changed")
                lock_identity = identity(lock_value)
                owner_identity = identity(orphan_value)
            else:
                raise ValueError("lock ownership changed")
        elif owner_content == f"{process_id} {token}\n".encode():
            if expected_owner and identity(owner_value) != expected_owner:
                raise ValueError("owner identity changed")
            lock_identity = identity(lock_value)
            owner_identity = identity(owner_value)
        elif owner_content == b"":
            entries = os.listdir(lock_fd)
            orphan_entries = [entry for entry in entries if entry.startswith(".firstmate-remove-")]
            if len(entries) != 2 or len(orphan_entries) != 1 or set(entries) != {"owner", orphan_entries[0]}:
                raise ValueError("lock ownership changed")
            orphan_name = orphan_entries[0]
            orphan_value, orphan_content = read_regular_bytes(lock_fd, orphan_name)
            if orphan_content != f"{process_id} {token}\n".encode():
                raise ValueError("lock ownership changed")
            lock_identity = identity(lock_value)
            owner_identity = identity(owner_value)
            orphan_identity = identity(orphan_value)
        else:
            raise ValueError("lock ownership changed")
    finally:
        if lock_fd >= 0:
            os.close(lock_fd)
        os.close(state_fd)
    if orphan_name:
        if owner_value is not None:
            remove_file(os.path.join(parent, name), "owner", lock_identity, owner_identity)
            remove_file(os.path.join(parent, name), orphan_name, lock_identity, orphan_identity)
        else:
            remove_file(os.path.join(parent, name), orphan_name, lock_identity, owner_identity)
    elif owner_identity:
        remove_file(os.path.join(parent, name), "owner", lock_identity, owner_identity)
    remove_directory(parent, name, expected_parent, expected_lock)


def snapshot_lock(parent, name, expected_parent):
    state_fd = open_directory(parent, expected_parent)
    lock_fd = -1
    try:
        lock_value = directory_entry(state_fd, name)
        lock_fd = os.open(name, READ_FLAGS, dir_fd=state_fd)
        opened_lock = os.fstat(lock_fd)
        if identity(opened_lock) != identity(lock_value):
            raise ValueError("lock identity changed")
        try:
            owner_value, content = read_regular_bytes(lock_fd, "owner")
        except FileNotFoundError:
            owner_value = None
            content = b""
        if owner_value is None:
            entries = os.listdir(lock_fd)
            if not entries:
                sys.stdout.write(" ".join((identity(os.fstat(state_fd)), identity(opened_lock),
                                           "orphan", "-", "-")) + "\n")
                return
            if len(entries) != 1 or not entries[0].startswith(".firstmate-remove-"):
                raise ValueError("lock owner is unavailable")
            orphan_name = entries[0]
            orphan_value, content = read_regular_bytes(lock_fd, orphan_name)
            fields = content.decode().strip().split()
            if len(fields) != 2 or not fields[0].isdigit() or not fields[1]:
                raise ValueError("lock owner is malformed")
            sys.stdout.write(" ".join((identity(os.fstat(state_fd)), identity(opened_lock),
                                       "orphan", fields[0], fields[1])) + "\n")
            return
        fields = content.decode().strip().split()
        if len(fields) == 2 and fields[0].isdigit() and fields[1]:
            sys.stdout.write(" ".join((identity(os.fstat(state_fd)), identity(opened_lock),
                                       identity(owner_value), fields[0], fields[1])) + "\n")
            return
        entries = os.listdir(lock_fd)
        orphan_entries = [entry for entry in entries if entry.startswith(".firstmate-remove-")]
        if content != b"" or len(entries) != 2 or len(orphan_entries) != 1 or set(entries) != {"owner", orphan_entries[0]}:
            raise ValueError("lock owner is malformed")
        _, orphan_content = read_regular_bytes(lock_fd, orphan_entries[0])
        fields = orphan_content.decode().strip().split()
        if len(fields) != 2 or not fields[0].isdigit() or not fields[1]:
            raise ValueError("lock owner is unavailable")
        sys.stdout.write(" ".join((identity(os.fstat(state_fd)), identity(opened_lock),
                                   "orphan", fields[0], fields[1])) + "\n")
    finally:
        if lock_fd >= 0:
            os.close(lock_fd)
        os.close(state_fd)


def create_file(parent, name, expected_parent):
    fd = open_directory(parent, expected_parent)
    try:
        require_name(name)
        child = os.open(name, FILE_WRITE_FLAGS | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=fd)
        try:
            value = os.fstat(child)
            if not stat.S_ISREG(value.st_mode):
                raise ValueError("not a regular file")
            sys.stdout.write(identity(value) + "\n")
        finally:
            os.close(child)
    finally:
        os.close(fd)


def write_file(parent, name, expected_parent, expected_entry):
    fd = open_directory(parent, expected_parent)
    child = -1
    try:
        regular_entry(fd, name, expected_entry)
        child = os.open(name, FILE_WRITE_FLAGS, dir_fd=fd)
        value = os.fstat(child)
        if not stat.S_ISREG(value.st_mode) or (expected_entry and identity(value) != expected_entry):
            raise ValueError("entry identity changed")
        data = sys.stdin.buffer.read()
        offset = 0
        while offset < len(data):
            offset += os.write(child, data[offset:])
        os.ftruncate(child, len(data))
    finally:
        if child >= 0:
            os.close(child)
        os.close(fd)


def append_file(parent, name, expected_parent, expected_entry):
    fd = open_directory(parent, expected_parent)
    child = -1
    try:
        regular_entry(fd, name, expected_entry)
        child = os.open(name, FILE_WRITE_FLAGS | os.O_APPEND, dir_fd=fd)
        value = os.fstat(child)
        if not stat.S_ISREG(value.st_mode) or (expected_entry and identity(value) != expected_entry):
            raise ValueError("entry identity changed")
        data = sys.stdin.buffer.read()
        offset = 0
        while offset < len(data):
            offset += os.write(child, data[offset:])
    finally:
        if child >= 0:
            os.close(child)
        os.close(fd)


def identity_file(parent, name, expected_parent):
    fd = open_directory(parent, expected_parent)
    child = -1
    try:
        require_name(name)
        child = os.open(name, FILE_READ_FLAGS, dir_fd=fd)
        value = os.fstat(child)
        if not stat.S_ISREG(value.st_mode):
            raise ValueError("not a regular file")
        sys.stdout.write(identity(value) + "\n")
    finally:
        if child >= 0:
            os.close(child)
        os.close(fd)


def replace_file(parent, source, expected_parent, expected_source, target, expected_target):
    fd = open_directory(parent, expected_parent)
    exchanged = False
    try:
        regular_entry(fd, source, expected_source)
        require_name(target)
        try:
            target_value = os.stat(target, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            target_value = None
        if target_value is None:
            if expected_target:
                raise ValueError("replacement target disappeared")
            os.link(source, target, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
            regular_entry(fd, target, expected_source)
            regular_entry(fd, source, expected_source)
            os.unlink(source, dir_fd=fd)
            return
        if not stat.S_ISREG(target_value.st_mode) or not expected_target:
            raise ValueError("replacement target is not the expected regular file")
        if identity(target_value) != expected_target:
            raise ValueError("replacement target identity changed")
        exchange(fd, source, target)
        exchanged = True
        replacement = regular_entry(fd, target)
        swapped = regular_entry(fd, source)
        if identity(replacement) != expected_source or identity(swapped) != expected_target:
            raise ValueError("replacement target changed during commit")
        removal_test_pause()
        regular_entry(fd, target, expected_source)
        regular_entry(fd, source, expected_target)
        os.unlink(source, dir_fd=fd)
        exchanged = False
    finally:
        if exchanged:
            try:
                replacement = os.stat(target, dir_fd=fd, follow_symlinks=False)
                swapped = os.stat(source, dir_fd=fd, follow_symlinks=False)
                if identity(replacement) == expected_source and identity(swapped) == expected_target:
                    exchange(fd, source, target)
            except (OSError, ValueError):
                pass
        os.close(fd)


def read_file(parent, name, expected_parent):
    fd = open_directory(parent, expected_parent)
    child = -1
    try:
        require_name(name)
        child = os.open(name, FILE_READ_FLAGS, dir_fd=fd)
        value = os.fstat(child)
        if not stat.S_ISREG(value.st_mode):
            raise ValueError("not a regular file")
        while True:
            data = os.read(child, 65536)
            if not data:
                break
            sys.stdout.buffer.write(data)
    finally:
        if child >= 0:
            os.close(child)
        os.close(fd)


def list_directory(path, expected):
    fd = open_directory(path, expected)
    try:
        for name in sorted(os.listdir(fd)):
            if "\n" in name or "\r" in name:
                raise ValueError("invalid directory entry")
            sys.stdout.write(name + "\n")
    finally:
        os.close(fd)


def main():
    command = sys.argv[1]
    args = sys.argv[2:]
    if command == "remove-file" and len(args) == 4:
        remove_file(*args)
    elif command == "remove-directory" and len(args) == 4:
        remove_directory(*args)
    elif command == "remove-lock" and len(args) == 7:
        remove_owned_lock(*args)
    elif command == "snapshot-lock" and len(args) == 3:
        snapshot_lock(*args)
    elif command == "create-file" and len(args) == 3:
        create_file(*args)
    elif command == "write-file" and len(args) == 4:
        write_file(*args)
    elif command == "append-file" and len(args) == 4:
        append_file(*args)
    elif command == "identity-file" and len(args) == 3:
        identity_file(*args)
    elif command == "replace-file" and len(args) == 6:
        replace_file(*args)
    elif command == "read-file" and len(args) == 3:
        read_file(*args)
    elif command == "list-directory" and len(args) == 2:
        list_directory(*args)
    else:
        raise ValueError("invalid arguments")


try:
    main()
except FileExistsError:
    raise SystemExit(17)
except (OSError, ValueError, IndexError):
    raise SystemExit(1)
