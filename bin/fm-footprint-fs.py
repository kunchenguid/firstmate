#!/usr/bin/env python3
"""Descriptor-safe filesystem engine for fm-footprint.sh's removal boundary.

The shell script owns which set-aside copies are candidates, the process
check, the content check, and every message. This helper owns the steps that
must be bound to the objects that were verified rather than to path text:

  freeze <record> <root>...
      Removes every write bit under each root, directory by directory, never
      following a link: each entry is opened relative to its already opened
      parent with O_NOFOLLOW and checked to be the object just listed before
      its mode changes. A directory is frozen before its entries are listed,
      so its set of names cannot change afterwards. A non-directory with more
      than one link is never changed (its mode belongs to every other name
      too), and the whole root is reported "linked" and left as it was.
      Appends "dev ino mode" for every changed object to <record>, and prints
      "root<TAB>ok" or "root<TAB><reason>" per root; a root that fails part
      way is thawed again from what this run changed.
  snapshot <root>...
      Prints one line per entry, "root<TAB>type<TAB>mode<TAB>dev<TAB>ino<TAB>
      size<TAB>blocks<TAB>mtime_ns<TAB>ctime_ns<TAB>nlink<TAB>relpath", the
      root itself as ".", or a single "root<TAB>!<TAB><reason>" line for a
      root that could not be read in full.
  thaw <record> <root>...
      Gives every object under each root whose identity is in <record> its
      recorded mode back, by descriptor, never following a link.
  remove <snapshot> <record> <root>...
      Removes, for each root, exactly the entries <snapshot> lists for it:
      it opens the root relative to its parent and checks it is the
      snapshotted directory, then walks down by descriptor. Each directory
      gets its write bit back only when its own entries are about to go;
      each listed entry is checked (device, inode, type, size, times, links)
      against the snapshot and unlinked by name in that directory. Anything
      that does not match, or is not listed, stays, and so does every
      directory above it, with the recorded modes restored. Prints
      "root<TAB>removed<TAB>kb" or "root<TAB>partial<TAB>kb".

Exit status 0 means every requested line was written; 2 is a usage error and
3 a failed write of <record> or the output, which the caller treats as keep.
FM_FOOTPRINT_TEST_REMOVE_HOOK names a program the test suites run with the
root and the relative directory each time remove has just made a directory
writable, to interleave a change at exactly that point.
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys

DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0)
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
FILE_FLAGS = os.O_RDONLY | NOFOLLOW | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOCTTY", 0) | getattr(os, "O_CLOEXEC", 0)
WRITE_BITS = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH


class Keep(Exception):
    """A root cannot be handled in full; the reason is the message."""


def type_char(mode: int) -> str:
    if stat.S_ISDIR(mode):
        return "d"
    if stat.S_ISREG(mode):
        return "f"
    if stat.S_ISLNK(mode):
        return "l"
    if stat.S_ISFIFO(mode):
        return "p"
    if stat.S_ISSOCK(mode):
        return "s"
    if stat.S_ISCHR(mode):
        return "c"
    if stat.S_ISBLK(mode):
        return "b"
    return "?"


def safe_name(name: str) -> bool:
    if name in ("", ".", "..") or "/" in name or "\\" in name:
        return False
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in name):
        return False
    try:
        name.encode("utf-8", "strict")
    except UnicodeEncodeError:
        return False
    return True


def same(a: os.stat_result, b: os.stat_result) -> bool:
    return a.st_dev == b.st_dev and a.st_ino == b.st_ino and stat.S_IFMT(a.st_mode) == stat.S_IFMT(b.st_mode)


def open_root(root: str) -> tuple[int, int, os.stat_result]:
    """Opens <root>'s parent by path and <root> by name within it."""
    parent, name = os.path.split(root.rstrip("/"))
    if not parent or not safe_name(name):
        raise Keep("unsafe")
    pfd = os.open(parent, DIR_FLAGS)
    try:
        before = os.stat(name, dir_fd=pfd, follow_symlinks=False)
        if not stat.S_ISDIR(before.st_mode):
            raise Keep("unreadable")
        fd = os.open(name, DIR_FLAGS | NOFOLLOW, dir_fd=pfd)
    except BaseException:
        os.close(pfd)
        raise
    st = os.fstat(fd)
    if not same(st, before):
        os.close(fd)
        os.close(pfd)
        raise Keep("unreadable")
    return pfd, fd, st


