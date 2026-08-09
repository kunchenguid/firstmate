#!/usr/bin/env python3
"""Private implementation helpers for bin/fm-shadow.sh."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"fm-shadow: {message}", file=sys.stderr)
    raise SystemExit(1)


def hash_file(path: Path) -> tuple[str, str]:
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
    except OSError as exc:
        fail(f"cannot hash {path}: {exc}")
    return digest.hexdigest(), str(size)


def link_target(path: Path, rel: str) -> str:
    target = os.readlink(path)
    if any(char in target for char in "\x00\r\n\t"):
        fail(f"symbolic-link target contains a control character: {rel}")
    return target


def copy_file_contents(source: Path, destination: Path) -> None:
    with source.open("rb") as source_handle, destination.open("wb") as destination_handle:
        while chunk := source_handle.read(1024 * 1024):
            destination_handle.write(chunk)


def copy_entry(source: Path, destination: Path, relative: str) -> None:
    mode = os.lstat(source).st_mode
    if stat.S_ISLNK(mode):
        os.symlink(os.readlink(source), destination)
        return
    if stat.S_ISDIR(mode):
        os.mkdir(destination)
        with os.scandir(source) as iterator:
            children = sorted(iterator, key=lambda entry: entry.name)
        for child in children:
            child_relative = f"{relative}/{child.name}" if relative else child.name
            copy_entry(Path(child.path), destination / child.name, child_relative)
        return
    if stat.S_ISREG(mode):
        copy_file_contents(source, destination)
        return
    fail(f"special file is not allowed in source tree: {relative}")


def copy_tree(source: Path, destination: Path) -> None:
    if not stat.S_ISDIR(os.lstat(source).st_mode) or source.is_symlink():
        fail(f"source tree is not a directory: {source}")
    try:
        copy_entry(source, destination, "")
    except OSError as exc:
        fail(f"cannot mirror source tree: {exc}")


def copy_command(args: argparse.Namespace) -> None:
    copy_tree(Path(args.source), Path(args.stage))


def staged_entries(root: Path) -> list[tuple[str, str, str, str]]:
    entries: list[tuple[str, str, str, str]] = []
    for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        kept_dirs = []
        for name in sorted(dirnames):
            path = current_path / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                entries.append(("symlink", link_target(path, rel), "-", rel))
            else:
                entries.append(("dir", "-", "-", rel))
                kept_dirs.append(name)
        dirnames[:] = kept_dirs
        for name in sorted(filenames):
            path = current_path / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                entries.append(("symlink", link_target(path, rel), "-", rel))
                continue
            if not path.is_file():
                fail(f"special file is not allowed in staged output: {rel}")
            digest, size = hash_file(path)
            entries.append(("file", digest, size, rel))
    return sorted(entries, key=lambda entry: entry[3])


def manifest_command(args: argparse.Namespace) -> None:
    values = (args.source, args.branch, args.commit)
    if any(any(char in value for char in "\x00\r\n\t") for value in values):
        fail("manifest metadata contains a control character")
    entries = staged_entries(Path(args.root))
    if not entries:
        fail("staged output is empty")
    lines = [
        "shadow-manifest-v1",
        f"source={args.source}",
        f"source_branch={args.branch}",
        f"source_commit={args.commit}",
        f"policy_sha256={hash_file(Path(args.policy))[0]}",
    ]
    lines.extend("entry\t%s\t%s\t%s\t%s" % entry for entry in entries)
    body = ("\n".join(lines) + "\n").encode("utf-8")
    output = body + f"manifest_sha256={hashlib.sha256(body).hexdigest()}\n".encode("ascii")
    try:
        Path(args.output).write_bytes(output)
    except OSError as exc:
        fail(f"cannot write manifest: {exc}")


def read_manifest(
    root: Path,
    manifest_path: Path,
    policy_path: Path,
    expected_branch: str,
    expected_commit: str,
) -> dict[str, tuple[str, str, str]]:
    if manifest_path.is_symlink() or policy_path.is_symlink():
        fail("destination manifest and policy must not be symbolic links")
    if not manifest_path.is_file() or not policy_path.is_file():
        fail("destination requires its manifest and policy sidecars")
    try:
        raw = manifest_path.read_bytes()
        lines = raw.decode("utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read manifest: {exc}")
    if len(lines) < 5 or lines[0] != "shadow-manifest-v1":
        fail("unsupported manifest format")
    if not raw.endswith(b"\n") or not lines[-1].startswith("manifest_sha256="):
        fail("manifest hash footer is missing")
    body = ("\n".join(lines[:-1]) + "\n").encode("utf-8")
    if hashlib.sha256(body).hexdigest() != lines[-1].split("=", 1)[1]:
        fail("manifest hash does not match its contents")
    fields: dict[str, str] = {}
    entries: dict[str, tuple[str, str, str]] = {}
    for line in lines[1:-1]:
        if line.startswith("entry\t"):
            parts = line.split("\t")
            if len(parts) != 5:
                fail("malformed manifest entry")
            _, kind, digest, size, rel = parts
            if not rel or rel.startswith("/") or "\\" in rel or "\x00" in rel:
                fail(f"unsafe manifest path: {rel!r}")
            if rel in entries:
                fail(f"duplicate manifest path: {rel}")
            if ".." in Path(rel).parts:
                fail(f"relative traversal in manifest path: {rel}")
            entries[rel] = kind, digest, size
        elif "=" in line:
            key, value = line.split("=", 1)
            if key in fields:
                fail(f"duplicate manifest field: {key}")
            fields[key] = value
        else:
            fail("malformed manifest line")
    if fields.get("source_branch") != expected_branch:
        fail("manifest source branch is not the configured default branch")
    if fields.get("source_commit") != expected_commit:
        fail("manifest source commit is not the current source commit")
    if fields.get("policy_sha256") != hash_file(policy_path)[0]:
        fail("policy hash does not match the generated policy")
    if not entries:
        fail("manifest contains no output entries")
    return entries


def actual_entries(root: Path) -> dict[str, tuple[str, str, str]]:
    result: dict[str, tuple[str, str, str]] = {}
    for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        kept_dirs = []
        for name in sorted(dirnames):
            path = current_path / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                result[rel] = "symlink", os.readlink(path), "-"
            else:
                result[rel] = "dir", "-", "-"
                kept_dirs.append(name)
        dirnames[:] = kept_dirs
        for name in sorted(filenames):
            path = current_path / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                result[rel] = "symlink", os.readlink(path), "-"
            elif path.is_file():
                digest, size = hash_file(path)
                result[rel] = "file", digest, size
            else:
                fail(f"special file is present in destination: {rel}")
    return result


def validate_command(args: argparse.Namespace) -> None:
    root = Path(args.root)
    entries = read_manifest(
        root,
        Path(args.manifest),
        Path(args.policy),
        args.branch,
        args.commit,
    )
    actual = actual_entries(root)
    if set(entries) != set(actual):
        missing = sorted(set(entries) - set(actual))
        extra = sorted(set(actual) - set(entries))
        if missing:
            fail(f"manifest file is missing from destination: {missing[0]}")
        fail(f"destination contains an unmanifested path: {extra[0]}")
    for rel, expected in entries.items():
        path = root / rel
        if actual[rel] != expected:
            fail(f"destination content differs from manifest: {rel}")
    try:
        branch = subprocess.check_output(
            [
                "git",
                "-c",
                f"safe.directory={root}",
                "-C",
                str(root),
                "symbolic-ref",
                "--quiet",
                "--short",
                "HEAD",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        fail("destination is detached")
    if branch != args.branch:
        fail(f"destination branch is {branch!r}, expected {args.branch!r}")


def compare_command(args: argparse.Namespace) -> None:
    source_entries = staged_entries(Path(args.source))
    replica_entries = staged_entries(Path(args.replica))
    if source_entries != replica_entries:
        fail("source tree changed while the replica was being built")


parser = argparse.ArgumentParser()
subparsers = parser.add_subparsers(dest="command", required=True)
copy_parser = subparsers.add_parser("copy")
copy_parser.add_argument("--source", required=True)
copy_parser.add_argument("--stage", required=True)
manifest_parser = subparsers.add_parser("manifest")
manifest_parser.add_argument("--root", required=True)
manifest_parser.add_argument("--source", required=True)
manifest_parser.add_argument("--branch", required=True)
manifest_parser.add_argument("--commit", required=True)
manifest_parser.add_argument("--policy", required=True)
manifest_parser.add_argument("--output", required=True)
validate_parser = subparsers.add_parser("validate")
validate_parser.add_argument("--root", required=True)
validate_parser.add_argument("--branch", required=True)
validate_parser.add_argument("--commit", required=True)
validate_parser.add_argument("--manifest", required=True)
validate_parser.add_argument("--policy", required=True)
compare_parser = subparsers.add_parser("compare")
compare_parser.add_argument("--source", required=True)
compare_parser.add_argument("--replica", required=True)
args = parser.parse_args()
if args.command == "copy":
    copy_command(args)
elif args.command == "manifest":
    manifest_command(args)
elif args.command == "compare":
    compare_command(args)
else:
    validate_command(args)
