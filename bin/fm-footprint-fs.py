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
      so its set of names cannot change afterwards. A file with more than one
      link is frozen only when all of its names are inside the root; one with
      a name elsewhere, such as in a package store, is never changed, since
      its mode and data belong to that name too.
      Each object's "dev ino mode" line is appended to <record> and written
      out before its mode changes, so a freeze stopped at any point can be
      undone from <record>. Prints "root<TAB>ok" or "root<TAB><reason>" per
      root; a root that fails part way is thawed again before this returns.
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
      against the snapshot and unlinked by name in that directory. Before
      anything goes, every name with more than one link is checked the same
      way, and the root stays whole if one fails; unlinking such a name
      never touches its data, which its other names keep. Anything
      that does not match, or is not listed, stays, and so does every
      directory above it, with the recorded modes restored. Prints
      "root<TAB>removed<TAB>kb" or "root<TAB>partial<TAB>kb".

Every walk is iterative, so a deep tree meets no recursion limit; it holds one
descriptor per level, with the soft open-file limit raised towards the hard
one, and a tree deeper than that allows is kept. Exit status 0 means every requested line was written;
2 is a usage error and 3 a failed write of <record> or the output, which the
caller treats as keep; any other status means the engine stopped early.

FM_FOOTPRINT_ENGINE_PID_FILE, set by the script while a removal run is under
way, names a file this engine writes its pid to, so a stop signal can stop
and wait for it before the run is undone.

