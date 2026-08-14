#!/usr/bin/env python3
"""Queue and drive exact-head no-mistakes runs on isolated Azure cells.

This host controller never executes a repository validation command. It may use
Git to bind and bundle a clean exact head, Azure CLI to create/control private
capacity, and storage data-plane calls to exchange digest-bound protocol files.
The durable contract is documented in docs/azure-validation.md.
"""

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "docs" / "azure-validation" / "cell.json"
GUEST = ROOT / "bin" / "fm-azure-validation-guest.sh"
SHARD_BRIDGE = ROOT / "bin" / "fm-azure-validation-shard-bridge.py"
CONTAINER = "validation-shards"
SCHEMA = "fm.azure-validation/v1"
RESULT_SCHEMA = "fm.azure-validation-result/v1"
LEASE_SCHEMA = "fm.azure-credential-lease/v1"
RUNTIME_SCHEMA = "fm.azure-validation-runtime/v1"
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
SAFE_CELL = re.compile(r"^azv-[a-z0-9]{12}$")
HEX_OBJECT = re.compile(r"^[0-9a-f]{40,64}$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
RESOURCE_ID = re.compile(r"^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/disks/[^/]+$", re.I)
PR_URL = re.compile(r"^https://github\.com/[^/]+/[^/]+/pull/[1-9][0-9]*$")
NM_RUN_ID = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")
RUNNER_INVOCATION = re.compile(r"^azr-[a-z0-9]{12}(?:-a[2-9][0-9]*)?$")
LOCAL_TIMEOUT = 300
REGIONAL_ADMISSION_CEILING_VCPUS = 128
BUDGET_TARGET_USD = 1000.0
BUDGET_CEILING_USD = 1500.0
MAX_CELL_LIFETIME_HOURS = 24
FOUNDATION_METER_RESERVE_USD = 210.0
VALIDATION_METER_RESERVE_USD = 80.0
BLOB_DATA_CONTRIBUTOR_ROLE = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"

# Control cells use the allocator's reviewed eight-vCPU control lane inside
# the same unrestricted v6 families as the fleet; the old v5 candidates are
# NotAvailableForSubscription in East US and their family collides with the
# pilot supervisor. Live SKU, capability, and retail evidence is re-read
# before every allocation; family and regional capacity are adjudicated only
# by the shared allocator's atomic shape admission.
VALIDATION_SKUS = (
    "Standard_D8as_v6",
    "Standard_D8s_v6",
    "Standard_D8ads_v6",
    "Standard_D8ds_v6",
)

RESOURCE_CLASSES = {
    "validation-heavy": {
        "vcpus": 8,
        "memory_gib": 32,
        "memory_max_bytes": 28 * 1024**3,
        "tasks_max": 8192,
        "worktree_gib": 256,
        "wall_seconds": 6 * 3600,
        "behavior_shards": 8,
    },
    "validation-standard": {
        "vcpus": 8,
        "memory_gib": 32,
        "memory_max_bytes": 24 * 1024**3,
        "tasks_max": 4096,
        "worktree_gib": 192,
        "wall_seconds": 3 * 3600,
        "behavior_shards": 4,
    },
}

FORBIDDEN_LEASE_KEYS = {
    "token", "secret", "password", "private_key", "access_token",
    "refresh_token", "credential", "cookie", "authorization",
}
FORBIDDEN_RUNTIME_NAMES = {
    ".claude", ".config/gh", ".credentials.json", "auth.json", "hosts.yml",
    "credentials", "token", "secret", "keychain", "cookies",
}
RESOURCE_API = {
    "vm": "2024-03-01",
    "nic": "2023-09-01",
    "disk": "2023-10-02",
    "run-command": "2024-03-01",
    "identity": "2023-01-31",
    "ttl-schedule": "2018-09-15",
    "container": "2023-05-01",
}
RUNNER_SHARD_SKUS = (
    "Standard_D4as_v6", "Standard_D4as_v7", "Standard_D4s_v6",
    "Standard_D4ads_v7", "Standard_D4ds_v6", "Standard_D4s_v7",
    "Standard_D4ds_v7", "Standard_D4ads_v6",
)


class ValidationError(RuntimeError):
    pass


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_bytes(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                return "sha256:" + digest.hexdigest()
            digest.update(block)


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(value=None):
    value = value or now_utc()
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_utc(value, label):
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        raise ValidationError("{} must be an exact UTC timestamp".format(label))


def run(command, cwd=None, check=True, capture=True, timeout=LOCAL_TIMEOUT, env=None):
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            env=env,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise ValidationError("bounded command timed out after {} seconds: {}".format(timeout, command[0]))
    if check and result.returncode != 0:
        detail = (result.stderr or "").strip()
        raise ValidationError("command failed ({}): {}{}".format(
            result.returncode,
            " ".join(command),
            ": " + detail if detail else "",
        ))
    return result


def git(repo, *args, check=True):
    return run(["git", "-C", str(repo)] + list(args), check=check)


def require_id(label, value):
    if not value or not SAFE_ID.match(value):
        raise ValidationError("{} must use 1-64 bounded identifier characters".format(label))
    return value


def require_cell(value):
    if not value or not SAFE_CELL.match(value):
        raise ValidationError("validation cell id is malformed")
    return value


def require_sha256(label, value):
    if not isinstance(value, str) or not SHA256.match(value):
        raise ValidationError("{} is not a SHA-256 identity".format(label))
    return value


def environment(require_cloud=False):
    home_value = os.environ.get("FM_HOME")
    if not home_value:
        raise ValidationError("FM_HOME is required")
    home = Path(home_value).resolve()
    state_dir = Path(os.environ.get(
        "FM_AZURE_VALIDATION_STATE_DIR", str(home / "state" / "azure-validation")
    )).resolve()
    if "FM_AZURE_VALIDATION_RESERVED_VCPUS" in os.environ:
        raise ValidationError(
            "FM_AZURE_VALIDATION_RESERVED_VCPUS is obsolete; author and review demand share the fixed East US 128-vCPU admission ceiling"
        )
    env = {
        "home": home,
        "home_binding": sha256_bytes(str(home).encode("utf-8")),
        "state_dir": state_dir,
        "queue_limit": bounded_int("FM_AZURE_VALIDATION_QUEUE_LIMIT", 128, 1, 1000),
        "max_active": bounded_int("FM_AZURE_VALIDATION_MAX_ACTIVE", 8, 1, 8),
        "budget_limit": bounded_float(
            "FM_AZURE_VALIDATION_BUDGET_LIMIT_USD", BUDGET_TARGET_USD,
            BUDGET_TARGET_USD, BUDGET_CEILING_USD,
        ),
    }
    if not require_cloud:
        return env
    required = (
        "FM_AZURE_TENANT_ID", "FM_AZURE_SUBSCRIPTION_ID", "FM_AZURE_NAMING_PREFIX",
        "FM_AZURE_STORAGE_NAME", "FM_AZURE_DEPLOYMENT_GENERATION",
        "FM_AZURE_OWNER_TAG", "FM_AZURE_RUNNER_OPERATOR_OBJECT_ID",
    )
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise ValidationError("required Azure environment is missing: " + ", ".join(missing))
    tenant = os.environ["FM_AZURE_TENANT_ID"]
    subscription = os.environ["FM_AZURE_SUBSCRIPTION_ID"]
    if not UUID.match(tenant) or not UUID.match(subscription):
        raise ValidationError("tenant and subscription must be exact UUIDs")
    if not UUID.match(os.environ["FM_AZURE_RUNNER_OPERATOR_OBJECT_ID"]):
        raise ValidationError("runner operator object id must be an exact UUID")
    prefix = os.environ["FM_AZURE_NAMING_PREFIX"]
    storage = os.environ["FM_AZURE_STORAGE_NAME"]
    if not re.match(r"^[a-z0-9]{3,12}$", prefix):
        raise ValidationError("FM_AZURE_NAMING_PREFIX must be 3-12 lowercase alphanumeric characters")
    if not re.match(r"^[a-z0-9]{3,24}$", storage):
        raise ValidationError("FM_AZURE_STORAGE_NAME is malformed")
    env.update({
        "tenant": tenant,
        "subscription": subscription,
        "prefix": prefix,
        "storage": storage,
        "operator_data_plane_ip": os.environ.get("FM_AZURE_OPERATOR_DATA_PLANE_IP", ""),
        "deployment_generation": require_id(
            "deployment generation", os.environ["FM_AZURE_DEPLOYMENT_GENERATION"]
        ),
        "resource_group": os.environ.get(
            "FM_AZURE_RESOURCE_GROUP", "rg-firstmate-pilot-eastus-001"
        ),
        "operator_object_id": os.environ["FM_AZURE_RUNNER_OPERATOR_OBJECT_ID"],
        "owner": require_id("Azure cleanup owner", os.environ["FM_AZURE_OWNER_TAG"]),
        "vnet": "vnet-{}-eus".format(prefix),
        "subnet": "snet-validation",
    })
    return env


def bounded_int(name, default, minimum, maximum):
    value = os.environ.get(name, str(default))
    try:
        parsed = int(value)
    except ValueError:
        raise ValidationError("{} must be an integer".format(name))
    if not minimum <= parsed <= maximum:
        raise ValidationError("{} must be between {} and {}".format(name, minimum, maximum))
    return parsed


def bounded_float(name, default, minimum, maximum):
    value = os.environ.get(name, str(default))
    try:
        parsed = float(value)
    except ValueError:
        raise ValidationError("{} must be numeric".format(name))
    if not minimum <= parsed <= maximum:
        raise ValidationError("{} must be between {} and {}".format(name, minimum, maximum))
    return parsed


def ensure_dirs(env):
    for path in (
        env["state_dir"], env["state_dir"] / "payloads", env["state_dir"] / "results"
    ):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path, 0o700)


@contextlib.contextmanager
def lock(env, name="queue"):
    ensure_dirs(env)
    path = env["state_dir"] / ("." + name + ".lock")
    with open(path, "a+", encoding="utf-8") as handle:
        os.chmod(path, 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def state_path(env, cell):
    return env["state_dir"] / (require_cell(cell) + ".json")


def save_state(env, state, create=False):
    path = state_path(env, state["cell"])
    if create and path.exists():
        raise ValidationError("validation cell state already exists")
    state["updated_at"] = iso_utc()
    temp = path.with_name(".{}.{}.tmp".format(path.name, uuid.uuid4().hex))
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if create and path.exists():
            raise ValidationError("validation cell state already exists")
        os.replace(str(temp), str(path))
        directory_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp.unlink()


def load_state(env, cell):
    path = state_path(env, cell)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ValidationError("unknown validation cell: {}".format(cell))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("validation state is unreadable: {}".format(exc))
    if value.get("schema") != SCHEMA or value.get("cell") != cell:
        raise ValidationError("validation state identity is corrupt")
    return value


def transition(env, state, phase, note="", **updates):
    state.update(updates)
    state["phase"] = phase
    state.setdefault("events", []).append({"at": iso_utc(), "phase": phase, "note": note})
    save_state(env, state)


def new_cell():
    return "azv-" + uuid.uuid4().hex[:12]


def count_queued(env):
    ensure_dirs(env)
    count = 0
    for path in env["state_dir"].glob("azv-*.json"):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            if json.loads(path.read_text(encoding="utf-8")).get("phase") == "queued":
                count += 1
    return count


def reject_secret_keys(value, path="lease"):
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = str(key).lower().replace("-", "_")
            if normalized in FORBIDDEN_LEASE_KEYS:
                raise ValidationError("credential lease descriptor contains forbidden secret field: {}.{}".format(path, key))
            reject_secret_keys(child, path + "." + str(key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_secret_keys(child, "{}[{}]".format(path, index))


def load_credential_lease(path, task, generation, repo_slug):
    source_arg = Path(path)
    source = source_arg.resolve()
    try:
        if source_arg.is_symlink() or not source.is_file():
            raise ValidationError("credential lease descriptor must be a regular non-link file")
        mode = source.stat().st_mode & 0o777
        value = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("credential lease descriptor is unreadable: {}".format(exc))
    reject_secret_keys(value)
    if not isinstance(value, dict) or set(value) != {
        "schema", "lease_id", "task", "task_generation", "provider",
        "provider_account_binding", "disk_content_binding", "disk", "paths",
        "github_authority", "expires_at",
    }:
        raise ValidationError("credential lease descriptor field inventory is not exact")
    if mode & 0o077:
        raise ValidationError("credential lease descriptor must not be group/world accessible")
    expected = {
        "schema": LEASE_SCHEMA,
        "task": task,
        "task_generation": generation,
    }
    for key, wanted in expected.items():
        if value.get(key) != wanted:
            raise ValidationError("credential lease descriptor {} does not match the run".format(key))
    require_id("credential lease id", value.get("lease_id"))
    require_sha256("provider account binding", value.get("provider_account_binding"))
    require_sha256("credential disk content binding", value.get("disk_content_binding"))
    disk = value.get("disk") or {}
    if not isinstance(disk, dict) or set(disk) != {"id", "etag", "luks_uuid", "zone"}:
        raise ValidationError("credential lease disk field inventory is not exact")
    if not RESOURCE_ID.match(str(disk.get("id", ""))):
        raise ValidationError("credential lease disk id is malformed")
    if not disk.get("etag") or not UUID.match(str(disk.get("luks_uuid", ""))):
        raise ValidationError("credential lease disk immutable/LUKS identity is incomplete")
    if str(disk.get("zone")) not in ("1", "2", "3"):
        raise ValidationError("credential lease disk zone must be 1, 2, or 3")
    github = value.get("github_authority") or {}
    if not isinstance(github, dict) or set(github) != {"kind", "repository", "permissions"}:
        raise ValidationError("GitHub authority field inventory is not exact")
    if github.get("repository") != repo_slug:
        raise ValidationError("GitHub authority is not scoped to the exact repository")
    permissions = set(github.get("permissions") or [])
    # GitHub's fine-grained token UI no longer offers a Checks permission;
    # actions:read plus statuses:read is its exact successor for reading CI
    # results. Either the historical triple or the successor quad is an
    # acceptable minimal declaration; nothing broader is.
    exact_permission_sets = (
        {"contents:write", "pull_requests:write", "checks:read"},
        {"contents:write", "pull_requests:write", "actions:read", "statuses:read"},
    )
    if permissions not in exact_permission_sets:
        raise ValidationError(
            "GitHub authority must declare only contents:write, pull_requests:write, "
            "and either checks:read or actions:read plus statuses:read"
        )
    if github.get("kind") not in ("fine-grained-token", "github-app-installation"):
        raise ValidationError("GitHub authority must be a fine-grained token or installation lease")
    expires = parse_utc(value.get("expires_at"), "credential lease expiry")
    if expires <= now_utc() + dt.timedelta(hours=1):
        raise ValidationError("credential lease expires too soon for admission")
    provider = value.get("provider")
    if provider not in ("claude", "codex", "pi", "opencode", "grok"):
        raise ValidationError("credential lease provider is not a verified Firstmate adapter")
    paths = value.get("paths") or {}
    if not isinstance(paths, dict) or set(paths) != {"provider_home", "account_binding", "github_token"}:
        raise ValidationError("credential lease path field inventory is not exact")
    for key in ("provider_home", "account_binding", "github_token"):
        relative = paths.get(key)
        if not isinstance(relative, str) or not relative or relative.startswith("/") or ".." in relative.split("/"):
            raise ValidationError("credential lease {} must be a bounded disk-relative path".format(key))
    if len(set(paths.values())) != len(paths):
        raise ValidationError("provider, account-binding, and GitHub lease paths must remain distinct")
    provider_prefix = paths["provider_home"].rstrip("/") + "/"
    if not paths["account_binding"].startswith(provider_prefix):
        raise ValidationError("provider account-binding marker must live inside the exact provider home")
    return value, sha256_file(source)


def validate_runtime_bundle(path, provider):
    source = Path(path).resolve()
    if not source.is_file() or source.is_symlink():
        raise ValidationError("runtime bundle must be a regular file")
    if source.stat().st_size > 1024**3:
        raise ValidationError("runtime bundle exceeds the one-GiB bound")
    try:
        with tarfile.open(source, "r:gz") as archive:
            members = archive.getmembers()
            names = [member.name for member in members]
            if len(members) > 10000 or sum(member.size for member in members) > 2 * 1024**3:
                raise ValidationError("runtime bundle exceeds the bounded member/decompressed inventory")
            if names.count("runtime.json") != 1 or len(names) != len(set(names)):
                raise ValidationError("runtime bundle has no unique runtime.json/member inventory")
            for member in members:
                lowered = member.name.lower().strip("./")
                parts = set(lowered.split("/"))
                if member.issym() or member.islnk() or member.isdev() or member.name.startswith("/") or ".." in member.name.split("/"):
                    raise ValidationError("runtime bundle contains an unsafe member")
                if parts.intersection(FORBIDDEN_RUNTIME_NAMES) or lowered.startswith(".config/gh/"):
                    raise ValidationError("runtime bundle contains a credential-like path: {}".format(member.name))
                if member.size > 512 * 1024**2:
                    raise ValidationError("runtime bundle member exceeds 512 MiB")
            manifest_handle = archive.extractfile("runtime.json")
            if manifest_handle is None:
                raise ValidationError("runtime manifest is not a regular file")
            manifest = json.loads(manifest_handle.read().decode("utf-8"))
    except (tarfile.TarError, OSError, json.JSONDecodeError) as exc:
        raise ValidationError("runtime bundle is unreadable: {}".format(exc))
    if manifest.get("schema") != RUNTIME_SCHEMA or manifest.get("provider") != provider:
        raise ValidationError("runtime manifest schema/provider does not match the credential lease")
    if not re.match(r"^v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$", str(manifest.get("no_mistakes_version", ""))):
        raise ValidationError("runtime manifest has no exact no-mistakes version")
    declared = manifest.get("files")
    if not isinstance(declared, list) or not declared:
        raise ValidationError("runtime manifest file inventory is empty")
    declared_paths = set()
    records_by_path = {}
    for record in declared:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise ValidationError("runtime manifest file record is malformed")
        relative = record["path"]
        if (
            not relative or relative.startswith("/") or ".." in relative.split("/")
            or relative in declared_paths
        ):
            raise ValidationError("runtime manifest file path is unsafe or duplicated")
        require_sha256("runtime file digest", record.get("digest"))
        declared_paths.add(relative)
        records_by_path[relative] = record
    archive_files = {member.name: member for member in members if member.isfile() and member.name != "runtime.json"}
    if set(archive_files) != declared_paths:
        raise ValidationError("runtime manifest does not exactly inventory the bundle")
    with tarfile.open(source, "r:gz") as archive:
        for relative, record in records_by_path.items():
            handle = archive.extractfile(relative)
            if handle is None:
                raise ValidationError("runtime manifest member is not a regular file")
            digest = hashlib.sha256()
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
            if "sha256:" + digest.hexdigest() != record["digest"]:
                raise ValidationError("runtime bundle file digest mismatch: {}".format(relative))
    required_executables = {
        "no_mistakes_path": "no-mistakes",
        "provider_path": provider,
        "gh_path": "gh",
        "gh_axi_path": "gh-axi",
    }
    for field, basename in required_executables.items():
        relative = manifest.get(field)
        member = archive_files.get(relative)
        if (
            not isinstance(relative, str)
            or Path(relative).name != basename
            or member is None
            or member.mode & 0o111 == 0
        ):
            raise ValidationError("runtime {} exact executable is absent or not executable".format(field))
    return manifest, sha256_file(source)


def repository_identity(repo):
    repo = Path(repo).resolve()
    top = Path(git(repo, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
    dirty = git(top, "status", "--porcelain", "--untracked-files=all").stdout
    if dirty:
        raise ValidationError("repository must be a clean exact committed snapshot")
    branch_result = git(top, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    if branch_result.returncode != 0:
        raise ValidationError("repository must be on a named branch")
    branch = branch_result.stdout.strip()
    head = git(top, "rev-parse", "HEAD").stdout.strip()
    tree = git(top, "rev-parse", "HEAD^{tree}").stdout.strip()
    if not HEX_OBJECT.match(head) or not HEX_OBJECT.match(tree):
        raise ValidationError("repository head/tree identity is malformed")
    origin = git(top, "remote", "get-url", "origin").stdout.strip()
    slug_match = re.search(r"github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$", origin)
    if not slug_match:
        raise ValidationError("origin must be an exact GitHub repository")
    repo_slug = "{}/{}".format(slug_match.group(1), slug_match.group(2))
    remote = git(top, "ls-remote", "--heads", "origin", "refs/heads/" + branch).stdout.split()
    if len(remote) != 2 or remote[1] != "refs/heads/" + branch or remote[0] != head:
        raise ValidationError("named branch is not pushed at the exact submitted head")
    return top, branch, head, tree, repo_slug


def project_resource_class(env, repo_slug, requested):
    path = env["home"] / "config" / "azure-validation-classes.json"
    if not path.exists():
        selected = requested or "validation-heavy"
        if selected not in RESOURCE_CLASSES:
            raise ValidationError("unknown validation resource class")
        return selected
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("per-project validation class policy is unreadable: {}".format(exc))
    if value.get("schema") != "fm.azure-validation-classes/v1":
        raise ValidationError("per-project validation class policy schema is invalid")
    default = value.get("default", "validation-heavy")
    projects = value.get("projects", {})
    if default not in RESOURCE_CLASSES or not isinstance(projects, dict):
        raise ValidationError("per-project validation class policy is malformed")
    unknown = [name for name in projects.values() if name not in RESOURCE_CLASSES]
    if unknown:
        raise ValidationError("per-project validation class policy names an unknown class")
    selected = projects.get(repo_slug, default)
    if requested and requested != selected:
        raise ValidationError("requested validation class differs from the exact project policy")
    return selected


def prepare_payload(env, state, runtime_source):
    payload = env["state_dir"] / "payloads" / state["cell"]
    if payload.exists():
        raise ValidationError("cell payload already exists")
    payload.mkdir(parents=True, mode=0o700)
    os.chmod(payload, 0o700)
    bundle = payload / "snapshot.bundle"
    git(state["repository_root"], "bundle", "create", str(bundle), "HEAD")
    run(["git", "bundle", "verify", str(bundle)])
    if bundle.stat().st_size > 1024**3:
        raise ValidationError("repository bundle exceeds one GiB")
    state["request"]["repository"]["snapshot_digest"] = sha256_file(bundle)
    state["request"]["repository"]["snapshot_bytes"] = bundle.stat().st_size
    runtime_copy = payload / "runtime.tar.gz"
    shutil.copyfile(str(runtime_source), str(runtime_copy))
    request_unsigned = dict(state["request"])
    request_unsigned.pop("request_digest", None)
    state["request_digest"] = sha256_bytes(canonical_bytes(request_unsigned))
    state["request"]["request_digest"] = state["request_digest"]
    request_path = payload / "request.json"
    request_path.write_bytes(canonical_bytes(state["request"]) + b"\n")
    for source, destination in ((GUEST, payload / "guest.sh"), (SHARD_BRIDGE, payload / "shard-bridge.py")):
        shutil.copyfile(str(source), str(destination))
    input_path = payload / "input.tar.gz"
    sources = (
        (request_path, "request.json"),
        (bundle, "snapshot.bundle"),
        (runtime_copy, "runtime.tar.gz"),
        (payload / "shard-bridge.py", "shard-bridge.py"),
    )
    with tarfile.open(input_path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for source, name in sources:
            info = archive.gettarinfo(str(source), arcname=name)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            with open(source, "rb") as handle:
                archive.addfile(info, handle)
    state["input_path"] = str(input_path)
    state["input_digest"] = sha256_file(input_path)
    state["input_bytes"] = input_path.stat().st_size
    return state


def submit(env, args):
    with lock(env):
        if count_queued(env) >= env["queue_limit"]:
            raise ValidationError("validation queue depth limit reached; no compute was created")
        repo, branch, head, tree, repo_slug = repository_identity(args.repo or os.getcwd())
        task = require_id("task", args.task)
        generation = require_id("task generation", args.task_generation)
        validation_generation = require_id("validation generation", args.validation_generation)
        deployment_generation = require_id(
            "deployment generation", os.environ.get("FM_AZURE_DEPLOYMENT_GENERATION")
        )
        resource_class = project_resource_class(env, repo_slug, args.resource_class)
        try:
            intent = Path(args.intent_file).read_text(encoding="utf-8")
        except OSError as exc:
            raise ValidationError("intent file is unreadable: {}".format(exc))
        if not intent.strip() or len(intent.encode("utf-8")) > 64 * 1024:
            raise ValidationError("intent must contain 1-65536 bytes")
        lease, lease_digest = load_credential_lease(
            args.credential_lease, task, generation, repo_slug
        )
        runtime, runtime_digest = validate_runtime_bundle(args.runtime_bundle, lease["provider"])
        cell = new_cell()
        token = cell.split("-", 1)[1]
        resources = resource_names(env, token, lease)
        shard_container = "fmval" + token
        fence = sha256_bytes(os.urandom(32))
        limits = dict(RESOURCE_CLASSES[resource_class])
        limits["reserved_vcpus"] = limits["vcpus"] + limits["behavior_shards"] * 4
        request = {
            "schema": SCHEMA,
            "cell": cell,
            "home_binding": env["home_binding"],
            "task": task,
            "task_generation": generation,
            "validation_generation": validation_generation,
            "deployment_generation": deployment_generation,
            "fence": fence,
            "intent": intent,
            "resource_bindings": {
                "vm_id": resources["vm_id"],
                "worktree_disk_id": resources["worktree_disk_id"],
                "credential_disk_id": resources["credential_disk_id"],
                "identity_id": resources["identity_id"],
                "shard_container": shard_container,
            },
            "repository": {
                "slug": repo_slug,
                "branch": branch,
                "head": head,
                "tree": tree,
                "snapshot_digest": None,
                "snapshot_bytes": None,
            },
            "credential_lease": lease,
            "credential_lease_digest": lease_digest,
            "runtime": runtime,
            "runtime_digest": runtime_digest,
            "resource_class": resource_class,
            "limits": limits,
            "protocol": {
                "guest_digest": sha256_file(GUEST),
                "shard_bridge_digest": sha256_file(SHARD_BRIDGE),
                "result_schema": RESULT_SCHEMA,
            },
            "created_at": iso_utc(),
        }
        staging_prefix = "validation-cells/{}/{}/{}/{}/{}".format(
            env["home_binding"].split(":", 1)[1][:16], task, generation,
            validation_generation, cell,
        )
        state = {
            "schema": SCHEMA,
            "cell": cell,
            "phase": "preparing",
            "created_at": iso_utc(),
            "repository_root": str(repo),
            "request": request,
            "attempt": 1,
            "staging": {
                "container": shard_container,
                "input_blob": "control/input.tar.gz",
                "result_blob": "control/result.tar.gz",
                "evidence_prefix": "control/evidence",
                "admission_container": CONTAINER,
                "admission_blob": "validation-cells/admission.lock",
                "lineage_prefix": staging_prefix,
            },
            "resources": resources,
            "events": [{"at": iso_utc(), "phase": "preparing", "note": "queue identity reserved"}],
        }
        ensure_dirs(env)
        save_state(env, state, create=True)
        try:
            prepare_payload(env, state, Path(args.runtime_bundle).resolve())
            transition(env, state, "queued", "exact pushed head queued without local validation execution")
        except Exception:
            with contextlib.suppress(OSError):
                state_path(env, cell).unlink()
            shutil.rmtree(env["state_dir"] / "payloads" / cell, ignore_errors=True)
            raise
    print("AZURE VALIDATION QUEUED cell={} task={} head={} class={} shards={}".format(
        cell, task, head, resource_class, limits["behavior_shards"]
    ))


def resource_names(env, token, lease):
    prefix = os.environ.get("FM_AZURE_NAMING_PREFIX", "")
    sub = os.environ.get("FM_AZURE_SUBSCRIPTION_ID", "")
    group = os.environ.get("FM_AZURE_RESOURCE_GROUP", "rg-firstmate-pilot-eastus-001")
    if not re.match(r"^[a-z0-9]{3,12}$", prefix) or not UUID.match(sub):
        raise ValidationError("submit requires exact naming-prefix and subscription identity without contacting Azure")
    if not re.match(r"^[A-Za-z0-9._()\-]{1,90}$", group):
        raise ValidationError("Azure resource group name is malformed")
    base = "/subscriptions/{}/resourceGroups/{}/providers".format(sub, group)
    vm = "vm-{}-val-{}".format(prefix, token)
    nic = "nic-{}-val-{}".format(prefix, token)
    os_disk = "disk-{}-val-{}-os".format(prefix, token)
    worktree = "disk-{}-val-{}-work".format(prefix, token)
    identity = "id-{}-val-{}".format(prefix, token)
    return {
        "deployment": "fm-val-{}".format(token),
        "vm_name": vm,
        "nic_name": nic,
        "os_disk_name": os_disk,
        "worktree_disk_name": worktree,
        "credential_disk_id": lease["disk"]["id"],
        "identity_name": identity,
        "identity_id": base + "/Microsoft.ManagedIdentity/userAssignedIdentities/" + identity,
        "vm_id": base + "/Microsoft.Compute/virtualMachines/" + vm,
        "nic_id": base + "/Microsoft.Network/networkInterfaces/" + nic,
        "os_disk_id": base + "/Microsoft.Compute/disks/" + os_disk,
        "worktree_disk_id": base + "/Microsoft.Compute/disks/" + worktree,
        "run_command_name": "validate-a1",
        "run_commands": [],
        "safety_run_command_id": base + "/Microsoft.Compute/virtualMachines/{}/runCommands/safety-shutdown".format(vm),
        "ttl_schedule_name": "shutdown-computevm-{}".format(vm),
        "ttl_schedule_id": base + "/Microsoft.DevTestLab/schedules/shutdown-computevm-{}".format(vm),
        "identities": {},
    }


def az_command(env, args, check=True, parse_json=True, timeout=LOCAL_TIMEOUT):
    command = [os.environ.get("FM_AZURE_CLI", "az")] + list(args)
    command += ["--subscription", env["subscription"], "--only-show-errors"]
    if parse_json and "--output" not in command and "-o" not in command:
        command += ["--output", "json"]
    result = run(command, check=check, timeout=timeout)
    if not parse_json:
        return result.stdout.strip(), result.returncode, (result.stderr or "").strip()
    if result.returncode != 0:
        return None, result.returncode, (result.stderr or "").strip()
    try:
        return json.loads(result.stdout or "null"), result.returncode, (result.stderr or "").strip()
    except json.JSONDecodeError as exc:
        raise ValidationError("Azure CLI returned malformed JSON: {}".format(exc))


def write_private_json(env, prefix, value):
    ensure_dirs(env)
    fd, name = tempfile.mkstemp(prefix=prefix, suffix=".json", dir=str(env["state_dir"]))
    os.chmod(name, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
    return Path(name)


def scope_gate(env):
    account, _, _ = az_command(env, ["account", "show"])
    if (
        account.get("id") != env["subscription"]
        or account.get("tenantId") != env["tenant"]
        or account.get("state") != "Enabled"
    ):
        raise ValidationError("selected Azure tenant/subscription is not the exact enabled scope")


def foundation_gate(env):
    # The released runner owns the exact private-foundation contract: the
    # complete 29-resource inventory, controller-UAMI classification, private
    # endpoints, DNS, NAT, NSGs, and zero-RBAC reservation identities. The
    # validation dispatcher consumes that released proof instead of keeping a
    # partial parallel one, then re-proves only its own cell subnet below.
    runner = runner_module()
    try:
        runner_env = runner.environment()
        runner.scope_gate(runner_env)
        runner.foundation_gate(runner_env)
    except runner.RunnerError as exc:
        raise ValidationError("released foundation contract refused: {}".format(exc))
    storage, _, _ = az_command(env, [
        "storage", "account", "show", "--resource-group", env["resource_group"],
        "--name", env["storage"],
    ])
    tags = storage.get("tags") or {}
    network = storage.get("networkRuleSet") or storage.get("networkAcls") or {}
    if (
        storage.get("location") != "eastus"
        or storage.get("kind") != "StorageV2"
        or (storage.get("sku") or {}).get("name") != "Standard_ZRS"
        or not runner.storage_network_access_is_exact(
            storage, env["operator_data_plane_ip"], "ipAddressOrRange"
        )
        or storage.get("allowSharedKeyAccess") is not False
        or storage.get("allowBlobPublicAccess") is not False
        or storage.get("defaultToOAuthAuthentication") is not True
        or storage.get("minimumTlsVersion") != "TLS1_2"
        or network.get("defaultAction") != "Deny"
        or network.get("bypass") != "None"
        or tags.get("workload") != "firstmate"
        or tags.get("cleanup-owner") != env["owner"]
        or tags.get("deployment-generation") != env["deployment_generation"]
    ):
        raise ValidationError("foundation storage/private identity is not exact")
    vnet, _, _ = az_command(env, [
        "network", "vnet", "show", "--resource-group", env["resource_group"],
        "--name", env["vnet"],
    ])
    vnet_tags = vnet.get("tags") or {}
    if (
        vnet.get("location") != "eastus"
        or (vnet.get("addressSpace") or {}).get("addressPrefixes") != ["10.42.0.0/16"]
        or vnet_tags.get("workload") != "firstmate"
        or vnet_tags.get("cleanup-owner") != env["owner"]
        or vnet_tags.get("deployment-generation") != env["deployment_generation"]
    ):
        raise ValidationError("foundation VNet owner/generation/address identity is not exact")
    matches = [item for item in vnet.get("subnets", []) if item.get("name") == env["subnet"]]
    if len(matches) != 1:
        raise ValidationError("private validation-cell subnet is absent or ambiguous")
    subnet = matches[0]
    nsg = str((subnet.get("networkSecurityGroup") or {}).get("id", "")).lower()
    nat = str((subnet.get("natGateway") or {}).get("id", "")).lower()
    if (
        subnet.get("addressPrefix") != "10.42.4.0/24"
        or not nsg.endswith("/nsg-{}-elastic-isolated".format(env["prefix"]).lower())
        or not nat.endswith("/nat-{}-eus".format(env["prefix"]).lower())
        or subnet.get("privateEndpointNetworkPolicies") != "Enabled"
    ):
        raise ValidationError("validation-cell subnet private NSG/NAT/address contract is not exact")




def sku_candidates(env, required_vcpus, required_memory):
    """Select a reviewed, live-capable control SKU.

    Selection proves only existence, restriction-freedom, capability, zonal
    coverage, and rate; every capacity and family-headroom decision belongs to
    the released shared allocator's atomic shape admission.
    """
    skus, _, _ = az_command(env, [
        "vm", "list-skus", "--location", "eastus", "--resource-type", "virtualMachines", "--all",
    ])
    candidates = []
    by_name = {item.get("name"): item for item in skus}
    requested = os.environ.get("FM_AZURE_VALIDATION_SKU")
    names = (requested,) if requested else VALIDATION_SKUS
    for name in names:
        if name not in VALIDATION_SKUS:
            raise ValidationError("validation SKU is outside the reviewed 8-vCPU/32-GiB allowlist")
        item = by_name.get(name)
        if not item or item.get("restrictions"):
            continue
        capabilities = {entry.get("name"): entry.get("value") for entry in item.get("capabilities", [])}
        family = str(item.get("family") or capabilities.get("Family") or "")
        if not family:
            continue
        try:
            vcpus = int(capabilities.get("vCPUsAvailable", capabilities.get("vCPUs", "0")))
            memory = float(capabilities.get("MemoryGB", "0"))
        except ValueError:
            continue
        zones = set(item.get("locationInfo", [{}])[0].get("zones", []))
        if (
            vcpus != required_vcpus or memory < required_memory
            or capabilities.get("CpuArchitectureType") != "x64"
            or "V2" not in str(capabilities.get("HyperVGenerations", ""))
            or capabilities.get("TrustedLaunchDisabled") == "True"
            or capabilities.get("EncryptionAtHostSupported") != "True"
            or not {"1", "2", "3"}.issubset(zones)
        ):
            continue
        rate = retail_rate(env, name)
        candidates.append({"sku": name, "family": family, "vcpus": vcpus, "memory_gib": memory, "rate": rate})
    if not candidates:
        raise ValidationError("no reviewed validation control SKU is live, unrestricted, and capability-complete")
    return sorted(candidates, key=lambda item: (item["rate"], item["sku"]))


_RUNNER_MODULE = None


def runner_module():
    global _RUNNER_MODULE
    if _RUNNER_MODULE is None:
        spec = importlib.util.spec_from_file_location(
            "azure_runner_module", str(ROOT / "bin" / "fm-azure-runner.py")
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _RUNNER_MODULE = module
    return _RUNNER_MODULE


def lifecycle_command(env, arguments):
    command_env = os.environ.copy()
    command_env["FM_HOME"] = str(ROOT)
    executable = os.environ.get(
        "FM_AZURE_VALIDATION_LIFECYCLE", str(ROOT / "bin" / "fm-worker-lifecycle.sh")
    )
    result = run([executable] + arguments, check=False, env=command_env)
    return result


def compose_shard_plan(selected_family, shards, rate_lookup):
    """Compose the exact shard constituents beside one selected control family.

    Pure beside the injected rate lookup: shards avoid the control family so
    the complete shape fits exact 10-vCPU families, ids are distinct so child
    runners re-admit their own constituent, and every amount is a cushioned
    worst-case bound at or above the child's exact first-day cost.
    """
    runner = runner_module()
    shard_skus = [
        sku for sku in RUNNER_SHARD_SKUS
        if runner.SKU_FAMILY[sku].lower() != str(selected_family).lower()
    ]
    if not shard_skus:
        raise ValidationError("no reviewed shard family remains beside the selected control family")
    plan = []
    for shard in range(1, int(shards) + 1):
        sku = shard_skus[(shard - 1) % len(shard_skus)]
        plan.append({
            "shard": shard,
            "invocation": "azr-" + uuid.uuid4().hex[:12],
            "sku": sku,
            "sku_family": runner.SKU_FAMILY[sku],
            "amount_usd": round(float(rate_lookup(sku)) * 24.0 * 1.5 + 5.0, 6),
        })
    return plan


def shared_shape_reserve(env, state, selected):
    """Atomically reserve the complete control-plus-shards specialized shape.

    The released whole-fleet allocator is the single capacity authority: the
    complete maximum shape (one reviewed eight-vCPU control cell plus one
    four-vCPU constituent per behavior shard) is admitted all-or-nothing with
    exact constituent SKU, family, vCPU, and cushioned worst-case cost
    identities. Child runners later re-admit their exact pre-reserved
    constituent ids idempotently, so live shards are never double-counted.
    """
    request = state["request"]
    limits = request["limits"]
    fence = request["fence"].split(":", 1)[-1]
    shards = int(limits["behavior_shards"])
    runner = runner_module()
    admission = state.get("admission") or {}
    shard_plan = admission.get("shard_plan")
    if not shard_plan:
        shard_plan = compose_shard_plan(
            selected["family"], shards, lambda sku: retail_rate(env, sku)
        )
    control_amount = round(selected["rate"] * 24.0 * 1.5 + 5.0, 6)
    arguments = [
        "capacity-reserve-shape",
        "--shape-id", state["cell"],
        "--fence-binding", fence,
        "--confirm-subscription", env["subscription"],
        "--constituent",
        "reservation-id={},role=validation,sku={},sku-family={},vcpus=8,amount-usd={}".format(
            state["cell"], selected["sku"], selected["family"], control_amount
        ),
    ]
    for entry in shard_plan:
        arguments += [
            "--constituent",
            "reservation-id={},role=validation,sku={},sku-family={},vcpus=4,amount-usd={}".format(
                entry["invocation"], entry["sku"], entry["sku_family"], entry["amount_usd"]
            ),
        ]
    result = lifecycle_command(env, arguments)
    if result.returncode != 0:
        raise ValidationError("shared allocator shape reservation failed: {}".format(
            (result.stderr or result.stdout or "").strip()[-500:]
        ))
    try:
        shape = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError):
        raise ValidationError("shared allocator returned a malformed shape reservation")
    if shape.get("shape_id") != state["cell"] or shape.get("status") not in ("reserved", "queued"):
        raise ValidationError("shared allocator returned a shape with the wrong identity")
    shape["shard_plan"] = shard_plan
    shape["control_amount_usd"] = control_amount
    return shape


def release_shape_constituent(env, state, reservation_id, evidence):
    receipt = hashlib.sha256(json.dumps(
        {"cell": state["cell"], "reservation": reservation_id, "evidence": evidence},
        sort_keys=True, separators=(",", ":"),
    ).encode()).hexdigest()
    result = lifecycle_command(env, [
        "capacity-release",
        "--reservation-id", reservation_id,
        "--fence-binding", state["request"]["fence"].split(":", 1)[-1],
        "--cleanup-receipt", receipt,
        "--confirm-subscription", env["subscription"],
    ])
    if result.returncode != 0:
        raise ValidationError("shared capacity release refused for {}: {}".format(
            reservation_id, (result.stderr or result.stdout or "").strip()[-400:]
        ))


def retail_rate(env, sku):
    escaped = sku.replace("_", "%5F")
    url = (
        "https://prices.azure.com/api/retail/prices?%24filter="
        "armRegionName%20eq%20%27eastus%27%20and%20armSkuName%20eq%20%27{}%27%20and%20priceType%20eq%20%27Consumption%27"
    ).format(escaped)
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "firstmate-azure-validation/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        raise ValidationError("Azure retail rate request failed with HTTP {}".format(exc.code))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise ValidationError("Azure retail rate request is unreadable: {}".format(exc))
    rates = []
    for item in result.get("Items", []):
        product = str(item.get("productName", "")).lower()
        meter = str(item.get("meterName", "")).lower()
        if item.get("unitOfMeasure") == "1 Hour" and "windows" not in product and "spot" not in meter:
            with contextlib.suppress(TypeError, ValueError):
                rates.append(float(item["retailPrice"]))
    if not rates:
        raise ValidationError("current retail rate is unreadable for {}".format(sku))
    return min(rates)






def ensure_secret_file(name):
    value = os.environ.get(name)
    if not value:
        raise ValidationError("{} must name an owner-only key file for billable dispatch".format(name))
    path = Path(value).resolve()
    try:
        mode = path.stat().st_mode & 0o777
        data = path.read_bytes()
    except OSError as exc:
        raise ValidationError("{} is unreadable: {}".format(name, exc))
    if mode & 0o077 or len(data) < 32 or len(data) > 4096:
        raise ValidationError("{} must be owner-only and contain 32-4096 bytes".format(name))
    return path, data


def storage_upload(env, path, blob, overwrite=False, container=CONTAINER):
    az_command(env, [
        "storage", "blob", "upload", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", container, "--name", blob, "--file", str(path),
        "--overwrite", "true" if overwrite else "false",
    ])


def storage_upload_after_role(env, path, blob, container):
    last = ""
    for _ in range(12):
        _, rc, stderr = az_command(env, [
            "storage", "blob", "upload", "--auth-mode", "login", "--account-name", env["storage"],
            "--container-name", container, "--name", blob, "--file", str(path), "--overwrite", "false",
        ], check=False)
        if rc == 0:
            return
        last = stderr
        time.sleep(5)
    raise ValidationError("cell-container data role did not converge within one minute: {}".format(last))


def storage_download(env, blob, path, container=CONTAINER):
    az_command(env, [
        "storage", "blob", "download", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", container, "--name", blob, "--file", str(path), "--overwrite", "true",
    ])


def storage_bytes_upload(env, data, blob, container):
    path = write_private_json(env, ".blob-bytes-", {"placeholder": True})
    try:
        path.write_bytes(data)
        os.chmod(path, 0o600)
        storage_upload(env, path, blob, overwrite=True, container=container)
    finally:
        path.unlink(missing_ok=True)


def blob_sas(env, blob, permissions, hours=MAX_CELL_LIFETIME_HOURS, container=CONTAINER):
    expiry = iso_utc(now_utc() + dt.timedelta(hours=hours))
    stdout, rc, stderr = az_command(env, [
        "storage", "blob", "generate-sas", "--as-user", "--auth-mode", "login", "--https-only",
        "--account-name", env["storage"], "--container-name", container, "--name", blob,
        "--permissions", permissions, "--expiry", expiry, "--full-uri", "--output", "tsv",
    ], parse_json=False)
    if rc != 0 or not stdout.startswith("https://"):
        raise ValidationError("exact-object SAS creation failed: {}".format(stderr))
    return stdout


class CloudAdmissionLease:
    def __init__(self, env, state):
        self.env = env
        self.state = state
        self.lease_id = str(uuid.uuid4())
        self.failed = threading.Event()
        self.stop = threading.Event()
        self.thread = None
        self.expiry_lock = threading.Lock()
        self.expires_at = 0.0

    def lease_args(self, action):
        args = [
            "storage", "blob", "lease", action, "--auth-mode", "login",
            "--account-name", self.env["storage"], "--container-name", CONTAINER,
            "--blob-name", self.state["staging"]["admission_blob"],
        ]
        if action == "acquire":
            args += ["--lease-duration", "60", "--proposed-lease-id", self.lease_id]
        else:
            args += ["--lease-id", self.lease_id]
        return args

    def __enter__(self):
        empty = self.env["state_dir"] / ".validation-admission-empty"
        empty.touch(mode=0o600, exist_ok=True)
        _, rc, _ = az_command(self.env, [
            "storage", "blob", "upload", "--auth-mode", "login", "--account-name", self.env["storage"],
            "--container-name", CONTAINER, "--name", self.state["staging"]["admission_blob"],
            "--file", str(empty), "--overwrite", "false",
        ], check=False)
        if rc != 0:
            exists, _, _ = az_command(self.env, [
                "storage", "blob", "exists", "--auth-mode", "login", "--account-name", self.env["storage"],
                "--container-name", CONTAINER, "--name", self.state["staging"]["admission_blob"],
            ])
            if not exists.get("exists"):
                raise ValidationError("global validation admission lock could not be created or proven")
        for _ in range(7):
            _, rc, _ = az_command(
                self.env, self.lease_args("acquire"), check=False, timeout=10
            )
            if rc == 0:
                with self.expiry_lock:
                    self.expires_at = time.monotonic() + 60
                break
            time.sleep(10)
        else:
            raise ValidationError("global validation admission lock is busy or unreachable")
        self.thread = threading.Thread(target=self.renew, daemon=True)
        self.thread.start()
        return self

    def renew_once(self):
        try:
            _, rc, _ = az_command(
                self.env, self.lease_args("renew"), check=False, timeout=10
            )
            if rc != 0:
                raise ValidationError("global validation admission renewal was refused")
            with self.expiry_lock:
                self.expires_at = time.monotonic() + 60
        except Exception:
            self.failed.set()
            raise

    def renew(self):
        while not self.stop.wait(25):
            try:
                self.renew_once()
            except Exception:
                return

    def assert_held(self):
        with self.expiry_lock:
            safely_live = time.monotonic() < self.expires_at - 15
        if self.failed.is_set() or not safely_live:
            self.failed.set()
            raise ValidationError("global validation admission lease was lost before cell start")

    def renew_and_assert(self):
        if self.failed.is_set():
            self.assert_held()
        self.renew_once()
        self.assert_held()

    def __exit__(self, exc_type, exc, traceback):
        self.stop.set()
        if self.thread:
            self.thread.join(timeout=2)
        az_command(self.env, self.lease_args("release"), check=False, timeout=10)


def read_resource(env, resource_id, kind):
    url = "https://management.azure.com{}?api-version={}".format(resource_id, RESOURCE_API[kind])
    result, rc, stderr = az_command(env, ["rest", "--method", "get", "--url", url], check=False)
    if rc == 0:
        return True, result
    listing, list_rc, list_stderr = az_command(env, ["resource", "list", "--resource-group", env["resource_group"]], check=False)
    if list_rc != 0:
        raise ValidationError("{} absence is ambiguous: {}; {}".format(kind, stderr, list_stderr))
    if any(str(item.get("id", "")).lower() == resource_id.lower() for item in listing):
        raise ValidationError("{} exists but immutable identity is unreadable".format(kind))
    return False, None


def immutable_identity(resource, kind):
    properties = resource.get("properties", resource)
    identity = {"id": str(resource.get("id", "")).lower(), "etag": resource.get("etag") or properties.get("etag")}
    if kind == "vm":
        identity["instance_id"] = properties.get("vmId") or resource.get("vmId")
    elif kind == "nic":
        identity["resource_guid"] = properties.get("resourceGuid")
    elif kind == "disk":
        identity["unique_id"] = properties.get("uniqueId")
    elif kind == "identity":
        identity["client_id"] = properties.get("clientId")
        identity["principal_id"] = properties.get("principalId")
    stable_keys = {
        "vm": ("instance_id",),
        "nic": ("resource_guid",),
        "disk": ("unique_id",),
        "identity": ("client_id", "principal_id"),
        "run-command": (),
        "ttl-schedule": (),
    }
    if (
        not identity["id"]
        or not identity["etag"]
        or any(not identity.get(key) for key in stable_keys.get(kind, ()))
    ):
        raise ValidationError("{} immutable identity is incomplete".format(kind))
    return identity


def same_stable_identity(recorded, live, kind):
    keys = {
        "vm": ("id", "instance_id"),
        "nic": ("id", "resource_guid"),
        "disk": ("id", "unique_id"),
        "identity": ("id", "client_id", "principal_id"),
        "run-command": ("id",),
        "ttl-schedule": ("id",),
    }.get(kind, ("id",))
    return bool(recorded) and all(
        recorded.get(key) and recorded.get(key) == live.get(key) for key in keys
    )


def expected_tags(state, selected):
    request = state["request"]
    return {
        "workload": "firstmate",
        "firstmate-role": "validation-cell",
        "lifecycle": "elastic-scale-to-zero",
        "deployment-generation": request["deployment_generation"],
        "cleanup-owner": selected["owner"],
        "home-binding": request["home_binding"],
        "task-binding": request["task"],
        "task-generation": request["task_generation"],
        "validation-generation": request["validation_generation"],
        "validation-cell": state["cell"],
        "fence": request["fence"],
        "branch-binding": sha256_bytes(request["repository"]["branch"].encode("utf-8")),
        "head-binding": request["repository"]["head"],
        "worktree-binding": sha256_bytes(state["resources"]["worktree_disk_id"].encode("utf-8")),
        "credential-lease": request["credential_lease"]["lease_id"],
        "resource-class": request["resource_class"],
        "selected-sku": selected["sku"],
        "sku-family": selected["family"],
        "reserved-vcpus": str(request["limits"]["reserved_vcpus"]),
        "behavior-shards": str(request["limits"]["behavior_shards"]),
        "cost-attribution": "validation-review",
    }


def deployment_parameters(env, state, selected, replacement=False):
    resources = state["resources"]
    request = state["request"]
    subnet_id = "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Network/virtualNetworks/{}/subnets/{}".format(
        env["subscription"], env["resource_group"], env["vnet"], env["subnet"]
    )
    expiry_value = now_utc() + dt.timedelta(hours=MAX_CELL_LIFETIME_HOURS - 1)
    expiry = iso_utc(expiry_value)
    return {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "region": {"value": "eastus"},
            "zone": {"value": request["credential_lease"]["disk"]["zone"]},
            "vmName": {"value": resources["vm_name"]},
            "nicName": {"value": resources["nic_name"]},
            "osDiskName": {"value": resources["os_disk_name"]},
            "worktreeDiskName": {"value": resources["worktree_disk_name"]},
            "worktreeDiskId": {"value": resources["worktree_disk_id"]},
            "createWorktreeDisk": {"value": not replacement},
            "credentialDiskId": {"value": resources["credential_disk_id"]},
            "identityName": {"value": resources["identity_name"]},
            "storageAccountName": {"value": env["storage"]},
            "shardContainerName": {"value": state["staging"]["container"]},
            "runnerOperatorPrincipalId": {"value": env["operator_object_id"]},
            "subnetId": {"value": subnet_id},
            "vmSize": {"value": selected["sku"]},
            "worktreeDiskGiB": {"value": request["limits"]["worktree_gib"]},
            "expiryUtc": {"value": expiry},
            "expiryTimeOfDay": {"value": expiry_value.strftime("%H%M")},
            "tags": {"value": expected_tags(state, selected)},
        },
    }


def verify_credential_disk(env, state, allow_expected_vm=False):
    expected = state["request"]["credential_lease"]["disk"]
    expected_prefix = "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Compute/disks/".format(
        env["subscription"], env["resource_group"]
    )
    if not expected["id"].lower().startswith(expected_prefix.lower()):
        raise ValidationError("credential lease disk is outside the exact subscription/resource group")
    exists, disk = read_resource(env, expected["id"], "disk")
    if not exists:
        raise ValidationError("exact credential lease disk is absent")
    properties = disk.get("properties") or {}
    live_identity = disk.get("etag") or properties.get("etag") or properties.get("uniqueId")
    if live_identity != expected["etag"]:
        raise ValidationError("credential lease disk ETag changed")
    managed_by = disk.get("managedBy") or properties.get("managedBy")
    expected_vm = (state.get("resources") or {}).get("vm_id")
    if managed_by and not (
        allow_expected_vm and expected_vm and str(managed_by).lower() == str(expected_vm).lower()
    ):
        raise ValidationError("credential lease disk is already attached to another cell")
    tags = disk.get("tags") or {}
    if tags.get("credential-lease") != state["request"]["credential_lease"]["lease_id"]:
        raise ValidationError("credential disk tag does not match the exact lease")


def adopt_resources(env, state):
    resources = state["resources"]
    request = state["request"]
    identities = {}
    for kind, resource_id, identity_key in (
        ("vm", resources["vm_id"], "vm"),
        ("nic", resources["nic_id"], "nic"),
        ("disk", resources["os_disk_id"], "disk"),
        ("run-command", resources["safety_run_command_id"], "run-command-safety"),
        ("ttl-schedule", resources["ttl_schedule_id"], "ttl-schedule"),
    ):
        exists, resource = read_resource(env, resource_id, kind)
        if not exists:
            raise ValidationError("created {} disappeared before identity adoption".format(kind))
        tags = resource.get("tags") or {}
        if tags.get("validation-cell") != state["cell"] or tags.get("fence") != state["request"]["fence"]:
            raise ValidationError("created {} has foreign validation identity".format(kind))
        identities[identity_key] = immutable_identity(resource, kind)
    exists, identity_resource = read_resource(env, resources["identity_id"], "identity")
    if not exists:
        raise ValidationError("cell-scoped storage identity is absent after deployment")
    identity = immutable_identity(identity_resource, "identity")
    client_id = identity_resource.get("properties", {}).get("clientId") or identity_resource.get("clientId")
    principal_id = identity_resource.get("properties", {}).get("principalId") or identity_resource.get("principalId")
    if not UUID.match(str(client_id)) or not UUID.match(str(principal_id)):
        raise ValidationError("cell-scoped storage identity lacks immutable client/principal ids")
    container_scope = "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Storage/storageAccounts/{}/blobServices/default/containers/{}".format(
        env["subscription"], env["resource_group"], env["storage"], state["staging"]["container"]
    )
    assignments, _, _ = az_command(env, [
        "role", "assignment", "list", "--assignee-object-id", principal_id,
        "--all", "--include-inherited", "--include-groups",
    ])
    expected_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], BLOB_DATA_CONTRIBUTOR_ROLE
    )
    if (
        not isinstance(assignments, list) or len(assignments) != 1
        or str(assignments[0].get("principalId", "")).lower() != str(principal_id).lower()
        or str(assignments[0].get("scope", "")).lower() != container_scope.lower()
        or str(assignments[0].get("roleDefinitionId", "")).lower() != expected_role.lower()
    ):
        raise ValidationError("cell identity effective RBAC exceeds its exact private container")
    identities["identity"] = identity
    resources["identity_client_id"] = client_id
    resources["identity_principal_id"] = principal_id
    exists, worktree = read_resource(env, resources["worktree_disk_id"], "disk")
    if not exists:
        raise ValidationError("durable worktree disk is absent after deployment")
    tags = worktree.get("tags") or {}
    if tags.get("validation-cell") != state["cell"] or tags.get("fence") != state["request"]["fence"]:
        raise ValidationError("durable worktree disk identity is foreign")
    identities["worktree"] = immutable_identity(worktree, "disk")
    credential_exists, credential = read_resource(env, resources["credential_disk_id"], "disk")
    if not credential_exists:
        raise ValidationError("credential lease disk disappeared during cell creation")
    managed_by = credential.get("managedBy") or credential.get("properties", {}).get("managedBy")
    if str(managed_by or "").lower() != resources["vm_id"].lower():
        raise ValidationError("credential lease disk is not attached only to the exact cell VM")
    identities["credential"] = immutable_identity(credential, "disk")
    resources["identities"] = identities
    resources["vm_instance_id"] = identities["vm"]["instance_id"]
    save_state(env, state)


def create_cell(env, state, selected, replacement=False):
    params = write_private_json(env, ".cell-params-", deployment_parameters(env, state, selected, replacement))
    try:
        az_command(env, [
            "deployment", "group", "create", "--resource-group", env["resource_group"],
            "--name", state["resources"]["deployment"], "--template-file", str(TEMPLATE),
            "--parameters", "@" + str(params), "--mode", "Incremental",
        ])
    finally:
        params.unlink(missing_ok=True)
    adopt_resources(env, state)


def create_run_command(env, state, mode, input_url=None, output_url=None, response=None):
    resources = state["resources"]
    current_digest = sha256_file(GUEST)
    if current_digest != state["request"]["protocol"]["guest_digest"]:
        raise ValidationError("trusted guest changed after exact request preparation")
    attempt = state["attempt"]
    name = "{}-a{}".format(mode, attempt)
    run_id = resources["vm_id"] + "/runCommands/" + name
    arguments = [
        {"name": "mode", "value": mode},
        {"name": "input_digest", "value": state["input_digest"]},
        {"name": "request_digest", "value": state["request_digest"]},
        {"name": "cell", "value": state["cell"]},
        {"name": "attempt", "value": str(attempt)},
        {"name": "vm_resource_id", "value": resources["vm_id"]},
        {"name": "vm_instance_id", "value": resources["vm_instance_id"]},
        {"name": "worktree_disk_id", "value": resources["worktree_disk_id"]},
        {"name": "credential_disk_id", "value": resources["credential_disk_id"]},
        {"name": "storage_account", "value": env["storage"]},
        {"name": "storage_container", "value": state["staging"]["container"]},
        {"name": "identity_client_id", "value": resources["identity_client_id"]},
    ]
    protected = []
    if input_url:
        protected.append({"name": "input_url", "value": input_url})
    if output_url:
        protected.append({"name": "output_url", "value": output_url})
    if response is not None:
        protected.append({"name": "response", "value": response})
    for name in ("FM_AZURE_VALIDATION_WORKTREE_KEY_FILE", "FM_AZURE_VALIDATION_CREDENTIAL_KEY_FILE"):
        _, secret = ensure_secret_file(name)
        protected.append({"name": name.lower(), "value": secret.decode("utf-8").rstrip("\n")})
    selected = {
        "sku": state["allocation"]["sku"],
        "family": state["allocation"]["sku_family"],
        "owner": env["owner"],
    }
    run_tags = expected_tags(state, selected)
    run_tags["attempt"] = str(attempt)
    body_value = {
        "location": "eastus",
        "tags": run_tags,
        "properties": {
            "source": {"script": GUEST.read_text(encoding="utf-8")},
            "parameters": arguments,
            "protectedParameters": protected,
            "asyncExecution": True,
            "timeoutInSeconds": state["request"]["limits"]["wall_seconds"] + 1800,
            "treatFailureAsDeploymentFailure": False,
        },
    }
    body = write_private_json(env, ".cell-run-", body_value)
    try:
        az_command(env, [
            "rest", "--method", "put",
            "--url", "https://management.azure.com{}?api-version={}".format(run_id, RESOURCE_API["run-command"]),
            "--body", "@" + str(body),
        ])
    finally:
        body.unlink(missing_ok=True)
    exists, run_command = read_resource(env, run_id, "run-command")
    if not exists:
        raise ValidationError("created validation Run Command disappeared before identity adoption")
    tags = run_command.get("tags") or {}
    if tags.get("validation-cell") != state["cell"] or tags.get("fence") != state["request"]["fence"]:
        raise ValidationError("created validation Run Command has foreign identity")
    resources["run_command_name"] = name
    resources["run_command_id"] = run_id
    resources.setdefault("run_commands", []).append({
        "id": run_id,
        "identity": immutable_identity(run_command, "run-command"),
    })
    save_state(env, state)


def dispatch(env, args):
    if not args.confirm_dispatch or args.confirm_subscription != env["subscription"]:
        raise ValidationError("billable dispatch requires --confirm-dispatch and the exact subscription")
    with lock(env):
        candidates = []
        for path in env["state_dir"].glob("azv-*.json"):
            with contextlib.suppress(OSError, json.JSONDecodeError):
                value = json.loads(path.read_text(encoding="utf-8"))
                if value.get("phase") in ("queued", "starting"):
                    candidates.append(value)
        candidates.sort(key=lambda item: (
            0 if item.get("phase") == "starting" else 1,
            item.get("created_at", ""), item.get("cell", ""),
        ))
        if not candidates:
            print("AZURE VALIDATION QUEUE empty active=0")
            return
        state = candidates[0]
        if state["request"]["deployment_generation"] != env["deployment_generation"]:
            raise ValidationError("queued request deployment generation differs from the live foundation")
        live_resources = resource_names(
            env, state["cell"].split("-", 1)[1], state["request"]["credential_lease"]
        )
        expected_bindings = state["request"].get("resource_bindings") or {}
        actual_bindings = {
            "vm_id": live_resources["vm_id"],
            "worktree_disk_id": live_resources["worktree_disk_id"],
            "credential_disk_id": live_resources["credential_disk_id"],
            "identity_id": live_resources["identity_id"],
            "shard_container": state["staging"]["container"],
        }
        if expected_bindings != actual_bindings:
            raise ValidationError("queued run resource bindings differ from the exact live foundation scope")
        recovering = state["phase"] == "starting"
        if recovering:
            for key, value in live_resources.items():
                if key.endswith("_id") and state.get("resources", {}).get(key) != value:
                    raise ValidationError("starting cell resource bindings differ from its exact recorded identities")
        else:
            state["resources"] = live_resources
            save_state(env, state)
        scope_gate(env)
        foundation_gate(env)
        with CloudAdmissionLease(env, state) as admission_lease:
            foundation_gate(env)
            verify_credential_disk(env, state, allow_expected_vm=recovering)
            if recovering:
                allocation = state.get("allocation") or {}
                admission = state.get("admission") or {}
                selected = {
                    "sku": allocation.get("sku"),
                    "family": allocation.get("sku_family"),
                    "rate": admission.get("hourly_rate"),
                    "owner": env["owner"],
                }
                if (
                    selected["sku"] not in VALIDATION_SKUS
                    or not selected["family"] or not isinstance(selected["rate"], (int, float))
                    or admission.get("shape_id") != state["cell"]
                    or len(admission.get("shard_plan") or []) != state["request"]["limits"]["behavior_shards"]
                ):
                    raise ValidationError("starting cell lacks its exact allocation and shape reservation")
            else:
                limits = state["request"]["limits"]
                selected = sku_candidates(env, limits["vcpus"], limits["memory_gib"])[0]
                selected["owner"] = env["owner"]
                shape = shared_shape_reserve(env, state, selected)
                if shape["status"] != "reserved":
                    state.setdefault("admission", {})["shard_plan"] = shape["shard_plan"]
                    state["admission"]["last_refusal"] = {"at": iso_utc(), "reason": shape.get("reason", "")[:400]}
                    save_state(env, state)
                    print("AZURE VALIDATION QUEUED cell={} reason={}".format(state["cell"], shape.get("reason", "")))
                    return
                state["allocation"] = {"sku": selected["sku"], "sku_family": selected["family"]}
                state["admission"] = {
                    "at": iso_utc(), "sku": selected["sku"], "sku_family": selected["family"],
                    "hourly_rate": selected["rate"],
                    "actual_usd": shape.get("actual_usd"), "forecast_usd": shape.get("forecast_usd"),
                    "admission_limit_usd": shape.get("admission_limit_usd"),
                    "shape_id": state["cell"], "capacity_fence": state["request"]["fence"].split(":", 1)[-1],
                    "control_amount_usd": shape["control_amount_usd"],
                    "shard_plan": shape["shard_plan"],
                }
                transition(env, state, "starting", "shared allocator atomically reserved the complete specialized shape")
            admission_lease.renew_and_assert()
            create_cell(env, state, selected)
            admission_lease.assert_held()
        storage_upload_after_role(
            env, Path(state["input_path"]), state["staging"]["input_blob"],
            state["staging"]["container"],
        )
        input_url = blob_sas(
            env, state["staging"]["input_blob"], "r", container=state["staging"]["container"]
        )
        output_url = blob_sas(
            env, state["staging"]["result_blob"], "cw", container=state["staging"]["container"]
        )
        create_run_command(env, state, "start", input_url=input_url, output_url=output_url)
        transition(env, state, "running", "isolated per-run no-mistakes cell started", started_at=iso_utc())
    print("AZURE VALIDATION STARTED cell={} sku={} head={}".format(state["cell"], selected["sku"], state["request"]["repository"]["head"]))


def run_command_status(env, state):
    run_id = state["resources"].get("run_command_id")
    if not run_id:
        return "missing", None
    url = "https://management.azure.com{}?api-version={}&$expand=instanceView".format(run_id, RESOURCE_API["run-command"])
    value, rc, stderr = az_command(env, ["rest", "--method", "get", "--url", url], check=False)
    if rc != 0:
        return "unreadable", stderr
    properties = value.get("properties", {})
    view = properties.get("instanceView") or {}
    execution = str(view.get("executionState", "Unknown"))
    return execution, view


def observe(env, args):
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] not in ("running", "reattaching", "responding", "needs-decision"):
            print_status(state)
            return
        execution, view = run_command_status(env, state)
        if execution in ("Running", "Pending", "Unknown"):
            print("AZURE VALIDATION RUNNING cell={} head={} attempt={}".format(state["cell"], state["request"]["repository"]["head"], state["attempt"]))
            return
        if execution == "unreadable":
            raise ValidationError("cell status is unreadable; duplicate execution is forbidden: {}".format(view))
        if execution not in ("Succeeded", "Failed", "Canceled", "TimedOut"):
            print("AZURE VALIDATION RUNNING cell={} control_state={}".format(state["cell"], execution))
            return
        output = str((view or {}).get("output", ""))
        error = str((view or {}).get("error", ""))
        marker = re.search(r"FM_AZURE_VALIDATION_RESULT\s+(sha256:[0-9a-f]{64})\s+boot=([0-9a-f-]{36})\s+outcome=([a-z-]+)", output)
        if not marker:
            transition(env, state, "failed-retained", "cell ended without an authenticated result marker", control_error=error[-2000:])
            raise ValidationError("cell ended without an authenticated result; worktree and lease remain retained")
        state["expected_result_digest"] = marker.group(1)
        state["expected_boot_id"] = marker.group(2)
        outcome = marker.group(3)
        if outcome == "needs-decision":
            transition(env, state, "needs-decision", "no-mistakes ask-user gate owns the exact run")
        else:
            transition(env, state, "result-published", "cell published an exact identity-bound result", reported_outcome=outcome)
        print_status(state)


def safe_extract_result(archive_path, destination):
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        allowed = {"result.json", "run.log", "report.md", "evidence"}
        for member in members:
            name = member.name
            if name in allowed or name.startswith("evidence/"):
                pass
            else:
                raise ValidationError("result archive contains undeclared path: {}".format(name))
            if member.issym() or member.islnk() or member.isdev() or member.name.startswith("/") or ".." in member.name.split("/"):
                raise ValidationError("result archive contains unsafe member")
            target = (destination / name).resolve()
            if target != destination.resolve() and destination.resolve() not in target.parents:
                raise ValidationError("result archive escapes destination")
        archive.extractall(str(destination), members=members)


def verify_result_identity(state, result):
    expected = {
        "schema": RESULT_SCHEMA,
        "request_digest": state["request_digest"],
        "cell": state["cell"],
        "home_binding": state["request"]["home_binding"],
        "task": state["request"]["task"],
        "task_generation": state["request"]["task_generation"],
        "validation_generation": state["request"]["validation_generation"],
        "fence": state["request"]["fence"],
        "branch": state["request"]["repository"]["branch"],
        "submitted_head": state["request"]["repository"]["head"],
        "worktree_disk_id": state["resources"]["worktree_disk_id"],
        "credential_lease_id": state["request"]["credential_lease"]["lease_id"],
        "vm_resource_id": state["resources"]["vm_id"],
        "vm_instance_id": state["resources"]["vm_instance_id"],
        "boot_id": state.get("expected_boot_id"),
    }
    for key, wanted in expected.items():
        if result.get(key) != wanted:
            raise ValidationError("validation result identity mismatch: {}".format(key))
    worktree_luks_uuid = result.get("worktree_luks_uuid")
    if not isinstance(worktree_luks_uuid, str) or not UUID.match(worktree_luks_uuid):
        raise ValidationError("validation result worktree LUKS identity is malformed")
    if state.get("worktree_luks_uuid") and state["worktree_luks_uuid"] != worktree_luks_uuid:
        raise ValidationError("validation result worktree LUKS identity changed")
    head = result.get("current_head")
    tree = result.get("current_tree")
    if (
        not isinstance(head, str) or not HEX_OBJECT.match(head)
        or not isinstance(tree, str) or not HEX_OBJECT.match(tree)
    ):
        raise ValidationError("validation result current head/tree is malformed")
    run_id = result.get("run_id")
    if not isinstance(run_id, str) or not NM_RUN_ID.match(run_id):
        raise ValidationError("validation result lacks the exact no-mistakes run id")
    if result.get("outcome") in ("passed", "checks-passed"):
        expected_pr_prefix = "https://github.com/{}/pull/".format(state["request"]["repository"]["slug"])
        if (
            not result.get("checks_green")
            or not PR_URL.match(str(result.get("pr_url", "")))
            or not str(result.get("pr_url", "")).startswith(expected_pr_prefix)
        ):
            raise ValidationError("successful result lacks repository-scoped CI-green PR proof")
        if result.get("remote_head") != head:
            raise ValidationError("successful result is not current with the exact remote head")
        shard_receipts = result.get("behavior_shards")
        expected_shards = state["request"]["limits"]["behavior_shards"]
        if not isinstance(shard_receipts, list) or len(shard_receipts) != expected_shards:
            raise ValidationError("successful result lacks the complete behavior-shard receipt set")
        expected_indexes = set(range(1, expected_shards + 1))
        indexes = set()
        boots = set()
        machines = set()
        invocations = set()
        rounds = set()
        for item in shard_receipts:
            if not isinstance(item, dict):
                raise ValidationError("behavior shard receipt is malformed")
            if (
                item.get("kind") != "behavior"
                or item.get("shard_count") != expected_shards
                or item.get("head") != head
                or item.get("tree") != tree
                or not SHA256.match(str(item.get("request_digest", "")))
                or not SHA256.match(str(item.get("command_digest", "")))
                or not RUNNER_INVOCATION.match(str(item.get("invocation", "")))
                or not item.get("boot_id")
                or not item.get("vm_instance_id")
            ):
                raise ValidationError("behavior shard receipt identity is incomplete or stale")
            artifact = item.get("artifact")
            if (
                not isinstance(artifact, dict)
                or artifact.get("path") != "results/executed-{}.tsv".format(item.get("shard"))
                or not SHA256.match(str(artifact.get("digest", "")))
                or not isinstance(artifact.get("bytes"), int)
                or artifact.get("bytes") < 0
            ):
                raise ValidationError("behavior shard receipt artifact identity is invalid")
            indexes.add(item.get("shard"))
            boots.add(item["boot_id"])
            machines.add(item["vm_instance_id"])
            invocations.add(item["invocation"])
            rounds.add(item.get("round"))
        if (
            indexes != expected_indexes
            or len(boots) != expected_shards
            or len(machines) != expected_shards
            or len(invocations) != expected_shards
            or len(rounds) != 1
            or None in rounds
        ):
            raise ValidationError("behavior shards did not prove one complete round on independent Azure machines")
    return True


def collect(env, args):
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] not in ("result-published", "needs-decision"):
            raise ValidationError("cell has not published a collectible result")
        result_root = env["state_dir"] / "results" / state["cell"] / "attempt-{}".format(state["attempt"])
        result_root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if result_root.exists():
            raise ValidationError("result was already collected; refusing overwrite")
        temp = result_root.with_name(".{}.{}.tmp".format(result_root.name, uuid.uuid4().hex))
        temp.mkdir(parents=True, mode=0o700)
        try:
            archive = temp / "result.tar.gz"
            storage_download(
                env, state["staging"]["result_blob"], archive,
                container=state["staging"]["container"],
            )
            digest = sha256_file(archive)
            if digest != state.get("expected_result_digest"):
                raise ValidationError("downloaded result digest differs from the control-plane marker")
            extracted = temp / "extracted"
            extracted.mkdir(mode=0o700)
            safe_extract_result(archive, extracted)
            result = json.loads((extracted / "result.json").read_text(encoding="utf-8"))
            verify_result_identity(state, result)
            os.replace(str(temp), str(result_root))
        except Exception:
            shutil.rmtree(temp, ignore_errors=True)
            raise
        state["result"] = result
        state["result_path"] = str(result_root)
        state["worktree_luks_uuid"] = result["worktree_luks_uuid"]
        if result.get("run_id"):
            state["run_id"] = result["run_id"]
        phase = "needs-decision" if result["outcome"] == "needs-decision" else "collected"
        transition(env, state, phase, "result and evidence passed exact identity verification")
    print_status(state)


def respond(env, args):
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] != "needs-decision":
            raise ValidationError("cell is not waiting on an ask-user decision")
        try:
            response = Path(args.response_file).read_text(encoding="utf-8")
        except OSError as exc:
            raise ValidationError("response file is unreadable: {}".format(exc))
        if not response.strip() or len(response.encode("utf-8")) > 64 * 1024:
            raise ValidationError("response must contain 1-65536 bytes")
        exists, vm = read_resource(env, state["resources"]["vm_id"], "vm")
        if (
            not exists
            or not same_stable_identity(
                state["resources"]["identities"]["vm"], immutable_identity(vm, "vm"), "vm"
            )
        ):
            raise ValidationError("exact cell VM identity is absent or changed; response retained")
        state["attempt"] += 1
        output_url = blob_sas(
            env, state["staging"]["result_blob"], "cw",
            container=state["staging"]["container"],
        )
        create_run_command(env, state, "respond", output_url=output_url, response=response)
        transition(env, state, "responding", "exact ask-user run received a protected response")
    print("AZURE VALIDATION RESPONDED cell={} attempt={}".format(state["cell"], state["attempt"]))


def replacement_allowed(state, vm_presence, worktree_identity, remote_head):
    if vm_presence != "absent-proven":
        return False, "old VM absence is not proven"
    expected = state.get("resources", {}).get("identities", {}).get("worktree")
    if not same_stable_identity(expected, worktree_identity, "disk"):
        return False, "durable worktree identity changed"
    if remote_head != state["request"]["repository"]["head"] and state.get("run_id") is None:
        return False, "remote head changed before an exact run id was recorded"
    if state.get("phase") not in ("running", "needs-decision", "failed-retained", "responding", "reattaching"):
        return False, "cell phase does not own recoverable work"
    return True, "replacement admitted"


def replace(env, args):
    if not args.confirm_replace or args.confirm_subscription != env["subscription"]:
        raise ValidationError("replacement requires --confirm-replace and the exact subscription")
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        exists, vm = read_resource(env, state["resources"]["vm_id"], "vm")
        if exists:
            if same_stable_identity(
                state["resources"]["identities"]["vm"], immutable_identity(vm, "vm"), "vm"
            ):
                raise ValidationError("old exact VM still exists; duplicate replacement is forbidden")
            raise ValidationError("foreign VM occupies the recorded identity")
        work_exists, worktree = read_resource(env, state["resources"]["worktree_disk_id"], "disk")
        if not work_exists:
            raise ValidationError("durable validation worktree disk is absent")
        remote = git(Path(state["repository_root"]), "ls-remote", "--heads", "origin", "refs/heads/" + state["request"]["repository"]["branch"]).stdout.split()
        remote_head = remote[0] if len(remote) == 2 else "unreadable"
        allowed, reason = replacement_allowed(state, "absent-proven", immutable_identity(worktree, "disk"), remote_head)
        if not allowed:
            raise ValidationError(reason)
        # Prove and remove the old attempt's exact disposable remnants before
        # their names leave authoritative state. Durable worktree, identity,
        # private container, and credential lease are retained.
        cleanup_compute(env, state)
        worktree_identity = wait_exact_disk_detached(
            env, state["resources"]["worktree_disk_id"],
            state["resources"]["identities"]["worktree"], "validation worktree",
        )
        wait_exact_disk_detached(
            env, state["resources"]["credential_disk_id"],
            state["resources"]["identities"]["credential"], "credential lease",
        )
        state["attempt"] += 1
        token = state["cell"].split("-", 1)[1] + "a{}".format(state["attempt"])
        old_resources = state["resources"]
        old_worktree_id = old_resources["worktree_disk_id"]
        old_worktree_name = old_resources["worktree_disk_name"]
        state["resources"] = resource_names(env, token, state["request"]["credential_lease"])
        state["resources"]["worktree_disk_id"] = old_worktree_id
        state["resources"]["worktree_disk_name"] = old_worktree_name
        for key in ("identity_name", "identity_id", "identity_client_id", "identity_principal_id"):
            state["resources"][key] = old_resources[key]
        state["resources"]["identities"] = {
            "worktree": worktree_identity,
            "identity": old_resources["identities"]["identity"],
        }
        selected = {
            "sku": state["allocation"]["sku"],
            "family": state["allocation"]["sku_family"],
            "owner": env["owner"],
        }
        transition(env, state, "reattaching", "old VM absence and exact durable identity proved")
        create_cell(env, state, selected, replacement=True)
        output_url = blob_sas(
            env, state["staging"]["result_blob"], "cw", hours=MAX_CELL_LIFETIME_HOURS,
            container=state["staging"]["container"],
        )
        create_run_command(env, state, "reattach", output_url=output_url)
        transition(env, state, "running", "replacement VM reattaching only to the exact recorded no-mistakes run")
    print("AZURE VALIDATION REPLACED cell={} attempt={}".format(state["cell"], state["attempt"]))


def verify_cleanup_resource(state, resource, kind, recorded_key=None):
    tags = resource.get("tags") or {}
    label = recorded_key or kind
    if tags.get("validation-cell") != state["cell"] or tags.get("fence") != state["request"]["fence"]:
        raise ValidationError("{} cleanup identity is foreign".format(label))
    recorded = state["resources"].get("identities", {}).get(label)
    if recorded and not same_stable_identity(recorded, immutable_identity(resource, kind), kind):
        raise ValidationError("{} immutable identity changed; cleanup retained".format(label))


def delete_resource(env, state, resource_id, kind, recorded_key=None):
    exists, resource = read_resource(env, resource_id, kind)
    if not exists:
        return
    verify_cleanup_resource(state, resource, kind, recorded_key)
    identity = immutable_identity(resource, kind)
    body = {"If-Match": identity["etag"]}
    header = write_private_json(env, ".delete-header-", body)
    try:
        _, rc, stderr = az_command(env, [
            "rest", "--method", "delete",
            "--url", "https://management.azure.com{}?api-version={}".format(resource_id, RESOURCE_API[kind]),
            "--headers", "If-Match={}".format(identity["etag"]),
        ], check=False)
    finally:
        header.unlink(missing_ok=True)
    if rc != 0:
        raise ValidationError("exact {} deletion failed: {}".format(kind, stderr))
    for _ in range(60):
        remains, _ = read_resource(env, resource_id, kind)
        if not remains:
            return
        time.sleep(5)
    raise ValidationError("exact {} remains after bounded delete reconciliation".format(kind))


def delete_run_command(env, state, run_id, recorded):
    exists, run_command = read_resource(env, run_id, "run-command")
    if not exists:
        return
    tags = run_command.get("tags") or {}
    live = immutable_identity(run_command, "run-command")
    if (
        tags.get("validation-cell") != state["cell"]
        or tags.get("fence") != state["request"]["fence"]
        or not same_stable_identity(recorded, live, "run-command")
    ):
        raise ValidationError("run-command cleanup identity is foreign")
    _, rc, stderr = az_command(env, [
        "rest", "--method", "delete",
        "--url", "https://management.azure.com{}?api-version={}".format(run_id, RESOURCE_API["run-command"]),
        "--headers", "If-Match={}".format(live["etag"]),
    ], check=False)
    if rc != 0:
        raise ValidationError("exact run-command delete failed: {}".format(stderr))
    for _ in range(60):
        remains, _ = read_resource(env, run_id, "run-command")
        if not remains:
            return
        time.sleep(5)
    raise ValidationError("exact run-command remains after bounded delete reconciliation")


def cleanup_compute(env, state):
    resources = state["resources"]
    for record in resources.get("run_commands", []):
        delete_run_command(env, state, record["id"], record["identity"])
    safety_identity = resources.get("identities", {}).get("run-command-safety")
    if safety_identity:
        delete_run_command(env, state, resources["safety_run_command_id"], safety_identity)
    delete_resource(env, state, state["resources"]["vm_id"], "vm")
    delete_resource(env, state, state["resources"]["nic_id"], "nic")
    delete_resource(env, state, state["resources"]["os_disk_id"], "disk")
    delete_resource(env, state, state["resources"]["ttl_schedule_id"], "ttl-schedule")


def wait_exact_disk_detached(env, disk_id, recorded, label):
    for _ in range(60):
        exists, disk = read_resource(env, disk_id, "disk")
        if not exists:
            raise ValidationError("{} disk disappeared during detach reconciliation".format(label))
        live = immutable_identity(disk, "disk")
        if not same_stable_identity(recorded, live, "disk"):
            raise ValidationError("{} disk stable identity changed".format(label))
        managed_by = disk.get("managedBy") or disk.get("properties", {}).get("managedBy")
        if not managed_by:
            return live
        time.sleep(5)
    raise ValidationError("{} disk did not detach after bounded reconciliation".format(label))


def delete_cell_storage_scope(env, state):
    scope = "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Storage/storageAccounts/{}/blobServices/default/containers/{}".format(
        env["subscription"], env["resource_group"], env["storage"], state["staging"]["container"]
    )
    plan = state.get("storage_cleanup")
    container_exists, container = read_resource(env, scope, "container")
    assignments, _, _ = az_command(env, ["role", "assignment", "list", "--scope", scope, "--all"])
    direct = [item for item in assignments if str(item.get("scope", "")).lower() == scope.lower()]
    expected_principals = {env["operator_object_id"].lower(), state["resources"]["identity_principal_id"].lower()}
    expected_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], BLOB_DATA_CONTRIBUTOR_ROLE
    )
    if plan is None:
        if not container_exists:
            raise ValidationError("cell private container disappeared before cleanup was planned")
        properties = container.get("properties", container)
        container_etag = container.get("etag") or properties.get("etag")
        principals = {str(item.get("principalId", "")).lower() for item in direct}
        if (
            properties.get("publicAccess") not in (None, "None")
            or not container_etag
            or len(direct) != 2
            or principals != expected_principals
            or any(
                not item.get("id")
                or str(item.get("roleDefinitionId", "")).lower() != expected_role.lower()
                for item in direct
            )
        ):
            raise ValidationError("cell container/role cleanup inventory is foreign or incomplete")
        plan = {
            "scope": scope,
            "container_etag": container_etag,
            "role_ids": sorted(item["id"] for item in direct),
            "roles_absent": False,
            "container_absent": False,
        }
        state["storage_cleanup"] = plan
        save_state(env, state)
    if plan.get("scope") != scope or not plan.get("container_etag") or len(plan.get("role_ids", [])) != 2:
        raise ValidationError("stored cell-container cleanup plan is corrupt")
    planned_ids = set(plan["role_ids"])
    current_ids = {item.get("id") for item in direct}
    if (
        not current_ids.issubset(planned_ids)
        or any(
            str(item.get("principalId", "")).lower() not in expected_principals
            or str(item.get("roleDefinitionId", "")).lower() != expected_role.lower()
            for item in direct
        )
    ):
        raise ValidationError("cell role cleanup inventory changed or gained foreign authority")
    for item in direct:
        _, rc, stderr = az_command(env, ["role", "assignment", "delete", "--ids", item["id"]], check=False)
        if rc != 0:
            raise ValidationError("exact cell role assignment deletion failed: {}".format(stderr))
    for _ in range(60):
        remaining, _, _ = az_command(env, ["role", "assignment", "list", "--scope", scope, "--all"])
        current = [item for item in remaining if str(item.get("scope", "")).lower() == scope.lower()]
        if not current:
            break
        if not {item.get("id") for item in current}.issubset(planned_ids):
            raise ValidationError("foreign role assignment appeared during cleanup")
        time.sleep(5)
    else:
        raise ValidationError("cell role assignments remain after bounded deletion reconciliation")
    plan["roles_absent"] = True
    save_state(env, state)
    container_exists, container = read_resource(env, scope, "container")
    if container_exists:
        properties = container.get("properties", container)
        live_etag = container.get("etag") or properties.get("etag")
        if live_etag != plan["container_etag"] or properties.get("publicAccess") not in (None, "None"):
            raise ValidationError("cell private container changed after cleanup planning")
        _, rc, stderr = az_command(env, [
            "rest", "--method", "delete",
            "--url", "https://management.azure.com{}?api-version={}".format(scope, RESOURCE_API["container"]),
            "--headers", "If-Match={}".format(live_etag),
        ], check=False)
        if rc != 0:
            raise ValidationError("exact cell container deletion failed: {}".format(stderr))
    for _ in range(60):
        remains, _ = read_resource(env, scope, "container")
        if not remains:
            break
        time.sleep(5)
    else:
        raise ValidationError("cell container remains after bounded exact deletion")
    plan["container_absent"] = True
    save_state(env, state)
    delete_resource(env, state, state["resources"]["identity_id"], "identity")


def close(env, args):
    if not args.confirm_close or args.confirm_subscription != env["subscription"]:
        raise ValidationError("close requires --confirm-close and the exact subscription")
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] not in ("collected", "cleanup-retained"):
            raise ValidationError("only an exact collected terminal result or its retained cleanup may close")
        result = state.get("result") or {}
        if result.get("outcome") not in ("passed", "checks-passed"):
            raise ValidationError("failed or unfinished validation retains durable storage")
        if args.confirm_head != result.get("current_head"):
            raise ValidationError("close head confirmation does not match the exact validated head")
        remote = git(Path(state["repository_root"]), "ls-remote", "--heads", "origin", "refs/heads/" + result["branch"]).stdout.split()
        if len(remote) != 2 or remote[0] != result["current_head"]:
            raise ValidationError("remote branch is not current with the exact validated head")
        try:
            cleanup_compute(env, state)
            wait_exact_disk_detached(
                env, state["resources"]["credential_disk_id"],
                state["resources"]["identities"]["credential"], "credential lease",
            )
            # Worktree deletion is authorized only after result/evidence collection,
            # current remote proof, CI green, and exact head confirmation.
            delete_resource(env, state, state["resources"]["worktree_disk_id"], "disk", recorded_key="worktree")
            delete_cell_storage_scope(env, state)
            # Return the shared shape capacity: the control constituent after
            # proven compute absence, plus any pre-reserved shard constituent
            # whose child runner never started. Dispatched children release
            # their own constituents through the runner's cleanup path.
            admission = state.get("admission") or {}
            if admission.get("shape_id"):
                release_shape_constituent(env, state, state["cell"], "control-compute-absent")
                dispatched = {
                    record.get("invocation")
                    for record in (state.get("shard_runs") or {}).values()
                }
                for entry in admission.get("shard_plan", []):
                    if entry["invocation"] not in dispatched:
                        release_shape_constituent(env, state, entry["invocation"], "shard-never-dispatched")
        except ValidationError as exc:
            transition(env, state, "cleanup-retained", "exact close was partial or ambiguous: {}".format(str(exc)[:300]))
            raise
        started = parse_utc(state.get("started_at"), "cell start")
        elapsed = max(0.0, (now_utc() - started).total_seconds())
        transition(env, state, "closed", "exact run closed; compute zero and credential lease detached", billable_seconds=elapsed)
    print("AZURE VALIDATION CLOSED cell={} head={} compute=zero".format(state["cell"], result["current_head"]))


