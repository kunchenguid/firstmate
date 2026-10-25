#!/usr/bin/env python3
"""Descriptor-safe filesystem engine for fm-record-export.sh.

The shell wrapper owns the public command line and task-lock integration.
This helper owns configured path traversal, the dedicated-root marker, exact
live snapshots, archive transactions, strict manifests, and durability.
"""

from __future__ import annotations

import errno
import hashlib
import json
import os
import re
import stat
import sys
import time
import uuid
from dataclasses import dataclass
from typing import Iterable


ROOT_SCHEMA = "firstmate-record-export-root.v1"
ROOT_MARKER = ".firstmate-record-export-root.v1.json"
LIVE_GENERATIONS = ".live-generations"
SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]*$")
INBOX_MESSAGE = re.compile(r"^[0-9]+\.msg$")
GENERATION_NAME = re.compile(r"^g[0-9]+\.[0-9]+\.[a-f0-9]+$")
STAGE_NAME = re.compile(r"^\.stage-[0-9]+-[a-f0-9]+$")
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0)
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


class ExportError(RuntimeError):
    pass


def fail(message: str) -> "NoReturn":
    raise ExportError(message)


def json_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def parse_json(data: bytes, label: str) -> object:
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=json_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"invalid {label}: {exc}")


def safe_component(value: str, label: str) -> None:
    if not SAFE_COMPONENT.fullmatch(value) or value in {".", ".."}:
        fail(f"unsafe {label}: {value}")


def read_all(fd: int) -> bytes:
    chunks: list[bytes] = []
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            fail("short write while publishing record export")
        view = view[written:]


def fd_identity(fd: int) -> tuple[int, int]:
    info = os.fstat(fd)
    return info.st_dev, info.st_ino


def stat_identity(info: os.stat_result) -> tuple[int, int]:
    return info.st_dev, info.st_ino


def stable_identity(info: os.stat_result) -> tuple[int, int, int, int]:
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def open_absolute_directory(path: str, label: str) -> int:
    if not os.path.isabs(path):
        fail(f"{label} must be absolute: {path}")
    parts = [part for part in path.split(os.sep) if part]
    fd = os.open(os.sep, DIR_FLAGS)
    try:
        for part in parts:
            if part in {".", ".."}:
                fail(f"{label} contains an unsafe component: {path}")
            next_fd = os.open(part, DIR_FLAGS | NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except Exception:
        os.close(fd)
        raise


def open_parent_for_new_directory(path: str, label: str) -> tuple[int, str]:
    normalized = path.rstrip(os.sep)
    if not normalized or normalized == os.sep:
        fail(f"{label} must not be the filesystem root")
    parent, name = os.path.split(normalized)
    if name in {"", ".", ".."}:
        fail(f"{label} has an unsafe final component")
    return open_absolute_directory(parent or os.sep, f"{label} parent"), name


def open_regular_at(parent_fd: int, name: str, label: str) -> tuple[int, os.stat_result]:
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise
    if not stat.S_ISREG(before.st_mode):
        fail(f"{label} is not a regular non-symlink file")
    try:
        fd = os.open(name, os.O_RDONLY | NOFOLLOW | getattr(os, "O_CLOEXEC", 0), dir_fd=parent_fd)
    except OSError as exc:
        fail(f"cannot open {label}: {exc.strerror}")
    after = os.fstat(fd)
    if not stat.S_ISREG(after.st_mode) or stat_identity(before) != fd_identity(fd):
        os.close(fd)
        fail(f"{label} changed while it was opened")
    return fd, after


def open_directory_at(parent_fd: int, name: str, label: str) -> int:
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as exc:
        fail(f"cannot inspect {label}: {exc.strerror}")
    if not stat.S_ISDIR(before.st_mode):
        fail(f"{label} is not a real directory")
    try:
        fd = os.open(name, DIR_FLAGS | NOFOLLOW, dir_fd=parent_fd)
    except OSError as exc:
        fail(f"cannot open {label}: {exc.strerror}")
    if stat_identity(before) != fd_identity(fd):
        os.close(fd)
        fail(f"{label} changed while it was opened")
    return fd


def ensure_directory_at(parent_fd: int, name: str, label: str) -> int:
    if name != LIVE_GENERATIONS:
        safe_component(name, label)
    try:
        os.mkdir(name, 0o750, dir_fd=parent_fd)
        os.fsync(parent_fd)
    except FileExistsError:
        pass
    fd = open_directory_at(parent_fd, name, label)
    os.fchmod(fd, 0o750)
    return fd


def atomic_write_at(parent_fd: int, name: str, data: bytes, mode: int = 0o640) -> None:
    token = uuid.uuid4().hex
    temporary = f".record-export-{os.getpid()}-{token}"
    fd = -1
    try:
        fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            mode,
            dir_fd=parent_fd,
        )
        write_all(fd, data)
        os.fchmod(fd, mode)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError:
            pass


