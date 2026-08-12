#!/usr/bin/env python3
"""Host-side controller for one-shot private Azure command runners.

The script packages a clean committed Git snapshot, binds it to a canonical
command request, stages exact input/output blobs, creates one identity-less VM,
drives it through Azure Managed Run Command, verifies the result, and removes
only resources whose recorded identities match the invocation.

See docs/azure-runner.md and `bin/fm-azure-runner.sh help` for the operator
contract. This file intentionally uses only the Python standard library and the
installed Azure CLI.
"""

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
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
import uuid
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "docs" / "azure-runner" / "invocation.json"
GUEST = ROOT / "bin" / "fm-azure-runner-guest.sh"
EXECUTOR = ROOT / "bin" / "fm-azure-runner-exec.py"
CONTAINER = "validation-shards"
SCHEMA = "fm.azure-command/v1"
RESULT_SCHEMA = "fm.azure-command-result/v1"
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
SAFE_INVOCATION = re.compile(r"^azr-[a-z0-9]{12}(?:-a[2-9][0-9]*)?$")
SAFE_ARTIFACT = re.compile(r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9._/+@:-]{1,240}$")
LOCAL_COMMAND_TIMEOUT_SECONDS = 300
LEASE_DURATION_SECONDS = 60
LEASE_RENEW_TIMEOUT_SECONDS = 10
LEASE_SAFETY_MARGIN_SECONDS = 15
MAX_STAGING_INPUT_BYTES = 512 * 1024**2
MAX_BOOTSTRAP_NETWORK_BYTES = 16 * 1024**3
MAX_RESULT_UPLOAD_BYTES = 600 * 1024**2
BOOTSTRAP_RATE_BITS_PER_SECOND = 1_000_000
MAX_BILLABLE_LIFETIME_HOURS = 24
TTL_SCHEDULE_HOURS_AFTER_PREPARATION = 23
AZURE_SCHEDULE_MINIMUM_LEAD_SECONDS = 30 * 60
SHELLCHECK_ARCHIVE_BYTES = 2_559_196
UV_ARCHIVE_BYTES = 21_427_164
FOUNDATION_SHARED_METER_RESERVE_USD = 210.0
METER_RATE_CEILINGS_USD = {
    "os_disk_storage_capacity": 0.02,
    "nat_gateway": 0.05,
    "public_ip": 0.02,
    "private_endpoints": 0.04,
    "private_dns": 0.02,
    "monitoring": 0.04,
    "boot_diagnostics": 0.01,
    "storage_capacity": 0.02,
    "provisioning_control_interval": 0.01,
}
RUNNER_CONTROL_OPERATION_CEILING = 2_000
RUNNER_STORAGE_OPERATION_CEILING = 2_000
STORAGE_OPERATION_RESERVE_USD = 5.0
CONTROL_OPERATION_RESERVE_USD = 20.0
BOOTSTRAP_GIB_RATE_CEILING_USD = 0.25
NAT_DATA_GIB_RATE_CEILING_USD = 0.10
INTERNET_EGRESS_GIB_RATE_CEILING_USD = 0.25
RESOURCE_API_VERSIONS = {
    "vm": "2024-03-01",
    "nic": "2023-09-01",
    "disk": "2023-10-02",
    "run-command": "2024-03-01",
    "ttl-schedule": "2018-09-15",
}

RESOURCE_CLASSES = {
    "validation-standard": {
        "cpu_cores": 3,
        "memory_bytes": 12 * 1024**3,
        "pid_max": 1024,
        "disk_bytes": 40 * 1024**3,
        "log_bytes": 4 * 1024**2,
        "artifact_bytes": 64 * 1024**2,
        "network_bytes": 0,
        "wall_seconds": 3600,
    },
    "behavior-heavy": {
        "cpu_cores": 3,
        "memory_bytes": 14 * 1024**3,
        "pid_max": 2048,
        "disk_bytes": 48 * 1024**3,
        "log_bytes": 16 * 1024**2,
        "artifact_bytes": 256 * 1024**2,
        "network_bytes": 0,
        "wall_seconds": 10800,
    },
    "crosscheck-tool": {
        "cpu_cores": 3,
        "memory_bytes": 12 * 1024**3,
        "pid_max": 1024,
        "disk_bytes": 40 * 1024**3,
        "log_bytes": 8 * 1024**2,
        "artifact_bytes": 128 * 1024**2,
        "network_bytes": 0,
        "wall_seconds": 7200,
    },
}
SKU_FAMILY = {
    "Standard_D4as_v6": "standardDav6Family",
    "Standard_D4as_v7": "StandardDasv7Family",
    "Standard_D4s_v6": "StandardDsv6Family",
    "Standard_D4ads_v7": "StandardDadsv7Family",
    "Standard_D4ds_v6": "StandardDdsv6Family",
    "Standard_D4s_v7": "StandardDsv7Family",
    "Standard_D4ds_v7": "StandardDdsv7Family",
    "Standard_D4ads_v6": "standardDadv6Family",
}
SKU_VCPUS = {sku: 4 for sku in SKU_FAMILY}
SKU_MEMORY_GIB = {sku: 16 for sku in SKU_FAMILY}


class RunnerError(RuntimeError):
    pass


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)


def run(command, cwd=None, check=True, capture=True, timeout_seconds=LOCAL_COMMAND_TIMEOUT_SECONDS):
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        raise RunnerError("command exceeded its bounded {}-second deadline: {}".format(
            timeout_seconds, command[0]
        ))
    if check and result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise RunnerError("command failed ({}): {}{}".format(
            result.returncode, " ".join(command), ": " + stderr if stderr else ""
        ))
    return result


def git(repo, *args, check=True):
    return run(["git", "-C", str(repo)] + list(args), check=check)


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(value=None):
    value = value or now_utc()
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def require_identifier(label, value):
    if not SAFE_ID.match(value):
        raise RunnerError("{} must use 1-64 bounded identifier characters".format(label))
    return value


def require_invocation(value):
    if not SAFE_INVOCATION.match(value):
        raise RunnerError("invocation id is malformed")
    return value


def require_artifact(value):
    if not SAFE_ARTIFACT.match(value) or "//" in value:
        raise RunnerError("artifact/dependency path is not a bounded repository-relative path: {}".format(value))
    return value


def environment():
    required = [
        "FM_HOME",
        "FM_AZURE_TENANT_ID",
        "FM_AZURE_SUBSCRIPTION_ID",
        "FM_AZURE_NAMING_PREFIX",
        "FM_AZURE_STORAGE_NAME",
        "FM_AZURE_OWNER_TAG",
        "FM_AZURE_DEPLOYMENT_GENERATION",
        "FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID",
    ]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise RunnerError("required environment is missing: " + ", ".join(missing))
    tenant = os.environ["FM_AZURE_TENANT_ID"]
    subscription = os.environ["FM_AZURE_SUBSCRIPTION_ID"]
    if not re.match(r"^[0-9a-fA-F-]{36}$", tenant) or not re.match(r"^[0-9a-fA-F-]{36}$", subscription):
        raise RunnerError("tenant and subscription must be exact UUIDs")
    prefix = os.environ["FM_AZURE_NAMING_PREFIX"]
    if not re.match(r"^[a-z0-9]{3,12}$", prefix):
        raise RunnerError("FM_AZURE_NAMING_PREFIX must be 3-12 lowercase alphanumeric characters")
    storage = os.environ["FM_AZURE_STORAGE_NAME"]
    if not re.match(r"^[a-z0-9]{3,24}$", storage):
        raise RunnerError("FM_AZURE_STORAGE_NAME is malformed")
    generation = require_identifier("deployment generation", os.environ["FM_AZURE_DEPLOYMENT_GENERATION"])
    owner = require_identifier("owner tag", os.environ["FM_AZURE_OWNER_TAG"])
    blob_private_endpoint_nic_resource_guid = os.environ["FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID"]
    if not re.match(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", blob_private_endpoint_nic_resource_guid):
        raise RunnerError("FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID must be the explicitly accepted Azure resourceGuid")
    resource_group = os.environ.get("FM_AZURE_RESOURCE_GROUP", "rg-firstmate-pilot-eastus-001")
    max_concurrency = int(os.environ.get("FM_AZURE_RUNNER_MAX_CONCURRENCY", "4"))
    if max_concurrency < 1 or max_concurrency > 8:
        raise RunnerError("FM_AZURE_RUNNER_MAX_CONCURRENCY must be between 1 and 8")
    budget_limit = int(os.environ.get("FM_AZURE_RUNNER_BUDGET_LIMIT_USD", "1000"))
    if budget_limit not in (1000, 1500):
        raise RunnerError("FM_AZURE_RUNNER_BUDGET_LIMIT_USD must be 1000 or 1500")
    home = Path(os.environ["FM_HOME"]).resolve()
    state_dir = Path(os.environ.get("FM_AZURE_RUNNER_STATE_DIR", str(home / "state" / "azure-runner"))).resolve()
    return {
        "tenant": tenant,
        "subscription": subscription,
        "prefix": prefix,
        "storage": storage,
        "owner": owner,
        "deployment_generation": generation,
        "resource_group": resource_group,
        "max_concurrency": max_concurrency,
        "budget_limit": budget_limit,
        "home": home,
        "home_binding": "sha256:" + sha256_bytes(str(home).encode("utf-8")),
        "state_dir": state_dir,
        "azure_operation_count": 0,
        "vnet": "vnet-{}-eus".format(prefix),
        "subnet": "snet-validation-shards",
        "elastic_nsg": "nsg-{}-elastic-isolated".format(prefix),
        "nat": "nat-{}-eus".format(prefix),
        "blob_private_endpoint": "pe-{}-blob".format(prefix),
        "blob_private_endpoint_nic": "nic-{}-pe-blob".format(prefix),
        "blob_private_endpoint_nic_resource_guid": blob_private_endpoint_nic_resource_guid.lower(),
        "blob_private_dns_zone": "privatelink.blob.core.windows.net",
    }


def ensure_state_dirs(env):
    for path in (env["state_dir"], env["state_dir"] / "payloads", env["state_dir"] / "results"):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path, 0o700)