def fail_retain(env, args):
    if not args.confirm_retain or args.confirm_subscription != env["subscription"]:
        raise ValidationError("retained failure cleanup requires exact confirmation")
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] not in ("failed-retained", "result-published", "needs-decision", "running"):
            raise ValidationError("cell phase does not own retainable failure capacity")
        cleanup_compute(env, state)
        state["resources"]["identities"]["worktree"] = wait_exact_disk_detached(
            env, state["resources"]["worktree_disk_id"],
            state["resources"]["identities"]["worktree"], "validation worktree",
        )
        state["resources"]["identities"]["credential"] = wait_exact_disk_detached(
            env, state["resources"]["credential_disk_id"],
            state["resources"]["identities"]["credential"], "credential lease",
        )
        transition(env, state, "failed-retained", "exact disposable compute removed; worktree and credential lease retained")
    print("AZURE VALIDATION RETAINED cell={} compute=zero worktree=retained".format(state["cell"]))


def list_cell_blobs(env, state, prefix="shards/"):
    values, _, _ = az_command(env, [
        "storage", "blob", "list", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", state["staging"]["container"], "--prefix", prefix,
    ])
    return [item.get("name") for item in values if isinstance(item, dict) and isinstance(item.get("name"), str)]


def extract_shard_request(archive_path, destination):
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        if {member.name for member in members} != {"request.json", "snapshot.bundle"}:
            raise ValidationError("shard request archive member set is invalid")
        for member in members:
            if not member.isfile() or member.issym() or member.islnk() or member.isdev() or member.size > 1024**3:
                raise ValidationError("shard request archive contains an unsafe member")
        archive.extractall(str(destination), members=members)


