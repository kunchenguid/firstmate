#!/usr/bin/env python3
"""Install the exact locked Agent Fleet source into a prepared offline venv.

The Azure runner has no package network while repository code executes and its
wheelhouse intentionally contains only locked registry dependencies. Agent
Fleet has no runtime dependencies, so this trusted installer copies the exact
snapshot package into the fresh venv, writes ordinary distribution metadata,
and creates the release-local console entrypoint without invoking an unsealed
PEP 517 build backend.
"""

import base64
import csv
import hashlib
import io
import os
from pathlib import Path
import re
import stat
import sys
import sysconfig


class InstallError(RuntimeError):
    pass


def real_subdirectory(root, parts, label):
    current = root
    for part in parts:
        current = current / part
        try:
            metadata = current.lstat()
        except OSError as exc:
            raise InstallError("{} is unavailable: {}".format(label, exc))
        if not stat.S_ISDIR(metadata.st_mode):
            raise InstallError("{} must have real directory ancestry".format(label))
    return current


def regular_file(path, label):
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise InstallError("{} is unavailable: {}".format(label, exc))
    if not stat.S_ISREG(metadata.st_mode):
        raise InstallError("{} must be a regular non-link file".format(label))
    return path


def write_new(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(str(path), flags, mode)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(content)
    os.chmod(path, mode)


def record_digest(path):
    digest = base64.urlsafe_b64encode(hashlib.sha256(path.read_bytes()).digest()).rstrip(b"=")
    return "sha256=" + digest.decode("ascii")


def copy_package(source, destination):
    if destination.exists() or destination.is_symlink():
        raise InstallError("Agent Fleet package destination already exists")
    destination.mkdir(parents=True, mode=0o755)
    copied = []
    for child in sorted(source.rglob("*")):
        relative = child.relative_to(source)
        metadata = child.lstat()
        target = destination / relative
        if stat.S_ISLNK(metadata.st_mode):
            raise InstallError("Agent Fleet source contains a link: {}".format(relative))
        if stat.S_ISDIR(metadata.st_mode):
            target.mkdir(mode=0o755)
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise InstallError("Agent Fleet source contains a non-regular entry: {}".format(relative))
        target.parent.mkdir(parents=True, exist_ok=True)
        write_new(target, child.read_bytes())
        copied.append(target)
    if not copied:
        raise InstallError("Agent Fleet source package is empty")
    return copied


def install(project, venv):
    if sys.version_info < (3, 11):
        raise InstallError("Agent Fleet requires Python 3.11 or newer")
    project = project.resolve()
    venv = venv.resolve()
    if Path(sys.prefix).resolve() != venv:
        raise InstallError("installer must run with the exact target venv interpreter")

    pyproject_path = regular_file(project / "pyproject.toml", "Agent Fleet pyproject")
    lock_path = regular_file(project / "uv.lock", "Agent Fleet lock")
    source = real_subdirectory(project, ("src", "agent_fleet"), "Agent Fleet package source")

    try:
        pyproject_text = pyproject_path.read_text(encoding="utf-8")
        lock_text = lock_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise InstallError("Agent Fleet project metadata is unreadable: {}".format(exc))

    project_match = re.search(r"(?ms)^\[project\]\n(.*?)(?=^\[|\Z)", pyproject_text)
    scripts_match = re.search(r"(?ms)^\[project\.scripts\]\n(.*?)(?=^\[|\Z)", pyproject_text)
    if project_match is None or scripts_match is None:
        raise InstallError("Agent Fleet project tables are absent")
    project_table = project_match.group(1)
    scripts_table = scripts_match.group(1)
    name_match = re.search(r'^name = "([^"]+)"$', project_table, re.MULTILINE)
    version_match = re.search(r'^version = "([^"]+)"$', project_table, re.MULTILINE)
    dependencies_match = re.search(r"^dependencies = (.+)$", project_table, re.MULTILINE)
    name = name_match.group(1) if name_match else None
    version = version_match.group(1) if version_match else None
    if name != "agent-fleet" or version is None or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", version):
        raise InstallError("Agent Fleet project identity is not exact")
    script_lines = [line.strip() for line in scripts_table.splitlines() if line.strip()]
    if script_lines != ['agent-fleet = "agent_fleet.cli:main"']:
        raise InstallError("Agent Fleet console entrypoint declaration is not exact")
    if dependencies_match is None or dependencies_match.group(1).strip() != "[]":
        raise InstallError("Agent Fleet gained runtime dependencies outside the sealed offline closure")

    locked = []
    for block in lock_text.split("[[package]]")[1:]:
        locked_name = re.search(r'^name = "([^"]+)"$', block, re.MULTILINE)
        if locked_name and locked_name.group(1) == name:
            locked.append(block)
    if len(locked) != 1:
        raise InstallError("Agent Fleet lock does not contain one exact project record")
    locked_block = locked[0]
    if (
        not re.search(r'^version = "{}"$'.format(re.escape(version)), locked_block, re.MULTILINE)
        or not re.search(r'^source = \{ editable = "\." \}$', locked_block, re.MULTILINE)
        or re.search(r"^dependencies = \[", locked_block, re.MULTILINE)
    ):
        raise InstallError("Agent Fleet lock does not bind the exact editable project without runtime dependencies")

    purelib = Path(sysconfig.get_path("purelib")).resolve()
    scripts_dir = Path(sysconfig.get_path("scripts")).resolve()
    if venv not in purelib.parents or venv not in scripts_dir.parents:
        raise InstallError("target interpreter paths escape the exact venv")

    package_destination = purelib / "agent_fleet"
    dist_info = purelib / "agent_fleet-{}.dist-info".format(version)
    entrypoint = scripts_dir / "agent-fleet"
    if dist_info.exists() or dist_info.is_symlink() or entrypoint.exists() or entrypoint.is_symlink():
        raise InstallError("Agent Fleet project or console entrypoint is already installed")

    installed = copy_package(source, package_destination)
    dist_info.mkdir(mode=0o755)
    metadata = (
        "Metadata-Version: 2.3\n"
        "Name: agent-fleet\n"
        "Version: {}\n"
        "Summary: Machine-global account profile routing for local agent CLIs\n"
        "Requires-Python: >=3.11\n"
        "\n"
    ).format(version).encode("utf-8")
    write_new(dist_info / "METADATA", metadata)
    write_new(dist_info / "WHEEL", b"Wheel-Version: 1.0\nGenerator: fm-azure-runner\nRoot-Is-Purelib: true\nTag: py3-none-any\n")
    write_new(dist_info / "entry_points.txt", b"[console_scripts]\nagent-fleet = agent_fleet.cli:main\n")
    write_new(dist_info / "INSTALLER", b"fm-azure-runner\n")

    python_path = venv / "bin" / "python"
    if not python_path.exists():
        raise InstallError("target venv has no Python entrypoint")
    entrypoint_bytes = (
        "#!{}\n"
        "import sys\n"
        "from agent_fleet.cli import main\n"
        "if __name__ == '__main__':\n"
        "    sys.exit(main())\n"
    ).format(python_path).encode("utf-8")
    write_new(entrypoint, entrypoint_bytes, mode=0o755)

    record_rows = []
    for path in sorted(installed + [
        dist_info / "METADATA",
        dist_info / "WHEEL",
        dist_info / "entry_points.txt",
        dist_info / "INSTALLER",
        entrypoint,
    ]):
        relative = path.relative_to(venv).as_posix()
        record_rows.append((relative, record_digest(path), str(path.stat().st_size)))
    record_path = dist_info / "RECORD"
    record_rows.append((record_path.relative_to(venv).as_posix(), "", ""))
    output = io.StringIO(newline="")
    writer = csv.writer(output, lineterminator="\n")
    writer.writerows(record_rows)
    write_new(record_path, output.getvalue().encode("utf-8"))
    return entrypoint


def main():
    if len(sys.argv) != 3:
        print("usage: fm-azure-runner-agent-fleet-install.py <project> <venv>", file=sys.stderr)
        return 2
    try:
        entrypoint = install(Path(sys.argv[1]), Path(sys.argv[2]))
    except InstallError as exc:
        print("agent-fleet offline install failed: {}".format(exc), file=sys.stderr)
        return 125
    print("agent-fleet offline install: {}".format(entrypoint))
    return 0


if __name__ == "__main__":
    sys.exit(main())
