#!/usr/bin/env python3
"""Build and verify the sealed Pi runtime for Azure no-mistakes workers."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile
import tempfile


SCHEMA = "fm.azure-validation-runtime/v1"
PROVIDER = "pi"
NM_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
PACKAGE_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$")
MAX_FILES = 20000
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MANIFEST_FIELDS = {
    "schema", "provider", "no_mistakes_version", "no_mistakes_source_commit",
    "owner_decision_protocol", "no_mistakes_path", "provider_path", "gh_path",
    "node_path", "gh_axi_path", "gh_axi_entrypoint", "gh_axi_closure", "files",
}
DENIED_BASENAMES = {
    ".env", ".netrc", ".npmrc", "auth.json", "credentials.json",
    "credentials", "id_rsa", "id_ed25519",
}

PI_WRAPPER = b'''#!/bin/sh
set -eu
runtime_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
agent_dir=${PI_CODING_AGENT_DIR:-"$HOME/pi-agent"}
export PI_CODING_AGENT_DIR=$agent_dir
config_dir=$agent_dir/extensions/pi-openai-fast-mode
mkdir -p "$config_dir"
cp "$runtime_root/config/pi-openai-fast-mode.json" "$config_dir/config.json"
exec "$runtime_root/bin/node" "$runtime_root/lib/pi/dist/cli.js" \
  --no-extensions \
  --extension "$runtime_root/extensions/pi-openai-fast-mode/src/index.ts" \
  --extension "$runtime_root/extensions/fast-mode-all-codex-accounts.ts" \
  --extension "$runtime_root/extensions/pi-ketch/src/index.ts" "$@"
'''

FAST_CONFIG = b'''{
 "enabled": true,
 "targets": [
  {"provider":"openai-codex","model":"gpt-5.4","serviceTier":"priority"},
  {"provider":"openai-codex","model":"gpt-5.5","serviceTier":"priority"},
  {"provider":"openai-codex","model":"gpt-5.6","serviceTier":"priority"},
  {"provider":"openai-codex","model":"gpt-5.6-sol","serviceTier":"priority"},
  {"provider":"openai-codex","model":"gpt-5.6-terra","serviceTier":"priority"},
  {"provider":"openai-codex","model":"gpt-5.6-luna","serviceTier":"priority"}
 ]
}
'''


class RuntimeError(ValueError):
    pass


def digest(body):
    return "sha256:" + hashlib.sha256(body).hexdigest()


def linux_amd64_elf(body):
    return (
        len(body) >= 20 and body[:4] == b"\x7fELF" and body[4] == 2
        and body[5] == 1 and int.from_bytes(body[18:20], "little") == 62
    )


def safe_relative(value):
    parts = Path(value).parts
    return bool(parts) and not value.startswith("/") and all(
        part not in ("", ".", "..") for part in parts
    )


def read_regular(path, label, executable=False, linux=False, enforce_linux=True):
    path = Path(path).expanduser()
    try:
        observed = os.lstat(path)
    except OSError as exc:
        raise RuntimeError("{} is unreadable: {}".format(label, exc))
    if not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1:
        raise RuntimeError("{} must be one regular, unlinked file".format(label))
    if executable and observed.st_mode & 0o111 == 0:
        raise RuntimeError("{} must be executable".format(label))
    if observed.st_size > MAX_FILE_BYTES:
        raise RuntimeError("{} exceeds 512 MiB".format(label))
    body = path.read_bytes()
    if len(body) != observed.st_size or os.lstat(path)[:4] != observed[:4]:
        raise RuntimeError("{} changed while it was read".format(label))
    if linux and enforce_linux and not linux_amd64_elf(body[:20]):
        raise RuntimeError("{} must be a Linux amd64 ELF artifact".format(label))
    return body


def record(name, body, mode):
    if not safe_relative(name):
        raise RuntimeError("runtime member path is unsafe: {}".format(name))
    if Path(name).name.lower() in DENIED_BASENAMES:
        raise RuntimeError("runtime member path is credential-like: {}".format(name))
    return {"name": name, "body": body, "mode": mode, "digest": digest(body)}


def package_records(root, expected_name, destination, label, enforce_linux=True):
    root = Path(root).expanduser()
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError("{} must be one package directory".format(label))
    package_body = read_regular(root / "package.json", label + " package.json")
    try:
        metadata = json.loads(package_body)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("{} package.json is malformed: {}".format(label, exc))
    if (
        not isinstance(metadata, dict) or metadata.get("name") != expected_name
        or not PACKAGE_VERSION.fullmatch(str(metadata.get("version", "")))
    ):
        raise RuntimeError("{} package identity/version is not exact".format(label))
    output = []
    for directory, directories, files in os.walk(root, followlinks=False):
        directories.sort()
        files.sort()
        base = Path(directory)
        for name in list(directories):
            child = base / name
            if child.is_symlink():
                if name == ".bin":
                    directories.remove(name)
                    continue
                raise RuntimeError("{} contains a redirected directory".format(label))
        for name in files:
            source = base / name
            relative = source.relative_to(root).as_posix()
            if source.is_symlink():
                if "/.bin/" in "/{}/".format(relative):
                    continue
                raise RuntimeError("{} contains a redirected file".format(label))
            body = read_regular(source, "{} {}".format(label, relative))
            if enforce_linux and source.suffix == ".node" and not linux_amd64_elf(body[:20]):
                raise RuntimeError("{} native module is not Linux amd64: {}".format(label, relative))
            output.append(record(destination + "/" + relative, body, 0o644))
    return output, metadata["version"]


def build(args, enforce_linux=True):
    if not NM_VERSION.fullmatch(args.no_mistakes_version):
        raise RuntimeError("--no-mistakes-version is malformed")
    if not HEX40.fullmatch(args.no_mistakes_source_commit):
        raise RuntimeError("--no-mistakes-source-commit must be exact 40-hex")
    output = Path(args.output).expanduser().absolute()
    if not output.parent.is_dir() or output.exists() or output.is_symlink():
        raise RuntimeError("output parent must exist and output must be absent")
    records = [
        record("bin/no-mistakes", read_regular(
            args.no_mistakes, "no-mistakes", True, True, enforce_linux), 0o755),
        record("bin/node", read_regular(
            args.node, "Node", True, True, enforce_linux), 0o755),
        record("bin/pi", PI_WRAPPER, 0o755),
        record("config/pi-openai-fast-mode.json", FAST_CONFIG, 0o644),
        record("extensions/fast-mode-all-codex-accounts.ts", read_regular(
            args.fast_mode_fleet_extension, "fleet fast-mode extension"), 0o644),
    ]
    pi_records, pi_version = package_records(
        args.pi_package, "@earendil-works/pi-coding-agent", "lib/pi", "Pi", enforce_linux)
    fast_records, fast_version = package_records(
        args.fast_mode_package, "pi-openai-fast-mode",
        "extensions/pi-openai-fast-mode", "Pi fast mode", enforce_linux)
    ketch_records, ketch_version = package_records(
        args.ketch_package, "pi-ketch", "extensions/pi-ketch", "Pi Ketch", enforce_linux)
    records.extend(pi_records + fast_records + ketch_records)
    names = [item["name"] for item in records]
    if len(names) > MAX_FILES or len(names) != len(set(names)):
        raise RuntimeError("runtime file inventory is duplicated or unbounded")
    if "lib/pi/dist/cli.js" not in names:
        raise RuntimeError("Pi package lacks dist/cli.js")
    for required in (
        "extensions/pi-openai-fast-mode/src/index.ts",
        "extensions/pi-ketch/src/index.ts",
    ):
        if required not in names:
            raise RuntimeError("extension package lacks {}".format(required))
    records.sort(key=lambda item: item["name"])
    manifest = {
        "schema": SCHEMA,
        "provider": PROVIDER,
        "no_mistakes_version": args.no_mistakes_version,
        "no_mistakes_source_commit": args.no_mistakes_source_commit,
        "owner_decision_protocol": "fm.azure-validation-owner-decision/v1",
        "no_mistakes_path": "bin/no-mistakes",
        "provider_path": "bin/pi",
        "gh_path": "",
        "node_path": "bin/node",
        "gh_axi_path": "",
        "gh_axi_entrypoint": "",
        "gh_axi_closure": [],
        "files": [{"path": item["name"], "digest": item["digest"]} for item in records],
    }
    manifest_body = json.dumps(manifest, sort_keys=True, indent=1).encode() + b"\n"
    if len(records) + 1 > MAX_FILES or sum(len(item["body"]) for item in records) > MAX_TOTAL_BYTES:
        raise RuntimeError("runtime exceeds its bounded inventory")
    fd, temporary_name = tempfile.mkstemp(prefix="." + output.name + ".", dir=output.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as zipped:
                with tarfile.open(fileobj=zipped, mode="w:", format=tarfile.PAX_FORMAT) as archive:
                    for name, body, mode in [("runtime.json", manifest_body, 0o644)] + [
                        (item["name"], item["body"], item["mode"]) for item in records
                    ]:
                        info = tarfile.TarInfo(name)
                        info.size = len(body)
                        info.mode = mode
                        info.uid = info.gid = 0
                        info.uname = info.gname = "root"
                        info.mtime = 0
                        archive.addfile(info, io.BytesIO(body))
            raw.flush()
            os.fsync(raw.fileno())
        verify(temporary, enforce_linux)
        smoke_pi_runtime(temporary)
        os.link(temporary, output, follow_symlinks=False)
    finally:
        temporary.unlink(missing_ok=True)
    bundle_digest = hashlib.sha256(output.read_bytes()).hexdigest()
    print("NO-MISTAKES PI RUNTIME BUILT output={} sha256={} pi={} fast={} ketch={}".format(
        output, bundle_digest, pi_version, fast_version, ketch_version))
    return manifest


def verify(path, enforce_linux=True):
    source = Path(path)
    if source.is_symlink() or not source.is_file() or source.stat().st_size > 1024**3:
        raise RuntimeError("runtime archive is absent, redirected, or oversized")
    try:
        with tarfile.open(source, "r:gz") as archive:
            members = archive.getmembers()
            if not members or len(members) > MAX_FILES:
                raise RuntimeError("runtime member inventory is empty or unbounded")
            bodies = {}
            modes = {}
            for member in members:
                if not member.isreg() or not safe_relative(member.name) or member.name in bodies:
                    raise RuntimeError("runtime contains unsafe or duplicate members")
                handle = archive.extractfile(member)
                body = handle.read() if handle else b""
                bodies[member.name] = body
                modes[member.name] = member.mode
    except (OSError, tarfile.TarError) as exc:
        raise RuntimeError("runtime archive is unreadable: {}".format(exc))
    try:
        manifest = json.loads(bodies.pop("runtime.json"))
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("runtime manifest is unreadable: {}".format(exc))
    if (
        not isinstance(manifest, dict) or set(manifest) != MANIFEST_FIELDS
        or manifest.get("schema") != SCHEMA or manifest.get("provider") != PROVIDER
        or not NM_VERSION.fullmatch(str(manifest.get("no_mistakes_version", "")))
        or not HEX40.fullmatch(str(manifest.get("no_mistakes_source_commit", "")))
        or manifest.get("owner_decision_protocol") != "fm.azure-validation-owner-decision/v1"
        or manifest.get("provider_path") != "bin/pi"
        or manifest.get("node_path") != "bin/node"
        or manifest.get("no_mistakes_path") != "bin/no-mistakes"
        or manifest.get("gh_path") != "" or manifest.get("gh_axi_path") != ""
        or manifest.get("gh_axi_entrypoint") != "" or manifest.get("gh_axi_closure") != []
    ):
        raise RuntimeError("runtime manifest identity is not the exact Pi worker schema")
    declared = manifest.get("files")
    if not isinstance(declared, list) or any(
        not isinstance(item, dict) or set(item) != {"path", "digest"}
        or not isinstance(item.get("path"), str) or not safe_relative(item["path"])
        or not isinstance(item.get("digest"), str)
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", item["digest"])
        for item in declared
    ):
        raise RuntimeError("runtime file inventory is malformed")
    expected = {item["path"]: item["digest"] for item in declared}
    if len(expected) != len(declared) or set(expected) != set(bodies):
        raise RuntimeError("runtime manifest does not inventory every byte")
    if any(expected[name] != digest(body) for name, body in bodies.items()):
        raise RuntimeError("runtime member digest differs")
    if any(Path(name).name.lower() in DENIED_BASENAMES for name in bodies):
        raise RuntimeError("runtime contains a credential-like path")
    if any(modes.get(name, 0) & 0o111 == 0 for name in ("bin/no-mistakes", "bin/node", "bin/pi")):
        raise RuntimeError("runtime executable is not executable")
    if enforce_linux and any(not linux_amd64_elf(bodies[name][:20]) for name in ("bin/no-mistakes", "bin/node")):
        raise RuntimeError("runtime executable is not Linux amd64")
    return manifest


def smoke_pi_runtime(path):
    """Start the staged Pi CLI under the staged Node without account material."""
    with tempfile.TemporaryDirectory(prefix="fm-pi-runtime-smoke.") as directory:
        root = Path(directory) / "runtime"
        home = Path(directory) / "home"
        root.mkdir(mode=0o700)
        home.mkdir(mode=0o700)
        with tarfile.open(path, "r:gz") as archive:
            for member in archive.getmembers():
                if member.name == "runtime.json":
                    continue
                handle = archive.extractfile(member)
                body = handle.read() if handle else b""
                target = root.joinpath(*Path(member.name).parts)
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                target.write_bytes(body)
                target.chmod(member.mode)
        environment = {
            "HOME": str(home),
            "PI_CODING_AGENT_DIR": str(home / "pi-agent"),
            "PATH": str(root / "bin") + ":/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        }
        try:
            completed = subprocess.run(
                [str(root / "bin/pi"), "--version"], env=environment,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=30, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError("staged Pi CLI did not start under bundled Node: {}".format(exc))
        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", errors="replace")[-500:].strip()
            raise RuntimeError(
                "staged Pi CLI did not start under bundled Node: exit={} {}".format(
                    completed.returncode, detail))


def parser():
    item = argparse.ArgumentParser(prog="fm-no-mistakes-runtime")
    item.add_argument("--no-mistakes", required=True)
    item.add_argument("--node", required=True)
    item.add_argument("--pi-package", required=True)
    item.add_argument("--fast-mode-package", required=True)
    item.add_argument("--fast-mode-fleet-extension", required=True)
    item.add_argument("--ketch-package", required=True)
    item.add_argument("--no-mistakes-version", required=True)
    item.add_argument("--no-mistakes-source-commit", required=True)
    item.add_argument("--output", required=True)
    return item


def main():
    try:
        build(parser().parse_args())
    except RuntimeError as exc:
        raise SystemExit("NO-MISTAKES PI RUNTIME FAILED: {}".format(exc))


if __name__ == "__main__":
    main()
