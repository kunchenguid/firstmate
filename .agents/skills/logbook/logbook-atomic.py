#!/usr/bin/env python3
import errno
import os
import stat
import sys


class Exists(Exception):
    pass


def die():
    raise SystemExit(1)


def parts(value):
    result = value.split("/")
    if not result or any(not item or item in (".", "..") for item in result):
        die()
    return result


def open_directory(home, components):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(home, flags)
    try:
        for component in components:
            next_fd = os.open(component, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def parent_and_name(home, relative):
    components = parts(relative)
    if len(components) < 2:
        die()
    return open_directory(home, components[:-1]), components[-1]


def read(home, relative):
    parent, name = parent_and_name(home, relative)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                die()
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
        finally:
            os.close(fd)
    finally:
        os.close(parent)


def publish(home, relative):
    parent, name = parent_and_name(home, relative)
    temporary = f".{name}.{os.getpid()}.{os.urandom(8).hex()}.tmp"
    fd = None
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        while chunk := sys.stdin.buffer.read(65536):
            offset = 0
            while offset < len(chunk):
                offset += os.write(fd, chunk[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.rename(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    except BaseException:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(temporary, dir_fd=parent)
        except OSError:
            pass
        raise
    finally:
        os.close(parent)


def remove(home, relative):
    parent, name = parent_and_name(home, relative)
    try:
        os.unlink(name, dir_fd=parent)
        os.fsync(parent)
    finally:
        os.close(parent)


def create_directory(home, relative):
    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in parts(relative):
            try:
                os.mkdir(component, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        os.fsync(fd)
    finally:
        os.close(fd)


def claim_directory(home, relative):
    parent, name = parent_and_name(home, relative)
    temporary = f".{name}.{os.getpid()}.{os.urandom(8).hex()}.tmp"
    lock_fd = None
    owner_fd = None
    try:
        os.mkdir(temporary, 0o700, dir_fd=parent)
        lock_fd = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        owner_fd = os.open("owner.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=lock_fd)
        while chunk := sys.stdin.buffer.read(65536):
            offset = 0
            while offset < len(chunk):
                offset += os.write(owner_fd, chunk[offset:])
        os.fsync(owner_fd)
        os.close(owner_fd)
        owner_fd = None
        os.fsync(lock_fd)
        os.close(lock_fd)
        lock_fd = None
        try:
            os.rename(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
        except OSError as error:
            if error.errno in (errno.EEXIST, errno.ENOTEMPTY):
                raise Exists() from error
            raise
        os.fsync(parent)
    except BaseException:
        if owner_fd is not None:
            os.close(owner_fd)
        if lock_fd is not None:
            os.close(lock_fd)
        temporary_fd = None
        try:
            temporary_fd = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.unlink("owner.json", dir_fd=temporary_fd)
        except OSError:
            pass
        finally:
            if temporary_fd is not None:
                os.close(temporary_fd)
        try:
            os.rmdir(temporary, dir_fd=parent)
        except OSError:
            pass
        raise
    finally:
        os.close(parent)


if len(sys.argv) != 4:
    die()

command, home, relative = sys.argv[1:]
try:
    if command == "read":
        read(home, relative)
    elif command == "publish":
        publish(home, relative)
    elif command == "remove":
        remove(home, relative)
    elif command == "mkdir":
        create_directory(home, relative)
    elif command == "claim":
        claim_directory(home, relative)
    else:
        die()
except Exists:
    raise SystemExit(17)
except (OSError, ValueError):
    die()