def validate_shard_request(state, request, bundle_path, blob):
    if request.get("schema") != "fm.azure-validation-shard/v1":
        raise ValidationError("shard request schema is invalid")
    unsigned = dict(request)
    supplied = unsigned.pop("request_digest", None)
    if supplied != sha256_bytes(canonical_bytes(unsigned)):
        raise ValidationError("shard request digest mismatch")
    repository = request.get("repository") or {}
    expected_repository = state["request"]["repository"]
    if request.get("cell") != state["cell"]:
        raise ValidationError("shard request belongs to another cell")
    if (
        repository.get("slug") != expected_repository["slug"]
        or repository.get("branch") != expected_repository["branch"]
    ):
        raise ValidationError("shard request repository/branch differs from the exact validation run")
    if repository.get("snapshot_digest") != sha256_file(bundle_path):
        raise ValidationError("shard request bundle digest mismatch")
    if (
        not HEX_OBJECT.match(str(repository.get("head", "")))
        or not HEX_OBJECT.match(str(repository.get("tree", "")))
    ):
        raise ValidationError("shard request head/tree is malformed")
    match = re.match(r"^shards/(round-[a-z0-9]{12})/request-([1-8])\.tar\.gz$", blob)
    if not match or request.get("round") != match.group(1) or int(request.get("shard", 0)) != int(match.group(2)):
        raise ValidationError("shard request blob identity is malformed")
    count = int(request.get("shard_count", 0))
    shard = int(request.get("shard", 0))
    if count < 1 or count > 8 or shard < 1 or shard > count:
        raise ValidationError("shard request index/count is outside 1-8")
    command = request.get("command", {}).get("argv")
    if not isinstance(command, list) or not command or any(not isinstance(item, str) or "\x00" in item for item in command):
        raise ValidationError("shard command argv is malformed")
    if request.get("command_digest") != sha256_bytes(canonical_bytes({"argv": command})):
        raise ValidationError("shard command digest mismatch")
    kind = request.get("kind")
    if kind == "behavior":
        exact = [
            "bin/fm-azure-runner-command.sh", "bash", "-c",
            "FM_TEST_SKIP_HERDR=1 bin/fm-behavior-shards.sh --run {} {} results/executed-{}.tsv".format(shard, count, shard),
        ]
        if command != exact or request.get("artifacts") != ["results/executed-{}.tsv".format(shard)]:
            raise ValidationError("behavior shard command differs from the sealed planner route")
    elif kind == "lint":
        exact = [
            "bin/fm-azure-runner-command.sh", "bash", "-c",
            "bin/fm-lint.sh && uv run --directory tools/agent-fleet --locked ruff check .",
        ]
        if count != 1 or shard != 1 or request.get("artifacts") != [] or command != exact:
            raise ValidationError("lint shard differs from the trusted default-branch command")
    else:
        raise ValidationError("shard kind is unsupported")
    return supplied


