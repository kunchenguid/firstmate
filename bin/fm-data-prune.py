#!/usr/bin/env python3
import json
import os
import stat
import sys


LIMIT = 1024 * 1024
RECORD_SUFFIXES = (".md", ".txt", ".log", ".status", ".json", ".jsonl", ".yaml", ".yml", ".toml")
RECORD_NAMES = {"status", "log", "logs", "stdout", "stderr"}
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def scratch(parent, name, info):
    lower = name.lower()
    if lower in RECORD_NAMES or lower.endswith(RECORD_SUFFIXES) or ".log." in lower or ".status." in lower:
        return False
    if info.st_size >= LIMIT:
        return True
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    with os.fdopen(fd, "rb") as stream:
        current = os.fstat(stream.fileno())
        if not stat.S_ISREG(current.st_mode) or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
            raise OSError("file changed during selection")
        data = stream.read(LIMIT)
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return True
    return b"\0" in data


def collect(directory, prefix=()):
    result = []
    for name in sorted(os.listdir(directory)):
        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            if name.lower() in RECORD_NAMES:
                continue
            child = os.open(name, DIRECTORY_FLAGS, dir_fd=directory)
            try:
                result.extend(collect(child, (*prefix, name)))
            finally:
                os.close(child)
        elif stat.S_ISREG(info.st_mode) and scratch(directory, name, info):
            result.append(((*prefix, name), info))
    return result


def remove_file(root, parts, expected):
    parent = os.dup(root)
    try:
        for part in parts[:-1]:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=parent)
            os.close(parent)
            parent = child
        current = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(current.st_mode) or fingerprint(current) != fingerprint(expected):
            raise OSError("file changed since preview")
        os.unlink(parts[-1], dir_fd=parent)
    finally:
        os.close(parent)


def fingerprint(info):
    return info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def main():
    data, task, confirm = sys.argv[1:]
    data_fd = os.open(data, DIRECTORY_FLAGS)
    try:
        root = os.open(task, DIRECTORY_FLAGS, dir_fd=data_fd)
    finally:
        os.close(data_fd)
    try:
        files = collect(root)
        total = sum(info.st_size for _, info in files)
        if total < LIMIT:
            files, total = [], 0
        print(f"  - id: {json.dumps(task)}")
        print(f"    bytes: {total}")
        print(f"    files[{len(files)}]{{path,bytes}}:")
        for parts, info in files:
            print(f"      {json.dumps('/'.join(parts))},{info.st_size}")
        if confirm == "1":
            for parts, info in files:
                remove_file(root, parts, info)
            print(f"    removed_bytes: {total}")
    finally:
        os.close(root)


if __name__ == "__main__":
    try:
        main()
    except OSError as error:
        print(f"error: {json.dumps(str(error))}")
        sys.exit(1)
