#!/usr/bin/env python3
"""Incremental, content-addressed backup for the canonical Firstmate tree."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any


CANONICAL_SOURCE = Path("/home/ale/firstmate")
CANONICAL_DESTINATION = Path("/mnt/h/Firstmate-Backup")
ROOT_MARKER = ".replicante-root.json"
LATEST_MARKER = "latest"
SNAPSHOT_FORMAT = "replicante-snapshot-v1"
ROOT_FORMAT = "replicante-root-v1"
SNAPSHOT_ID_RE = re.compile(r"^[0-9a-f]{64}$")


def fail(message: str) -> None:
    print(f"fm-replicante: {message}", file=sys.stderr)
    raise SystemExit(1)


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def read_bytes(path: Path) -> bytes:
    try:
        with path.open("rb") as handle:
            return handle.read()
    except OSError as exc:
        fail(f"cannot read {path}: {exc}")


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(read_bytes(path).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"invalid JSON in {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"JSON root is not an object: {path}")
    return value


def atomic_write(path: Path, content: bytes) -> None:
    temporary = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.tmp-",
            dir=path.parent,
        )
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
        os.replace(temporary, path)
        temporary = None
    except OSError as exc:
        fail(f"cannot atomically write {path}: {exc}")
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def ensure_directory(path: Path) -> None:
    if path.is_symlink():
        fail(f"path must not be a symbolic link: {path}")
    if path.exists():
        if not path.is_dir():
            fail(f"path is not a directory: {path}")
        return
    try:
        path.mkdir()
    except OSError as exc:
        fail(f"cannot create directory {path}: {exc}")


def is_under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def resolve_paths(command: str) -> tuple[Path, Path, bool]:
    test_mode = os.environ.get("REPLICANTE_TEST_MODE") == "1"
    test_source = os.environ.get("REPLICANTE_TEST_SOURCE")
    test_destination = os.environ.get("REPLICANTE_TEST_DESTINATION")
    if test_mode:
        if not test_source or not test_destination:
            fail("fixture mode requires REPLICANTE_TEST_SOURCE and REPLICANTE_TEST_DESTINATION")
        source = Path(test_source)
        destination = Path(test_destination)
    else:
        if test_source or test_destination:
            fail("test source or destination overrides require REPLICANTE_TEST_MODE=1")
        source = CANONICAL_SOURCE
        destination = CANONICAL_DESTINATION

    source_text = os.path.realpath(source)
    destination_text = os.path.realpath(destination)
    if not test_mode:
        if source_text != str(CANONICAL_SOURCE) or destination_text != str(CANONICAL_DESTINATION):
            fail("operational paths are not the canonical source and destination")
        if not Path("/mnt/h").is_dir() or Path("/mnt/h").is_symlink():
            fail("H: volume is unavailable at /mnt/h")
        if not os.path.ismount("/mnt/h"):
            fail("H: volume is not mounted at /mnt/h")

    if source_text == destination_text:
        fail("source and backup destination are the same path")
    source_absolute = Path(source_text)
    destination_absolute = Path(destination_text)
    if is_under(destination_absolute, source_absolute) or is_under(source_absolute, destination_absolute):
        fail("source and backup destination must not contain one another")
    if not test_mode and is_under(destination_absolute, Path("/mnt/d")):
        fail("backup destination must not touch the D: tree")
    if command == "run" and not source_absolute.is_dir():
        fail(f"canonical source is not an existing directory: {source_absolute}")
    return source_absolute, destination_absolute, test_mode


def git_output(root: Path, arguments: list[str], allow_failure: bool = False) -> str:
    command = [
        "git",
        "-c",
        f"safe.directory={root}",
        "-C",
        str(root),
        *arguments,
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        if allow_failure:
            return ""
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        fail(f"Git command failed for {root}: {detail}")
    return result.stdout.strip()


def source_identity(source: Path) -> dict[str, str]:
    root = Path(git_output(source, ["rev-parse", "--show-toplevel"])).resolve()
    if root != source.resolve():
        fail(f"source is not the root of its Git worktree: {source}")
    commit = git_output(source, ["rev-parse", "--verify", "HEAD"])
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        fail("source HEAD is not a valid commit identity")
    branch = git_output(source, ["symbolic-ref", "--quiet", "--short", "HEAD"], allow_failure=True)
    return {"source_branch": branch or "DETACHED", "source_commit": commit}


def hash_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
    except OSError as exc:
        fail(f"cannot hash {path}: {exc}")
    return digest.hexdigest(), size


def scan_tree(root: Path) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []

    def visit(path: Path, relative: str) -> None:
        try:
            metadata = os.lstat(path)
        except OSError as exc:
            fail(f"cannot inspect source path {path}: {exc}")
        mode = metadata.st_mode
        if stat.S_ISLNK(mode):
            try:
                target = os.readlink(path)
            except OSError as exc:
                fail(f"cannot read symbolic link {path}: {exc}")
            entries.append({"kind": "symlink", "path": relative, "target": target})
            return
        if stat.S_ISREG(mode):
            digest, size = hash_file(path)
            entries.append(
                {
                    "kind": "file",
                    "mode": stat.S_IMODE(mode),
                    "path": relative,
                    "sha256": digest,
                    "size": size,
                }
            )
            return
        if not stat.S_ISDIR(mode):
            fail(f"special file is not supported in the canonical tree: {relative}")
        entries.append({"kind": "dir", "mode": stat.S_IMODE(mode), "path": relative})
        try:
            with os.scandir(path) as iterator:
                children = sorted(iterator, key=lambda entry: entry.name)
        except OSError as exc:
            fail(f"cannot enumerate source path {path}: {exc}")
        for child in children:
            child_path = Path(child.path)
            child_relative = child.name if relative == "." else f"{relative}/{child.name}"
            visit(child_path, child_relative)

    visit(root, ".")
    return sorted(entries, key=lambda entry: entry["path"])


def identity_payload(source: Path, identity: dict[str, str], entries: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "entries": entries,
        "format": SNAPSHOT_FORMAT,
        "source": str(source),
        **identity,
    }


def snapshot_id(source: Path, identity: dict[str, str], entries: list[dict[str, Any]]) -> str:
    return hashlib.sha256(canonical_json(identity_payload(source, identity, entries))).hexdigest()


def backup_root_marker(source: Path, destination: Path) -> dict[str, str]:
    return {
        "destination": str(destination),
        "format": ROOT_FORMAT,
        "policy": "content-addressed-incremental",
        "source": str(source),
    }


def load_root(source: Path, destination: Path, allow_initialize: bool) -> tuple[bool, Path, Path]:
    if destination.is_symlink():
        fail(f"backup destination must not be a symbolic link: {destination}")
    initialized = False
    if destination.exists():
        if not destination.is_dir():
            fail(f"backup destination is not a directory: {destination}")
        marker = destination / ROOT_MARKER
        if marker.is_symlink():
            fail(f"backup identity marker must not be a symbolic link: {marker}")
        if not marker.exists():
            try:
                nonempty = any(destination.iterdir())
            except OSError as exc:
                fail(f"cannot inspect backup destination: {exc}")
            if nonempty:
                fail("backup destination has no matching replicante identity marker")
            if not allow_initialize:
                fail("backup destination is uninitialized")
            initialized = True
    else:
        if not allow_initialize:
            fail(f"backup destination is unavailable: {destination}")
        try:
            destination.mkdir()
        except OSError as exc:
            fail(f"cannot create backup destination: {exc}")
        initialized = True

    marker_path = destination / ROOT_MARKER
    if initialized:
        atomic_write(marker_path, canonical_json(backup_root_marker(source, destination)) + b"\n")
        ensure_directory(destination / "objects")
        ensure_directory(destination / "snapshots")
    else:
        marker = read_json(marker_path)
        expected = backup_root_marker(source, destination)
        if marker != expected:
            fail("backup destination identity marker does not match the canonical source and destination")
        for child in (destination / "objects", destination / "snapshots"):
            if not child.is_dir() or child.is_symlink():
                fail(f"backup layout is incomplete or unsafe: {child}")
        latest = destination / LATEST_MARKER
        if latest.is_symlink():
            fail("latest snapshot marker must not be a symbolic link")
        if not latest.is_file():
            fail("backup destination has no latest snapshot marker")
    return initialized, destination / "objects", destination / "snapshots"


class BackupLock:
    def __init__(self, destination: Path) -> None:
        self.destination = destination
        self.path = destination.parent / f".{destination.name}.replicante.lock"
        self.held = False

    def __enter__(self) -> "BackupLock":
        try:
            self.path.mkdir()
            self.held = True
            atomic_write(
                self.path / "owner",
                f"pid={os.getpid()}\ndestination={self.destination}\n".encode(),
            )
        except FileExistsError:
            fail(f"another replicante execution holds the lock: {self.path}")
        except OSError as exc:
            if self.held:
                try:
                    self.path.rmdir()
                except OSError:
                    pass
            fail(f"cannot acquire replicante lock {self.path}: {exc}")
        return self

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        if not self.held:
            return
        try:
            owner = self.path / "owner"
            if owner.exists():
                owner.unlink()
            self.path.rmdir()
        except OSError as exc:
            fail(f"cannot release replicante lock {self.path}: {exc}")
        self.held = False


def snapshot_path(snapshots: Path, identifier: str) -> Path:
    if not SNAPSHOT_ID_RE.fullmatch(identifier):
        fail(f"invalid snapshot identifier: {identifier}")
    return snapshots / identifier


def validate_entry(entry: Any, seen: set[str]) -> None:
    if not isinstance(entry, dict):
        fail("snapshot contains a non-object entry")
    kind = entry.get("kind")
    relative = entry.get("path")
    if kind not in {"dir", "file", "symlink"} or not isinstance(relative, str):
        fail("snapshot contains a malformed entry")
    if not relative or relative.startswith("/") or "\\" in relative or "\x00" in relative:
        fail(f"snapshot contains an unsafe path: {relative!r}")
    if relative != PurePosixPath(relative).as_posix():
        fail(f"snapshot contains a non-canonical path: {relative}")
    if relative != "." and ".." in PurePosixPath(relative).parts:
        fail(f"snapshot contains a traversal path: {relative}")
    if relative in seen:
        fail(f"snapshot contains a duplicate path: {relative}")
    seen.add(relative)
    if kind in {"dir", "file"}:
        mode = entry.get("mode")
        if not isinstance(mode, int) or mode < 0 or mode > 0o7777:
            fail(f"snapshot contains an invalid mode: {relative}")
    if kind == "file":
        if not isinstance(entry.get("size"), int) or entry["size"] < 0:
            fail(f"snapshot contains an invalid file size: {relative}")
        if not isinstance(entry.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            fail(f"snapshot contains an invalid file hash: {relative}")
    if kind == "symlink" and not isinstance(entry.get("target"), str):
        fail(f"snapshot contains an invalid symbolic-link target: {relative}")


def validate_entry_tree(entries: list[dict[str, Any]]) -> None:
    kinds = {entry["path"]: entry["kind"] for entry in entries}
    if kinds.get(".") != "dir":
        fail("snapshot has no directory root entry")
    for entry in entries:
        relative = entry["path"]
        if relative == ".":
            continue
        parts = PurePosixPath(relative).parts
        for index in range(1, len(parts)):
            parent = "/".join(parts[:index])
            if kinds.get(parent) != "dir":
                fail(f"snapshot path has a non-directory parent: {relative}")


def read_snapshot_manifest(
    source: Path,
    destination: Path,
    snapshots: Path,
    objects: Path,
    identifier: str,
    verify_objects: bool,
) -> dict[str, Any]:
    snapshot = snapshot_path(snapshots, identifier)
    manifest_path = snapshot / "manifest.json"
    if snapshot.is_symlink() or not snapshot.is_dir() or manifest_path.is_symlink() or not manifest_path.is_file():
        fail(f"snapshot is missing its manifest: {identifier}")
    try:
        extra = [child for child in snapshot.iterdir() if child.name != "manifest.json"]
    except OSError as exc:
        fail(f"cannot inspect snapshot {identifier}: {exc}")
    if extra:
        fail(f"snapshot contains unexpected files: {extra[0]}")
    manifest = read_json(manifest_path)
    if manifest.get("format") != SNAPSHOT_FORMAT:
        fail(f"snapshot has an unsupported format: {identifier}")
    if manifest.get("source") != str(source) or manifest.get("destination") != str(destination):
        fail(f"snapshot identity does not match this backup: {identifier}")
    if manifest.get("snapshot_id") != identifier:
        fail(f"snapshot identifier does not match its manifest: {identifier}")
    if not isinstance(manifest.get("source_branch"), str) or not isinstance(manifest.get("source_commit"), str):
        fail(f"snapshot source identity is malformed: {identifier}")
    if not re.fullmatch(r"[0-9a-f]{40,64}", manifest["source_commit"]):
        fail(f"snapshot source commit is malformed: {identifier}")
    entries = manifest.get("entries")
    if not isinstance(entries, list) or not entries:
        fail(f"snapshot has no entries: {identifier}")
    seen: set[str] = set()
    for entry in entries:
        validate_entry(entry, seen)
    if entries != sorted(entries, key=lambda entry: entry["path"]):
        fail(f"snapshot entries are not canonically ordered: {identifier}")
    validate_entry_tree(entries)
    expected_id = snapshot_id(source, {
        "source_branch": manifest.get("source_branch", ""),
        "source_commit": manifest.get("source_commit", ""),
    }, entries)
    if expected_id != identifier:
        fail(f"snapshot identity hash does not match its manifest: {identifier}")
    manifest_hash = manifest.get("manifest_sha256")
    unsigned = dict(manifest)
    unsigned.pop("manifest_sha256", None)
    if not isinstance(manifest_hash, str) or hashlib.sha256(canonical_json(unsigned)).hexdigest() != manifest_hash:
        fail(f"snapshot manifest hash does not match its contents: {identifier}")
    if verify_objects:
        for entry in entries:
            if entry["kind"] != "file":
                continue
            object_path = objects / entry["sha256"]
            if not object_path.is_file() or object_path.is_symlink():
                fail(f"snapshot object is missing: {entry['sha256']}")
            digest, size = hash_file(object_path)
            if digest != entry["sha256"] or size != entry["size"]:
                fail(f"snapshot object hash or size is corrupt: {entry['path']}")
    return manifest


def latest_id(destination: Path) -> str:
    marker = destination / LATEST_MARKER
    if marker.is_symlink() or not marker.is_file():
        fail("latest snapshot marker is missing or a symbolic link")
    value = read_bytes(marker).decode("ascii").strip()
    if not SNAPSHOT_ID_RE.fullmatch(value):
        fail("latest snapshot marker is malformed")
    return value


def source_path(root: Path, relative: str) -> Path:
    if relative == ".":
        return root
    return root.joinpath(*PurePosixPath(relative).parts)


def copy_file_contents(source: Path, destination: Path) -> None:
    try:
        with source.open("rb") as source_handle, destination.open("wb") as destination_handle:
            while chunk := source_handle.read(1024 * 1024):
                destination_handle.write(chunk)
    except OSError as exc:
        fail(f"cannot copy backup content from {source}: {exc}")


def ensure_object(source: Path, objects: Path, digest: str, size: int) -> bool:
    object_path = objects / digest
    if object_path.exists():
        if object_path.is_symlink() or not object_path.is_file():
            fail(f"backup object path is not a regular file: {digest}")
        actual_digest, actual_size = hash_file(object_path)
        if actual_digest != digest or actual_size != size:
            fail(f"existing backup object is corrupt: {digest}")
        return False
    temporary = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=".object.tmp-", dir=objects)
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as handle:
            with source.open("rb") as source_handle:
                while chunk := source_handle.read(1024 * 1024):
                    handle.write(chunk)
        actual_digest, actual_size = hash_file(temporary)
        if actual_digest != digest or actual_size != size:
            fail(f"source changed while copying backup object: {source}")
        os.replace(temporary, object_path)
        temporary = None
        return True
    except OSError as exc:
        fail(f"cannot create backup object {digest}: {exc}")
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
    return False


def write_snapshot(
    source: Path,
    destination: Path,
    snapshots: Path,
    identifier: str,
    identity: dict[str, str],
    entries: list[dict[str, Any]],
) -> None:
    final_path = snapshot_path(snapshots, identifier)
    if final_path.exists():
        fail(f"snapshot path already exists but was not accepted: {identifier}")
    temporary = snapshots / f".{identifier}.tmp-{os.getpid()}"
    if temporary.exists():
        fail(f"stale snapshot staging path exists: {temporary}")
    try:
        temporary.mkdir()
        body: dict[str, Any] = {
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "destination": str(destination),
            "entries": entries,
            "format": SNAPSHOT_FORMAT,
            "snapshot_id": identifier,
            "source": str(source),
            **identity,
        }
        manifest = dict(body)
        manifest["manifest_sha256"] = hashlib.sha256(canonical_json(body)).hexdigest()
        atomic_write(temporary / "manifest.json", canonical_json(manifest) + b"\n")
        os.replace(temporary, final_path)
    except OSError as exc:
        fail(f"cannot install snapshot {identifier}: {exc}")
    finally:
        if temporary.exists():
            shutil.rmtree(temporary, ignore_errors=True)


def source_state(source: Path) -> tuple[dict[str, str], list[dict[str, Any]]]:
    identity = source_identity(source)
    entries = scan_tree(source)
    return identity, entries


def assert_source_stable(
    source: Path,
    identity: dict[str, str],
    entries: list[dict[str, Any]],
) -> None:
    current_identity, current_entries = source_state(source)
    if current_identity != identity or current_entries != entries:
        fail("canonical source changed while the backup was being built")


def snapshot_ids(snapshots: Path) -> list[str]:
    try:
        values = [child.name for child in snapshots.iterdir() if child.is_dir() and SNAPSHOT_ID_RE.fullmatch(child.name)]
    except OSError as exc:
        fail(f"cannot enumerate snapshots: {exc}")
    return sorted(values)


def prune_snapshots(
    source: Path,
    destination: Path,
    objects: Path,
    snapshots: Path,
    retain: int,
) -> None:
    if retain < 1:
        fail("snapshot retention must be at least 1")
    verified: list[tuple[str, str]] = []
    for identifier in snapshot_ids(snapshots):
        manifest = read_snapshot_manifest(source, destination, snapshots, objects, identifier, True)
        created = manifest.get("created_at")
        if not isinstance(created, str):
            fail(f"snapshot has no creation time: {identifier}")
        verified.append((created, identifier))
    if len(verified) <= retain:
        return
    current = latest_id(destination)
    ordered = sorted(verified)
    retained = {current}
    for _, identifier in reversed(ordered):
        if len(retained) >= retain:
            break
        retained.add(identifier)
    for _, identifier in ordered:
        if identifier in retained:
            continue
        target = snapshot_path(snapshots, identifier)
        try:
            shutil.rmtree(target)
        except OSError as exc:
            fail(f"cannot prune snapshot {identifier}: {exc}")


def destination_needs_initialization(destination: Path) -> bool:
    if not destination.exists():
        return True
    if destination.is_symlink() or not destination.is_dir():
        return False
    try:
        return not any(destination.iterdir())
    except OSError as exc:
        fail(f"cannot inspect backup destination: {exc}")


def run_backup(source: Path, destination: Path, retain: int) -> None:
    if retain < 1:
        fail("snapshot retention must be at least 1")
    with BackupLock(destination):
        initial_backup = destination_needs_initialization(destination)
        if initial_backup:
            identity, entries = source_state(source)
            assert_source_stable(source, identity, entries)
            _, objects, snapshots = load_root(source, destination, allow_initialize=True)
            previous = None
        else:
            _, objects, snapshots = load_root(source, destination, allow_initialize=False)
            previous = latest_id(destination)
            read_snapshot_manifest(source, destination, snapshots, objects, previous, True)
            identity, entries = source_state(source)
        identifier = snapshot_id(source, identity, entries)
        if identifier == previous:
            assert_source_stable(source, identity, entries)
            prune_snapshots(source, destination, objects, snapshots, retain)
            print(f"already current: snapshot={identifier} destination={destination}")
            return
        for entry in entries:
            if entry["kind"] == "file":
                ensure_object(
                    source_path(source, entry["path"]),
                    objects,
                    entry["sha256"],
                    entry["size"],
                )
        assert_source_stable(source, identity, entries)
        if snapshot_path(snapshots, identifier).exists():
            read_snapshot_manifest(source, destination, snapshots, objects, identifier, True)
        else:
            write_snapshot(source, destination, snapshots, identifier, identity, entries)
            read_snapshot_manifest(source, destination, snapshots, objects, identifier, True)
        atomic_write(destination / LATEST_MARKER, f"{identifier}\n".encode("ascii"))
        prune_snapshots(source, destination, objects, snapshots, retain)
        print(f"replicated: snapshot={identifier} destination={destination}")


def restore_tree(
    manifest: dict[str, Any],
    objects: Path,
    output: Path,
    apply_modes: bool,
) -> None:
    entries = manifest["entries"]
    try:
        output.mkdir()
        for entry in entries:
            target = source_path(output, entry["path"])
            if entry["path"] == ".":
                continue
            if entry["kind"] == "dir":
                target.mkdir()
            elif entry["kind"] == "symlink":
                os.symlink(entry["target"], target)
            else:
                copy_file_contents(objects / entry["sha256"], target)
        if apply_modes:
            for entry in sorted(entries, key=lambda value: value["path"].count("/"), reverse=True):
                if entry["kind"] in {"dir", "file"}:
                    os.chmod(source_path(output, entry["path"]), entry["mode"])
    except OSError as exc:
        fail(f"cannot restore snapshot to {output}: {exc}")


def projected_entries(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            key: value
            for key, value in entry.items()
            if key in {"kind", "path", "sha256", "size", "target"}
        }
        for entry in entries
    ]


def verify_restore_test(manifest: dict[str, Any], objects: Path) -> None:
    temporary = Path(tempfile.mkdtemp(prefix="replicante-verify-"))
    temporary.rmdir()
    try:
        restore_tree(manifest, objects, temporary, apply_modes=False)
        restored = scan_tree(temporary)
        if projected_entries(restored) != projected_entries(manifest["entries"]):
            fail("restore verification produced a tree different from the snapshot")
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def verify_backup(
    source: Path,
    destination: Path,
    identifier: str | None,
    verify_all: bool,
    restore_test: bool,
) -> None:
    with BackupLock(destination):
        initialized, objects, snapshots = load_root(source, destination, allow_initialize=False)
        if initialized:
            fail("backup destination is initialized but has no snapshot to verify")
        selected = snapshot_ids(snapshots) if verify_all else [identifier or latest_id(destination)]
        if not selected:
            fail("backup destination contains no snapshots")
        for value in selected:
            manifest = read_snapshot_manifest(source, destination, snapshots, objects, value, True)
            if restore_test:
                if verify_all or len(selected) != 1:
                    fail("restore test requires one selected snapshot")
                verify_restore_test(manifest, objects)
        suffix = " with restore test" if restore_test else ""
        print(f"verified: snapshots={len(selected)} destination={destination}{suffix}")


def restore_backup(
    source: Path,
    destination: Path,
    identifier: str,
    output: Path,
    test_mode: bool,
    apply_modes: bool,
) -> None:
    if output.exists() or output.is_symlink():
        fail(f"restore output already exists: {output}")
    output_parent = output.parent.resolve()
    output_absolute = Path(os.path.realpath(output))
    if not output_parent.is_dir():
        fail(f"restore output parent is unavailable: {output_parent}")
    if not test_mode:
        if is_under(output_absolute, Path("/mnt/d")) or is_under(output_absolute, source):
            fail("restore output must not touch the source or D: trees")
        if is_under(output_absolute, destination):
            fail("restore output must not be inside the backup store")
        if not is_under(output_absolute, Path("/mnt/h")):
            fail("restore output must be on H: or use fixture mode")
    with BackupLock(destination):
        initialized, objects, snapshots = load_root(source, destination, allow_initialize=False)
        if initialized:
            fail("backup destination is initialized but has no snapshot to restore")
        manifest = read_snapshot_manifest(source, destination, snapshots, objects, identifier, True)
        temporary = output_parent / f".{output.name}.replicante-restore-{os.getpid()}"
        if temporary.exists():
            fail(f"stale restore staging path exists: {temporary}")
        try:
            restore_tree(manifest, objects, temporary, apply_modes)
            os.replace(temporary, output)
        except OSError as exc:
            fail(f"cannot install restored snapshot: {exc}")
        finally:
            if temporary.exists():
                shutil.rmtree(temporary, ignore_errors=True)
        print(f"restored: snapshot={identifier} output={output}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Incremental content-addressed backup to /mnt/h/Firstmate-Backup."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    run_parser = subparsers.add_parser("run", help="create or advance the incremental backup")
    retention_default = os.environ.get("REPLICANTE_RETENTION", "30")
    try:
        retention_default_value = int(retention_default)
    except ValueError:
        parser.error("REPLICANTE_RETENTION must be an integer")
    run_parser.add_argument(
        "--retain",
        type=int,
        default=retention_default_value,
        help="number of historical snapshots to retain (default: 30)",
    )
    verify_parser = subparsers.add_parser("verify", help="verify one or all snapshots")
    verify_parser.add_argument("--snapshot", help="snapshot identifier; defaults to latest")
    verify_parser.add_argument("--all", action="store_true", help="verify every retained snapshot")
    verify_parser.add_argument(
        "--restore-test",
        action="store_true",
        help="restore the selected snapshot to a temporary directory and compare its tree",
    )
    restore_parser = subparsers.add_parser("restore", help="restore one snapshot to a new output directory")
    restore_parser.add_argument("--snapshot", required=True, help="snapshot identifier")
    restore_parser.add_argument("--output", required=True, help="new recovery output directory")
    restore_parser.add_argument(
        "--apply-modes",
        action="store_true",
        help="apply recorded source modes where the recovery filesystem permits it",
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    source, destination, test_mode = resolve_paths(arguments.command)
    if arguments.command == "run":
        run_backup(source, destination, arguments.retain)
    elif arguments.command == "verify":
        if arguments.snapshot and arguments.all:
            fail("--snapshot and --all cannot be combined")
        if arguments.restore_test and arguments.all:
            fail("--restore-test requires one selected snapshot")
        verify_backup(source, destination, arguments.snapshot, arguments.all, arguments.restore_test)
    else:
        restore_backup(
            source,
            destination,
            arguments.snapshot,
            Path(arguments.output).absolute(),
            test_mode,
            arguments.apply_modes,
        )


if __name__ == "__main__":
    main()