def read_config(config_path: str) -> str | None:
    config_fd = open_absolute_directory(config_path, "record export config directory")
    try:
        try:
            fd, _ = open_regular_at(config_fd, "record-export-root", "record export config")
        except FileNotFoundError:
            return None
        try:
            data = read_all(fd)
        finally:
            os.close(fd)
    finally:
        os.close(config_fd)
    if b"\x00" in data:
        fail("record export config contains a NUL byte")
    lines = data.splitlines()
    if len(lines) != 1 or not lines[0]:
        fail("record export config must contain exactly one non-empty line")
    try:
        root = os.fsdecode(lines[0])
    except UnicodeDecodeError:
        fail("record export config is not valid filesystem text")
    if not os.path.isabs(root):
        fail("record export root must be absolute")
    return root


def canonical_path(path: str) -> str:
    return os.path.normpath(os.path.realpath(path))


def paths_overlap(left: str, right: str) -> bool:
    try:
        common = os.path.commonpath([left, right])
    except ValueError:
        return False
    return common == left or common == right


def validate_disjoint_root(root: str, protected: Iterable[tuple[str, str]]) -> None:
    root_path = canonical_path(root)
    for label, path in protected:
        protected_path = canonical_path(path)
        if paths_overlap(root_path, protected_path):
            fail(f"record export root overlaps the effective {label} root: {root}")