def names(fd: int) -> list[str]:
    with os.scandir(fd) as it:
        result = [entry.name for entry in it]
    for name in result:
        if not safe_name(name):
            raise Keep("unsafe")
    return sorted(result)


def open_child(fd: int, name: str, expect: os.stat_result) -> int:
    flags = DIR_FLAGS | NOFOLLOW if stat.S_ISDIR(expect.st_mode) else FILE_FLAGS
    child = os.open(name, flags, dir_fd=fd)
    if not same(os.fstat(child), expect):
        os.close(child)
        raise Keep("frozen")
    return child


# --- freeze and thaw ----------------------------------------------------------


def freeze_root(root: str, seen: list[tuple[int, int, int]]) -> None:
    """Freezes <root>, appending every directory and singly linked file it
    visits, with its mode before the freeze, to <seen>."""
    pfd, fd, st = open_root(root)
    os.close(pfd)
    root_dev = st.st_dev

    def chmod_fd(cfd: int, cst: os.stat_result) -> None:
        mode = stat.S_IMODE(cst.st_mode)
        seen.append((cst.st_dev, cst.st_ino, mode))
        if mode & WRITE_BITS:
            os.fchmod(cfd, mode & ~WRITE_BITS)

    def walk(dfd: int, dst: os.stat_result) -> None:
        chmod_fd(dfd, dst)
        for name in names(dfd):
            cst = os.stat(name, dir_fd=dfd, follow_symlinks=False)
            if cst.st_dev != root_dev:
                raise Keep("mount")
            if stat.S_ISDIR(cst.st_mode):
                cfd = open_child(dfd, name, cst)
                try:
                    walk(cfd, os.fstat(cfd))
                finally:
                    os.close(cfd)
            elif cst.st_nlink > 1:
                raise Keep("linked")
            elif stat.S_ISREG(cst.st_mode):
                cfd = open_child(dfd, name, cst)
                try:
                    now = os.fstat(cfd)
                    if now.st_nlink > 1:
                        raise Keep("linked")
                    chmod_fd(cfd, now)
                finally:
                    os.close(cfd)
            # Links, sockets, FIFOs and devices hold no content to protect;
            # their own modes are never changed.

    try:
        walk(fd, st)
    finally:
        os.close(fd)


def read_record(path: str) -> dict[tuple[int, int], int]:
    modes: dict[tuple[int, int], int] = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) != 3:
                raise ValueError("malformed record")
            modes[(int(parts[0]), int(parts[1]))] = int(parts[2], 8)
    return modes


def thaw_root(root: str, modes: dict[tuple[int, int], int]) -> bool:
    ok = True
    try:
        pfd, fd, st = open_root(root)
    except (OSError, Keep):
        return False
    os.close(pfd)

    def restore(cfd: int, cst: os.stat_result) -> None:
        nonlocal ok
        want = modes.get((cst.st_dev, cst.st_ino))
        if want is not None and stat.S_IMODE(cst.st_mode) != want:
            try:
                os.fchmod(cfd, want)
            except OSError:
                ok = False

    def walk(dfd: int, dst: os.stat_result) -> None:
        nonlocal ok
        try:
            entries = names(dfd)
        except (OSError, Keep):
            ok = False
            entries = []
        for name in entries:
            try:
                cst = os.stat(name, dir_fd=dfd, follow_symlinks=False)
                if not (stat.S_ISDIR(cst.st_mode) or stat.S_ISREG(cst.st_mode)):
                    continue
                if (cst.st_dev, cst.st_ino) not in modes and not stat.S_ISDIR(cst.st_mode):
                    continue
                cfd = open_child(dfd, name, cst)
            except (OSError, Keep):
                ok = False
                continue
            try:
                if stat.S_ISDIR(cst.st_mode):
                    walk(cfd, os.fstat(cfd))
                restore(cfd, os.fstat(cfd))
            finally:
                os.close(cfd)
        restore(dfd, dst)

    try:
        walk(fd, st)
    finally:
        os.close(fd)
    return ok


