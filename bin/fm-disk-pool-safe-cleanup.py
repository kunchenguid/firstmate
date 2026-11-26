#!/usr/bin/env python3
"""Preview or remove ignored, regenerable directories in idle Treehouse slots.

Read Treehouse pool state under its existing exclusive flock. Do not invoke
Treehouse: even `status` can recover a slot and move its untracked files.
Schema v4 reservation records prove a slot is free; a pool in any other state
version is inspected slot by slot, and a slot there must also be untouched for
24 hours, as must any slot while a same-user process hides its cwd. A pool with
a duplicate slot identity is skipped whole.
"""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time


POOL_STATE = "treehouse-state.json"
POOL_LOCK = "treehouse-state.lock"
DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
READ = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
IDLE_SECONDS = 24 * 60 * 60
GIT_ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


class Keep(Exception):
    """An eligibility check refused the slot or candidate."""


@contextlib.contextmanager
def opened(name, flags, parent=None):
    fd = os.open(name, flags, dir_fd=parent)
    try:
        yield fd
    finally:
        os.close(fd)


@contextlib.contextmanager
def regular_file(parent, name):
    with opened(name, READ, parent) as fd:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise Keep("not a regular state or lock file")
        yield fd, info


def unique_fields(pairs):
    obj = dict(pairs)
    if len(obj) != len(pairs):
        raise Keep("duplicate Treehouse state field")
    return obj


def read_pool(fd):
    """Return the slot inventory and whether its reservation records are schema v4."""
    with regular_file(fd, POOL_STATE) as (entry, _), os.fdopen(os.dup(entry), "rb") as f:
        data = json.load(f, object_pairs_hook=unique_fields)
    if not isinstance(data, dict) or "worktrees" not in data:
        raise Keep("unrecognized Treehouse state")
    # Any other version still names its slots, but its reservations are unverified.
    verified = type(data.get("version")) is int and data["version"] == 4
    rows = [] if data["worktrees"] is None else data["worktrees"]
    if not isinstance(rows, list):
        raise Keep("invalid Treehouse slot inventory")
    slots, paths = {}, set()
    for row in rows:
        if not isinstance(row, dict):
            raise Keep("invalid Treehouse slot record")
        name, path = row.get("name"), row.get("path")
        if not isinstance(name, str) or not name or not isinstance(path, str) or not os.path.isabs(path):
            raise Keep("invalid Treehouse slot identity")
        physical = os.path.realpath(path)
        if name in slots or physical in paths:
            raise Keep("duplicate Treehouse slot identity")
        paths.add(physical)
        slots[name] = (Path(path), row)
    return slots, verified


def slot_layout(pool, slot):
    # Only the built-in <pool>/<number>/<repo> layout, not external templates.
    return (slot.parent.parent == pool and re.fullmatch(r"[0-9]+", slot.parent.name)
            and slot.resolve(strict=True) == slot)