def runner_state_dir(env):
    return Path(os.environ.get(
        "FM_AZURE_RUNNER_STATE_DIR", str(env["home"] / "state" / "azure-runner")
    )).resolve()


def shard_plan_entry(state, shard):
    plan = (state.get("admission") or {}).get("shard_plan") or []
    for entry in plan:
        if entry.get("shard") == shard:
            return entry
    raise ValidationError("shard {} has no pre-reserved shape constituent".format(shard))


def prepare_shard_runner(env, state, blob, request, extracted, plan):
    sku = plan["sku"]
    key = request["request_digest"]
    existing = state.setdefault("shard_runs", {}).get(key)
    if existing:
        expected = {
            "blob": blob,
            "sku": sku,
            "invocation": plan["invocation"],
            "round": request["round"],
            "shard": request["shard"],
            "head": request["repository"]["head"],
            "command_digest": request["command_digest"],
        }
        if any(existing.get(name) != value for name, value in expected.items()):
            raise ValidationError("recorded shard runner identity differs from the exact request")
        return existing
    repo = extracted / "repo"
    git_bundle = extracted / "snapshot.bundle"
    run(["git", "clone", "--no-local", str(git_bundle), str(repo)])
    git(repo, "checkout", "-B", request["repository"]["branch"], request["repository"]["head"])
    if git(repo, "rev-parse", "HEAD").stdout.strip() != request["repository"]["head"]:
        raise ValidationError("materialized shard head mismatch")
    if git(repo, "rev-parse", "HEAD^{tree}").stdout.strip() != request["repository"]["tree"]:
        raise ValidationError("materialized shard tree mismatch")
    public_remote = "https://github.com/{}.git".format(request["repository"]["slug"])
    git(repo, "remote", "set-url", "origin", public_remote)
    invocation = plan["invocation"]
    record = {
        "blob": blob,
        "request_digest": key,
        "invocation": invocation,
        "sku": sku,
        "round": request["round"],
        "shard": request["shard"],
        "head": request["repository"]["head"],
        "command_digest": request["command_digest"],
        "repo": str(repo),
        "snapshot_bundle": str(git_bundle),
        "source_ref": "refs/heads/" + request["repository"]["branch"],
        "task": "{}-s{}".format(state["cell"], request["shard"]),
        "generation": request["round"],
        "resource_class": request["resource_class"],
        "artifacts": list(request.get("artifacts", [])),
        "command": list(request["command"]["argv"]),
        "response_uploaded": False,
    }
    state["shard_runs"][key] = record
    save_state(env, state)
    return record