# --- snapshot -----------------------------------------------------------------


def snapshot_root(root: str) -> list[str]:
    lines: list[str] = []
    pfd, fd, st = open_root(root)
    os.close(pfd)
    root_dev = st.st_dev

    def line(rel: str, cst: os.stat_result) -> str:
        return "\t".join((root, type_char(cst.st_mode), f"{stat.S_IMODE(cst.st_mode):o}", str(cst.st_dev),
                          str(cst.st_ino), str(cst.st_size), str(getattr(cst, "st_blocks", 0)),
                          str(cst.st_mtime_ns), str(cst.st_ctime_ns), str(cst.st_nlink), rel))

    def walk(dfd: int, dst: os.stat_result, rel: str) -> None:
        lines.append(line(rel, dst))
        for name in names(dfd):
            cst = os.stat(name, dir_fd=dfd, follow_symlinks=False)
            if cst.st_dev != root_dev:
                raise Keep("mount")
            crel = name if rel == "." else rel + "/" + name
            if stat.S_ISDIR(cst.st_mode):
                cfd = open_child(dfd, name, cst)
                try:
                    walk(cfd, os.fstat(cfd), crel)
                finally:
                    os.close(cfd)
            else:
                lines.append(line(crel, cst))

    try:
        walk(fd, st, ".")
    finally:
        os.close(fd)
    return lines


# --- remove -------------------------------------------------------------------


def read_snapshot(path: str, roots: set[str]) -> dict[str, dict[str, list[str]]]:
    snap: dict[str, dict[str, list[str]]] = {}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            fields = raw.rstrip("\n").split("\t")
            if len(fields) != 11 or fields[0] not in roots:
                continue
            snap.setdefault(fields[0], {})[fields[10]] = fields[1:10]
    return snap


def matches(cst: os.stat_result, want: list[str], content: bool) -> bool:
    kind, _mode, dev, ino, size, _blocks, mtime, ctime, nlink = want
    if type_char(cst.st_mode) != kind or str(cst.st_dev) != dev or str(cst.st_ino) != ino:
        return False
    if not content:
        return True
    return (str(cst.st_size) == size and str(cst.st_mtime_ns) == mtime and str(cst.st_ctime_ns) == ctime
            and str(cst.st_nlink) == nlink)


def run_hook(root: str, rel: str) -> None:
    hook = os.environ.get("FM_FOOTPRINT_TEST_REMOVE_HOOK", "")
    if hook:
        subprocess.run([hook, root, rel], check=False, stdin=subprocess.DEVNULL)


