#!/usr/bin/env python3
"""Implementation core for bin/fm-council.sh.

The shell entrypoint and its --help output are the public contract.
This module owns only the private mechanics behind that contract.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterator


SCHEMA = "fm-council.v1"
SUPPORTED: dict[tuple[str, str, str], str] = {
    ("claude", "claude-fable-5", "xhigh"): "anthropic",
    ("codex", "gpt-5.6-sol", "xhigh"): "openai",
}
SECRET_NAMES = {
    ".netrc",
    ".npmrc",
    ".pypirc",
    "auth.json",
    "credentials",
    "credentials.json",
    "id_dsa",
    "id_ed25519",
    "id_ecdsa",
    "id_rsa",
    "service-account.json",
}
SECRET_SUFFIXES = (".pem", ".key", ".p12", ".pfx", ".jks", ".keystore")
SECRET_STEMS = {"secret", "secrets", "token", "tokens"}
SECRET_STEM_SUFFIXES = ("", ".yaml", ".yml", ".json", ".txt", ".toml", ".ini")
SKIP_DIRS = {".git", ".hg", ".svn", "node_modules", "__pycache__", ".cache", ".venv", "venv"}
SECRET_DIRS = {".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker"}
MAX_FILE_BYTES = 20 * 1024 * 1024
MAX_ANSWER_BYTES = 1024 * 1024


class CouncilError(RuntimeError):
    pass


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def atomic_bytes(path: Path, content: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def atomic_text(path: Path, content: str, mode: int = 0o600) -> None:
    atomic_bytes(path, content.encode(), mode)


def atomic_json(path: Path, value: Any) -> None:
    atomic_text(path, json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def load_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except FileNotFoundError as error:
        raise CouncilError(f"missing council record: {path}") from error
    except json.JSONDecodeError as error:
        raise CouncilError(f"invalid council JSON: {path}: {error}") from error


def append_event(path: Path, event: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    event = {"at": now(), **event}
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, (json.dumps(event, sort_keys=True, ensure_ascii=False) + "\n").encode())
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def slug(value: str) -> str:
    cleaned = "".join(character.lower() if character.isalnum() else "-" for character in value)
    cleaned = "-".join(part for part in cleaned.split("-") if part)[:40].strip("-")
    if not cleaned:
        cleaned = "council"
    suffix = hashlib.sha256(value.casefold().encode()).hexdigest()[:8]
    return f"{cleaned}-{suffix}"


def validate_name(value: str) -> str:
    value = value.strip()
    if not value or "\n" in value or "\r" in value or "\0" in value:
        raise CouncilError("council name must be one non-empty line")
    return value


def canonical_project(path: str) -> Path:
    candidate = Path(path).expanduser()
    if candidate.is_symlink():
        raise CouncilError("project root may not be a symlink")
    try:
        resolved = candidate.resolve(strict=True)
    except FileNotFoundError as error:
        raise CouncilError(f"project path does not exist: {candidate}") from error
    if not resolved.is_dir():
        raise CouncilError(f"project path is not a directory: {resolved}")
    for system_root in (Path("/usr"), Path("/etc"), Path("/proc"), Path("/sys"), Path("/dev")):
        with contextlib.suppress(ValueError):
            resolved.relative_to(system_root)
            raise CouncilError(f"project path is inside the sandbox's admitted system surface: {resolved}")
    return resolved


def profile(text: str) -> dict[str, str]:
    parts = text.split("/")
    if len(parts) != 3 or any(not part for part in parts):
        raise CouncilError(f"participant must be harness/model/effort, got: {text}")
    key = tuple(parts)
    provider = SUPPORTED.get(key)
    if provider is None:
        supported = ", ".join("/".join(item) for item in SUPPORTED)
        raise CouncilError(f"unsupported exact participant profile '{text}'; supported: {supported}")
    harness, model, effort = parts
    return {
        "id": f"{harness}-{hashlib.sha256(text.encode()).hexdigest()[:10]}",
        "harness": harness,
        "model": model,
        "effort": effort,
        "provider": provider,
    }


class Paths:
    def __init__(self) -> None:
        root = Path(__file__).resolve().parent.parent
        home = Path(os.environ.get("FM_HOME", root)).resolve()
        self.root = root
        self.home = home
        self.data = Path(os.environ.get("FM_DATA_OVERRIDE", home / "data")).resolve()
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE", home / "state")).resolve()
        self.config = Path(os.environ.get("FM_CONFIG_OVERRIDE", home / "config")).resolve()
        self.councils = self.data / "councils"
        self.runtime = self.state / "councils"
        self.projects = self.data / "council-projects"
        self.consent = self.config / "council-provider-consent.json"
        for path in (self.councils, self.runtime, self.projects, self.config):
            path.mkdir(parents=True, exist_ok=True, mode=0o700)

    def council_dir(self, council_id: str) -> Path:
        return self.councils / council_id

    def runtime_dir(self, council_id: str) -> Path:
        return self.runtime / council_id


PATHS = Paths()


@contextlib.contextmanager
def lock(path: Path, blocking: bool = True) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        flags = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
        try:
            fcntl.flock(descriptor, flags)
        except BlockingIOError as error:
            raise CouncilError("another command is already changing this council") from error
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def read_council_record(record_path: Path) -> dict[str, Any]:
    record = load_json(record_path)
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        raise CouncilError(f"unsupported council schema in {record_path}")
    return record


def find_council(name: str, include_closed: bool = True) -> tuple[Path, dict[str, Any]]:
    wanted = name.casefold()
    matches: list[tuple[Path, dict[str, Any]]] = []
    for record_path in PATHS.councils.glob("*/council.json"):
        try:
            record = read_council_record(record_path)
        except CouncilError:
            if record_path.parent.name == name:
                raise
            continue
        if record.get("id") == name or str(record.get("name", "")).casefold() == wanted:
            if include_closed or record.get("status") == "open":
                matches.append((record_path.parent, record))
    if not matches:
        raise CouncilError(f"council not found: {name}")
    if len(matches) != 1:
        raise CouncilError(f"ambiguous council identity: {name}")
    return matches[0]


def save_council(directory: Path, council: dict[str, Any]) -> None:
    council["updated_at"] = now()
    atomic_json(directory / "council.json", council)


def reload_open_council(directory: Path) -> dict[str, Any]:
    council = read_council_record(directory / "council.json")
    if council.get("status") != "open":
        raise CouncilError("council is closed")
    return council


def project_key(project: Path) -> str:
    return hashlib.sha256(str(project).encode()).hexdigest()


def project_decision_dir(project: Path) -> Path:
    return PATHS.projects / project_key(project) / "decisions"


def decision_index(project: Path) -> dict[str, Any]:
    path = project_decision_dir(project) / "index.json"
    if not path.exists():
        return {"schema": "fm-council-project-decisions.v1", "project": str(project), "decisions": []}
    value = load_json(path)
    if value.get("schema") != "fm-council-project-decisions.v1" or value.get("project") != str(project):
        raise CouncilError(f"invalid project decision index: {path}")
    return value


def active_project_decision_ids(project: Path) -> list[str]:
    return [str(item["id"]) for item in decision_index(project).get("decisions", []) if item.get("active", True)]


def decision_path(project: Path, decision_id: str) -> Path:
    return project_decision_dir(project) / f"{decision_id}.md"


def load_consent() -> dict[str, Any]:
    if not PATHS.consent.exists():
        return {"schema": "fm-council-provider-consent.v1", "consents": []}
    value = load_json(PATHS.consent)
    if value.get("schema") != "fm-council-provider-consent.v1":
        raise CouncilError(f"unsupported provider consent schema: {PATHS.consent}")
    return value


def has_consent(provider: str, project: Path) -> bool:
    return any(
        item.get("provider") == provider and item.get("project") == str(project) and item.get("active") is True
        for item in load_consent().get("consents", [])
    )


def command_consent(arguments: argparse.Namespace) -> None:
    project = canonical_project(arguments.project)
    if not arguments.acknowledge_project_disclosure:
        raise CouncilError("provider consent requires --acknowledge-project-disclosure after the captain explicitly approves this provider and project")
    providers = {value for value in SUPPORTED.values()}
    if arguments.provider not in providers:
        raise CouncilError(f"unsupported provider: {arguments.provider}")
    with lock(PATHS.config / ".council-provider-consent.lock"):
        consent = load_consent()
        records = consent["consents"]
        for item in records:
            if item.get("provider") == arguments.provider and item.get("project") == str(project):
                item.update({"active": True, "granted_at": now()})
                break
        else:
            records.append({"provider": arguments.provider, "project": str(project), "active": True, "granted_at": now()})
        atomic_json(PATHS.consent, consent)
    print(f"consent saved: {arguments.provider} may receive filtered council views of {project}")


def excluded_reason(relative: Path, entry: os.DirEntry[str]) -> str | None:
    name = entry.name.lower()
    if entry.is_symlink():
        return "symlink"
    if entry.is_dir(follow_symlinks=False) and name in SKIP_DIRS:
        return "metadata-or-build-directory"
    if entry.is_dir(follow_symlinks=False) and name in SECRET_DIRS:
        return "credential-directory-default"
    if name == ".env.example":
        return None
    if name == ".env" or name.startswith(".env."):
        return "secret-default"
    if name in SECRET_NAMES or name.endswith(SECRET_SUFFIXES) or "credential" in name or "private-key" in name:
        return "credential-default"
    if not entry.is_dir(follow_symlinks=False) and any(
        name == stem + suffix for stem in SECRET_STEMS for suffix in SECRET_STEM_SUFFIXES
    ):
        return "secret-default"
    return None


def inventory(source: Path) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    entries: list[dict[str, Any]] = []
    excluded: list[dict[str, str]] = []

    def walk(directory: Path, relative: Path) -> None:
        try:
            children = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError as error:
            raise CouncilError(f"cannot read project directory {directory}: {error}") from error
        for child in children:
            child_relative = relative / child.name
            reason = excluded_reason(child_relative, child)
            if reason:
                excluded.append({"path": child_relative.as_posix(), "reason": reason})
                continue
            try:
                child_stat = child.stat(follow_symlinks=False)
            except OSError as error:
                raise CouncilError(f"cannot stat project entry {child_relative}: {error}") from error
            if stat.S_ISDIR(child_stat.st_mode):
                entries.append({"path": child_relative.as_posix(), "type": "dir", "mode": stat.S_IMODE(child_stat.st_mode)})
                walk(Path(child.path), child_relative)
            elif stat.S_ISREG(child_stat.st_mode):
                if child_stat.st_size > MAX_FILE_BYTES:
                    excluded.append({"path": child_relative.as_posix(), "reason": "file-too-large"})
                    continue
                try:
                    content = Path(child.path).read_bytes()
                except OSError as error:
                    raise CouncilError(f"cannot read project file {child_relative}: {error}") from error
                entries.append(
                    {
                        "path": child_relative.as_posix(),
                        "type": "file",
                        "mode": stat.S_IMODE(child_stat.st_mode),
                        "size": len(content),
                        "sha256": hashlib.sha256(content).hexdigest(),
                    }
                )
            else:
                excluded.append({"path": child_relative.as_posix(), "reason": "unsafe-file-type"})

    walk(source, Path())
    return entries, excluded


def remove_readonly_tree(root: Path) -> None:
    if not root.exists():
        return
    for path in sorted(root.rglob("*"), reverse=True):
        with contextlib.suppress(OSError):
            os.chmod(path, 0o700 if path.is_dir() else 0o600)
    with contextlib.suppress(OSError):
        os.chmod(root, 0o700)
    shutil.rmtree(root, ignore_errors=True)


def build_snapshot(council_dir: Path, source: Path, round_id: str) -> tuple[Path, str, list[dict[str, str]]]:
    snapshots = council_dir / "snapshots"
    snapshots.mkdir(parents=True, exist_ok=True, mode=0o700)
    for attempt in range(2):
        before, excluded_before = inventory(source)
        staging = Path(tempfile.mkdtemp(prefix=f".{round_id}.", dir=snapshots))
        tree = staging / "project"
        tree.mkdir(mode=0o700)
        try:
            try:
                for entry in before:
                    target = tree / entry["path"]
                    if entry["type"] == "dir":
                        target.mkdir(parents=True, exist_ok=True, mode=0o700)
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                        shutil.copyfile(source / entry["path"], target, follow_symlinks=False)
                        os.chmod(target, entry["mode"])
                for entry in before:
                    if entry["type"] == "dir":
                        os.chmod(tree / entry["path"], entry["mode"])
            except OSError as error:
                raise CouncilError(f"cannot copy the project into its fixed read-only view: {error}") from error
            after, excluded_after = inventory(source)
            copied, copied_excluded = inventory(tree)
            if before != after or excluded_before != excluded_after or before != copied or copied_excluded:
                remove_readonly_tree(staging)
                if attempt == 0:
                    continue
                raise CouncilError("project changed while the fixed read-only view was being built; retry after it stabilizes")
            manifest_bytes = json.dumps(before, sort_keys=True, separators=(",", ":")).encode()
            view_hash = hashlib.sha256(manifest_bytes).hexdigest()
            manifest = {
                "schema": "fm-council-view.v1",
                "source": str(source),
                "round_id": round_id,
                "view_hash": view_hash,
                "entries": before,
                "excluded": excluded_before,
                "created_at": now(),
            }
            atomic_json(staging / "manifest.json", manifest)
            for path in sorted(tree.rglob("*"), reverse=True):
                os.chmod(path, 0o555 if path.is_dir() else 0o444)
            os.chmod(tree, 0o555)
            final = snapshots / round_id
            os.replace(staging, final)
            return final / "project", view_hash, excluded_before
        except Exception:
            remove_readonly_tree(staging)
            raise
    raise CouncilError("could not build a stable project view")


def copy_auth(profile_value: dict[str, str], lane_home: Path) -> None:
    real_home = Path.home()
    if profile_value["harness"] == "claude":
        source = real_home / ".claude" / ".credentials.json"
        destination = lane_home / ".claude" / ".credentials.json"
    else:
        source = real_home / ".codex" / "auth.json"
        destination = lane_home / ".codex" / "auth.json"
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if source.is_file():
        shutil.copyfile(source, destination)
        os.chmod(destination, 0o600)


def executable_paths(harness: str) -> list[str]:
    names = ["bash", "sh", "cat", "rg", "grep", "find", "sed", "awk", "head", "tail", "wc", "sort", "uniq", "cut", "tr", "ls", "stat", "mktemp", "mv", "env", "node"]
    result: list[str] = []
    for name in [harness, *names]:
        resolved = shutil.which(name)
        if resolved:
            real = str(Path(resolved).resolve())
            if real not in result:
                result.append(real)
    if harness == "codex":
        codex_root = Path("/usr/lib/node_modules/@openai/codex")
        if codex_root.exists():
            for path in codex_root.glob("node_modules/@openai/codex-linux-*/vendor/*/bin/codex"):
                result.append(str(path.resolve()))
            for path in codex_root.glob("node_modules/@openai/codex-linux-*/vendor/*/bin/codex-code-mode-host"):
                result.append(str(path.resolve()))
    return sorted(set(result))


def launch_argv(profile_value: dict[str, str]) -> list[str]:
    if profile_value["harness"] == "claude":
        return [
            shutil.which("claude") or "claude",
            "--model",
            profile_value["model"],
            "--effort",
            profile_value["effort"],
            "--dangerously-skip-permissions",
        ]
    return [
        shutil.which("codex") or "codex",
        "--model",
        profile_value["model"],
        "-c",
        f'model_reasoning_effort="{profile_value["effort"]}"',
        "--dangerously-bypass-approvals-and-sandbox",
        "--cd",
        ".",
    ]


def sandbox_command(profile_value: dict[str, str], lane_home: Path, snapshots: Path) -> list[str]:
    command = [
        shutil.which("python3") or "/usr/bin/python3",
        str(PATHS.root / "bin" / "fm-council-sandbox.py"),
        "--home",
        str(lane_home),
        "--readable",
        str(snapshots),
        "--harness",
        profile_value["harness"],
    ]
    for executable in executable_paths(profile_value["harness"]):
        command.extend(("--allow-exec", executable))
    command.append("--")
    command.extend(launch_argv(profile_value))
    return command


def test_transport() -> str | None:
    return os.environ.get("FM_COUNCIL_TEST_TRANSPORT")


def run_transport(arguments: list[str], expect_json: bool = False) -> Any:
    transport = test_transport()
    if not transport:
        raise CouncilError("internal: no test transport configured")
    result = subprocess.run([transport, *arguments], text=True, capture_output=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise CouncilError(f"participant transport failed: {detail}")
    if expect_json:
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise CouncilError("participant transport returned invalid JSON") from error
    return result.stdout


def herdr_session(arguments: argparse.Namespace | None = None) -> str:
    explicit = getattr(arguments, "herdr_session", None) if arguments else None
    return explicit or os.environ.get("FM_COUNCIL_HERDR_SESSION") or os.environ.get("HERDR_SESSION") or "default"


def herdr_run(session: str, arguments: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    helper = os.environ.get("FM_COUNCIL_HERDR_LAB_HELPER")
    if helper:
        command = [helper, "run", session, *arguments]
        environment = os.environ.copy()
    else:
        command = ["herdr", *arguments, "--session", session]
        environment = {**os.environ, "HERDR_SESSION": session}
    result = subprocess.run(command, text=True, capture_output=True, check=False, env=environment)
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise CouncilError(f"Herdr command failed: {detail}")
    return result


def parse_result_json(result: subprocess.CompletedProcess[str], label: str) -> dict[str, Any]:
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise CouncilError(f"could not parse Herdr {label} response") from error
    if not isinstance(value, dict):
        raise CouncilError(f"invalid Herdr {label} response")
    return value


def launch_test_members(council: dict[str, Any], directory: Path) -> None:
    runtime_root = PATHS.runtime_dir(council["id"])
    for member in council["members"]:
        lane_home = runtime_root / "members" / member["id"] / "home"
        lane_home.mkdir(parents=True, exist_ok=False, mode=0o700)
        owner = secrets.token_hex(16)
        seed = {
            "schema": "fm-council-member-runtime.v1",
            "council_id": council["id"],
            "member_id": member["id"],
            "owner_token": owner,
            "machine_label": f"fm-council-{council['id']}-{member['id']}",
            "home": str(lane_home),
            "delivered_decisions": [],
        }
        runtime_path = lane_home.parent / "runtime.json"
        atomic_json(runtime_path, seed)
        returned = run_transport(["launch", council["id"], member["id"], owner, str(runtime_path)], expect_json=True)
        for field in ("session", "workspace_id", "tab_id", "pane_id", "endpoint"):
            if not isinstance(returned.get(field), str) or not returned[field]:
                raise CouncilError(f"test transport launch omitted exact endpoint field {field}")
        seed.update({field: returned[field] for field in ("session", "workspace_id", "tab_id", "pane_id", "endpoint")})
        atomic_json(runtime_path, seed)
        member["runtime"] = str(runtime_path.relative_to(PATHS.home) if runtime_path.is_relative_to(PATHS.home) else runtime_path)


def launch_herdr_members(council: dict[str, Any], directory: Path, arguments: argparse.Namespace) -> None:
    if sys.platform != "linux" or os.uname().machine != "x86_64":
        raise CouncilError("the MVP participant lane is verified only on Linux x86_64")
    has_herdr = shutil.which("herdr") is not None or os.environ.get("FM_COUNCIL_HERDR_LAB_HELPER")
    if not has_herdr or shutil.which("python3") is None:
        raise CouncilError("Herdr and python3 are required for council participants")
    runtime_root = PATHS.runtime_dir(council["id"])
    session = herdr_session(arguments)
    member_endpoints: list[tuple[dict[str, str], str, str, str, str]] = []
    created_panes: list[str] = []
    try:
        first_member = council["members"][0]
        first_home = runtime_root / "members" / first_member["id"] / "home"
        first_home.mkdir(parents=True, exist_ok=False, mode=0o700)
        token = secrets.token_hex(10)
        workspace_label = f"fm-council-{council['id']}-{token}"
        response = parse_result_json(
            herdr_run(session, ["workspace", "create", "--cwd", str(first_home), "--label", workspace_label, "--no-focus"]),
            "workspace create",
        )
        workspace_id = str(response.get("result", {}).get("workspace", {}).get("workspace_id", ""))
        first_tab = str(response.get("result", {}).get("tab", {}).get("tab_id", ""))
        first_pane = str(response.get("result", {}).get("root_pane", {}).get("pane_id", ""))
        if not workspace_id or not first_tab or not first_pane:
            raise CouncilError("Herdr workspace create omitted exact endpoint IDs")
        first_label = f"fm-council-member-{council['id']}-{first_member['id']}-{token}"
        herdr_run(session, ["tab", "rename", first_tab, first_label])
        created_panes.append(first_pane)
        member_endpoints.append((first_member, first_tab, first_pane, first_label, str(first_home)))

        for member in council["members"][1:]:
            lane_home = runtime_root / "members" / member["id"] / "home"
            lane_home.mkdir(parents=True, exist_ok=False, mode=0o700)
            label = f"fm-council-member-{council['id']}-{member['id']}-{token}"
            response = parse_result_json(
                herdr_run(
                    session,
                    ["tab", "create", "--workspace", workspace_id, "--cwd", str(lane_home), "--label", label, "--no-focus"],
                ),
                "tab create",
            )
            tab_id = str(response.get("result", {}).get("tab", {}).get("tab_id", ""))
            pane_id = str(response.get("result", {}).get("root_pane", {}).get("pane_id", ""))
            if not tab_id or not pane_id:
                raise CouncilError("Herdr tab create omitted exact endpoint IDs")
            created_panes.append(pane_id)
            member_endpoints.append((member, tab_id, pane_id, label, str(lane_home)))

        for member, tab_id, pane_id, label, home_text in member_endpoints:
            lane_home = Path(home_text)
            for child in ("outbox", "inbox", "tmp", ".config", ".cache", ".local/share"):
                (lane_home / child).mkdir(parents=True, exist_ok=True, mode=0o700)
            copy_auth(member, lane_home)
            command = sandbox_command(member, lane_home, directory / "snapshots")
            herdr_run(session, ["pane", "run", pane_id, shlex.join(command)])
            runtime = {
                "schema": "fm-council-member-runtime.v1",
                "council_id": council["id"],
                "member_id": member["id"],
                "owner_token": token,
                "machine_label": label,
                "session": session,
                "workspace_id": workspace_id,
                "tab_id": tab_id,
                "pane_id": pane_id,
                "endpoint": f"{session}:{pane_id}",
                "home": str(lane_home),
                "delivered_decisions": [],
                "sandbox": "linux-landlock-v1",
                "launch_profile": {key: member[key] for key in ("harness", "model", "effort")},
            }
            runtime_path = lane_home.parent / "runtime.json"
            atomic_json(runtime_path, runtime)
            member["runtime"] = str(runtime_path.relative_to(PATHS.home) if runtime_path.is_relative_to(PATHS.home) else runtime_path)
        council["herdr_session"] = session
        council["herdr_workspace_id"] = workspace_id
        council["owner_token"] = token
    except Exception:
        for pane in reversed(created_panes):
            herdr_run(session, ["pane", "close", pane], check=False)
        shutil.rmtree(runtime_root, ignore_errors=True)
        raise


def runtime_path(member: dict[str, Any]) -> Path:
    value = Path(str(member["runtime"]))
    return value if value.is_absolute() else PATHS.home / value


def load_runtime(council: dict[str, Any], member: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    path = runtime_path(member).resolve()
    expected_path = (PATHS.runtime_dir(council["id"]) / "members" / member["id"] / "runtime.json").resolve()
    if path != expected_path:
        raise CouncilError(f"participant runtime path escaped its exact council/member identity: {path}")
    value = load_json(path)
    expected_home = (expected_path.parent / "home").resolve()
    if (
        value.get("schema") != "fm-council-member-runtime.v1"
        or value.get("council_id") != council["id"]
        or value.get("member_id") != member["id"]
        or Path(str(value.get("home", ""))).resolve() != expected_home
        or any(not isinstance(value.get(field), str) or not value[field] for field in ("session", "workspace_id", "tab_id", "pane_id", "endpoint", "owner_token"))
    ):
        raise CouncilError(f"invalid participant runtime identity: {path}")
    return path, value


def command_create(arguments: argparse.Namespace) -> None:
    name = validate_name(arguments.name)
    project = canonical_project(arguments.project)
    participants = [profile(value) for value in arguments.participant]
    if len(participants) < 2:
        raise CouncilError("a council requires at least two exact participant profiles")
    ids = [item["id"] for item in participants]
    if len(set(ids)) != len(ids):
        raise CouncilError("duplicate participant profiles are not allowed")
    council_id = slug(name)
    with lock(PATHS.councils / ".registry.lock"):
        for record_path in PATHS.councils.glob("*/council.json"):
            try:
                record = read_council_record(record_path)
            except CouncilError:
                continue
            if str(record.get("name", "")).casefold() == name.casefold():
                raise CouncilError(f"council name already exists: {name}")
        directory = PATHS.council_dir(council_id)
        if directory.exists():
            raise CouncilError(f"council identity already exists: {council_id}")
        directory.mkdir(parents=True, mode=0o700)
        (directory / "snapshots").mkdir(mode=0o700)
        council = {
            "schema": SCHEMA,
            "id": council_id,
            "name": name,
            "status": "open",
            "phase": "idle",
            "project": str(project),
            "project_key": project_key(project),
            "members": participants,
            "decision_ids": [] if arguments.clean_slate else active_project_decision_ids(project),
            "clean_slate": bool(arguments.clean_slate),
            "active_round": None,
            "round_counter": 0,
            "created_at": now(),
            "updated_at": now(),
        }
        save_council(directory, council)
        try:
            if test_transport():
                launch_test_members(council, directory)
            else:
                launch_herdr_members(council, directory, arguments)
            save_council(directory, council)
            append_event(directory / "events.jsonl", {"event": "council_created", "members": ids})
        except Exception:
            shutil.rmtree(directory, ignore_errors=True)
            shutil.rmtree(PATHS.runtime_dir(council_id), ignore_errors=True)
            raise
    print(json.dumps({"council": name, "id": council_id, "project": str(project), "members": ids, "clean_slate": bool(arguments.clean_slate)}, ensure_ascii=False))


def probe_member(council: dict[str, Any], member: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    _, runtime = load_runtime(council, member)
    if test_transport():
        try:
            value = run_transport(
                ["probe", council["id"], member["id"], runtime["owner_token"], str(runtime_path(member))],
                expect_json=True,
            )
        except CouncilError:
            return "unavailable", runtime
        exact = all(value.get(field) == runtime.get(field) for field in ("session", "workspace_id", "tab_id", "pane_id", "owner_token"))
        return ("available" if exact and value.get("alive") is True else "unavailable"), runtime
    pane_result = herdr_run(runtime["session"], ["pane", "get", runtime["pane_id"]], check=False)
    tab_result = herdr_run(runtime["session"], ["tab", "get", runtime["tab_id"]], check=False)
    if pane_result.returncode != 0 or tab_result.returncode != 0:
        return "unavailable", runtime
    try:
        pane = json.loads(pane_result.stdout).get("result", {}).get("pane", {})
        tab = json.loads(tab_result.stdout).get("result", {}).get("tab", {})
    except json.JSONDecodeError:
        return "unavailable", runtime
    exact = (
        pane.get("pane_id") == runtime["pane_id"]
        and pane.get("tab_id") == runtime["tab_id"]
        and pane.get("workspace_id") == runtime["workspace_id"]
        and tab.get("tab_id") == runtime["tab_id"]
        and tab.get("workspace_id") == runtime["workspace_id"]
        and tab.get("label") == runtime["machine_label"]
    )
    return ("available" if exact else "unavailable"), runtime


def write_payload(runtime: dict[str, Any], kind: str, payload: str) -> Path:
    inbox = Path(runtime["home"]) / "inbox"
    inbox.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = inbox / f"{now().replace(':', '')}-{kind}-{secrets.token_hex(4)}.md"
    atomic_text(path, payload)
    return path


def send_member(
    council: dict[str, Any],
    member: dict[str, Any],
    kind: str,
    payload: str,
    answer_path: Path | None = None,
    common_path: Path | None = None,
) -> bool:
    state, runtime = probe_member(council, member)
    if state != "available":
        return False
    payload_path = write_payload(runtime, kind, payload)
    if test_transport():
        try:
            run_transport(
                [
                    "send",
                    council["id"],
                    member["id"],
                    kind,
                    str(payload_path),
                    str(common_path or "-"),
                    str(runtime_path(member)),
                ]
            )
            return True
        except CouncilError:
            return False
    digest = hashlib.sha256(payload.encode()).hexdigest()
    lines = [
        f"Council {kind} message. Your complete instructions are in your own private inbox payload file.",
        f"Payload file: {payload_path}",
        f"Payload sha256: {digest}",
    ]
    if answer_path is not None:
        lines.append(f"Write your complete answer atomically to this participant-private path before finishing your turn: {answer_path}")
        lines.append("Use a temporary file in the same directory and rename it into place. Do not only leave the answer on screen.")
    lines.append("Read the payload file, verify its exact sha256, then follow it fully.")
    instruction = "\n".join(lines) + "\n"
    result = herdr_run(runtime["session"], ["agent", "send", runtime["pane_id"], instruction], check=False)
    return result.returncode == 0


def update_runtime(path: Path, runtime: dict[str, Any]) -> None:
    atomic_json(path, runtime)


def open_outbox_dir(home: Path) -> int | None:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        descriptor = os.open(str(home.parent), flags)
    except OSError:
        return None
    for component in ("home", "outbox"):
        try:
            child = os.open(component, flags, dir_fd=descriptor)
        except OSError:
            os.close(descriptor)
            return None
        os.close(descriptor)
        descriptor = child
    return descriptor


def expected_answer_path(runtime: dict[str, Any], round_id: str) -> Path:
    return Path(str(runtime["home"])) / "outbox" / f"{round_id}.md"


def read_member_answer(council: dict[str, Any], member: dict[str, Any], round_id: str, answer_value: Any) -> str | None:
    try:
        _, runtime = load_runtime(council, member)
    except CouncilError:
        return None
    if not answer_value or Path(str(answer_value)) != expected_answer_path(runtime, round_id):
        return None
    directory_fd = open_outbox_dir(Path(str(runtime["home"])))
    if directory_fd is None:
        return None
    try:
        answer_fd = os.open(f"{round_id}.md", os.O_RDONLY | os.O_NOFOLLOW | os.O_NOCTTY | os.O_CLOEXEC, dir_fd=directory_fd)
    except OSError:
        return None
    finally:
        os.close(directory_fd)
    try:
        info = os.fstat(answer_fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_uid != os.getuid()
            or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH | stat.S_ISUID | stat.S_ISGID)
            or not 0 < info.st_size <= MAX_ANSWER_BYTES
        ):
            return None
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(answer_fd, 1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_ANSWER_BYTES:
                return None
    finally:
        os.close(answer_fd)
    try:
        return b"".join(chunks).decode("utf-8")
    except UnicodeDecodeError:
        return None


def remove_member_answer(council: dict[str, Any], member: dict[str, Any], round_id: str, answer_value: Any) -> None:
    try:
        _, runtime = load_runtime(council, member)
    except CouncilError:
        return
    if not answer_value or Path(str(answer_value)) != expected_answer_path(runtime, round_id):
        return
    directory_fd = open_outbox_dir(Path(str(runtime["home"])))
    if directory_fd is None:
        return
    try:
        with contextlib.suppress(OSError):
            os.unlink(f"{round_id}.md", dir_fd=directory_fd)
    finally:
        os.close(directory_fd)


def catch_up_member(directory: Path, council: dict[str, Any], member: dict[str, Any]) -> bool:
    path, runtime = load_runtime(council, member)
    delivered = list(runtime.get("delivered_decisions", []))
    project = Path(council["project"])
    for decision_id in council.get("decision_ids", []):
        if decision_id in delivered:
            continue
        body_path = decision_path(project, decision_id)
        if not body_path.is_file():
            raise CouncilError(f"accepted decision body is missing: {body_path}")
        body = body_path.read_text(encoding="utf-8")
        if not send_member(council, member, "decision", body):
            append_event(directory / "events.jsonl", {"event": "decision_delivery_deferred", "member": member["id"], "decision": decision_id})
            return False
        delivered.append(decision_id)
        runtime["delivered_decisions"] = delivered
        update_runtime(path, runtime)
        append_event(directory / "events.jsonl", {"event": "decision_delivered", "member": member["id"], "decision": decision_id})
    return True


def round_record_path(directory: Path, round_id: str) -> Path:
    return directory / "rounds" / round_id / "round.json"


def load_round(directory: Path, round_id: str) -> dict[str, Any]:
    return load_json(round_record_path(directory, round_id))


def save_round(directory: Path, round_value: dict[str, Any]) -> None:
    atomic_json(round_record_path(directory, round_value["id"]), round_value)


def next_round_id(council: dict[str, Any]) -> str:
    council["round_counter"] = int(council.get("round_counter", 0)) + 1
    return f"R{council['round_counter']:04d}"


def accepted_context(council: dict[str, Any]) -> str:
    project = Path(council["project"])
    sections: list[str] = []
    for decision_id in council.get("decision_ids", []):
        path = decision_path(project, decision_id)
        if path.is_file():
            sections.append(f"### {decision_id}\n\n{path.read_text(encoding='utf-8')}")
    return "\n\n".join(sections) if sections else "(none)"


def require_idle(council: dict[str, Any]) -> None:
    if council.get("status") != "open":
        raise CouncilError("council is closed")
    if council.get("phase") != "idle" or council.get("active_round"):
        raise CouncilError(f"council already has an active round in phase {council.get('phase')}")


def start_round(directory: Path, council: dict[str, Any], task: str) -> dict[str, Any]:
    require_idle(council)
    task = task.strip()
    if not task:
        raise CouncilError("round task must not be empty")
    project = Path(council["project"])
    missing = sorted({member["provider"] for member in council["members"] if not has_consent(member["provider"], project)})
    if missing:
        raise CouncilError(
            "provider consent missing for this project: "
            + ", ".join(missing)
            + "; use provider-consent only after explicit captain approval"
        )
    round_id = next_round_id(council)
    round_directory = directory / "rounds" / round_id
    if round_directory.exists():
        shutil.rmtree(round_directory)
    remove_snapshot(directory, round_id)
    round_directory.mkdir(parents=True, mode=0o700)
    try:
        snapshot, view_hash, excluded = build_snapshot(directory, project, round_id)
        common = (
            f"# Council round {round_id}\n\n"
            f"Project view: `{snapshot}`\n\n"
            f"View hash: `{view_hash}`\n\n"
            f"## Task\n\n{task}\n\n"
            f"## Accepted project decisions\n\n{accepted_context(council)}\n\n"
            "Analyze independently. Do not inspect other participants, terminal-control state, or any source path outside the fixed project view. "
            "Do not edit or implement the source project. Give a concise, project-grounded answer.\n"
        )
        common_path = round_directory / "common.md"
        atomic_text(common_path, common)
        common_hash = hashlib.sha256(common.encode()).hexdigest()
        roster: dict[str, Any] = {}
        round_value = {
            "schema": "fm-council-round.v1",
            "id": round_id,
            "status": "dispatching",
            "task": task,
            "view": str(snapshot),
            "view_hash": view_hash,
            "common_hash": common_hash,
            "excluded": excluded,
            "roster": roster,
            "created_at": now(),
        }
        save_round(directory, round_value)
        council["phase"] = "collecting"
        council["active_round"] = round_id
        save_council(directory, council)
    except Exception:
        council["round_counter"] = int(council["round_counter"]) - 1
        council["phase"] = "idle"
        council["active_round"] = None
        shutil.rmtree(round_directory, ignore_errors=True)
        remove_snapshot(directory, round_id)
        raise
    append_event(directory / "events.jsonl", {"event": "round_started", "round": round_id, "common_hash": common_hash})

    for member in council["members"]:
        try:
            if not catch_up_member(directory, council, member):
                roster[member["id"]] = {"dispatch": "unavailable", "answer": None}
                continue
            runtime_file, runtime = load_runtime(council, member)
            outbox = Path(runtime["home"]) / "outbox"
            outbox.mkdir(parents=True, exist_ok=True, mode=0o700)
            answer_path = outbox / f"{round_id}.md"
            nonce = secrets.token_hex(16)
            envelope = {
                "schema": "fm-council-envelope.v1",
                "council_id": council["id"],
                "round_id": round_id,
                "member_id": member["id"],
                "common_hash": common_hash,
                "view_hash": view_hash,
                "answer_path": str(answer_path),
                "nonce": nonce,
            }
            envelope_path = Path(runtime["home"]) / "inbox" / f"{round_id}.json"
            atomic_json(envelope_path, envelope)
            if send_member(council, member, "round", common, answer_path=answer_path, common_path=common_path):
                roster[member["id"]] = {"dispatch": "sent", "answer": str(answer_path), "nonce": nonce}
                runtime["active_round"] = round_id
                update_runtime(runtime_file, runtime)
            else:
                roster[member["id"]] = {"dispatch": "unavailable", "answer": None}
        except CouncilError:
            roster[member["id"]] = {"dispatch": "unavailable", "answer": None}
    round_value["status"] = "collecting"
    save_round(directory, round_value)
    append_event(
        directory / "events.jsonl",
        {
            "event": "round_dispatched",
            "round": round_id,
            "available": [member for member, value in roster.items() if value["dispatch"] == "sent"],
            "unavailable": [member for member, value in roster.items() if value["dispatch"] != "sent"],
        },
    )
    return round_value


def command_ask(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock", blocking=False):
        council = reload_open_council(directory)
        round_value = start_round(directory, council, arguments.task)
    print(json.dumps({"council": council["name"], "round": round_value["id"], "common_hash": round_value["common_hash"], "view_hash": round_value["view_hash"], "roster": round_value["roster"]}, ensure_ascii=False))


def command_submit(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock"):
        council = reload_open_council(directory)
        if council.get("active_round") != arguments.round_id or council.get("phase") != "collecting":
            raise CouncilError("submission does not match the active collecting round")
        round_value = load_round(directory, arguments.round_id)
        roster = round_value.get("roster", {})
        member_value = roster.get(arguments.member)
        member_record = next((item for item in council["members"] if item["id"] == arguments.member), None)
        if not member_value or not member_record or member_value.get("dispatch") != "sent" or member_value.get("nonce") != arguments.nonce:
            raise CouncilError("submission identity or nonce does not match the frozen round roster")
        destination = Path(member_value["answer"])
        _, runtime = load_runtime(council, member_record)
        if destination != expected_answer_path(runtime, arguments.round_id):
            raise CouncilError("submission destination escaped the member's recorded outbox")
        if destination.exists() or destination.is_symlink():
            raise CouncilError("participant already submitted an answer for this round")
        source = Path(arguments.file)
        content = source.read_bytes()
        if not content.strip():
            raise CouncilError("participant answer is empty")
        directory_fd = open_outbox_dir(Path(str(runtime["home"])))
        if directory_fd is None:
            raise CouncilError("participant outbox is not a private directory")
        os.close(directory_fd)
        atomic_bytes(destination, content)
    print(f"submitted: {arguments.member} {arguments.round_id}")


def readiness(directory: Path, council: dict[str, Any]) -> dict[str, Any]:
    if council.get("phase") != "collecting" or not council.get("active_round"):
        raise CouncilError("council has no collecting round")
    round_value = load_round(directory, council["active_round"])
    answered: list[str] = []
    pending: list[str] = []
    unavailable: list[str] = []
    for member in council["members"]:
        roster_value = round_value.get("roster", {}).get(member["id"], {})
        answer_text = read_member_answer(council, member, round_value["id"], roster_value.get("answer"))
        if answer_text is not None and answer_text.strip():
            answered.append(member["id"])
        elif roster_value.get("dispatch") != "sent":
            unavailable.append(member["id"])
        else:
            try:
                state, _ = probe_member(council, member)
            except CouncilError:
                state = "unavailable"
            (pending if state == "available" else unavailable).append(member["id"])
    return {
        "council": council["id"],
        "round": round_value["id"],
        "ready": not pending,
        "answered": answered,
        "pending": pending,
        "unavailable": unavailable,
    }


def command_ready(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    print(json.dumps(readiness(directory, council), ensure_ascii=False))


def command_wait(arguments: argparse.Namespace) -> None:
    deadline = time.monotonic() + arguments.timeout
    while True:
        directory, council = find_council(arguments.name, include_closed=False)
        value = readiness(directory, council)
        if value["ready"] or time.monotonic() >= deadline:
            value["timed_out"] = not value["ready"]
            print(json.dumps(value, ensure_ascii=False))
            if value["timed_out"]:
                raise SystemExit(3)
            return
        time.sleep(arguments.poll)


def command_collect(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock"):
        council = reload_open_council(directory)
        if council.get("phase") != "collecting" or not council.get("active_round"):
            raise CouncilError("council has no collecting round")
        round_value = load_round(directory, council["active_round"])
        answers: list[dict[str, str]] = []
        unavailable: list[str] = []
        for member in council["members"]:
            roster_value = round_value["roster"].get(member["id"], {})
            answer_text = (read_member_answer(council, member, round_value["id"], roster_value.get("answer")) or "").strip()
            if answer_text:
                answers.append({"member": member["id"], "profile": f"{member['harness']}/{member['model']}/{member['effort']}", "answer": answer_text})
            else:
                unavailable.append(member["id"])
        if not answers:
            raise CouncilError("no participant answer is available; retry or wait rather than inventing a council result")
        collection = {
            "schema": "fm-council-collection.v1",
            "council": council["id"],
            "round": round_value["id"],
            "common_hash": round_value["common_hash"],
            "answers": answers,
            "unavailable": unavailable,
            "comparison": "only-available" if len(answers) == 1 else "compare-or-synthesize",
        }
        collection_path = PATHS.runtime_dir(council["id"]) / "rounds" / round_value["id"] / "collection.json"
        atomic_json(collection_path, collection)
        round_value["status"] = "awaiting_presentation"
        round_value["available_members"] = [answer["member"] for answer in answers]
        round_value["unavailable_members"] = unavailable
        save_round(directory, round_value)
        council["phase"] = "awaiting_presentation"
        save_council(directory, council)
        append_event(directory / "events.jsonl", {"event": "answers_collected", "round": round_value["id"], "available": round_value["available_members"], "unavailable": unavailable})
    print(json.dumps({"collection": str(collection_path), **collection}, ensure_ascii=False, indent=2))


def command_present(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock"):
        council = reload_open_council(directory)
        if council.get("phase") != "awaiting_presentation" or not council.get("active_round"):
            raise CouncilError("collect available answers before presenting a canonical decision")
        round_value = load_round(directory, council["active_round"])
        available = round_value.get("available_members", [])
        if len(available) == 1 and arguments.kind != "only":
            raise CouncilError("one available answer must be presented as the only available answer, never as a comparative winner or synthesis")
        if len(available) > 1 and arguments.kind == "only":
            raise CouncilError("--kind only is valid only when exactly one answer is available")
        source = Path(arguments.file)
        content = source.read_bytes()
        if not content.strip():
            raise CouncilError("presented canonical decision is empty")
        try:
            text = content.decode("utf-8")
        except UnicodeDecodeError as error:
            raise CouncilError("presented canonical decision must be valid UTF-8") from error
        presented = round_record_path(directory, round_value["id"]).parent / "presented.md"
        atomic_bytes(presented, content)
        round_value["status"] = "awaiting_acceptance"
        round_value["presentation_kind"] = arguments.kind
        round_value["presented_sha256"] = hashlib.sha256(content).hexdigest()
        save_round(directory, round_value)
        council["phase"] = "awaiting_acceptance"
        save_council(directory, council)
        append_event(directory / "events.jsonl", {"event": "canonical_presented", "round": round_value["id"], "sha256": round_value["presented_sha256"], "kind": arguments.kind})
    print(text, end="" if text.endswith("\n") else "\n")


def remove_snapshot(directory: Path, round_id: str) -> None:
    remove_readonly_tree(directory / "snapshots" / round_id)


def cleanup_round_payloads(directory: Path, council: dict[str, Any], round_value: dict[str, Any], keep_presentation: bool) -> None:
    members = {member["id"]: member for member in council["members"]}
    for member_id, roster_value in round_value.get("roster", {}).items():
        member = members.get(member_id)
        answer = roster_value.get("answer")
        if member and answer:
            remove_member_answer(council, member, round_value["id"], answer)
    runtime_round = PATHS.runtime_dir(council["id"]) / "rounds" / round_value["id"]
    shutil.rmtree(runtime_round, ignore_errors=True)
    if not keep_presentation:
        with contextlib.suppress(FileNotFoundError):
            (round_record_path(directory, round_value["id"]).parent / "presented.md").unlink()
    remove_snapshot(directory, round_value["id"])


def accept_round(directory: Path, council: dict[str, Any]) -> tuple[str, Path, list[str]]:
    if council.get("phase") != "awaiting_acceptance" or not council.get("active_round"):
        raise CouncilError("council has no presented canonical decision to accept")
    round_value = load_round(directory, council["active_round"])
    presented = round_record_path(directory, round_value["id"]).parent / "presented.md"
    content = presented.read_bytes()
    if hashlib.sha256(content).hexdigest() != round_value.get("presented_sha256"):
        raise CouncilError("presented canonical decision changed after presentation")
    project = Path(council["project"])
    decisions = project_decision_dir(project)
    decisions.mkdir(parents=True, exist_ok=True, mode=0o700)
    digest = hashlib.sha256(content).hexdigest()
    with lock(decisions / ".lock"):
        index = decision_index(project)
        existing = next(
            (
                item
                for item in index["decisions"]
                if item.get("council_id") == council["id"] and item.get("round_id") == round_value["id"]
            ),
            None,
        )
        if existing is not None:
            if existing.get("sha256") != digest:
                raise CouncilError(f"round {round_value['id']} already saved a different decision: {existing.get('id')}")
            decision_id = str(existing["id"])
            destination = decision_path(project, decision_id)
            if not destination.is_file():
                raise CouncilError(f"accepted decision body is missing: {destination}")
        else:
            sequence = len(index["decisions"]) + 1
            decision_id = f"D{sequence:04d}"
            destination = decision_path(project, decision_id)
            if destination.exists():
                raise CouncilError(f"decision destination already exists: {destination}")
            atomic_bytes(destination, content)
            index["decisions"].append(
                {
                    "id": decision_id,
                    "active": True,
                    "council_id": council["id"],
                    "round_id": round_value["id"],
                    "sha256": digest,
                    "accepted_at": now(),
                }
            )
            atomic_json(decisions / "index.json", index)
            append_event(directory / "events.jsonl", {"event": "decision_saved", "decision": decision_id, "round": round_value["id"], "sha256": digest})
    if decision_id not in council["decision_ids"]:
        council["decision_ids"].append(decision_id)
    deferred: list[str] = []
    body = content.decode()
    for member in council["members"]:
        delivered: list[str] = []
        try:
            runtime_file, runtime = load_runtime(council, member)
            delivered = list(runtime.get("delivered_decisions", []))
            sent = decision_id in delivered or send_member(council, member, "decision", body)
        except CouncilError:
            sent = False
        if sent:
            if decision_id not in delivered:
                delivered.append(decision_id)
            runtime["delivered_decisions"] = delivered
            runtime["active_round"] = None
            update_runtime(runtime_file, runtime)
            append_event(directory / "events.jsonl", {"event": "decision_delivered", "decision": decision_id, "member": member["id"]})
        else:
            deferred.append(member["id"])
            append_event(directory / "events.jsonl", {"event": "decision_delivery_deferred", "decision": decision_id, "member": member["id"]})
    round_value["status"] = "accepted"
    round_value["decision_id"] = decision_id
    save_round(directory, round_value)
    cleanup_round_payloads(directory, council, round_value, keep_presentation=True)
    council["phase"] = "idle"
    council["active_round"] = None
    save_council(directory, council)
    return decision_id, destination, deferred


def command_accept(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock"):
        council = reload_open_council(directory)
        decision_id, destination, deferred = accept_round(directory, council)
    result: dict[str, Any] = {"accepted": decision_id, "canonical": str(destination), "deferred_members": deferred}
    if arguments.implement:
        result["implementation"] = {
            "action": "create_separate_ordinary_implementation_task",
            "project_path": council["project"],
            "decision_id": decision_id,
            "decision_path": str(destination),
            "instruction": "Create a separate ordinary Firstmate implementation task from this accepted decision. Do not reuse council participants as implementers.",
        }
    print(json.dumps(result, ensure_ascii=False, indent=2))


def reject_active(directory: Path, council: dict[str, Any], reason: str) -> str:
    if council.get("phase") not in {"collecting", "awaiting_presentation", "awaiting_acceptance", "interrupted"} or not council.get("active_round"):
        raise CouncilError("council has no active round to reject")
    round_value = load_round(directory, council["active_round"])
    round_value["status"] = "rejected"
    round_value.pop("presented_sha256", None)
    round_value.pop("presentation_kind", None)
    round_value.pop("available_members", None)
    round_value.pop("unavailable_members", None)
    round_value["rejection_reason"] = reason
    cleanup_round_payloads(directory, council, round_value, keep_presentation=False)
    save_round(directory, round_value)
    round_id = round_value["id"]
    council["phase"] = "idle"
    council["active_round"] = None
    save_council(directory, council)
    append_event(directory / "events.jsonl", {"event": "round_rejected", "round": round_id, "reason": reason})
    return round_id


def command_reject(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock"):
        council = reload_open_council(directory)
        round_id = reject_active(directory, council, arguments.reason)
    print(f"rejected: {round_id}; no rejected result was retained")


def command_rerun(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock"):
        council = reload_open_council(directory)
        if not council.get("active_round"):
            raise CouncilError("council has no active round to rerun")
        old = load_round(directory, council["active_round"])
        task = old["task"]
        if arguments.clarify:
            task = f"{task}\n\nClarified constraint: {arguments.clarify.strip()}"
        rejected = reject_active(directory, council, "rerun with clarified constraints")
        round_value = start_round(directory, council, task)
    print(json.dumps({"rejected": rejected, "rerun": round_value["id"], "task": task}, ensure_ascii=False))


def command_recover(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock"):
        council = reload_open_council(directory)
        if council.get("phase") != "collecting" or not council.get("active_round"):
            raise CouncilError("only an interrupted collecting round can be marked for explicit retry")
        round_value = load_round(directory, council["active_round"])
        round_value["status"] = "interrupted"
        save_round(directory, round_value)
        council["phase"] = "interrupted"
        save_council(directory, council)
        append_event(directory / "events.jsonl", {"event": "round_interrupted", "round": round_value["id"]})
    print(f"interrupted: {round_value['id']}; use retry explicitly")


def command_retry(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock"):
        council = reload_open_council(directory)
        if council.get("phase") != "interrupted" or not council.get("active_round"):
            raise CouncilError("council has no interrupted round to retry")
        old = load_round(directory, council["active_round"])
        task = old["task"]
        if arguments.clarify:
            task = f"{task}\n\nClarified constraint: {arguments.clarify.strip()}"
        rejected = reject_active(directory, council, "interrupted round retried explicitly")
        round_value = start_round(directory, council, task)
    print(json.dumps({"interrupted": rejected, "retry": round_value["id"], "task": task}, ensure_ascii=False))


def close_preflight(council: dict[str, Any], member: dict[str, Any]) -> dict[str, Any]:
    _, runtime = load_runtime(council, member)
    if runtime.get("council_id") != council["id"] or runtime.get("member_id") != member["id"]:
        raise CouncilError(f"participant identity mismatch for {member['id']}")
    if test_transport():
        value = run_transport(["probe", council["id"], member["id"], runtime["owner_token"], str(runtime_path(member))], expect_json=True)
        for field in ("session", "workspace_id", "tab_id", "pane_id", "owner_token"):
            if value.get(field) != runtime.get(field):
                raise CouncilError(f"participant endpoint identity mismatch for {member['id']}: {field}")
        return runtime
    pane_result = herdr_run(runtime["session"], ["pane", "get", runtime["pane_id"]], check=False)
    tab_result = herdr_run(runtime["session"], ["tab", "get", runtime["tab_id"]], check=False)
    if pane_result.returncode != 0 or tab_result.returncode != 0:
        raise CouncilError(f"cannot verify exact council-owned participant endpoint for {member['id']}")
    try:
        pane = json.loads(pane_result.stdout).get("result", {}).get("pane", {})
        tab = json.loads(tab_result.stdout).get("result", {}).get("tab", {})
    except json.JSONDecodeError as error:
        raise CouncilError(f"cannot parse endpoint identity for {member['id']}") from error
    if pane.get("pane_id") != runtime["pane_id"] or pane.get("tab_id") != runtime["tab_id"] or pane.get("workspace_id") != runtime["workspace_id"]:
        raise CouncilError(f"exact pane identity changed for {member['id']}")
    if tab.get("tab_id") != runtime["tab_id"] or tab.get("workspace_id") != runtime["workspace_id"] or tab.get("label") != runtime["machine_label"]:
        raise CouncilError(f"exact tab ownership changed for {member['id']}")
    return runtime


def close_member(council: dict[str, Any], member: dict[str, Any], runtime: dict[str, Any]) -> None:
    if test_transport():
        run_transport(["close", council["id"], member["id"], runtime["owner_token"], str(runtime_path(member))])
    else:
        result = herdr_run(runtime["session"], ["pane", "close", runtime["pane_id"]], check=False)
        if result.returncode != 0:
            raise CouncilError(f"failed to close exact participant endpoint for {member['id']}")


def load_close_journal(directory: Path, council: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    path = directory / "close-journal.json"
    if not path.exists():
        return path, {"schema": "fm-council-close.v1", "council_id": council["id"], "closed": {}}
    journal = load_json(path)
    if (
        journal.get("schema") != "fm-council-close.v1"
        or journal.get("council_id") != council["id"]
        or not isinstance(journal.get("closed"), dict)
    ):
        raise CouncilError(f"invalid council close journal: {path}")
    return path, journal


def command_close(arguments: argparse.Namespace) -> None:
    directory, council = find_council(arguments.name, include_closed=False)
    with lock(PATHS.runtime_dir(council["id"]) / ".lock"):
        council = reload_open_council(directory)
        journal_path, journal = load_close_journal(directory, council)
        pending = [member for member in council["members"] if member["id"] not in journal["closed"]]
        runtimes = [(member, close_preflight(council, member)) for member in pending]
        for member, runtime in runtimes:
            close_member(council, member, runtime)
            journal["closed"][member["id"]] = now()
            atomic_json(journal_path, journal)
            append_event(directory / "events.jsonl", {"event": "member_closed", "member": member["id"]})
        runtime_root = PATHS.runtime_dir(council["id"])
        shutil.rmtree(runtime_root / "members", ignore_errors=True)
        shutil.rmtree(runtime_root / "rounds", ignore_errors=True)
        council["status"] = "closed"
        council["phase"] = "closed"
        council["active_round"] = None
        council["closed_at"] = now()
        for member in council["members"]:
            member.pop("runtime", None)
        save_council(directory, council)
        append_event(directory / "events.jsonl", {"event": "council_closed"})
    print(f"closed: {council['name']}; participant conversations were cleared")


def command_status(arguments: argparse.Namespace) -> None:
    if arguments.name:
        _, council = find_council(arguments.name)
        output = [council]
    else:
        output = []
        for path in sorted(PATHS.councils.glob("*/council.json")):
            try:
                output.append(read_council_record(path))
            except CouncilError as error:
                output.append({"id": path.parent.name, "status": "unreadable", "error": str(error)})
    print(json.dumps(output, ensure_ascii=False, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command")
    parser.add_argument("rest", nargs=argparse.REMAINDER)
    return parser


def command_parser(command: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=f"fm-council.sh {command}")
    if command == "create":
        parser.add_argument("name")
        parser.add_argument("--project", required=True)
        parser.add_argument("--participant", action="append", required=True)
        parser.add_argument("--clean-slate", action="store_true")
        parser.add_argument("--herdr-session")
    elif command == "provider-consent":
        parser.add_argument("provider")
        parser.add_argument("--project", required=True)
        parser.add_argument("--acknowledge-project-disclosure", action="store_true")
    elif command == "ask":
        parser.add_argument("name")
        parser.add_argument("task")
    elif command == "submit":
        parser.add_argument("name")
        parser.add_argument("member")
        parser.add_argument("--round", dest="round_id", required=True)
        parser.add_argument("--nonce", required=True)
        parser.add_argument("--file", required=True)
    elif command in {"ready", "collect"}:
        parser.add_argument("name")
    elif command == "wait":
        parser.add_argument("name")
        parser.add_argument("--timeout", type=int, default=900)
        parser.add_argument("--poll", type=float, default=2.0)
    elif command == "present":
        parser.add_argument("name")
        parser.add_argument("--file", required=True)
        parser.add_argument("--kind", choices=("best", "synthesis", "only"), required=True)
    elif command in {"accept", "accept-and-implement"}:
        parser.add_argument("name")
        parser.set_defaults(implement=command == "accept-and-implement")
    elif command == "reject":
        parser.add_argument("name")
        parser.add_argument("--reason", default="explicitly rejected")
    elif command in {"rerun", "retry"}:
        parser.add_argument("name")
        parser.add_argument("--clarify")
    elif command in {"recover", "close"}:
        parser.add_argument("name")
    elif command == "status":
        parser.add_argument("name", nargs="?")
    else:
        raise CouncilError(f"unknown command: {command}; run fm-council.sh --help")
    return parser


def main() -> int:
    top = build_parser()
    arguments = top.parse_args()
    parsed = command_parser(arguments.command).parse_args(arguments.rest)
    commands = {
        "create": command_create,
        "provider-consent": command_consent,
        "ask": command_ask,
        "submit": command_submit,
        "ready": command_ready,
        "wait": command_wait,
        "collect": command_collect,
        "present": command_present,
        "accept": command_accept,
        "accept-and-implement": command_accept,
        "reject": command_reject,
        "rerun": command_rerun,
        "recover": command_recover,
        "retry": command_retry,
        "close": command_close,
        "status": command_status,
    }
    commands[arguments.command](parsed)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CouncilError as error:
        print(f"fm-council: {error}", file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("fm-council: interrupted", file=sys.stderr)
        raise SystemExit(130)