def root_marker(home: str) -> bytes:
    document = {
        "schema": ROOT_SCHEMA,
        "schema_version": 1,
        "home": canonical_path(home),
    }
    return (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def validate_root_marker(root_fd: int, home: str) -> None:
    try:
        fd, _ = open_regular_at(root_fd, ROOT_MARKER, "record export ownership marker")
    except FileNotFoundError:
        fail("existing record export root has no ownership marker")
    try:
        value = parse_json(read_all(fd), "record export ownership marker")
    finally:
        os.close(fd)
    expected = {
        "schema": ROOT_SCHEMA,
        "schema_version": 1,
        "home": canonical_path(home),
    }
    if value != expected:
        fail("record export root is owned by another home or has an invalid marker")


def validate_root_entries(root_fd: int) -> None:
    allowed = {ROOT_MARKER, LIVE_GENERATIONS, "live", "archive"}
    for name in os.listdir(root_fd):
        if name not in allowed:
            fail(f"unknown artifact in dedicated record export root: {name}")
        info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        if name == ROOT_MARKER and not stat.S_ISREG(info.st_mode):
            fail("record export ownership marker is unsafe")
        if name in {LIVE_GENERATIONS, "archive"} and not stat.S_ISDIR(info.st_mode):
            fail(f"record export managed directory is unsafe: {name}")
        if name == "live":
            if not stat.S_ISLNK(info.st_mode):
                fail("record export live pointer is unsafe")
            target = os.readlink(name, dir_fd=root_fd)
            if not re.fullmatch(r"\.live-generations/" + GENERATION_NAME.pattern[1:-1], target):
                fail("record export live pointer has an unsafe target")


def open_export_root(root: str, home: str, protected: Iterable[tuple[str, str]]) -> int:
    if os.path.normpath(root) == os.sep:
        fail("record export root must not be the filesystem root")
    validate_disjoint_root(root, protected)
    parent_fd, name = open_parent_for_new_directory(root, "record export root")
    created = False
    try:
        try:
            root_fd = open_directory_at(parent_fd, name, "record export root")
        except ExportError:
            try:
                os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                os.mkdir(name, 0o750, dir_fd=parent_fd)
                os.fsync(parent_fd)
                root_fd = open_directory_at(parent_fd, name, "record export root")
                created = True
            else:
                raise
    finally:
        os.close(parent_fd)
    try:
        os.fchmod(root_fd, 0o750)
        if created:
            fd = os.open(
                ROOT_MARKER,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
                0o640,
                dir_fd=root_fd,
            )
            try:
                write_all(fd, root_marker(home))
                os.fchmod(fd, 0o640)
                os.fsync(fd)
            finally:
                os.close(fd)
            os.fsync(root_fd)
        validate_root_marker(root_fd, home)
        validate_root_entries(root_fd)
        return root_fd
    except Exception:
        os.close(root_fd)
        raise


@dataclass
class Source:
    relative: str
    fd: int
    initial: os.stat_result

    def close(self) -> None:
        os.close(self.fd)


def add_source(sources: list[Source], parent_fd: int, name: str, relative: str, label: str) -> None:
    try:
        fd, info = open_regular_at(parent_fd, name, label)
    except FileNotFoundError:
        return
    sources.append(Source(relative, fd, info))


def collect_data_sources(data_fd: int) -> list[Source]:
    sources: list[Source] = []
    for name in ("projects.md", "backlog.md", "done-archive.md"):
        add_source(sources, data_fd, name, f"data/{name}", f"data/{name}")
    for task in sorted(os.listdir(data_fd)):
        if task in {"projects.md", "backlog.md", "done-archive.md"}:
            continue
        try:
            info = os.stat(task, dir_fd=data_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if not stat.S_ISDIR(info.st_mode):
            continue
        task_fd = open_directory_at(data_fd, task, f"data task directory {task}")
        try:
            names = set(os.listdir(task_fd))
            candidates = [name for name in ("brief.md", "report.md") if name in names]
            candidates.extend(sorted(name for name in names if name.startswith("status") and name.endswith(".log")))
            if not candidates:
                continue
            safe_component(task, "task directory in record export allowlist")
            for name in candidates:
                safe_component(name, "data record name")
                add_source(sources, task_fd, name, f"data/{task}/{name}", f"data/{task}/{name}")
        finally:
            os.close(task_fd)
    return sources


def collect_inbox_sources(state_fd: int, inbox_name: str, task: str, sources: list[Source]) -> None:
    inbox_fd = open_directory_at(state_fd, inbox_name, f"state inbox {inbox_name}")
    try:
        for name in sorted(os.listdir(inbox_fd)):
            if INBOX_MESSAGE.fullmatch(name):
                add_source(sources, inbox_fd, name, f"state/{inbox_name}/{name}", f"state/{inbox_name}/{name}")
        try:
            handled_info = os.stat("handled", dir_fd=inbox_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        if not stat.S_ISDIR(handled_info.st_mode):
            fail(f"state/{inbox_name}/handled is not a real directory")
        handled_fd = open_directory_at(inbox_fd, "handled", f"state/{inbox_name}/handled")
        try:
            for name in sorted(os.listdir(handled_fd)):
                if INBOX_MESSAGE.fullmatch(name):
                    add_source(
                        sources,
                        handled_fd,
                        name,
                        f"state/{task}.inbox/handled/{name}",
                        f"state/{task}.inbox/handled/{name}",
                    )
        finally:
            os.close(handled_fd)
    finally:
        os.close(inbox_fd)


def collect_state_sources(state_fd: int) -> list[Source]:
    sources: list[Source] = []
    add_source(sources, state_fd, "fleet-ledger.jsonl", "state/fleet-ledger.jsonl", "state/fleet-ledger.jsonl")
    names = sorted(os.listdir(state_fd))
    for name in names:
        if name.endswith(".meta"):
            task = name[: -len(".meta")]
            safe_component(task, "task metadata name")
            add_source(sources, state_fd, name, f"state/{name}", f"state/{name}")
        elif name.endswith(".status"):
            task = name[: -len(".status")]
            safe_component(task, "task status name")
            add_source(sources, state_fd, name, f"state/{name}", f"state/{name}")
        elif name.endswith(".inbox"):
            task = name[: -len(".inbox")]
            safe_component(task, "task inbox name")
            collect_inbox_sources(state_fd, name, task, sources)
    return sources


def ensure_relative_directory(root_fd: int, parts: list[str]) -> int:
    fd = os.dup(root_fd)
    try:
        for part in parts:
            next_fd = ensure_directory_at(fd, part, "record export snapshot directory")
            os.close(fd)
            fd = next_fd
        return fd
    except Exception:
        os.close(fd)
        raise


def copy_source(source: Source, stage_fd: int) -> None:
    parts = source.relative.split("/")
    for part in parts:
        safe_component(part, "record export relative path")
    parent_fd = ensure_relative_directory(stage_fd, parts[:-1])
    destination_fd = -1
    source_digest = hashlib.sha256()
    try:
        destination_fd = os.open(
            parts[-1],
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            0o640,
            dir_fd=parent_fd,
        )
        os.lseek(source.fd, 0, os.SEEK_SET)
        while True:
            chunk = os.read(source.fd, 1024 * 1024)
            if not chunk:
                break
            source_digest.update(chunk)
            write_all(destination_fd, chunk)
        os.fchmod(destination_fd, 0o640)
        os.fsync(destination_fd)
        after = os.fstat(source.fd)
        if stable_identity(source.initial) != stable_identity(after):
            fail(f"record export source changed during live capture: {source.relative}")
        os.lseek(source.fd, 0, os.SEEK_SET)
        verify_digest = hashlib.sha256()
        while True:
            chunk = os.read(source.fd, 1024 * 1024)
            if not chunk:
                break
            verify_digest.update(chunk)
        if source_digest.digest() != verify_digest.digest():
            fail(f"record export source changed during live capture: {source.relative}")
    finally:
        if destination_fd >= 0:
            os.close(destination_fd)
        os.fsync(parent_fd)
        os.close(parent_fd)


def remove_tree_at(parent_fd: int, name: str) -> None:
    info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode):
        fail(f"refusing to remove unsafe record export artifact: {name}")
    fd = open_directory_at(parent_fd, name, f"record export artifact {name}")
    try:
        for child in os.listdir(fd):
            child_info = os.stat(child, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISDIR(child_info.st_mode):
                remove_tree_at(fd, child)
            elif stat.S_ISREG(child_info.st_mode):
                os.unlink(child, dir_fd=fd)
            else:
                fail(f"refusing to remove unsafe record export artifact: {name}/{child}")
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=parent_fd)
    os.fsync(parent_fd)


def sync_records(home: str, config: str, data: str, state: str) -> None:
    configured_root = read_config(config)
    if configured_root is None:
        return
    data_fd = open_absolute_directory(data, "data root")
    state_fd = open_absolute_directory(state, "state root")
    root_fd = -1
    sources: list[Source] = []
    try:
        root_fd = open_export_root(
            configured_root,
            home,
            (("home", home), ("config", config), ("data", data), ("state", state)),
        )
        sources = collect_data_sources(data_fd) + collect_state_sources(state_fd)
        generations_fd = ensure_directory_at(root_fd, LIVE_GENERATIONS, "record export live generations")
        try:
            stage_name = f".stage-{os.getpid()}-{uuid.uuid4().hex}"
            os.mkdir(stage_name, 0o750, dir_fd=generations_fd)
            stage_fd = open_directory_at(generations_fd, stage_name, "record export live staging generation")
            try:
                for source in sources:
                    copy_source(source, stage_fd)
                os.fsync(stage_fd)
            except Exception:
                os.close(stage_fd)
                stage_fd = -1
                remove_tree_at(generations_fd, stage_name)
                raise
            finally:
                if stage_fd >= 0:
                    os.close(stage_fd)

            current_generations = os.stat(LIVE_GENERATIONS, dir_fd=root_fd, follow_symlinks=False)
            if not stat.S_ISDIR(current_generations.st_mode) \
                    or stat_identity(current_generations) != fd_identity(generations_fd):
                remove_tree_at(generations_fd, stage_name)
                fail("record export live generations directory changed before publication")

            generation_name = f"g{time.time_ns()}.{os.getpid()}.{uuid.uuid4().hex}"
            os.rename(stage_name, generation_name, src_dir_fd=generations_fd, dst_dir_fd=generations_fd)
            os.fsync(generations_fd)
            pointer_name = f".live-next-{os.getpid()}-{uuid.uuid4().hex}"
            os.symlink(f"{LIVE_GENERATIONS}/{generation_name}", pointer_name, dir_fd=root_fd)
            try:
                os.replace(pointer_name, "live", src_dir_fd=root_fd, dst_dir_fd=root_fd)
                os.fsync(root_fd)
            finally:
                try:
                    os.unlink(pointer_name, dir_fd=root_fd)
                except FileNotFoundError:
                    pass

            for name in os.listdir(generations_fd):
                if name == generation_name:
                    continue
                if not (GENERATION_NAME.fullmatch(name) or STAGE_NAME.fullmatch(name)):
                    fail(f"unknown record export live generation artifact: {name}")
                try:
                    remove_tree_at(generations_fd, name)
                except ExportError as exc:
                    print(f"warning: could not remove stale live generation {name}: {exc}", file=sys.stderr)
        finally:
            os.close(generations_fd)
    finally:
        for source in sources:
            source.close()
        if root_fd >= 0:
            os.close(root_fd)
        os.close(state_fd)
        os.close(data_fd)


def main(argv: list[str]) -> int:
    if argv != ["sync"]:
        print("usage: fm-record-export.py sync", file=sys.stderr)
        return 2
    script_dir = os.path.dirname(os.path.realpath(__file__))
    root = os.environ.get("FM_ROOT_OVERRIDE", os.path.dirname(script_dir))
    home = os.environ.get("FM_HOME", root)
    config = os.environ.get("FM_CONFIG_OVERRIDE", os.path.join(home, "config"))
    data = os.environ.get("FM_DATA_OVERRIDE", os.path.join(home, "data"))
    state = os.environ.get("FM_STATE_OVERRIDE", os.path.join(home, "state"))
    sync_records(home, config, data, state)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ExportError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
    except OSError as exc:
        detail = exc.strerror or str(exc)
        if exc.filename:
            detail = f"{detail}: {exc.filename}"
        print(f"error: record export filesystem operation failed: {detail}", file=sys.stderr)
        raise SystemExit(1)