def remove_root(root: str, entries: dict[str, list[str]]) -> tuple[bool, int]:
    removed_blocks = 0
    children: dict[str, list[str]] = {}
    for rel in entries:
        if rel != ".":
            parent = rel.rsplit("/", 1)[0] if "/" in rel else "."
            children.setdefault(parent, []).append(rel)
    top = entries.get(".")
    if top is None or top[0] != "d":
        return False, 0
    parent, name = os.path.split(root.rstrip("/"))
    pfd = os.open(parent, DIR_FLAGS)
    try:
        before = os.stat(name, dir_fd=pfd, follow_symlinks=False)
        if not matches(before, top, True):
            return False, 0
        fd = os.open(name, DIR_FLAGS | NOFOLLOW, dir_fd=pfd)
        if not same(os.fstat(fd), before):
            os.close(fd)
            return False, 0

        def walk(dfd: int, rel: str) -> bool:
            nonlocal removed_blocks
            whole = True
            here = os.fstat(dfd)
            os.fchmod(dfd, stat.S_IMODE(here.st_mode) | stat.S_IWUSR | stat.S_IXUSR | stat.S_IRUSR)
            run_hook(root, rel)
            listed = {c.rsplit("/", 1)[-1]: c for c in children.get(rel, [])}
            try:
                present = set(names(dfd))
            except (OSError, Keep):
                return False
            if present - set(listed):
                whole = False
            for cname in sorted(listed):
                crel = listed[cname]
                want = entries[crel]
                try:
                    cst = os.stat(cname, dir_fd=dfd, follow_symlinks=False)
                except OSError:
                    whole = False
                    continue
                if not matches(cst, want, True):
                    whole = False
                    continue
                if want[0] == "d":
                    try:
                        cfd = os.open(cname, DIR_FLAGS | NOFOLLOW, dir_fd=dfd)
                    except OSError:
                        whole = False
                        continue
                    try:
                        if not same(os.fstat(cfd), cst):
                            whole = False
                            continue
                        sub = walk(cfd, crel)
                    finally:
                        os.close(cfd)
                    if not sub:
                        whole = False
                        continue
                    try:
                        again = os.stat(cname, dir_fd=dfd, follow_symlinks=False)
                        if not same(again, cst):
                            whole = False
                            continue
                        os.rmdir(cname, dir_fd=dfd)
                        removed_blocks += int(want[5])
                    except OSError:
                        whole = False
                else:
                    try:
                        os.unlink(cname, dir_fd=dfd)
                        removed_blocks += int(want[5])
                    except OSError:
                        whole = False
            return whole

        try:
            whole = walk(fd, ".")
        finally:
            os.close(fd)
        if whole:
            again = os.stat(name, dir_fd=pfd, follow_symlinks=False)
            if same(again, before):
                os.rmdir(name, dir_fd=pfd)
                removed_blocks += int(top[5])
                return True, removed_blocks
        return False, removed_blocks
    except OSError:
        return False, removed_blocks
    finally:
        os.close(pfd)


# --- commands -----------------------------------------------------------------


def emit(text: str) -> None:
    sys.stdout.write(text)


def cmd_freeze(args: list[str]) -> int:
    if len(args) < 2:
        return 2
    out: list[str] = []
    with open(args[0], "a", encoding="utf-8") as record:
        for root in args[1:]:
            seen: list[tuple[int, int, int]] = []
            reason = "ok"
            try:
                freeze_root(root, seen)
            except Keep as why:
                reason = str(why)
            except OSError:
                reason = "frozen"
            if reason == "ok":
                for dev, ino, mode in seen:
                    record.write(f"{dev} {ino} {mode:o}\n")
            elif seen and not thaw_root(root, {(dev, ino): mode for dev, ino, mode in seen}):
                reason = "frozen"
            out.append(f"{root}\t{reason}\n")
        record.flush()
        os.fsync(record.fileno())
    emit("".join(out))
    return 0


def cmd_snapshot(args: list[str]) -> int:
    out: list[str] = []
    for root in args:
        try:
            out.extend(line + "\n" for line in snapshot_root(root))
        except Keep as why:
            out.append(f"{root}\t!\t{why}\n")
        except OSError:
            out.append(f"{root}\t!\tunreadable\n")
    emit("".join(out))
    return 0


def cmd_thaw(args: list[str]) -> int:
    if len(args) < 2:
        return 2
    modes = read_record(args[0])
    ok = all([thaw_root(root, modes) for root in args[1:]])
    return 0 if ok else 1


def cmd_remove(args: list[str]) -> int:
    if len(args) < 3:
        return 2
    roots = args[2:]
    snap = read_snapshot(args[0], set(roots))
    modes = read_record(args[1])
    out: list[str] = []
    for root in roots:
        done, blocks = remove_root(root, snap.get(root, {}))
        if done and not os.path.lexists(root):
            out.append(f"{root}\tremoved\t{blocks // 2}\n")
        else:
            if os.path.lexists(root):
                thaw_root(root, modes)
            out.append(f"{root}\tpartial\t{blocks // 2}\n")
    emit("".join(out))
    return 0


def main(argv: list[str]) -> int:
    commands = {"freeze": cmd_freeze, "snapshot": cmd_snapshot, "thaw": cmd_thaw, "remove": cmd_remove}
    if len(argv) < 2 or argv[1] not in commands:
        sys.stderr.write("usage: fm-footprint-fs.py freeze|snapshot|thaw|remove ...\n")
        return 2
    try:
        rc = commands[argv[1]](argv[2:])
        sys.stdout.flush()
        return rc
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"fm-footprint-fs: {exc}\n")
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