def run_shard_invocations(env, state, records):
    processes = []
    runner = ROOT / "bin" / "fm-azure-runner.sh"
    for record in records:
        runner_state = runner_state_dir(env) / (record["invocation"] + ".json")
        operation = [str(runner), "resume", "--invocation", record["invocation"]]
        if runner_state.is_file():
            try:
                value = json.loads(runner_state.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValidationError("recorded shard runner state is unreadable: {}".format(exc))
            if value.get("phase") == "complete":
                continue
        else:
            operation = [
                str(runner), "run", "--confirm-run",
                "--confirm-subscription", env["subscription"],
                "--repo", record["repo"],
                "--task", record["task"],
                "--generation", record["generation"],
                "--invocation", record["invocation"],
                "--resource-class", record["resource_class"],
                "--capacity-parent", state["cell"],
                "--capacity-reservation-vcpus", str(state["request"]["limits"]["reserved_vcpus"]),
                "--capacity-fence", state["request"]["fence"].split(":", 1)[-1],
                "--source-ref", record["source_ref"],
                "--private-snapshot-bundle", record["snapshot_bundle"],
            ]
            for artifact in record["artifacts"]:
                operation += ["--artifact", artifact]
            operation += ["--"] + record["command"]
        process_env = os.environ.copy()
        process_env["FM_AZURE_RUNNER_SKU"] = record["sku"]
        process_env["FM_AZURE_RUNNER_MAX_CONCURRENCY"] = "8"
        process = subprocess.Popen(
            operation, env=process_env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        processes.append((record, process))
    failures = []
    for record, process in processes:
        stdout, stderr = process.communicate()
        record["runner_stdout_tail"] = stdout[-2000:]
        record["runner_stderr_tail"] = stderr[-2000:]
        if process.returncode == 125 or process.returncode < 0:
            failures.append("{} rc={}".format(record["invocation"], process.returncode))
    if failures:
        raise ValidationError("one or more shard transports retained ambiguous state: " + ", ".join(failures))


def extract_runner_archive(path, destination):
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            if not (
                member.name in ("result.json", "stdout.log", "stderr.log", "artifacts")
                or member.name.startswith("artifacts/")
            ):
                raise ValidationError("runner result archive contains an undeclared path")
            if (
                member.issym() or member.islnk() or member.isdev()
                or member.name.startswith("/") or ".." in member.name.split("/")
                or member.size > 256 * 1024**2
            ):
                raise ValidationError("runner result archive contains an unsafe member")
        archive.extractall(str(destination), members=members)


def package_shard_response(env, state, request, record, destination):
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = runner_state_dir(env) / (record["invocation"] + ".json")
    try:
        runner_state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("shard runner state is unreadable: {}".format(exc))
    if runner_state.get("phase") != "complete":
        raise ValidationError("shard runner has not reached safe collected cleanup")
    runner_result = runner_state.get("result") or {}
    runner_request = runner_state.get("request") or {}
    repository = runner_request.get("repository") or {}
    if (
        repository.get("source_mode") != "private-parent-bundle"
        or repository.get("commit") != request["repository"]["head"]
        or repository.get("tree") != request["repository"]["tree"]
        or repository.get("source_ref") != "refs/heads/" + request["repository"]["branch"]
        or repository.get("source_head") != request["repository"]["head"]
    ):
        raise ValidationError("shard runner executed the wrong public branch head/tree")
    if (
        runner_request.get("command_digest") != request["command_digest"]
        or runner_request.get("capacity_parent") != state["cell"]
        or runner_request.get("capacity_reservation_vcpus") != state["request"]["limits"]["reserved_vcpus"]
    ):
        raise ValidationError("shard runner executed the wrong command or capacity parent")
    private_archive = destination / "runner-result.tar.gz"
    storage_download(
        env, runner_state["staging"]["output_blob"], private_archive,
        container=CONTAINER,
    )
    if sha256_file(private_archive) != runner_state.get("result_digest"):
        raise ValidationError("shard runner private archive digest differs from collected control state")
    extracted = destination / "runner-result"
    extracted.mkdir(mode=0o700)
    extract_runner_archive(private_archive, extracted)
    try:
        archive_result = json.loads((extracted / "result.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("shard runner private result is unreadable: {}".format(exc))
    if archive_result != runner_result:
        raise ValidationError("shard runner private/control-plane result identities differ")
    artifact_records = runner_result.get("artifacts")
    artifacts = request.get("artifacts", [])
    if not isinstance(artifact_records, list) or len(artifact_records) != len(artifacts):
        raise ValidationError("shard runner artifact manifest differs from the request")
    artifact_record = artifact_records[0] if artifact_records else None
    if artifact_record is not None and artifact_record.get("path") != artifacts[0]:
        raise ValidationError("shard runner returned the wrong manifest artifact")
    result = {
        "schema": "fm.azure-validation-shard-result/v1",
        "cell": state["cell"], "round": request["round"], "kind": request["kind"],
        "shard": request["shard"], "shard_count": request["shard_count"],
        "head": request["repository"]["head"], "tree": request["repository"]["tree"],
        "request_digest": request["request_digest"], "command_digest": request["command_digest"],
        "invocation": record["invocation"], "vm_instance_id": runner_result.get("vm_instance_id"),
        "boot_id": runner_result.get("boot_id"), "exit_code": runner_result.get("exit_code"),
        "artifact": artifact_record,
        "duration_seconds": runner_result.get("duration_seconds"),
        "cost_usd": round(float(runner_state.get("cost", {}).get("hourly_rate", 0.0)) * float(runner_result.get("duration_seconds", 0.0)) / 3600.0, 6),
    }
    response_root = destination / "response"
    response_root.mkdir(mode=0o700)
    (response_root / "result.json").write_bytes(canonical_bytes(result) + b"\n")
    for name in ("stdout.log", "stderr.log"):
        source = extracted / name
        if source.is_file():
            shutil.copyfile(str(source), str(response_root / name))
    if artifact_record is not None:
        source = extracted / "artifacts" / artifacts[0]
        if (
            not source.is_file() or source.is_symlink()
            or source.stat().st_size != artifact_record.get("bytes")
            or sha256_file(source) != artifact_record.get("digest")
        ):
            raise ValidationError("shard runner returned a mismatched manifest artifact")
        shutil.copyfile(str(source), str(response_root / "executed.tsv"))
    archive = destination / "response.tar.gz"
    with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as output:
        for source in sorted(response_root.iterdir()):
            info = output.gettarinfo(str(source), arcname=source.name)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            with open(source, "rb") as handle:
                output.addfile(info, handle)
    return archive


def drive(env, args):
    deadline = time.monotonic() + args.wait_seconds
    cell = require_cell(args.cell)
    # The shard-driver lock serializes duplicate drivers without holding the
    # cell-state lock across hours of Azure execution. Observe/status/respond
    # therefore retain bounded access while independent command VMs are busy.
    with lock(env, cell + "-shards"):
        while True:
            with lock(env, cell):
                state = load_state(env, cell)
                if state["phase"] not in ("running", "responding", "reattaching", "needs-decision"):
                    print_status(state)
                    return
                names = list_cell_blobs(env, state)
                requests = [name for name in names if re.match(r"^shards/round-[a-z0-9]{12}/request-[1-8]\.tar\.gz$", name)]
                pending = []
                work_root = env["state_dir"] / "shards" / state["cell"]
                work_root.mkdir(parents=True, exist_ok=True, mode=0o700)
                for blob in sorted(requests):
                    response_blob = blob.replace("/request-", "/response-")
                    if response_blob in names:
                        continue
                    blob_key = sha256_bytes(blob.encode("utf-8")).split(":", 1)[1][:16]
                    request_root = work_root / blob_key
                    if request_root.exists():
                        shutil.rmtree(request_root)
                    request_root.mkdir(mode=0o700)
                    archive = request_root / "request.tar.gz"
                    storage_download(env, blob, archive, container=state["staging"]["container"])
                    extracted = request_root / "extracted"
                    extracted.mkdir(mode=0o700)
                    extract_shard_request(archive, extracted)
                    request = json.loads((extracted / "request.json").read_text(encoding="utf-8"))
                    validate_shard_request(state, request, extracted / "snapshot.bundle", blob)
                    plan = shard_plan_entry(state, int(request["shard"]))
                    record = prepare_shard_runner(env, state, blob, request, extracted, plan)
                    pending.append((request, record, request_root, response_blob))
            if pending:
                run_shard_invocations(env, state, [item[1] for item in pending])
                with lock(env, cell):
                    live = load_state(env, cell)
                    if live["request_digest"] != state["request_digest"]:
                        raise ValidationError("cell identity changed while shard VMs were running")
                    for _request, record, _root, _blob in pending:
                        live_record = live.get("shard_runs", {}).get(record["request_digest"])
                        if not live_record or live_record.get("invocation") != record["invocation"]:
                            raise ValidationError("shard invocation identity changed while running")
                        live_record.update({
                            "runner_stdout_tail": record.get("runner_stdout_tail", ""),
                            "runner_stderr_tail": record.get("runner_stderr_tail", ""),
                        })
                    save_state(env, live)
                for request, record, request_root, response_blob in pending:
                    archive = package_shard_response(env, live, request, record, request_root)
                    storage_upload(
                        env, archive, response_blob, overwrite=False,
                        container=live["staging"]["container"],
                    )
                with lock(env, cell):
                    live = load_state(env, cell)
                    for _request, record, _root, _blob in pending:
                        live["shard_runs"][record["request_digest"]]["response_uploaded"] = True
                    save_state(env, live)
                print("AZURE VALIDATION SHARDS DISPATCHED cell={} count={}".format(cell, len(pending)))
                return
            if time.monotonic() >= deadline:
                print("AZURE VALIDATION SHARDS WAITING cell={} pending=0".format(cell))
                return
            time.sleep(5)


def queue(env):
    ensure_dirs(env)
    rows = []
    for path in sorted(env["state_dir"].glob("azv-*.json")):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            value = json.loads(path.read_text(encoding="utf-8"))
            rows.append((value.get("created_at", ""), value))
    rows.sort(key=lambda item: (item[0], item[1].get("cell", "")))
    if not rows:
        print("AZURE VALIDATION QUEUE empty active=0 queued=0")
        return
    for _, state in rows:
        print("cell={} phase={} task={} head={} class={} attempt={}".format(
            state.get("cell"), state.get("phase"), state.get("request", {}).get("task"),
            state.get("request", {}).get("repository", {}).get("head"),
            state.get("request", {}).get("resource_class"), state.get("attempt"),
        ))


def print_status(state):
    result = state.get("result") or {}
    fields = [
        "AZURE VALIDATION", "cell=" + state["cell"], "phase=" + state["phase"],
        "task=" + state["request"]["task"], "head=" + state["request"]["repository"]["head"],
        "attempt=" + str(state["attempt"]),
    ]
    if state.get("run_id"):
        fields.append("run=" + str(state["run_id"]))
    if result.get("current_head"):
        fields.append("current_head=" + result["current_head"])
    if result.get("pr_url"):
        fields.append("pr=" + result["pr_url"])
    print(" ".join(fields))


def status(env, args):
    with lock(env, require_cell(args.cell)):
        print_status(load_state(env, args.cell))


def pure_check(args):
    value = json.loads(Path(args.fixture).read_text(encoding="utf-8"))
    operation = value.get("operation")
    if operation == "shape-plan":
        rates = value.get("rates") or {}
        plan = compose_shard_plan(
            value["selected_family"], value["behavior_shards"],
            lambda sku: rates[sku],
        )
        print(json.dumps({
            "plan": plan,
            "total_vcpus": 8 + 4 * len(plan),
            "distinct_invocations": len({entry["invocation"] for entry in plan}),
        }, sort_keys=True))
        return
    if operation == "result-identity":
        verify_result_identity(value["state"], value["result"])
        print(json.dumps({"valid": True}, sort_keys=True))
        return
    if operation == "replacement":
        allowed, reason = replacement_allowed(
            value["state"], value["vm_presence"], value["worktree_identity"], value["remote_head"]
        )
        print(json.dumps({"allowed": allowed, "reason": reason}, sort_keys=True))
        return
    raise ValidationError("unknown focused pure-check operation")


def parser():
    root = argparse.ArgumentParser(prog="fm-azure-validation.sh")
    commands = root.add_subparsers(dest="command", required=True)
    submit_parser = commands.add_parser("submit")
    submit_parser.add_argument("--repo")
    submit_parser.add_argument("--task", required=True)
    submit_parser.add_argument("--task-generation", required=True)
    submit_parser.add_argument("--validation-generation", required=True)
    submit_parser.add_argument("--intent-file", required=True)
    submit_parser.add_argument("--credential-lease", required=True)
    submit_parser.add_argument("--runtime-bundle", required=True)
    submit_parser.add_argument("--resource-class", choices=sorted(RESOURCE_CLASSES))
    dispatch_parser = commands.add_parser("dispatch")
    dispatch_parser.add_argument("--confirm-dispatch", action="store_true")
    dispatch_parser.add_argument("--confirm-subscription")
    for name in ("observe", "collect", "status"):
        item = commands.add_parser(name)
        item.add_argument("--cell", required=True)
    drive_parser = commands.add_parser("drive")
    drive_parser.add_argument("--cell", required=True)
    drive_parser.add_argument("--wait-seconds", type=int, default=0, choices=range(0, 301))
    respond_parser = commands.add_parser("respond")
    respond_parser.add_argument("--cell", required=True)
    respond_parser.add_argument("--response-file", required=True)
    replace_parser = commands.add_parser("replace")
    replace_parser.add_argument("--cell", required=True)
    replace_parser.add_argument("--confirm-replace", action="store_true")
    replace_parser.add_argument("--confirm-subscription")
    close_parser = commands.add_parser("close")
    close_parser.add_argument("--cell", required=True)
    close_parser.add_argument("--confirm-close", action="store_true")
    close_parser.add_argument("--confirm-subscription")
    close_parser.add_argument("--confirm-head", required=True)
    retain_parser = commands.add_parser("retain-failure")
    retain_parser.add_argument("--cell", required=True)
    retain_parser.add_argument("--confirm-retain", action="store_true")
    retain_parser.add_argument("--confirm-subscription")
    commands.add_parser("queue")
    pure = commands.add_parser("pure-check", help=argparse.SUPPRESS)
    pure.add_argument("--fixture", required=True)
    return root


def main():
    args = parser().parse_args()
    try:
        if args.command == "pure-check":
            pure_check(args)
            return 0
        cloud = args.command in ("dispatch", "drive", "observe", "collect", "respond", "replace", "close", "retain-failure")
        env = environment(require_cloud=cloud)
        if args.command == "submit":
            submit(env, args)
        elif args.command == "dispatch":
            dispatch(env, args)
        elif args.command == "drive":
            drive(env, args)
        elif args.command == "observe":
            observe(env, args)
        elif args.command == "collect":
            collect(env, args)
        elif args.command == "respond":
            respond(env, args)
        elif args.command == "replace":
            replace(env, args)
        elif args.command == "close":
            close(env, args)
        elif args.command == "retain-failure":
            fail_retain(env, args)
        elif args.command == "queue":
            queue(env)
        elif args.command == "status":
            status(env, args)
        return 0
    except ValidationError as exc:
        print("AZURE VALIDATION FAILED: {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