Test seams, honoured only while FM_FOOTPRINT_TEST_SEAMS=1:
FM_FOOTPRINT_TEST_REMOVE_HOOK names a program run with the root and the
relative directory each time remove has just made a directory writable, to
interleave a change at exactly that point; FM_FOOTPRINT_TEST_FREEZE_KILL_AFTER
makes the freeze kill itself after that many mode changes, and
FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER makes it stop itself (SIGSTOP) after
that many, first writing its pid to FM_FOOTPRINT_TEST_PAUSED_FILE.
"""

from __future__ import annotations

import os
import signal
import stat
import subprocess
import sys

DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0)
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
FILE_FLAGS = os.O_RDONLY | NOFOLLOW | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOCTTY", 0) | getattr(os, "O_CLOEXEC", 0)
WRITE_BITS = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
SEAMS = os.environ.get("FM_FOOTPRINT_TEST_SEAMS", "") == "1"


class Keep(Exception):
    """A root cannot be handled in full; the reason is the message."""


class RecordError(Exception):
    """The record could not be written; the caller must keep everything."""


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


def close_all(fds: list[int]) -> None:
    for fd in fds:
        try:
            os.close(fd)
        except OSError:
            pass


# --- freeze and thaw ----------------------------------------------------------


class Freezer:
    """Freezes roots, writing each record line ahead of its mode change."""

    def __init__(self, record_fd: int) -> None:
        self.record_fd = record_fd
        self.changes = 0
        kill_after = os.environ.get("FM_FOOTPRINT_TEST_FREEZE_KILL_AFTER", "") if SEAMS else ""
        self.kill_after = int(kill_after) if kill_after.isdigit() else 0
        stop_after = os.environ.get("FM_FOOTPRINT_TEST_FREEZE_STOP_AFTER", "") if SEAMS else ""
        self.stop_after = int(stop_after) if stop_after.isdigit() else 0

    def record(self, cst: os.stat_result, mode: int) -> None:
        data = f"{cst.st_dev} {cst.st_ino} {mode:o}\n".encode()
        try:
            if os.write(self.record_fd, data) != len(data):
                raise RecordError("short write")
        except OSError as exc:
            raise RecordError(str(exc)) from exc

    def chmod_fd(self, cfd: int, cst: os.stat_result, seen: list[tuple[int, int, int]]) -> None:
        mode = stat.S_IMODE(cst.st_mode)
        self.record(cst, mode)
        seen.append((cst.st_dev, cst.st_ino, mode))
        if mode & WRITE_BITS:
            os.fchmod(cfd, mode & ~WRITE_BITS)
            self.changes += 1
            if self.kill_after and self.changes >= self.kill_after:
                os.kill(os.getpid(), signal.SIGKILL)
            if self.stop_after and self.changes == self.stop_after:
                paused = os.environ.get("FM_FOOTPRINT_TEST_PAUSED_FILE", "")
                if paused:
                    with open(paused, "w", encoding="utf-8") as handle:
                        handle.write(f"{os.getpid()}\n")
                os.kill(os.getpid(), signal.SIGSTOP)

    def freeze_root(self, root: str, seen: list[tuple[int, int, int]]) -> None:
        """Freezes <root>, appending every directory and file whose mode it
        changes, with its mode before the freeze, to <seen>. A file with more
        than one link is frozen only when every one of its names is inside
        <root>; otherwise its mode belongs to names elsewhere too, such as a
        package store, and it is left exactly as it is."""
        pfd, fd, st = open_root(root)
        os.close(pfd)
        root_dev = st.st_dev
        # (dev, ino) -> [link count, names seen inside root] for linked files.
        multi: dict[tuple[int, int], list[int]] = {}
        self.walk_freeze(fd, st, root_dev, seen, multi)
        inside = {key for key, (links, count) in multi.items() if count >= links}
        if inside:
            self.freeze_inside_links(root, root_dev, inside, seen)

    def walk_freeze(self, fd: int, st: os.stat_result, root_dev: int, seen: list[tuple[int, int, int]],
                    multi: dict[tuple[int, int], list[int]]) -> None:
        stack: list[list] = []
        try:
            self.chmod_fd(fd, st, seen)
            stack.append([fd, names(fd), 0])
            while stack:
                frame = stack[-1]
                if frame[2] >= len(frame[1]):
                    os.close(frame[0])
                    stack.pop()
                    continue
                name = frame[1][frame[2]]
                frame[2] += 1
                cst = os.stat(name, dir_fd=frame[0], follow_symlinks=False)
                if cst.st_dev != root_dev:
                    raise Keep("mount")
                if stat.S_ISDIR(cst.st_mode):
                    cfd = open_child(frame[0], name, cst)
                    try:
                        self.chmod_fd(cfd, os.fstat(cfd), seen)
                        entries = names(cfd)
                    except BaseException:
                        os.close(cfd)
                        raise
                    stack.append([cfd, entries, 0])
                elif cst.st_nlink > 1:
                    if stat.S_ISREG(cst.st_mode):
                        multi.setdefault((cst.st_dev, cst.st_ino), [cst.st_nlink, 0])[1] += 1
                elif stat.S_ISREG(cst.st_mode):
                    cfd = open_child(frame[0], name, cst)
                    try:
                        now = os.fstat(cfd)
                        if now.st_nlink > 1:
                            multi.setdefault((now.st_dev, now.st_ino), [now.st_nlink, 0])[1] += 1
                        else:
                            self.chmod_fd(cfd, now, seen)
                    finally:
                        os.close(cfd)
                # Links, sockets, FIFOs and devices hold no content to protect;
                # their own modes are never changed.
        finally:
            close_all([frame[0] for frame in stack])

    def freeze_inside_links(self, root: str, root_dev: int, inside: set[tuple[int, int]],
                            seen: list[tuple[int, int, int]]) -> None:
        """Freezes the linked files whose every name is inside <root>, once
        each, checking at the moment of change that the link count is still
        the one counted."""
        pfd, fd, _st = open_root(root)
        os.close(pfd)
        done: set[tuple[int, int]] = set()
        stack: list[list] = []
        try:
            stack.append([fd, names(fd), 0])
            while stack:
                frame = stack[-1]
                if frame[2] >= len(frame[1]):
                    os.close(frame[0])
                    stack.pop()
                    continue
                name = frame[1][frame[2]]
                frame[2] += 1
                cst = os.stat(name, dir_fd=frame[0], follow_symlinks=False)
                if cst.st_dev != root_dev:
                    raise Keep("mount")
                if stat.S_ISDIR(cst.st_mode):
                    cfd = open_child(frame[0], name, cst)
                    try:
                        entries = names(cfd)
                    except BaseException:
                        os.close(cfd)
                        raise
                    stack.append([cfd, entries, 0])
                    continue
                key = (cst.st_dev, cst.st_ino)
                if key not in inside or key in done or not stat.S_ISREG(cst.st_mode):
                    continue
                cfd = open_child(frame[0], name, cst)
                try:
                    now = os.fstat(cfd)
                    if now.st_nlink != cst.st_nlink:
                        raise Keep("changed")
                    self.chmod_fd(cfd, now, seen)
                    done.add(key)
                finally:
                    os.close(cfd)
        finally:
            close_all([frame[0] for frame in stack])


def read_record(path: str) -> dict[tuple[int, int], int]:
    """Reads a freeze record. A last line without its newline is the trace of
    a write that failed part way, before its mode changed, so it is ignored."""
    modes: dict[tuple[int, int], int] = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if not line.endswith("\n"):
                break
            parts = line.split()
            if len(parts) != 3:
                raise ValueError("malformed record")
            # The first line for an object holds its mode before any freeze.
            modes.setdefault((int(parts[0]), int(parts[1])), int(parts[2], 8))
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

    def entries_of(dfd: int) -> list[str]:
        nonlocal ok
        try:
            return names(dfd)
        except (OSError, Keep):
            ok = False
            return []

    stack: list[list] = [[fd, st, entries_of(fd), 0]]
    try:
        while stack:
            frame = stack[-1]
            if frame[3] >= len(frame[2]):
                restore(frame[0], frame[1])
                os.close(frame[0])
                stack.pop()
                continue
            name = frame[2][frame[3]]
            frame[3] += 1
            try:
                cst = os.stat(name, dir_fd=frame[0], follow_symlinks=False)
                if not (stat.S_ISDIR(cst.st_mode) or stat.S_ISREG(cst.st_mode)):
                    continue
                if not stat.S_ISDIR(cst.st_mode) and (cst.st_dev, cst.st_ino) not in modes:
                    continue
                cfd = open_child(frame[0], name, cst)
            except (OSError, Keep):
                ok = False
                continue
            if stat.S_ISDIR(cst.st_mode):
                stack.append([cfd, os.fstat(cfd), entries_of(cfd), 0])
            else:
                try:
                    restore(cfd, os.fstat(cfd))
                finally:
                    os.close(cfd)
    finally:
        close_all([frame[0] for frame in stack])
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

    stack: list[list] = []
    try:
        lines.append(line(".", st))
        stack.append([fd, ".", names(fd), 0])
        while stack:
            frame = stack[-1]
            if frame[3] >= len(frame[2]):
                os.close(frame[0])
                stack.pop()
                continue
            name = frame[2][frame[3]]
            frame[3] += 1
            cst = os.stat(name, dir_fd=frame[0], follow_symlinks=False)
            if cst.st_dev != root_dev:
                raise Keep("mount")
            crel = name if frame[1] == "." else frame[1] + "/" + name
            if stat.S_ISDIR(cst.st_mode):
                cfd = open_child(frame[0], name, cst)
                try:
                    lines.append(line(crel, os.fstat(cfd)))
                    entries = names(cfd)
                except BaseException:
                    os.close(cfd)
                    raise
                stack.append([cfd, crel, entries, 0])
            else:
                lines.append(line(crel, cst))
    finally:
        close_all([frame[0] for frame in stack])
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


def matches(cst: os.stat_result, want: list[str], gone: int = 0) -> bool:
    """<cst> is still the snapshotted object: device, inode, type, size,
    modification time and link count, less the <gone> names of the same
    object this removal already unlinked; the change time only while none
    were, since each unlink changes it."""
    kind, _mode, dev, ino, size, _blocks, mtime, ctime, nlink = want
    if not (type_char(cst.st_mode) == kind and str(cst.st_dev) == dev and str(cst.st_ino) == ino
            and str(cst.st_size) == size and str(cst.st_mtime_ns) == mtime):
        return False
    if cst.st_nlink != int(nlink) - gone:
        return False
    return gone > 0 or str(cst.st_ctime_ns) == ctime


def run_hook(root: str, rel: str) -> None:
    hook = os.environ.get("FM_FOOTPRINT_TEST_REMOVE_HOOK", "") if SEAMS else ""
    if hook:
        subprocess.run([hook, root, rel], check=False, stdin=subprocess.DEVNULL)


class Dir:
    """One directory being emptied: its descriptor, its listed entries, and
    (for all but the root) the name and identity it has in its parent."""

    def __init__(self, fd: int, rel: str, listed: dict[str, str], meta) -> None:
        self.fd = fd
        self.rel = rel
        self.listed = listed
        self.items = sorted(listed)
        self.index = 0
        self.whole = True
        self.meta = meta


def remove_root(root: str, entries: dict[str, list[str]]) -> tuple[bool, int]:
    removed_blocks = 0
    children: dict[str, dict[str, str]] = {}
    for rel in entries:
        if rel != ".":
            parent, _, cname = rel.rpartition("/")
            children.setdefault(parent or ".", {})[cname] = rel
    top = entries.get(".")
    if top is None or top[0] != "d":
        return False, 0
    # Names of an object with more than one link: each unlink lowers the
    # link count the next name of the same object must show.
    linked = [rel for rel, want in entries.items() if want[0] != "d" and int(want[8]) > 1]
    gone: dict[tuple[str, str], int] = {}
    parent, name = os.path.split(root.rstrip("/"))
    pfd = os.open(parent, DIR_FLAGS)
    stack: list[Dir] = []
    try:
        before = os.stat(name, dir_fd=pfd, follow_symlinks=False)
        if not matches(before, top):
            return False, 0
        fd = os.open(name, DIR_FLAGS | NOFOLLOW, dir_fd=pfd)
        if not same(os.fstat(fd), before):
            os.close(fd)
            return False, 0
        # Before anything goes, every hard-linked name must still be the
        # snapshotted object with its link count; otherwise the whole copy
        # stays. Each is checked again at its own unlink.
        for rel in linked:
            try:
                now = os.stat(rel, dir_fd=fd, follow_symlinks=False)
            except OSError:
                os.close(fd)
                return False, 0
            if not matches(now, entries[rel]):
                os.close(fd)
                return False, 0

        def enter(dfd: int, rel: str, meta) -> Dir:
            frame = Dir(dfd, rel, children.get(rel, {}), meta)
            here = os.fstat(dfd)
            os.fchmod(dfd, stat.S_IMODE(here.st_mode) | stat.S_IWUSR | stat.S_IXUSR | stat.S_IRUSR)
            run_hook(root, rel)
            try:
                present = set(names(dfd))
            except (OSError, Keep):
                frame.whole = False
                frame.items = []
                return frame
            if present - set(frame.listed):
                frame.whole = False
            return frame

        try:
            stack.append(enter(fd, ".", None))
        except OSError:
            os.close(fd)
            return False, 0
        root_whole = False
        while stack:
            frame = stack[-1]
            if frame.index >= len(frame.items):
                os.close(frame.fd)
                stack.pop()
                if frame.meta is None:
                    root_whole = frame.whole
                    continue
                cname, cst, want = frame.meta
                up = stack[-1]
                if not frame.whole:
                    up.whole = False
                    continue
                try:
                    again = os.stat(cname, dir_fd=up.fd, follow_symlinks=False)
                    if not same(again, cst):
                        up.whole = False
                        continue
                    os.rmdir(cname, dir_fd=up.fd)
                    removed_blocks += int(want[5])
                except OSError:
                    up.whole = False
                continue
            cname = frame.items[frame.index]
            frame.index += 1
            want = entries[frame.listed[cname]]
            try:
                cst = os.stat(cname, dir_fd=frame.fd, follow_symlinks=False)
            except OSError:
                frame.whole = False
                continue
            key = (want[2], want[3])
            if not matches(cst, want, gone.get(key, 0) if want[0] != "d" else 0):
                frame.whole = False
                continue
            if want[0] == "d":
                try:
                    cfd = os.open(cname, DIR_FLAGS | NOFOLLOW, dir_fd=frame.fd)
                except OSError:
                    frame.whole = False
                    continue
                try:
                    if not same(os.fstat(cfd), cst):
                        raise OSError("changed")
                    stack.append(enter(cfd, frame.listed[cname], (cname, cst, want)))
                except OSError:
                    os.close(cfd)
                    frame.whole = False
                continue
            try:
                os.unlink(cname, dir_fd=frame.fd)
                if int(want[8]) > 1:
                    gone[key] = gone.get(key, 0) + 1
                    # The data stays reachable through its other names; only
                    # the last name inside frees its blocks.
                    if int(want[8]) - gone[key] == 0:
                        removed_blocks += int(want[5])
                else:
                    removed_blocks += int(want[5])
            except OSError:
                frame.whole = False
        if root_whole:
            again = os.stat(name, dir_fd=pfd, follow_symlinks=False)
            if same(again, before):
                os.rmdir(name, dir_fd=pfd)
                removed_blocks += int(top[5])
                return True, removed_blocks
        return False, removed_blocks
    except OSError:
        return False, removed_blocks
    finally:
        close_all([frame.fd for frame in stack])
        os.close(pfd)


# --- commands -----------------------------------------------------------------


def emit(text: str) -> None:
    sys.stdout.write(text)


def cmd_freeze(args: list[str]) -> int:
    if len(args) < 2:
        return 2
    out: list[str] = []
    record_fd = os.open(args[0], os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_CLOEXEC", 0), 0o600)
    try:
        freezer = Freezer(record_fd)
        for root in args[1:]:
            seen: list[tuple[int, int, int]] = []
            reason = "ok"
            try:
                freezer.freeze_root(root, seen)
            except Keep as why:
                reason = str(why)
            except OSError:
                reason = "frozen"
            if reason != "ok" and seen and not thaw_root(root, {(dev, ino): mode for dev, ino, mode in seen}):
                reason = "frozen"
            out.append(f"{root}\t{reason}\n")
    finally:
        os.close(record_fd)
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
        try:
            done, blocks = remove_root(root, snap.get(root, {}))
        except (ValueError, IndexError, Keep):
            done, blocks = False, 0
        if done and not os.path.lexists(root):
            out.append(f"{root}\tremoved\t{blocks // 2}\n")
        else:
            if os.path.lexists(root):
                thaw_root(root, modes)
            out.append(f"{root}\tpartial\t{blocks // 2}\n")
    emit("".join(out))
    return 0


def write_pid_file() -> None:
    """Names this engine in FM_FOOTPRINT_ENGINE_PID_FILE, so the script can
    stop and wait for it before undoing a run it was stopped in."""
    path = os.environ.get("FM_FOOTPRINT_ENGINE_PID_FILE", "")
    if not path:
        return
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | NOFOLLOW | getattr(os, "O_CLOEXEC", 0), 0o600)
        try:
            os.write(fd, f"{os.getpid()}\n".encode())
        finally:
            os.close(fd)
    except OSError:
        pass


def raise_open_file_limit() -> None:
    """Each walk holds one descriptor per level, so a deep tree needs the
    soft open-file limit raised towards the hard one; when that is not
    allowed, a tree too deep for it fails to open and is kept."""
    try:
        import resource
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    except (ImportError, OSError, ValueError):
        return
    if soft == resource.RLIM_INFINITY:
        return
    ceiling = 1 << 20 if hard == resource.RLIM_INFINITY else min(hard, 1 << 20)
    for want in (ceiling, 10240):
        if want <= soft:
            return
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
            return
        except (OSError, ValueError):
            continue


def main(argv: list[str]) -> int:
    commands = {"freeze": cmd_freeze, "snapshot": cmd_snapshot, "thaw": cmd_thaw, "remove": cmd_remove}
    if len(argv) < 2 or argv[1] not in commands:
        sys.stderr.write("usage: fm-footprint-fs.py freeze|snapshot|thaw|remove ...\n")
        return 2
    write_pid_file()
    raise_open_file_limit()
    try:
        rc = commands[argv[1]](argv[2:])
        sys.stdout.flush()
        return rc
    except (OSError, ValueError, RecordError) as exc:
        sys.stderr.write(f"fm-footprint-fs: {exc}\n")
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
