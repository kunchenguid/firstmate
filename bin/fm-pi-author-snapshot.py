#!/usr/bin/env python3
"""Copy one Pi home into a bounded task-private author snapshot.

Regular files and directories are copied descriptor-relative without following
links, with owner-only modes, source identity rechecks, and the existing entry,
per-file, and total-byte bounds. Top-level sessions, backup, and editor-temp
entries remain excluded, and an empty private sessions directory is added.

Relative symlinks are preserved as links only after their complete captured
source and destination graphs resolve to copied regular files or directories
inside their respective roots. Absolute, escaping, dangling, looping, changing,
excluded, and special-file targets fail the whole snapshot. Symlinks consume the
same entry budget as regular files so a link farm cannot bypass the bound.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import stat
import sys
from typing import Dict, NamedTuple, Optional, Set, Tuple


MAX_FILES = 20_000
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_FILE_BYTES = 16 * 1024 * 1024
# Darwin permits at most 32 symlink dereferences while resolving one path;
# Linux permits 40. Keeping snapshots within the lower supported-host limit
# prevents both unusable link chains and expansion work that can grow
# exponentially while still preserving normal package-manager shims.
MAX_SYMLINK_DEREFERENCES = 32

DIRECTORY_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)

RelativePath = Tuple[str, ...]
Fingerprint = Tuple[int, int, int, int, int, int]


class Node(NamedTuple):
    kind: str
    fingerprint: Fingerprint
    target: Optional[str]


class SnapshotError(RuntimeError):
    pass


def fingerprint(metadata: os.stat_result) -> Fingerprint:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        getattr(metadata, "st_mtime_ns", int(metadata.st_mtime * 1_000_000_000)),
        getattr(metadata, "st_ctime_ns", int(metadata.st_ctime * 1_000_000_000)),
    )


def same_copy_identity(actual: os.stat_result, expected: os.stat_result) -> bool:
    return (
        actual.st_dev,
        actual.st_ino,
        actual.st_size,
    ) == (
        expected.st_dev,
        expected.st_ino,
        expected.st_size,
    )


def kind(metadata: os.stat_result) -> str:
    if stat.S_ISDIR(metadata.st_mode):
        return "directory"
    if stat.S_ISREG(metadata.st_mode):
        return "file"
    if stat.S_ISLNK(metadata.st_mode):
        return "symlink"
    return "special"


def shown(root: Path, relative: RelativePath) -> Path:
    return root.joinpath(*relative)


def copy_file(
    source_directory: int,
    destination_directory: int,
    name: str,
    source_path: Path,
    expected: os.stat_result,
) -> Tuple[int, Fingerprint]:
    if expected.st_size > MAX_FILE_BYTES:
        raise SnapshotError(f"source file exceeds the per-file bound: {source_path}")
    source_descriptor = os.open(
        name, os.O_RDONLY | NOFOLLOW, dir_fd=source_directory
    )
    destination_descriptor = -1
    try:
        actual = os.fstat(source_descriptor)
        if not stat.S_ISREG(actual.st_mode) or not same_copy_identity(actual, expected):
            raise SnapshotError(f"source file changed during snapshot: {source_path}")
        initial = fingerprint(actual)
        mode = 0o700 if actual.st_mode & 0o111 else 0o600
        destination_descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW,
            mode,
            dir_fd=destination_directory,
        )
        os.fchmod(destination_descriptor, mode)
        copied = 0
        while True:
            chunk = os.read(
                source_descriptor, min(1024 * 1024, MAX_FILE_BYTES + 1 - copied)
            )
            if not chunk:
                break
            copied += len(chunk)
            if copied > MAX_FILE_BYTES:
                raise SnapshotError(f"source file exceeds the per-file bound: {source_path}")
            written = 0
            while written < len(chunk):
                written += os.write(destination_descriptor, chunk[written:])
        final = os.fstat(source_descriptor)
        if fingerprint(final) != initial:
            raise SnapshotError(f"source file changed during snapshot: {source_path}")
        os.fsync(destination_descriptor)
        return copied, fingerprint(os.fstat(destination_descriptor))
    finally:
        os.close(source_descriptor)
        if destination_descriptor >= 0:
            os.close(destination_descriptor)


def resolve_link(
    link_path: RelativePath, manifest: Dict[RelativePath, Node]
) -> Tuple[RelativePath, Set[RelativePath]]:
    link = manifest[link_path]
    if link.target is None or os.path.isabs(link.target):
        raise SnapshotError(f"Pi source contains an unsafe symlink: {'/'.join(link_path)}")

    remaining = [(part, frozenset({link_path})) for part in link.target.split("/")]
    resolved = list(link_path[:-1])
    dependencies: Set[RelativePath] = set()
    dereferences = 1
    while remaining:
        component, active = remaining.pop(0)
        if component in ("", "."):
            continue
        if component == "..":
            if not resolved:
                raise SnapshotError(
                    f"Pi source symlink escapes its snapshot root: {'/'.join(link_path)}"
                )
            resolved.pop()
            continue

        candidate = tuple(resolved + [component])
        node = manifest.get(candidate)
        if node is None:
            raise SnapshotError(
                f"Pi source symlink is dangling or targets excluded content: {'/'.join(link_path)}"
            )
        dependencies.add(candidate)
        if node.kind == "symlink":
            dereferences += 1
            if dereferences > MAX_SYMLINK_DEREFERENCES:
                raise SnapshotError(
                    "Pi source symlink exceeds the resolution bound: "
                    f"{'/'.join(link_path)}"
                )
            if candidate in active:
                raise SnapshotError(
                    f"Pi source contains a symlink loop: {'/'.join(link_path)}"
                )
            if node.target is None or os.path.isabs(node.target):
                raise SnapshotError(
                    f"Pi source contains an unsafe symlink: {'/'.join(candidate)}"
                )
            resolved = list(candidate[:-1])
            remaining = [
                (part, active | {candidate}) for part in node.target.split("/")
            ] + remaining
            continue
        if node.kind == "directory":
            resolved.append(component)
            continue
        if node.kind == "file":
            if remaining:
                raise SnapshotError(
                    f"Pi source symlink traverses a non-directory: {'/'.join(link_path)}"
                )
            resolved.append(component)
            continue
        raise SnapshotError(
            f"Pi source symlink targets a special file: {'/'.join(link_path)}"
        )

    final_path = tuple(resolved)
    final = manifest.get(final_path)
    if final is None or final.kind not in ("directory", "file"):
        raise SnapshotError(
            f"Pi source symlink does not resolve to copied content: {'/'.join(link_path)}"
        )
    return final_path, dependencies


def reject_directory_cycles(
    manifest: Dict[RelativePath, Node],
    resolutions: Dict[RelativePath, RelativePath],
) -> None:
    directories = {
        path for path, node in manifest.items() if node.kind == "directory"
    }
    edges = {path: set() for path in directories}  # type: Dict[RelativePath, Set[RelativePath]]
    for path in directories:
        if path:
            edges[path[:-1]].add(path)
    for link_path, target_path in resolutions.items():
        if manifest[target_path].kind == "directory":
            edges[link_path[:-1]].add(target_path)

    indegree = {path: 0 for path in directories}
    for targets in edges.values():
        for target in targets:
            indegree[target] += 1
    ready = [path for path, count in indegree.items() if count == 0]
    visited = 0
    while ready:
        current = ready.pop()
        visited += 1
        for target in edges[current]:
            indegree[target] -= 1
            if indegree[target] == 0:
                ready.append(target)
    if visited != len(directories):
        raise SnapshotError("Pi source contains a directory symlink loop")


def verify_source_node(
    root_descriptor: int,
    source_root: Path,
    relative: RelativePath,
    manifest: Dict[RelativePath, Node],
) -> os.stat_result:
    expected = manifest[relative]
    if not relative:
        metadata = os.fstat(root_descriptor)
        if fingerprint(metadata) != expected.fingerprint:
            raise SnapshotError(f"source directory changed during snapshot: {source_root}")
        return metadata

    descriptor = os.dup(root_descriptor)
    try:
        for index, component in enumerate(relative[:-1], start=1):
            child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            parent_path = relative[:index]
            parent = manifest.get(parent_path)
            if (
                parent is None
                or parent.kind != "directory"
                or fingerprint(os.fstat(descriptor)) != parent.fingerprint
            ):
                raise SnapshotError(
                    f"source directory changed during snapshot: {shown(source_root, parent_path)}"
                )
        metadata = os.stat(relative[-1], dir_fd=descriptor, follow_symlinks=False)
        if fingerprint(metadata) != expected.fingerprint:
            raise SnapshotError(
                f"source entry changed during snapshot: {shown(source_root, relative)}"
            )
        if expected.kind == "symlink" and os.readlink(
            relative[-1], dir_fd=descriptor
        ) != expected.target:
            raise SnapshotError(
                f"source symlink changed during snapshot: {shown(source_root, relative)}"
            )
        return metadata
    finally:
        os.close(descriptor)


def verify_destination_node(
    root_descriptor: int,
    destination_root: Path,
    relative: RelativePath,
    manifest: Dict[RelativePath, Node],
) -> None:
    metadata = verify_source_node(
        root_descriptor, destination_root, relative, manifest
    )
    expected = manifest[relative]
    if kind(metadata) != expected.kind:
        raise SnapshotError(
            f"destination entry changed during snapshot: {shown(destination_root, relative)}"
        )
    if expected.kind == "directory" and stat.S_IMODE(metadata.st_mode) != 0o700:
        raise SnapshotError(
            f"destination directory permissions are unsafe: {shown(destination_root, relative)}"
        )
    if expected.kind == "file":
        expected_mode = 0o700 if expected.fingerprint[2] & 0o111 else 0o600
        if stat.S_IMODE(metadata.st_mode) != expected_mode:
            raise SnapshotError(
                f"destination file permissions are unsafe: {shown(destination_root, relative)}"
            )


def verify_link_graphs(
    source_descriptor: int,
    destination_descriptor: int,
    source_root: Path,
    destination_root: Path,
    manifest: Dict[RelativePath, Node],
    destination_manifest: Dict[RelativePath, Node],
) -> None:
    resolutions: Dict[RelativePath, RelativePath] = {}
    for path, node in manifest.items():
        if node.kind != "symlink":
            continue
        final_path, _ = resolve_link(path, manifest)
        resolutions[path] = final_path

    reject_directory_cycles(manifest, resolutions)
    for path, target in resolutions.items():
        destination_target, _ = resolve_link(path, destination_manifest)
        if destination_target != target:
            raise SnapshotError("destination symlink graph changed during snapshot")
    for _ in range(2):
        for root, graph in (
            (source_root, manifest), (destination_root, destination_manifest)
        ):
            if fingerprint(os.stat(root, follow_symlinks=False)) != graph[()].fingerprint:
                raise SnapshotError(f"snapshot root changed during capture: {root}")
        for path in sorted(manifest, key=lambda value: (len(value), value)):
            verify_source_node(source_descriptor, source_root, path, manifest)
            verify_destination_node(
                destination_descriptor, destination_root, path, destination_manifest
            )


def copy_tree(source: Path, destination: Path) -> None:
    counters = {"files": 0, "bytes": 0}
    manifest: Dict[RelativePath, Node] = {}
    destination_manifest: Dict[RelativePath, Node] = {}

    source_metadata = os.stat(source, follow_symlinks=False)
    if not stat.S_ISDIR(source_metadata.st_mode):
        raise SnapshotError(f"source directory is unsafe: {source}")
    source_descriptor = os.open(source, DIRECTORY_FLAGS)
    destination_descriptor = -1
    try:
        source_actual = os.fstat(source_descriptor)
        if fingerprint(source_actual) != fingerprint(source_metadata):
            raise SnapshotError(f"source directory changed during snapshot: {source}")
        manifest[()] = Node("directory", fingerprint(source_actual), None)

        os.mkdir(destination, 0o700)
        destination_descriptor = os.open(destination, DIRECTORY_FLAGS)
        os.fchmod(destination_descriptor, 0o700)

        def consume_entry() -> None:
            counters["files"] += 1
            if counters["files"] > MAX_FILES:
                raise SnapshotError("Pi source exceeds the file-count bound")

        def visit(
            source_directory: int,
            destination_directory: int,
            relative_directory: RelativePath,
            depth: int,
        ) -> None:
            for name in sorted(os.listdir(source_directory)):
                if depth == 0 and (
                    name == "sessions" or ".bak" in name or name.endswith("~")
                ):
                    continue
                relative = relative_directory + (name,)
                source_path = shown(source, relative)
                entry_metadata = os.stat(
                    name, dir_fd=source_directory, follow_symlinks=False
                )
                entry_kind = kind(entry_metadata)
                if entry_kind == "directory":
                    node = Node("directory", fingerprint(entry_metadata), None)
                    manifest[relative] = node
                    source_child = os.open(
                        name, DIRECTORY_FLAGS, dir_fd=source_directory
                    )
                    destination_child = -1
                    try:
                        if fingerprint(os.fstat(source_child)) != node.fingerprint:
                            raise SnapshotError(
                                f"source directory changed during snapshot: {source_path}"
                            )
                        os.mkdir(name, 0o700, dir_fd=destination_directory)
                        destination_child = os.open(
                            name, DIRECTORY_FLAGS, dir_fd=destination_directory
                        )
                        os.fchmod(destination_child, 0o700)
                        visit(source_child, destination_child, relative, depth + 1)
                        destination_final = os.fstat(destination_child)
                        destination_manifest[relative] = Node(
                            "directory", fingerprint(destination_final), None
                        )
                        if fingerprint(os.fstat(source_child)) != node.fingerprint:
                            raise SnapshotError(
                                f"source directory changed during snapshot: {source_path}"
                            )
                    finally:
                        os.close(source_child)
                        if destination_child >= 0:
                            os.close(destination_child)
                elif entry_kind == "file":
                    consume_entry()
                    node = Node("file", fingerprint(entry_metadata), None)
                    manifest[relative] = node
                    copied, destination_fingerprint = copy_file(
                        source_directory,
                        destination_directory,
                        name,
                        source_path,
                        entry_metadata,
                    )
                    counters["bytes"] += copied
                    destination_manifest[relative] = Node(
                        "file", destination_fingerprint, None
                    )
                    if counters["bytes"] > MAX_TOTAL_BYTES:
                        raise SnapshotError("Pi source exceeds the total-size bound")
                elif entry_kind == "symlink":
                    consume_entry()
                    target = os.readlink(name, dir_fd=source_directory)
                    if os.path.isabs(target):
                        raise SnapshotError(
                            f"Pi source contains an absolute symlink: {source_path}"
                        )
                    actual = os.stat(
                        name, dir_fd=source_directory, follow_symlinks=False
                    )
                    if fingerprint(actual) != fingerprint(entry_metadata):
                        raise SnapshotError(
                            f"source symlink changed during snapshot: {source_path}"
                        )
                    node = Node("symlink", fingerprint(actual), target)
                    manifest[relative] = node
                    os.symlink(target, name, dir_fd=destination_directory)
                    destination_link = os.stat(
                        name, dir_fd=destination_directory, follow_symlinks=False
                    )
                    destination_manifest[relative] = Node(
                        "symlink", fingerprint(destination_link), target
                    )
                    if not stat.S_ISLNK(destination_link.st_mode) or os.readlink(
                        name, dir_fd=destination_directory
                    ) != target:
                        raise SnapshotError(
                            f"destination symlink changed during snapshot: {shown(destination, relative)}"
                        )
                else:
                    raise SnapshotError(
                        f"Pi source contains an unsafe entry: {source_path}"
                    )

        visit(source_descriptor, destination_descriptor, (), 0)
        os.mkdir("sessions", 0o700, dir_fd=destination_descriptor)
        sessions_descriptor = os.open(
            "sessions", DIRECTORY_FLAGS, dir_fd=destination_descriptor
        )
        try:
            os.fchmod(sessions_descriptor, 0o700)
        finally:
            os.close(sessions_descriptor)
        destination_manifest[()] = Node(
            "directory", fingerprint(os.fstat(destination_descriptor)), None
        )
        verify_link_graphs(
            source_descriptor,
            destination_descriptor,
            source,
            destination,
            manifest,
            destination_manifest,
        )
    finally:
        os.close(source_descriptor)
        if destination_descriptor >= 0:
            os.close(destination_descriptor)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: fm-pi-author-snapshot.py SOURCE DESTINATION", file=sys.stderr)
        return 2
    source_value, destination_value = sys.argv[1:]
    source = Path(source_value)
    destination = Path(destination_value)
    if not source.is_absolute() or not destination.is_absolute():
        print("Pi snapshot paths must be absolute", file=sys.stderr)
        return 1
    if destination.exists() or destination.is_symlink():
        print(f"Pi snapshot destination already exists: {destination}", file=sys.stderr)
        return 1
    try:
        copy_tree(source, destination)
    except (OSError, ValueError, UnicodeError, SnapshotError) as exc:
        shutil.rmtree(destination, ignore_errors=True)
        print(f"Pi author snapshot failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
