#!/usr/bin/env python3
"""Load the private Firstmate-home Azure controller environment and exec a command.

The configuration contract is owned by docs/configuration.md.
This helper owns only bounded parsing, allowlist enforcement, precedence, and
in-memory command handoff; it never prints a configured value.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
CONTRACT_TOOL = ROOT / "bin" / "fm-cloud-env-contract.py"
LOADED_MARKER = "FM_CONTROLLER_AZURE_ENV_LOADED_FROM"
MAX_CONFIG_BYTES = 64 * 1024
MAX_VALUE_BYTES = 8 * 1024
ASSIGNMENT = re.compile(r"^(FM_AZURE_[A-Z0-9_]+)=(.*)$")


class ControllerEnvironmentError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ControllerEnvironmentError(message)


def contract_module():
    spec = importlib.util.spec_from_file_location("fm_cloud_env_contract", CONTRACT_TOOL)
    if spec is None or spec.loader is None:
        fail("the cloud environment allowlist owner is unavailable")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        fail("the cloud environment allowlist owner could not be loaded: {}".format(exc))
    return module


def allowed_and_required_names() -> tuple[set[str], set[str]]:
    module = contract_module()
    try:
        allowed = set(module.required())
        required = set(module.pilot_required())
    except Exception as exc:
        fail("the cloud environment contract could not be derived: {}".format(exc))
    missing = sorted(required - allowed)
    if missing:
        fail("required controller values are outside the existing allowlist: " + ", ".join(missing))
    return allowed, required


def read_private_config(path: Path) -> str:
    try:
        directory_metadata = path.parent.lstat()
    except OSError as exc:
        fail("private config directory is unavailable at {}: {}".format(path.parent, exc))
    if not stat.S_ISDIR(directory_metadata.st_mode) or stat.S_ISLNK(directory_metadata.st_mode):
        fail("private config directory must be a real non-symlink directory: {}".format(path.parent))
    if directory_metadata.st_uid != os.getuid():
        fail("private config directory must be owned by the current operator: {}".format(path.parent))
    if stat.S_IMODE(directory_metadata.st_mode) & 0o022:
        fail("private config directory must not be group/world writable: {}".format(path.parent))
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(str(path), flags)
    except FileNotFoundError:
        fail("private config is missing: {}".format(path))
    except OSError as exc:
        fail("private config cannot be opened safely at {}: {}".format(path, exc))
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail("private config must be a regular non-symlink file: {}".format(path))
        if metadata.st_uid != os.getuid():
            fail("private config must be owned by the current operator: {}".format(path))
        if metadata.st_nlink != 1:
            fail("private config must have exactly one filesystem link: {}".format(path))
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            fail("private config must have no group/world permissions (use chmod 600): {}".format(path))
        if metadata.st_size > MAX_CONFIG_BYTES:
            fail("private config exceeds its {}-byte bound: {}".format(MAX_CONFIG_BYTES, path))
        chunks = []
        remaining = MAX_CONFIG_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
    except OSError as exc:
        fail("private config could not be read at {}: {}".format(path, exc))
    finally:
        os.close(descriptor)
    if len(raw) > MAX_CONFIG_BYTES:
        fail("private config exceeds its {}-byte bound: {}".format(MAX_CONFIG_BYTES, path))
    if b"\0" in raw:
        fail("private config contains a NUL byte: {}".format(path))
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        fail("private config must be UTF-8: {}".format(path))


def parse_config(path: Path, allowed: set[str]) -> dict[str, str]:
    text = read_private_config(path)
    if any(ord(character) < 32 and character != "\n" for character in text):
        fail("private config contains a control character: {}".format(path))
    values: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = ASSIGNMENT.fullmatch(line)
        if match is None:
            fail(
                "private config line {} must be a literal FM_AZURE_NAME=value assignment".format(
                    number
                )
            )
        name, value = match.groups()
        if name not in allowed:
            fail("private config line {} names non-allowlisted {}".format(number, name))
        if name in values:
            fail("private config line {} duplicates {}".format(number, name))
        encoded = value.encode("utf-8")
        if not value:
            fail("private config line {} gives {} an empty value; omit unused values".format(number, name))
        if len(encoded) > MAX_VALUE_BYTES:
            fail("private config value for {} exceeds its byte bound".format(name))
        if any(ord(character) < 32 or ord(character) == 127 for character in value):
            fail("private config value for {} contains a control character".format(name))
        values[name] = value
    return values


def validate_effective_environment(environment: dict[str, str]) -> None:
    checks = (
        ([sys.executable, str(ROOT / "bin" / "fm-worker-lifecycle.py"), "environment-check"],
         "elastic worker controller"),
        ([str(ROOT / "bin" / "fm-azure-pilot.sh"), "controller-environment-check"],
         "Azure pilot controller"),
    )
    for command, label in checks:
        try:
            result = subprocess.run(
                command,
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=15,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            fail("{} validation could not run: {}".format(label, exc))
        if result.returncode == 0:
            continue
        detail = result.stderr.decode("utf-8", errors="replace")
        private_values = sorted(
            {
                value
                for name, value in environment.items()
                if name.startswith("FM_AZURE_") and value
            },
            key=len,
            reverse=True,
        )
        for value in private_values:
            detail = detail.replace(value, "<redacted>")
        detail = " ".join(detail.split())[-1000:]
        suffix = ": {}".format(detail) if detail else ""
        fail("{} values are invalid{}".format(label, suffix))


def merged_environment(path: Path) -> dict[str, str]:
    allowed, required = allowed_and_required_names()
    configured = parse_config(path, allowed)
    environment = os.environ.copy()
    for name, value in configured.items():
        if name not in environment:
            environment[name] = value
    missing = sorted(name for name in required if not environment.get(name))
    if missing:
        fail("private config plus explicit environment is missing required values: " + ", ".join(missing))
    validate_effective_environment(environment)
    environment[LOADED_MARKER] = str(path)
    return environment


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="validate and load Firstmate's private Azure controller environment"
    )
    value.add_argument("--config", required=True, help="exact private config file")
    value.add_argument("--check", action="store_true", help="validate without executing a command")
    value.add_argument("command", nargs=argparse.REMAINDER, help="command to exec after --")
    return value


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if args.check == bool(command):
        fail("choose exactly one of --check or a command after --")
    path = Path(args.config)
    environment = merged_environment(path)
    if args.check:
        print("Azure controller environment is valid: {}".format(path))
        return 0
    try:
        os.execvpe(command[0], command, environment)
    except OSError as exc:
        fail("configured command could not be executed: {}".format(exc))
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ControllerEnvironmentError as exc:
        print("error: Azure controller environment {}".format(exc), file=sys.stderr)
        raise SystemExit(1)