def check_reservation(row, verified):
    for key, empty in {"leased": False, "destroying": False, "owner_pid": 0,
                       "owner_started_at": 0, "lease_id": "", "lease_holder": "",
                       "leased_at": None, "recovery_error": "", "recovery_reason": ""}.items():
        val = row.get(key, empty)
        if type(val) is not type(empty) or val != empty:
            raise Keep("Treehouse reservation, process owner, or recovery hold")
    if not verified:
        # Unversioned records carry no seed inventory; honor one only if present.
        if row.get("seeded_paths") not in (None, []):
            raise Keep("seeded or unverified Treehouse slot")
        return
    digest = row.get("seed_inventory_digest", "")
    if (row.get("seed_inventory_known") is not True or row.get("seeded_paths") not in (None, [])
            or row.get("seed_backend", "") not in ("", "git") or row.get("seed_auth_identity")
            or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
        raise Keep("seeded or unverified Treehouse slot")


def under(path, root):
    return path == root or path.startswith(root + "/")


def check_metadata(slot, container, state_dirs):
    try:
        os.stat(".fm-slot-owner", dir_fd=container, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise Keep("Firstmate slot-owner marker")
    for state in state_dirs:
        with opened(state, DIR) as fd:
            for name in os.listdir(fd):
                if not name.endswith(".meta"):
                    continue
                with regular_file(fd, name) as (entry, _), os.fdopen(os.dup(entry), "rb") as f:
                    for line in f:
                        if not line.startswith((b"worktree=", b"home=")):
                            continue
                        path = os.fsdecode(line.split(b"=", 1)[1].removesuffix(b"\n"))
                        if not path:
                            continue
                        if not os.path.isabs(path):
                            raise Keep("unverifiable Firstmate metadata path")
                        if under(os.path.realpath(path), str(slot)):
                            raise Keep("Firstmate task metadata names the slot")


def check_mounts(slot):
    # Unlike device-number checks, mountinfo also sees same-device bind mounts.
    visible_proc = False
    with open("/proc/self/mountinfo", encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            fields = line.rstrip("\n").split(" ")
            if len(fields) < 10 or fields[-4] != "-":
                raise Keep("cannot verify mount layout")
            mount = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), fields[4])
            if under(mount, str(slot.parent)):
                raise Keep("mount at or below the slot container")
            if mount == "/proc" and fields[-3] == "proc":
                options = (fields[5] + "," + fields[-1]).split(",")
                visible_proc = not any(opt.startswith("hidepid=") and opt not in ("hidepid=0", "hidepid=off")
                                       for opt in options)
    if not visible_proc:
        raise Keep("procfs does not expose the full process census")


def process_uids(pid):
    # The status file stays world-readable when cwd is hidden; the /proc/PID
    # owner does not, because non-dumpable tasks show as root-owned.
    with open(f"/proc/{pid}/status", "rb") as f:
        for line in f:
            if line.startswith(b"Uid:"):
                return {int(uid) for uid in line.split()[1:]}
    raise ValueError("no Uid line")


def check_cwds(slot):
    """Refuse a visible or unverifiable cwd in the slot; return hidden same-user cwds.

    Another user's process with a hidden cwd is not a Firstmate worker, and
    everything this tool removes is regenerable, so it does not block.
    """
    hidden = unverifiable = 0
    for pid in os.listdir("/proc"):
        if not pid.isdecimal():
            continue
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except FileNotFoundError:  # Exited, or a kernel thread/zombie with no cwd.
            continue
        except PermissionError:
            try:
                uids = process_uids(pid)
            except FileNotFoundError:
                continue
            except (OSError, ValueError):
                unverifiable += 1
                continue
            hidden += os.geteuid() in uids  # Any of real, effective, saved, or fs uid.
            continue
        if under(cwd, str(slot.parent)) or under(cwd.removesuffix(" (deleted)"), str(slot.parent)):
            raise Keep("process cwd in the slot")
        if not cwd.startswith("/"):
            unverifiable += 1
    if unverifiable:
        raise Keep(f"cannot verify {unverifiable} process cwd(s)")
    return hidden


def check_idle(repo, git_dir, why):
    # Newest change to the slot's top-level entries or its Git index.
    try:
        newest = max([os.fstat(repo).st_mtime, os.stat(os.path.join(git_dir, "index")).st_mtime]
                     + [entry.stat(follow_symlinks=False).st_mtime for entry in os.scandir(repo)])
    except FileNotFoundError:
        raise Keep("cannot verify slot idle age") from None
    if time.time() - newest < IDLE_SECONDS:
        raise Keep(f"slot touched within 24 hours{why}")


def git(slot, *args):
    return subprocess.run(
        ["git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", str(slot), *args],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, env=GIT_ENV,
    ).stdout


def check_git(slot):
    layout = os.fsdecode(git(slot, "rev-parse", "--path-format=absolute", "--show-toplevel",
                            "--git-dir", "--git-common-dir")).splitlines()
    if len(layout) != 3 or layout[0] != str(slot) or layout[1] == layout[2]:
        raise Keep("not the root of a linked Git worktree")
    if any(under(os.path.realpath(path), str(slot)) for path in layout[1:]):
        raise Keep("Git storage is inside the slot")
    if git(slot, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"):
        raise Keep("Git status is not clean")
    return layout[1]


def protected(name):
    return name in (".git", ".jj") or name.startswith(".env")


def read_git_paths(slot, *args):
    return [os.fsdecode(path) for path in git(slot, "ls-files", "-z", *args).split(b"\0") if path]


def candidates(slot):
    indexed = read_git_paths(slot, "-v")
    if any(line[:2] != "H " for line in indexed):
        raise Keep("Git index contains hidden or unmerged paths")
    tracked = [line[2:] for line in indexed]
    result = set()
    for path in read_git_paths(slot, "--others", "--ignored", "--exclude-standard", "--directory"):
        if not path.endswith("/"):
            continue
        parts = tuple(path[:-1].split("/"))
        if any(part in ("", ".", "..") or protected(part) for part in parts):
            continue
        if parts[-1] == ".terraform" and "terraform" in parts[:-1]:
            parts += ("providers",)
        if (parts[-1] in ("node_modules", ".next", ".venv")
                or parts[-2:] in (("dbt", "target"), ("dbt", "dbt_packages"))
                or (parts[-2:] == (".terraform", "providers") and "terraform" in parts[:-2])):
            rel = "/".join(parts)
            if not any(under(p, rel) or under(rel, p) for p in tracked):
                result.add(parts)
    return sorted(result)


@contextlib.contextmanager
def parent_dir(fd, parts):
    with contextlib.ExitStack() as stack:
        for part in parts:
            fd = stack.enter_context(opened(part, DIR, fd))
        yield fd


def walk(fd, device, remove=False):
    # Never follow symlinks, and enforce protected names even while deleting.
    size = os.fstat(fd).st_blocks * 512
    with os.scandir(fd) as entries:
        for entry in list(entries):
            info = entry.stat(follow_symlinks=False)
            if protected(entry.name) or info.st_dev != device:
                raise Keep("generated directory contains a protected path or mount")
            if stat.S_ISDIR(info.st_mode):
                with opened(entry.name, DIR, fd) as child:
                    if not os.path.samestat(info, os.fstat(child)):
                        raise Keep("generated directory changed during inspection")
                    size += walk(child, device, remove)
                if remove:
                    os.rmdir(entry.name, dir_fd=fd)
            elif stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                if info.st_nlink == 1:
                    size += info.st_blocks * 512
                if remove:
                    os.unlink(entry.name, dir_fd=fd)
            else:
                raise Keep("generated directory contains a special file")
    return size


def verify(slot, container, repo, state_dirs, verified):
    """Run every slot gate; repeated immediately before removal."""
    if not os.path.samestat(os.fstat(repo), os.stat(slot, follow_symlinks=False)):
        raise Keep("worktree identity changed")
    marker = os.stat(".git", dir_fd=repo, follow_symlinks=False)
    if not stat.S_ISREG(marker.st_mode):
        raise Keep("not a linked Git worktree")
    check_metadata(slot, container, state_dirs)
    check_mounts(slot)
    hidden = check_cwds(slot)
    git_dir = check_git(slot)
    # Without reservation records, or with a same-user cwd hidden from the
    # census, only age shows the slot is idle.
    if hidden:
        check_idle(repo, git_dir, f" and {hidden} same-user process cwd(s) are hidden")
    elif not verified:
        check_idle(repo, git_dir, "")


def clean_slot(fd, pool, name, slot, state_dirs, apply):
    with regular_file(fd, POOL_LOCK) as (lock, lock_info):
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Keep("Treehouse pool lock held") from None
        slots, verified = read_pool(fd)
        current, row = slots.get(name, (None, None))
        if current != slot or not slot_layout(pool, slot):
            raise Keep("slot changed or not in the built-in pool layout")
        check_reservation(row, verified)
        with opened(slot.parent.name, DIR, fd) as container, opened(slot.name, DIR, container) as repo:
            verify(slot, container, repo, state_dirs, verified)
            device = os.fstat(repo).st_dev
            plans = []
            for parts in candidates(slot):
                try:
                    with parent_dir(repo, parts[:-1]) as parent, opened(parts[-1], DIR, parent) as target:
                        info = os.fstat(target)
                        if info.st_dev != device:
                            raise Keep("generated directory crosses devices")
                        plans.append((parts, info, walk(target, device)))
                except FileNotFoundError:
                    continue  # For example, .terraform without a providers directory.
                except (Keep, NotADirectoryError) as exc:
                    reason = str(exc) if isinstance(exc, Keep) else "not an ordinary directory"
                    print(f"{str(slot)!r}: keeping {'/'.join(parts)!r}: {reason}")
            if apply and plans:
                verify(slot, container, repo, state_dirs, verified)
                if not {parts for parts, _, _ in plans}.issubset(candidates(slot)):
                    raise Keep("generated directory no longer eligible in Git")
                if not os.path.samestat(lock_info, os.stat(POOL_LOCK, dir_fd=fd, follow_symlinks=False)):
                    raise Keep("Treehouse lock file changed")
            if not plans:
                print(f"{str(slot)!r}: no eligible generated directories")
            for parts, expected, size in plans:
                if apply:
                    try:
                        with parent_dir(repo, parts[:-1]) as parent, opened(parts[-1], DIR, parent) as target:
                            if not os.path.samestat(expected, os.fstat(target)):
                                raise Keep("generated directory changed before removal")
                            size = walk(target, device, remove=True)
                            os.rmdir(parts[-1], dir_fd=parent)
                    except (Keep, OSError, RecursionError) as exc:
                        raise RuntimeError("removal did not finish; the directory may be partial") from exc
                print(f"{str(slot)!r}: {'removed' if apply else 'would remove'} {'/'.join(parts)!r}: {size} bytes")
                yield size


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Allows ignored node_modules, .next, .venv, dbt/{target,dbt_packages}, and "
        "terraform/**/.terraform/providers directories. Linux with Python 3.9+ only. "
        "Run in the workers' PID and mount namespaces. Another user's process with a hidden cwd "
        "does not block a slot; a hidden cwd of the same user blocks a slot touched within 24 hours. "
        "Supply every relevant Firstmate state directory and keep manual access to idle slots "
        "quiescent during --apply; the pool lock excludes Treehouse allocation, not a direct cd. "
        "Byte counts estimate allocated space, excluding multiply linked files."
    ))
    parser.add_argument("--apply", action="store_true", help="remove eligible directories (default: dry-run)")
    parser.add_argument("--pool-root", type=Path, default=os.getenv("TREEHOUSE_ROOT") or "~/.treehouse",
                        help="Treehouse root (default: TREEHOUSE_ROOT or ~/.treehouse)")
    parser.add_argument("--state-dir", action="append", type=Path, help=(
        "Firstmate state directory, repeatable (default: FM_STATE_OVERRIDE or FM_HOME/state; "
        "FM_HOME defaults to ~/.firstmate)"
    ))
    parser.add_argument("pool", nargs="*", help="exact pool names under the root (default: all pools)")
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("Linux procfs and Treehouse flock are required")
    if any(Path(name).name != name or name in ("", ".", "..") for name in args.pool):
        parser.error("pool names must be single path components")
    state_dirs = args.state_dir or [Path(os.getenv("FM_STATE_OVERRIDE") or
                                        (Path(os.getenv("FM_HOME") or "~/.firstmate") / "state"))]
    state_dirs = [path.expanduser() for path in state_dirs]
    root = args.pool_root.expanduser()
    if not root.is_absolute() or not all(path.is_absolute() for path in state_dirs):
        parser.error("pool root and state directories must be absolute")
    total, failed = 0, False
    try:
        root = root.resolve(strict=True)
        pools = [root / name for name in dict.fromkeys(args.pool)] if args.pool else sorted(
            path for path in root.iterdir() if not path.is_symlink() and (path / POOL_STATE).exists()
        )
        for pool in pools:
            try:
                with opened(pool, DIR) as fd:
                    slots, verified = read_pool(fd)
                    if not verified:
                        print(f"{str(pool)!r}: reservation state is not schema v4; "
                              "each slot must also be untouched for 24 hours")
                    for name, (slot, _) in slots.items():
                        try:
                            for size in clean_slot(fd, pool, name, slot, state_dirs, args.apply):
                                total += size
                        except Keep as exc:
                            print(f"{str(slot)!r}: skipped: {exc}")
                        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
                            failed = True
                            detail = str(exc) if type(exc) is RuntimeError else type(exc).__name__
                            print(f"{str(slot)!r}: stopped: could not verify or finish ({detail})")
            except (Keep, OSError, ValueError) as exc:
                failed = True
                print(f"{str(pool)!r}: skipped pool: {exc if isinstance(exc, Keep) else type(exc).__name__}")
    except OSError as exc:
        failed = True
        print(f"could not enumerate Treehouse pools ({type(exc).__name__})", file=sys.stderr)
    print(f"Total {'estimated bytes freed' if args.apply else 'estimated bytes reclaimable (dry-run)'}: {total}")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