@contextlib.contextmanager
def state_lock(env):
    ensure_state_dirs(env)
    lock_path = env["state_dir"] / ".lock"
    with open(lock_path, "a+", encoding="utf-8") as handle:
        os.chmod(lock_path, 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


@contextlib.contextmanager
def invocation_lock(env, invocation):
    require_invocation(invocation)
    ensure_state_dirs(env)
    lock_path = env["state_dir"] / ("." + invocation + ".lock")
    with open(lock_path, "a+", encoding="utf-8") as handle:
        os.chmod(lock_path, 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def state_path(env, invocation):
    require_invocation(invocation)
    return env["state_dir"] / (invocation + ".json")


def load_state(env, invocation):
    path = state_path(env, invocation)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise RunnerError("unknown invocation: {}".format(invocation))
    except (OSError, json.JSONDecodeError) as exc:
        raise RunnerError("invocation state is unreadable: {}".format(exc))
    if value.get("invocation") != invocation or value.get("schema") != SCHEMA:
        raise RunnerError("invocation state identity is corrupt")
    return value


def save_state(env, state, create=False):
    path = state_path(env, state["invocation"])
    if create and path.exists():
        raise RunnerError("invocation already exists and will not be reused")
    state["updated_at"] = iso_utc()
    temp = path.with_name(".{}.{}.tmp".format(path.name, uuid.uuid4().hex))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(str(temp), flags, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if create and path.exists():
            raise RunnerError("invocation already exists and will not be reused")
        os.replace(str(temp), str(path))
        directory_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp.unlink()


def save_private_json_atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(".{}.{}.tmp".format(path.name, uuid.uuid4().hex))
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temp), str(path))
        directory_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp.unlink()


def bind_operation_context(env, state):
    request = state["request"]
    env["operation_context"] = {
        "invocation": state["invocation"],
        "fence": request["fence"],
        "parent_invocation": state.get("parent_invocation"),
        "lineage_root": request.get("lineage_root_invocation", state["invocation"]),
    }


def operation_category(args):
    return "storage" if args and args[0] == "storage" else "control"


def record_azure_operation(env, args):
    category = operation_category(args)
    ceilings = {
        "control": RUNNER_CONTROL_OPERATION_CEILING,
        "storage": RUNNER_STORAGE_OPERATION_CEILING,
    }
    path = env["state_dir"] / "operation-ledger.json"
    with state_lock(env):
        try:
            ledger = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            ledger = {
                "schema": "fm.azure-operation-ledger/v1",
                "home_binding": env["home_binding"],
                "deployment_generation": env["deployment_generation"],
                "bootstrap": {"control": 0, "storage": 0},
                "invocations": {},
            }
        except (OSError, json.JSONDecodeError) as exc:
            raise RunnerError("Azure operation ledger is unreadable: {}".format(exc))
        if (
            ledger.get("schema") != "fm.azure-operation-ledger/v1"
            or ledger.get("home_binding") != env["home_binding"]
            or ledger.get("deployment_generation") != env["deployment_generation"]
        ):
            raise RunnerError("Azure operation ledger binding is not exact")
        context = env.get("operation_context")
        if context is None:
            counts = ledger["bootstrap"]
            scope = "admission/bootstrap"
        else:
            invocation = require_invocation(context["invocation"])
            entry = ledger["invocations"].setdefault(invocation, {
                "fence": context["fence"],
                "parent_invocation": context.get("parent_invocation"),
                "lineage_root": context["lineage_root"],
                "counts": {"control": 0, "storage": 0},
            })
            if (
                entry.get("fence") != context["fence"]
                or entry.get("parent_invocation") != context.get("parent_invocation")
                or entry.get("lineage_root") != context["lineage_root"]
            ):
                raise RunnerError("Azure operation ledger invocation/fence lineage is not exact")
            counts = entry["counts"]
            scope = "attempt lineage {}".format(context["lineage_root"])
        used = int(counts.get(category, 0))
        if context is not None:
            used = sum(
                int(item.get("counts", {}).get(category, 0))
                for item in ledger["invocations"].values()
                if item.get("lineage_root") == context["lineage_root"]
            )
        if used >= ceilings[category]:
            raise RunnerError("Azure {} operation ceiling exhausted for {}; exact state is retained".format(category, scope))
        counts[category] = int(counts.get(category, 0)) + 1
        ledger["updated_at"] = iso_utc()
        save_private_json_atomic(path, ledger)


def transition(env, state, phase, note=None, **updates):
    state["phase"] = phase
    state.update(updates)
    state.setdefault("events", []).append({"at": iso_utc(), "phase": phase, "note": note or ""})
    save_state(env, state)


def new_invocation(attempt=1):
    base = "azr-" + uuid.uuid4().hex[:12]
    if attempt > 1:
        return "{}-a{}".format(base, attempt)
    return base


def download_pinned(url, destination, expected_digest, expected_bytes):
    temp = destination.with_name(destination.name + ".tmp")
    request = urllib.request.Request(url, headers={"User-Agent": "firstmate-azure-runner/1"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, open(temp, "xb") as handle:
            remaining = expected_bytes
            while True:
                chunk = response.read(min(1024 * 1024, remaining + 1))
                if not chunk:
                    break
                remaining -= len(chunk)
                if remaining < 0:
                    raise RunnerError("pinned tool download exceeds its exact byte contract")
                handle.write(chunk)
        if remaining != 0 or sha256_file(temp) != expected_digest:
            raise RunnerError("pinned tool download identity mismatch")
        os.replace(str(temp), str(destination))
        os.chmod(destination, 0o600)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp.unlink()


def prepare_tool_closure(payload_dir):
    cache = Path(os.environ.get("FM_AZURE_RUNNER_TOOL_CACHE", str(Path(tempfile.gettempdir()) / "fm-azure-runner-tools")))
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(cache, 0o700)
    lock_path = cache / ".lock"
    tools = (
        (
            "shellcheck.tar.xz",
            "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz",
            "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198",
            SHELLCHECK_ARCHIVE_BYTES,
        ),
        (
            "uv.tar.gz",
            "https://github.com/astral-sh/uv/releases/download/0.9.10/uv-x86_64-unknown-linux-gnu.tar.gz",
            "440c4215b171e64061d65d16a23753dd25c29a7f7b1b0446c9e9aed0fa372f27",
            UV_ARCHIVE_BYTES,
        ),
    )
    with open(lock_path, "a+", encoding="utf-8") as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        for name, url, digest, size in tools:
            cached = cache / name
            if not cached.exists() or cached.stat().st_size != size or sha256_file(cached) != digest:
                with contextlib.suppress(FileNotFoundError):
                    cached.unlink()
                download_pinned(url, cached, digest, size)
    destinations = []
    for name, _, digest, size in tools:
        source = cache / name
        destination = payload_dir / name
        shutil.copyfile(source, destination)
        os.chmod(destination, 0o600)
        if destination.stat().st_size != size or sha256_file(destination) != digest:
            raise RunnerError("copied pinned tool closure identity mismatch")
        destinations.append(destination)
    return tuple(destinations)


def prepare_locked_python_closure(repo, payload_dir):
    lock_path = repo / "tools" / "agent-fleet" / "uv.lock"
    if not lock_path.is_file():
        raise RunnerError("locked Agent Fleet Python closure is absent from the exact snapshot")
    lock_text = lock_path.read_text(encoding="utf-8")
    wheels = []
    for block in lock_text.split("[[package]]")[1:]:
        name_match = re.search(r'^name = "([^"]+)"$', block, re.MULTILINE)
        version_match = re.search(r'^version = "([^"]+)"$', block, re.MULTILINE)
        if not name_match or not version_match or "source = { registry = " not in block:
            continue
        name = name_match.group(1)
        candidates = [
            {"url": match.group(1), "digest": match.group(2), "bytes": int(match.group(3))}
            for match in re.finditer(
                r'\{ url = "([^"]+\.whl)", hash = "(sha256:[0-9a-f]{64})", size = ([0-9]+),', block
            )
        ]
        selected = next((item for item in candidates if item["url"].endswith("-py3-none-any.whl")), None)
        if name == "colorama":
            continue
        if name == "ruff":
            selected = next((item for item in candidates if "manylinux2014_x86_64.whl" in item["url"]), None)
        if selected is None:
            raise RunnerError("locked Agent Fleet package has no reviewed Linux x86_64 wheel: {}".format(name))
        wheels.append({
            "name": name,
            "version": version_match.group(1),
            "file": selected["url"].rsplit("/", 1)[-1],
            "url": selected["url"],
            "digest": selected["digest"],
            "bytes": selected["bytes"],
        })
    if {item["name"] for item in wheels} != {"iniconfig", "packaging", "pluggy", "pygments", "pytest", "ruff"}:
        raise RunnerError("locked Agent Fleet Linux wheel set differs from the reviewed closure")
    cache = Path(os.environ.get(
        "FM_AZURE_RUNNER_TOOL_CACHE", str(Path(tempfile.gettempdir()) / "fm-azure-runner-tools")
    )) / "agent-fleet-wheels"
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(cache / ".lock", "a+", encoding="utf-8") as handle:
        os.chmod(cache / ".lock", 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        for item in wheels:
            destination = cache / item["file"]
            digest = item["digest"].split(":", 1)[1]
            if not destination.exists() or destination.stat().st_size != item["bytes"] or sha256_file(destination) != digest:
                with contextlib.suppress(FileNotFoundError):
                    destination.unlink()
                download_pinned(item["url"], destination, digest, item["bytes"])
    archive_path = payload_dir / "agent-fleet-wheelhouse.tar"
    with tarfile.open(archive_path, "w", format=tarfile.PAX_FORMAT) as archive:
        for item in sorted(wheels, key=lambda value: value["file"]):
            source = cache / item["file"]
            info = archive.gettarinfo(str(source), arcname=item["file"])
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            with open(source, "rb") as source_handle:
                archive.addfile(info, source_handle)
    return archive_path, {
        "lock_digest": "sha256:" + sha256_file(lock_path),
        "archive_digest": "sha256:" + sha256_file(archive_path),
        "archive_bytes": archive_path.stat().st_size,
        "wheels": [{key: item[key] for key in ("name", "version", "file", "digest", "bytes")} for item in wheels],
    }


def tree_digest(repo, relative):
    path = repo / relative
    if not path.exists():
        raise RunnerError("declared dependency is absent: {}".format(relative))
    if path.is_symlink():
        raise RunnerError("declared dependency may not be a symlink: {}".format(relative))
    if path.is_file():
        return "sha256:" + sha256_file(path), path.stat().st_size
    digest = hashlib.sha256()
    total = 0
    for child in sorted(path.rglob("*")):
        if child.is_symlink():
            raise RunnerError("declared dependency tree contains a symlink: {}".format(child.relative_to(repo)))
        if child.is_file():
            relative_child = child.relative_to(repo).as_posix().encode("utf-8")
            content_digest = sha256_file(child).encode("ascii")
            size = child.stat().st_size
            total += size
            digest.update(len(relative_child).to_bytes(4, "big"))
            digest.update(relative_child)
            digest.update(content_digest)
            digest.update(size.to_bytes(8, "big"))
    return "sha256:" + digest.hexdigest(), total


def prepare(env, args, parent_state=None):
    repo = Path(args.repo or os.getcwd()).resolve()
    top = Path(git(repo, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
    if top != repo:
        repo = top
    dirty = git(repo, "status", "--porcelain", "--untracked-files=all").stdout
    if dirty:
        raise RunnerError("repository must be an exact clean committed snapshot; tracked or untracked changes are present")
    branch = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    if branch.returncode != 0:
        raise RunnerError("repository must be on a named committed branch")
    commit = git(repo, "rev-parse", "HEAD").stdout.strip()
    tree = git(repo, "rev-parse", "HEAD^{tree}").stdout.strip()
    if not re.match(r"^[0-9a-f]{40,64}$", commit) or not re.match(r"^[0-9a-f]{40,64}$", tree):
        raise RunnerError("repository commit/tree identity is malformed")

    task = require_identifier("task", args.task)
    generation = require_identifier("generation", args.generation)
    resource_class = args.resource_class
    if resource_class not in RESOURCE_CLASSES:
        raise RunnerError("unknown resource class: {}".format(resource_class))
    limits = dict(RESOURCE_CLASSES[resource_class])
    selected_sku = os.environ.get("FM_AZURE_RUNNER_SKU", "Standard_D4as_v6")
    if selected_sku not in SKU_FAMILY:
        raise RunnerError("runner SKU is not reviewed")
    limits["sku"] = selected_sku
    limits["sku_family"] = SKU_FAMILY[selected_sku]
    if args.wall_seconds is not None:
        if args.wall_seconds < 60 or args.wall_seconds > limits["wall_seconds"]:
            raise RunnerError("wall time override must be between 60 and the resource-class maximum")
        limits["wall_seconds"] = args.wall_seconds

    attempt = 1 if parent_state is None else int(parent_state["attempt"]) + 1
    invocation = require_invocation(args.invocation or new_invocation(attempt))
    fence = "sha256:" + sha256_bytes(os.urandom(32))
    payload_dir = env["state_dir"] / "payloads" / invocation
    if payload_dir.exists():
        raise RunnerError("invocation payload directory already exists")
    payload_dir.mkdir(parents=True, mode=0o700)
    os.chmod(payload_dir, 0o700)
    bundle_path = payload_dir / "snapshot.bundle"
    run(["git", "-C", str(repo), "bundle", "create", str(bundle_path), "HEAD"])
    run(["git", "bundle", "verify", str(bundle_path)])
    if bundle_path.stat().st_size > MAX_STAGING_INPUT_BYTES:
        raise RunnerError("reachable committed snapshot history exceeds the bounded staging input allowance")
    snapshot_digest = "sha256:" + sha256_file(bundle_path)

    dependencies = []
    for relative in args.dependency or []:
        relative = require_artifact(relative)
        if relative in (".", ".git") or relative.startswith(".git/"):
            raise RunnerError("declared dependency may not name the repository root or Git internals")
        tracked = git(repo, "ls-files", "--", relative).stdout.splitlines()
        tree_entry = git(repo, "cat-file", "-e", "HEAD:" + relative, check=False)
        if not tracked and tree_entry.returncode != 0:
            raise RunnerError("declared dependency is not part of the exact committed snapshot: {}".format(relative))
        digest, size = tree_digest(repo, relative)
        dependencies.append({"path": relative, "digest": digest, "bytes": size})
    artifacts = sorted(set(require_artifact(value) for value in (args.artifact or [])))
    command = {"argv": list(args.command)}
    if not command["argv"]:
        raise RunnerError("a command argv is required after --")
    if any("\x00" in value for value in command["argv"]):
        raise RunnerError("command argv contains NUL")
    command_digest = "sha256:" + sha256_bytes(canonical_bytes(command))
    locked_python_path, locked_python = prepare_locked_python_closure(repo, payload_dir)
    prepared_at = now_utc()
    expires_at = prepared_at + dt.timedelta(hours=TTL_SCHEDULE_HOURS_AFTER_PREPARATION)
    request = {
        "schema": SCHEMA,
        "home_binding": env["home_binding"],
        "task": task,
        "generation": generation,
        "deployment_generation": env["deployment_generation"],
        "invocation": invocation,
        "attempt": attempt,
        "parent_invocation": parent_state["invocation"] if parent_state else None,
        "lineage_root_invocation": (
            parent_state["request"].get("lineage_root_invocation", parent_state["invocation"])
            if parent_state else invocation
        ),
        "fence": fence,
        "repository": {
            "commit": commit,
            "tree": tree,
            "snapshot_digest": snapshot_digest,
            "snapshot_bytes": bundle_path.stat().st_size,
        },
        "command": command,
        "command_digest": command_digest,
        "resource_class": resource_class,
        "limits": limits,
        "dependencies": dependencies,
        "artifacts": artifacts,
        "protocol": {
            "guest_digest": "sha256:" + sha256_file(GUEST),
            "executor_digest": "sha256:" + sha256_file(EXECUTOR),
            "shellcheck_archive_digest": "sha256:8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198",
            "uv_archive_digest": "sha256:440c4215b171e64061d65d16a23753dd25c29a7f7b1b0446c9e9aed0fa372f27",
            "agent_fleet_python": locked_python,
        },
        "created_at": iso_utc(prepared_at),
        "compute_deallocation_deadline": iso_utc(expires_at),
    }
    request_digest = "sha256:" + sha256_bytes(canonical_bytes(request))
    request["request_digest"] = request_digest
    request_path = payload_dir / "request.json"
    request_path.write_bytes(canonical_bytes(request) + b"\n")
    os.chmod(request_path, 0o600)
    executor_path = payload_dir / "runner-exec.py"
    shutil.copyfile(EXECUTOR, executor_path)
    os.chmod(executor_path, 0o600)
    shellcheck_path, uv_archive_path = prepare_tool_closure(payload_dir)
    input_path = payload_dir / "input.tar.gz"
    with tarfile.open(input_path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for source, name in (
            (request_path, "request.json"),
            (bundle_path, "snapshot.bundle"),
            (executor_path, "runner-exec.py"),
            (shellcheck_path, "shellcheck.tar.xz"),
            (uv_archive_path, "uv.tar.gz"),
            (locked_python_path, "agent-fleet-wheelhouse.tar"),
        ):
            info = archive.gettarinfo(str(source), arcname=name)
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mtime = 0
            with open(source, "rb") as handle:
                archive.addfile(info, handle)
    if input_path.stat().st_size > MAX_STAGING_INPUT_BYTES:
        raise RunnerError("staged snapshot and pinned tool closure exceed the bounded input allowance")
    input_digest = "sha256:" + sha256_file(input_path)
    token = invocation.split("-")[1]
    vm_name = "vm-{}-run-{}".format(env["prefix"], token)
    nic_name = "nic-{}-run-{}".format(env["prefix"], token)
    disk_name = "disk-{}-run-{}-os".format(env["prefix"], token)
    staging_prefix = "{}/{}/{}/{}/attempt-{}".format(
        env["home_binding"].split(":", 1)[1][:16], task, generation, invocation, attempt
    )
    state = {
        "schema": SCHEMA,
        "invocation": invocation,
        "attempt": attempt,
        "parent_invocation": parent_state["invocation"] if parent_state else None,
        "phase": "prepared",
        "created_at": iso_utc(),
        "request": request,
        "request_digest": request_digest,
        "input_digest": input_digest,
        "input_bytes": input_path.stat().st_size,
        "input_path": str(input_path),
        "repository_root": str(repo),
        "staging": {
            "container": CONTAINER,
            "input_blob": staging_prefix + "/input.tar.gz",
            "output_blob": staging_prefix + "/result.tar.gz",
            "admission_blob": "runner-control/admission.lock",
            "reservation_blob": "runner-control/reservations.json",
        },
        "resources": {
            "deployment": "fm-run-{}".format(token),
            "vm_name": vm_name,
            "nic_name": nic_name,
            "os_disk_name": disk_name,
            "vm_id": "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Compute/virtualMachines/{}".format(env["subscription"], env["resource_group"], vm_name),
            "nic_id": "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Network/networkInterfaces/{}".format(env["subscription"], env["resource_group"], nic_name),
            "os_disk_id": "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Compute/disks/{}".format(env["subscription"], env["resource_group"], disk_name),
            "run_command_name": "execute",
            "safety_run_command_name": "safety-shutdown",
            "ttl_schedule_name": "shutdown-{}".format(vm_name),
            "ttl_schedule_id": "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.DevTestLab/schedules/shutdown-{}".format(
                env["subscription"], env["resource_group"], vm_name
            ),
            "identities": {},
        },
        "events": [{"at": iso_utc(), "phase": "prepared", "note": "clean snapshot and digest-bound request created"}],
    }
    save_state(env, state, create=True)
    return state


def az_command(env, args, check=True, parse_json=True, timeout_seconds=LOCAL_COMMAND_TIMEOUT_SECONDS):
    record_azure_operation(env, args)
    command = ["az"] + list(args) + ["--subscription", env["subscription"], "--only-show-errors"]
    if parse_json and "--output" not in command and "-o" not in command:
        command += ["--output", "json"]
    result = run(command, check=check, timeout_seconds=timeout_seconds)
    if not parse_json:
        return result.stdout.strip(), result.returncode, result.stderr.strip()
    if result.returncode != 0:
        return None, result.returncode, result.stderr.strip()
    try:
        return json.loads(result.stdout or "null"), result.returncode, result.stderr.strip()
    except json.JSONDecodeError as exc:
        raise RunnerError("Azure CLI returned malformed JSON for {}: {}".format(" ".join(args), exc))


def scope_gate(env):
    account, _, _ = az_command(env, ["account", "show"])
    if account.get("id") != env["subscription"] or account.get("tenantId") != env["tenant"] or account.get("state") != "Enabled":
        raise RunnerError("selected tenant/subscription is not the exact enabled runner scope")


def exact_id(env, provider, resource_type, name):
    return "/subscriptions/{}/resourceGroups/{}/providers/{}/{}/{}".format(
        env["subscription"], env["resource_group"], provider, resource_type, name
    )


def verify_foundation_tags(env, resource, label):
    tags = resource.get("tags") or {}
    if tags.get("workload") != "firstmate" or tags.get("deployment-generation") != env["deployment_generation"] or tags.get("cleanup-owner") != env["owner"]:
        raise RunnerError("foundation {} owner/generation identity is not exact".format(label))


def foundation_gate(env):
    storage_id = exact_id(env, "Microsoft.Storage", "storageAccounts", env["storage"])
    vnet_id = exact_id(env, "Microsoft.Network", "virtualNetworks", env["vnet"])
    subnet_id = vnet_id + "/subnets/" + env["subnet"]
    nsg_id = exact_id(env, "Microsoft.Network", "networkSecurityGroups", env["elastic_nsg"])
    nat_id = exact_id(env, "Microsoft.Network", "natGateways", env["nat"])
    public_ip_id = exact_id(env, "Microsoft.Network", "publicIPAddresses", "pip-{}-nat-eus".format(env["prefix"]))
    endpoint_id = exact_id(env, "Microsoft.Network", "privateEndpoints", env["blob_private_endpoint"])
    endpoint_nic_id = exact_id(env, "Microsoft.Network", "networkInterfaces", env["blob_private_endpoint_nic"])
    private_subnet_id = vnet_id + "/subnets/snet-private-endpoints"
    dns_zone_id = "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Network/privateDnsZones/{}".format(
        env["subscription"], env["resource_group"], env["blob_private_dns_zone"]
    )
    dns_link_id = dns_zone_id + "/virtualNetworkLinks/firstmate-vnet"

    storage, _, _ = az_command(env, ["resource", "show", "--ids", storage_id, "--api-version", "2023-05-01"])
    verify_foundation_tags(env, storage, "storage")
    properties = storage.get("properties", storage)
    network_acls = properties.get("networkAcls") or {}
    if (
        str(storage.get("id", "")).lower() != storage_id.lower()
        or storage.get("location") != "eastus"
        or storage.get("kind") != "StorageV2"
        or (storage.get("sku") or {}).get("name") != "Standard_ZRS"
        or properties.get("accessTier") != "Hot"
        or properties.get("defaultToOAuthAuthentication") is not True
        or properties.get("publicNetworkAccess") != "Disabled"
        or properties.get("allowSharedKeyAccess") is not False
        or properties.get("allowBlobPublicAccess") is not False
        or properties.get("supportsHttpsTrafficOnly") is not True
        or properties.get("minimumTlsVersion") != "TLS1_2"
        or network_acls.get("defaultAction") != "Deny"
        or network_acls.get("bypass") != "None"
    ):
        raise RunnerError("foundation storage identity/private-security contract is not exact")

    vnet, _, _ = az_command(env, ["resource", "show", "--ids", vnet_id, "--api-version", "2023-09-01"])
    verify_foundation_tags(env, vnet, "VNet")
    if (
        str(vnet.get("id", "")).lower() != vnet_id.lower()
        or vnet.get("location") != "eastus"
        or vnet.get("properties", {}).get("addressSpace", {}).get("addressPrefixes") != ["10.42.0.0/16"]
    ):
        raise RunnerError("foundation VNet identity is not exact")
    subnet, _, _ = az_command(env, ["resource", "show", "--ids", subnet_id, "--api-version", "2023-09-01"])
    subnet_properties = subnet.get("properties", subnet)
    if (
        str(subnet.get("id", "")).lower() != subnet_id.lower()
        or subnet_properties.get("addressPrefix") != "10.42.7.0/24"
        or str((subnet_properties.get("networkSecurityGroup") or {}).get("id", "")).lower() != nsg_id.lower()
        or str((subnet_properties.get("natGateway") or {}).get("id", "")).lower() != nat_id.lower()
        or subnet_properties.get("privateEndpointNetworkPolicies") != "Enabled"
    ):
        raise RunnerError("runner subnet exact private binding is not exact")
    private_subnet, _, _ = az_command(env, [
        "resource", "show", "--ids", private_subnet_id, "--api-version", "2023-09-01",
    ])
    private_subnet_properties = private_subnet.get("properties", private_subnet)
    if (
        str(private_subnet.get("id", "")).lower() != private_subnet_id.lower()
        or private_subnet_properties.get("addressPrefix") != "10.42.3.0/27"
        or private_subnet_properties.get("privateEndpointNetworkPolicies") != "Disabled"
        or private_subnet_properties.get("networkSecurityGroup")
        or private_subnet_properties.get("natGateway")
    ):
        raise RunnerError("private-endpoint subnet exact isolation is not exact")

    nsg, _, _ = az_command(env, ["resource", "show", "--ids", nsg_id, "--api-version", "2023-09-01"])
    verify_foundation_tags(env, nsg, "NSG")
    rules = nsg.get("properties", {}).get("securityRules", [])
    rule_fields = (
        "priority", "access", "direction", "protocol", "sourcePortRange", "destinationPortRange",
        "sourceAddressPrefix", "destinationAddressPrefix",
    )
    actual_rules = {
        rule.get("name"): {field: rule.get("properties", {}).get(field) for field in rule_fields}
        for rule in rules
    }
    expected_rules = {
        "deny-public-inbound": dict(zip(rule_fields, (100, "Deny", "Inbound", "*", "*", "*", "Internet", "*"))),
        "deny-vnet-cross-compartment-inbound": dict(zip(rule_fields, (110, "Deny", "Inbound", "*", "*", "*", "VirtualNetwork", "*"))),
    }
    if (
        str(nsg.get("id", "")).lower() != nsg_id.lower()
        or nsg.get("location") != "eastus"
        or actual_rules != expected_rules
    ):
        raise RunnerError("runner NSG identity or deny rules are not exact")

    public_ip, _, _ = az_command(env, ["resource", "show", "--ids", public_ip_id, "--api-version", "2023-09-01"])
    verify_foundation_tags(env, public_ip, "NAT public IP")
    public_ip_properties = public_ip.get("properties", public_ip)
    if (
        str(public_ip.get("id", "")).lower() != public_ip_id.lower()
        or public_ip.get("location") != "eastus"
        or (public_ip.get("sku") or {}).get("name") != "Standard"
        or public_ip_properties.get("publicIPAllocationMethod") != "Static"
        or public_ip_properties.get("publicIPAddressVersion") != "IPv4"
        or public_ip_properties.get("idleTimeoutInMinutes") != 4
    ):
        raise RunnerError("runner NAT public IP identity is not exact")

    nat, _, _ = az_command(env, ["resource", "show", "--ids", nat_id, "--api-version", "2023-09-01"])
    verify_foundation_tags(env, nat, "NAT")
    nat_properties = nat.get("properties", nat)
    if (
        str(nat.get("id", "")).lower() != nat_id.lower()
        or nat.get("location") != "eastus"
        or (nat.get("sku") or {}).get("name") != "Standard"
        or nat_properties.get("idleTimeoutInMinutes") != 10
        or [str(item.get("id", "")).lower() for item in nat_properties.get("publicIpAddresses", [])]
        != [public_ip_id.lower()]
    ):
        raise RunnerError("runner NAT identity is not exact")

    endpoint, _, _ = az_command(env, ["resource", "show", "--ids", endpoint_id, "--api-version", "2023-09-01"])
    verify_foundation_tags(env, endpoint, "private endpoint")
    endpoint_properties = endpoint.get("properties", endpoint)
    connections = endpoint_properties.get("privateLinkServiceConnections", [])
    if len(connections) != 1:
        raise RunnerError("blob private-link connection is absent or ambiguous")
    connection = connections[0]
    connection_properties = connection.get("properties", connection)
    status = (connection_properties.get("privateLinkServiceConnectionState") or {}).get("status")
    if (
        str(endpoint.get("id", "")).lower() != endpoint_id.lower()
        or endpoint.get("location") != "eastus"
        or str((endpoint_properties.get("subnet") or {}).get("id", "")).lower() != private_subnet_id.lower()
        or connection.get("name") != "blob"
        or str(connection_properties.get("privateLinkServiceId", "")).lower() != storage_id.lower()
        or connection_properties.get("groupIds") != ["blob"]
        or status != "Approved"
        or len(endpoint_properties.get("networkInterfaces", [])) != 1
    ):
        raise RunnerError("foundation blob private endpoint identity/approval is not exact")

    deployment, _, _ = az_command(env, [
        "deployment", "sub", "show", "--name", "fm-azure-pilot-{}".format(env["deployment_generation"]),
    ])
    outputs = deployment.get("properties", {}).get("outputs") or deployment.get("outputs") or {}
    recorded_nic_id = (outputs.get("blobPrivateEndpointNicId") or {}).get("value")
    recorded_nic_guid = (outputs.get("blobPrivateEndpointNicResourceGuid") or {}).get("value")
    if (
        str(recorded_nic_id).lower() != endpoint_nic_id.lower()
        or str(recorded_nic_guid).lower() != env["blob_private_endpoint_nic_resource_guid"]
        or [str(item.get("id", "")).lower() for item in endpoint_properties["networkInterfaces"]]
        != [endpoint_nic_id.lower()]
    ):
        raise RunnerError("foundation deployment output does not bind the exact blob private-endpoint NIC")
    endpoint_nic, _, _ = az_command(env, ["resource", "show", "--ids", endpoint_nic_id, "--api-version", "2023-09-01"])
    verify_foundation_tags(env, endpoint_nic, "private-endpoint NIC")
    endpoint_nic_properties = endpoint_nic.get("properties", endpoint_nic)
    endpoint_ip_configs = endpoint_nic_properties.get("ipConfigurations", [])
    if (
        str(endpoint_nic.get("id", "")).lower() != endpoint_nic_id.lower()
        or str(endpoint_nic_properties.get("resourceGuid", "")).lower()
        != env["blob_private_endpoint_nic_resource_guid"]
        or str((endpoint_nic_properties.get("privateEndpoint") or {}).get("id", "")).lower() != endpoint_id.lower()
        or endpoint_nic_properties.get("virtualMachine")
        or len(endpoint_ip_configs) != 1
        or str((endpoint_ip_configs[0].get("properties", {}).get("subnet") or {}).get("id", "")).lower()
        != private_subnet_id.lower()
    ):
        raise RunnerError("foundation blob private-endpoint NIC identity is not exact")

    dns_zone, _, _ = az_command(env, ["resource", "show", "--ids", dns_zone_id, "--api-version", "2020-06-01"])
    verify_foundation_tags(env, dns_zone, "private DNS zone")
    if str(dns_zone.get("id", "")).lower() != dns_zone_id.lower() or dns_zone.get("location") != "global":
        raise RunnerError("foundation blob private-DNS zone identity is not exact")
    dns_link, _, _ = az_command(env, ["resource", "show", "--ids", dns_link_id, "--api-version", "2020-06-01"])
    dns_link_properties = dns_link.get("properties", dns_link)
    if (
        str(dns_link.get("id", "")).lower() != dns_link_id.lower()
        or dns_link.get("location") != "global"
        or dns_link_properties.get("registrationEnabled") is not False
        or str((dns_link_properties.get("virtualNetwork") or {}).get("id", "")).lower() != vnet_id.lower()
    ):
        raise RunnerError("foundation blob private-DNS VNet link identity is not exact")

    dns_group_id = endpoint_id + "/privateDnsZoneGroups/default"
    dns_group, _, _ = az_command(env, ["resource", "show", "--ids", dns_group_id, "--api-version", "2023-09-01"])
    configs = dns_group.get("properties", {}).get("privateDnsZoneConfigs", [])
    if (
        str(dns_group.get("id", "")).lower() != dns_group_id.lower()
        or len(configs) != 1
        or configs[0].get("name") != "blob"
        or str(configs[0].get("properties", {}).get("privateDnsZoneId", "")).lower() != dns_zone_id.lower()
    ):
        raise RunnerError("foundation blob private-DNS binding is not exact")


def sku_quota_gate(env, limits):
    skus, _, _ = az_command(env, ["vm", "list-skus", "--location", "eastus", "--resource-type", "virtualMachines", "--all"])
    matching = [item for item in skus if item.get("name") == limits["sku"]]
    if len(matching) != 1 or matching[0].get("restrictions"):
        raise RunnerError("runner SKU is unavailable or restricted")
    capabilities = {item.get("name"): item.get("value") for item in matching[0].get("capabilities", [])}
    if int(capabilities.get("vCPUsAvailable", "0")) < SKU_VCPUS[limits["sku"]] or float(capabilities.get("MemoryGB", "0")) < SKU_MEMORY_GIB[limits["sku"]]:
        raise RunnerError("runner SKU no longer satisfies the reviewed CPU/memory class")
    if capabilities.get("CpuArchitectureType") != "x64" or "V2" not in capabilities.get("HyperVGenerations", ""):
        raise RunnerError("runner SKU no longer satisfies x64 Gen2")
    if capabilities.get("TrustedLaunchDisabled") == "True" or capabilities.get("EncryptionAtHostSupported") != "True":
        raise RunnerError("runner SKU no longer satisfies Trusted Launch/encryption-at-host")
    usage, _, _ = az_command(env, ["vm", "list-usage", "--location", "eastus"])
    wanted = ("cores", SKU_FAMILY[limits["sku"]].lower())
    free = {}
    for item in usage:
        name = str(item.get("name", {}).get("value", "")).lower()
        free[name] = int(item.get("limit", 0)) - int(item.get("currentValue", 0))
    required = SKU_VCPUS[limits["sku"]]
    current_active = active_runner_vms(env)
    same_family_active = sum(
        1
        for vm in current_active
        if (vm.get("tags") or {}).get("sku-family") == SKU_FAMILY[limits["sku"]]
    )
    remaining_slots = free.get(wanted[1], 0) // required
    if free.get("cores", 0) < required or free.get(wanted[1], 0) < required or remaining_slots < 1:
        raise RunnerError("regional or exact runner-family free vCPU quota is insufficient")
    return {"family_free_vcpus": free.get(wanted[1], 0), "family_active": same_family_active}


def write_private_json(env, prefix, value):
    ensure_state_dirs(env)
    fd, name = tempfile.mkstemp(prefix=prefix, suffix=".json", dir=str(env["state_dir"]))
    os.chmod(name, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, separators=(",", ":"))
        handle.write("\n")
    return Path(name)


def cost_query(env, forecast=False, invocation=None, reserved_at=None):
    endpoint = "forecast" if forecast else "query"
    url = "https://management.azure.com/subscriptions/{}/providers/Microsoft.CostManagement/{}?api-version=2023-11-01".format(
        env["subscription"], endpoint
    )
    body = {
        "type": "Usage",
        "timeframe": "MonthToDate",
        "dataset": {
            "granularity": "None",
            "aggregation": {"totalCost": {"name": "PreTaxCost", "function": "Sum"}},
            "filter": {"dimensions": {"name": "ResourceGroupName", "operator": "In", "values": [env["resource_group"]]}},
        },
    }
    if invocation is not None:
        body["timeframe"] = "Custom"
        start = dt.datetime.fromisoformat(reserved_at.replace("Z", "+00:00"))
        body["timePeriod"] = {
            "from": start.replace(hour=0, minute=0, second=0, microsecond=0).isoformat().replace("+00:00", "Z"),
            "to": (now_utc() + dt.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0).isoformat().replace("+00:00", "Z"),
        }
        body["dataset"]["filter"] = {
            "and": [
                {"dimensions": {"name": "ResourceGroupName", "operator": "In", "values": [env["resource_group"]]}},
                {"tags": {"name": "invocation-binding", "operator": "In", "values": [invocation]}},
            ]
        }
    if forecast:
        today = now_utc().date()
        month_start = today.replace(day=1)
        if month_start.month == 12:
            month_end = month_start.replace(year=month_start.year + 1, month=1)
        else:
            month_end = month_start.replace(month=month_start.month + 1)
        body["timeframe"] = "Custom"
        body["timePeriod"] = {
            "from": month_start.isoformat() + "T00:00:00Z",
            "to": month_end.isoformat() + "T00:00:00Z",
        }
    path = write_private_json(env, ".cost-", body)
    try:
        result, _, _ = az_command(env, ["rest", "--method", "post", "--url", url, "--body", "@" + str(path)])
    finally:
        path.unlink(missing_ok=True)
    properties = result.get("properties", result)
    columns = properties.get("columns", [])
    rows = properties.get("rows", [])
    names = [column.get("name", "") for column in columns]
    if not rows:
        return 0.0
    index = names.index("PreTaxCost") if "PreTaxCost" in names else 0
    try:
        return float(rows[0][index])
    except (IndexError, TypeError, ValueError):
        raise RunnerError("Azure cost result did not contain a readable PreTaxCost")


def retail_rate(env, sku):
    escaped = sku.replace("_", "%5F")
    url = (
        "https://prices.azure.com/api/retail/prices?%24filter="
        "armRegionName%20eq%20%27eastus%27%20and%20armSkuName%20eq%20%27{}%27%20and%20priceType%20eq%20%27Consumption%27"
    ).format(escaped)
    result, _, _ = az_command(env, ["rest", "--method", "get", "--url", url, "--skip-authorization-header"])
    prices = []
    for item in result.get("Items", []):
        product = str(item.get("productName", "")).lower()
        meter = str(item.get("meterName", "")).lower()
        if item.get("unitOfMeasure") == "1 Hour" and "windows" not in product and "spot" not in meter:
            with contextlib.suppress(TypeError, ValueError):
                prices.append(float(item["retailPrice"]))
    if not prices:
        raise RunnerError("current runner retail rate is unreadable")
    return min(prices)


def itemized_cost_bound(rate, hours, limits):
    rate_bound_bytes = BOOTSTRAP_RATE_BITS_PER_SECOND * 3600 * hours // 8
    vm_network_bytes = min(MAX_BOOTSTRAP_NETWORK_BYTES, rate_bound_bytes)
    bootstrap_bytes = min(
        MAX_BOOTSTRAP_NETWORK_BYTES,
        SHELLCHECK_ARCHIVE_BYTES + UV_ARCHIVE_BYTES + MAX_STAGING_INPUT_BYTES + MAX_RESULT_UPLOAD_BYTES + vm_network_bytes,
    )
    bootstrap_gib = bootstrap_bytes / float(1024**3)
    categories = {
        "vm_compute": rate * hours,
        "os_disk_storage_capacity": METER_RATE_CEILINGS_USD["os_disk_storage_capacity"] * hours,
        "nat_gateway": METER_RATE_CEILINGS_USD["nat_gateway"] * hours,
        "public_ip": METER_RATE_CEILINGS_USD["public_ip"] * hours,
        "private_endpoints": METER_RATE_CEILINGS_USD["private_endpoints"] * hours,
        "private_dns": METER_RATE_CEILINGS_USD["private_dns"] * hours,
        "monitoring": METER_RATE_CEILINGS_USD["monitoring"] * hours,
        "boot_diagnostics": METER_RATE_CEILINGS_USD["boot_diagnostics"] * hours,
        "storage_capacity": METER_RATE_CEILINGS_USD["storage_capacity"] * hours,
        "storage_operations": STORAGE_OPERATION_RESERVE_USD,
        "control_operations": CONTROL_OPERATION_RESERVE_USD,
        "provisioning_control_interval": METER_RATE_CEILINGS_USD["provisioning_control_interval"] * hours,
        "nat_data_processing": bootstrap_gib * NAT_DATA_GIB_RATE_CEILING_USD,
        "internet_egress": bootstrap_gib * INTERNET_EGRESS_GIB_RATE_CEILING_USD,
        "trusted_bootstrap_traffic": bootstrap_gib * BOOTSTRAP_GIB_RATE_CEILING_USD,
        "foundation_shared_meter_reserve": FOUNDATION_SHARED_METER_RESERVE_USD,
        "repository_command_egress": 0.0,
    }
    return {
        "hours": hours,
        "bootstrap_bytes": bootstrap_bytes,
        "vm_network_bytes": vm_network_bytes,
        "bootstrap_rate_bits_per_second": BOOTSTRAP_RATE_BITS_PER_SECOND,
        "control_operation_ceiling": RUNNER_CONTROL_OPERATION_CEILING,
        "storage_operation_ceiling": RUNNER_STORAGE_OPERATION_CEILING,
        "input_bytes": MAX_STAGING_INPUT_BYTES,
        "output_bytes": MAX_RESULT_UPLOAD_BYTES,
        "repository_command_network_bytes": limits["network_bytes"],
        "categories": categories,
        "post_deallocation_daily_floor": {
            "os_disk_storage_capacity": METER_RATE_CEILINGS_USD["os_disk_storage_capacity"] * 24,
            "storage_capacity": METER_RATE_CEILINGS_USD["storage_capacity"] * 24,
            "nat_gateway": METER_RATE_CEILINGS_USD["nat_gateway"] * 24,
            "public_ip": METER_RATE_CEILINGS_USD["public_ip"] * 24,
            "private_endpoints": METER_RATE_CEILINGS_USD["private_endpoints"] * 24,
            "private_dns": METER_RATE_CEILINGS_USD["private_dns"] * 24,
            "monitoring": METER_RATE_CEILINGS_USD["monitoring"] * 24,
        },
        "total": round(sum(categories.values()), 6),
    }


def budget_gate(env, limits, outstanding_reservations=0.0):
    actual = cost_query(env, forecast=False)
    forecast = cost_query(env, forecast=True)
    rate = retail_rate(env, limits["sku"])
    first_hour = itemized_cost_bound(rate, 1, limits)
    first_day = itemized_cost_bound(rate, MAX_BILLABLE_LIFETIME_HOURS, limits)
    maximum_increment = first_day["total"]
    pressure = max(actual, forecast) + outstanding_reservations + maximum_increment
    if pressure >= env["budget_limit"]:
        raise RunnerError("budget pressure stops new invocations (actual {:.2f}, forecast {:.2f}, outstanding reservations {:.2f}, first-hour {:.2f}, first-day {:.2f}, admitted ceiling {})".format(
            actual, forecast, outstanding_reservations, first_hour["total"], first_day["total"], env["budget_limit"]
        ))
    return {
        "actual": actual,
        "forecast": forecast,
        "hourly_rate": rate,
        "first_hour": first_hour,
        "first_day": first_day,
        "max_network_bytes": limits["network_bytes"],
        "max_billable_lifetime_hours": MAX_BILLABLE_LIFETIME_HOURS,
        "max_increment": maximum_increment,
        "outstanding_reservations": outstanding_reservations,
        "admission_pressure": pressure,
    }


def empty_reservation_ledger(env):
    return {
        "schema": "fm.azure-cost-reservations/v1",
        "subscription": env["subscription"],
        "resource_group": env["resource_group"],
        "storage": env["storage"],
        "container": CONTAINER,
        "deployment_generation": env["deployment_generation"],
        "reservations": {},
    }


def verify_reservation_ledger(env, ledger):
    expected = empty_reservation_ledger(env)
    for field in ("schema", "subscription", "resource_group", "storage", "container", "deployment_generation"):
        if ledger.get(field) != expected[field]:
            raise RunnerError("cost reservation ledger {} binding is not exact".format(field))
    if not isinstance(ledger.get("reservations"), dict):
        raise RunnerError("cost reservation ledger entries are malformed")


def load_reservation_ledger(env, state, lease):
    lease.assert_held()
    path = write_private_json(env, ".reservations-empty-", empty_reservation_ledger(env))
    try:
        _, rc, stderr = az_command(env, [
            "storage", "blob", "download", "--auth-mode", "login", "--account-name", env["storage"],
            "--container-name", CONTAINER, "--name", state["staging"]["reservation_blob"],
            "--file", str(path), "--overwrite", "true", "--lease-id", lease.reservation_lease_id,
        ], check=False)
        if rc != 0:
            raise RunnerError("leased cost reservation ledger is unavailable: {}".format(stderr))
        try:
            ledger = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RunnerError("cost reservation ledger is unreadable: {}".format(exc))
        verify_reservation_ledger(env, ledger)
        return ledger
    finally:
        path.unlink(missing_ok=True)


def save_reservation_ledger(env, state, ledger, lease):
    lease.assert_held()
    verify_reservation_ledger(env, ledger)
    path = write_private_json(env, ".reservations-", ledger)
    try:
        az_command(env, [
            "storage", "blob", "upload", "--auth-mode", "login", "--account-name", env["storage"],
            "--container-name", CONTAINER, "--name", state["staging"]["reservation_blob"],
            "--file", str(path), "--overwrite", "true", "--lease-id", lease.reservation_lease_id,
        ])
        lease.assert_held()
    finally:
        path.unlink(missing_ok=True)


def reservation_is_reconciled(env, entry, actual, forecast):
    invocation = entry.get("invocation")
    if not invocation or entry.get("cleanup_verified_at") is None:
        return False
    try:
        cleanup_at = dt.datetime.fromisoformat(entry["cleanup_verified_at"].replace("Z", "+00:00"))
        state = load_state(env, invocation)
    except (RunnerError, TypeError, ValueError):
        return False
    if state.get("phase") not in ("complete", "absent-fenced") or now_utc() < cleanup_at + dt.timedelta(hours=72):
        return False
    invocation_cost = cost_query(
        env, forecast=False, invocation=invocation, reserved_at=entry["reserved_at"]
    )
    entry.update({
        "status": "reconciled",
        "reconciled_at": iso_utc(),
        "reconciled_actual": actual,
        "reconciled_forecast": forecast,
        "reconciled_invocation_cost": invocation_cost,
    })
    return True


def reserve_budget(env, state, lease, limits):
    ledger = load_reservation_ledger(env, state, lease)
    preliminary = budget_gate(env, limits)
    for entry in ledger["reservations"].values():
        if entry.get("status") == "reserved":
            reservation_is_reconciled(env, entry, preliminary["actual"], preliminary["forecast"])
    existing = ledger["reservations"].get(state["invocation"])
    if existing is not None:
        if (
            existing.get("fence") != state["request"]["fence"]
            or existing.get("lineage_root") != state["request"]["lineage_root_invocation"]
        ):
            raise RunnerError("cost reservation invocation/fence lineage is not exact")
        return existing["cost_bound"]
    outstanding = sum(
        float(entry["amount_usd"])
        for entry in ledger["reservations"].values()
        if entry.get("status") == "reserved"
    )
    cost = budget_gate(env, limits, outstanding_reservations=outstanding)
    ledger["reservations"][state["invocation"]] = {
        "invocation": state["invocation"],
        "fence": state["request"]["fence"],
        "parent_invocation": state.get("parent_invocation"),
        "lineage_root": state["request"]["lineage_root_invocation"],
        "amount_usd": cost["max_increment"],
        "status": "reserved",
        "reserved_at": iso_utc(),
        "compute_deallocation_deadline": state["request"]["compute_deallocation_deadline"],
        "cost_bound": cost,
    }
    ledger["updated_at"] = iso_utc()
    save_reservation_ledger(env, state, ledger, lease)
    lease.assert_held()
    return cost


def mark_reservation_cleanup_verified(env, state):
    with AdmissionLease(env, state) as lease:
        ledger = load_reservation_ledger(env, state, lease)
        entry = ledger["reservations"].get(state["invocation"])
        if entry is None:
            raise RunnerError("cost reservation is absent after compute cleanup")
        if entry.get("fence") != state["request"]["fence"] or entry.get("status") != "reserved":
            raise RunnerError("cost reservation cleanup binding is not exact")
        entry["cleanup_verified_at"] = iso_utc()
        ledger["updated_at"] = iso_utc()
        save_reservation_ledger(env, state, ledger, lease)


def active_runner_vms(env):
    vms, _, _ = az_command(env, ["vm", "list", "--resource-group", env["resource_group"], "--show-details"])
    active = []
    for vm in vms:
        tags = vm.get("tags") or {}
        if tags.get("firstmate-role") != "validation-shard":
            continue
        power = str(vm.get("powerState", "")).lower()
        if "deallocated" not in power:
            active.append(vm)
    return active


def ensure_admission_blob(env, state):
    empty = env["state_dir"] / ".admission-empty"
    empty.touch(mode=0o600, exist_ok=True)
    args = [
        "storage", "blob", "upload", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", CONTAINER, "--name", state["staging"]["admission_blob"], "--file", str(empty),
        "--overwrite", "false",
    ]
    _, rc, _ = az_command(env, args, check=False)
    if rc != 0:
        exists, _, _ = az_command(env, [
            "storage", "blob", "exists", "--auth-mode", "login", "--account-name", env["storage"],
            "--container-name", CONTAINER, "--name", state["staging"]["admission_blob"],
        ])
        if not exists.get("exists"):
            raise RunnerError("admission-lock blob could not be created or proven present")


def ensure_reservation_blob(env, state):
    path = write_private_json(env, ".reservations-initial-", empty_reservation_ledger(env))
    try:
        _, rc, _ = az_command(env, [
            "storage", "blob", "upload", "--auth-mode", "login", "--account-name", env["storage"],
            "--container-name", CONTAINER, "--name", state["staging"]["reservation_blob"],
            "--file", str(path), "--overwrite", "false",
        ], check=False)
        if rc != 0:
            exists, _, _ = az_command(env, [
                "storage", "blob", "exists", "--auth-mode", "login", "--account-name", env["storage"],
                "--container-name", CONTAINER, "--name", state["staging"]["reservation_blob"],
            ])
            if not exists.get("exists"):
                raise RunnerError("cost reservation ledger blob could not be created or proven present")
    finally:
        path.unlink(missing_ok=True)


class AdmissionLease:
    def __init__(self, env, state):
        self.env = env
        self.state = state
        self.admission_lease_id = str(uuid.uuid4())
        self.reservation_lease_id = str(uuid.uuid4())
        self.stop = threading.Event()
        self.failed = threading.Event()
        self.thread = None
        self.renew_lock = threading.Lock()
        self.expiry_lock = threading.Lock()
        self.expires_at = {"admission": 0.0, "reservation": 0.0}

    def _lease_args(self, operation, blob_name, lease_id):
        args = [
            "storage", "blob", "lease", operation, "--auth-mode", "login", "--account-name", self.env["storage"],
            "--container-name", CONTAINER, "--blob-name", blob_name,
        ]
        if operation == "acquire":
            args += ["--lease-duration", "60", "--proposed-lease-id", lease_id]
        else:
            args += ["--lease-id", lease_id]
        return args

    def _lease_call(self, operation, blob_name, lease_id):
        return az_command(
            self.env, self._lease_args(operation, blob_name, lease_id), check=False,
            timeout_seconds=LEASE_RENEW_TIMEOUT_SECONDS,
        )

    def _record_success(self, label):
        with self.expiry_lock:
            self.expires_at[label] = time.monotonic() + LEASE_DURATION_SECONDS

    def __enter__(self):
        ensure_admission_blob(self.env, self.state)
        acquired = False
        for _ in range(7):
            _, rc, _ = self._lease_call(
                "acquire", self.state["staging"]["admission_blob"], self.admission_lease_id
            )
            if rc == 0:
                self._record_success("admission")
                acquired = True
                break
            time.sleep(10)
        if not acquired:
            raise RunnerError("runner admission lock is busy or unreachable")
        try:
            ensure_reservation_blob(self.env, self.state)
            _, reservation_rc, _ = self._lease_call(
                "acquire", self.state["staging"]["reservation_blob"], self.reservation_lease_id
            )
            if reservation_rc != 0:
                raise RunnerError("cost reservation ledger lease is busy or unreachable")
            self._record_success("reservation")
            self.renew_and_assert()
        except Exception:
            for blob_name, lease_id in (
                (self.state["staging"]["reservation_blob"], self.reservation_lease_id),
                (self.state["staging"]["admission_blob"], self.admission_lease_id),
            ):
                with contextlib.suppress(RunnerError):
                    self._lease_call("release", blob_name, lease_id)
            raise
        self.thread = threading.Thread(target=self._renew, daemon=True)
        self.thread.start()
        return self

    def _renew(self):
        while not self.stop.wait(25):
            try:
                self.renew_and_assert()
            except Exception:
                self.failed.set()
                return

    def renew_and_assert(self):
        try:
            with self.renew_lock:
                for blob_name, lease_id, label in (
                    (self.state["staging"]["admission_blob"], self.admission_lease_id, "admission"),
                    (self.state["staging"]["reservation_blob"], self.reservation_lease_id, "reservation"),
                ):
                    _, rc, stderr = self._lease_call("renew", blob_name, lease_id)
                    if rc != 0:
                        raise RunnerError("runner {} lease renewal failed: {}".format(label, stderr))
                    self._record_success(label)
        except Exception:
            self.failed.set()
            raise
        self.assert_held()

    def assert_held(self):
        if self.failed.is_set():
            raise RunnerError("runner admission lease renewal failed; no command was started")
        with self.expiry_lock:
            remaining = {
                label: expiry - time.monotonic()
                for label, expiry in self.expires_at.items()
            }
        stale = [label for label, seconds in remaining.items() if seconds <= LEASE_SAFETY_MARGIN_SECONDS]
        if stale:
            self.failed.set()
            raise RunnerError("runner lease expiry safety margin exhausted for {}; no command was started".format(
                ", ".join(sorted(stale))
            ))

    def __exit__(self, exc_type, exc, traceback):
        self.stop.set()
        if self.thread:
            self.thread.join(timeout=2)
        for blob_name, lease_id in (
            (self.state["staging"]["reservation_blob"], self.reservation_lease_id),
            (self.state["staging"]["admission_blob"], self.admission_lease_id),
        ):
            with contextlib.suppress(RunnerError):
                self._lease_call("release", blob_name, lease_id)


def storage_upload(env, local_path, blob, overwrite=False):
    args = [
        "storage", "blob", "upload", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", CONTAINER, "--name", blob, "--file", str(local_path),
        "--overwrite", "true" if overwrite else "false",
    ]
    az_command(env, args)


def storage_download(env, blob, local_path):
    az_command(env, [
        "storage", "blob", "download", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", CONTAINER, "--name", blob, "--file", str(local_path), "--overwrite", "true",
    ])


def storage_delete(env, blob):
    exists, _, _ = az_command(env, [
        "storage", "blob", "exists", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", CONTAINER, "--name", blob,
    ])
    if not exists.get("exists"):
        return
    _, rc, stderr = az_command(env, [
        "storage", "blob", "delete", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", CONTAINER, "--name", blob, "--delete-snapshots", "include",
    ], check=False)
    if rc != 0:
        raise RunnerError("exact staging blob deletion failed: {}".format(stderr))
    remains, _, _ = az_command(env, [
        "storage", "blob", "exists", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", CONTAINER, "--name", blob,
    ])
    if remains.get("exists"):
        raise RunnerError("exact staging blob remains after deletion")


def blob_sas(env, blob, permissions, expiry):
    stdout, rc, stderr = az_command(env, [
        "storage", "blob", "generate-sas", "--as-user", "--auth-mode", "login", "--https-only",
        "--account-name", env["storage"], "--container-name", CONTAINER, "--name", blob,
        "--permissions", permissions, "--expiry", expiry, "--full-uri", "--output", "tsv",
    ], parse_json=False)
    if rc != 0 or not stdout.startswith("https://"):
        raise RunnerError("object-scoped user-delegation SAS creation failed: {}".format(stderr))
    return stdout


def ownership_tags(env, state):
    request = state["request"]
    token = state["invocation"].split("-")[1]
    return {
        "workload": "firstmate",
        "firstmate-role": "validation-shard",
        "lifecycle": "one-invocation-disposable",
        "deployment-generation": env["deployment_generation"],
        "cleanup-owner": env["owner"],
        "home-binding": request["home_binding"],
        "task-binding": request["task"],
        "task-generation": request["generation"],
        "invocation-binding": state["invocation"],
        "attempt": str(state["attempt"]),
        "fence": request["fence"],
        "snapshot-digest": request["repository"]["snapshot_digest"],
        "command-digest": request["command_digest"],
        "resource-class": request["resource_class"],
        "selected-sku": request["limits"]["sku"],
        "sku-family": request["limits"]["sku_family"],
        "cost-attribution": "validation-shard",
        "expiry-utc": request["compute_deallocation_deadline"],
        "cleanup-token": token,
    }


def deployment_parameters(env, state):
    request = state["request"]
    resources = state["resources"]
    expiry = dt.datetime.fromisoformat(request["compute_deallocation_deadline"].replace("Z", "+00:00"))
    subnet_id = "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Network/virtualNetworks/{}/subnets/{}".format(
        env["subscription"], env["resource_group"], env["vnet"], env["subnet"]
    )
    tags = ownership_tags(env, state)
    return {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "region": {"value": "eastus"},
            "vmName": {"value": resources["vm_name"]},
            "nicName": {"value": resources["nic_name"]},
            "osDiskName": {"value": resources["os_disk_name"]},
            "subnetId": {"value": subnet_id},
            "vmSize": {"value": request["limits"]["sku"]},
            "expiryUtc": {"value": iso_utc(expiry)},
            "expiryTimeOfDay": {"value": expiry.strftime("%H%M")},
            "tags": {"value": tags},
        },
    }


def resource_url(resource_id, api_version):
    return "https://management.azure.com{}?api-version={}".format(resource_id, api_version)


def read_exact_resource(env, resource_id, kind):
    result, rc, stderr = az_command(env, [
        "rest", "--method", "get", "--url", resource_url(resource_id, RESOURCE_API_VERSIONS[kind]),
    ], check=False)
    if rc == 0:
        return True, result
    listing, list_rc, list_stderr = az_command(env, [
        "resource", "list", "--resource-group", env["resource_group"],
    ], check=False)
    if list_rc != 0:
        raise RunnerError("{} absence is ambiguous: {}; {}".format(kind, stderr, list_stderr))
    matches = [item for item in listing if str(item.get("id", "")).lower() == resource_id.lower()]
    if matches:
        raise RunnerError("{} exists but its full immutable identity is unreadable".format(kind))
    return False, None


def immutable_identity(resource, label):
    properties = resource.get("properties", resource)
    identity = {
        "id": str(resource.get("id", "")).lower(),
        "etag": resource.get("etag"),
    }
    if label == "vm":
        identity["instance_id"] = properties.get("vmId") or resource.get("vmId")
    elif label == "nic":
        identity["resource_guid"] = properties.get("resourceGuid") or resource.get("resourceGuid")
    elif label == "disk":
        identity["unique_id"] = properties.get("uniqueId") or resource.get("uniqueId")
    elif label == "run-command":
        identity["provisioning_state"] = properties.get("provisioningState")
    elif label == "ttl-schedule":
        identity["task_type"] = properties.get("taskType")
    required = {
        "vm": "instance_id",
        "nic": "resource_guid",
        "disk": "unique_id",
        "run-command": "provisioning_state",
        "ttl-schedule": "task_type",
    }[label]
    if not identity["id"] or not identity["etag"] or not identity.get(required):
        raise RunnerError("created {} immutable identity is incomplete".format(label))
    return identity


def adopt_vm_identity(env, state, vm):
    resources = state["resources"]
    vm_id = vm.get("id")
    vm_properties = vm.get("properties", vm)
    instance_id = vm_properties.get("vmId")
    nic_ids = [item.get("id") for item in vm_properties.get("networkProfile", {}).get("networkInterfaces", [])]
    os_disk_id = vm_properties.get("storageProfile", {}).get("osDisk", {}).get("managedDisk", {}).get("id")
    if (
        not vm_id
        or not instance_id
        or len(nic_ids) != 1
        or vm_id.lower() != resources["vm_id"].lower()
        or nic_ids[0].lower() != resources["nic_id"].lower()
        or str(os_disk_id).lower() != resources["os_disk_id"].lower()
    ):
        raise RunnerError("created VM identity inventory is incomplete or differs from the fenced plan")
    identities = {}
    for label, resource_id in (
        ("vm", resources["vm_id"]),
        ("nic", resources["nic_id"]),
        ("disk", resources["os_disk_id"]),
    ):
        exists, resource = read_exact_resource(env, resource_id, label)
        if not exists:
            raise RunnerError("created {} disappeared before immutable identity adoption".format(label))
        verify_resource_tags(env, state, resource, label)
        if label == "vm" and (resource.get("properties", {}).get("vmId") or resource.get("vmId")) != instance_id:
            raise RunnerError("created VM instance identity changed during adoption")
        if label == "nic" and str(resource.get("properties", {}).get("virtualMachine", {}).get("id", "")).lower() != resources["vm_id"].lower():
            raise RunnerError("created NIC is not managed by the exact VM")
        if label == "disk" and str(resource.get("managedBy") or resource.get("properties", {}).get("managedBy") or "").lower() != resources["vm_id"].lower():
            raise RunnerError("created OS disk is not managed by the exact VM")
        identities[label] = immutable_identity(resource, label)
    safety_id = resources["vm_id"] + "/runCommands/" + resources["safety_run_command_name"]
    exists, safety = read_exact_resource(env, safety_id, "run-command")
    if not exists:
        raise RunnerError("template safety Run Command disappeared before immutable identity adoption")
    verify_resource_tags(env, state, safety, "safety Run Command")
    identities["run-command-safety"] = immutable_identity(safety, "run-command")
    resources["safety_run_command_id"] = safety_id
    ttl_id = exact_id(env, "Microsoft.DevTestLab", "schedules", resources["ttl_schedule_name"])
    exists, ttl = read_exact_resource(env, ttl_id, "ttl-schedule")
    if not exists:
        raise RunnerError("control-plane TTL schedule disappeared before immutable identity adoption")
    verify_resource_tags(env, state, ttl, "TTL schedule")
    verify_ttl_schedule(state, ttl)
    identities["ttl-schedule"] = immutable_identity(ttl, "ttl-schedule")
    resources["ttl_schedule_id"] = ttl_id
    resources["vm_instance_id"] = instance_id
    resources["identities"] = identities
    save_state(env, state)


def create_vm(env, state):
    deadline = dt.datetime.fromisoformat(
        state["request"]["compute_deallocation_deadline"].replace("Z", "+00:00")
    )
    required_lead = dt.timedelta(
        seconds=AZURE_SCHEDULE_MINIMUM_LEAD_SECONDS + LOCAL_COMMAND_TIMEOUT_SECONDS
    )
    if deadline <= now_utc() + required_lead:
        raise RunnerError(
            "control-plane TTL schedule has insufficient lead for Azure's 30-minute activation window and bounded deployment"
        )
    params = write_private_json(env, ".vm-params-", deployment_parameters(env, state))
    try:
        az_command(env, [
            "deployment", "group", "create", "--resource-group", env["resource_group"],
            "--name", state["resources"]["deployment"], "--template-file", str(TEMPLATE),
            "--parameters", "@" + str(params), "--mode", "Incremental",
        ])
    finally:
        params.unlink(missing_ok=True)
    exists, vm = read_exact_resource(env, state["resources"]["vm_id"], "vm")
    if not exists:
        raise RunnerError("runner deployment completed without its exact VM")
    adopt_vm_identity(env, state, vm)
    transition(env, state, "vm-created", "exact identity-less VM/NIC/OS disk created")


def managed_run_command_id(state):
    return state["resources"]["vm_id"] + "/runCommands/" + state["resources"]["run_command_name"]


def safety_run_command_id(state):
    return state["resources"]["vm_id"] + "/runCommands/" + state["resources"].get(
        "safety_run_command_name", "safety-shutdown"
    )


def ttl_schedule_id(env, state):
    return state["resources"].get("ttl_schedule_id") or exact_id(
        env, "Microsoft.DevTestLab", "schedules", state["resources"]["ttl_schedule_name"]
    )


def verify_ttl_schedule(state, resource):
    properties = resource.get("properties", resource)
    deadline = dt.datetime.fromisoformat(
        state["request"]["compute_deallocation_deadline"].replace("Z", "+00:00")
    )
    if (
        resource.get("location") != "eastus"
        or properties.get("status") != "Enabled"
        or properties.get("taskType") != "ComputeVmShutdownTask"
        or properties.get("dailyRecurrence", {}).get("time") != deadline.strftime("%H%M")
        or properties.get("timeZoneId") != "UTC"
        or str(properties.get("targetResourceId", "")).lower() != state["resources"]["vm_id"].lower()
        or properties.get("notificationSettings", {}).get("status") != "Disabled"
    ):
        raise RunnerError("control-plane TTL schedule binding is not exact")


def create_run_command(env, state, input_url, output_url):
    current_guest_digest = "sha256:" + sha256_file(GUEST)
    if current_guest_digest != state["request"]["protocol"]["guest_digest"]:
        raise RunnerError("trusted guest protocol changed after request preparation")
    script = GUEST.read_text(encoding="utf-8")
    properties = {
        "location": "eastus",
        "tags": ownership_tags(env, state),
        "properties": {
            "source": {"script": script},
            "parameters": [
                {"name": "input_digest", "value": state["input_digest"]},
                {"name": "vm_resource_id", "value": state["resources"]["vm_id"]},
                {"name": "vm_instance_id", "value": state["resources"]["vm_instance_id"]},
                {"name": "guest_digest", "value": state["request"]["protocol"]["guest_digest"]},
            ],
            "protectedParameters": [
                {"name": "input_url", "value": input_url},
                {"name": "output_url", "value": output_url},
            ],
            "asyncExecution": False,
            "timeoutInSeconds": state["request"]["limits"]["wall_seconds"] + 1200,
            "treatFailureAsDeploymentFailure": True,
        },
    }
    body = write_private_json(env, ".run-command-", properties)
    run_id = managed_run_command_id(state)
    url = "https://management.azure.com{}?api-version=2024-03-01".format(run_id)
    try:
        az_command(env, ["rest", "--method", "put", "--url", url, "--body", "@" + str(body)])
    finally:
        body.unlink(missing_ok=True)
    state["resources"]["run_command_id"] = run_id
    exists, run_command = read_exact_resource(env, run_id, "run-command")
    if not exists:
        raise RunnerError("managed run command disappeared before immutable identity adoption")
    verify_resource_tags(env, state, run_command, "run-command")
    state["resources"].setdefault("identities", {})["run-command-execute"] = immutable_identity(run_command, "run-command")
    transition(env, state, "command-submitted", "managed control-plane command submitted")


def run_command_exists(env, state):
    run_id = managed_run_command_id(state)
    url = "https://management.azure.com{}?api-version=2024-03-01".format(run_id)
    result, rc, stderr = az_command(env, ["rest", "--method", "get", "--url", url], check=False)
    if rc == 0:
        return True, result
    listing, list_rc, list_stderr = az_command(env, [
        "resource", "list", "--resource-group", env["resource_group"],
        "--resource-type", "Microsoft.Compute/virtualMachines/runCommands",
    ], check=False)
    if list_rc != 0:
        raise RunnerError("Managed Run Command absence is ambiguous: {}; {}".format(stderr, list_stderr))
    ids = {str(item.get("id", "")).lower() for item in listing}
    return run_id.lower() in ids, None


def poll_run_command(env, state):
    url = "https://management.azure.com{}?api-version=2024-03-01&$expand=instanceView".format(managed_run_command_id(state))
    deadline = time.monotonic() + state["request"]["limits"]["wall_seconds"] + 1500
    while time.monotonic() < deadline:
        result, rc, stderr = az_command(env, ["rest", "--method", "get", "--url", url], check=False)
        if rc != 0:
            raise RunnerError("managed run-command status is unreadable: {}".format(stderr))
        properties = result.get("properties", {})
        view = properties.get("instanceView") or {}
        execution = str(view.get("executionState", ""))
        provisioning = str(properties.get("provisioningState", ""))
        if execution in ("Succeeded", "Failed", "Canceled", "TimedOut"):
            output = str(view.get("output", ""))
            error = str(view.get("error", ""))
            if execution != "Succeeded":
                raise RunnerError("managed run command failed ({}, {}): {}".format(execution, provisioning, error[-1000:]))
            marker = re.search(r"FM_AZURE_RESULT\s+(sha256:[0-9a-f]{64})\s+boot=([0-9a-f-]{36})", output)
            if not marker:
                raise RunnerError("managed run command completed without a valid result identity marker")
            state["expected_result_digest"] = marker.group(1)
            state["expected_boot_id"] = marker.group(2)
            transition(env, state, "result-published", "guest published digest-bound output")
            return
        time.sleep(10)
    raise RunnerError("managed run command exceeded its control-plane completion bound")


def safe_extract_result(archive_path, destination):
    allowed = {"result.json", "stdout.log", "stderr.log"}
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            name = member.name
            if name in allowed or name == "artifacts":
                pass
            elif name.startswith("artifacts/") and require_artifact(name[len("artifacts/"):]):
                pass
            else:
                raise RunnerError("result archive contains an undeclared path: {}".format(name))
            if member.issym() or member.islnk() or member.isdev():
                raise RunnerError("result archive contains a link/device")
            target = (destination / name).resolve()
            if destination.resolve() not in target.parents and target != destination.resolve():
                raise RunnerError("result archive path escapes destination")
        archive.extractall(str(destination), members=members)


def collect_result(env, state):
    result_dir = env["state_dir"] / "results" / state["invocation"]
    if result_dir.exists():
        raise RunnerError("result destination already exists; collection will not overwrite it")
    work_dir = result_dir.with_name(".{}.{}.tmp".format(result_dir.name, uuid.uuid4().hex))
    work_dir.mkdir(parents=True, mode=0o700)
    try:
        result = verify_downloaded_result(env, state, work_dir)
        os.replace(str(work_dir), str(result_dir))
    except Exception:
        shutil.rmtree(work_dir, ignore_errors=True)
        raise
    state["result"] = result
    state["result_path"] = str(result_dir)
    state["result_digest"] = state["expected_result_digest"]
    transition(env, state, "result-collected", "result identity and every returned digest verified")
    return result


def verify_downloaded_result(env, state, result_dir):
    archive_path = result_dir / "result.tar.gz"
    storage_download(env, state["staging"]["output_blob"], archive_path)
    digest = "sha256:" + sha256_file(archive_path)
    if digest != state.get("expected_result_digest"):
        raise RunnerError("retrieved result digest does not match the control-plane publication marker")
    extracted = result_dir / "extracted"
    extracted.mkdir(mode=0o700)
    safe_extract_result(archive_path, extracted)
    result = json.loads((extracted / "result.json").read_text(encoding="utf-8"))
    checks = {
        "schema": RESULT_SCHEMA,
        "request_digest": state["request_digest"],
        "invocation": state["invocation"],
        "attempt": state["attempt"],
        "fence": state["request"]["fence"],
        "snapshot_digest": state["request"]["repository"]["snapshot_digest"],
        "commit": state["request"]["repository"]["commit"],
        "tree": state["request"]["repository"]["tree"],
        "command_digest": state["request"]["command_digest"],
        "vm_resource_id": state["resources"]["vm_id"],
        "vm_instance_id": state["resources"]["vm_instance_id"],
        "boot_id": state["expected_boot_id"],
    }
    for key, expected in checks.items():
        if result.get(key) != expected:
            raise RunnerError("result identity mismatch: {}".format(key))
    for log_name, field in (("stdout.log", "stdout_digest"), ("stderr.log", "stderr_digest")):
        actual = "sha256:" + sha256_file(extracted / log_name)
        if result.get(field) != actual:
            raise RunnerError("result log integrity mismatch: {}".format(log_name))
    declared = state["request"].get("artifacts", [])
    records = result.get("artifacts")
    if not isinstance(records, list):
        raise RunnerError("result artifact manifest is malformed")
    seen = set()
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise RunnerError("result artifact record is malformed")
        relative = require_artifact(record["path"])
        if relative in seen or not any(relative == item or relative.startswith(item.rstrip("/") + "/") for item in declared):
            raise RunnerError("result returned an undeclared or duplicate artifact: {}".format(relative))
        seen.add(relative)
        artifact_path = extracted / "artifacts" / relative
        if not artifact_path.is_file() or artifact_path.is_symlink():
            raise RunnerError("result artifact file is absent or linked: {}".format(relative))
        if artifact_path.stat().st_size != record.get("bytes") or "sha256:" + sha256_file(artifact_path) != record.get("digest"):
            raise RunnerError("result artifact integrity mismatch: {}".format(relative))
    returned_files = set()
    artifact_root = extracted / "artifacts"
    if artifact_root.exists():
        returned_files = {path.relative_to(artifact_root).as_posix() for path in artifact_root.rglob("*") if path.is_file()}
    if returned_files != seen:
        raise RunnerError("result archive and artifact manifest disagree")
    return result


def get_vm(env, state):
    result, rc, stderr = az_command(env, ["vm", "show", "--ids", state["resources"]["vm_id"]], check=False)
    if rc == 0:
        return True, result
    listing, list_rc, list_stderr = az_command(env, [
        "vm", "list", "--resource-group", env["resource_group"],
    ], check=False)
    if list_rc != 0:
        raise RunnerError("VM absence is ambiguous: {}; {}".format(stderr, list_stderr))
    matches = [vm for vm in listing if str(vm.get("id", "")).lower() == state["resources"]["vm_id"].lower()]
    if matches:
        return True, matches[0]
    return False, None


def verify_resource_tags(env, state, resource, label):
    tags = resource.get("tags") or {}
    expected = ownership_tags(env, state)
    for key in (
        "workload", "firstmate-role", "lifecycle", "deployment-generation", "cleanup-owner",
        "home-binding", "task-binding", "task-generation", "invocation-binding", "attempt", "fence",
        "snapshot-digest", "command-digest", "resource-class", "selected-sku", "sku-family",
        "cost-attribution", "cleanup-token",
    ):
        if tags.get(key) != expected[key]:
            raise RunnerError("live {} cleanup tag mismatch: {}".format(label, key))


def verify_live_resource_identity(env, state, kind, resource_id, identity_key=None, require_vm_relation=True):
    exists, resource = read_exact_resource(env, resource_id, kind)
    if not exists:
        return False, None
    verify_resource_tags(env, state, resource, kind)
    identity_key = identity_key or kind
    recorded = state["resources"].get("identities", {}).get(identity_key)
    if recorded is None or immutable_identity(resource, kind) != recorded:
        raise RunnerError("live {} immutable identity changed; cleanup retained ambiguous state".format(kind))
    if require_vm_relation and kind == "nic" and str(resource.get("properties", {}).get("virtualMachine", {}).get("id", "")).lower() != state["resources"]["vm_id"].lower():
        raise RunnerError("live NIC is not managed by the exact runner VM")
    if require_vm_relation and kind == "disk" and str(resource.get("managedBy") or resource.get("properties", {}).get("managedBy") or "").lower() != state["resources"]["vm_id"].lower():
        raise RunnerError("live OS disk is not managed by the exact runner VM")
    if kind == "ttl-schedule":
        verify_ttl_schedule(state, resource)
    return True, resource


def disposable_plan(state, include_vm=True):
    planned = [
        ("ttl-schedule", "ttl-schedule", state["resources"]["ttl_schedule_id"]),
        ("run-command", "run-command-execute", state["resources"].get("run_command_id") or managed_run_command_id(state)),
        ("run-command", "run-command-safety", state["resources"].get("safety_run_command_id") or safety_run_command_id(state)),
    ]
    if include_vm:
        planned.append(("vm", "vm", state["resources"]["vm_id"]))
    planned.extend((
        ("nic", "nic", state["resources"]["nic_id"]),
        ("disk", "disk", state["resources"]["os_disk_id"]),
    ))
    return planned


def classify_disposable_resources(env, state, include_vm=True):
    planned = disposable_plan(state, include_vm=include_vm)
    resources, _, _ = az_command(env, ["resource", "list", "--resource-group", env["resource_group"]])
    run_commands, _, _ = az_command(env, [
        "resource", "list", "--resource-group", env["resource_group"],
        "--resource-type", "Microsoft.Compute/virtualMachines/runCommands",
    ])
    resources = resources + run_commands
    expected_ids = {resource_id.lower() for _, _, resource_id in planned}
    vm_child_prefix = state["resources"]["vm_id"].lower() + "/"
    residual = [
        item for item in resources
        if (item.get("tags") or {}).get("invocation-binding") == state["invocation"]
        or str(item.get("id", "")).lower() in expected_ids
        or str(item.get("id", "")).lower().startswith(vm_child_prefix)
    ]
    residual_ids = {str(item.get("id", "")).lower() for item in residual}
    unknown = sorted(residual_ids - expected_ids)
    if unknown:
        raise RunnerError("VM-absent invocation has an unplanned residual resource; cleanup retained ambiguous state")
    classified = []
    for kind, identity_key, resource_id in planned:
        exists, resource = verify_live_resource_identity(env, state, kind, resource_id, identity_key)
        if exists:
            classified.append((kind, identity_key, resource_id, resource))
    return classified


def cleanup_partial_capacity(env, state):
    classified = classify_disposable_resources(env, state, include_vm=False)
    for kind, identity_key, resource_id, resource in classified:
        delete_classified_resource(env, state, resource_id, kind, identity_key, resource)


def delete_resource(env, state, resource_id, kind):
    exists, resource = verify_live_resource_identity(env, state, kind, resource_id)
    if not exists:
        return
    delete_classified_resource(env, state, resource_id, kind, kind, resource)


def delete_classified_resource(env, state, resource_id, kind, identity_key, resource):
    url = resource_url(resource_id, RESOURCE_API_VERSIONS[kind])
    _, rc, stderr = az_command(env, [
        "rest", "--method", "delete", "--url", url,
        "--headers", "If-Match={}".format(resource["etag"]),
    ], check=False)
    if rc != 0:
        raise RunnerError("conditional exact {} deletion failed: {}".format(kind, stderr))
    remains, _ = read_exact_resource(env, resource_id, kind)
    if remains:
        raise RunnerError("exact {} still exists after conditional delete".format(kind))


def adopt_expected_detach(env, state, kind, identity_key, resource_id):
    exists, resource = read_exact_resource(env, resource_id, kind)
    if not exists:
        return None
    verify_resource_tags(env, state, resource, kind)
    recorded = state["resources"]["identities"][identity_key]
    current = immutable_identity(resource, kind)
    stable_fields = {"nic": ("id", "resource_guid"), "disk": ("id", "unique_id")}[kind]
    if any(current.get(field) != recorded.get(field) for field in stable_fields):
        raise RunnerError("detached {} stable immutable identity changed; cleanup retained ambiguous state".format(kind))
    relation = resource.get("properties", {}).get("virtualMachine", {}).get("id") if kind == "nic" else (
        resource.get("managedBy") or resource.get("properties", {}).get("managedBy")
    )
    if relation:
        raise RunnerError("{} did not detach from the deleted runner VM".format(kind))
    state["resources"]["identities"][identity_key] = current
    save_state(env, state)
    return resource


def cleanup(env, state):
    if state.get("phase") not in ("result-collected", "cleanup-retained", "complete"):
        raise RunnerError("cleanup requires a safely collected result; active or ambiguous work is retained")
    if state.get("phase") == "complete":
        return
    try:
        classified = classify_disposable_resources(env, state, include_vm=True)
        by_key = {identity_key: (kind, resource_id, resource) for kind, identity_key, resource_id, resource in classified}
        for identity_key in ("run-command-execute", "run-command-safety"):
            if identity_key in by_key:
                kind, resource_id, resource = by_key[identity_key]
                delete_classified_resource(env, state, resource_id, kind, identity_key, resource)
        if "vm" in by_key:
            kind, resource_id, resource = by_key["vm"]
            delete_classified_resource(env, state, resource_id, kind, "vm", resource)
        for kind, identity_key, resource_id in (
            ("nic", "nic", state["resources"]["nic_id"]),
            ("disk", "disk", state["resources"]["os_disk_id"]),
        ):
            resource = adopt_expected_detach(env, state, kind, identity_key, resource_id)
            if resource is not None:
                delete_classified_resource(env, state, resource_id, kind, identity_key, resource)
        if "ttl-schedule" in by_key:
            kind, resource_id, resource = by_key["ttl-schedule"]
            delete_classified_resource(env, state, resource_id, kind, "ttl-schedule", resource)
    except RunnerError:
        transition(env, state, "cleanup-retained", "compute cleanup ambiguous; staging retained")
        raise
    transition(env, state, "compute-removed", "exact invocation VM/NIC/OS disk absent")
    try:
        storage_delete(env, state["staging"]["input_blob"])
        storage_delete(env, state["staging"]["output_blob"])
    except RunnerError:
        transition(env, state, "cleanup-retained", "staging cleanup ambiguous after compute removal")
        raise
    payload_dir = Path(state["input_path"]).parent
    if payload_dir.parent == env["state_dir"] / "payloads":
        shutil.rmtree(payload_dir, ignore_errors=False)
    if state.get("reservation_recorded"):
        try:
            mark_reservation_cleanup_verified(env, state)
        except RunnerError:
            transition(env, state, "cleanup-retained", "cost reservation reconciliation marker is ambiguous")
            raise
    transition(env, state, "complete", "verified result retained locally; invocation compute and staging are zero")


def dispatch_prepared(env, state, confirm_subscription):
    bind_operation_context(env, state)
    if confirm_subscription != env["subscription"]:
        raise RunnerError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    try:
        deadline = dt.datetime.fromisoformat(
            state["request"]["compute_deallocation_deadline"].replace("Z", "+00:00")
        )
        if deadline <= now_utc() + dt.timedelta(minutes=10):
            raise RunnerError("prepared invocation has insufficient time remaining before its control-plane deallocation deadline")
        scope_gate(env)
        limits = state["request"]["limits"]
        sku_quota_gate(env, limits)
        cost = budget_gate(env, limits)
        foundation_gate(env)
        transition(env, state, "admission-checked", "scope, quota, SKU, budget, and exact foundation gates passed", cost=cost)
        with AdmissionLease(env, state) as lease:
            foundation_gate(env)
            sku_quota_gate(env, limits)
            active = active_runner_vms(env)
            if len(active) >= env["max_concurrency"]:
                raise RunnerError("runner queue is at its bounded concurrency limit ({})".format(env["max_concurrency"]))
            cost = reserve_budget(env, state, lease, limits)
            transition(
                env, state, "cost-reserved",
                "durable worst-case cost reserved under the admission lease",
                cost=cost, reservation_recorded=True,
            )
            foundation_gate(env)
            storage_upload(env, state["input_path"], state["staging"]["input_blob"], overwrite=False)
            transition(env, state, "input-staged", "exact private input object uploaded")
            expiry = (now_utc() + dt.timedelta(seconds=limits["wall_seconds"] + 1800)).strftime("%Y-%m-%dT%H:%MZ")
            input_url = blob_sas(env, state["staging"]["input_blob"], "r", expiry)
            output_url = blob_sas(env, state["staging"]["output_blob"], "cw", expiry)
            foundation_gate(env)
            lease.renew_and_assert()
            create_vm(env, state)
            lease.assert_held()
        create_run_command(env, state, input_url, output_url)
        poll_run_command(env, state)
        result = collect_result(env, state)
        cleanup(env, state)
    except Exception as exc:
        if state.get("phase") not in ("cleanup-retained", "complete", "absent-fenced"):
            transition(env, state, "failed-retained", str(exc)[:500])
        raise
    print_logs_and_summary(state, result)
    return int(result["exit_code"])


def print_logs_and_summary(state, result):
    extracted = Path(state["result_path"]) / "extracted"
    stdout = (extracted / "stdout.log").read_text(encoding="utf-8", errors="replace")
    stderr = (extracted / "stderr.log").read_text(encoding="utf-8", errors="replace")
    if stdout:
        sys.stdout.write(stdout)
        if not stdout.endswith("\n"):
            sys.stdout.write("\n")
    if stderr:
        sys.stderr.write(stderr)
        if not stderr.endswith("\n"):
            sys.stderr.write("\n")
    print(
        "azure-runner: invocation={} exit={} timeout={} signal={} stdout_truncated={} stderr_truncated={} max_cost=${:.2f}".format(
            state["invocation"], result["exit_code"], str(result["timed_out"]).lower(),
            result.get("signal") if result.get("signal") is not None else "none",
            str(result["stdout_truncated"]).lower(), str(result["stderr_truncated"]).lower(),
            state.get("cost", {}).get("max_increment", 0.0),
        ),
        file=sys.stderr,
    )


def resume(env, state):
    bind_operation_context(env, state)
    phase = state.get("phase")
    if phase == "complete":
        print_logs_and_summary(state, state["result"])
        return int(state["result"]["exit_code"])
    scope_gate(env)
    if phase in ("result-published", "failed-retained") and state.get("expected_result_digest"):
        result = collect_result(env, state)
        cleanup(env, state)
        print_logs_and_summary(state, result)
        return int(result["exit_code"])
    if phase == "result-collected" or phase == "cleanup-retained":
        cleanup(env, state)
        print_logs_and_summary(state, state["result"])
        return int(state["result"]["exit_code"])
    if phase in (
        "prepared", "admission-checked", "cost-reserved", "input-staged", "vm-created", "command-submitted", "failed-retained"
    ):
        output_exists, _, _ = az_command(env, [
            "storage", "blob", "exists", "--auth-mode", "login", "--account-name", env["storage"],
            "--container-name", CONTAINER, "--name", state["staging"]["output_blob"],
        ])
        vm_exists, vm = get_vm(env, state)
        if output_exists.get("exists") and state.get("expected_result_digest"):
            result = collect_result(env, state)
            cleanup(env, state)
            print_logs_and_summary(state, result)
            return int(result["exit_code"])
        if vm_exists:
            foundation_gate(env)
            adopt_vm_identity(env, state, vm)
            command_exists, _ = run_command_exists(env, state)
            if not command_exists:
                if output_exists.get("exists"):
                    raise RunnerError("output exists without a durable Managed Run Command digest marker; state is retained")
                input_exists, _, _ = az_command(env, [
                    "storage", "blob", "exists", "--auth-mode", "login", "--account-name", env["storage"],
                    "--container-name", CONTAINER, "--name", state["staging"]["input_blob"],
                ])
                if not input_exists.get("exists"):
                    raise RunnerError("VM exists but exact staged input is absent; state is retained")
                expiry = (
                    now_utc() + dt.timedelta(seconds=state["request"]["limits"]["wall_seconds"] + 1800)
                ).strftime("%Y-%m-%dT%H:%MZ")
                input_url = blob_sas(env, state["staging"]["input_blob"], "r", expiry)
                output_url = blob_sas(env, state["staging"]["output_blob"], "cw", expiry)
                create_run_command(env, state, input_url, output_url)
            else:
                transition(env, state, "command-submitted", "existing Managed Run Command adopted without resubmission")
            poll_run_command(env, state)
            result = collect_result(env, state)
            cleanup(env, state)
            print_logs_and_summary(state, result)
            return int(result["exit_code"])
        if output_exists.get("exists"):
            raise RunnerError("VM is absent but an unverified result object remains; retry is unsafe")
        cleanup_partial_capacity(env, state)
        input_exists, _, _ = az_command(env, [
            "storage", "blob", "exists", "--auth-mode", "login", "--account-name", env["storage"],
            "--container-name", CONTAINER, "--name", state["staging"]["input_blob"],
        ])
        if input_exists.get("exists"):
            storage_delete(env, state["staging"]["input_blob"])
        transition(env, state, "absent-fenced", "VM and invocation staging absence proven; same invocation will never be rerun", old_lease_absent=True)
        if state.get("reservation_recorded"):
            mark_reservation_cleanup_verified(env, state)
        raise RunnerError("runner VM is absent without a verified result; retry requires a new fenced attempt")
    raise RunnerError("invocation phase {} cannot be resumed automatically".format(phase))


def retry(env, old_state, args):
    bind_operation_context(env, old_state)
    if old_state.get("phase") != "absent-fenced" or old_state.get("old_lease_absent") is not True:
        raise RunnerError("retry requires old invocation absence to be proven by resume/reconcile")
    scope_gate(env)
    vm_exists, _ = get_vm(env, old_state)
    input_exists, _, _ = az_command(env, [
        "storage", "blob", "exists", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", CONTAINER, "--name", old_state["staging"]["input_blob"],
    ])
    output_exists, _, _ = az_command(env, [
        "storage", "blob", "exists", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", CONTAINER, "--name", old_state["staging"]["output_blob"],
    ])
    if vm_exists or input_exists.get("exists") or output_exists.get("exists"):
        raise RunnerError("old invocation absence no longer holds; retry is fenced")
    current = Path(old_state["repository_root"]).resolve()
    if git(current, "rev-parse", "HEAD").stdout.strip() != old_state["request"]["repository"]["commit"]:
        raise RunnerError("retry repository HEAD differs from the fenced old snapshot")
    args.repo = str(current)
    args.task = old_state["request"]["task"]
    args.generation = old_state["request"]["generation"]
    args.resource_class = old_state["request"]["resource_class"]
    args.wall_seconds = old_state["request"]["limits"]["wall_seconds"]
    args.dependency = [item["path"] for item in old_state["request"].get("dependencies", [])]
    args.artifact = list(old_state["request"].get("artifacts", []))
    args.command = list(old_state["request"]["command"]["argv"])
    args.invocation = None
    with state_lock(env):
        state = prepare(env, args, parent_state=old_state)
    bind_operation_context(env, state)
    with invocation_lock(env, state["invocation"]):
        return dispatch_prepared(env, state, args.confirm_subscription)


def local_queue(env):
    ensure_state_dirs(env)
    states = []
    for path in sorted(env["state_dir"].glob("azr-*.json")):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            value = json.loads(path.read_text(encoding="utf-8"))
            states.append((value.get("invocation", "?"), value.get("phase", "?"), value.get("request", {}).get("task", "?")))
    active = [item for item in states if item[1] not in ("complete", "absent-fenced")]
    print("queue: active={} total={}".format(len(active), len(states)))
    for invocation, phase, task in active:
        print("  {} {} {}".format(invocation, phase, task))


def cloud_cost_status(env):
    scope_gate(env)
    actual = cost_query(env, False)
    forecast = cost_query(env, True)
    active = active_runner_vms(env)
    print("cost: actual=${:.2f} forecast=${:.2f} target=${} active_runner_vms={} max_concurrency={}".format(
        actual, forecast, env["budget_limit"], len(active), env["max_concurrency"]
    ))


def show_status(env, state):
    result = state.get("result") or {}
    print("status: invocation={} phase={} task={} generation={} attempt={} commit={} command={} exit={}".format(
        state["invocation"], state["phase"], state["request"]["task"], state["request"]["generation"],
        state["attempt"], state["request"]["repository"]["commit"], state["request"]["command_digest"],
        result.get("exit_code", "pending"),
    ))


def add_request_arguments(parser, require_command=True):
    parser.add_argument("--repo")
    parser.add_argument("--task", required=True)
    parser.add_argument("--generation", required=True)
    parser.add_argument("--invocation")
    parser.add_argument("--resource-class", choices=sorted(RESOURCE_CLASSES), default="validation-standard")
    parser.add_argument("--wall-seconds", type=int)
    parser.add_argument("--dependency", action="append", default=[])
    parser.add_argument("--artifact", action="append", default=[])
    if require_command:
        parser.add_argument("command", nargs=argparse.REMAINDER)


def parser():
    result = argparse.ArgumentParser(prog="fm-azure-runner.sh")
    sub = result.add_subparsers(dest="operation", required=True)
    prepare_parser = sub.add_parser("prepare", help="package a clean snapshot and canonical request without Azure mutation")
    add_request_arguments(prepare_parser)
    run_parser = sub.add_parser("run", help="run one confirmed disposable Azure invocation")
    add_request_arguments(run_parser)
    run_parser.add_argument("--confirm-run", action="store_true")
    run_parser.add_argument("--confirm-subscription")
    resume_parser = sub.add_parser("resume", help="resume collection/cleanup without duplicating execution")
    resume_parser.add_argument("--invocation", required=True)
    retry_parser = sub.add_parser("retry", help="create a new fenced attempt after proven old-lease absence")
    retry_parser.add_argument("--invocation", required=True)
    retry_parser.add_argument("--confirm-run", action="store_true")
    retry_parser.add_argument("--confirm-subscription")
    queue_parser = sub.add_parser("queue", help="show concise local invocation queue state")
    cost_parser = sub.add_parser("cost", help="show concise Azure cost/concurrency admission state")
    status_parser = sub.add_parser("status", help="show one invocation identity and outcome")
    status_parser.add_argument("--invocation", required=True)
    cleanup_parser = sub.add_parser("cleanup", help="retry exact cleanup after a safely collected result")
    cleanup_parser.add_argument("--invocation", required=True)
    return result


def normalize_command(args):
    if hasattr(args, "command") and args.command and args.command[0] == "--":
        args.command = args.command[1:]


def main():
    args = parser().parse_args()
    normalize_command(args)
    env = environment()
    ensure_state_dirs(env)
    if args.operation == "prepare":
        with state_lock(env):
            state = prepare(env, args)
        print("prepared: invocation={} request={} snapshot={} command={} input={}".format(
            state["invocation"], state["request_digest"], state["request"]["repository"]["snapshot_digest"],
            state["request"]["command_digest"], state["input_digest"],
        ))
        return 0
    if args.operation == "run":
        if not args.confirm_run or not args.confirm_subscription:
            raise RunnerError("run requires --confirm-run and --confirm-subscription <exact-id>")
        with state_lock(env):
            state = prepare(env, args)
        with invocation_lock(env, state["invocation"]):
            return dispatch_prepared(env, state, args.confirm_subscription)
    if args.operation == "queue":
        local_queue(env)
        return 0
    if args.operation == "cost":
        cloud_cost_status(env)
        return 0
    with state_lock(env):
        state = load_state(env, args.invocation)
    if args.operation == "status":
        show_status(env, state)
        return 0
    if args.operation == "resume":
        with invocation_lock(env, state["invocation"]):
            state = load_state(env, state["invocation"])
            return resume(env, state)
    if args.operation == "cleanup":
        with invocation_lock(env, state["invocation"]):
            state = load_state(env, state["invocation"])
            cleanup(env, state)
        return 0
    if args.operation == "retry":
        if not args.confirm_run or not args.confirm_subscription:
            raise RunnerError("retry requires --confirm-run and --confirm-subscription <exact-id>")
        with invocation_lock(env, state["invocation"]):
            state = load_state(env, state["invocation"])
            return retry(env, state, args)
    raise RunnerError("unsupported operation")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RunnerError as exc:
        print("AZURE RUNNER FAILED: {}".format(exc), file=sys.stderr)
        sys.exit(125)
